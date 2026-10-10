// swift-tools-version: 5.8
import PackageDescription
let package = Package(name: "HueScenes", platforms: [.macOS(.v13)], products: [.executable(name: "SceneDeck", targets: ["HueScenes"])], targets: [.target(name: "HueCore"), .executableTarget(name: "HueScenes", dependencies: ["HueCore"]), .testTarget(name: "HueCoreTests", dependencies: ["HueCore"])])
