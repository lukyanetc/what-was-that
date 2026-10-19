import SwiftUI

/// Окно настроек внешнего вида.
struct SettingsView: View {
    @Bindable var appearance: Appearance
    let events: CalendarEvents

    /// Подсказки по подключению заметочников лежат в репозитории (docs/NOTES.md).
    private static let notesGuide = URL(string: "https://github.com/lukyanetc/d-cal/blob/main/docs/NOTES.md")

    private static let datePresets = ["DD ddd", "ddd DD", "DD.MM", "DD.MM.YYYY", "MM/DD/YYYY", "YYYY-MM-DD"]
    private static let monthPresets = ["MMMM YYYY", "MMMM", "MMM YY", "YYYY-MM"]

    var body: some View {
        Form {
            Section("View") {
                Picker("Show", selection: $appearance.viewKind) {
                    ForEach(ViewKind.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
            }
            Section("My Ranges") {
                ForEach(appearance.periods) { period in
                    periodRow(period.id)
                }
                HStack {
                    Button("Add Range") {
                        let today = Calendar.current.startOfDay(for: .now)
                        let end = Calendar.current.date(byAdding: .day, value: 6, to: today) ?? today
                        appearance.periods.append(Period(name: "", start: today, end: end))
                    }
                    Spacer()
                    Button("Remove Expired") {
                        appearance.periods.removeAll { $0.isExpired(on: .now) }
                    }
                    .disabled(!appearance.periods.contains { $0.isExpired(on: .now) })
                }
                Toggle("Show ranges in the feed", isOn: $appearance.showsPeriodsInFeed)
                Toggle("Day counter under the title", isOn: $appearance.showsPeriodCounter)
                Text("The Range view shows only the days of the longest current range; shorter ones appear inside it. Month and Week views have no ranges; in the Feed they can be turned off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Calendar") {
                Picker("Events", selection: $appearance.eventsMode) {
                    ForEach(EventsMode.allCases, id: \.self) { Text($0.title) }
                }
                if events.isAuthorized {
                    ForEach(events.calendars, id: \.id) { calendar in
                        Toggle("\(calendar.title) (\(calendar.source))", isOn: Binding(
                            get: { appearance.eventCalendarIDs.contains(calendar.id) },
                            set: { isOn in
                                if isOn { appearance.eventCalendarIDs.insert(calendar.id) }
                                else { appearance.eventCalendarIDs.remove(calendar.id) }
                            }))
                    }
                } else {
                    Button("Allow Calendar Access") { Task { await events.requestAccess() } }
                }
                Text("Read-only. Google Calendar appears here if the account is added in System Settings (Internet Accounts).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Notes") {
                Picker("Notes app", selection: $appearance.noteApp) {
                    ForEach(NoteApp.allCases, id: \.self) { Text($0.title) }
                }
                switch appearance.noteApp {
                case .obsidian:
                    TextField("Vault", text: $appearance.obsidianVault)
                    TextField("Folder (optional)", text: $appearance.obsidianFolder)
                    TextField("File name", text: $appearance.obsidianFileFormat)
                    LabeledContent("Example") {
                        Text(MomentFormat.string(from: .now, pattern: appearance.obsidianFileFormat))
                    }
                    Text("In Edit mode, the arrow at the end of a row creates the day's note in Obsidian (if it doesn't exist) and opens it. After that the arrow opens the same note in Scroll and Edit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .appleNotes:
                    TextField("Folder (optional)", text: $appearance.appleNotesFolder)
                    TextField("Note name", text: $appearance.appleNotesFormat)
                    LabeledContent("Example") {
                        Text(MomentFormat.string(from: .now, pattern: appearance.appleNotesFormat))
                    }
                    Text("In Edit mode, the arrow at the end of a row creates the day's note in Notes (if it doesn't exist) and opens it. After that the arrow opens the same note in Scroll and Edit. The first time, macOS asks for permission to control Notes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .manual:
                    TextField("Link or file path template", text: $appearance.noteTemplate)
                    LabeledContent("Example") { Text(appearance.noteTemplateExample).lineLimit(1).truncationMode(.middle) }
                    Text("The date goes in like this: {YYYY-MM-DD}. Link: scheme://…, for example bear://x-callback-url/open-note?title={YYYY-MM-DD} (the note must already exist). File: a path starting with / or ~, for example ~/Notes/Daily/{YYYY-MM-DD}.md (if the file doesn't exist, it is created empty and opened in the default app).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let guide = Self.notesGuide {
                    Link("Guides for popular notes apps", destination: guide)
                }
            }
            Section("Text") {
                ColorPicker("Color", selection: $appearance.color, supportsOpacity: false)
                Toggle("Adapt to wallpaper", isOn: $appearance.adapts)
                Slider(value: $appearance.textOpacity, in: 0.2...1) { Text("Opacity") }
                Picker("Font", selection: $appearance.fontName) {
                    Text("System").tag(Appearance.systemFont)
                    ForEach(Appearance.fonts, id: \.self) { Text($0).tag($0) }
                }
                Slider(value: $appearance.fontSize, in: Appearance.fontSizeRange, step: 1) {
                    Text("Font size: \(Int(appearance.fontSize))")
                }
                Slider(value: $appearance.rowPadding, in: Appearance.rowPaddingRange, step: 1) {
                    Text("Row spacing: \(Int(appearance.rowPadding * 2))")
                }
                Toggle("Uppercase", isOn: $appearance.uppercase)
                Text(appearance.isMeasured
                     ? "Wallpaper under the feed: \(appearance.luminance < 0.5 ? "dark" : "light") (\(Int(appearance.luminance * 100))%)"
                     : "Couldn't measure the wallpaper; following the system appearance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Date Format") {
                formatField("Format", text: $appearance.dateFormat, presets: Self.datePresets)
                LabeledContent("Example") { Text(appearance.dayText(.now)) }
                Text("Like moment.js, date only: YYYY YY MMMM MMM MM M Do DD D dddd ddd dd E Q W w DDD. Text in [brackets] is shown as is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Month") {
                Toggle("Show month headings", isOn: $appearance.showsMonth)
                if appearance.showsMonth {
                    formatField("Format", text: $appearance.monthFormat, presets: Self.monthPresets)
                    Toggle("Bold", isOn: $appearance.monthBold)
                    LabeledContent("Example") { Text(appearance.monthText(.now)).bold(appearance.monthBold) }
                }
            }
            Section("Week") {
                Toggle("Week number on Mondays", isOn: $appearance.showsWeekNumber)
                Toggle("Larger gap between weeks", isOn: $appearance.weekGap)
            }
            Section("Window") {
                Slider(value: $appearance.width, in: Appearance.widthRange, step: 10) { Text("Width") }
                Slider(value: $appearance.edgeFade, in: 0...150, step: 5) { Text("Edge fade") }
            }
            Section("Today Highlight") {
                ColorPicker("Color and opacity",
                            selection: Binding(get: { appearance.highlightColor }, set: { appearance.highlight = $0 }))
            }
            Section("Settings File") {
                HStack {
                    Button("Export…") { appearance.exportSettings() }
                    Button("Import…") { appearance.importSettings() }
                }
                Text("All settings except the selected calendars and the window position, in one JSON file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    /// Строка отрезка: название, начало, конец, удаление. Истёкшие приглушены и зачёркнуты.
    private func periodRow(_ id: UUID) -> some View {
        // Привязка по id, а не по индексу: после удаления строка ещё раз читает своё значение, и индекс
        // выходил бы за границы массива (падение).
        let period = Binding<Period>(
            get: { appearance.periods.first { $0.id == id } ?? Period(id: id, name: "", start: .now, end: .now) },
            set: { value in
                if let index = appearance.periods.firstIndex(where: { $0.id == id }) { appearance.periods[index] = value }
            })
        let isExpired = period.wrappedValue.isExpired(on: .now)
        return VStack(alignment: .leading) {
            TextField("Name", text: period.name)
            HStack {
                DatePicker("Start", selection: Binding(
                    get: { period.wrappedValue.start },
                    set: {
                        period.wrappedValue.start = $0
                        // Конец не может быть раньше начала.
                        if period.wrappedValue.end < $0 { period.wrappedValue.end = $0 }
                    }), displayedComponents: .date)
                DatePicker("End", selection: period.end, in: period.wrappedValue.start..., displayedComponents: .date)
                Button("Delete", systemImage: "trash") {
                    appearance.periods.removeAll { $0.id == id }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            // Длинный период не помещается в окно: режим «Период» покажет вместо него обычную ленту.
            if !isExpired, appearance.estimatedHeight(of: period.wrappedValue)
                > appearance.periodRoom(screenHeight: Double(NSScreen.main?.frame.height ?? 0)) {
                Text("Doesn't fit in the window: the Range view will show the feed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .strikethrough(isExpired)
        .opacity(isExpired ? 0.5 : 1)
    }

    /// Поле формата и меню готовых шаблонов.
    private func formatField(_ title: String, text: Binding<String>, presets: [String]) -> some View {
        HStack {
            TextField(title, text: text)
            Menu("Presets") {
                ForEach(presets, id: \.self) { preset in
                    Button("\(preset)  →  \(MomentFormat.string(from: .now, pattern: preset))") { text.wrappedValue = preset }
                }
            }
            .fixedSize()
        }
    }
}
