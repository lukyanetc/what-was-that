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
        return (folder ?? .documentsDirectory).appending(path: "d-cal.json")
    }

    /// Короткое описание проблемы с файлом для показа пользователю.
    static func problemText(for error: Error) -> String {
        if (error as? CocoaError)?.code == .fileReadNoSuchFile { return "Файл данных скачивается из iCloud" }
        if error is DecodingError { return "Файл данных повреждён: записи не сохраняются" }
        return "Не удалось сохранить записи"
    }

    /// Время изменения файла (нужно, чтобы замечать правки с другого Mac, пришедшие через iCloud).
    var modificationDate: Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Ключ дня в локальном часовом поясе: "2026-03-10".
    static func key(for date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    /// Нет файла → пустой дневник. Битый файл → ошибка (чтобы не затереть его при сохранении).
    func load() throws -> [String: DayEntry] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path(percentEncoded: false)) else {
            // iCloud мог выгрузить файл с диска: остался «.d-cal.json.icloud». Пустой дневник тут вернуть нельзя, иначе
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
