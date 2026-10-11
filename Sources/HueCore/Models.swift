import Foundation

public struct SceneGroup: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var kind: String
    public var serviceID: String?
    public var brightness: Double?
    public var isOn: Bool?
    public var activeSceneID: String?
    public var icon: String { kind == "zone" ? "square.3.layers.3d" : (name.lowercased().contains("bed") ? "bed.double" : name.lowercased().contains("studio") ? "desktopcomputer" : "sofa") }
}
public struct LightScene: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let groupID: String
    public let colors: [String]
    public let brightness: Double?
    public let detail: String
}
public struct HomeSnapshot {
    public var groups: [SceneGroup]
    public var scenes: [LightScene]
    public var resources: [HueResource] = []
    public mutating func recall(_ id: String) throws {
        guard let scene = scenes.first(where: { $0.id == id }), let index = groups.firstIndex(where: { $0.id == scene.groupID }) else { throw HueError.invalidResource }
        groups[index].activeSceneID = id
        if let brightness = scene.brightness { groups[index].brightness = brightness }
        groups[index].isOn = true
    }
    public mutating func setBrightness(groupID: String, value: Double) {
        guard value.isFinite, let index = groups.firstIndex(where: { $0.id == groupID }), groups[index].brightness != nil else { return }
        groups[index].brightness = min(100, max(0, value))
        groups[index].activeSceneID = nil
    }
    public mutating func togglePower(groupID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), let on = groups[index].isOn else { return }
        groups[index].isOn = !on
        groups[index].activeSceneID = nil
    }
    public static func project(_ resources: [HueResource]) -> HomeSnapshot {
        let scenes = resources.filter { $0.type == "scene" }.compactMap { r -> LightScene? in
            guard let group = r.group else { return nil }
            var colors: [String] = []
            for action in r.actions ?? [] where action.action.on?.on != false {
                let state = action.action
                let swatch: String?
                if let xy = state.color?.xy, xy.x.isFinite, xy.y.isFinite, xy.x >= 0, xy.y > 0, xy.x+xy.y <= 1 {
                    let rgb = SceneColor.rgb(xy)
                    swatch = String(format: "%02X%02X%02X", Int((rgb.red*255).rounded()), Int((rgb.green*255).rounded()), Int((rgb.blue*255).rounded()))
                } else if let mirek = state.color_temperature?.mirek, (153...500).contains(mirek) {
                    // Representative warmth swatches, not a calibrated bulb simulation.
                    swatch = mirek < 220 ? "DCEAFF" : mirek < 330 ? "FFF0D7" : "FFC080"
                } else { swatch = nil }
                if let swatch, !colors.contains(swatch), colors.count < 5 { colors.append(swatch) }
            }
            return LightScene(id: r.id, name: r.metadata?.name ?? "Untitled scene", groupID: group.rid, colors: colors, brightness: nil, detail: colors.isEmpty ? "Color preview unavailable" : "Saved light colors")
        }
        let groups = resources.filter { ["room", "zone"].contains($0.type) }.map { r -> SceneGroup in
            let serviceID = r.services?.first { $0.rtype == "grouped_light" }?.rid
            let service = resources.first { $0.id == serviceID }
            let active = resources.first { $0.type == "scene" && $0.group?.rid == r.id && ["static", "dynamic_palette"].contains($0.status?.active ?? "") }?.id
            return SceneGroup(id: r.id, name: r.metadata?.name ?? "Unnamed group", kind: r.type, serviceID: serviceID, brightness: service?.dimming?.brightness, isOn: service?.on?.on, activeSceneID: active)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return HomeSnapshot(groups: groups, scenes: scenes, resources: resources)
    }
}
public enum DemoHome {
    public static func make() -> HomeSnapshot {
        let groups = [SceneGroup(id: "living", name: "Living room", kind: "room", serviceID: "demo-living", brightness: 72, isOn: true, activeSceneID: "living-0"), SceneGroup(id: "bedroom", name: "Bedroom", kind: "room", serviceID: "demo-bedroom", brightness: 38, isOn: true, activeSceneID: "bedroom-1"), SceneGroup(id: "studio", name: "Studio", kind: "room", serviceID: "demo-studio", brightness: 85, isOn: true, activeSceneID: nil), SceneGroup(id: "evening", name: "Downstairs", kind: "zone", serviceID: "demo-zone", brightness: 60, isOn: true, activeSceneID: nil)]
        let palettes: [(String, [String], Double, String)] = [
            ("Golden hour", ["A43F35", "F6A55F", "F7D999"], 72, "Warm · easygoing"),
            ("Afterglow", ["473F80", "BE6289", "F3AA87"], 38, "Soft · unhurried"),
            ("Blue hour", ["143B65", "387FAD", "9EBECB"], 48, "Cool · immersive"),
            ("Candlelight", ["5F2C28", "AC5A34", "F0B85C"], 28, "Low · intimate"),
            ("Daybreak", ["BC8C66", "E0C9A0", "EEE7CA"], 90, "Clear · focused"),
            ("Northern sky", ["233B51", "3B817D", "A1C8A0"], 60, "Fresh · spacious")]
        let scenes = groups.flatMap { group in palettes.enumerated().map { i, p in LightScene(id: "\(group.id)-\(i)", name: p.0, groupID: group.id, colors: p.1, brightness: p.2, detail: p.3) } }
        // Synthetic capabilities let the local editor/export flow work without any Bridge.
        var wire: [[String: Any]] = []
        for group in groups {
            let lightIDs = [group.id + "-lamp-1", group.id + "-lamp-2"]
            wire.append(["id": group.id, "type": group.kind, "metadata": ["name": group.name], "children": lightIDs.map { ["rid": $0, "rtype": "light"] }])
            for (index, id) in lightIDs.enumerated() {
                wire.append(["id": id, "type": "light", "metadata": ["name": index == 0 ? "Floor lamp" : "Table lamp"], "on": ["on": true], "dimming": ["brightness": group.brightness ?? 50], "color": ["xy": ["x": 0.4, "y": 0.4]], "color_temperature": ["mirek": 350, "mirek_schema": ["mirek_minimum": 153, "mirek_maximum": 500]] as [String: Any]])
            }
            for scene in scenes.filter({ $0.groupID == group.id }) {
                wire.append(["id": scene.id, "type": "scene", "metadata": ["name": scene.name], "group": ["rid": group.id, "rtype": group.kind], "actions": lightIDs.map { id -> [String: Any] in ["target": ["rid": id, "rtype": "light"], "action": ["on": ["on": true], "dimming": ["brightness": scene.brightness ?? 50]] as [String: Any]] }])
            }
        }
        let resources = (try? JSONDecoder().decode([HueResource].self, from: JSONSerialization.data(withJSONObject: wire))) ?? []
        return HomeSnapshot(groups: groups, scenes: scenes, resources: resources)
    }
}

// Minimal v2 wire subset, checked against public OpenHue schemas and read-only inventory.
// Unknown resource kinds and absent capabilities do not imply support for a control.
public struct HueEnvelope: Decodable {
    public let errors: [HueAPIError]
    public let data: [HueResource]
}
public struct HueAPIError: Decodable { public let description: String }
public struct HueResource: Decodable {
    public let id: String
    public let type: String
    public let metadata: Metadata?
    public let group: Reference?
    public let services: [Reference]?
    public let on: OnState?
    public let dimming: Dimming?
    public let status: Status?
    public let children: [Reference]?
    public let owner: Reference?
    public let color: ColorState?
    public let colorTemperature: Temperature?
    public let actions: [Action]?
    private enum CodingKeys: String, CodingKey { case id, type, metadata, group, services, on, dimming, status, children, owner, color, color_temperature, actions }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode(String.self, forKey: .type)
        metadata = ["scene", "room", "zone", "light"].contains(type) ? try values.decodeIfPresent(Metadata.self, forKey: .metadata) : nil
        group = type == "scene" ? try values.decodeIfPresent(Reference.self, forKey: .group) : nil
        services = ["room", "zone", "device"].contains(type) ? try values.decodeIfPresent([Reference].self, forKey: .services) : nil
        on = ["grouped_light", "light"].contains(type) ? try values.decodeIfPresent(OnState.self, forKey: .on) : nil
        dimming = ["grouped_light", "light"].contains(type) ? try values.decodeIfPresent(Dimming.self, forKey: .dimming) : nil
        status = type == "scene" ? try values.decodeIfPresent(Status.self, forKey: .status) : nil
        children = ["room", "zone"].contains(type) ? try values.decodeIfPresent([Reference].self, forKey: .children) : nil
        owner = type == "light" ? try values.decodeIfPresent(Reference.self, forKey: .owner) : nil
        color = type == "light" ? try values.decodeIfPresent(ColorState.self, forKey: .color) : nil
        colorTemperature = type == "light" ? try values.decodeIfPresent(Temperature.self, forKey: .color_temperature) : nil
        actions = type == "scene" ? try values.decodeIfPresent([Action].self, forKey: .actions) : nil
    }
    public struct Metadata: Decodable { public let name: String? }
    public struct Reference: Decodable { public let rid: String; public let rtype: String }
    public struct OnState: Decodable { public let on: Bool }
    public struct Dimming: Decodable { public let brightness: Double }
    public struct ColorState: Decodable { public let xy: SceneXY? }
    public struct Temperature: Decodable {
        public let mirek: Int?
        public let mirek_schema: Schema?
        public struct Schema: Decodable { public let mirek_minimum: Int; public let mirek_maximum: Int }
    }
    public struct Action: Decodable { public let target: Reference; public let action: ActionBody }
    public struct ActionBody: Decodable {
        public let on: OnState?; public let dimming: Dimming?; public let color: ColorState?; public let color_temperature: Temperature?
        public let unsupported: Bool
        struct Key: CodingKey { var stringValue: String; var intValue: Int? { nil }; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil } }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            on = try c.decodeIfPresent(OnState.self, forKey: Key(stringValue: "on")!)
            dimming = try c.decodeIfPresent(Dimming.self, forKey: Key(stringValue: "dimming")!)
            color = try c.decodeIfPresent(ColorState.self, forKey: Key(stringValue: "color")!)
            color_temperature = try c.decodeIfPresent(Temperature.self, forKey: Key(stringValue: "color_temperature")!)
            unsupported = !Set(c.allKeys.map(\.stringValue)).isSubset(of: ["on", "dimming", "color", "color_temperature"])
        }
    }
    public struct Status: Decodable { public let active: String? }
}
