import SwiftUI
import UniformTypeIdentifiers

/// Settings in a single JSON file (export and import). All fields are optional: anything missing from the file is left unchanged on import.
/// Not included: selected calendars and window position (tied to this Mac and screen).
struct SettingsFile: Codable {
    var version: Int? = 1
    var viewKind: String?
    var color: String?
    var adapts: Bool?
    var textOpacity: Double?
    var width: Double?
    var edgeFade: Double?
    var periods: [Period]?
    var showsPeriodsInFeed: Bool?
    var showsPeriodCounter: Bool?
    /// Empty string means the default color.
    var highlight: String?
    var dateFormat: String?
    var showsMonth: Bool?
    var monthFormat: String?
    var monthBold: Bool?
    var uppercase: Bool?
    var fontName: String?
    var fontSize: Double?
    var rowPadding: Double?
    var showsWeekNumber: Bool?
    var weekGap: Bool?
    var eventsMode: String?
    var noteApp: String?
    var obsidianVault: String?
    var obsidianFolder: String?
    var obsidianFileFormat: String?
    var appleNotesFolder: String?
    var appleNotesFormat: String?
    var noteTemplate: String?
    var hotKeyCode: Int?
    var hotKeyModifiers: Int?
    var hotKeyLabel: String?
}

extension Appearance {
    /// Current settings as JSON.
    func settingsJSON() throws -> Data {
        let file = SettingsFile(
            viewKind: viewKind.rawValue, color: color.hex, adapts: adapts, textOpacity: textOpacity, width: width,
            edgeFade: edgeFade, periods: periods, showsPeriodsInFeed: showsPeriodsInFeed,
            showsPeriodCounter: showsPeriodCounter, highlight: highlight?.hex ?? "", dateFormat: dateFormat,
            showsMonth: showsMonth, monthFormat: monthFormat, monthBold: monthBold, uppercase: uppercase,
            fontName: fontName, fontSize: fontSize, rowPadding: rowPadding, showsWeekNumber: showsWeekNumber,
            weekGap: weekGap, eventsMode: eventsMode.rawValue, noteApp: noteApp.rawValue,
            obsidianVault: obsidianVault, obsidianFolder: obsidianFolder, obsidianFileFormat: obsidianFileFormat,
            appleNotesFolder: appleNotesFolder, appleNotesFormat: appleNotesFormat, noteTemplate: noteTemplate,
            hotKeyCode: hotKeyCode, hotKeyModifiers: hotKeyModifiers, hotKeyLabel: hotKeyLabel)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// Applies settings from JSON. Numbers are clamped to valid bounds, unknown values are skipped.
    func applySettings(_ data: Data) throws {
        let file = try JSONDecoder().decode(SettingsFile.self, from: data)
        if let value = file.viewKind.flatMap({ ViewKind(rawValue: $0) }) { viewKind = value }
        if let value = file.color.flatMap({ Color(hex: $0) }) { color = value }
        if let value = file.adapts { adapts = value }
        if let value = file.textOpacity { textOpacity = min(max(value, 0.2), 1) }
        if let value = file.width { width = min(max(value, Self.widthRange.lowerBound), Self.widthRange.upperBound) }
        if let value = file.edgeFade { edgeFade = min(max(value, 0), 150) }
        if let value = file.periods { periods = value }
        if let value = file.showsPeriodsInFeed { showsPeriodsInFeed = value }
        if let value = file.showsPeriodCounter { showsPeriodCounter = value }
        if let value = file.highlight { highlight = Color(hex: value) }
        if let value = file.dateFormat { dateFormat = value }
        if let value = file.showsMonth { showsMonth = value }
        if let value = file.monthFormat { monthFormat = value }
        if let value = file.monthBold { monthBold = value }
        if let value = file.uppercase { uppercase = value }
        if let value = file.fontName, value == Self.systemFont || Self.fonts.contains(value) { fontName = value }
        if let value = file.fontSize {
            fontSize = min(max(value, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        }
        if let value = file.rowPadding {
            rowPadding = min(max(value, Self.rowPaddingRange.lowerBound), Self.rowPaddingRange.upperBound)
        }
        if let value = file.showsWeekNumber { showsWeekNumber = value }
        if let value = file.weekGap { weekGap = value }
        if let value = file.eventsMode.flatMap({ EventsMode(rawValue: $0) }) { eventsMode = value }
        if let value = file.noteApp.flatMap({ NoteApp(rawValue: $0) }) { noteApp = value }
        if let value = file.obsidianVault { obsidianVault = value }
        if let value = file.obsidianFolder { obsidianFolder = value }
        if let value = file.obsidianFileFormat { obsidianFileFormat = value }
        if let value = file.appleNotesFolder { appleNotesFolder = value }
        if let value = file.appleNotesFormat { appleNotesFormat = value }
        if let value = file.noteTemplate { noteTemplate = value }
        if let code = file.hotKeyCode, let modifiers = file.hotKeyModifiers, let label = file.hotKeyLabel, modifiers != 0 {
            setHotKey(code: code, modifiers: modifiers, label: label)
        }
    }

    /// Save dialog and writing the settings file (menu item).
    func exportSettings() {
        NSApp.activate()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "what-was-that-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settingsJSON().write(to: url, options: .atomic)
        } catch {
            Export.alert("Could not save the settings", error.localizedDescription)
        }
    }

    /// Open dialog and applying the settings (menu item).
    func importSettings() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try applySettings(Data(contentsOf: url))
        } catch {
            Export.alert("Could not load the settings", "The file doesn't look like what was that!? settings.")
        }
    }
}
