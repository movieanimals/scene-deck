import SwiftUI
import HueCore

struct LibraryView: View {
    @EnvironmentObject var store: SceneStore
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 216)
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.surface)
                if store.pausedAfterSleep { HStack { Label("Paused after sleep", systemImage: "pause.circle"); Spacer(); Button("Reconnect") { Task { await store.restoreConnection() } } }.padding().background(Theme.surface) }
                if store.simulatedOffline { Label("Demo Bridge offline. Restore the connection to use controls.", systemImage: "wifi.slash").foregroundColor(Theme.accent).font(.callout).padding().frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        if store.groups.isEmpty { emptyState }
                        ForEach(store.groups) { group in
                            VStack(alignment: .leading, spacing: 16) {
                                GroupHeader(group: group)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16)], spacing: 16) {
                                    ForEach(store.scenes(in: group.id)) { scene in SceneTile(scene: scene, active: group.activeSceneID == scene.id) }
                                }
                            }
                        }
                    }.padding(28)
                }
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundColor(Theme.accent)
                    Text(store.notice).lineLimit(1)
                    Spacer()
                    Text(store.isLive ? (store.controlsEnabled ? "HUE BRIDGE" : "SETUP · READ ONLY") : "LOCAL DEMO").font(.system(size: 10, weight: .semibold)).tracking(1.2)
                }.font(.system(size: 12)).foregroundColor(Theme.muted).padding(.horizontal, 28).padding(.vertical, 13).background(Theme.sidebar)
            }
        }.background(Theme.canvas).foregroundColor(Theme.ink)
            .frame(minWidth: 900, minHeight: 640)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $store.showConnection) { ConnectionView(connection: store.connection) }
            .sheet(isPresented: $store.showSceneEditor) { SceneEditorView() }
            .onAppear { AppDelegate.openLibrary = { openWindow(id: "library") } }
            .background(Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden())
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 25)).foregroundColor(Theme.accent)
                Text("Scene Deck").font(.system(size: 20, weight: .semibold, design: .rounded))
            }.padding(.top, 30).padding(.bottom, 34).padding(.horizontal, 20)
            nav("All scenes", icon: "square.grid.2x2", id: "all", count: store.home.scenes.count)
            nav("Favorites", icon: "star", id: "favorites", count: store.favoriteScenes.count)
            nav("Recently played", icon: "clock", id: "recent", count: store.recentScenes.count)
            Text("ROOMS").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundColor(Theme.muted).padding(.horizontal, 22).padding(.top, 32).padding(.bottom, 10)
            ForEach(store.home.groups.filter { $0.kind == "room" }) { group in nav(group.name, icon: group.icon, id: group.id) }
            Text("ZONES").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundColor(Theme.muted).padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 10)
            ForEach(store.home.groups.filter { $0.kind == "zone" }) { group in nav(group.name, icon: group.icon, id: group.id) }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label(store.isLive ? "Your Hue Bridge" : "Demo home", systemImage: "house").font(.system(size: 13, weight: .semibold))
                Text(store.isLive ? (store.controlsEnabled ? "Your scenes, connected.\nChanges stay in sync." : "Your scenes are connected.\nFinish setup to control lights.") : "Explore freely. Your lights\naren’t connected.").font(.system(size: 12)).foregroundColor(Theme.muted).lineSpacing(3)
                Button { store.showConnection = true } label: { HStack { Text(store.isLive ? "Bridge settings" : "Connect a Bridge"); Spacer(); Image(systemName: "arrow.right") }.font(.system(size: 12, weight: .medium)) }.buttonStyle(.plain).foregroundColor(Theme.accent).padding(.top, 4)
            }.padding(20)
        }.background(Theme.sidebar)
    }
    private func nav(_ title: String, icon: String, id: String, count: Int? = nil) -> some View {
        Button { store.selection = id; store.search = "" } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
                if let count { Text("\(count)").font(.system(size: 11)).foregroundColor(Theme.muted) }
            }.font(.system(size: 13, weight: store.selection == id ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 11)
                .foregroundColor(store.selection == id ? Theme.ink : Theme.muted)
                .background(store.selection == id ? Theme.surface : Color.clear).cornerRadius(8)
        }.buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 2).accessibilityAddTraits(store.selection == id ? .isSelected : [])
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.title).font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text("A different atmosphere, one click away.").font(.system(size: 13)).foregroundColor(Theme.muted)
                }
                Spacer()
                Button("Scene files & editor…") { store.edit() }.disabled(store.home.resources.isEmpty || store.pausedAfterSleep)
                Menu {
                    if !store.isLive {
                    Button("Simulate a Bridge event") { store.simulateExternalChange() }
                    Button(store.simulatedOffline ? "Restore demo connection" : "Simulate offline Bridge") { store.simulatedOffline.toggle() }
                    Button("Reset demo rooms") { store.reset() }
                    }
                    Divider()
                    Button("Reconnect") { Task { await store.restoreConnection() } }
                    Button("Connection setup…") { store.showConnection = true }
                } label: { Label(store.isLive ? "Bridge connected" : "Demo mode", systemImage: "circle.dotted").font(.system(size: 12)) }
                    .menuStyle(.borderlessButton).fixedSize().foregroundColor(Theme.accent).padding(.top, 9)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.muted)
                TextField("Find a scene or room", text: $store.search).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Search scenes")
                if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Clear search") }
                Text("⌘F").foregroundColor(Theme.muted).font(.system(size: 11))
            }.padding(10).background(Theme.surface).cornerRadius(8).frame(maxWidth: 350)
        }.padding(28)
    }
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: store.search.isEmpty ? "star" : "magnifyingglass").font(.system(size: 32)).foregroundColor(Theme.accent)
            Text(store.search.isEmpty ? (store.selection == "recent" ? "Your next scene starts here" : "Keep your best scenes close") : "No scenes found").font(.title2)
            Text(store.search.isEmpty ? (store.selection == "recent" ? "Scenes you play will appear here, most recent first." : "Star any scene to keep it here and in your menu bar.") : "Try another name, or clear your search.").foregroundColor(Theme.muted)
            Button(store.search.isEmpty ? "Browse all scenes" : "Clear search") { store.search = ""; if ["favorites", "recent"].contains(store.selection) { store.selection = "all" } }
        }.frame(maxWidth: .infinity).padding(.vertical, 90)
    }
}

struct GroupHeader: View {
    @EnvironmentObject var store: SceneStore
    let group: SceneGroup
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: group.icon).foregroundColor(Theme.muted).font(.system(size: 19))
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).font(.system(size: 17, weight: .semibold))
                Text(group.isOn == false ? "Lights off" : group.activeSceneID.flatMap { id in store.home.scenes.first { $0.id == id }?.name } ?? "Custom lighting").font(.system(size: 11)).foregroundColor(Theme.muted)
            }
            Spacer(minLength: 16)
            if let level = group.brightness {
                Image(systemName: "sun.max").foregroundColor(Theme.muted)
                GroupBrightnessSlider(group: group, level: level).frame(width: 110)
                Text("\(Int(level))%").monospacedDigit().font(.system(size: 12)).foregroundColor(Theme.muted).frame(width: 34, alignment: .trailing)
            }
            if let on = group.isOn {
                Button { store.power(group) } label: { Image(systemName: "power").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28).background(on ? Theme.accent : Theme.surface).foregroundColor(on ? Theme.canvas : Theme.muted).clipShape(Circle()) }.buttonStyle(.plain).accessibilityLabel("Turn \(group.name) \(on ? "off" : "on")").help("Turn \(group.name) \(on ? "off" : "on")").disabled(store.controlsDisabled)
            }
        }
    }
}

struct SceneTile: View {
    @EnvironmentObject var store: SceneStore
    let scene: LightScene
    let active: Bool
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { store.activate(scene) } label: {
                ZStack(alignment: .bottomLeading) {
                    SceneArtwork(colors: scene.colors).frame(height: 115)
                    if active { Label("Active", systemImage: "checkmark.circle.fill").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 5).background(Color.black.opacity(0.65)).cornerRadius(6).padding(10) }
                    if hovered && !active { Image(systemName: "play.fill").font(.system(size: 17)).padding(10).background(Color.black.opacity(0.45)).clipShape(Circle()).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(store.controlsDisabled).accessibilityLabel("Activate \(scene.name) in \(store.home.groups.first { $0.id == scene.groupID }?.name ?? "room")").help("Activate \(scene.name)")
            HStack(spacing: 6) {
                Button { store.activate(scene) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(scene.name).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                        Text(scene.detail).font(.system(size: 10)).foregroundColor(Theme.muted).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(store.controlsDisabled)
                Button { store.favorite(scene) } label: { Image(systemName: store.favorites.contains(scene.id) ? "star.fill" : "star").font(.system(size: 13)).foregroundColor(store.favorites.contains(scene.id) ? Theme.accent : Theme.muted).frame(width: 28, height: 32) }.buttonStyle(.plain).accessibilityLabel("\(store.favorites.contains(scene.id) ? "Unfavorite" : "Favorite") \(scene.name)")
            }.padding(12)
        }.background(Theme.surface).cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(active ? Theme.accent : Color.clear, lineWidth: 1.5))
            .onHover { hovered = $0 }
            .contextMenu {
                Button("Play scene") { store.activate(scene) }.disabled(store.controlsDisabled)
                Button(store.favorites.contains(scene.id) ? "Remove favorite" : "Add favorite") { store.favorite(scene) }
                Divider()
                Button("Edit / export scene…") { store.edit(scene) }.disabled(store.pausedAfterSleep)
                Button("Duplicate scene…") { store.edit(scene, duplicate: true) }.disabled(store.pausedAfterSleep)
            }
    }
}

struct GroupBrightnessSlider: View {
    @EnvironmentObject var store: SceneStore
    let group: SceneGroup
    let level: Double
    @State private var draft: Double?
    var body: some View {
        Slider(value: Binding(get: { draft ?? level }, set: { draft = $0 }), in: 0...100, step: 1, onEditingChanged: { editing in
            if !editing, let value = draft { store.brightness(group, value); draft = nil }
        }).tint(Theme.accent).accessibilityLabel("\(group.name) brightness").disabled(store.controlsDisabled || group.isOn == false)
    }
}
