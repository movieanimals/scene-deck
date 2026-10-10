import SwiftUI
import HueCore

@MainActor final class BridgeConnection: ObservableObject {
    @Published var host = ""
    @Published var bridgeID = ""
    @Published private(set) var busy = false
    @Published private(set) var verified = false
    @Published private(set) var message = "Verify your Bridge, then press its physical button when asked."
    @Published private(set) var paired = false
    private let defaults: UserDefaults
    private var pendingKey: String?
    private var verifiedEndpoint: String?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let args = CommandLine.arguments
        func value(_ name: String) -> String { guard let index = args.firstIndex(of: name), args.count > index + 1 else { return "" }; return args[index + 1] }
        host = value("--bridge-host"); bridgeID = value("--bridge-id")
        if host.isEmpty { host = defaults.string(forKey: "bridgeHost") ?? "" }
        if bridgeID.isEmpty { bridgeID = defaults.string(forKey: "bridgeID") ?? "" }
    }
    var hasSavedEndpoint: Bool { !host.isEmpty && !bridgeID.isEmpty }
    var setupCompleted: Bool { defaults.bool(forKey: "setupComplete-" + bridgeID) }
    func completeSetup() throws -> HueClient {
        guard paired, let key = try BridgeKeychain.load(bridgeID: bridgeID) else { throw HueError.approvalRequired }
        defaults.set(true, forKey: "setupComplete-" + bridgeID)
        return HueClient(configuration: .init(host: host, applicationKey: key), access: .control, trust: .init(host: host, bridgeID: bridgeID))
    }
    /// Restore never registers a new application if this Mac has no key.
    func restore() async -> (HomeSnapshot, HueClient)? {
        guard !busy, hasSavedEndpoint else { return nil }
        busy = true; defer { busy = false }
        do {
            guard let key = try BridgeKeychain.load(bridgeID: bridgeID) else { message = "This Mac needs its own pairing. Verify the Bridge, then press its button."; return nil }
            let client = HueClient(configuration: .init(host: host, applicationKey: key), access: .readOnly, trust: .init(host: host, bridgeID: bridgeID))
            do {
                let snapshot = HomeSnapshot.project(try await client.resources())
                paired = true; verified = true; verifiedEndpoint = endpoint
                defaults.set(host, forKey: "bridgeHost"); defaults.set(bridgeID, forKey: "bridgeID")
                message = "Connected. \(snapshot.scenes.count) scenes. Access is stored on this Mac."
                return (snapshot, client)
            } catch { client.close(); throw error }
        } catch { message = "Could not reconnect. Check Bridge address, Local Network permission, and Keychain access."; return nil }
    }
    func discover() async {
        guard !busy, !paired, pendingKey == nil else { return }
        busy = true; defer { busy = false }
        do {
            struct Bridge: Decodable { let id: String; let internalipaddress: String }
            var request = URLRequest(url: URL(string: "https://discovery.meethue.com/")!); request.timeoutInterval = 10
            let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HueError.malformedResponse }
            let bridges = try JSONDecoder().decode([Bridge].self, from: data)
            guard bridges.count == 1, let bridge = bridges.first else {
                message = bridges.isEmpty ? "No Bridge found. Enter its IP address and Bridge ID from your Hue app." : "Multiple Bridges found. Enter the address and ID of the one you want."
                return
            }
            host = bridge.internalipaddress; bridgeID = bridge.id.lowercased(); verified = false
            message = "Bridge found. Verify the secure connection next."
        } catch { message = "Discovery did not complete. You can enter the Bridge details manually." }
    }
    private var endpoint: String { host + "|" + bridgeID.lowercased() }
    var canPair: Bool { verified && verifiedEndpoint == endpoint && !busy && !paired }
    var hasPendingSave: Bool { pendingKey != nil }
    func verify() async {
        guard !busy, pendingKey == nil else { return }
        busy = true; verified = false; message = "Checking the secure connection…"
        defer { busy = false }
        do {
            try await HuePairingService(trust: .init(host: host, bridgeID: bridgeID)).verifyBridge()
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
            let saved = try BridgeKeychain.load(bridgeID: bridgeID)
            let key: String
            if let saved { key = saved }
            else {
                if pendingKey == nil { pendingKey = try await HuePairingService(trust: trust).pair() }
                guard let pendingKey else { throw PairingError.invalidResponse }
                try BridgeKeychain.save(pendingKey, bridgeID: bridgeID)
                key = pendingKey; self.pendingKey = nil
            }
            let client = HueClient(configuration: .init(host: host, applicationKey: key), access: .readOnly, trust: trust)
            do {
                let resources = try await client.resources()
                let snapshot = HomeSnapshot.project(resources)
                paired = true
                defaults.set(host, forKey: "bridgeHost"); defaults.set(bridgeID, forKey: "bridgeID")
                message = "Connected. \(snapshot.scenes.count) scenes across \(snapshot.groups.count) rooms and zones. Access saved in Keychain."
                return (snapshot, client)
            } catch { client.close(); message = "Access is saved in Keychain. The scene inventory could not load; retry to reconnect without pairing again."; return nil }
        } catch let error as PairingError { message = error.localizedDescription }
        catch { message = "Connection failed. No light changes were requested. Verify network access, then try again." }
        return nil
    }
}
