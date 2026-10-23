import ServiceManagement

/// Start at login. The source of truth is the system status, not UserDefaults:
/// the user can turn the item off in "System Settings → General → Login Items".
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            print("Start at login not changed: \(error)")
        }
    }
}

extension DesktopController {
    /// Turns on start at login once, on first launch. After that the user's choice is left alone.
    func enableLoginItemOnFirstLaunch() {
        let key = "loginItemInitialized"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        LoginItem.set(true)
    }
}
