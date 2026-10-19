import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Файл данных теперь лежит в другой папке: лента перечитывает его.
    static let dataFolderChanged = Notification.Name("dcal.dataFolderChanged")
}

/// Экспорт дневника в JSON или Markdown: все дни от первой записи, пустые тоже.
enum Export {
    /// День по ключу "yyyy-MM-dd".
    private static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Ключи всех дней от первой записи до последней или до сегодняшнего дня (что позже).
    static func days(_ entries: [String: DayEntry], today: Date = .now) -> [String] {
        let calendar = Calendar.current
        guard let first = entries.keys.min().flatMap(date) else { return [] }
        let last = max(entries.keys.max().flatMap(date) ?? first, calendar.startOfDay(for: today))
        var keys: [String] = []
        var day = first
        while day <= last {
            keys.append(DayStore.key(for: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return keys
    }

    /// Тот же формат, что у файла данных, но с каждым днём (у пустых дней текст пустой).
    static func json(_ entries: [String: DayEntry], today: Date = .now) throws -> Data {
        let all = Dictionary(uniqueKeysWithValues: days(entries, today: today).map { ($0, entries[$0] ?? DayEntry(text: "")) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(all)
    }

    /// Список «дата — текст»; пустой день это одна дата. Ссылка на заметку добавляется, если это обычная ссылка.
    static func markdown(_ entries: [String: DayEntry], today: Date = .now) -> String {
        days(entries, today: today).map { key in
            let entry = entries[key]
            var line = "- " + key
            if let text = entry?.text, !text.isEmpty {
                // Следующие строки дня стоят под первой с отступом, чтобы остаться в том же пункте списка.
                line += " — " + text.replacingOccurrences(of: "\n", with: "\n  ")
            }
            if let note = entry?.note, !note.hasPrefix(AppleNotes.prefix) { line += " [заметка](\(note))" }
            return line
        }.joined(separator: "\n") + "\n"
    }

    /// Окно сохранения и запись файла (пункт меню).
    static func save(markdown isMarkdown: Bool) {
        NSApp.activate()
        guard let entries = try? DayStore().load(), !entries.isEmpty else {
            alert("Нет данных для экспорта", "Файл данных пуст или его не удалось прочитать.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = isMarkdown ? "d-cal.md" : "d-cal-export.json"
        panel.allowedContentTypes = [isMarkdown ? UTType(filenameExtension: "md") ?? .plainText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = isMarkdown ? Data(markdown(entries).utf8) : try json(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            alert("Не удалось сохранить файл", error.localizedDescription)
        }
    }

    /// Выбор папки для файла данных (например, в iCloud Drive). Текущий файл копируется туда, а старый остаётся на месте.
    /// Если в выбранной папке уже лежит d-cal.json, берётся он.
    static func chooseDataFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Папка для файла d-cal.json (например, в iCloud Drive)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let current = DayStore.defaultURL
        let target = folder.appending(path: "d-cal.json")
        guard target.standardizedFileURL != current.standardizedFileURL else { return }
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path(percentEncoded: false)) {
            let alert = NSAlert()
            alert.messageText = "В этой папке уже есть d-cal.json"
            alert.informativeText = "Приложение будет работать с ним. Текущий файл останется на прежнем месте."
            alert.addButton(withTitle: "Использовать")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        } else if manager.fileExists(atPath: current.path(percentEncoded: false)) {
            do { try manager.copyItem(at: current, to: target) } catch {
                alert("Не удалось скопировать файл", error.localizedDescription)
                return
            }
        }
        UserDefaults.standard.set(folder.path(percentEncoded: false), forKey: "dataFolder")
        NotificationCenter.default.post(name: .dataFolderChanged, object: nil)
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
