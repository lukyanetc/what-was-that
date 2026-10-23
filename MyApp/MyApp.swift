import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let desktop = DesktopController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        desktop.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        desktop.flushPending?()
    }
}

private struct MenuContent: View {
    let desktop: DesktopController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Modes and views go straight into the menu (no drop-down lists), the current one has a checkmark. The title shows the hotkey hint.
        // Headings are plain strings, not Section or Picker: those draw separators around their own items.
        Text("Mode · \(desktop.appearance.hotKeyLabel), Esc → locked")
        ForEach(Mode.allCases, id: \.self) { mode in
            Toggle(mode.rawValue, isOn: Binding(get: { desktop.mode == mode }, set: { _ in desktop.mode = mode }))
        }
        Divider()
        Text("View")
        ForEach(ViewKind.allCases, id: \.self) { kind in
            Toggle(kind.title, isOn: Binding(
                get: { desktop.appearance.viewKind == kind }, set: { _ in desktop.appearance.viewKind = kind }))
        }
        Divider()
        Menu("Data") {
            Button("Export as JSON…") { Export.save(markdown: false) }
            Button("Export as Markdown…") { Export.save(markdown: true) }
            Divider()
            Button("Data Folder…") { Export.chooseDataFolder() }
            Button("Show File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([DayStore.defaultURL]) }
        }
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate()
            // When invoked, the settings window comes to the front and then behaves like a normal window (the level does not change).
            // It does not appear instantly, hence the delay.
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                for window in NSApp.windows where window.title == "what was that!? - settings" {
                    // The window opens on the Space where it was invoked instead of staying on the previous one.
                    window.collectionBehavior.insert(.moveToActiveSpace)
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
        Button("Check for Updates…") { desktop.updates.checkManually() }
        Divider()
        Button("Quit what was that!?") { NSApp.terminate(nil) }
    }
}

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        // Menu bar icon: a custom template image (18 and 36 px); macOS tints it for the light or dark menu bar.
        MenuBarExtra("what was that!?", image: "MenuBarIcon") {
            MenuContent(desktop: delegate.desktop)
        }
        Window("what was that!? - settings", id: "settings") {
            SettingsView(desktop: delegate.desktop)
        }
        .windowResizability(.contentSize)
        // The settings window can be dragged by any free area (tab strip, background), not only by the title bar.
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.suppressed)
    }
}
