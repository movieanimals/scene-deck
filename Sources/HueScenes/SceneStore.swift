import SwiftUI
import HueCore
import Combine

@MainActor final class SceneStore: ObservableObject {
    @Published var home = DemoHome.make()
    @Published var selection = "all"
    @Published var search = ""
    @Published var favorites: Set<String>
    @Published var notice = "Demo home ready. Choose a scene to try it."
    @Published var showConnection = false
    @Published var simulatedOffline = false
    let connection: BridgeConnection
    @Published private(set) var controlsEnabled = false
    @Published private(set) var sending = false
    private var controlClient: HueClient?
    private var liveRecall: ((String) async throws -> Void)?
    private var liveBrightness: ((String, Double) async throws -> Void)?
    private var liveFetch: (() async throws -> [HueResource])?
    private var commandTask: Task<Void, Never>?
    var controlsDisabled: Bool { simulatedOffline || sending || (isLive && !controlsEnabled) }
    @Published private(set) var isLive = false
    private var synchronizer: BridgeSynchronizer?
    private var subscriptions: Set<AnyCancellable> = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        connection = BridgeConnection(defaults: defaults)
        showConnection = CommandLine.arguments.contains("--setup")
        favorites = Set(defaults.stringArray(forKey: "demoFavoriteIDs") ?? ["living-0", "living-2", "bedroom-1", "studio-4"])
        // Explicit command-line equivalent of the approved Verify + Pair buttons.
        // Never used by normal launch; reports only non-secret outcome text.
        if CommandLine.arguments.contains("--pair-after-button") {
            showConnection = true
            Task { [weak self] in
                guard let self else { return }
                await self.connection.verify()
                if self.connection.canPair, let (snapshot, client) = await self.connection.pairAndRead() {
                    self.connect(snapshot: snapshot, client: client)
                }
                if let index = CommandLine.arguments.firstIndex(of: "--pair-status-file"), CommandLine.arguments.count > index + 1 {
                    let summary = self.connection.message + "\nPaired: \(self.connection.paired)\n"
                    try? summary.write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
                }
            }
        }
        else if connection.hasSavedEndpoint && (connection.setupCompleted || CommandLine.arguments.contains("--connect-saved")) {
            Task { [weak self] in await self?.restoreConnection() }
        }
    }
    func restoreConnection() async {
        if let (snapshot, client) = await connection.restore() {
            connect(snapshot: snapshot, client: client)
            if connection.setupCompleted { finishSetup() }
        } else { notice = connection.message; showConnection = true }
    }
    func finishSetup() {
        do {
            let client = try connection.completeSetup()
            controlClient = client
            enableControls(recall: { try await client.recall($0) }, brightness: { try await client.brightness($0, value: $1) }, fetch: nil)
            showConnection = false
        } catch { notice = "Could not enable controls. Check this Mac’s Keychain access and reconnect." }
    }
    // In-memory closures also allow verification without touching real lights.
    func enableControls(recall: @escaping (String) async throws -> Void, brightness: @escaping (String, Double) async throws -> Void, fetch: (() async throws -> [HueResource])?) {
        guard isLive else { return }
        liveRecall = recall; liveBrightness = brightness; liveFetch = fetch
        controlsEnabled = true; notice = "Ready · Choose a scene to change your lights"
    }
    private func sendCommand(_ label: String, operation: @escaping () async throws -> Void) {
        guard controlsEnabled, !sending else { return }
        sending = true; notice = "Sending \(label)…"
        commandTask = Task { [weak self] in
            defer { self?.sending = false }
            do {
                try await operation()
                do {
                    if let fetch = self?.liveFetch { self?.home = HomeSnapshot.project(try await fetch()) }
                    else { self?.synchronizer?.start() }
                    self?.notice = "\(label) · Bridge confirmed"
                } catch { self?.notice = "Command sent. State refresh failed; waiting for the Bridge." }
            } catch { self?.notice = "The Bridge did not confirm the command. Check the connection and try again." }
        }
    }
    var title: String { selection == "favorites" ? "Your favorites" : home.groups.first { $0.id == selection }?.name ?? "Your scenes" }
    var groups: [SceneGroup] { home.groups.filter { (selection == "all" || selection == "favorites" || selection == $0.id) && !scenes(in: $0.id).isEmpty } }
    func scenes(in groupID: String) -> [LightScene] {
        home.scenes.filter { scene in
            let groupName = home.groups.first { $0.id == scene.groupID }?.name ?? ""
            return scene.groupID == groupID && (selection != "favorites" || favorites.contains(scene.id)) && (search.isEmpty || scene.name.localizedCaseInsensitiveContains(search) || groupName.localizedCaseInsensitiveContains(search))
        }
    }
    func activate(_ scene: LightScene) {
        if isLive {
            guard controlsEnabled, let recall = liveRecall, home.scenes.contains(where: { $0.id == scene.id }) else { return }
            sendCommand(scene.name) { try await recall(scene.id) }; return
        }
        guard !simulatedOffline else { notice = "Demo Bridge is offline. Restore it from the toolbar to try again."; return }
        do { try home.recall(scene.id); notice = "\(scene.name) · \(home.groups.first { $0.id == scene.groupID }?.name ?? "Room") · Demo" }
        catch { notice = error.localizedDescription }
    }
    func favorite(_ scene: LightScene) {
        if favorites.contains(scene.id) { favorites.remove(scene.id) } else { favorites.insert(scene.id) }
        defaults.set(favorites.sorted(), forKey: isLive ? "bridgeFavoriteIDs" : "demoFavoriteIDs")
    }
    func brightness(_ group: SceneGroup, _ value: Double) {
        if isLive {
            guard controlsEnabled, value.isFinite, (0...100).contains(value), let id = group.serviceID, let brightness = liveBrightness else { return }
            sendCommand("\(group.name) brightness") { try await brightness(id, value) }; return
        }
        guard !simulatedOffline else { return }
        home.setBrightness(groupID: group.id, value: value)
        notice = "\(group.name) brightness · \(Int(value))% · Demo"
    }
    func power(_ group: SceneGroup) {
        guard !isLive else { return }
        guard !simulatedOffline else { return }
        home.togglePower(groupID: group.id)
        notice = "\(group.name) · Demo power changed"
    }
    func simulateExternalChange() {
        guard !isLive else { return }
        guard !simulatedOffline, let scene = home.scenes.first(where: { $0.id == "living-2" }) else { return }
        try? home.recall(scene.id)
        notice = "Simulated Bridge event · Living room updated to Blue hour"
    }
    func connect(snapshot: HomeSnapshot, client: HueClient) {
        subscriptions.removeAll(); synchronizer?.stop(); controlsEnabled = false
        isLive = true; simulatedOffline = false; home = snapshot; selection = "all"; search = ""
        favorites = Set(defaults.stringArray(forKey: "bridgeFavoriteIDs") ?? [])
        notice = "Bridge connected · Read-only scene inventory · No lights changed"
        let sync = BridgeSynchronizer(client: client)
        synchronizer = sync
        sync.$snapshot.compactMap { $0 }.sink { [weak self] in self?.home = $0 }.store(in: &subscriptions)
        sync.$status.sink { [weak self] in self?.notice = "Bridge · \($0)" }.store(in: &subscriptions)
        sync.start()
        NotificationCenter.default.post(name: Notification.Name("SceneDeckInventoryReady"), object: nil)
    }
    func reset() { guard !isLive else { return }; home = DemoHome.make(); simulatedOffline = false; notice = "Demo home reset. Favorites kept." }
}

