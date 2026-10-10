import SwiftUI
import AppKit

@main struct SceneDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = SceneStore()
    var body: some Scene {
        Window("Scene Deck", id: "library") {
            LibraryView().environmentObject(store)
        }.defaultSize(width: 1120, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Demo") {
                Button("Simulate Bridge event") { store.simulateExternalChange() }
                Button("Reset demo rooms") { store.reset() }
                Button("Connection setup…") { store.showConnection = true }
            }
        }
        MenuBarExtra("Scene Deck", systemImage: "circle.hexagongrid.fill") {
            MenuView().environmentObject(store)
        }.menuBarExtraStyle(.window)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 {
            let path = args[index + 1]
            let capture = {
                guard let window = NSApp.windows.first(where: { $0.title == "Scene Deck" }), let view = window.contentView else { NSApp.terminate(nil); return }
                window.setContentSize(NSSize(width: 1120, height: 820))
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
                NSApp.terminate(nil)
            }
            if args.contains("--connect-saved") {
                NotificationCenter.default.addObserver(forName: Notification.Name("SceneDeckInventoryReady"), object: nil, queue: .main) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: capture) }
            } else { DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: capture) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
