import ServiceManagement

/// Автозапуск при входе в систему (Start at login). Источник истины — системный статус, а не UserDefaults:
/// пользователь может выключить пункт в «Системные настройки → Основные → Объекты входа».
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            print("Автозапуск не изменён: \(error)")
        }
    }
}

extension DesktopController {
    /// Включает автозапуск один раз, при первом запуске. Дальше выбор пользователя не трогается.
    func enableLoginItemOnFirstLaunch() {
        let key = "loginItemInitialized"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        LoginItem.set(true)
    }
}
