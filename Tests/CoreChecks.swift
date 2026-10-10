import Foundation
import HueCore

@main struct CoreChecks {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1
        print("PASS: \(name)")
    }
    static func rejects(_ name: String, _ block: () throws -> Void) {
        do { try block(); check(false, name) } catch { check(true, name) }
    }
    static func main() async throws {
        var home = DemoHome.make()
        let untouched = home.groups[1]
        try home.recall("living-2")
        check(home.groups[0].activeSceneID == "living-2", "Scene recall activates the selected scene")
        check(home.groups[1] == untouched, "Scene recall leaves other rooms unchanged")
        home.setBrightness(groupID: "living", value: 37)
        check(home.groups[0].brightness == 37 && home.groups[0].activeSceneID == nil, "Manual brightness clears stale active scene")
        let before = home.groups
        rejects("Unknown scene fails") { try home.recall("missing") }
        check(home.groups == before, "Unknown scene leaves state unchanged")
        home.setBrightness(groupID: "living", value: .nan)
        check(home.groups == before, "NaN brightness leaves state unchanged")
        home.togglePower(groupID: "living")
        check(home.groups[0].isOn == false, "Group power toggles")
        check(Set(home.scenes.map(\.id)).count == home.scenes.count, "Demo scene identifiers are unique")
        check(home.groups.contains { $0.kind == "zone" }, "Demo includes a zone")
        let factory = HueRequestFactory(configuration: .init(host: "192.0.2.1", applicationKey: "test-only"))
        let request = try factory.resources()
        check(request.url?.scheme == "https" && request.url?.path == "/clip/v2/resource", "Resource request uses HTTPS v2 endpoint")
        check(request.value(forHTTPHeaderField: "hue-application-key") == "test-only", "Application key is a header")
        check(request.url?.query == nil, "Credential is absent from URL")
        for invalid in ["http://192.0.2.1", "example.com/path", "user@host", "", "127.0.0.1:80", "host?x=y", "host\nname"] {
            rejects("Reject malformed host \(invalid.debugDescription)") { _ = try HueRequestFactory(configuration: .init(host: invalid, applicationKey: "test")).resources() }
        }
        for value in [-1.0, 101, .nan, .infinity] { rejects("Reject brightness \(value)") { _ = try factory.brightness(id: "group", value: value) } }
        rejects("Reject resource path traversal") { _ = try factory.recall(id: "../bad") }
        let recall = try factory.recall(id: "scene-1")
        let recallJSON = try JSONSerialization.jsonObject(with: recall.httpBody!) as! [String: [String: String]]
        check(recall.httpMethod == "PUT" && recallJSON["recall"]?["action"] == "active", "Recall request contract fixture")
        let brightness = try factory.brightness(id: "group", value: 42)
        let brightnessJSON = try JSONSerialization.jsonObject(with: brightness.httpBody!) as! [String: [String: Double]]
        check(brightnessJSON["dimming"]?["brightness"] == 42, "Brightness request contract fixture")
        rejects("HTTP failures are rejected") { _ = try HueClient.decode(Data(), status: 401) }
        rejects("API errors in HTTP 200 are rejected") { _ = try HueClient.decode(Data(#"{"errors":[{"description":"unauthorized"}],"data":[]}"#.utf8), status: 200) }
        let resources = try HueClient.decode(Data(#"{"errors":[],"data":[{"id":"g","type":"grouped_light","on":{"on":true}},{"id":"future","type":"future_resource"}]}"#.utf8), status: 200)
        check(resources.data[0].dimming == nil, "Absent brightness capability decodes safely")
        check(resources.data[1].type == "future_resource", "Unknown resource kinds decode safely")
        let json = #"{"errors":[],"data":[{"id":"r","type":"room","metadata":{"name":"Office"},"services":[{"rid":"g","rtype":"grouped_light"}]},{"id":"g","type":"grouped_light","on":{"on":true},"dimming":{"brightness":52}},{"id":"s","type":"scene","metadata":{"name":"Focus"},"group":{"rid":"r","rtype":"room"},"status":{"active":"static"}}]}"#
        let projected = HomeSnapshot.project(try HueClient.decode(Data(json.utf8), status: 200).data)
        check(projected.groups[0].brightness == 52 && projected.groups[0].activeSceneID == "s", "Projection resolves resource references")
        check(projected.scenes[0].groupID == "r", "Scene remains associated with its room")
        var parser = SSEParser()
        check(parser.feed(": ping") == nil && parser.feed("") == nil, "SSE heartbeat causes no state change")
        check(parser.feed("data: [{\"type\":\"update\"}]") == nil, "SSE waits for complete frame")
        check(parser.feed("") == "[{\"type\":\"update\"}]", "SSE emits a complete event")
        check(parser.feed("") == nil, "SSE does not repeat prior frame")
        let blocked = HueClient(configuration: .init(host: "192.0.2.1", applicationKey: "test-only"))
        do { _ = try await blocked.resources(); check(false, "Blocked read") } catch { check(error as? HueError == .approvalRequired, "Read blocked before any network access") }
        do { try await blocked.recall("scene"); check(false, "Blocked write") } catch { check(error as? HueError == .approvalRequired, "Write blocked before any network access") }
        let readonly = HueClient(configuration: .init(host: "192.0.2.1", applicationKey: "test-only"), access: .readOnly)
        do { try await readonly.brightness("group", value: 42); check(false, "Read-only write") } catch { check(error as? HueError == .approvalRequired, "Read-only authorization cannot control lights") }
        print("\(count) core checks passed. No network requests made.")
    }
}
