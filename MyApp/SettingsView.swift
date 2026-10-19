import SwiftUI
import Carbon.HIToolbox

/// Окно настроек: четыре закладки (General, Ranges, Appearance, Notes).
struct SettingsView: View {
    let desktop: DesktopController
    @Bindable private var appearance: Appearance

    init(desktop: DesktopController) {
        self.desktop = desktop
        _appearance = Bindable(desktop.appearance)
    }

    private var events: CalendarEvents { desktop.events }

    /// Новый диапазон, пока он не добавлен: название и срок (по умолчанию неделя с сегодняшнего дня).
    /// Выбранная закладка.
    @State private var tab = Tab.general
    /// Диапазон в списке, который сейчас правится (остальные показаны текстом).
    @State private var editingRangeID: UUID?
    @State private var frozenRangeOrder: [UUID]?
    /// Высота содержимого списка диапазонов (по ней считается высота рамки).
    @State private var rangeListContentHeight = 0.0
    @State private var draftName = ""
    @State private var draftStart = Calendar.current.startOfDay(for: .now)
    @State private var draftEnd = Calendar.current.date(byAdding: .day, value: 6, to: Calendar.current.startOfDay(for: .now)) ?? .now

    /// Подсказки по подключению заметочников лежат в репозитории (docs/NOTES.md).
    private static let notesGuide = URL(string: "https://github.com/lukyanetc/d-cal/blob/main/docs/NOTES.md")

    /// Какие обозначения формата даты поддерживаются, лежит в репозитории (docs/DATE_FORMATS.md).
    private static let formatGuide = URL(string: "https://github.com/lukyanetc/d-cal/blob/main/docs/DATE_FORMATS.md")

    private static let datePresets = ["DD ddd", "ddd DD", "DD.MM", "DD.MM.YYYY", "MM/DD/YYYY", "YYYY-MM-DD"]
    private static let monthPresets = ["MMMM YYYY", "MMMM", "MMM YY", "YYYY-MM"]

    var body: some View {
        // Закладки внизу окна, а не сверху: сверху остаётся свободный заголовок, за который удобно таскать окно.
        VStack(spacing: 0) {
            switch tab {
            case .general: generalTab
            case .ranges: rangesTab
            case .appearance: appearanceTab
            case .notes: notesTab
            }
            Divider()
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        VStack(spacing: 2) {
                            Image(systemName: item.icon)
                            Text(item.title).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(tab == item ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        // Моноширинный стиль, как у ленты.
        .fontDesign(.monospaced)
        .frame(width: 500, height: 580)
    }

    private enum Tab: CaseIterable {
        case general, ranges, appearance, notes

        var title: String {
            switch self {
            case .general: "General"
            case .ranges: "Ranges"
            case .appearance: "Appearance"
            case .notes: "Notes"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .ranges: "calendar.badge.clock"
            case .appearance: "paintbrush"
            case .notes: "note.text"
            }
        }
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section("View") {
                Picker("Show", selection: $appearance.viewKind) {
                    ForEach(ViewKind.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
            }
            Section("Keyboard Shortcut") {
                HotKeyRecorder(desktop: desktop)
                Text("Cycles Locked → Scroll → Edit → Locked from anywhere. Esc always returns to Locked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // День → месяц → неделя: один блок. Пример стоит сразу после названия, до поля ввода.
            Section("Date Format") {
                formatRow("Day", example: appearance.dayText(.now), text: $appearance.dateFormat,
                          presets: Self.datePresets)
                formatRow("Month", example: appearance.monthText(.now), text: $appearance.monthFormat,
                          presets: Self.monthPresets)
                    .disabled(!appearance.showsMonth)
                Toggle("Show month", isOn: $appearance.showsMonth)
                Toggle("Bold month", isOn: $appearance.monthBold)
                    .disabled(!appearance.showsMonth)
                Text("Week")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                Toggle("Week number on Mondays", isOn: $appearance.showsWeekNumber)
                Toggle("Larger gap between weeks", isOn: $appearance.weekGap)
                HStack(spacing: 6) {
                    Text("Moment-style tokens, e.g. DD-MM-YYYY. Text stays as is.")
                        .foregroundStyle(.secondary)
                    if let guide = Self.formatGuide {
                        Link(destination: guide) {
                            Text("Format info").underline().foregroundStyle(.blue)
                        }
                    }
                }
                .font(.caption)
            }
            Section {
                Picker("Calendar events", selection: $appearance.eventsMode) {
                    ForEach(EventsMode.allCases, id: \.self) { Text($0.title) }
                }
                if events.isAuthorized {
                    // При Hide выбор календарей не нужен: список неактивен.
                    calendarList
                        .disabled(appearance.eventsMode == .hide)
                        .opacity(appearance.eventsMode == .hide ? 0.5 : 1)
                } else {
                    Button("Allow Calendar Access") { Task { await events.requestAccess() } }
                }
                Text("Read-only. Google Calendar appears here if the account is added in System Settings (Internet Accounts).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Export Settings…") { appearance.exportSettings() }
                    Button("Import Settings…") { appearance.importSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Ranges

    private var rangesTab: some View {
        Form {
            Section {
                // Одна строка: название, срок, кнопка. Новый диапазон попадает в список ниже.
                HStack(spacing: 8) {
                    // Подсказка «Name» внутри поля (prompt), а не отдельной подписью слева: в Form подпись поля выводится словом.
                    TextField("", text: $draftName, prompt: Text("Name"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    DatePicker("", selection: Binding(
                        get: { draftStart },
                        set: {
                            draftStart = $0
                            if draftEnd < $0 { draftEnd = $0 }
                        }), displayedComponents: .date)
                        .labelsHidden()
                        .fixedSize()
                    DatePicker("", selection: $draftEnd, in: draftStart..., displayedComponents: .date)
                        .labelsHidden()
                        .fixedSize()
                    Button("Add Range") {
                        let calendar = Calendar.current
                        appearance.periods.append(Period(
                            name: draftName.trimmingCharacters(in: .whitespaces),
                            start: calendar.startOfDay(for: draftStart), end: calendar.startOfDay(for: draftEnd)))
                        draftName = ""
                    }
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                // Список виден всегда: пустой показывает одну строку «Empty».
                rangeList
                if !appearance.periods.isEmpty {
                    HStack {
                        Spacer()
                        Button("Remove Expired") {
                            appearance.periods.removeAll { $0.isExpired(on: .now) }
                        }
                        .disabled(!appearance.periods.contains { $0.isExpired(on: .now) })
                    }
                }
            }
            Section("Display") {
                Toggle("Show ranges in the feed", isOn: $appearance.showsPeriodsInFeed)
                Toggle("Day counter under the title", isOn: $appearance.showsPeriodCounter)
                Text("The Range view shows only the days of the longest current range; shorter ones appear inside it. Month and Week views have no ranges; in the Feed they can be turned off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Appearance

    private var appearanceTab: some View {
        Form {
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
            Section("Window") {
                Slider(value: $appearance.width, in: Appearance.widthRange, step: 10) { Text("Width") }
                Slider(value: $appearance.edgeFade, in: 0...150, step: 5) { Text("Edge fade") }
            }
            Section("Today Highlight") {
                ColorPicker("Color and opacity",
                            selection: Binding(get: { appearance.highlightColor }, set: { appearance.highlight = $0 }))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Notes

    private var notesTab: some View {
        Form {
            Section("Daily Note") {
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
        }
        .formStyle(.grouped)
    }

    /// Все диапазоны в рамке с прокруткой (как список календарей): у каждого правка названия и срока и удаление.
    private var rangeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if appearance.periods.isEmpty {
                    Text("Empty").foregroundStyle(.secondary)
                } else {
                    ForEach(orderedPeriods) { period in
                        rangeRow(period.id)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Double.self) { $0.size.height } action: { rangeListContentHeight = $0 }
        }
        // Высота по содержимому, но не больше 200 pt: дальше включается прокрутка, и окно не растёт.
        .frame(height: rangeListContentHeight > 0 ? min(rangeListContentHeight, 200) : 200)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    /// Диапазоны по дате начала (при равном начале сначала короткий); прошедшие остаются на своём месте.
    /// Порядок меняется только в показе, в настройках и в файле он прежний. Пока правится строка, порядок заморожен.
    private var orderedPeriods: [Period] {
        let calendar = Calendar.current
        let sorted = appearance.periods.sorted {
            let a = (calendar.startOfDay(for: $0.start), calendar.startOfDay(for: $0.end))
            let b = (calendar.startOfDay(for: $1.start), calendar.startOfDay(for: $1.end))
            return a.0 != b.0 ? a.0 < b.0 : a.1 < b.1
        }
        guard let frozen = frozenRangeOrder else { return sorted }
        let kept = frozen.compactMap { id in appearance.periods.first { $0.id == id } }
        return kept + sorted.filter { period in !frozen.contains(period.id) }
    }

    /// Правка закончена: строка встаёт на место по новым датам.
    private func stopEditingRange() {
        editingRangeID = nil
        frozenRangeOrder = nil
    }

    /// Ширина колонки названий в списке диапазонов, pt: постоянная, чтобы сроки стояли на одном месте и окно не менялось.
    /// Название, которое в неё не помещается, обрезается многоточием.
    private var nameColumnWidth: Double { 100 }

    private func deleteButton(_ id: UUID) -> some View {
        Button("Delete", systemImage: "trash") {
            if editingRangeID == id { stopEditingRange() }
            appearance.periods.removeAll { $0.id == id }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    /// Срок диапазона текстом: «2026-10-01 – 2026-10-24».
    private static func rangeText(_ period: Period) -> String {
        "\(DayStore.key(for: period.start)) – \(DayStore.key(for: period.end))"
    }

    /// Строка диапазона: название, начало, конец, удаление. Истёкшие приглушены и зачёркнуты.
    private func rangeRow(_ id: UUID) -> some View {
        // Привязка по id, а не по индексу: после удаления строка ещё раз читает своё значение, и индекс
        // выходил бы за границы массива (падение).
        let period = Binding<Period>(
            get: { appearance.periods.first { $0.id == id } ?? Period(id: id, name: "", start: .now, end: .now) },
            set: { value in
                if let index = appearance.periods.firstIndex(where: { $0.id == id }) { appearance.periods[index] = value }
            })
        let isExpired = period.wrappedValue.isExpired(on: .now)
        return VStack(alignment: .leading) {
            if editingRangeID == id {
                // Правка: название и срок можно перепечатать, кнопка «Done» возвращает строку в текст.
                HStack(spacing: 8) {
                    TextField("", text: period.name)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    DatePicker("", selection: Binding(
                        get: { period.wrappedValue.start },
                        set: {
                            period.wrappedValue.start = $0
                            // Конец не может быть раньше начала.
                            if period.wrappedValue.end < $0 { period.wrappedValue.end = $0 }
                        }), displayedComponents: .date)
                        .labelsHidden()
                        .fixedSize()
                    DatePicker("", selection: period.end, in: period.wrappedValue.start..., displayedComponents: .date)
                        .labelsHidden()
                        .fixedSize()
                    Button("Done", systemImage: "checkmark") { stopEditingRange() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    deleteButton(id)
                }
            } else {
                // Обычный вид: название и срок текстом, справа «Edit» и «Delete».
                HStack(spacing: 8) {
                    // Название, срок и «exp» выровнены по базовой линии, а не по центру рамок: мелкая подпись
                    // иначе казалась приподнятой.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // Названия в колонке одной ширины: сроки встают по сетке (одна вертикаль у всех строк).
                        Text(period.wrappedValue.name.isEmpty ? "Untitled" : period.wrappedValue.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: nameColumnWidth, alignment: .leading)
                        Text(Self.rangeText(period.wrappedValue))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        // Прошедший диапазон не зачёркнут, а приглушён и подписан.
                        if isExpired {
                            Text("exp")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Edit", systemImage: "pencil") {
                        // Порядок строк замораживается на время правки: строка не убегает, пока меняются даты.
                        frozenRangeOrder = orderedPeriods.map(\.id)
                        editingRangeID = id
                    }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    deleteButton(id)
                }
            }
            // Длинный период не помещается в окно: режим «Период» покажет вместо него обычную ленту.
            if !isExpired, appearance.estimatedHeight(of: period.wrappedValue)
                > appearance.periodRoom(screenHeight: Double(NSScreen.main?.frame.height ?? 0)) {
                Text("Doesn't fit in the window: the Range view will show the feed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isExpired ? 0.5 : 1)
    }

    /// Строка формата: название, пример (как будет выглядеть), поле ввода с рамкой и меню готовых шаблонов.
    private func formatRow(_ title: String, example: String, text: Binding<String>, presets: [String]) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 56, alignment: .leading)
            Text(example)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 120, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(presets, id: \.self) { preset in
                    Button("\(preset)  →  \(MomentFormat.string(from: .now, pattern: preset))") { text.wrappedValue = preset }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Presets")
        }
    }

    /// Список календарей в рамке с прокруткой: источники (аккаунты) заголовками, названия цветом календаря.
    private var calendarList: some View {
        let groups = Dictionary(grouping: events.calendars, by: \.source).sorted { $0.key < $1.key }
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(groups, id: \.key) { source, calendars in
                    Text(source).bold()
                    ForEach(calendars, id: \.id) { calendar in
                        Toggle(isOn: Binding(
                            get: { appearance.eventCalendarIDs.contains(calendar.id) },
                            set: { isOn in
                                if isOn { appearance.eventCalendarIDs.insert(calendar.id) }
                                else { appearance.eventCalendarIDs.remove(calendar.id) }
                            })
                        ) {
                            Text(calendar.title).bold().foregroundStyle(calendar.color)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 170)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }
}

/// Поле записи глобального хоткея: по нажатию ждёт комбинацию (минимум один модификатор), Esc отменяет.
private struct HotKeyRecorder: View {
    let desktop: DesktopController
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent("Shortcut") {
            HStack {
                Button(isRecording ? "Press a shortcut…" : desktop.appearance.hotKeyLabel) {
                    isRecording ? stop() : start()
                }
                Button("Reset") {
                    let hotKey = Appearance.defaultHotKey
                    desktop.appearance.setHotKey(code: hotKey.code, modifiers: hotKey.modifiers, label: hotKey.label)
                }
                .disabled(isRecording)
            }
        }
        .onDisappear { if isRecording { stop() } }
    }

    private func start() {
        isRecording = true
        // Пока идёт запись, хоткей снят: иначе система перехватила бы нажатие раньше окна.
        desktop.pauseHotKey(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else {
                NSSound.beep()
                return nil
            }
            var modifiers = 0
            var label = ""
            if flags.contains(.control) { modifiers |= controlKey; label += "⌃" }
            if flags.contains(.option) { modifiers |= optionKey; label += "⌥" }
            if flags.contains(.shift) { modifiers |= shiftKey; label += "⇧" }
            if flags.contains(.command) { modifiers |= cmdKey; label += "⌘" }
            let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
            label += key.trimmingCharacters(in: .whitespaces).isEmpty
                ? (event.keyCode == UInt16(kVK_Space) ? "Space" : "Key \(event.keyCode)") : key
            stop()
            desktop.appearance.setHotKey(code: Int(event.keyCode), modifiers: modifiers, label: label)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        desktop.pauseHotKey(false)
    }
}
