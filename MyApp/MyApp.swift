import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let desktop = DesktopController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        desktop.start()
    }
}

private struct MenuContent: View {
    let desktop: DesktopController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Picker("Режим", selection: Binding(get: { desktop.mode }, set: { desktop.mode = $0 })) {
            ForEach([Mode.solid, .scroll, .edit], id: \.self) { Text($0.rawValue) }
        }
        Button("Переместить окно") { desktop.mode = .move }
        Button("Настройки…") {
            openWindow(id: "settings")
            NSApp.activate()
        }
        Button("Выход") { NSApp.terminate(nil) }
    }
}

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("D-Cal", systemImage: "calendar") {
            MenuContent(desktop: delegate.desktop)
        }
        Window("Настройки", id: "settings") {
            SettingsView(appearance: delegate.desktop.appearance)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
