import XCTest
@testable import HueCore

final class HueCoreTests: XCTestCase {
    func testSceneRecallOnlyChangesItsOwnRoom() throws {
        var home = DemoHome.make()
        let bedroom = home.groups[1]
        let scene = home.scenes.first { $0.groupID == home.groups[0].id }!
        try home.recall(scene.id)
        XCTAssertEqual(home.groups[0].activeSceneID, scene.id)
        XCTAssertEqual(home.groups[1], bedroom)
        home.setBrightness(groupID: home.groups[0].id, value: 37)
        XCTAssertNil(home.groups[0].activeSceneID)
        XCTAssertEqual(home.groups[0].brightness, 37)
    }
    func testUnknownSceneDoesNotMutateHome() {
        var home = DemoHome.make()
        let before = home.groups
        XCTAssertThrowsError(try home.recall("missing"))
        XCTAssertEqual(home.groups, before)
    }
    func testCapabilitiesAreOptionalAndUnknownResourcesSurvive() throws {
        let data = Data(#"{"errors":[],"data":[{"id":"g1","type":"grouped_light","on":{"on":true}},{"id":"future","type":"future_resource"}]}"#.utf8)
        let envelope = try JSONDecoder().decode(HueEnvelope.self, from: data)
        XCTAssertNil(envelope.data[0].dimming)
        XCTAssertEqual(envelope.data[1].type, "future_resource")
    }
    func testTransportCannotRunWithoutApproval() async {
        let client = HueClient(configuration: .init(host: "192.0.2.1", applicationKey: "test-only"), access: .blocked)
        do { _ = try await client.resources(); XCTFail("Must be blocked") }
        catch { XCTAssertEqual(error as? HueError, .approvalRequired) }
    }
    func testHostValidationAndHTTPS() throws {
        for invalid in ["http://192.0.2.1", "example.com/path", "user@host", "", "127.0.0.1:80", "host?x=y"] {
            XCTAssertThrowsError(try HueRequestFactory(configuration: .init(host: invalid, applicationKey: "test")).resources())
        }
        let request = try HueRequestFactory(configuration: .init(host: "192.0.2.1", applicationKey: "test")).resources()
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.path, "/clip/v2/resource")
        XCTAssertEqual(request.value(forHTTPHeaderField: "hue-application-key"), "test")
    }
    func testBrightnessRejectsInvalidValuesAndIDs() throws {
        let factory = HueRequestFactory(configuration: .init(host: "192.0.2.1", applicationKey: "test"))
        for value in [-1.0, 101, .nan, .infinity] { XCTAssertThrowsError(try factory.brightness(id: "group", value: value)) }
        XCTAssertThrowsError(try factory.recall(id: "../bad"))
        let request = try factory.brightness(id: "group", value: 42)
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: [String: Double]]
        XCTAssertEqual(object["dimming"]?["brightness"], 42)
    }
    func testResponseErrorsAreNotTreatedAsSuccess() {
        XCTAssertThrowsError(try HueClient.decode(Data(#"{"errors":[{"description":"unauthorized"}],"data":[]}"#.utf8), status: 200))
        XCTAssertThrowsError(try HueClient.decode(Data(), status: 401))
    }
    func testEventFramesWaitForBlankLineAndIgnoreHeartbeat() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(": ping"))
        XCTAssertNil(parser.feed(""))
        XCTAssertNil(parser.feed("data: [{\"type\":\"update\"}]"))
        XCTAssertEqual(parser.feed(""), "[{\"type\":\"update\"}]")
        XCTAssertNil(parser.feed(""))
    }
    func testProjectionUsesReferencesNotNames() throws {
        let json = #"{"errors":[],"data":[{"id":"r","type":"room","metadata":{"name":"Office"},"services":[{"rid":"g","rtype":"grouped_light"}]},{"id":"g","type":"grouped_light","on":{"on":true},"dimming":{"brightness":52}},{"id":"s","type":"scene","metadata":{"name":"Focus"},"group":{"rid":"r","rtype":"room"},"status":{"active":"static"}}]}"#
        let home = HomeSnapshot.project(try JSONDecoder().decode(HueEnvelope.self, from: Data(json.utf8)).data)
        XCTAssertEqual(home.groups.first?.brightness, 52)
        XCTAssertEqual(home.groups.first?.activeSceneID, "s")
        XCTAssertEqual(home.scenes.first?.groupID, "r")
    }
}
