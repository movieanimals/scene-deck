import SwiftUI

struct ConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: SceneStore
    @State private var confirmRemove = false
    @ObservedObject var connection: BridgeConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Group {
            HStack {
                Image(systemName: "network").font(.system(size: 30)).foregroundColor(Theme.accent)
                Spacer()
                Button("Done") { dismiss() }.disabled(connection.busy || connection.hasPendingSave)
            }
            Text("Your Bridge. Your scenes.").font(.system(size: 27, weight: .semibold, design: .rounded))
            Text("Connect securely and bring in the scenes you already have. Read your library first, then finish setup to enable your scene and brightness controls.").foregroundColor(Theme.muted).lineSpacing(3)
            Button("Find my Bridge") { Task { await connection.discover() } }.disabled(connection.busy || connection.paired || connection.hasPendingSave)
            VStack(alignment: .leading, spacing: 8) {
                if !connection.savedBridges.isEmpty {
                    Picker("Saved Bridge", selection: Binding(get: { connection.bridgeID }, set: { connection.selectSavedBridge($0) })) {
                        Text("Choose saved access").tag("")
                        ForEach(connection.savedBridges) { Text("\($0.id) · \($0.internalipaddress)").tag($0.id) }
                    }
                    Text("Selecting a Bridge does not connect. Choose Reconnect when ready.").font(.caption).foregroundColor(Theme.muted)
                }
                if connection.discovered.count > 1 {
                    Picker("Discovered Bridge", selection: Binding(get: { connection.bridgeID }, set: { connection.selectDiscovered($0) })) {
                        Text("Select a Bridge").tag("")
                        ForEach(connection.discovered) { Text("\($0.id) · \($0.internalipaddress)").tag($0.id) }
                    }
                }
                Text("Bridge address").font(.caption)
                TextField("192.0.2.1", text: $connection.host)
                Text("Bridge ID").font(.caption)
                TextField("16-character Bridge ID", text: $connection.bridgeID)
            }.textFieldStyle(.roundedBorder).disabled(connection.busy || connection.hasPendingSave || connection.paired)
            Button("Verify secure connection") { Task { await connection.verify() } }.disabled(connection.busy || connection.hasPendingSave || connection.paired)
            if !connection.paired && connection.hasSavedEndpoint {
                Button("Reconnect using this Mac’s Keychain") { Task { await store.restoreConnection() } }.disabled(connection.busy || connection.hasPendingSave)
            }
            }
            Divider()
            Label(connection.message, systemImage: connection.paired ? "checkmark.circle.fill" : "button.programmable").font(.system(size: 13)).foregroundColor(Theme.accent).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            if connection.busy { ProgressView().controlSize(.small) }
            if !connection.paired {
                Button(connection.hasPendingSave ? "Retry Keychain save" : "I pressed the Bridge button — Pair") {
                    if connection.hasPendingSave { connection.savePendingAccess(); return }
                    Task { if let (snapshot, client) = await connection.pairAndRead() { store.connect(snapshot: snapshot, client: client) } }
                }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(connection.busy || (!connection.hasPendingSave && !connection.canPair))
            }
            if connection.paired && !store.controlsEnabled {
                Text("Ready to use your lights? Scene clicks will activate scenes and brightness sliders will adjust their room or zone.").font(.callout).foregroundColor(Theme.muted)
                Button("Finish setup & enable controls") { store.finishSetup() }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            if connection.hasSavedEndpoint {
                Button("Reconnect") { Task { await store.restoreConnection() } }.disabled(connection.busy || connection.hasPendingSave || store.sending)
                if connection.paired || store.isLive {
                    Button("Disconnect / switch Bridge") { store.disconnectForSwitch() }.disabled(connection.busy || connection.hasPendingSave || store.sending)
                    Text("Disconnecting keeps this Mac’s saved keys and each Bridge’s preferences.").font(.caption).foregroundColor(Theme.muted)
                }
                Button("Forget this Mac’s saved access…", role: .destructive) { confirmRemove = true }.disabled(connection.busy || connection.hasPendingSave || store.sending)
            }
            Text("Uses the approved, app-scoped OpenHue certificate roots. The Bridge key stays in your Mac’s Keychain. No account is needed. Optional discovery uses Hue’s discovery service.").font(.system(size: 11)).foregroundColor(Theme.muted).lineSpacing(3)
        }.padding(32).frame(width: 480).background(Theme.canvas).foregroundColor(Theme.ink).preferredColorScheme(.dark).interactiveDismissDisabled(connection.busy || connection.hasPendingSave)
        .alert("Remove this Mac’s saved Bridge access?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove local access", role: .destructive) { store.removeLocalAccess() }
        } message: { Text("Scene Deck will need a new physical-button pairing on this Mac. Scenes and other devices are unchanged. This does not revoke keys stored on the Bridge.") }
    }
}
