import Foundation
import SwiftUI
import HueCore

@main struct StoreChecks {
    @MainActor static func main() async throws {
        let suite = "SceneDeckVerification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SceneStore(defaults: defaults)
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            count += 1; print("PASS: \(name)")
        }
        check(store.favorites.count == 4, "Initial demo favorites")
        let scene = store.home.scenes[0]
        store.favorite(scene)
        check(!store.favorites.contains(scene.id), "Favorite toggles off")
        let restored = SceneStore(defaults: defaults)
        check(!restored.favorites.contains(scene.id), "Favorites survive new store instance")
        store.favorite(scene)
        store.selection = "favorites"
        check(store.groups.count == 3, "Favorites grouped by room")
        store.selection = "living"
        check(store.groups.map(\.id) == ["living"], "Room filter")
        store.selection = "all"; store.search = "BLUE HOUR"
        check(store.groups.count == 4 && store.scenes(in: "living").count == 1, "Case insensitive search")
        check(SceneStore.sceneCountLabel(store.scenes(in: "living").count) == "1 scene", "Single filtered scene uses singular count")
        check(SceneStore.sceneCountLabel(0) == "0 scenes" && SceneStore.sceneCountLabel(2) == "2 scenes", "Zero and multiple scene counts use plural")
        store.search = "no such scene"
        check(store.groups.isEmpty, "Search empty state")
        store.search = "Studio"
        check(store.groups.map(\.id) == ["studio"], "Room name search")
        store.search = ""; store.simulatedOffline = true
        let before = store.home.groups
        store.activate(store.home.scenes[2])
        check(store.home.groups == before, "Offline scene action cannot change state")
        store.simulatedOffline = false
        store.simulateExternalChange()
        check(store.home.groups[0].activeSceneID == "living-2", "Simulated external event updates shared state")
        store.reset()
        check(store.home.groups[0].activeSceneID == "living-0", "Reset restores demo rooms")
        check(store.favorites.contains(scene.id), "Reset preserves favorites")
        store.activate(store.home.scenes[1]); store.activate(store.home.scenes[2]); store.activate(store.home.scenes[1])
        check(store.recentIDs == ["living-1", "living-2"], "Recent recalls are deduplicated newest first")
        let recentRestored = SceneStore(defaults: defaults)
        check(recentRestored.recentIDs == store.recentIDs, "Recent recalls persist locally")
        store.selection = "recent"
        check(store.scenes(in: "living").map(\.id) == ["living-1", "living-2"], "Recent filter retains recency within rooms")
        store.selection = "all"
        var fetchCount = 0
        var callback: (() async -> Void)?
        var releaseFetch: CheckedContinuation<Void, Never>?
        var closed = false
        var sync: BridgeSynchronizer? = BridgeSynchronizer(fetch: {
            fetchCount += 1
            if fetchCount == 2 { await withCheckedContinuation { releaseFetch = $0 } }
            return []
        }, events: { callback = $0; try await Task.sleep(nanoseconds: 60_000_000_000) }, close: { closed = true }, minimumFetchInterval: 0)
        weak var weakSync = sync
        sync?.start()
        for _ in 0..<100 where callback == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        check(callback != nil, "Synchronizer starts event listener")
        await callback?()
        for _ in 0..<100 where releaseFetch == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        check(fetchCount == 2, "Event starts authoritative refresh")
        await callback?()
        releaseFetch?.resume(); releaseFetch = nil
        for _ in 0..<100 where fetchCount < 3 { try await Task.sleep(nanoseconds: 10_000_000) }
        check(fetchCount == 3, "Event during fetch triggers trailing refresh")
        sync = nil
        check(weakSync == nil && closed, "Listening task does not retain synchronizer owner")
        let noNetworkClient = HueClient(configuration: .init(host: "unit-test.invalid", applicationKey: "synthetic"), access: .blocked)
        store.connect(snapshot: DemoHome.make(), client: noNetworkClient)
        let liveBefore = store.home.groups
        store.activate(store.home.scenes[3]); store.brightness(store.home.groups[0], 1); store.power(store.home.groups[0]); store.reset(); store.simulateExternalChange()
        check(store.home.groups == liveBefore, "Read-only live store blocks every demo/light mutation")
        check(store.isLive, "Connected inventory is visibly marked live")
        var recalls: [String] = []
        var levels: [(String, Double)] = []
        store.enableControls(recall: { recalls.append($0) }, brightness: { levels.append(($0, $1)) }, fetch: { [] })
        check(recalls.isEmpty && levels.isEmpty && store.controlsEnabled, "Enabling controls sends no command")
        let chosen = store.home.scenes[0]
        let chosenGroup = store.home.groups[0]
        store.activate(chosen)
        for _ in 0..<100 where store.sending { try await Task.sleep(nanoseconds: 1_000_000) }
        check(recalls == [chosen.id], "Explicit scene action sends only selected scene ID")
        check(store.home.scenes.isEmpty, "Command state comes from authoritative refresh")
        store.home = DemoHome.make()
        store.brightness(chosenGroup, 44)
        for _ in 0..<100 where store.sending { try await Task.sleep(nanoseconds: 1_000_000) }
        check(levels.count == 1 && levels[0].0 == chosenGroup.serviceID && levels[0].1 == 44, "Brightness targets grouped-light service")
        store.brightness(chosenGroup, .nan)
        check(levels.count == 1, "Invalid live brightness sends no request")
        store.home = DemoHome.make()
        var powerCommands: [(String, Bool)] = []
        store.enableControls(recall: { _ in }, brightness: { _, _ in }, power: { powerCommands.append(($0, $1)) }, fetch: { [] })
        store.power(chosenGroup)
        for _ in 0..<100 where store.sending { try await Task.sleep(nanoseconds: 1_000_000) }
        check(powerCommands.count == 1 && powerCommands[0].0 == chosenGroup.serviceID && powerCommands[0].1 == false, "Live power uses selected grouped-light service")
        check(store.home.groups.isEmpty, "Power state is fetched instead of guessed")
        store.power(chosenGroup); store.brightness(chosenGroup, 44)
        check(powerCommands.count == 1 && levels.count == 1, "Stale group targets cannot send commands")
        store.home = DemoHome.make()
        let recentBeforeFailure = store.recentIDs
        store.enableControls(recall: { _ in throw HueError.http(503) }, brightness: { _, _ in throw HueError.http(503) }, fetch: { [] })
        store.activate(store.home.scenes[3])
        for _ in 0..<100 where store.sending { try await Task.sleep(nanoseconds: 1_000_000) }
        check(store.notice.contains("did not confirm") && !store.sending, "Failed commands release controls and report failure")
        check(store.recentIDs == recentBeforeFailure, "Failed recall does not appear in recent scenes")
        var pendingReads: [CheckedContinuation<[HueResource], Error>] = []
        let coordinated = BridgeSynchronizer(fetch: { try await withCheckedThrowingContinuation { pendingReads.append($0) } }, events: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }, close: {}, minimumFetchInterval: 0)
        coordinated.start()
        for _ in 0..<100 where pendingReads.count < 1 { try await Task.sleep(nanoseconds: 1_000_000) }
        coordinated.start() // production command completion restarts this one authority
        for _ in 0..<100 where pendingReads.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        check(pendingReads.count == 2, "Post-command refresh supersedes earlier read")
        pendingReads[1].resume(returning: [])
        let stale = try HueClient.decode(Data(#"{"errors":[],"data":[{"id":"stale-room","type":"room"}]}"#.utf8), status: 200).data
        pendingReads[0].resume(returning: stale)
        try await Task.sleep(nanoseconds: 10_000_000)
        check(coordinated.snapshot?.groups.isEmpty == true, "Late pre-command response cannot replace newer snapshot")
        coordinated.stop()
        var revokedFetches = 0
        var revokedCallback: (() async -> Void)?
        var revokedClosed = false
        let revoked = BridgeSynchronizer(fetch: {
            revokedFetches += 1
            if revokedFetches > 1 { throw HueError.http(403) }
            return []
        }, events: { revokedCallback = $0; try await Task.sleep(nanoseconds: 60_000_000_000) }, close: { revokedClosed = true }, minimumFetchInterval: 0)
        revoked.start()
        for _ in 0..<100 where revokedCallback == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        await revokedCallback?()
        for _ in 0..<100 where !revoked.authorizationRequired { try await Task.sleep(nanoseconds: 10_000_000) }
        check(revoked.authorizationRequired && revokedClosed, "Revoked access during event refresh closes listener and requires recovery")
        revoked.start(); await revokedCallback?()
        try await Task.sleep(nanoseconds: 300_000_000)
        check(revokedFetches == 2, "Revocation blocks later callbacks and automatic restart")
        var sleepingFetches = 0
        var sleepingClosed = false
        let sleeping = BridgeSynchronizer(fetch: { sleepingFetches += 1; throw HueError.http(503) }, events: { _ in }, close: { sleepingClosed = true })
        sleeping.start()
        for _ in 0..<100 where sleepingFetches == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        sleeping.pauseForSleep(); sleeping.start()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        check(sleeping.paused && sleepingClosed && sleepingFetches == 1, "Sleep closes read transport and cancels retry without automatic wake restart")
        store.connection.bridgeID = "synthetic-household-a"
        store.connection.host = "unit-test.invalid"
        store.connect(snapshot: DemoHome.make(), client: noNetworkClient)
        store.selection = "bedroom"; store.favorite(store.home.scenes[0])
        let householdAFavorites = store.favorites
        store.connection.bridgeID = "synthetic-household-b"
        store.connect(snapshot: DemoHome.make(), client: noNetworkClient)
        check(store.favorites.isEmpty && store.selection == "all", "Another household receives separate favorites and view")
        store.selection = "studio"
        store.connection.bridgeID = "synthetic-household-a"
        store.connect(snapshot: DemoHome.make(), client: noNetworkClient)
        check(store.favorites == householdAFavorites && store.selection == "bedroom", "Returning household restores its own preferences")
        store.enableControls(recall: { recalls.append($0) }, brightness: { levels.append(($0, $1)) }, fetch: { [] })
        store.pauseForSleep()
        let commandCount = recalls.count + levels.count
        store.activate(store.home.scenes[0]); store.brightness(store.home.groups[0], 80)
        check(store.pausedAfterSleep && !store.controlsEnabled && store.controlsDisabled && recalls.count + levels.count == commandCount, "Sleep disables all commands until a fresh connection is ready")
        defaults.set(store.connection.bridgeID, forKey: "bridgeID"); defaults.set(store.connection.host, forKey: "bridgeHost")
        defaults.set(true, forKey: "setupComplete-" + store.connection.bridgeID)
        let afterSleep = SceneStore(defaults: defaults, connectionServices: .init(loadKeySilently: { _ in nil }))
        check(afterSleep.pausedAfterSleep && !afterSleep.isLive && !afterSleep.connection.busy, "Relaunch starts with controls paused pending saved-access recovery")
        print("\(count) store checks passed. No network requests made.")
    }
}
