import SwiftUI
import HueCore

@MainActor final class BridgeConnection: ObservableObject {
    struct Services {
        var loadKey: (String) throws -> String? = { try BridgeKeychain.load(bridgeID: $0) }
        var saveKey: (String, String) throws -> Void = { try BridgeKeychain.save($0, bridgeID: $1) }
        var removeKey: (String) throws -> Void = { try BridgeKeychain.remove(bridgeID: $0) }
        var makeClient: (String, String, String, BridgeAccess) -> HueClient = { host, key, bridgeID, access in
            HueClient(configuration: .init(host: host, applicationKey: key), access: access, trust: .init(host: host, bridgeID: bridgeID))
        }
    }
    @Published var host = ""
    @Published var bridgeID = ""
    @Published private(set) var busy = false
    @Published private(set) var verified = false
    @Published private(set) var message = "Verify your Bridge, then press its physical button when asked."
    @Published private(set) var paired = false
    struct DiscoveredBridge: Decodable, Identifiable { let id: String; let internalipaddress: String }
    @Published private(set) var discovered: [DiscoveredBridge] = []
    @Published private(set) var savedBridges: [DiscoveredBridge] = []
    var requiresExplicitReconnect: Bool { defaults.bool(forKey: "connectionDisconnected") }
    func selectSavedBridge(_ id: String) {
        guard !busy, !paired, pendingKey == nil, let saved = savedBridges.first(where: { $0.id == id }) else { return }
        bridgeID = saved.id; host = saved.internalipaddress; verified = false; verifiedEndpoint = nil
        defaults.set(true, forKey: "connectionDisconnected")
        rememberEndpoint()
        message = "Saved Bridge selected. Choose Reconnect to use this Mac’s saved access."
    }
    /// Keeps all per-Bridge keys and preferences. Selecting the next endpoint makes no request.
    func disconnectForSwitch() -> Bool {
        guard !busy, pendingKey == nil else { return false }
        pauseForSleep(); paired = false; verifiedEndpoint = nil; discovered = []
        defaults.set(true, forKey: "connectionDisconnected")
        message = "Disconnected. Choose a saved Bridge, find another, or enter its details. Saved access and preferences are kept."
        return true
    }
    func selectDiscovered(_ id: String) {
        guard !busy, !paired, let bridge = discovered.first(where: { $0.id == id }) else { return }
        bridgeID = bridge.id.lowercased(); host = bridge.internalipaddress; verified = false
    }
    func updateVerifiedAddress(_ address: String) { host = address; rememberEndpoint() }
    private func rememberEndpoint() {
        var records = defaults.dictionary(forKey: "bridgeEndpoints") as? [String: String] ?? [:]
        if let previousID = defaults.string(forKey: "bridgeID"), let previousHost = defaults.string(forKey: "bridgeHost") { records[previousID] = previousHost }
        records[bridgeID] = host
        defaults.set(records, forKey: "bridgeEndpoints")
        defaults.set(host, forKey: "bridgeHost"); defaults.set(bridgeID, forKey: "bridgeID")
        savedBridges = records.map { DiscoveredBridge(id: $0.key, internalipaddress: $0.value) }.sorted { $0.id < $1.id }
    }
    private let defaults: UserDefaults
    private let services: Services
    private var suspendedForSleep = false
    private var pendingRead: HueReadConnection?
    private var pendingService: HuePairingService?
    private var pendingInventory: HueClient?
    private var discoverySession: URLSession?
    func pauseForSleep() {
        suspendedForSleep = true; verified = false
        if let pendingRead { Task { await pendingRead.close() } }
        if let pendingService { Task { await pendingService.close() } }
        pendingInventory?.close(); discoverySession?.invalidateAndCancel()
    }
    private var pendingKey: String?
    private var verifiedEndpoint: String?
    init(defaults: UserDefaults = .standard, services: Services = Services()) {
        self.defaults = defaults; self.services = services
        let args = CommandLine.arguments
        func value(_ name: String) -> String { guard let index = args.firstIndex(of: name), args.count > index + 1 else { return "" }; return args[index + 1] }
        host = value("--bridge-host"); bridgeID = value("--bridge-id")
        if host.isEmpty { host = defaults.string(forKey: "bridgeHost") ?? "" }
        if bridgeID.isEmpty { bridgeID = defaults.string(forKey: "bridgeID") ?? "" }
        var records = defaults.dictionary(forKey: "bridgeEndpoints") as? [String: String] ?? [:]
        if !bridgeID.isEmpty, !host.isEmpty { records[bridgeID] = host }
        savedBridges = records.map { DiscoveredBridge(id: $0.key, internalipaddress: $0.value) }.sorted { $0.id < $1.id }
    }
    func removeLocalAccess() throws {
        guard !busy, pendingKey == nil else { throw HueError.approvalRequired }
        try services.removeKey(bridgeID)
        defaults.set(false, forKey: "setupComplete-" + bridgeID)
        paired = false; verified = false
        message = "Local access removed. Verify and pair again with the physical Bridge button."
    }
    var hasSavedEndpoint: Bool { !host.isEmpty && !bridgeID.isEmpty }
    var setupCompleted: Bool { defaults.bool(forKey: "setupComplete-" + bridgeID) }
    func completeSetup() throws -> HueClient {
        guard paired, let key = try services.loadKey(bridgeID) else { throw HueError.approvalRequired }
        defaults.set(true, forKey: "setupComplete-" + bridgeID)
        return services.makeClient(host, key, bridgeID, .control)
    }
    /// Restore never registers a new application if this Mac has no key.
    func restore() async -> (HomeSnapshot, HueClient)? {
        guard !busy, hasSavedEndpoint else { return nil }
        suspendedForSleep = false
        busy = true; defer { busy = false }
        do {
            guard let key = try services.loadKey(bridgeID) else { message = "This Mac needs its own pairing. Verify the Bridge, then press its button."; return nil }
            guard !suspendedForSleep else { throw CancellationError() }
            let client = services.makeClient(host, key, bridgeID, .readOnly)
            let recovery = HueReadConnection(client: client, bridgeID: bridgeID, host: host, addressChanged: { _ in })
            pendingRead = recovery
            defer { pendingRead = nil }
            do {
                let snapshot = HomeSnapshot.project(try await recovery.resources())
                guard !suspendedForSleep else { await recovery.close(); throw CancellationError() }
                let resolved = await recovery.currentEndpoint()
                host = resolved.host
                paired = true; verified = true; verifiedEndpoint = endpoint
                defaults.set(false, forKey: "connectionDisconnected")
                rememberEndpoint()
                message = "Connected. \(snapshot.scenes.count) scenes. Access is stored on this Mac."
                return (snapshot, resolved.client)
            } catch { await recovery.close(); throw error }
        } catch { message = "Could not reconnect. Check Bridge address, Local Network permission, and Keychain access."; return nil }
    }
    func discover() async {
        guard !busy, !paired, pendingKey == nil else { return }
        suspendedForSleep = false
        busy = true; defer { busy = false }
        do {
            var request = URLRequest(url: URL(string: "https://discovery.meethue.com/")!); request.timeoutInterval = 10
            let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
            discoverySession = session; defer { discoverySession = nil }
            let (data, response) = try await session.data(for: request)
            guard !suspendedForSleep else { throw CancellationError() }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HueError.malformedResponse }
            let bridges = try JSONDecoder().decode([DiscoveredBridge].self, from: data)
            discovered = bridges
            guard bridges.count == 1, let bridge = bridges.first else {
                message = bridges.isEmpty ? "No Bridge found. Enter its IP address and Bridge ID from your Hue app." : "Multiple Bridges found. Select the Bridge you want below."
                return
            }
            host = bridge.internalipaddress; bridgeID = bridge.id.lowercased(); verified = false
            message = "Bridge found. Verify the secure connection next."
        } catch { message = "Discovery did not complete. You can enter the Bridge details manually." }
    }
    private var endpoint: String { host + "|" + bridgeID.lowercased() }
    var canPair: Bool { verified && verifiedEndpoint == endpoint && !busy && !paired && !suspendedForSleep }
    var hasPendingSave: Bool { pendingKey != nil }
    /// Recovery is a local Keychain operation only, including when paused after sleep.
    func savePendingAccess() {
        guard !busy, let key = pendingKey else { return }
        busy = true; defer { busy = false }
        do {
            try services.saveKey(key, bridgeID)
            pendingKey = nil; rememberEndpoint()
            message = "Access saved on this Mac. Choose Reconnect explicitly to load your scenes."
        } catch { message = "Keychain could not save access. Keep this window open and retry saving." }
    }
    func verify() async {
        guard !busy, pendingKey == nil else { return }
        suspendedForSleep = false
        busy = true; verified = false; message = "Checking the secure connection…"
        defer { busy = false }
        do {
            let service = HuePairingService(trust: .init(host: host, bridgeID: bridgeID))
            pendingService = service; defer { pendingService = nil }
            try await service.verifyBridge()
            guard !suspendedForSleep else { throw CancellationError() }
            verified = true; verifiedEndpoint = endpoint
            message = "Bridge verified. Press its physical button, then choose Pair below."
        } catch { message = "Could not verify the Bridge. Check the address, Bridge ID, and Local Network permission. No pairing was attempted." }
    }
    func pairAndRead() async -> (HomeSnapshot, HueClient)? {
        guard canPair else { return nil }
        busy = true; message = pendingKey == nil ? "Connecting to the Bridge…" : "Saving access to Keychain…"
        defer { busy = false }
        let trust = HueTrustConfiguration(host: host, bridgeID: bridgeID)
        do {
            // Explicit user action only. Reuse our own saved key to avoid duplicate registrations.
            let saved = try services.loadKey(bridgeID)
            let key: String
            if let saved { key = saved }
            else {
                guard !suspendedForSleep else { throw CancellationError() }
                if pendingKey == nil {
                    let service = HuePairingService(trust: trust)
                    pendingService = service; defer { pendingService = nil }
                    pendingKey = try await service.pair()
                }
                guard let pendingKey else { throw PairingError.invalidResponse }
                try services.saveKey(pendingKey, bridgeID)
                key = pendingKey; self.pendingKey = nil
            }
            guard !suspendedForSleep else { throw CancellationError() }
            let client = services.makeClient(host, key, bridgeID, .readOnly)
            pendingInventory = client; defer { pendingInventory = nil }
            do {
                let resources = try await client.resources()
                let snapshot = HomeSnapshot.project(resources)
                guard !suspendedForSleep else { client.close(); throw CancellationError() }
                paired = true
                defaults.set(false, forKey: "connectionDisconnected")
                rememberEndpoint()
                message = "Connected. \(snapshot.scenes.count) scenes across \(snapshot.groups.count) rooms and zones. Access saved in Keychain."
                return (snapshot, client)
            } catch { client.close(); message = "Access is saved in Keychain. The scene inventory could not load; retry to reconnect without pairing again."; return nil }
        } catch let error as PairingError { message = error.localizedDescription }
        catch { message = "Connection failed. No light changes were requested. Verify network access, then try again." }
        return nil
    }
}
