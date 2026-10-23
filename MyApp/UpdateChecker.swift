import AppKit

/// Update check via GitHub Releases: the repository's latest release is compared with the current version.
/// It downloads and installs nothing: if there is a new version, the release page opens. A request is sent only on the
/// "Check for Updates…" button or at launch (if enabled, at most once a day); the request contains nothing about the user.
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

    /// Number of version components: "v1.2.10" → [1, 2, 10]; a non-numeric tail ("-beta") is dropped.
    nonisolated static func components(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// `remote` version is newer than `local` (missing components count as zeros: 1.2 and 1.2.0 are equal).
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

    /// Tag and release page from the GitHub response.
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

    /// "Check for Updates…" button: always answers with a window.
    func checkManually() {
        Task { show(await check(), isManual: true) }
    }

    /// Check at launch: at most once a day, a few seconds after start, and silent if there is nothing new.
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
            // At launch, remind about the same version only once.
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
