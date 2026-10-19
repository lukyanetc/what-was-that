import Foundation

/// Apple Notes через AppleScript (у Notes нет ссылок на заметки). Скрипты идут через `osascript` в фоне:
/// пока macOS спрашивает разрешение на управление Notes или Notes запускается, лента не зависает.
enum AppleNotes {
    /// В поле `note` записи дня ссылка на заметку Notes хранится с этим префиксом, дальше идёт id заметки.
    static let prefix = "apple-notes-id:"

    /// Находит заметку с таким именем в папке (папка и заметка создаются, если их нет), показывает её и возвращает id.
    static func openOrCreate(name: String, folder: String) async -> String? {
        let name = escaped(name), folder = escaped(folder)
        return await run("""
        tell application "Notes"
            if "\(folder)" is "" then
                set targetFolder to default folder of default account
            else
                if not (exists folder "\(folder)") then make new folder with properties {name:"\(folder)"}
                set targetFolder to folder "\(folder)"
            end if
            set found to (notes of targetFolder whose name is "\(name)")
            if (count of found) > 0 then
                set theNote to item 1 of found
            else
                set theNote to make new note at targetFolder with properties {body:"<div><h1>\(name)</h1></div>"}
            end if
            show theNote
            activate
            return id of theNote
        end tell
        """)
    }

    /// Показывает заметку по id.
    static func show(id: String) async {
        _ = await run("""
        tell application "Notes"
            show note id "\(escaped(id))"
            activate
        end tell
        """)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Выполняет скрипт; nil, если он завершился ошибкой (например, нет разрешения).
    private static func run(_ script: String) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do { try process.run() } catch { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
