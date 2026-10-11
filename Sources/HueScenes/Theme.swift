import SwiftUI

enum Theme {
    static let canvas = Color(hex: "14151A")
    static let sidebar = Color(hex: "191B22")
    static let surface = Color(hex: "23252E")
    static let elevated = Color(hex: "2C303B")
    static let line = Color.white.opacity(0.10)
    static let ink = Color(hex: "F5F2EA")
    static let muted = Color(hex: "A6A9B5")
    static let accent = Color(hex: "F4BF78")
}
extension Color {
    init(hex: String) {
        let number = UInt64(hex, radix: 16) ?? 0
        self.init(.sRGB, red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255, opacity: 1)
    }
}
struct SceneArtwork: View {
    let colors: [String]
    var body: some View {
        GeometryReader { geo in
            if colors.isEmpty {
                ZStack {
                    Theme.elevated
                    Image(systemName: "lightbulb.2").font(.system(size: 26, weight: .light)).foregroundColor(Theme.muted)
                }
            } else {
                let palette = colors.map { Color(hex: $0) }
                ZStack {
                    LinearGradient(colors: palette, startPoint: .bottomLeading, endPoint: .topTrailing)
                    Ellipse().fill(palette.last!.opacity(0.68))
                        .frame(width: geo.size.width * 1.2, height: geo.size.height * 1.65)
                        .rotationEffect(.degrees(-24)).offset(x: geo.size.width * 0.24, y: -geo.size.height * 0.35)
                    Ellipse().fill(palette.first!.opacity(0.60))
                        .frame(width: geo.size.width * 1.55, height: geo.size.height * 0.8)
                        .rotationEffect(.degrees(-15)).offset(x: -geo.size.width * 0.17, y: geo.size.height * 0.49)
                    LinearGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }.frame(width: geo.size.width, height: geo.size.height).clipped()
            }
        }.accessibilityHidden(true)
    }
}
struct RefreshScenesButton: View {
    @EnvironmentObject var store: SceneStore
    var compact = false
    var body: some View {
        Button {
            if store.bridgeAuthorizationRequired { Task { await store.restoreConnection() } }
            else { store.refreshScenes() }
        } label: {
            Label(store.bridgeAuthorizationRequired ? "Reconnect" : store.refreshing ? "Refreshing…" : "Refresh scenes", systemImage: "arrow.clockwise")
                .labelStyle(.titleAndIcon)
                .font(.system(size: compact ? 11 : 12, weight: .medium))
        }.disabled(store.bridgeAuthorizationRequired ? store.connection.busy || store.sending : !store.canRefresh)
            .help(store.bridgeAuthorizationRequired ? "Check this Mac’s saved Bridge access" : store.pausedAfterSleep ? "Choose Reconnect after sleep" : "Reload scenes saved on the Bridge (⌘R)")
    }
}
