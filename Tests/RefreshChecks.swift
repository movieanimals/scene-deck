import Foundation
import SwiftUI
@testable import HueCore

@main struct RefreshChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) { guard value else { fputs("FAIL: \(name)\n", stderr); exit(1) }; count += 1; print("PASS: \(name)") }
        func wait(_ condition: () -> Bool) async throws { for _ in 0..<300 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }; check(false, "Timed out waiting for synthetic refresh") }
        func resources(_ scenes: [(String,String)], room: Bool = true) throws -> [HueResource] {
            var rows: [[String:Any]] = room ? [["id":"room-a","type":"room","metadata":["name":"Study"],"services":[["rid":"group-a","rtype":"grouped_light"]]]] : []
            rows += scenes.map { ["id":$0.0,"type":"scene","metadata":["name":$0.1],"group":["rid":"room-a","rtype":"room"]] }
            return try JSONDecoder().decode([HueResource].self, from: JSONSerialization.data(withJSONObject: rows))
        }
        var fixture = try resources([("scene-a","Evening")])
        var calls = 0, concurrent = 0, maximumConcurrent = 0, listens = 0
        var callback: (() async -> Void)?
        var hold: CheckedContinuation<Void,Never>?
        var shouldHold = false, shouldFail = false
        let sync = BridgeSynchronizer(fetch: {
            calls += 1; concurrent += 1; maximumConcurrent = max(maximumConcurrent, concurrent)
            defer { concurrent -= 1 }
            if shouldHold { shouldHold = false; await withCheckedContinuation { hold = $0 } }
            if shouldFail { throw HueError.http(503) }
            return fixture
        }, events: { callback = $0; listens += 1; try await Task.sleep(nanoseconds: 60_000_000_000) }, close: {}, pollInterval: 0, minimumFetchInterval: 0, eventDebounce: 0, retryInterval: 0.03, foregroundInterval: 5)
        sync.start(); try await wait { callback != nil && sync.snapshot?.scenes.count == 1 }
        check(calls == 1 && sync.lastUpdated != nil, "Initial load fetches one authoritative inventory")
        fixture = try resources([("scene-a","Evening"),("scene-b","Harvest")])
        sync.refresh(); try await wait { sync.snapshot?.scenes.count == 2 }
        check(listens == 1, "Manual refresh adds scenes without reconnecting the event stream")
        fixture = try resources([("scene-b","Autumn glow")])
        await callback?(); try await wait { sync.snapshot?.scenes.first?.name == "Autumn glow" }
        check(sync.snapshot?.scenes.count == 1, "Event invalidation handles rename and deletion")
        shouldHold = true; sync.refresh(); try await wait { hold != nil }
        for _ in 0..<20 { await callback?(); sync.refresh() }
        let before = calls; hold?.resume(); hold = nil
        try await wait { !sync.refreshing && calls > before }
        check(maximumConcurrent == 1 && calls == before + 1, "Burst refreshes coalesce into one trailing read")
        shouldFail = true; sync.refresh(); try await wait { sync.unavailable }
        check(sync.snapshot?.scenes.first?.name == "Autumn glow", "Network failure preserves last inventory")
        shouldFail = false; fixture = try resources([])
        try await wait { !sync.unavailable && sync.snapshot?.scenes.isEmpty == true }
        check(sync.lastUpdated != nil, "Recovery distinguishes a successfully empty scene list")
        var now = Date(timeIntervalSince1970: 100)
        var foregroundReads = 0
        let foreground = BridgeSynchronizer(fetch: { foregroundReads += 1; return [] }, events: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }, close: {}, pollInterval: 0, minimumFetchInterval: 0, eventDebounce: 0, now: { now })
        foreground.start(); try await wait { foregroundReads == 1 && !foreground.refreshing }
        foreground.refreshOnForeground(); try await Task.sleep(nanoseconds: 20_000_000)
        check(foregroundReads == 1, "Immediate foreground notifications do not duplicate a fresh initial read")
        now = now.addingTimeInterval(6); foreground.refreshOnForeground(); try await wait { foregroundReads == 2 }
        check(foregroundReads == 2, "Returning to foreground refreshes older inventory")
        foreground.pauseForSleep(); now = now.addingTimeInterval(60); foreground.refresh(); foreground.refreshOnForeground()
        try await Task.sleep(nanoseconds: 20_000_000)
        check(foregroundReads == 2 && foreground.paused, "Foreground and manual refresh cannot reconnect a sleep-paused session")
        var polls = 0
        let polling = BridgeSynchronizer(fetch: { polls += 1; return [] }, events: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }, close: {}, pollInterval: 0.04, minimumFetchInterval: 0, eventDebounce: 0)
        polling.start(); try await wait { polls >= 2 }; polling.stop(); let pollCount = polls
        try await Task.sleep(nanoseconds: 100_000_000)
        check(polls == pollCount, "Fallback reconciliation stops with the connection")
        var restoredReads = 0, streamAttempts = 0
        let restoredStream = BridgeSynchronizer(fetch: {
            restoredReads += 1
            return try resources([("scene-a", restoredReads == 1 ? "Before interruption" : "After restoration")])
        }, events: { _ in
            streamAttempts += 1
            if streamAttempts > 1 { try await Task.sleep(nanoseconds: 60_000_000_000) }
        }, close: {}, pollInterval: 0, minimumFetchInterval: 0, eventDebounce: 0)
        restoredStream.start(); try await wait { streamAttempts == 2 }
        check(restoredReads == 2 && restoredStream.snapshot?.scenes.first?.name == "After restoration", "Event connection restoration reloads changes missed while disconnected")
        restoredStream.stop()
        var timedReads: [Date] = []
        let limited = BridgeSynchronizer(fetch: { timedReads.append(Date()); return [] }, events: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }, close: {}, pollInterval: 0, minimumFetchInterval: 0.08, eventDebounce: 0)
        limited.start(); try await wait { timedReads.count == 1 && !limited.refreshing }
        limited.refresh(); try await wait { timedReads.count == 2 }
        check(timedReads[1].timeIntervalSince(timedReads[0]) >= 0.075, "Minimum interval bounds repeated resource reads")
        limited.stop()
        var lateRead: CheckedContinuation<[HueResource],Error>?
        let late = BridgeSynchronizer(fetch: { try await withCheckedThrowingContinuation { lateRead = $0 } }, events: { _ in }, close: {}, pollInterval: 0)
        late.start(); try await wait { lateRead != nil }; late.pauseForSleep()
        lateRead?.resume(returning: try resources([("late-scene","Too late")]))
        try await Task.sleep(nanoseconds: 20_000_000)
        check(late.snapshot == nil && !late.refreshing, "Late read after sleep cannot publish or resume work")
        let suite = "SceneDeckRefresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SceneStore(defaults: defaults)
        store.connection.bridgeID = "synthetic-household"
        store.connect(snapshot: HomeSnapshot.project(try resources([("scene-a","Evening")])), client: HueClient(configuration: .init(host:"unit-test.invalid",applicationKey:"synthetic"), access:.blocked))
        store.selection = "room-a"; store.favorite(store.home.scenes[0])
        store.applySnapshot(HomeSnapshot.project(try resources([("scene-a","Renamed")])) )
        check(store.favoriteScenes.first?.name == "Renamed" && store.selection == "room-a", "Refresh preserves favorite identity and valid room selection")
        store.applySnapshot(HomeSnapshot.project(try resources([], room: false)))
        check(store.selection == "all" && store.favoriteScenes.isEmpty && store.favorites.contains("scene-a"), "Removed group resets selection; missing favorite is hidden without deleting saved preferences")
        let denied = HueClient(configuration: .init(host:"unit-test.invalid",applicationKey:"synthetic"), access:.readOnly, transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        })
        store.connect(snapshot: HomeSnapshot.project(try resources([])), client: denied)
        try await wait { store.bridgeAuthorizationRequired }
        check(store.bridgeUnavailable && !store.canRefresh && !store.controlsEnabled, "Revocation surfaces reconnect recovery and disables ineffective refresh")
        store.pauseForSleep(); sync.stop()
        print("\(count) refresh checks passed. Synthetic data only; no network or Keychain access.")
    }
}
