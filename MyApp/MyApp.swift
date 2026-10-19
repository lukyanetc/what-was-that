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
        Picker("Режим", selection: Binding(get: { desktop.mode }, set: { desktop.mode = $0 })) {
            ForEach([Mode.solid, .scroll, .edit], id: \.self) { Text($0.rawValue) }
        }
        Picker("Отрезок", selection: Binding(
            get: { desktop.appearance.viewKind }, set: { desktop.appearance.viewKind = $0 })
        ) {
            ForEach(ViewKind.allCases, id: \.self) { Text($0.title) }
        }
        Button("Переместить окно") { desktop.mode = .move }
        Button("Настройки…") {
            openWindow(id: "settings")
            NSApp.activate()
            // Окно настроек (обычное, не лента) поверх остальных окон. Оно появляется не мгновенно, поэтому с паузой.
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                for window in NSApp.windows where window.title == "Настройки" {
                    window.level = .floating
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        Menu("Экспорт данных") {
            Button("JSON…") { Export.save(markdown: false) }
            Button("Markdown…") { Export.save(markdown: true) }
        }
        Button("Папка данных…") { Export.chooseDataFolder() }
        Button("Показать файл данных в Finder") { NSWorkspace.shared.activateFileViewerSelecting([DayStore.defaultURL]) }
        Menu("Настройки: файл") {
            Button("Экспорт настроек…") { desktop.appearance.exportSettings() }
            Button("Импорт настроек…") { desktop.appearance.importSettings() }
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
            SettingsView(appearance: delegate.desktop.appearance, events: delegate.desktop.events)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
