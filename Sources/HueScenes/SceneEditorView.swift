import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HueCore

struct SceneEditorView: View {
    @EnvironmentObject var store: SceneStore
    @Environment(\.dismiss) private var dismiss
    @State private var document = PortableScene(name: "New scene", groupLabel: "Room", lights: [])
    @State private var mapping: [String: String] = [:]
    @State private var groupID = ""
    @State private var sourceSceneID = ""
    @State private var editingID: String?
    @State private var original: SceneEditSnapshot?
    @State private var loaded = false
    @State private var message = "Import a Scene Deck JSON file, load a static Bridge scene, or start from your current lights."
    @State private var preview: Preview?
    @State private var applying = false
    struct Preview: Identifiable { let id = UUID(); let document: PortableScene; let groupID: String; let mapping: [String: String]; let editingID: String?; let bridgeID: String; let original: SceneEditSnapshot?; let summary: String }
    var catalog: SceneCatalog { SceneCatalog(store.home.resources) }
    var lights: [AvailableLight] { catalog.lights(in: groupID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Scene files & editor").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.disabled(applying) }
            Text("Local Scene Deck JSON · static on/off, brightness, color and warmth · no cloud upload").font(.caption).foregroundColor(.secondary)
            HStack {
                Picker("Room / zone", selection: $groupID) { ForEach(store.home.groups) { Text($0.name).tag($0.id) } }.disabled(editingID != nil)
                Button("New from current lights") { newDraft() }
                Button("Import file…") { importFile() }
            }.disabled(applying)
            HStack {
                Picker("Existing scene", selection: $sourceSceneID) { Text("Choose a scene").tag(""); ForEach(store.home.scenes.filter { $0.groupID == groupID }) { Text($0.name).tag($0.id) } }
                Button("Load for edit / export") { loadScene() }.disabled(sourceSceneID.isEmpty)
            }.disabled(applying)
            Divider()
            if loaded {
                TextField("Scene name (1–32 characters)", text: $document.name).textFieldStyle(.roundedBorder)
                HStack { Text(editingID == nil ? "Create a new scene" : "Editing an existing scene").font(.headline); Spacer(); if editingID != nil { Button("Save as a new scene instead") { editingID = nil; original = nil } } }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach($document.lights) { $lamp in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text(lamp.label).font(.headline)
                                    Spacer()
                                    Picker("Map to", selection: Binding(get: { mapping[lamp.slot] ?? "" }, set: { mapping[lamp.slot] = $0.isEmpty ? nil : $0 })) {
                                        Text("Choose this home’s light").tag("")
                                        ForEach(lights) { Text($0.name).tag($0.id) }
                                    }.frame(width: 300)
                                }
                                SceneStateEditor(state: $lamp.state)
                            }.padding(12).background(Theme.surface).cornerRadius(10)
                        }
                    }
                }.frame(minHeight: 170, maxHeight: 330)
                HStack {
                    Button("Export Scene Deck file…") { exportFile() }
                    Spacer()
                    Button("Preview changes…") { makePreview() }.buttonStyle(.borderedProminent).disabled(!store.controlsEnabled || store.pausedAfterSleep)
                }
            }
            Text(message).font(.callout).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if !store.controlsEnabled { Text("You can prepare and export files now. Finish Bridge setup to save scenes to the Bridge.").font(.caption).foregroundColor(Theme.accent) }
        }.padding(26).frame(width: 760).background(Theme.canvas).foregroundColor(Theme.ink).preferredColorScheme(.dark)
        .disabled(applying).interactiveDismissDisabled(applying)
        .onAppear { groupID = store.home.groups.first(where: { $0.id == store.selection })?.id ?? store.home.groups.first?.id ?? "" }
        .onChange(of: groupID) { _ in mapping = [:]; sourceSceneID = "" }
        .sheet(item: $preview) { p in
            VStack(alignment: .leading, spacing: 18) {
                Text(p.editingID == nil ? "Create this scene?" : "Replace this scene’s settings?").font(.title2.bold())
                ScrollView { Text(p.summary).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 360)
                Text("This saves the scene definition to the selected Bridge. It does not send a scene-recall command. Replacing a scene overwrites its supported static light settings.").font(.caption).foregroundColor(.secondary)
                HStack { Button("Back") { preview = nil }; Spacer(); Button(p.editingID == nil ? "Create scene on Bridge" : "Apply changes to scene") {
                    preview = nil; applying = true
                    Task {
                        do { try await store.saveSceneFile(p.document, groupID: p.groupID, mapping: p.mapping, replacing: p.editingID, expectedBridgeID: p.bridgeID, original: p.original, confirmed: true); message = "Scene saved. The library is refreshing."; editingID = nil; original = nil; loaded = false }
                        catch { message = error.localizedDescription }
                        applying = false
                    }
                }.buttonStyle(.borderedProminent) }
            }.padding(28).frame(width: 550).preferredColorScheme(.dark)
        }
    }
    func newDraft() { do { let result = try catalog.draft(groupID: groupID); document = result.0; mapping = result.1; editingID = nil; original = nil; loaded = true; message = "Edit values, review mappings, then preview. Nothing is saved yet." } catch { message = error.localizedDescription } }
    func loadScene() { do { let result = try catalog.editSnapshot(sceneID: sourceSceneID); document = result.document; original = result; mapping = result.mapping; editingID = sourceSceneID; loaded = true; message = "Supported static settings loaded. Export stays local; Bridge edits need preview and confirmation." } catch { message = error.localizedDescription } }
    func makePreview() {
        do {
            _ = try catalog.plan(document, groupID: groupID, mapping: mapping, replacing: editingID, original: original)
            let groupName = store.home.groups.first { $0.id == groupID }?.name ?? "Room"
            var portable = document; portable.groupLabel = groupName
            let rows = document.lights.map { lamp in "• \(lamp.label) → \(lights.first { $0.id == mapping[lamp.slot] }?.name ?? "Unavailable"): \(lamp.state.on ? "on" : "off"), \(lamp.state.brightness.map { "\(Int($0))%" } ?? "brightness unchanged")\(lamp.state.mirek.map { ", \($0) mirek" } ?? "")\(lamp.state.xy.map { ", color x=\($0.x), y=\($0.y)" } ?? "")" }
            preview = Preview(document: portable, groupID: groupID, mapping: mapping, editingID: editingID, bridgeID: store.activeBridgeID, original: original, summary: "\(document.name) · \(groupName)\n\n" + rows.joined(separator: "\n"))
        } catch { message = error.localizedDescription }
    }
    func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw SceneFileError.invalid("Choose a regular JSON file.") }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                let data = try file.read(upToCount: PortableScene.maxBytes + 1) ?? Data()
                document = try PortableScene.decode(data); mapping = [:]; editingID = nil; original = nil; loaded = true
                message = "Imported locally. Map every source light to an available light in your chosen room. No URLs or code are executed."
            } catch { message = (error as? SceneFileError)?.localizedDescription ?? "The file could not be read as a supported Scene Deck scene." }
        }
    }
    func exportFile() {
        do {
            let data = try document.encoded()
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Scene.scenedeck.json"
            guard let window = NSApp.keyWindow else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do { try data.write(to: url, options: .atomic); message = "Saved locally. The file includes scene/light labels and static states, but no credentials, Bridge IDs, or resource IDs." }
                catch { message = "The scene file could not be saved." }
            }
        } catch { message = error.localizedDescription }
    }
}
private struct SceneStateEditor: View {
    @Binding var state: SceneLightState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("On", isOn: $state.on).toggleStyle(.switch)
                Toggle("Set brightness", isOn: Binding(get: { state.brightness != nil }, set: { state.brightness = $0 ? 70 : nil }))
                if state.brightness != nil { Slider(value: Binding(get: { state.brightness ?? 70 }, set: { state.brightness = $0 }), in: 0...100, step: 1).frame(width: 130); Text("\(Int(state.brightness ?? 0))%").monospacedDigit() }
            }
            HStack {
                Picker("Color", selection: Binding(get: { state.xy != nil ? "xy" : state.mirek != nil ? "warmth" : "none" }, set: { mode in state.xy = mode == "xy" ? SceneXY(x: 0.3, y: 0.3) : nil; state.mirek = mode == "warmth" ? 300 : nil })) {
                    Text("Unchanged").tag("none"); Text("Warmth").tag("warmth"); Text("Color coordinates").tag("xy")
                }.frame(width: 260)
                if state.mirek != nil { Slider(value: Binding(get: { Double(state.mirek ?? 300) }, set: { state.mirek = Int($0) }), in: 153...500, step: 1).frame(width: 150); Text("\(state.mirek ?? 300) mirek").font(.caption) }
                if state.xy != nil {
                    Text("x"); TextField("x", value: Binding(get: { state.xy?.x ?? 0.3 }, set: { state.xy?.x = $0 }), format: .number).frame(width: 80)
                    Text("y"); TextField("y", value: Binding(get: { state.xy?.y ?? 0.3 }, set: { state.xy?.y = $0 }), format: .number).frame(width: 80)
                }
            }
        }.font(.callout)
    }
}
