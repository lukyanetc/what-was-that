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
        // Режимы и виды сразу в меню (без выпадающих списков), у текущего галочка. В заголовке подсказка хоткея.
        // Заголовки это обычные строки, а не Section и не Picker: те сами рисуют разделители вокруг своих пунктов.
        Text("Mode · \(desktop.appearance.hotKeyLabel), Esc → locked")
        ForEach(Mode.allCases, id: \.self) { mode in
            Toggle(mode.rawValue.capitalized, isOn: Binding(get: { desktop.mode == mode }, set: { _ in desktop.mode = mode }))
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
            // При вызове окно настроек выходит поверх остальных, а дальше ведёт себя как обычное окно (уровень не меняется).
            // Оно появляется не мгновенно, поэтому с паузой.
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                for window in NSApp.windows where window.title == "what was that!? - settings" {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
        Button("Check for Updates…") { desktop.updates.checkManually() }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("What Was That!?", systemImage: "calendar") {
            MenuContent(desktop: delegate.desktop)
        }
        Window("what was that!? - settings", id: "settings") {
            SettingsView(desktop: delegate.desktop)
        }
        .windowResizability(.contentSize)
        // Окно настроек можно таскать за любое свободное место (полосу закладок, фон), а не только за заголовок.
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.suppressed)
    }
}
