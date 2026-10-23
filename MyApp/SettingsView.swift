import SwiftUI
import Carbon.HIToolbox

/// Settings window: tabs (General, Ranges, Appearance, Notes, About).
struct SettingsView: View {
    let desktop: DesktopController
    @Bindable private var appearance: Appearance

    init(desktop: DesktopController) {
        self.desktop = desktop
        _appearance = Bindable(desktop.appearance)
    }

    private var events: CalendarEvents { desktop.events }

    /// A new range until it is added: name and span (a week starting today by default).
    /// The selected tab.
    @State private var tab = Tab.general
    @State private var startsAtLogin = LoginItem.isEnabled
    /// The range in the list that is being edited now (the others are shown as text).
    @State private var editingRangeID: UUID?
    @State private var frozenRangeOrder: [UUID]?
    /// Height of the ranges list content (the frame height is computed from it).
    @State private var rangeListContentHeight = 0.0
    @State private var draftName = ""
    @State private var draftStart = Calendar.current.startOfDay(for: .now)
    @State private var draftEnd = Calendar.current.date(byAdding: .day, value: 6, to: Calendar.current.startOfDay(for: .now)) ?? .now

    /// Hints for connecting notes apps are in the repository (docs/NOTES.md).
    private static let notesGuide = URL(string: "https://github.com/lukyanetc/what-was-that/blob/main/docs/NOTES.md")

    /// Which date format tokens are supported is in the repository (docs/DATE_FORMATS.md).
    private static let formatGuide = URL(string: "https://github.com/lukyanetc/what-was-that/blob/main/docs/DATE_FORMATS.md")

    private static let datePresets = ["DD ddd", "ddd DD", "DD.MM", "DD.MM.YYYY", "MM/DD/YYYY", "YYYY-MM-DD"]
    private static let monthPresets = ["MMMM YYYY", "MMMM", "MMM YY", "YYYY-MM"]

    var body: some View {
        // Tabs at the bottom of the window, not at the top: the top stays a free title area that is handy for dragging the window.
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
        // Monospaced style, like the feed.
        .fontDesign(.monospaced)
        // Slider row: title 96 + value 120 + slider 260 pt and the form's padding.
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
            // Day → month → week: one block. The example comes right after the title, before the input field.
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
                    // With Hide, calendar selection is not needed: the list is inactive.
                    CalendarListView(appearance: appearance, events: events)
                        .disabled(appearance.eventsMode == .hide)
                        .opacity(appearance.eventsMode == .hide ? 0.5 : 1)
                } else {
                    Button("Allow Calendar Access") {
                        Task {
                            await events.requestAccess()
                            // The system request takes focus from the app, and the settings window used to go out of sight:
                            // after the answer we bring it back to the front.
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
                // One row: name, span, button. The new range lands in the list below.
                HStack(spacing: 8) {
                    // The "Name" hint inside the field (prompt), not a separate label on the left: in a Form a field's label is shown as a word.
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
                // The list is always visible: an empty one shows a single "Empty" row.
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
                // Width: Width → manual input field → px → stepper → slider.
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
                // No number and no step (the step draws ticks on the slider): the fade is tuned by eye.
                // Empty text, not EmptyView: an empty view ignores the value column's frame, and the slider shifted left.
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


    /// Placeholder: image, title, version, a couple of lines about the author and links.
    private var aboutTab: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
        // Texts and links live in AboutContent.swift: edit them there. Everything fits in the window (texts wrap
        // by lines), and if it does not fit, the tab scrolls.
        return ScrollView {
            VStack(spacing: 14) {
                // The app icon is the main thing: large and with a big margin, everything else is below.
                Image("AboutIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 192, height: 192)
                    .padding(.top, 8)
                    .padding(.bottom, 22)
                // Intro in gray, centered, line breaks placed by hand in AboutContent.
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
                // Outro in gray, on one line.
                Text(AboutContent.outro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                // Updates above the links: a button and the check at launch (the menu also has "Check for Updates…").
                HStack(spacing: 12) {
                    Button("Check for Updates…") { desktop.updates.checkManually() }
                    Toggle("Check at launch", isOn: $appearance.checksUpdatesAtLaunch)
                }
                .font(.caption)
                .padding(.top, 6)
                // Above the links: "Inspired by this video".
                HStack(spacing: 4) {
                    Text(AboutContent.inspiredText).foregroundStyle(.secondary)
                    link(AboutContent.inspiredLinkTitle, URL(string: AboutContent.inspiredURL))
                }
                .padding(.top, 6)
                // Links in one row.
                HStack(spacing: 20) {
                    ForEach(AboutContent.links, id: \.title) { item in
                        if let url = item.url.flatMap({ URL(string: $0) }) {
                            link(item.title, url)
                        } else {
                            Text(item.title).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Link: blue and underlined, like "Format info".
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

    /// All ranges in a scrolling frame (like the calendar list): each has editing of name and span, and deletion.
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
        // Height by content, but not more than 200 pt: beyond that scrolling turns on and the window does not grow.
        .frame(height: rangeListContentHeight > 0 ? min(rangeListContentHeight, 200) : 200)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    /// Slider row on one line: title → value (the width has a field and a stepper) → slider of constant length.
    /// The title and value columns are the same width in all rows, so all sliders line up in one column.
    @ViewBuilder
    private func sliderRow<Display: View>(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                                          step: Double? = nil, @ViewBuilder display: () -> Display) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 96, alignment: .leading)
            display().frame(width: 120, alignment: .leading)
            // No label: otherwise the form puts the slider with its own label on the right and gives it a narrow width.
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

    /// Slider row with a plain text value ("13 pt").
    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                           step: Double? = nil, shows text: String) -> some View {
        sliderRow(title, value: value, in: range, step: step) {
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Length of all sliders, pt.
    private static let sliderWidth = 260.0

    /// Example of the result: small gray text, like the examples in Date Format. The label is in the same column as the fields.
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

    /// Notes app field: label on the left, a bordered field with a gray hint inside (it is clear that you can type here).
    private func noteField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 90, alignment: .leading)
            TextField("", text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Color row: label and swatch centered on one line (in LabeledContent the label sat above the swatch).
    private func colorRow(_ title: String, selection: Binding<Color>) -> some View {
        HStack(alignment: .center) {
            Text(title)
            Spacer()
            ColorPicker("", selection: selection, supportsOpacity: false)
                .labelsHidden()
        }
    }

    /// Window width: a manually entered value is clamped to valid bounds.
    private var widthBinding: Binding<Double> {
        Binding(
            get: { appearance.width },
            set: { appearance.width = min(max($0, Appearance.widthRange.lowerBound), Appearance.widthRange.upperBound) })
    }

    /// "Today" line: color without opacity and a separate opacity. While nothing is chosen, it is the text color at 15%.
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

    /// Ranges by start date (on equal start the shorter first); past ones stay in their place.
    /// The order changes only in display; in settings and in the file it stays the same. While a row is being edited, the order is frozen.
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

    /// Editing is done: the row takes its place by the new dates.
    private func stopEditingRange() {
        editingRangeID = nil
        frozenRangeOrder = nil
    }

    /// Width of the titles column in the ranges list, pt: constant, so the spans line up and the window does not change.
    /// A title that does not fit is truncated with an ellipsis.
    private var nameColumnWidth: Double { 100 }

    private func deleteButton(_ id: UUID) -> some View {
        Button("Delete", systemImage: "trash") {
            if editingRangeID == id { stopEditingRange() }
            appearance.periods.removeAll { $0.id == id }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    /// Range span as text: "2026-10-01 – 2026-10-24".
    private static func rangeText(_ period: Period) -> String {
        "\(DayStore.key(for: period.start)) – \(DayStore.key(for: period.end))"
    }

    /// Range row: name, start, end, deletion. Expired ones are muted and struck through.
    private func rangeRow(_ id: UUID) -> some View {
        // Binding by id, not by index: after deletion the row reads its value once more, and the index
        // would go out of the array's bounds (a crash).
        let period = Binding<Period>(
            get: { appearance.periods.first { $0.id == id } ?? Period(id: id, name: "", start: .now, end: .now) },
            set: { value in
                if let index = appearance.periods.firstIndex(where: { $0.id == id }) { appearance.periods[index] = value }
            })
        let isExpired = period.wrappedValue.isExpired(on: .now)
        return VStack(alignment: .leading) {
            if editingRangeID == id {
                // Editing: the name and span can be retyped, the "Done" button returns the row to text.
                HStack(spacing: 8) {
                    TextField("", text: period.name)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    DatePicker("", selection: Binding(
                        get: { period.wrappedValue.start },
                        set: {
                            period.wrappedValue.start = $0
                            // The end cannot be earlier than the start.
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
                // Normal view: name and span as text, "Edit" and "Delete" on the right.
                HStack(spacing: 8) {
                    // The name, span and "exp" are aligned by the baseline, not by the centers of their frames: the small label
                    // otherwise looked raised.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // Names in a column of one width: spans line up on a grid (one vertical for all rows).
                        Text(period.wrappedValue.name.isEmpty ? "Untitled" : period.wrappedValue.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: nameColumnWidth, alignment: .leading)
                        Text(Self.rangeText(period.wrappedValue))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        // A past range is not struck through but muted and labeled.
                        if isExpired {
                            Text("exp")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Edit", systemImage: "pencil") {
                        // Row order is frozen while editing: the row does not run away while the dates change.
                        frozenRangeOrder = orderedPeriods.map(\.id)
                        editingRangeID = id
                    }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    deleteButton(id)
                }
            }
            // A long period does not fit in the window: "Period" mode will show the ordinary feed instead.
            if !isExpired, appearance.estimatedHeight(of: period.wrappedValue)
                > appearance.periodRoom(screenHeight: Double(NSScreen.main?.frame.height ?? 0)) {
                Text("Doesn't fit in the window: the Range view will show the feed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isExpired ? 0.5 : 1)
    }

    /// Format row: title, example (how it will look), a bordered input field and a menu of ready templates.
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

/// Global hotkey recording field: on click it waits for a combination (at least one modifier), Esc cancels.
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
        // While recording, the hotkey is removed: otherwise the system would catch the key press before the window.
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
