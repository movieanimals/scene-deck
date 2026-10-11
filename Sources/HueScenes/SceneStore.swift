import SwiftUI
import HueCore
import Combine

@MainActor final class SceneStore: ObservableObject {
    static func sceneCountLabel(_ count: Int) -> String { "\(count) \(count == 1 ? "scene" : "scenes")" }
    @Published var home = DemoHome.make()
    @Published var selection = "all" { didSet { if isLive && !activeBridgeID.isEmpty { defaults.set(selection, forKey: "selectedView-" + activeBridgeID) } } }
    @Published var search = ""
    @Published var favorites: Set<String>
    @Published var notice = "Demo home ready. Choose a scene to try it."
    @Published var showConnection = false
    @Published var showSceneEditor = false
    @Published var editorSceneID: String?
    @Published var editorDuplicate = false
    @Published private(set) var recentIDs: [String] = []
    var favoriteScenes: [LightScene] { home.scenes.filter { favorites.contains($0.id) }.sorted { $0.id < $1.id } }
    var recentScenes: [LightScene] { recentIDs.compactMap { id in home.scenes.first { $0.id == id } } }
    private var recentKey: String { isLive ? "recentSceneIDs-" + activeBridgeID : "demoRecentSceneIDs" }
    private func recordRecall(_ id: String) {
        recentIDs = Array(([id] + recentIDs.filter { $0 != id }).prefix(20))
        defaults.set(recentIDs, forKey: recentKey)
    }
    func edit(_ scene: LightScene? = nil, duplicate: Bool = false) {
        editorSceneID = scene?.id; editorDuplicate = duplicate; showSceneEditor = true
    }
    @Published private(set) var activeBridgeID = ""
    @Published private(set) var pausedAfterSleep = false
    @Published private(set) var refreshing = false
    @Published private(set) var bridgeUnavailable = false
    @Published private(set) var bridgeAuthorizationRequired = false
    @Published private(set) var lastUpdated: Date?
    private var foregroundSubscription: AnyCancellable?
    var canRefresh: Bool { isLive && !pausedAfterSleep && !bridgeAuthorizationRequired && !refreshing }
    func refreshScenes() {
        guard isLive, !pausedAfterSleep else { return }
        synchronizer?.refresh()
    }
    func refreshOnForeground() {
        guard isLive, !pausedAfterSleep else { return }
        synchronizer?.refreshOnForeground()
    }
    func applySnapshot(_ snapshot: HomeSnapshot) {
        home = snapshot
        if !["all", "favorites", "recent"].contains(selection), !snapshot.groups.contains(where: { $0.id == selection }) { selection = "all" }
    }
    private var sleepSubscription: AnyCancellable?
    private var readClient: HueClient?
    private var sessionGeneration = 0
    private var favoriteKey: String { "bridgeFavoriteIDs-" + activeBridgeID }
    @Published var simulatedOffline = false
    let connection: BridgeConnection
    @Published private(set) var controlsEnabled = false
    @Published private(set) var sending = false
    private var controlClient: HueClient?
    private var liveRecall: ((String) async throws -> Void)?
    private var liveBrightness: ((String, Double) async throws -> Void)?
    private var livePower: ((String, Bool) async throws -> Void)?
    private var liveFetch: (() async throws -> [HueResource])?
    private var commandTask: Task<Void, Never>?
    var controlsDisabled: Bool { simulatedOffline || sending || pausedAfterSleep || (isLive && !controlsEnabled) }
    @Published private(set) var isLive = false
    private var synchronizer: BridgeSynchronizer?
    private var subscriptions: Set<AnyCancellable> = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard, connectionServices: BridgeConnection.Services = .init()) {
        self.defaults = defaults
        connection = BridgeConnection(defaults: defaults, services: connectionServices)
        showConnection = CommandLine.arguments.contains("--setup") || ((!connection.hasSavedEndpoint || connection.requiresExplicitReconnect) && !CommandLine.arguments.contains("--demo"))
        pausedAfterSleep = !CommandLine.arguments.contains("--demo") && defaults.bool(forKey: "pausedAfterSleep-" + connection.bridgeID)
        favorites = Set(defaults.stringArray(forKey: "demoFavoriteIDs") ?? ["living-0", "living-2", "bedroom-1", "studio-4"])
        recentIDs = defaults.stringArray(forKey: "demoRecentSceneIDs") ?? []
        sleepSubscription = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in Task { @MainActor in self?.pauseForSleep() } }
        foregroundSubscription = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in Task { @MainActor in self?.refreshOnForeground() } }
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
        else if !CommandLine.arguments.contains("--demo") && connection.hasSavedEndpoint && !connection.requiresExplicitReconnect && !pausedAfterSleep && (connection.setupCompleted || CommandLine.arguments.contains("--connect-saved")) {
            Task { [weak self] in await self?.restoreConnection() }
        }
    }
    func pauseForSleep() {
        guard isLive || !CommandLine.arguments.contains("--demo") else { return }
        guard isLive || connection.hasSavedEndpoint else { return }
        sessionGeneration += 1; pausedAfterSleep = true
        defaults.set(true, forKey: "pausedAfterSleep-" + connection.bridgeID)
        commandTask?.cancel(); sending = false; synchronizer?.pauseForSleep(); connection.pauseForSleep()
        // Invalidate the session too: editor POST/PUT work must never resume after wake.
        controlClient?.close(); controlClient = nil; readClient?.close(); readClient = nil
        liveRecall = nil; liveBrightness = nil; livePower = nil; liveFetch = nil; controlsEnabled = false
        notice = "Paused after sleep · Choose Reconnect when ready"
    }
    func restoreConnection() async {
        let generation = sessionGeneration
        if let (snapshot, client) = await connection.restore() {
            guard generation == sessionGeneration else { client.close(); return }
            pausedAfterSleep = false
            connect(snapshot: snapshot, client: client)
            if connection.setupCompleted { finishSetup() }
        } else { notice = connection.message; showConnection = true }
    }
    func finishSetup() {
        guard !pausedAfterSleep else { notice = "Reconnect explicitly before enabling controls."; return }
        do {
            let client = try connection.completeSetup()
            controlClient = client
            enableControls(recall: { try await client.recall($0) }, brightness: { try await client.brightness($0, value: $1) }, power: { try await client.power($0, on: $1) }, fetch: nil)
            showConnection = false
        } catch { notice = "Could not enable controls. Check this Mac’s Keychain access and reconnect." }
    }
    // In-memory closures also allow verification without touching real lights.
    func enableControls(recall: @escaping (String) async throws -> Void, brightness: @escaping (String, Double) async throws -> Void, power: ((String, Bool) async throws -> Void)? = nil, fetch: (() async throws -> [HueResource])?) {
        guard isLive else { return }
        liveRecall = recall; liveBrightness = brightness; livePower = power; liveFetch = fetch
        controlsEnabled = true; notice = "Ready · Choose a scene to change your lights"
    }
    private func sendCommand(_ label: String, recalledSceneID: String? = nil, operation: @escaping () async throws -> Void) {
        guard controlsEnabled, !sending, !pausedAfterSleep else { return }
        let generation = sessionGeneration
        sending = true; notice = "Sending \(label)…"
        commandTask = Task { [weak self] in
            defer { if self?.sessionGeneration == generation { self?.sending = false } }
            do {
                try await operation()
                guard !Task.isCancelled, self?.sessionGeneration == generation, self?.pausedAfterSleep == false else { return }
                if let id = recalledSceneID { self?.recordRecall(id) }
                do {
                    if let fetch = self?.liveFetch {
                        let snapshot = HomeSnapshot.project(try await fetch())
                        guard !Task.isCancelled, self?.sessionGeneration == generation, self?.pausedAfterSleep == false else { return }
                        self?.applySnapshot(snapshot)
                    }
                    else { self?.synchronizer?.refresh() }
                    self?.notice = "\(label) · Bridge confirmed"
                } catch { self?.notice = "Command sent. State refresh failed; waiting for the Bridge." }
            } catch { if self?.sessionGeneration == generation { self?.notice = "The Bridge did not confirm the command. Check the connection and try again." } }
        }
    }
    var title: String { selection == "recent" ? "Recently played" : selection == "favorites" ? "Your favorites" : home.groups.first { $0.id == selection }?.name ?? "Your scenes" }
    var groups: [SceneGroup] { home.groups.filter { (selection == "all" || selection == "favorites" || selection == "recent" || selection == $0.id) && !scenes(in: $0.id).isEmpty } }
    func scenes(in groupID: String) -> [LightScene] {
        (selection == "recent" ? recentScenes : home.scenes).filter { scene in
            let groupName = home.groups.first { $0.id == scene.groupID }?.name ?? ""
            return scene.groupID == groupID && (selection != "favorites" || favorites.contains(scene.id)) && (search.isEmpty || scene.name.localizedCaseInsensitiveContains(search) || groupName.localizedCaseInsensitiveContains(search))
        }
    }
    func activate(_ scene: LightScene) {
        if isLive {
            guard controlsEnabled, let recall = liveRecall, home.scenes.contains(where: { $0.id == scene.id }) else { return }
            sendCommand(scene.name, recalledSceneID: scene.id) { try await recall(scene.id) }; return
        }
        guard !simulatedOffline else { notice = "Demo Bridge is offline. Restore it from the toolbar to try again."; return }
        do { try home.recall(scene.id); recordRecall(scene.id); notice = "\(scene.name) · \(home.groups.first { $0.id == scene.groupID }?.name ?? "Room") · Demo" }
        catch { notice = error.localizedDescription }
    }
    func favorite(_ scene: LightScene) {
        if favorites.contains(scene.id) { favorites.remove(scene.id) } else { favorites.insert(scene.id) }
        defaults.set(favorites.sorted(), forKey: isLive ? favoriteKey : "demoFavoriteIDs")
    }
    func brightness(_ group: SceneGroup, _ value: Double) {
        if isLive {
            guard controlsEnabled, value.isFinite, (0...100).contains(value), let current = home.groups.first(where: { $0.id == group.id }), current.brightness != nil, let id = current.serviceID, let brightness = liveBrightness else { return }
            sendCommand("\(group.name) brightness") { try await brightness(id, value) }; return
        }
        guard !simulatedOffline else { return }
        home.setBrightness(groupID: group.id, value: value)
        notice = "\(group.name) brightness · \(Int(value))% · Demo"
    }
    func power(_ group: SceneGroup) {
        if isLive {
            guard controlsEnabled, let current = home.groups.first(where: { $0.id == group.id }), let on = current.isOn, let id = current.serviceID, let power = livePower else { return }
            sendCommand("\(current.name) \(on ? "off" : "on")") { try await power(id, !on) }; return
        }
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
        guard !pausedAfterSleep else { client.close(); return }
        sessionGeneration += 1; commandTask?.cancel(); sending = false
        subscriptions.removeAll(); synchronizer?.stop(); controlsEnabled = false
        controlClient?.close(); controlClient = nil; liveRecall = nil; liveBrightness = nil; livePower = nil; liveFetch = nil
        readClient = client; activeBridgeID = connection.bridgeID
        let savedSelection = defaults.string(forKey: "selectedView-" + activeBridgeID) ?? "all"
        pausedAfterSleep = false; defaults.set(false, forKey: "pausedAfterSleep-" + activeBridgeID)
        isLive = true; simulatedOffline = false; home = snapshot; selection = (["all", "favorites", "recent"].contains(savedSelection) || snapshot.groups.contains { $0.id == savedSelection }) ? savedSelection : "all"; search = ""
        if defaults.object(forKey: favoriteKey) == nil, defaults.string(forKey: "bridgeID") == activeBridgeID, let legacy = defaults.stringArray(forKey: "bridgeFavoriteIDs") {
            defaults.set(legacy, forKey: favoriteKey); defaults.removeObject(forKey: "bridgeFavoriteIDs")
        }
        favorites = Set(defaults.stringArray(forKey: favoriteKey) ?? [])
        recentIDs = defaults.stringArray(forKey: recentKey) ?? []
        notice = "Bridge connected · Read-only scene inventory · No lights changed"
        let generation = sessionGeneration
        let sync = BridgeSynchronizer(client: client, bridgeID: activeBridgeID, host: connection.host, addressChanged: { [weak self] address in
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation, !self.pausedAfterSleep else { return }
                self.connection.updateVerifiedAddress(address)
                // Recreate control client at the verified address; do not issue any lighting request.
                if self.controlsEnabled, let old = self.controlClient {
                    let moved = old.relocatedCopy(host: address, bridgeID: self.activeBridgeID)
                    self.controlClient = moved; old.close()
                    self.enableControls(recall: { try await moved.recall($0) }, brightness: { try await moved.brightness($0, value: $1) }, power: { try await moved.power($0, on: $1) }, fetch: nil)
                }
            }
        })
        synchronizer = sync
        sync.$snapshot.compactMap { $0 }.sink { [weak self] in self?.applySnapshot($0) }.store(in: &subscriptions)
        sync.$refreshing.sink { [weak self] in self?.refreshing = $0 }.store(in: &subscriptions)
        sync.$unavailable.sink { [weak self] in self?.bridgeUnavailable = $0 }.store(in: &subscriptions)
        sync.$lastUpdated.sink { [weak self] in self?.lastUpdated = $0 }.store(in: &subscriptions)
        sync.$status.sink { [weak self] in self?.notice = "Bridge · \($0)" }.store(in: &subscriptions)
        sync.$authorizationRequired.sink { [weak self] required in
            self?.bridgeAuthorizationRequired = required
            guard required else { return }
            self?.commandTask?.cancel(); self?.controlClient?.close(); self?.controlClient = nil
            self?.liveRecall = nil; self?.liveBrightness = nil; self?.livePower = nil; self?.controlsEnabled = false
        }.store(in: &subscriptions)
        sync.start()
        NotificationCenter.default.post(name: Notification.Name("SceneDeckInventoryReady"), object: nil)
    }
    func saveSceneFile(_ document: PortableScene, groupID: String, mapping: [String: String], replacing sceneID: String?, expectedBridgeID: String, original: SceneEditSnapshot?, confirmed: Bool) async throws {
        guard confirmed, controlsEnabled, !pausedAfterSleep, !sending, expectedBridgeID == activeBridgeID, let client = controlClient else { throw HueError.approvalRequired }
        let generation = sessionGeneration
        sending = true; defer { if generation == sessionGeneration { sending = false } }
        let fresh = SceneCatalog(try await client.resources())
        guard !Task.isCancelled, generation == sessionGeneration, !pausedAfterSleep else { throw HueError.approvalRequired }
        let plan = try fresh.plan(document, groupID: groupID, mapping: mapping, replacing: sceneID, original: original)
        do { _ = try await client.saveScene(plan) }
        catch {
            if generation != sessionGeneration || pausedAfterSleep { throw SceneFileError.invalid("Save interrupted. After reconnecting, check whether the Bridge already saved this scene before trying again.") }
            throw error
        }
        guard generation == sessionGeneration, !pausedAfterSleep else { throw SceneFileError.invalid("Save interrupted. Reconnect and check the scene before trying again.") }
        synchronizer?.refresh(); notice = "Scene saved · Library refreshing"
    }
    func removeLocalAccess() {
        guard !sending else { return }
        do {
            try connection.removeLocalAccess()
            sessionGeneration += 1; commandTask?.cancel(); synchronizer?.stop(); synchronizer = nil; subscriptions.removeAll()
            controlClient?.close(); controlClient = nil; readClient?.close(); readClient = nil
            liveRecall = nil; liveBrightness = nil; livePower = nil; controlsEnabled = false; isLive = false
            refreshing = false; bridgeUnavailable = false; bridgeAuthorizationRequired = false; lastUpdated = nil
            home = DemoHome.make(); favorites = Set(defaults.stringArray(forKey: "demoFavoriteIDs") ?? [])
            recentIDs = defaults.stringArray(forKey: "demoRecentSceneIDs") ?? []
            notice = connection.message; showConnection = true
        } catch { notice = "Could not remove local access. Nothing was changed on the Bridge." }
    }
    func disconnectForSwitch() {
        guard !sending, connection.disconnectForSwitch() else { return }
        sessionGeneration += 1; commandTask?.cancel(); commandTask = nil
        subscriptions.removeAll(); synchronizer?.stop(); synchronizer = nil
        controlClient?.close(); controlClient = nil; readClient?.close(); readClient = nil
        liveRecall = nil; liveBrightness = nil; livePower = nil; liveFetch = nil; controlsEnabled = false
        isLive = false; activeBridgeID = ""; pausedAfterSleep = false
        refreshing = false; bridgeUnavailable = false; bridgeAuthorizationRequired = false; lastUpdated = nil
        home = DemoHome.make(); selection = "all"; search = ""; simulatedOffline = false
        favorites = Set(defaults.stringArray(forKey: "demoFavoriteIDs") ?? [])
        recentIDs = defaults.stringArray(forKey: "demoRecentSceneIDs") ?? []
        showSceneEditor = false; showConnection = true; notice = connection.message
    }
    func reset() { guard !isLive else { return }; home = DemoHome.make(); simulatedOffline = false; notice = "Demo home reset. Favorites kept." }
}

