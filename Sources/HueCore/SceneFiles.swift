import Foundation

public enum SceneFileError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}
public struct SceneXY: Codable, Equatable {
    public var x: Double; public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct SceneLightState: Codable, Equatable {
    public var on: Bool
    public var brightness: Double?
    public var xy: SceneXY?
    public var mirek: Int?
    public init(on: Bool = true, brightness: Double? = nil, xy: SceneXY? = nil, mirek: Int? = nil) { self.on = on; self.brightness = brightness; self.xy = xy; self.mirek = mirek }
    func validate() throws {
        if let b = brightness, !b.isFinite || !(0...100).contains(b) { throw SceneFileError.invalid("Brightness must be 0–100.") }
        if let c = xy, !c.x.isFinite || !c.y.isFinite || c.x < 0 || c.y <= 0 || c.x + c.y > 1 { throw SceneFileError.invalid("Color coordinates must be finite and inside the xy chromaticity triangle.") }
        if let m = mirek, !(153...500).contains(m) { throw SceneFileError.invalid("Color temperature must be 153–500 mirek.") }
        if xy != nil && mirek != nil { throw SceneFileError.invalid("Choose color or color temperature for a light, not both.") }
    }
    var hueBody: [String: Any] {
        var body: [String: Any] = ["on": ["on": on]]
        if let b = brightness { body["dimming"] = ["brightness": b] }
        if let xy { body["color"] = ["xy": ["x": xy.x, "y": xy.y]] }
        if let mirek { body["color_temperature"] = ["mirek": mirek] }
        return body
    }
}
public struct PortableScene: Codable, Equatable {
    public struct Lamp: Codable, Equatable, Identifiable {
        public var slot: String; public var label: String; public var state: SceneLightState
        public var id: String { slot }
        public init(slot: String, label: String, state: SceneLightState) { self.slot = slot; self.label = label; self.state = state }
    }
    public var format = "scene-deck.scene"
    public var version = 1
    public var name: String
    public var groupLabel: String
    public var lights: [Lamp]
    public init(name: String, groupLabel: String, lights: [Lamp]) { self.name = name; self.groupLabel = groupLabel; self.lights = lights }
    public static let maxBytes = 131_072
    public func validate() throws {
        guard format == "scene-deck.scene", version == 1 else { throw SceneFileError.invalid("Only Scene Deck scene format version 1 is supported.") }
        func label(_ text: String, maximum: Int) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= maximum && text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        guard label(name, maximum: 32), label(groupLabel, maximum: 64) else { throw SceneFileError.invalid("Use a scene name of 1–32 characters and a room label of 1–64 characters, without control characters.") }
        guard (1...50).contains(lights.count), Set(lights.map(\.slot)).count == lights.count else { throw SceneFileError.invalid("Use 1–50 lights with unique slot names.") }
        for lamp in lights {
            guard (1...32).contains(lamp.slot.utf8.count), lamp.slot.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }), label(lamp.label, maximum: 64) else { throw SceneFileError.invalid("Each light needs a simple unique slot and a readable label.") }
            try lamp.state.validate()
        }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maxBytes else { throw SceneFileError.invalid("Scene files must be no larger than 128 KiB.") }
        // Strict allowlist. URLs, scripts, credentials, target resource IDs, and unknown fields are never accepted.
        func object(_ value: Any?, keys: Set<String>, required: Set<String>) throws -> [String: Any] {
            guard let v = value as? [String: Any], Set(v.keys).isSubset(of: keys), required.isSubset(of: Set(v.keys)) else { throw SceneFileError.invalid("Unrecognized or missing scene-file fields.") }
            return v
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw SceneFileError.invalid("Choose a valid Scene Deck JSON file.") }
        let root = try object(json, keys: ["format", "version", "name", "groupLabel", "lights"], required: ["format", "version", "name", "groupLabel", "lights"])
        guard let lamps = root["lights"] as? [Any], lamps.count <= 50 else { throw SceneFileError.invalid("The scene must contain no more than 50 lights.") }
        for lamp in lamps {
            let v = try object(lamp, keys: ["slot", "label", "state"], required: ["slot", "label", "state"])
            let state = try object(v["state"], keys: ["on", "brightness", "xy", "mirek"], required: ["on"])
            if let xy = state["xy"] { _ = try object(xy, keys: ["x", "y"], required: ["x", "y"]) }
        }
        guard let result = try? JSONDecoder().decode(Self.self, from: data) else { throw SceneFileError.invalid("Scene-file values have invalid types.") }
        try result.validate(); return result
    }
    public func encoded() throws -> Data { try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(self) }
}

public struct AvailableLight: Identifiable {
    public let id: String; public let name: String
    public let brightness: Bool; public let color: Bool
    public let mirekRange: ClosedRange<Int>?
    public let current: SceneLightState
}
public struct SceneCatalog {
    public let resources: [HueResource]
    public init(_ resources: [HueResource]) { self.resources = resources }
    public var groups: [HueResource] { resources.filter { ["room", "zone"].contains($0.type) } }
    public func lights(in groupID: String) -> [AvailableLight] {
        guard let group = groups.first(where: { $0.id == groupID }) else { return [] }
        let children = Set((group.children ?? []).filter { $0.rtype == "device" }.map(\.rid))
        let direct = Set((group.children ?? []).filter { $0.rtype == "light" }.map(\.rid))
        let lightIDs = Set(resources.filter { $0.type == "device" && children.contains($0.id) }.flatMap { ($0.services ?? []).filter { $0.rtype == "light" }.map(\.rid) }).union(direct)
        return resources.filter { $0.type == "light" && (lightIDs.contains($0.id) || children.contains($0.owner?.rid ?? "")) }.map {
            let range = $0.colorTemperature?.mirek_schema
            return AvailableLight(id: $0.id, name: $0.metadata?.name ?? "Light", brightness: $0.dimming != nil, color: $0.color != nil,
                mirekRange: range.flatMap { $0.mirek_minimum <= $0.mirek_maximum ? $0.mirek_minimum...$0.mirek_maximum : nil },
                current: SceneLightState(on: $0.on?.on ?? true, brightness: $0.dimming?.brightness, xy: $0.colorTemperature?.mirek == nil ? $0.color?.xy : nil, mirek: $0.colorTemperature?.mirek))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func draft(groupID: String) throws -> (PortableScene, [String: String]) {
        guard let group = groups.first(where: { $0.id == groupID }) else { throw HueError.invalidResource }
        let lights = lights(in: groupID)
        let entries = lights.enumerated().map { PortableScene.Lamp(slot: "lamp-\($0.offset + 1)", label: $0.element.name, state: $0.element.current) }
        let draft = PortableScene(name: "New scene", groupLabel: group.metadata?.name ?? "Room", lights: entries)
        try draft.validate()
        return (draft, Dictionary(uniqueKeysWithValues: zip(entries.map(\.slot), lights.map(\.id))))
    }
    public func export(sceneID: String) throws -> (PortableScene, [String: String]) {
        guard let scene = resources.first(where: { $0.type == "scene" && $0.id == sceneID }), let groupID = scene.group?.rid,
              let actions = scene.actions, !actions.isEmpty else { throw SceneFileError.invalid("This scene has no supported static light actions.") }
        let available = lights(in: groupID)
        var entries: [PortableScene.Lamp] = []; var mapping: [String: String] = [:]
        for (index, action) in actions.enumerated() {
            guard action.target.rtype == "light", let light = available.first(where: { $0.id == action.target.rid }), !action.action.unsupported else { throw SceneFileError.invalid("This scene uses unsupported effects, gradients, or targets. Create a new scene from current lights instead.") }
            guard let on = action.action.on?.on else { throw SceneFileError.invalid("This scene leaves power unchanged, which format version 1 cannot represent. Create a new scene from current lights instead.") }
            let state = SceneLightState(on: on, brightness: action.action.dimming?.brightness, xy: action.action.color?.xy, mirek: action.action.color_temperature?.mirek)
            let slot = "lamp-\(index + 1)"; entries.append(.init(slot: slot, label: light.name, state: state)); mapping[slot] = light.id
        }
        let group = groups.first { $0.id == groupID }
        let draft = PortableScene(name: scene.metadata?.name ?? "Scene", groupLabel: group?.metadata?.name ?? "Room", lights: entries)
        try draft.validate(); return (draft, mapping)
    }
    public func plan(_ scene: PortableScene, groupID: String, mapping: [String: String], replacing sceneID: String? = nil) throws -> SceneWritePlan {
        try scene.validate()
        guard let group = groups.first(where: { $0.id == groupID }) else { throw SceneFileError.invalid("Select a room or zone on this Bridge.") }
        if let sceneID { guard resources.contains(where: { $0.id == sceneID && $0.type == "scene" && $0.group?.rid == groupID }) else { throw SceneFileError.invalid("The scene to edit must belong to the selected room on this Bridge.") } }
        guard Set(mapping.keys) == Set(scene.lights.map(\.slot)), Set(mapping.values).count == scene.lights.count else { throw SceneFileError.invalid("Map every source light to a different light in the selected room.") }
        let available = lights(in: groupID)
        var actions: [[String: Any]] = []
        for entry in scene.lights {
            guard let target = mapping[entry.slot], let light = available.first(where: { $0.id == target }) else { throw SceneFileError.invalid("A mapped light is unavailable in the selected room. Refresh and map again.") }
            let state = entry.state
            guard state.brightness == nil || light.brightness, state.xy == nil || light.color else { throw SceneFileError.invalid("\(light.name) does not support the selected brightness or color setting.") }
            if let m = state.mirek { guard light.mirekRange?.contains(m) == true else { throw SceneFileError.invalid("\(light.name) does not support this color temperature.") } }
            actions.append(["target": ["rid": target, "rtype": "light"], "action": state.hueBody])
        }
        var body: [String: Any] = ["metadata": ["name": scene.name], "actions": actions]
        if sceneID == nil { body["type"] = "scene"; body["group"] = ["rid": groupID, "rtype": group.type] }
        return SceneWritePlan(sceneID: sceneID, groupID: groupID, name: scene.name, body: body)
    }
}
public struct SceneWritePlan {
    public let sceneID: String?; public let groupID: String; public let name: String
    internal let body: [String: Any]
}
