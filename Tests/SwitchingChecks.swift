import Foundation
import SwiftUI
@testable import HueCore

@main struct SwitchingChecks {
    @MainActor static func main() async throws {
        let suite = "SceneDeckSwitchVerification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        func check(_ value: Bool, _ name: String) { guard value else { fputs("FAIL: \(name)\n", stderr); exit(1) }; count += 1; print("PASS: \(name)") }
        let a = "aaaaaaaaaaaaaaaa", b = "bbbbbbbbbbbbbbbb"
        let keys = [a: "synthetic-a", b: "synthetic-b"]
        let hosts = [a: "household-a.invalid", b: "household-b.invalid"]
        defaults.set(hosts, forKey: "bridgeEndpoints")
        defaults.set(a, forKey: "bridgeID"); defaults.set(hosts[a], forKey: "bridgeHost")
        defaults.set(true, forKey: "setupComplete-" + a); defaults.set(true, forKey: "setupComplete-" + b)
        defaults.set(true, forKey: "connectionDisconnected")
        var loads: [String] = [], saves = 0, removals = 0, methods: [String] = []
        var identityMatches = true, listening = 0
        let services = BridgeConnection.Services(loadKey: { loads.append($0); return keys[$0] }, saveKey: { _, _ in saves += 1 }, removeKey: { _ in removals += 1 }, makeClient: { host, key, id, access in
            identityMatches = identityMatches && hosts[id] == host && keys[id] == key
            let payload = """
            {"errors":[],"data":[
              {"id":"\(id)-room","type":"room","metadata":{"name":"Study"}},
              {"id":"\(id)-scene","type":"scene","metadata":{"name":"Work"},"group":{"rid":"\(id)-room","rtype":"room"}}
            ]}
            """
            return HueClient(configuration: .init(host: host, applicationKey: key), access: access, transport: { request in
                methods.append(request.httpMethod ?? "GET")
                return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, eventTransport: { _ in
                listening += 1; defer { listening -= 1 }
                try await Task.sleep(nanoseconds: 60_000_000_000)
            })
        })
        let store = SceneStore(defaults: defaults, connectionServices: services)
        check(store.showConnection && !store.connection.paired && store.connection.savedBridges.count == 2 && loads.isEmpty, "Disconnected launch offers saved Bridges without reading keys")
        await store.restoreConnection()
        for _ in 0..<100 where listening == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        check(store.isLive && store.connection.paired && store.activeBridgeID == a && store.controlsEnabled, "Explicit reconnect follows production setup flow for household A")
        store.selection = a + "-room"; store.favorite(store.home.scenes[0])
        store.pauseForSleep()
        check(store.pausedAfterSleep && !store.controlsEnabled && defaults.bool(forKey: "pausedAfterSleep-" + a), "Household A sleep pause persists and disables controls")
        store.disconnectForSwitch()
        for _ in 0..<100 where listening > 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        check(!store.isLive && !store.connection.paired && !store.controlsEnabled && store.activeBridgeID.isEmpty && listening == 0, "Switch action closes old streams and enables endpoint selection")
        check(store.selection == "all" && !store.favorites.contains(a + "-scene"), "Disconnected demo exposes no prior household favorites or selection")
        let loadsBeforeChoice = loads.count, requestsBeforeChoice = methods.count
        store.connection.selectSavedBridge(b)
        check(store.connection.bridgeID == b && loads.count == loadsBeforeChoice && methods.count == requestsBeforeChoice, "Saved Bridge selection performs no credential read or network operation")
        await store.restoreConnection()
        check(store.activeBridgeID == b && store.favorites.isEmpty && store.selection == "all", "Household B reconnect gets its own initial preferences")
        store.selection = "favorites"; store.favorite(store.home.scenes[0])
        store.disconnectForSwitch(); store.connection.selectSavedBridge(a)
        let loadCount = loads.count
        let relaunched = SceneStore(defaults: defaults, connectionServices: services)
        try await Task.sleep(nanoseconds: 10_000_000)
        check(relaunched.pausedAfterSleep && !relaunched.isLive && loads.count == loadCount, "Selecting paused A and relaunching never reconnects automatically")
        await store.restoreConnection()
        check(store.activeBridgeID == a && store.selection == a + "-room" && store.favorites == [a + "-scene"], "A to B to A restores A's own selection and favorites")
        check(!store.pausedAfterSleep && !defaults.bool(forKey: "pausedAfterSleep-" + a), "Only explicit reconnect clears selected household sleep pause")
        check(defaults.string(forKey: "selectedView-" + b) == "favorites" && defaults.stringArray(forKey: "bridgeFavoriteIDs-" + b) == [b + "-scene"], "Returning to A preserves B's independent preferences")
        store.disconnectForSwitch()
        let beforeRelaunch = loads.count
        let disconnected = SceneStore(defaults: defaults, connectionServices: services)
        try await Task.sleep(nanoseconds: 10_000_000)
        check(!disconnected.isLive && loads.count == beforeRelaunch && disconnected.connection.requiresExplicitReconnect, "Explicit disconnect stays disconnected across launch")
        check(saves == 0 && removals == 0 && identityMatches, "Switching keeps both keys and uses each only with its own endpoint")
        check(!methods.isEmpty && methods.allSatisfy { $0 == "GET" }, "Switching never registers, recalls, or writes any scene/light state")
        print("\(count) Bridge switching checks passed. In-memory services only; no network or Keychain access.")
    }
}
