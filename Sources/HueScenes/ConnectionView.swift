import SwiftUI

struct ConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: SceneStore
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
                    Task { if let (snapshot, client) = await connection.pairAndRead() { store.connect(snapshot: snapshot, client: client) } }
                }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(!connection.canPair)
            }
            if connection.paired && !store.controlsEnabled {
                Text("Ready to use your lights? Scene clicks will activate scenes and brightness sliders will adjust their room or zone.").font(.callout).foregroundColor(Theme.muted)
                Button("Finish setup & enable controls") { store.finishSetup() }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            Text("Uses the approved, app-scoped OpenHue certificate roots. The Bridge key stays in your Mac’s Keychain. No account or cloud service is needed.").font(.system(size: 11)).foregroundColor(Theme.muted).lineSpacing(3)
        }.padding(32).frame(width: 480).background(Theme.canvas).foregroundColor(Theme.ink).preferredColorScheme(.dark).interactiveDismissDisabled(connection.busy || connection.hasPendingSave)
    }
}
