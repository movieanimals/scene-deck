import Foundation
@testable import HueCore

@main struct SceneFileChecks {
    static var count = 0
    static func check(_ value: Bool, _ title: String) { guard value else { fputs("FAIL: \(title)\n", stderr); exit(1) }; count += 1; print("PASS: \(title)") }
    static func rejects(_ title: String, _ operation: () throws -> Void) { do { try operation(); check(false, title) } catch { check(true, title) } }
    static func catalog(_ prefix: String) throws -> SceneCatalog {
        let json = """
        {"errors":[],"data":[
        {"id":"\(prefix)-room","type":"room","metadata":{"name":"Study"},"children":[{"rid":"\(prefix)-device","rtype":"device"}]},
        {"id":"\(prefix)-device","type":"device","services":[{"rid":"\(prefix)-light","rtype":"light"}]},
        {"id":"\(prefix)-light","type":"light","metadata":{"name":"Desk"},"owner":{"rid":"\(prefix)-device","rtype":"device"},"on":{"on":true},"dimming":{"brightness":42},"color":{"xy":{"x":0.3,"y":0.3}},"color_temperature":{"mirek":250,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":500}}},
        {"id":"\(prefix)-scene","type":"scene","metadata":{"name":"Work"},"group":{"rid":"\(prefix)-room","rtype":"room"},"actions":[{"target":{"rid":"\(prefix)-light","rtype":"light"},"action":{"on":{"on":true},"dimming":{"brightness":50}}}]}
        ]}
        """
        return SceneCatalog(try HueClient.decode(Data(json.utf8), status: 200).data)
    }
    static func main() async throws {
        let a = try catalog("a"), b = try catalog("b")
        let (scene, mapping) = try a.export(sceneID: "a-scene")
        let data = try scene.encoded()
        check(try PortableScene.decode(data) == scene, "Scene file round trips supported static values")
        let text = String(data: data, encoding: .utf8)!
        check(!text.contains("a-light") && !text.contains("a-room") && !text.contains("application"), "Exports contain no Bridge resource IDs or credentials")
        rejects("Reject oversized files") { _ = try PortableScene.decode(Data(repeating: 32, count: PortableScene.maxBytes + 1)) }
        rejects("Reject script or URL fields") { _ = try PortableScene.decode(Data(text.replacingOccurrences(of: "\"version\"", with: "\"url\":\"https://example.invalid\",\"version\"").utf8)) }
        var invalid = scene; invalid.version = 2
        rejects("Reject unknown schema version") { _ = try invalid.encoded() }
        invalid = scene; invalid.lights[0].state.brightness = .nan
        rejects("Reject nonfinite brightness") { _ = try invalid.encoded() }
        invalid = scene; invalid.lights.append(invalid.lights[0])
        rejects("Reject duplicate slots") { _ = try invalid.encoded() }
        invalid = scene; invalid.lights[0].state.xy = .init(x: 0.9, y: 0.9)
        rejects("Reject out-of-range colors") { _ = try invalid.encoded() }
        invalid = scene; invalid.lights[0].state.xy = .init(x: 0.3, y: 0.3); invalid.lights[0].state.mirek = 200
        rejects("Reject competing color modes") { _ = try invalid.encoded() }
        rejects("Second household rejects first-household mapping") { _ = try b.plan(scene, groupID: "b-room", mapping: mapping) }
        rejects("Require explicit mapping for every imported lamp") { _ = try b.plan(scene, groupID: "b-room", mapping: [:]) }
        let remapped = try b.plan(scene, groupID: "b-room", mapping: ["lamp-1":"b-light"])
        let factory = HueRequestFactory(configuration: .init(host: "unit-test.invalid", applicationKey: "synthetic"))
        let request = try factory.sceneWrite(remapped)
        let body = String(data: request.httpBody!, encoding: .utf8)!
        check(request.httpMethod == "POST" && body.contains("b-light") && !body.contains("a-light") && !body.contains("recall"), "Import creates only in mapped household and never recalls")
        let edit = try a.plan(scene, groupID: "a-room", mapping: mapping, replacing: "a-scene")
        check(try factory.sceneWrite(edit).httpMethod == "PUT", "Editing uses selected scene endpoint")
        rejects("Cannot edit another household scene") { _ = try b.plan(scene, groupID: "b-room", mapping: ["lamp-1":"b-light"], replacing: "a-scene") }
        var attempts = 0
        let readonly = HueClient(configuration: .init(host: "unit-test.invalid", applicationKey: "synthetic"), access: .readOnly, transport: { request in attempts += 1; return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
        do { _ = try await readonly.saveScene(remapped); check(false, "read only") } catch { check(attempts == 0, "Read-only setup blocks scene creation before transport") }
        let client = HueClient(configuration: .init(host: "unit-test.invalid", applicationKey: "synthetic"), access: .control, transport: { request in attempts += 1; return (Data(#"{"errors":[],"data":[{"rid":"new-scene","rtype":"scene"}]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
        check(try await client.saveScene(remapped) == "new-scene", "Creation returns validated scene acknowledgment")
        let simpleResources = try HueClient.decode(Data(#"{"errors":[],"data":[{"id":"room","type":"room","children":[{"rid":"light","rtype":"light"}]},{"id":"light","type":"light","on":{"on":true}},{"id":"scene","type":"scene","group":{"rid":"room","rtype":"room"},"actions":[{"target":{"rid":"light","rtype":"light"},"action":{"dimming":{"brightness":40}}}]}]}"#.utf8), status: 200).data
        let simple = SceneCatalog(simpleResources)
        rejects("Unsupported brightness cannot target a switch-only light") { _ = try simple.plan(scene, groupID: "room", mapping: ["lamp-1":"light"]) }
        var warmth = scene; warmth.lights[0].state.brightness = nil; warmth.lights[0].state.mirek = 350
        rejects("Unsupported warmth cannot target a switch-only light") { _ = try simple.plan(warmth, groupID: "room", mapping: ["lamp-1":"light"]) }
        rejects("Export never invents an omitted scene power state") { _ = try simple.export(sceneID: "scene") }
        let demo = SceneCatalog(DemoHome.make().resources)
        check(try demo.draft(groupID: "living").0.lights.count == 2 && demo.export(sceneID: "living-0").0.name == "Golden hour", "Offline demo provides editor and export fixtures")
        print("\(count) portable scene checks passed. Synthetic households; no network or Bridge writes.")
    }
}
