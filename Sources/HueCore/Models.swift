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
            return LightScene(id: r.id, name: r.metadata?.name ?? "Untitled scene", groupID: group.rid, colors: ["506A85", "B9A4A0", "D8BE9C"], brightness: nil, detail: "Bridge scene")
        }
        let groups = resources.filter { ["room", "zone"].contains($0.type) }.map { r -> SceneGroup in
            let serviceID = r.services?.first { $0.rtype == "grouped_light" }?.rid
            let service = resources.first { $0.id == serviceID }
            let active = resources.first { $0.type == "scene" && $0.group?.rid == r.id && ["static", "dynamic_palette"].contains($0.status?.active ?? "") }?.id
            return SceneGroup(id: r.id, name: r.metadata?.name ?? "Unnamed group", kind: r.type, serviceID: serviceID, brightness: service?.dimming?.brightness, isOn: service?.on?.on, activeSceneID: active)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return HomeSnapshot(groups: groups, scenes: scenes)
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
        return HomeSnapshot(groups: groups, scenes: scenes)
    }
}

// Provisional minimal v2 wire subset. Unknown resource kinds and absent capabilities are preserved.
// Confirm against the gated official reference before enabling real Bridge transport.
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
    private enum CodingKeys: String, CodingKey { case id, type, metadata, group, services, on, dimming, status }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode(String.self, forKey: .type)
        metadata = ["scene", "room", "zone"].contains(type) ? try values.decodeIfPresent(Metadata.self, forKey: .metadata) : nil
        group = type == "scene" ? try values.decodeIfPresent(Reference.self, forKey: .group) : nil
        services = ["room", "zone"].contains(type) ? try values.decodeIfPresent([Reference].self, forKey: .services) : nil
        on = type == "grouped_light" ? try values.decodeIfPresent(OnState.self, forKey: .on) : nil
        dimming = type == "grouped_light" ? try values.decodeIfPresent(Dimming.self, forKey: .dimming) : nil
        status = type == "scene" ? try values.decodeIfPresent(Status.self, forKey: .status) : nil
    }
    public struct Metadata: Decodable { public let name: String? }
    public struct Reference: Decodable { public let rid: String; public let rtype: String }
    public struct OnState: Decodable { public let on: Bool }
    public struct Dimming: Decodable { public let brightness: Double }
    public struct Status: Decodable { public let active: String? }
}
