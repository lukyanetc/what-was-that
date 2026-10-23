import SwiftUI

/// Day feed: a year back from the earliest entry and two years ahead from today, or a single month or week
/// (see `ViewKind`). In edit each day's text is editable.
struct ContentView: View {
    let desktop: DesktopController
    @State private var entries: [String: DayEntry] = [:]
    /// Days that were changed but not yet written to the file.
    @State private var dirty: Set<String> = []
    /// What is wrong with the data file (corrupted, downloading, not saving); nil means all is well. Shown in the corner of the window.
    @State private var dataProblem: String?
    /// Deferred re-sorting of events after the calendar priority changes.
    @State private var orderTask: Task<Void, Never>?
    /// Deferred text save, see `scheduleSave`.
    @State private var saveTask: Task<Void, Never>?
    /// File modification time at the last read: used to notice edits from another Mac (iCloud).
    @State private var fileStamp: Date?
    /// Fallback interval for checking the file, sec. The check reads only the modification time; the file itself is reread if it changed.
    private static let syncInterval = 600.0
    @FocusState private var focusedDay: Date?
    /// The day whose indicator color picker row is expanded now.
    @State private var pickerDay: Date?
    /// The day where the cursor was in the current edit session. When the window takes focus back (for example, after
    /// picking an emoji in an external panel), the cursor returns to this day instead of jumping to "today".
    @State private var editingDay: Date?
    /// Indices of days fully visible in the window.
    @State private var visibleRange = 0...0
    @State private var isIndicatorVisible = true
    /// Today and the feed around it; updated when the date changes.
    @State private var today = Calendar.current.startOfDay(for: .now)
    @State private var days = ContentView.days(around: Calendar.current.startOfDay(for: .now))
    /// Month and week: how many spans the window is shifted from the current one (paging in scroll and edit; always 0 in locked).
    @State private var periodOffset = 0
    /// The cursor went past the edge of the span by arrow or Enter: +1 lands on the first day of the next one, -1 on the last of the previous.
    @State private var pendingEdge: Int?
    /// Width of the entries column (the same for all rows); it decides whether an entry can be drawn over the field.
    @State private var recordWidth = 0.0
    /// The current attempt to place the cursor (see `focusEditor`); a new one cancels the previous.
    @State private var focusTask: Task<Void, Never>?
    /// Height of the first day of the running period (with its title), see `periodAnchor`.
    @State var periodItemHeight = 0.0
    /// Positions of the rows where periods start and end in the feed window, see `StickyPeriodTitles`.
    @State private var periodFrames = PeriodFrames()
    private static let feedSpace = "feed"

    // Constants without `private`: they are also used by the period files (PeriodViews) and the color picker row.
    static let calendar = Calendar.current
    /// "Today" sits at about a third of the window height.
    private static let todayAnchor = UnitPoint(x: 0, y: 0.3)
    /// Dimming for weekends and month headings.
    static let mutedOpacity = 0.5
    /// How far the "today" bar extends to the left beyond the text. ScrollView clips its content at its bounds,
    /// so this room is set as padding inside the feed, not as window padding.
    static let highlightInset = 35.0
    /// Period line: thickness and the gap to the neighboring line and to the dates.
    static let lineWidth = 1.5
    static let lineGap = 3.0
    /// Gap between the period title and the lines.
    static let titleGap = 6.0
    /// Extra gap before Monday when it is enabled.
    private static let weekGapHeight = 12.0

    /// The earliest day with an entry (the "yyyy-MM-dd" keys sort as strings).
    private static func earliestDay(in entries: [String: DayEntry]) -> Date? {
        guard let key = entries.keys.min() else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The window's days. Feed: see below. Month and week: one span, shifted by `offset` spans from the current one.
    private static func days(around today: Date, earliest: Date? = nil, kind: ViewKind = .feed, offset: Int = 0) -> [Date] {
        if kind != .feed {
            let component: Calendar.Component = kind == .month ? .month : .weekOfYear
            // The week always starts on Monday, regardless of regional settings.
            var cal = kind == .month ? calendar : Calendar(identifier: .iso8601)
            cal.timeZone = calendar.timeZone
            guard let anchor = cal.date(byAdding: component, value: offset, to: today),
                  let interval = cal.dateInterval(of: component, for: anchor) else { return [today] }
            let count = cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
            return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: interval.start) }
        }
        // A year back from the earliest entry (or from today if it is later) and two years ahead from today.
        let anchor = min(earliest ?? today, today)
        let first = calendar.date(byAdding: .year, value: -1, to: anchor) ?? today
        let last = calendar.date(byAdding: .year, value: 2, to: today) ?? today
        let count = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        return (0...count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        dayItem(day, reportsFrames: true)
                    }
                }
                .scrollTargetLayout()
                .padding(.leading, leadingInset)
                // Month, week and period: the window is sized to content, the top and bottom margins equal the edge fade,
                // so rows do not fall into the fade.
                .padding(.vertical, desktop.isCompact ? desktop.edgeFade : 0)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
                    if desktop.isCompact { desktop.periodHeight = height }
                }
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: Self.feedSpace)
            // Period titles in scroll and edit: under the feed (not over the input fields), smoothly following the line.
            .background(alignment: .topLeading) {
                StickyPeriodTitles(desktop: desktop, days: days, frames: periodFrames, leadingInset: leadingInset,
                                   visibleRange: $visibleRange)
            }
            .onScrollTargetVisibilityChange(idType: Date.self, threshold: 0.9) { ids in
                let indices = ids.compactMap { days.firstIndex(of: $0) }
                if let first = indices.min(), let last = indices.max() { visibleRange = first...last }
            }
            .onAppear {
                reload()
                scrollHome(proxy)
                desktop.moveFocus = { step in move(by: step, proxy: proxy) }
                desktop.shiftPeriod = { step in periodOffset += step }
                desktop.flushPending = { flush() }
            }
            // Span change (settings, menu) and paging in scroll: the set of days is rebuilt.
            .onChange(of: desktop.appearance.viewKind) {
                periodOffset = 0
                rebuildDays(proxy)
            }
            .onChange(of: periodOffset) { rebuildDays(proxy) }
            // Calendar settings: mode, selected calendars, granted access.
            .onChange(of: desktop.appearance.eventsMode) { loadEvents() }
            .onChange(of: desktop.appearance.eventCalendarIDs) { loadEvents() }
            // Calendar priority changes by dragging in settings: events are re-sorted a bit later, when
            // the drag is already over (otherwise the row's image hangs on screen while the feed redraws).
            .onChange(of: desktop.appearance.eventCalendarOrder) {
                orderTask?.cancel()
                orderTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    loadEvents()
                }
            }
            .onChange(of: desktop.events.isAuthorized) { loadEvents() }
            // The running period changed (list edit, start or end) or its place in the window: the feed settles again.
            .onChange(of: activePeriodStart) { restorePosition(proxy) }
            // The height of the first day also changes on entering edit (a field instead of text, events): the feed must not move,
            // otherwise it shifts by a point or two. Fitting is needed only where the feed stands by the period anchor.
            .onChange(of: periodItemHeight) {
                if desktop.mode == .locked || desktop.mode == .move { restorePosition(proxy) }
            }
            .onChange(of: desktop.periodOffset) { restorePosition(proxy) }
            // After the width changes the feed returns to its place: in locked to today, in the other modes
            // to the topmost visible day.
            .onChange(of: desktop.appearance.width) { restorePosition(proxy) }
            // A font size change alters row heights: the feed returns to its place the same way.
            .onChange(of: desktop.appearance.fontSize) { restorePosition(proxy) }
            .onChange(of: desktop.appearance.rowPadding) { restorePosition(proxy) }
            .onChange(of: focusedDay) { _, day in
                if let day {
                    pickerDay = nil
                    editingDay = day
                }
            }
            .onChange(of: desktop.mode) { oldMode, mode in
                pickerDay = nil
                if oldMode == .edit { flush() }
                if mode == .scroll { reload() }
                if mode == .edit {
                    // A new edit session starts at "today" (or the topmost visible day).
                    editingDay = nil
                    // Input fields do not appear instantly, so focus is set after a short pause.
                    Task {
                        try? await Task.sleep(for: .milliseconds(50))
                        if desktop.mode == .edit { focusEditor() }
                    }
                }
                if oldMode == .edit { focusedDay = nil }
                // Leaving the view returns the feed to today (month and week to the current span).
                if mode == .locked {
                    periodOffset = 0
                    if activePeriodStart == nil {
                        scrollHome(proxy)
                    } else {
                        // The feed under the period layer settles when the layer already covers it (the jump is not visible).
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            if desktop.mode == .locked { scrollHome(proxy) }
                        }
                    }
                }
            }
            // A lazy feed estimates the position of a distant row only approximately on the first scroll:
            // after drawing at launch we scroll once more, now exactly.
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                if desktop.mode == .locked { scrollHome(proxy) }
            }
            // The window does not become key right away: app activation is asynchronous. Focus set before that
            // gives no caret (the feed "moves focus" but there is no caret), so we set it again when the window is ready.
            .task {
                for await note in NotificationCenter.default.notifications(named: NSWindow.didBecomeKeyNotification) {
                    if note.object is DesktopWindow, desktop.mode == .edit { focusEditor() }
                }
            }
            // The file may have changed on another Mac (iCloud). We check its modification time at natural moments:
            // after wake, on Space change and (in case none of those happens for a long time) on a rare timer.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.syncInterval))
                    syncIfFileChanged()
                }
            }
            .task {
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                    syncIfFileChanged()
                }
            }
            .task {
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.activeSpaceDidChangeNotification) {
                    syncIfFileChanged()
                }
            }
            // The data file moved to another folder (menu "Data Folder…").
            .task {
                for await _ in NotificationCenter.default.notifications(named: .dataFolderChanged) { reload() }
            }
            // Date change (midnight, waking from sleep): the feed moves along with "today".
            .task {
                for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
                    today = Self.calendar.startOfDay(for: .now)
                    syncIfFileChanged()
                    // A period may have started or ended: the window is fitted again.
                    rebuildDays(proxy)
                    desktop.fitWindow()
                    if desktop.mode == .locked { scrollHome(proxy) }
                }
            }
        }
        // "Period" mode in locked: the feed is replaced by a static period layer, the feed under it is invisible. In other views
        // the feed stays without these add-ons.
        .modifier(PeriodSwap(isActive: desktop.appearance.viewKind == .period,
                             hidesContent: desktop.shownPeriod != nil, layer: periodLayer))
        // No top and bottom padding: the feed goes past the window edges, and the fade at the edges creates a sense of infinity.
        // On top of the edge fade comes a soft "window" under the mode name: the feed under it is transparent down to the desktop,
        // so the name does not blend into the text.
        .mask {
            edgeFadeMask
                .overlay(alignment: .topTrailing) { modePlateHole }
                .compositingGroup()
        }
        .font(desktop.appearance.font)
        .foregroundStyle(desktop.appearance.textColor.opacity(desktop.appearance.textOpacity))
        .padding(.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 0) {
                modeIndicator
                dataProblemLabel
            }
        }
    }

    /// Warning about a data file problem (under the mode indicator, visible in all modes).
    @ViewBuilder private var dataProblemLabel: some View {
        if let dataProblem {
            Text("⚠ \(dataProblem)")
                .font(desktop.appearance.smallFont)
                .foregroundStyle(desktop.appearance.textColor)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 240, alignment: .trailing)
                .padding(.horizontal)
                .opacity(0.8)
                .allowsHitTesting(false)
        }
    }

    /// A feed day: month heading, day row and period lines. The same view in the feed and in the static period layer.
    func dayItem(_ day: Date, reportsFrames: Bool = false) -> some View {
        // The rows where periods start and end report their position in the feed window (for smooth titles in scroll and edit).
        let calendar = Self.calendar
        let isBoundary = reportsFrames && desktop.appearance.showsPeriodMarks && desktop.appearance.periods.contains {
            calendar.startOfDay(for: $0.start) == day || calendar.startOfDay(for: $0.end) == day
        }
        return VStack(alignment: .leading, spacing: 0) {
            if desktop.appearance.showsMonth && isMonthStart(day) {
                Text(desktop.appearance.monthText(day))
                    .bold(desktop.appearance.monthBold)
                    .opacity(Self.mutedOpacity)
                    .padding(.vertical, 12)
            }
            row(day)
                .background(alignment: .topLeading) { periodLines(on: day, starting: true) }
                .onGeometryChange(for: ClosedRange<Double>?.self) { proxy in
                    guard isBoundary else { return nil }
                    let frame = proxy.frame(in: .named(Self.feedSpace))
                    return frame.minY...frame.maxY
                } action: { range in
                    if let range { periodFrames.frames[day] = range }
                }
        }
        // Gap before Monday; the month heading has its own gap, the first day is not shifted.
        .padding(.top, desktop.appearance.weekGap && isMonday(day) && !isMonthStart(day) ? Self.weekGapHeight : 0)
        // Lines of periods that started earlier run through month headings and gaps without a break.
        .background(alignment: .topLeading) { periodLines(on: day, starting: false) }
        // The height of the period's first day is needed so the feed stands the same way as the static period layer.
        .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
            if day == activePeriodStart { periodItemHeight = height }
        }
    }

    /// Feed home position: with a running period ("Period") its start is at the set place, otherwise "today".
    private func scrollHome(_ proxy: ScrollViewProxy) {
        if let start = activePeriodStart, days.contains(start) {
            proxy.scrollTo(start, anchor: periodAnchor)
        } else {
            proxy.scrollTo(today, anchor: Self.todayAnchor)
        }
    }

    /// Mask: the feed fades smoothly to transparent at the top and bottom edge of the window.
    private var edgeFadeMask: some View {
        let fade = desktop.edgeFade
        return VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: fade)
        }
    }

    /// Mode in the top right corner: appears right away on mode change. Lit in scroll, edit and move;
    /// locked is shown for a second and fades smoothly.
    /// The "> mode" line: a half-space gap, and the ">" sign is lowered a couple of points to sit at the center of lowercase letters.
    private var modeLabel: some View {
        HStack(spacing: 4) {
            Text(">").baselineOffset(-1)
            // The invisible "scroll" (the longest word) sets the width: ">" stays in place, the word changes after it.
            ZStack(alignment: .leading) {
                Text("scroll").hidden()
                Text(desktop.mode.rawValue)
            }
        }
        .font(desktop.appearance.font)
    }

    /// Top inset of the mode line. Feed: below the menu bar, the window goes under it. Month and week: the window is small.
    private var modeTopInset: Double { desktop.isCompact ? 8 : 56 }

    /// A transparent "window" in the feed mask under the mode line: a flat rectangle with slight rounding that cuts the feed
    /// down to the desktop. Fitted to the word: starts at ">" (it stays in place) and ends past the mode word.
    /// The position is set by the invisible `modeLabel` line of the same width as the real one, and the plate is drawn behind it.
    /// Fades together with the name itself.
    private var modePlateHole: some View {
        modeLabel
            .foregroundStyle(.clear)
            .background(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(">").baselineOffset(-1)
                    Text(desktop.mode.rawValue)
                }
                .font(desktop.appearance.font)
                .foregroundStyle(.clear)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.black))
                .padding(.leading, -10)
            }
            .padding(.top, modeTopInset)
            .blendMode(.destinationOut)
            .opacity(isIndicatorVisible ? 1 : 0)
    }

    private var modeIndicator: some View {
        modeLabel
        .foregroundStyle(desktop.appearance.textColor)
        .padding(.horizontal)
        .padding(.top, modeTopInset)
        .opacity(isIndicatorVisible ? 0.5 : 0)
        .task(id: desktop.mode) {
            isIndicatorVisible = true
            guard desktop.mode == .locked else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { isIndicatorVisible = false }
        }
        .allowsHitTesting(false)
    }

    private func row(_ day: Date) -> some View {
        let label = desktop.appearance.dayText(day)
        let isWeekend = Self.calendar.isDateInWeekend(day)
        let key = DayStore.key(for: day)
        // The date sits at the level of the entry's first line, the other lines go under it in the entries column.
        return HStack(alignment: .firstTextBaseline, spacing: Self.dotGap) {
            Text(label)
                .opacity(isWeekend ? Self.mutedOpacity : 1)
                // Fixed-width date column: indicators and entries stand on one vertical with any font.
                .frame(width: desktop.appearance.dateColumnWidth, alignment: .leading)
            // Room for the indicator (it is drawn on top, see `indicator`), between the date and the entry.
            Color.clear.frame(width: Self.dotWidth, height: 0)
            // The day's entry, under it the calendar events in a column (all-day first, then by time).
            VStack(alignment: .leading, spacing: 0) {
            // While the color picker is open, the entry is hidden: the color row opens along the input line, in its place.
            Group {
                // While the color picker is open, there is no input field at all: even hidden, it makes the mouse cursor
                // over the color row turn into a text cursor. Plain text stands in for it.
                if desktop.mode == .edit && pickerDay != day {
                    // The letters are drawn by the same Text as in locked (the input field draws the same font a pixel differently, and
                    // entries "jumped" on entering edit). The field stays for the caret, selection and input, and its
                    // own text is transparent. If a line is wider than the column it wraps, and the wrap in the field
                    // and in Text could differ: then the text is shown by the field itself.
                    let text = entries[key]?.text ?? ""
                    let overlaysText = fitsInColumn(text)
                    // Several lines in a day (Shift+Enter): the entry wraps and grows downward.
                    let field = TextField("", text: binding(for: key), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...20)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(overlaysText ? Color.clear : desktop.appearance.textColor)
                        .opacity(desktop.appearance.textOpacity)
                        .focused($focusedDay, equals: day)
                    if overlaysText {
                        // The row height is set by the same Text as in locked, and the field lies on top and does not affect the size:
                        // the field is slightly taller than the text, and feed rows (with the events under them) used to shift on entering edit.
                        // Empty lines (after Shift/Cmd/Opt+Enter) are drawn as a space: a Text with an "empty" line is shorter
                        // than normal and does not grow with the field, so the date shifted until letters appeared.
                        let padded = text.split(separator: "\n", omittingEmptySubsequences: false)
                            .map { $0.isEmpty ? " " : String($0) }.joined(separator: "\n")
                        recordText(AttributedString(padded))
                            .allowsHitTesting(false)
                            .overlay(alignment: .topLeading) { field }
                    } else {
                        field
                    }
                } else {
                    let text = entries[key]?.text ?? ""
                    recordText(desktop.appearance.displayText(text.trimmingCharacters(in: .newlines)))
                }
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { recordWidth = $0 }
            .opacity(pickerDay == day ? 0 : 1)
            .overlay(alignment: .topTrailing) {
                // "Future only" mode: how many past events are hidden.
                let hidden = desktop.events.events(on: day, mode: desktop.appearance.eventsMode).hidden
                if hidden > 0 {
                    Text("+\(hidden)").font(desktop.appearance.smallFont).opacity(Self.mutedOpacity).allowsHitTesting(false)
                }
            }
            eventLines(day)
            }
            // Room for the note arrow at the end of the line (the arrow itself is drawn on top, see `noteArrow`).
            Color.clear.frame(width: Self.noteArrowWidth, height: 0)
        }
        // Titles of periods that start on this day: to the left of the lines, in a separate column (title → line → dates).
        // Under the row, not over it: a layer over the input field in edit made the feed jitter.
        .background(alignment: .topLeading) {
            PeriodTitles(desktop: desktop, day: day)
        }
        // The week number stands to the left of the date, in the spare room for the "today" bar, and does not shift the text.
        .overlay(alignment: .topLeading) {
            if desktop.appearance.showsWeekNumber && isMonday(day) {
                Text(desktop.appearance.weekText(day))
                    .font(desktop.appearance.smallFont)
                    .opacity(0.4)
                    // The frame height equals the date row height: the number sits at its center instead of being pressed to the top.
                    .frame(width: Self.highlightInset - 6, height: desktop.appearance.lineHeight, alignment: .trailing)
                    .offset(x: -Self.highlightInset, y: 0)
            }
        }
        .padding(.vertical, desktop.appearance.rowPadding)
        .overlay(alignment: .topLeading) { indicator(for: day) }
        .overlay(alignment: .topTrailing) { noteArrow(day) }
        .overlay(alignment: .topLeading) {
            if pickerDay == day {
                // The color row stands at the level of the entry's first line, like the indicator itself.
                GeometryReader { geo in
                    // Squares with a side equal to the bar height stand to the right of it: the previous color stays visible.
                    ColorStrip(size: markerHeight) { choose($0, for: day) }
                        .offset(x: dotX + Self.dotWidth + Self.dotGap - ColorStrip.slotPadding,
                                y: centerY(in: geo.size.height) - markerHeight / 2 - ColorStrip.slotPadding)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if day == today { todayHighlight }
        }
    }

    /// The day's calendar events in a column: time and title (all-day events have only the title).
    @ViewBuilder private func eventLines(_ day: Date) -> some View {
        let shown = desktop.events.events(on: day, mode: desktop.appearance.eventsMode).shown
        ForEach(shown) { event in
            let startsToday = !event.isAllDay && Self.calendar.startOfDay(for: event.start) == day
            // Looks like the day's entry, but smaller and lighter so as not to outweigh it; an event is distinguished by the calendar color dot.
            HStack(alignment: .top, spacing: Self.dotGap + 2) {
                Circle()
                    .fill(event.color)
                    .frame(width: Self.eventDot, height: Self.eventDot)
                    .padding(.top, desktop.appearance.smallCapCenter - Self.eventDot / 2)
                recordText(AttributedString(startsToday ? "\(event.start.formatted(.dateTime.hour().minute())) \(event.title)" : event.title))
                    .font(desktop.appearance.smallFont)
            }
            .opacity(Self.eventOpacity)
            .allowsHitTesting(false)
        }
    }

    /// Loads calendar events for the feed's days (nothing is read in "Don't show" mode).
    private func loadEvents() {
        let ids = desktop.appearance.eventsMode == .hide ? [] : desktop.appearance.eventCalendarIDs
        desktop.events.load(days: days, calendarIDs: ids, order: desktop.appearance.eventCalendarOrder)
    }

    /// An entry in the feed (locked, scroll) and over the field in edit: the same layout so the letters stand in the same place.
    private func recordText(_ text: AttributedString) -> some View {
        // Text that reaches the window edge wraps to the next line and is fully visible.
        // An empty entry is drawn as a space: an empty Text is a pixel shorter than a normal line, and the calendar events under it
        // shifted down as soon as the first letter appeared.
        Text(text.characters.isEmpty ? AttributedString(" ") : text)
            .fadedLikeText(desktop.appearance)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the longest line of the entry fits in the entries column (with room for the input field's padding).
    private func fitsInColumn(_ text: String) -> Bool {
        recordWidth > 0 && desktop.appearance.textWidth(text) + 8 <= recordWidth
    }

    /// The indicator is a vertical bar: the width, and the height of a single day as a fraction of the row height.
    private static let dotWidth = 4.0
    private static let markerHeightFactor = 0.8
    /// Height of a single day's bar; the color picker row consists of the same bars.
    private var markerHeight: Double { desktop.appearance.lineHeight * Self.markerHeightFactor }
    /// Width of the room for the note arrow at the end of the line.
    private static let noteArrowWidth = 20.0

    /// Diagonal arrow at the end of the line. No link: a pale button only in edit, clicking it links a note to the day.
    /// With a link: the arrow is always visible, in scroll and edit it opens the note (in locked clicks pass through the window);
    /// the link can be removed only in edit.
    @ViewBuilder private func noteArrow(_ day: Date) -> some View {
        let key = DayStore.key(for: day)
        let hasNote = entries[key]?.note != nil
        let isEdit = desktop.mode == .edit
        let isActive = hasNote ? (desktop.mode == .scroll || isEdit) : isEdit
        // The button is always in the row, and in the needed modes it only fades in: if it were inserted on entering edit,
        // every visible row would get a new view at the same moment the input fields change (a flicker hypothesis).
        Group {
            Button { openOrLinkNote(day) } label: {
                Image(systemName: "arrow.up.right")
                    .font(desktop.appearance.smallFont)
                    .frame(width: Self.noteArrowWidth, height: desktop.appearance.lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hasNote ? 0.6 : (isEdit ? 0.2 : 0))
            .padding(.top, desktop.appearance.rowPadding)
            .allowsHitTesting(isActive)
            .contextMenu {
                if hasNote && isEdit { Button("Remove Note Link") { setNote(nil, for: day) } }
            }
        }
    }

    /// With a link — opens the note. Without — links the day to a note: Obsidian and Apple Notes create the day's note
    /// (if there is none) and open it.
    private func openOrLinkNote(_ day: Date) {
        if let link = entries[DayStore.key(for: day)]?.note {
            if link.hasPrefix(AppleNotes.prefix) {
                Task { await AppleNotes.show(id: String(link.dropFirst(AppleNotes.prefix.count))) }
            } else if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        switch desktop.appearance.noteApp {
        case .obsidian, .manual:
            guard let urls = desktop.appearance.noteTargets(for: day) else { NSSound.beep(); return }
            // For a file path: creates the file if it does not exist (does nothing for links).
            desktop.appearance.createNoteFileIfNeeded(urls.open)
            setNote(urls.open.absoluteString, for: day)
            NSWorkspace.shared.open(urls.create ?? urls.open)
        case .appleNotes:
            let name = MomentFormat.string(from: day, pattern: desktop.appearance.appleNotesFormat)
            let folder = desktop.appearance.appleNotesFolder
            Task {
                // Notes creates the day's note (if there is none) and opens it; the note id is stored in the day's entry.
                guard let id = await AppleNotes.openOrCreate(name: name, folder: folder), !id.isEmpty else {
                    NSSound.beep()
                    return
                }
                setNote(AppleNotes.prefix + id, for: day)
            }
        }
    }

    /// Saves the day's note link to the file right away (nil removes it).
    private func setNote(_ note: String?, for day: Date) {
        let key = DayStore.key(for: day)
        var entry = entries[key] ?? DayEntry(text: "")
        entry.note = note
        entries[key] = entry.isEmpty ? nil : entry
        try? DayStore().setNote(note, for: key)
    }

    /// Diameter of the calendar dot before an event.
    private static let eventDot = 5.0
    /// Opacity of an event relative to the day's entry.
    private static let eventOpacity = 0.65
    /// Gap between the date column, the indicator and the entry.
    private static let dotGap = 4.0
    /// Left edge of the indicator: right after the date column, before the entry.
    private var dotX: Double { desktop.appearance.dateColumnWidth + Self.dotGap }

    /// Height of the indicator's center in the row: the visual center of capital letters and digits of the entry's first line
    /// (the middle between the baseline and the cap height), where the date sits. Not the geometric center of the row:
    /// in most fonts it is higher or lower and the bar would look shifted.
    private func centerY(in height: Double) -> Double {
        desktop.appearance.rowPadding + desktop.appearance.capCenter
    }

    private func indicatorColor(_ day: Date) -> Int? {
        entries[DayStore.key(for: day)]?.color.flatMap { Appearance.indicatorColors.indices.contains($0) ? $0 : nil }
    }

    /// This day is preceded by a month heading or a larger week gap: the period does not stretch through it.
    private func startsBlock(_ day: Date) -> Bool {
        isMonthStart(day) || (desktop.appearance.weekGap && isMonday(day))
    }

    /// Round indicator at the start of the line. Neighboring days of the same color merge into one bar with rounded ends.
    /// In edit a day without a color shows a pale outline; clicking it opens the color picker.
    @ViewBuilder private func indicator(for day: Date) -> some View {
        let w = Self.dotWidth
        let cap = w / 2
        // Half the height of a single indicator.
        let half = markerHeight / 2
        let color = indicatorColor(day)
        let isEdit = desktop.mode == .edit
        ZStack(alignment: .topLeading) {
            if let color {
                let prev = Self.calendar.date(byAdding: .day, value: -1, to: day)
                let next = Self.calendar.date(byAdding: .day, value: 1, to: day)
                let linkedPrev = !startsBlock(day) && prev.map { indicatorColor($0) == color } == true
                let linkedNext = next.map { !startsBlock($0) && indicatorColor($0) == color } == true
                GeometryReader { geo in
                    let h = geo.size.height
                    let top = linkedPrev ? 0 : centerY(in: h) - half
                    let bottom = linkedNext ? h : centerY(in: h) + half
                    UnevenRoundedRectangle(
                        topLeadingRadius: linkedPrev ? 0 : cap, bottomLeadingRadius: linkedNext ? 0 : cap,
                        bottomTrailingRadius: linkedNext ? 0 : cap, topTrailingRadius: linkedPrev ? 0 : cap)
                        .fill(Appearance.indicatorColors[color].opacity(Appearance.indicatorOpacity))
                        .frame(width: w, height: bottom - top)
                        .offset(x: dotX, y: top)
                }
                .allowsHitTesting(false)
            } else if isEdit {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: cap).strokeBorder(lineWidth: 1)
                        .opacity(0.25)
                        .frame(width: w, height: 2 * half)
                        .offset(x: dotX, y: centerY(in: geo.size.height) - half)
                }
                .allowsHitTesting(false)
            }
            if isEdit {
                Button {
                    if pickerDay == day { closePicker(for: day) } else { withAnimation(.easeOut(duration: 0.2)) { pickerDay = day } }
                } label: {
                    Color.clear.frame(width: w + 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: dotX - 6)
            }
        }
        // The bar's shape (ends, length) changes on neighbors at once when a color is chosen. Without this SwiftUI "finishes drawing"
        // it with an animation, and the rounded ends and height drift differently in neighboring rows: we change instantly.
        .transaction { $0.animation = nil }
    }

    /// Sets the day's color and writes it to the file right away.
    private func choose(_ index: Int?, for day: Date) {
        let key = DayStore.key(for: day)
        var entry = entries[key] ?? DayEntry(text: "")
        entry.color = index
        entries[key] = entry.isEmpty ? nil : entry
        try? DayStore().setColor(index, for: key)
        closePicker(for: day)
    }

    /// Closes the color row and returns the caret to this day's field (there is no field while choosing).
    private func closePicker(for day: Date) {
        withAnimation(.easeOut(duration: 0.2)) { pickerDay = nil }
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard desktop.mode == .edit, pickerDay == nil else { return }
            // The field selects all text on focus; the click on a color was just input, so we tell the window
            // that the selection must be collapsed right away (caret at the end), otherwise it will flicker.
            desktop.expectProgrammaticFocus()
            focusedDay = day
        }
    }

    /// Today's bar: extends to the left beyond the text (into the window padding) and fades to transparent at the edges.
    private var todayHighlight: some View {
        let color = desktop.appearance.highlightColor
        return LinearGradient(
            stops: [
                .init(color: color.opacity(0), location: 0),
                .init(color: color, location: 0.10),
                .init(color: color, location: 0.75),
                .init(color: color.opacity(0), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
        .padding(.leading, -Self.highlightInset)
    }

    /// The topmost fully visible day (the index is clamped to bounds: the set of days may have changed).
    private var topVisibleDay: Date {
        days[min(visibleRange.lowerBound, days.count - 1)]
    }

    private func restorePosition(_ proxy: ScrollViewProxy) {
        if desktop.mode == .locked || (desktop.mode == .move && activePeriodStart != nil) {
            scrollHome(proxy)
        } else {
            proxy.scrollTo(topVisibleDay, anchor: .top)
        }
    }

    private func isMonday(_ day: Date) -> Bool {
        Self.calendar.component(.weekday, from: day) == 2
    }

    private func isMonthStart(_ day: Date) -> Bool {
        Self.calendar.component(.day, from: day) == 1 || day == days.first
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { entries[key]?.text ?? "" },
            set: {
                var entry = entries[key] ?? DayEntry(text: "")
                entry.text = $0
                entries[key] = entry.isEmpty ? nil : entry
                dirty.insert(key)
                scheduleSave()
            })
    }

    /// The file is written one and a half seconds after the last letter, not on each one (otherwise every character rewrites
    /// the whole file and drives iCloud sync). Then a flush on leaving edit, on rereading the file and on quitting
    /// the app (`flushPending`), so at most the last few seconds can be lost on a crash.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    /// Places the caret in the field again: on today if it is on screen, otherwise on the topmost visible day.
    private func focusEditor() {
        focusedDay = nil
        // The previous attempt is cancelled: otherwise every didBecomeKey (including from reopening the window in refreshCaret)
        // would start another loop, the loops piled up, reopened the window one after another, and the feed flickered.
        focusTask?.cancel()
        focusTask = Task {
            await Task.yield()
            guard !Task.isCancelled, desktop.mode == .edit else { return }
            let todayIsVisible = days.firstIndex(of: today).map(visibleRange.contains) ?? false
            focusedDay = editingDay.flatMap { days.contains($0) ? $0 : nil }
                ?? (todayIsVisible ? today : topVisibleDay)
            // Focus is already set, but on re-entering edit the caret may not be drawn until the window is key:
            // we retry (up to a second) until the caret works.
            for attempt in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, desktop.mode == .edit else { return }
                if desktop.refreshCaret(attempt: attempt) { break }
            }
        }
    }

    /// Moves focus to the neighboring day (called from the window's key monitor).
    private func move(by step: Int, proxy: ScrollViewProxy) {
        guard let current = focusedDay, let index = days.firstIndex(of: current) else { return }
        // Month and week: past the edge of the span comes the neighboring span, as in the feed.
        if !days.indices.contains(index + step) {
            if desktop.appearance.viewKind.isPaged {
                pendingEdge = step
                periodOffset += step
            }
            return
        }
        let target = index + step
        focusedDay = days[target]
        // The feed stands still while focus walks through the window. At the edge it follows one row at a time: we show the row
        // `margin` beyond the focus, so focus does not reach the edge and the rows before it are already drawn (the feed is lazy).
        let margin = 4
        if target < visibleRange.lowerBound + margin || target > visibleRange.upperBound - margin {
            let ahead = min(max(target + step * margin, 0), days.count - 1)
            proxy.scrollTo(days[ahead])
        }
    }

    /// Rereads the file if it changed since the last read. We do not touch it in edit: the user is typing,
    /// and they have already saved their own entries.
    private func syncIfFileChanged() {
        if desktop.mode != .edit, DayStore().modificationDate != fileStamp { reload() }
    }

    private func reload() {
        // Unsaved text goes to the file before rereading, otherwise it would be overwritten by the file's entries.
        flush()
        let store = DayStore()
        do {
            entries = try store.load()
            dataProblem = nil
        } catch {
            // Could not be read (the file is downloading from iCloud or corrupted): the previous entries stay instead of an empty feed,
            // and a warning appears in the corner of the window.
            dataProblem = DayStore.problemText(for: error)
        }
        fileStamp = store.modificationDate
        // The start of the feed depends on the earliest entry; we change the array only if the bounds moved.
        let newDays = buildDays()
        if newDays != days { days = newDays }
        loadEvents()
    }

    private func buildDays() -> [Date] {
        let kind = desktop.appearance.viewKind
        return Self.days(around: today, earliest: Self.earliestDay(in: entries),
                         kind: kind.isPaged ? kind : .feed, offset: periodOffset)
    }

    /// The set of days changed: the edit caret and the visible range referred to the previous set.
    private func rebuildDays(_ proxy: ScrollViewProxy) {
        days = buildDays()
        loadEvents()
        visibleRange = 0...0
        editingDay = pendingEdge.map { $0 > 0 ? days.first : days.last } ?? nil
        pendingEdge = nil
        pickerDay = nil
        if !desktop.appearance.viewKind.isPaged {
            scrollHome(proxy)
            // A lazy feed settles exactly only after drawing: we scroll with a pause.
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                scrollHome(proxy)
            }
        }
        if desktop.mode == .edit {
            focusedDay = nil
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                if desktop.mode == .edit { focusEditor() }
            }
        }
    }

    /// Writes the day to the file. If the write fails, the day stays in dirty and is saved on the next attempt.
    private func save(_ key: String) {
        guard dirty.contains(key) else { return }
        do {
            try DayStore().set(entries[key]?.text ?? "", for: key)
            dirty.remove(key)
            dataProblem = nil
        } catch {
            dataProblem = DayStore.problemText(for: error)
        }
    }

    private func flush() {
        for key in dirty { save(key) }
    }
}


