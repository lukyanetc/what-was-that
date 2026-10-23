import Foundation

struct DayEntry: Codable, Equatable {
    var text: String
    /// Color of the round indicator at the start of the line: a number in `Appearance.indicatorColors`. Neighboring days of the same color merge into a period.
    var color: Int?
    /// Link to the day's note in a notes app (Obsidian, Apple Notes): opened by the arrow at the end of the line.
    var note: String?

    /// An entry without text, color and link is not stored in the file.
    var isEmpty: Bool { text.isEmpty && color == nil && note == nil }
}

/// The diary in a single JSON file: date ("2026-03-10") → entry.
struct DayStore {
    var url = DayStore.defaultURL

    /// Data file: in the folder chosen by the user (for example, in iCloud Drive), otherwise in Documents.
    static var defaultURL: URL {
        let folder = UserDefaults.standard.string(forKey: "dataFolder").map { URL(filePath: $0, directoryHint: .isDirectory) }
        return (folder ?? .documentsDirectory).appending(path: fileName)
    }

    static let fileName = "what-was-that.json"
    /// Previous file name (the app used to be called D-Cal).
    private static let legacyFileName = "d-cal.json"

    /// If the new file is not in the folder but the file under the previous name is, it is copied under the new name.
    /// The old one stays in place as a copy: you can delete it yourself.
    static func migrateLegacyFile(in folder: URL) {
        let manager = FileManager.default
        let new = folder.appending(path: fileName), old = folder.appending(path: legacyFileName)
        guard !manager.fileExists(atPath: new.path(percentEncoded: false)),
              manager.fileExists(atPath: old.path(percentEncoded: false)) else { return }
        try? manager.copyItem(at: old, to: new)
    }

    /// Short description of a file problem to show to the user.
    static func problemText(for error: Error) -> String {
        if (error as? CocoaError)?.code == .fileReadNoSuchFile { return "Data file is downloading from iCloud" }
        if error is DecodingError { return "Data file is corrupted: entries are not saved" }
        return "Could not save entries"
    }

    /// File modification time (needed to notice edits from another Mac that arrive through iCloud).
    var modificationDate: Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Keys of dates already computed. A feed row needs the day key several times per render (entry, arrow, indicator,
    /// events), and formatting a date costs noticeably more than a dictionary lookup. The time zone offset is part of the cache key:
    /// when the time zone changes, the previous values are not used.
    private struct CacheKey: Hashable {
        let date: Date
        let offset: Int
    }
    private static var keyCache: [CacheKey: String] = [:]

    /// Day key in the local time zone: "2026-03-10".
    static func key(for date: Date) -> String {
        let cacheKey = CacheKey(date: date, offset: TimeZone.current.secondsFromGMT(for: date))
        if let cached = keyCache[cacheKey] { return cached }
        let key = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        // Size limit: a three-year feed is about a thousand dates, anything else is stray requests.
        if keyCache.count > 5000 { keyCache.removeAll() }
        keyCache[cacheKey] = key
        return key
    }

    /// No file → empty diary. Corrupted file → error (so it is not overwritten on save).
    func load() throws -> [String: DayEntry] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path(percentEncoded: false)) else {
            // iCloud may have offloaded the file from disk, leaving ".what-was-that.json.icloud". An empty diary must not be returned here, otherwise
            // the next write would overwrite the real file. Ask the system to download it and treat this as an error for now.
            let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
            if manager.fileExists(atPath: placeholder.path(percentEncoded: false)) {
                try? manager.startDownloadingUbiquitousItem(at: url)
                throw CocoaError(.fileReadNoSuchFile)
            }
            return [:]
        }
        return try JSONDecoder().decode([String: DayEntry].self, from: Data(contentsOf: url))
    }

    /// Rereads the file, changes one day's text (the color is kept) and writes atomically.
    /// An entry with no text and no color is removed.
    func set(_ text: String, for key: String) throws {
        try update(key) { $0.text = text }
    }

    /// Same for the indicator color (nil removes it).
    func setColor(_ color: Int?, for key: String) throws {
        try update(key) { $0.color = color }
    }

    /// Same for the note link (nil removes it).
    func setNote(_ note: String?, for key: String) throws {
        try update(key) { $0.note = note }
    }

    private func update(_ key: String, _ change: (inout DayEntry) -> Void) throws {
        var days = try load()
        var entry = days[key] ?? DayEntry(text: "")
        change(&entry)
        days[key] = entry.isEmpty ? nil : entry
        try write(days)
    }

    private func write(_ days: [String: DayEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(days).write(to: url, options: .atomic)
    }
}
