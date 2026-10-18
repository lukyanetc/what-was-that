import Foundation

struct DayEntry: Codable, Equatable {
    var text: String
    /// Цвет круглого индикатора в начале строки: номер в `Appearance.indicatorColors`. Соседние дни одного цвета сливаются в период.
    var color: Int?
}

/// Дневник в одном JSON-файле: дата ("2026-03-10") → запись.
struct DayStore {
    var url = URL.documentsDirectory.appending(path: "d-cal.json")

    /// Ключ дня в локальном часовом поясе: "2026-03-10".
    static func key(for date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    /// Нет файла → пустой дневник. Битый файл → ошибка (чтобы не затереть его при сохранении).
    func load() throws -> [String: DayEntry] {
        guard FileManager.default.fileExists(atPath: url.path()) else { return [:] }
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

    private func update(_ key: String, _ change: (inout DayEntry) -> Void) throws {
        var days = try load()
        var entry = days[key] ?? DayEntry(text: "")
        change(&entry)
        days[key] = entry.text.isEmpty && entry.color == nil ? nil : entry
        try write(days)
    }

    private func write(_ days: [String: DayEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(days).write(to: url, options: .atomic)
    }
}
