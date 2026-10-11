import Foundation
import SwiftUI
@testable import HueCore

@MainActor final class RecoveryClock {
    var delays: [TimeInterval] = []
    var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    func sleep(_ delay: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                delays.append(delay); waiting.append((id, continuation))
            }
        }, onCancel: { Task { @MainActor in
            if let index = self.waiting.firstIndex(where: { $0.0 == id }) { self.waiting.remove(at: index).1.resume(throwing: CancellationError()) }
        } })
    }
    func advance() { if !waiting.isEmpty { waiting.removeFirst().1.resume() } }
}
@MainActor final class WakeFixture {
    let suite = "SceneDeckWake-\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let clock = RecoveryClock()
    var silentLoads = 0, interactiveLoads = 0, saves = 0, removals = 0
    var requests: [String] = [], status = 200, name = "Evening", missingKey = false, keyLocked = false, apiDenied = false
    var holdNext = false, held: CheckedContinuation<(Data, URLResponse), Error>?, heldReply: (Data, URLResponse)?
    var activeReads = 0, maximumReads = 0, listeners = 0
    func services() -> BridgeConnection.Services {
        .init(loadKey: { _ in self.interactiveLoads += 1; return self.missingKey ? nil : "synthetic" }, loadKeySilently: { _ in
            self.silentLoads += 1
            if self.keyLocked { throw PairingError.keychain(-25308) }
            return self.missingKey ? nil : "synthetic"
        }, saveKey: { _, _ in self.saves += 1 }, removeKey: { _ in self.removals += 1 }, makeClient: { host, key, _, access in
            HueClient(configuration: .init(host: host, applicationKey: key), access: access, transport: { request in try await self.reply(request) }, eventTransport: { _ in
                self.beginListening()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { self.endListening(); throw error }
                self.endListening()
            })
        })
    }
    func beginListening() { listeners += 1 }
    func endListening() { listeners -= 1 }
    func reply(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request.httpMethod ?? "GET"); activeReads += 1; maximumReads = max(maximumReads, activeReads)
        defer { activeReads -= 1 }
        let body = apiDenied ? #"{"errors":[{"description":"unauthorized user"}],"data":[]}"# : """
        {"errors":[],"data":[{"id":"room-a","type":"room","metadata":{"name":"Study"}},{"id":"scene-a","type":"scene","metadata":{"name":"\(name)"},"group":{"rid":"room-a","rtype":"room"}}]}
        """
        let response: (Data, URLResponse) = (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        if holdNext {
            holdNext = false; heldReply = response
            return try await withCheckedThrowingContinuation { held = $0 } // Deliberately ignores cancellation to test late replies.
        }
        return response
    }
    func release() { let value = held; held = nil; if let heldReply { value?.resume(returning: heldReply) }; heldReply = nil }
    func store(disconnected: Bool = false, legacyPause: Bool = false) -> SceneStore {
        defaults.set("synthetic-bridge", forKey: "bridgeID"); defaults.set("unit-test.invalid", forKey: "bridgeHost")
        defaults.set(true, forKey: "setupComplete-synthetic-bridge")
        defaults.set(disconnected, forKey: "connectionDisconnected")
        defaults.set(legacyPause, forKey: "pausedAfterSleep-synthetic-bridge")
        return SceneStore(defaults: defaults, connectionServices: services(), recoverySleep: { try await self.clock.sleep($0) })
    }
    func clean() { defaults.removePersistentDomain(forName: suite) }
}

@main struct WakeChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) { guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }; count += 1; print("PASS: \(name)") }
        func until(_ description: String, _ condition: () -> Bool) async {
            for _ in 0..<20_000 { if condition() { return }; await Task.yield() }
            check(false, "Timed out: \(description)")
        }
        func drain() async { for _ in 0..<100 { await Task.yield() } }
        let f = WakeFixture(); defer { f.clean() }
        let store = f.store(legacyPause: true)
        await until("saved launch", { store.controlsEnabled && f.listeners == 1 })
        check(!store.pausedAfterSleep && !store.showConnection && f.interactiveLoads == 0, "Legacy sleep pause migrates to silent saved-access restoration on launch")
        store.selection = "room-a"; store.favorite(store.home.scenes[0])
        store.pauseForSleep(); await until("stream closes", { f.listeners == 0 })
        let sleepingReads = f.requests.count
        store.refreshOnForeground(); store.refreshScenes(); await drain()
        check(store.controlsDisabled && f.requests.count == sleepingReads, "No foreground or refresh traffic while actually sleeping")
        f.status = 503; store.resumeAfterWake()
        await until("retry backoff", { f.clock.waiting.count == 1 })
        let failedReads = f.requests.count
        for _ in 0..<10 { store.resumeAfterWake(); store.refreshOnForeground() }
        await drain()
        check(f.requests.count == failedReads && f.clock.waiting.count == 1 && store.reconnecting, "Repeated wake and foreground notifications share one recovery loop")
        check(store.home.scenes.first?.name == "Evening" && store.bridgeUnavailable && !store.controlsEnabled, "Offline wake keeps the last library and reports unavailability without controls")
        for _ in 0..<7 { f.clock.advance(); await until("next backoff", { f.clock.waiting.count == 1 }) }
        check(f.clock.delays == [1,2,4,8,16,32,60,60], "Retry backoff grows to sixty seconds and stays bounded")
        f.name = "After wake"; f.status = 200; f.clock.advance()
        await until("network recovery", { store.controlsEnabled && store.home.scenes.first?.name == "After wake" && !store.reconnecting })
        check(!store.pausedAfterSleep && store.selection == "room-a" && store.favorites == ["scene-a"] && f.interactiveLoads == 0, "Delayed network recovery refreshes inventory and preserves preferences without interaction")
        check(f.maximumReads == 1 && f.saves == 0 && f.removals == 0 && f.requests.allSatisfy { $0 == "GET" }, "Automatic recovery serializes reads and never pairs, saves credentials, or sends lighting commands")
        store.pauseForSleep(); f.status = 503; store.resumeAfterWake()
        await until("second outage", { f.clock.waiting.count == 1 })
        store.disconnectForSwitch(); let disconnectedReads = f.requests.count
        store.resumeAfterWake(); store.refreshOnForeground(); await drain()
        check(!store.isLive && !store.reconnecting && store.connection.requiresExplicitReconnect && f.requests.count == disconnectedReads, "Explicit Disconnect cancels backoff and blocks subsequent wake recovery")
        let relaunch = SceneStore(defaults: f.defaults, connectionServices: f.services(), recoverySleep: { try await f.clock.sleep($0) })
        relaunch.resumeAfterWake(); await drain()
        check(!relaunch.isLive && f.requests.count == disconnectedReads, "Explicit Disconnect remains respected after relaunch")

        let stale = WakeFixture(); defer { stale.clean() }
        stale.holdNext = true
        let staleStore = stale.store()
        await until("held launch read", { stale.held != nil })
        staleStore.pauseForSleep(); staleStore.resumeAfterWake()
        stale.name = "Fresh after second wake"; stale.release()
        await drain(); if !stale.clock.waiting.isEmpty { stale.clock.advance() }
        await until("fresh replacement read", { staleStore.controlsEnabled })
        check(staleStore.home.scenes.first?.name == "Fresh after second wake", "Late pre-sleep read cannot publish after wake")
        staleStore.disconnectForSwitch()

        let race = WakeFixture(); defer { race.clean() }
        race.holdNext = true
        let raceStore = race.store()
        await until("held automatic read", { race.held != nil })
        let manual = Task { await raceStore.restoreConnection() }
        await drain(); raceStore.disconnectForSwitch(); race.release(); await manual.value; await drain()
        check(!raceStore.isLive && raceStore.connection.requiresExplicitReconnect && race.interactiveLoads == 0, "Disconnect invalidates manual retry waiting for a cancelled automatic read")

        let manualWake = WakeFixture(); defer { manualWake.clean() }
        let manualStore = manualWake.store(disconnected: true)
        await manualStore.restoreConnection()
        await until("manual stream", { manualWake.listeners == 1 })
        manualWake.holdNext = true
        let heldManual = Task { await manualStore.restoreConnection() }
        await until("held manual read", { manualWake.held != nil })
        manualStore.pauseForSleep(); manualStore.resumeAfterWake(); manualWake.name = "Recovered wake"; manualWake.release()
        await heldManual.value
        await until("wake after manual teardown", { manualStore.controlsEnabled && manualStore.home.scenes.first?.name == "Recovered wake" })
        check(!manualStore.pausedAfterSleep, "Wake arriving during manual teardown resumes automatic recovery afterward")
        manualStore.disconnectForSwitch()

        let denied = WakeFixture(); defer { denied.clean() }
        denied.status = 403
        let deniedStore = denied.store()
        await until("revoked access", { deniedStore.bridgeAuthorizationRequired && !deniedStore.reconnecting })
        let deniedReads = denied.requests.count
        deniedStore.pauseForSleep(); deniedStore.resumeAfterWake(); deniedStore.refreshOnForeground(); await drain()
        check(denied.requests.count == deniedReads && denied.clock.delays.isEmpty && deniedStore.connection.automaticReconnectBlocked, "Revoked credentials stop automatic recovery across wake")
        let deniedRelaunch = SceneStore(defaults: denied.defaults, connectionServices: denied.services())
        deniedRelaunch.resumeAfterWake(); await drain()
        check(denied.requests.count == deniedReads, "Revoked access block survives relaunch")
        denied.status = 200; await deniedStore.restoreConnection()
        check(deniedStore.controlsEnabled && !deniedStore.connection.automaticReconnectBlocked, "Explicit retry can recover saved access without generating credentials")
        denied.apiDenied = true; deniedStore.refreshScenes()
        await until("API denial", { deniedStore.bridgeAuthorizationRequired })
        check(!deniedStore.controlsEnabled && deniedStore.connection.automaticReconnectBlocked, "API error in a successful HTTP response also stops live recovery")
        deniedStore.disconnectForSwitch()

        let missing = WakeFixture(); defer { missing.clean() }; missing.missingKey = true
        let missingStore = missing.store()
        await until("missing credential", { missingStore.bridgeAuthorizationRequired })
        check(missing.requests.isEmpty && missing.saves == 0 && missing.clock.delays.isEmpty, "Missing credentials never trigger network, pairing, or repeated attempts")
        let locked = WakeFixture(); defer { locked.clean() }; locked.keyLocked = true
        let lockedStore = locked.store()
        await until("locked keychain", { locked.clock.waiting.count == 1 })
        check(locked.interactiveLoads == 0 && locked.requests.isEmpty && !lockedStore.connection.automaticReconnectBlocked, "Temporarily locked Keychain retries silently without network or an authentication prompt")
        locked.keyLocked = false; locked.clock.advance()
        await until("unlocked keychain", { lockedStore.controlsEnabled })
        check(locked.interactiveLoads == 0 && !lockedStore.reconnecting, "Unlocking restores saved access on the next automatic attempt")
        lockedStore.disconnectForSwitch()
        print("\(count) wake lifecycle checks passed. Deterministic in-memory responses and manual clock; no network or Keychain access.")
    }
}
