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
        var fetchCount = 0
        var callback: (() async -> Void)?
        var releaseFetch: CheckedContinuation<Void, Never>?
        var closed = false
        var sync: BridgeSynchronizer? = BridgeSynchronizer(fetch: {
            fetchCount += 1
            if fetchCount == 2 { await withCheckedContinuation { releaseFetch = $0 } }
            return []
        }, events: { callback = $0; try await Task.sleep(nanoseconds: 60_000_000_000) }, close: { closed = true })
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
        store.brightness(chosenGroup, 44)
        for _ in 0..<100 where store.sending { try await Task.sleep(nanoseconds: 1_000_000) }
        check(levels.count == 1 && levels[0].0 == chosenGroup.serviceID && levels[0].1 == 44, "Brightness targets grouped-light service")
        store.brightness(chosenGroup, .nan)
        check(levels.count == 1, "Invalid live brightness sends no request")
        store.enableControls(recall: { _ in throw HueError.http(503) }, brightness: { _, _ in throw HueError.http(503) }, fetch: { [] })
        store.brightness(chosenGroup, 30)
        for _ in 0..<100 where store.sending { try await Task.sleep(nanoseconds: 1_000_000) }
        check(store.notice.contains("did not confirm") && !store.sending, "Failed commands release controls and report failure")
        var pendingReads: [CheckedContinuation<[HueResource], Error>] = []
        let coordinated = BridgeSynchronizer(fetch: { try await withCheckedThrowingContinuation { pendingReads.append($0) } }, events: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }, close: {})
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
        print("\(count) store checks passed. No network requests made.")
    }
}
