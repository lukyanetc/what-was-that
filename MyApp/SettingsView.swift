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
    @State private var startsAtLogin = LoginItem.isEnabled
    /// Диапазон в списке, который сейчас правится (остальные показаны текстом).
    @State private var editingRangeID: UUID?
    @State private var frozenRangeOrder: [UUID]?
    /// Высота содержимого списка диапазонов (по ней считается высота рамки).
    @State private var rangeListContentHeight = 0.0
    @State private var draftName = ""
    @State private var draftStart = Calendar.current.startOfDay(for: .now)
    @State private var draftEnd = Calendar.current.date(byAdding: .day, value: 6, to: Calendar.current.startOfDay(for: .now)) ?? .now

    /// Подсказки по подключению заметочников лежат в репозитории (docs/NOTES.md).
    private static let notesGuide = URL(string: "https://github.com/lukyanetc/what-was-that/blob/main/docs/NOTES.md")

    /// Какие обозначения формата даты поддерживаются, лежит в репозитории (docs/DATE_FORMATS.md).
    private static let formatGuide = URL(string: "https://github.com/lukyanetc/what-was-that/blob/main/docs/DATE_FORMATS.md")

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
            case .about: aboutTab
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
        // Строка ползунка: название 96 + значение 120 + ползунок 260 pt и отступы формы.
        .frame(width: 560, height: 580)
    }

    private enum Tab: CaseIterable {
        case general, ranges, appearance, notes, about

        var title: String {
            switch self {
            case .general: "General"
            case .ranges: "Ranges"
            case .appearance: "Appearance"
            case .notes: "Notes"
            case .about: "About"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .ranges: "calendar.badge.clock"
            case .appearance: "paintbrush"
            case .notes: "note.text"
            case .about: "person.crop.circle"
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
            Section("Startup") {
                Toggle("Start at login", isOn: Binding(get: { startsAtLogin }, set: {
                    LoginItem.set($0)
                    startsAtLogin = LoginItem.isEnabled
                }))
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
                    CalendarListView(appearance: appearance, events: events)
                        .disabled(appearance.eventsMode == .hide)
                        .opacity(appearance.eventsMode == .hide ? 0.5 : 1)
                } else {
                    Button("Allow Calendar Access") {
                        Task {
                            await events.requestAccess()
                            // Системный запрос забирает фокус у приложения, и окно настроек уходило из виду:
                            // после ответа возвращаем его на передний план.
                            NSApp.activate()
                            for window in NSApp.windows where window.title == "what was that!? - settings" {
                                window.makeKeyAndOrderFront(nil)
                            }
                        }
                    }
                }
                Text("Read-only. Google Calendar appears here if the account is added in System Settings (Internet Accounts). Drag calendars to set priority: higher ones come first in a day and win when an event is duplicated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Data") {
                HStack {
                    Button("Export Data as JSON…") { Export.save(markdown: false) }
                    Button("Export Data as Markdown…") { Export.save(markdown: true) }
                }
                HStack {
                    Button("Data Folder…") { Export.chooseDataFolder() }
                    Button("Show File in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([DayStore.defaultURL])
                    }
                }
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
                colorRow("Color", selection: $appearance.color)
                Toggle("Adapt to wallpaper", isOn: $appearance.adapts)
                sliderRow("Opacity", value: $appearance.textOpacity, in: 0.2...1,
                          shows: "\(Int(appearance.textOpacity * 100)) %")
                Picker("Font", selection: $appearance.fontName) {
                    Text("System").tag(Appearance.systemFont)
                    ForEach(Appearance.fonts, id: \.self) { Text($0).tag($0) }
                }
                sliderRow("Font size", value: $appearance.fontSize, in: Appearance.fontSizeRange, step: 1,
                          shows: "\(Int(appearance.fontSize)) pt")
                sliderRow("Row spacing", value: $appearance.rowPadding, in: Appearance.rowPaddingRange, step: 1,
                          shows: "\(Int(appearance.rowPadding * 2)) pt")
                Toggle("Uppercase", isOn: $appearance.uppercase)
                Text(appearance.isMeasured
                     ? "Wallpaper under the feed: \(appearance.luminance < 0.5 ? "dark" : "light") (\(Int(appearance.luminance * 100))%)"
                     : "Couldn't measure the wallpaper; following the system appearance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Window") {
                // Ширина: Width → поле для ручного ввода → px → счётчик со стрелками → ползунок.
                sliderRow("Width", value: widthBinding, in: Appearance.widthRange, step: 10) {
                    HStack(spacing: 6) {
                        TextField("", value: widthBinding, format: .number.grouping(.never))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 52)
                        Text("px").font(.caption).foregroundStyle(.secondary)
                        Stepper("", value: widthBinding, in: Appearance.widthRange, step: 10)
                            .labelsHidden()
                    }
                }
                // Без числа и без шага (шаг рисует риски на ползунке): затухание подбирается на глаз.
                // Пустой текст, а не EmptyView: у пустого вида рамка колонки значения игнорируется, и ползунок съезжал влево.
                sliderRow("Edge fade", value: $appearance.edgeFade, in: 0...150) { Text("") }
                Text("Fades the feed at the top and bottom of the screen. Works only when the window is full height (Feed and Range views).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Today Highlight") {
                colorRow("Color", selection: highlightColorBinding)
                sliderRow("Opacity", value: highlightOpacityBinding, in: 0.02...1,
                          shows: "\(Int(highlightAlpha * 100)) %")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: About


    /// Заглушка: рисунок, название, версия, пара строк об авторе и ссылки.
    private var aboutTab: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
        // Тексты и ссылки лежат в AboutContent.swift: там их и править. Всё помещается в окно (тексты переносятся
        // по строкам), а если не поместится, закладка прокручивается.
        return ScrollView {
            VStack(spacing: 14) {
                // Значок приложения главный: крупный и с большим отступом, всё остальное ниже.
                Image("AboutIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 192, height: 192)
                    .padding(.top, 8)
                    .padding(.bottom, 22)
                // Вступление серым, по центру, переносы строк расставлены вручную в AboutContent.
                Text(AboutContent.intro.joined(separator: "\n"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                VStack(spacing: 4) {
                    Text(AboutContent.title).font(.title2.bold())
                    HStack(spacing: 8) {
                        Text("Version \(version)")
                        if let tag = AboutContent.tag { Text(tag) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                // Продолжение серым, в одну строку.
                Text(AboutContent.outro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                // Обновления над ссылками: кнопка и проверка при запуске (в меню тоже есть «Check for Updates…»).
                HStack(spacing: 12) {
                    Button("Check for Updates…") { desktop.updates.checkManually() }
                    Toggle("Check at launch", isOn: $appearance.checksUpdatesAtLaunch)
                }
                .font(.caption)
                .padding(.top, 6)
                // Ссылки в одну строку, ниже серая подчёркнутая «Report a problem».
                HStack(spacing: 20) {
                    ForEach(AboutContent.links, id: \.title) { item in
                        if let url = item.url.flatMap({ URL(string: $0) }) {
                            link(item.title, url)
                        } else {
                            Text(item.title).foregroundStyle(.secondary)
                        }
                    }
                }
                if let url = URL(string: AboutContent.reportURL) {
                    // Кнопка без оформления, а не Link: ссылка перекрашивает подпись в цвет выделения, а нужен серый.
                    Button { NSWorkspace.shared.open(url) } label: {
                        Text(AboutContent.reportTitle).underline().foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Ссылка: синяя и подчёркнутая, как «Format info».
    @ViewBuilder
    private func link(_ title: String, _ url: URL?) -> some View {
        if let url {
            Link(destination: url) {
                Text(title).underline().foregroundStyle(.blue)
            }
        }
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
                    noteField("Vault", text: $appearance.obsidianVault, prompt: "Vault name")
                    noteField("Folder", text: $appearance.obsidianFolder, prompt: "optional, e.g. Daily")
                    noteField("File name", text: $appearance.obsidianFileFormat, prompt: "YYYY-MM-DD")
                    exampleRow(MomentFormat.string(from: .now, pattern: appearance.obsidianFileFormat))
                    Text("In Edit mode, the arrow at the end of a row creates the day's note in Obsidian (if it doesn't exist) and opens it. After that the arrow opens the same note in Scroll and Edit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .appleNotes:
                    noteField("Folder", text: $appearance.appleNotesFolder, prompt: "optional, default folder")
                    noteField("Note name", text: $appearance.appleNotesFormat, prompt: "YYYY-MM-DD")
                    exampleRow(MomentFormat.string(from: .now, pattern: appearance.appleNotesFormat))
                    Text("In Edit mode, the arrow at the end of a row creates the day's note in Notes (if it doesn't exist) and opens it. After that the arrow opens the same note in Scroll and Edit. The first time, macOS asks for permission to control Notes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .manual:
                    noteField("Template", text: $appearance.noteTemplate, prompt: "link or file path")
                    exampleRow(appearance.noteTemplateExample)
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

    /// Строка ползунка в одну линию: название → значение (у ширины поле и счётчик) → ползунок постоянной длины.
    /// Колонки названия и значения одной ширины у всех строк, поэтому все ползунки стоят в одну колонку.
    @ViewBuilder
    private func sliderRow<Display: View>(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                                          step: Double? = nil, @ViewBuilder display: () -> Display) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 96, alignment: .leading)
            display().frame(width: 120, alignment: .leading)
            // Без подписи: форма иначе ставит ползунок со своей подписью справа и сама задаёт ему узкую ширину.
            Group {
                if let step {
                    Slider(value: value, in: range, step: step) { EmptyView() }
                } else {
                    Slider(value: value, in: range) { EmptyView() }
                }
            }
            .labelsHidden()
            .frame(width: Self.sliderWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    /// Строка ползунка со значением обычным текстом («13 pt»).
    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                           step: Double? = nil, shows text: String) -> some View {
        sliderRow(title, value: value, in: range, step: step) {
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Длина всех ползунков, pt.
    private static let sliderWidth = 260.0

    /// Пример результата: мелкий серый текст, как у примеров в Date Format. Подпись в той же колонке, что у полей.
    private func exampleRow(_ example: String) -> some View {
        HStack(spacing: 8) {
            Text("Example").frame(width: 90, alignment: .leading)
            Text(example)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    /// Поле заметочника: подпись слева, поле с рамкой и серой подсказкой внутри (видно, что сюда можно вводить).
    private func noteField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 90, alignment: .leading)
            TextField("", text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Строка цвета: подпись и образец по центру одной линии (в LabeledContent подпись стояла выше образца).
    private func colorRow(_ title: String, selection: Binding<Color>) -> some View {
        HStack(alignment: .center) {
            Text(title)
            Spacer()
            ColorPicker("", selection: selection, supportsOpacity: false)
                .labelsHidden()
        }
    }

    /// Ширина окна: введённое вручную значение зажимается в допустимые границы.
    private var widthBinding: Binding<Double> {
        Binding(
            get: { appearance.width },
            set: { appearance.width = min(max($0, Appearance.widthRange.lowerBound), Appearance.widthRange.upperBound) })
    }

    /// Линия «сегодня»: цвет без прозрачности и отдельная прозрачность. Пока ничего не выбрано, это цвет текста с 15%.
    private var highlightAlpha: Double { Double(NSColor(appearance.highlightColor).alphaComponent) }

    private var highlightColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(appearance.highlightColor).withAlphaComponent(1)) },
            set: { appearance.highlight = Color(nsColor: NSColor($0).withAlphaComponent(CGFloat(highlightAlpha))) })
    }

    private var highlightOpacityBinding: Binding<Double> {
        Binding(
            get: { highlightAlpha },
            set: {
                appearance.highlight = Color(nsColor: NSColor(appearance.highlightColor).withAlphaComponent(CGFloat($0)))
            })
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
