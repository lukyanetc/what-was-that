import AppKit

/// Проверка обновлений через GitHub Releases: последний релиз репозитория сравнивается с текущей версией.
/// Ничего не скачивает и не устанавливает: при новой версии открывается страница релиза. Запрос уходит только по кнопке
/// «Check for Updates…» или при запуске (если включено, не чаще раза в сутки); в запросе нет ничего о пользователе.
@MainActor
final class UpdateChecker {
    enum Outcome: Equatable {
        case upToDate(current: String)
        case available(version: String, page: URL)
        case failed
    }

    private static let endpoint = URL(string: "https://api.github.com/repos/lukyanetc/what-was-that/releases/latest")
    private static let launchInterval: TimeInterval = 24 * 60 * 60

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Число компонентов версии: «v1.2.10» → [1, 2, 10]; нечисловой хвост («-beta») отбрасывается.
    nonisolated static func components(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// Версия `remote` новее `local` (недостающие компоненты считаются нулями: 1.2 и 1.2.0 равны).
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = components(remote), b = components(local)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    /// Тег и страница релиза из ответа GitHub.
    nonisolated static func parse(_ data: Data) -> (tag: String, page: URL)? {
        (try? JSONDecoder().decode(Release.self, from: data)).map { ($0.tag_name, $0.html_url) }
    }

    func check() async -> Outcome {
        guard let url = Self.endpoint else { return .failed }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = Self.parse(data) else { return .failed }
        return Self.isNewer(release.tag, than: Self.currentVersion)
            ? .available(version: release.tag, page: release.page)
            : .upToDate(current: Self.currentVersion)
    }

    /// Кнопка «Check for Updates…»: всегда отвечает окном.
    func checkManually() {
        Task { show(await check(), isManual: true) }
    }

    /// Проверка при запуске: не чаще раза в сутки, через несколько секунд после старта, и молчит, если новостей нет.
    func checkAtLaunch() async {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > Self.launchInterval else { return }
        try? await Task.sleep(for: .seconds(5))
        let outcome = await check()
        if outcome != .failed { defaults.set(Date.now, forKey: "lastUpdateCheck") }
        show(outcome, isManual: false)
    }

    private func show(_ outcome: Outcome, isManual: Bool) {
        let alert = NSAlert()
        switch outcome {
        case .available(let version, let page):
            // При запуске об одной и той же версии напоминаем один раз.
            let defaults = UserDefaults.standard
            if !isManual {
                guard defaults.string(forKey: "lastNotifiedVersion") != version else { return }
                defaults.set(version, forKey: "lastNotifiedVersion")
            }
            alert.messageText = "Version \(version) is available"
            alert.informativeText = "You have \(Self.currentVersion)."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
        case .upToDate(let current):
            guard isManual else { return }
            alert.messageText = "You're up to date"
            alert.informativeText = "Version \(current) is the latest."
            NSApp.activate()
            alert.runModal()
        case .failed:
            guard isManual else { return }
            alert.messageText = "Could not check for updates"
            alert.informativeText = "Check your connection or try again later."
            NSApp.activate()
            alert.runModal()
        }
    }
}
