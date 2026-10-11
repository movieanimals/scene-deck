import Foundation
@testable import HueCore

actor StubTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, String)]
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw HueError.malformedResponse }
        let next = responses.removeFirst()
        return (Data(next.1.utf8), HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}
@main struct ClientChecks {
    static var count = 0
    static func check(_ value: Bool, _ name: String) {
        guard value else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1; print("PASS: \(name)")
    }
    static func main() async throws {
        // Explicitly synthetic provisional envelopes; no real Bridge identifiers or keys.
        let fixture = #"{"errors":[],"data":[{"id":"room-a","type":"room","metadata":{"name":"Study"},"services":[{"rid":"group-a","rtype":"grouped_light"}]},{"id":"group-a","type":"grouped_light","dimming":{"brightness":42}},{"id":"scene-a","type":"scene","metadata":{"name":"Focus"},"group":{"rid":"room-a","rtype":"room"}}]}"#
        let mixed = #"{"errors":[],"data":[{"id":"radio-a","type":"zigbee_connectivity","status":"connected","metadata":"unrelated"},{"id":"scene-a","type":"scene","status":{"active":"static"},"group":{"rid":"room-a","rtype":"room"}}]}"#
        let mixedResources = try HueClient.decode(Data(mixed.utf8), status: 200).data
        check(mixedResources.count == 2 && mixedResources[1].status?.active == "static", "Mixed non-scene status cannot block scene inventory")
        let ack = #"{"errors":[],"data":[{"rid":"scene-a","rtype":"scene"}]}"#
        let transport = StubTransport([(200, fixture), (200, ack), (200, #"{"errors":[],"data":[{"rid":"group-a","rtype":"grouped_light"}]}"#)])
        let client = HueClient(configuration: .init(host: "unit-test.invalid", applicationKey: "synthetic-test-value"), access: .control, transport: { try await transport.send($0) })
        let resources = try await client.resources()
        let home = HomeSnapshot.project(resources)
        check(home.groups.first?.brightness == 42, "Mock scene list preserves observed group brightness")
        check(home.scenes.first?.brightness == nil, "Imported scene has no fabricated recall brightness")
        try await client.recall("scene-a")
        check(true, "Recall accepts acknowledgment without full resource fields")
        try await client.brightness("group-a", value: 31)
        check(true, "Brightness accepts acknowledgment without full resource fields")
        let requests = await transport.requests
        check(requests.map(\.httpMethod) == ["GET", "PUT", "PUT"], "Mock records intended methods")
        check(requests.map { $0.url!.path } == ["/clip/v2/resource", "/clip/v2/resource/scene/scene-a", "/clip/v2/resource/grouped_light/group-a"], "Scene and grouped-light resource IDs stay distinct")
        let errorTransport = StubTransport([(200, #"{"errors":[{"description":"mock denial"}],"data":[]}"#), (401, ""), (200, #"{"errors":[],"data":"invalid"}"#)])
        let errorClient = HueClient(configuration: .init(host: "unit-test.invalid", applicationKey: "synthetic-test-value"), access: .control, transport: { try await errorTransport.send($0) })
        do { try await errorClient.recall("scene-a"); check(false, "API error") }
        catch { check(error as? HueError == .api("mock denial"), "Write surfaces API error from HTTP 200") }
        do { try await errorClient.recall("scene-a"); check(false, "HTTP error") }
        catch { check(error as? HueError == .http(401), "Write surfaces HTTP authorization failure") }
        do { try await errorClient.recall("scene-a"); check(false, "Malformed receipt") }
        catch { check(true, "Malformed acknowledgment is not success") }
        for invalidReceipt in [#"{"errors":[],"data":[{}]}"#, #"{"errors":[],"data":[{"rid":"other-scene","rtype":"scene"}]}"#, #"{"errors":[],"data":[{"rid":"scene-a","rtype":"grouped_light"}]}"#, #"{"errors":[],"data":[]}"#] {
            let stub = StubTransport([(200, invalidReceipt)])
            let invalidClient = HueClient(configuration: .init(host: "unit-test.invalid", applicationKey: "synthetic-test-value"), access: .control, transport: { try await stub.send($0) })
            do { try await invalidClient.recall("scene-a"); check(false, "Invalid target receipt accepted") }
            catch { check(true, "Reject missing or mismatched acknowledgment target") }
        }
        let powerStub = StubTransport([(200, #"{"errors":[],"data":[{"rid":"group-a","rtype":"grouped_light"}]}"#), (200, #"{"errors":[],"data":[{"rid":"other","rtype":"grouped_light"}]}"#)])
        let powerClient = HueClient(configuration: .init(host: "unit-test.invalid", applicationKey: "synthetic"), access: .control, transport: { try await powerStub.send($0) })
        try await powerClient.power("group-a", on: false)
        check(true, "Power accepts matching grouped-light receipt")
        do { try await powerClient.power("group-a", on: true); check(false, "Mismatched power receipt") }
        catch { check(error as? HueError == .malformedResponse, "Power rejects receipt for a different group") }
        let never = StubTransport([])
        let readOnly = HueClient(configuration: .init(host: "unit-test.invalid", applicationKey: "synthetic-test-value"), access: .readOnly, transport: { try await never.send($0) })
        do { try await readOnly.recall("scene-a"); check(false, "Read-only recall") }
        catch { check(error as? HueError == .approvalRequired, "Read-only policy blocks recall with injected transport too") }
        do { try await readOnly.power("group-a", on: false); check(false, "Read-only power") }
        catch { check(error as? HueError == .approvalRequired, "Read-only policy blocks power before transport") }
        check(await never.requests.isEmpty, "Blocked action never reaches transport")
        check(home.groups.first?.activeSceneID == nil, "Mock recall acknowledgment does not invent observed active state")
        print("\(count) client integration checks passed. All responses are in-memory mocks.")
    }
}
