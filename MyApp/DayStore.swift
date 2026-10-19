import Foundation

struct DayEntry: Codable, Equatable {
    var text: String
    /// Цвет круглого индикатора в начале строки: номер в `Appearance.indicatorColors`. Соседние дни одного цвета сливаются в период.
    var color: Int?
    /// Ссылка на заметку дня в заметочнике (Obsidian, Apple Notes): открывается стрелкой в конце строки.
    var note: String?

    /// Запись без текста, цвета и ссылки в файле не хранится.
    var isEmpty: Bool { text.isEmpty && color == nil && note == nil }
}

/// Дневник в одном JSON-файле: дата ("2026-03-10") → запись.
struct DayStore {
    var url = DayStore.defaultURL

    /// Файл данных: в папке, выбранной пользователем (например, в iCloud Drive), иначе в «Документах».
    static var defaultURL: URL {
        let folder = UserDefaults.standard.string(forKey: "dataFolder").map { URL(filePath: $0, directoryHint: .isDirectory) }
        return (folder ?? .documentsDirectory).appending(path: fileName)
    }

    static let fileName = "what-was-that.json"
    /// Прежнее имя файла (приложение называлось D-Cal).
    private static let legacyFileName = "d-cal.json"

    /// Если нового файла в папке нет, а файл под прежним именем есть, он копируется под новым именем.
    /// Прежний остаётся на месте как копия: удалять его вы можете сами.
    static func migrateLegacyFile(in folder: URL) {
        let manager = FileManager.default
        let new = folder.appending(path: fileName), old = folder.appending(path: legacyFileName)
        guard !manager.fileExists(atPath: new.path(percentEncoded: false)),
              manager.fileExists(atPath: old.path(percentEncoded: false)) else { return }
        try? manager.copyItem(at: old, to: new)
    }

    /// Короткое описание проблемы с файлом для показа пользователю.
    static func problemText(for error: Error) -> String {
        if (error as? CocoaError)?.code == .fileReadNoSuchFile { return "Data file is downloading from iCloud" }
        if error is DecodingError { return "Data file is corrupted: entries are not saved" }
        return "Could not save entries"
    }

    /// Время изменения файла (нужно, чтобы замечать правки с другого Mac, пришедшие через iCloud).
    var modificationDate: Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Ключи уже посчитанных дат. Ключ дня нужен строке ленты по нескольку раз за отрисовку (запись, стрелка, индикатор,
    /// события), а форматирование даты стоит заметно дороже поиска в словаре. Смещение пояса входит в ключ кэша:
    /// при смене часового пояса прежние значения не используются.
    private struct CacheKey: Hashable {
        let date: Date
        let offset: Int
    }
    private static var keyCache: [CacheKey: String] = [:]

    /// Ключ дня в локальном часовом поясе: "2026-03-10".
    static func key(for date: Date) -> String {
        let cacheKey = CacheKey(date: date, offset: TimeZone.current.secondsFromGMT(for: date))
        if let cached = keyCache[cacheKey] { return cached }
        let key = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        // Ограничение размера: лента на три года это порядка тысячи дат, остальное случайные запросы.
        if keyCache.count > 5000 { keyCache.removeAll() }
        keyCache[cacheKey] = key
        return key
    }

    /// Нет файла → пустой дневник. Битый файл → ошибка (чтобы не затереть его при сохранении).
    func load() throws -> [String: DayEntry] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path(percentEncoded: false)) else {
            // iCloud мог выгрузить файл с диска: остался «.what-was-that.json.icloud». Пустой дневник тут вернуть нельзя, иначе
            // следующая запись затёрла бы настоящий файл. Просим систему скачать его и пока считаем это ошибкой.
            let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
            if manager.fileExists(atPath: placeholder.path(percentEncoded: false)) {
                try? manager.startDownloadingUbiquitousItem(at: url)
                throw CocoaError(.fileReadNoSuchFile)
            }
            return [:]
        }
        return try JSONDecoder().decode([String: DayEntry].self, from: Data(contentsOf: url))
    }

    /// Перечитывает файл, меняет текст одного дня (цвет сохраняется) и пишет атомарно.
    /// Запись без текста и без цвета удаляется.
    func set(_ text: String, for key: String) throws {
        try update(key) { $0.text = text }
    }

    /// То же для цвета индикатора (nil убирает его).
    func setColor(_ color: Int?, for key: String) throws {
        try update(key) { $0.color = color }
    }

    /// То же для ссылки на заметку (nil убирает её).
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
