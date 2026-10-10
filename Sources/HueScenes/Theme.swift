import SwiftUI

enum Theme {
    static let canvas = Color(hex: "14151A")
    static let sidebar = Color(hex: "191B22")
    static let surface = Color(hex: "23252E")
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
            ZStack {
                LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .bottomLeading, endPoint: .topTrailing)
                Circle().fill(Color(hex: colors.last ?? "FFFFFF").opacity(0.5))
                    .frame(width: geo.size.width * 0.76, height: geo.size.width * 0.76)
                    .offset(x: geo.size.width * 0.27, y: -geo.size.height * 0.26)
                Ellipse().fill(Color(hex: colors.first ?? "000000").opacity(0.48))
                    .frame(width: geo.size.width * 1.7, height: geo.size.height * 0.85)
                    .rotationEffect(.degrees(-19)).offset(x: -geo.size.width * 0.25, y: geo.size.height * 0.48)
                Ellipse().fill(Color(hex: colors[colors.count / 2]).opacity(0.45))
                    .frame(width: geo.size.width * 1.5, height: geo.size.height * 0.6)
                    .rotationEffect(.degrees(16)).offset(x: geo.size.width * 0.22, y: geo.size.height * 0.48)
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
        }.accessibilityHidden(true)
    }
}
