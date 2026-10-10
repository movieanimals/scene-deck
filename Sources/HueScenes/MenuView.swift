import SwiftUI
import HueCore

struct MenuView: View {
    @EnvironmentObject var store: SceneStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Scene Deck").font(.system(size: 17, weight: .semibold, design: .rounded)); Spacer(); Text(store.isLive ? (store.controlsEnabled ? "HUE" : "SETUP") : "DEMO").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.accent) }
            Text("Your favorites, within reach.").font(.system(size: 11)).foregroundColor(Theme.muted)
            Divider()
            if store.favorites.isEmpty { Text("Star scenes in the library to keep them here.").font(.callout).foregroundColor(Theme.muted) }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.home.scenes.filter { store.favorites.contains($0.id) }) { scene in
                        Button { store.activate(scene) } label: {
                            HStack(spacing: 10) {
                                SceneArtwork(colors: scene.colors).frame(width: 38, height: 36).cornerRadius(6)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(scene.name).font(.system(size: 12, weight: .medium))
                                    Text(store.home.groups.first { $0.id == scene.groupID }?.name ?? "").font(.system(size: 10)).foregroundColor(Theme.muted)
                                }
                                Spacer()
                                if store.home.groups.first(where: { $0.id == scene.groupID })?.activeSceneID == scene.id { Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.accent) }
                            }.padding(5).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(store.controlsDisabled)
                    }
                }
            }.frame(maxHeight: 250)
            Divider()
            ForEach(store.home.groups.filter { $0.kind == "room" }) { group in
                HStack {
                    Text(group.name).font(.system(size: 11)).frame(width: 78, alignment: .leading)
                    if let level = group.brightness {
                        GroupBrightnessSlider(group: group, level: level)
                        Text("\(Int(level))%").font(.system(size: 10)).monospacedDigit().frame(width: 28)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open scene library") { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("o")
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Scene Deck").accessibilityLabel("Quit Scene Deck")
            }
        }.padding(20).frame(width: 310).background(Theme.canvas).foregroundColor(Theme.ink).preferredColorScheme(.dark)
    }
}
