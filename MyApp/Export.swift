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
            if let note = entry?.note, !note.hasPrefix(AppleNotes.prefix) { line += " [note](\(note))" }
            return line
        }.joined(separator: "\n") + "\n"
    }

    /// Окно сохранения и запись файла (пункт меню).
    static func save(markdown isMarkdown: Bool) {
        NSApp.activate()
        guard let entries = try? DayStore().load(), !entries.isEmpty else {
            alert("No data to export", "The data file is empty or could not be read.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = isMarkdown ? "what-was-that.md" : "what-was-that-export.json"
        panel.allowedContentTypes = [isMarkdown ? UTType(filenameExtension: "md") ?? .plainText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = isMarkdown ? Data(markdown(entries).utf8) : try json(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            alert("Could not save the file", error.localizedDescription)
        }
    }

    /// Выбор папки для файла данных (например, в iCloud Drive). Текущий файл копируется туда, а старый остаётся на месте.
    /// Если в выбранной папке уже лежит файл данных, берётся он.
    static func chooseDataFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Folder for the \(DayStore.fileName) file (for example, in iCloud Drive)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let current = DayStore.defaultURL
        // Файл под прежним именем в выбранной папке тоже подхватывается.
        DayStore.migrateLegacyFile(in: folder)
        let target = folder.appending(path: DayStore.fileName)
        guard target.standardizedFileURL != current.standardizedFileURL else { return }
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path(percentEncoded: false)) {
            let alert = NSAlert()
            alert.messageText = "This folder already contains \(DayStore.fileName)"
            alert.informativeText = "The app will use it. The current file stays where it is."
            alert.addButton(withTitle: "Use")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        } else if manager.fileExists(atPath: current.path(percentEncoded: false)) {
            do { try manager.copyItem(at: current, to: target) } catch {
                alert("Could not copy the file", error.localizedDescription)
                return
            }
        }
        UserDefaults.standard.set(folder.path(percentEncoded: false), forKey: "dataFolder")
        NotificationCenter.default.post(name: .dataFolderChanged, object: nil)
    }

    /// Окно с сообщением об ошибке (общее для экспорта, папки данных и файла настроек).
    static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
