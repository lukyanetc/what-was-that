import SwiftUI

/// Everything about periods in the feed: lines, titles, the static layer of "Period" mode.
extension ContentView {
    /// Positions of the rows where periods start and end in the feed window (top and bottom, pt). Titles in scroll and edit
    /// smoothly follow the line using it. This is a separate observable object: while scrolling only the titles layer updates, not the whole feed.
    @Observable final class PeriodFrames {
        var frames: [Date: ClosedRange<Double>] = [:]
    }

    /// Period title in the row of its first day, to the left of the lines (locked and move).
    struct PeriodTitles: View {
        let desktop: DesktopController
        let day: Date

        var body: some View {
            let appearance = desktop.appearance
            if appearance.showsPeriodMarks, desktop.shownPeriod != nil {
                let calendar = Calendar.current
                // A period that started before the shown one gets its title in the first row of the shown period.
                let shownStart = desktop.shownPeriod.map { calendar.startOfDay(for: $0.start) }
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(appearance.periods.filter { period in
                        let start = calendar.startOfDay(for: period.start)
                        return max(start, shownStart ?? start) == day
                    }) { period in
                        ContentView.titleText(period, appearance)
                    }
                }
                .offset(x: -ContentView.titleOffset(appearance))
                .allowsHitTesting(false)
            }
        }
    }

    /// Period titles in scroll and edit: they stay at the top edge of the window while the period is visible and smoothly follow the line.
    /// Before the period starts, the title moves with the start row; at the end it rests against the period's bottom bound.
    struct StickyPeriodTitles: View {
        let desktop: DesktopController
        let days: [Date]
        let frames: PeriodFrames
        let leadingInset: Double
        @Binding var visibleRange: ClosedRange<Int>

        /// Day index in the feed; outside the feed: -1 before the first day, `days.count` after the last.
        private func index(of day: Date) -> Int {
            if let index = days.firstIndex(of: day) { return index }
            return day < (days.first ?? day) ? -1 : days.count
        }

        /// Top of each visible period's title in the feed window.
        private func placedTitles(_ appearance: Appearance) -> [(period: Period, y: Double)] {
            let calendar = Calendar.current
            // Top bound of the title: below the fade at the window edge.
            let stickyY = appearance.edgeFade
            var items: [(period: Period, y: Double)] = []
            for period in appearance.periods {
                let start = calendar.startOfDay(for: period.start)
                let end = calendar.startOfDay(for: period.end)
                let first = index(of: start), last = index(of: end)
                // Start is above the window (moving top to bottom) or in it; below the window the period is not visible yet.
                let yStart: Double
                if first < visibleRange.lowerBound {
                    yStart = -.infinity
                } else if first > visibleRange.upperBound {
                    continue
                } else if let frame = frames.frames[start] {
                    yStart = frame.lowerBound + appearance.rowPadding
                } else {
                    continue
                }
                let yEnd: Double
                if last > visibleRange.upperBound {
                    yEnd = .infinity
                } else if last < visibleRange.lowerBound {
                    continue
                } else if let frame = frames.frames[end] {
                    yEnd = frame.upperBound - appearance.rowPadding
                } else {
                    continue
                }
                let height = ContentView.titleHeight(period, appearance)
                items.append((period, max(min(max(stickyY, yStart), yEnd - height), yStart)))
            }
            // Titles that meet at one place stack one under another.
            return items.sorted { $0.y < $1.y }.reduce(into: [(period: Period, y: Double)]()) { result, item in
                let below = result.last.map { $0.y + ContentView.titleHeight($0.period, appearance) } ?? -.infinity
                result.append((item.period, max(item.y, below)))
            }
        }

        var body: some View {
            let appearance = desktop.appearance
            if appearance.showsPeriodMarks, desktop.shownPeriod == nil {
                ZStack(alignment: .topLeading) {
                    ForEach(placedTitles(appearance), id: \.period.id) { item in
                        ContentView.titleText(item.period, appearance)
                            .offset(x: leadingInset - ContentView.titleOffset(appearance), y: item.y)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
            }
        }
    }

    /// Period title: small muted font, right-aligned in the titles column, frame as tall as the date row.
    /// If the counter is on, "12 / 90" goes under the title of the running period.
    static func titleText(_ period: Period, _ appearance: Appearance) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(appearance.uppercase ? period.name.uppercased() : period.name)
                .frame(width: appearance.periodTitleWidth, height: appearance.lineHeight, alignment: .trailing)
            if let counter = appearance.counterText(period) {
                Text(counter)
                    .frame(width: appearance.periodTitleWidth, height: appearance.lineHeight, alignment: .trailing)
            }
        }
        .font(appearance.smallFont)
        .opacity(mutedOpacity)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// Title height: one line, or two with the counter.
    static func titleHeight(_ period: Period, _ appearance: Appearance) -> Double {
        appearance.lineHeight * (appearance.counterText(period) == nil ? 1 : 2)
    }

    /// Distance from the left edge of the dates to the left edge of the titles column (titles column → lines → dates).
    static func titleOffset(_ appearance: Appearance) -> Double {
        let edge = appearance.showsWeekNumber ? highlightInset : 4
        let lines = Double((appearance.periodLanes.values.max() ?? 0) + 1) * (lineWidth + lineGap)
        return edge + lines + titleGap + appearance.periodTitleWidth
    }

    var lanes: [UUID: Int] { desktop.appearance.periodLanes }

    /// Right edge of the lines column: past the week numbers column (if it is on), otherwise right at the dates.
    var lineColumnEdge: Double { desktop.appearance.showsWeekNumber ? Self.highlightInset : 4 }

    /// Left edge of a period line; column 0 (nested) is closer to the dates.
    func lineX(_ id: UUID) -> Double {
        -(lineColumnEdge + Self.lineGap + Self.lineWidth + Double(lanes[id] ?? 0) * (Self.lineWidth + Self.lineGap))
    }

    /// Width of the line columns (the outer line is farthest from the dates).
    var lineColumnWidth: Double {
        guard let maxLane = lanes.values.max() else { return 0 }
        return Double(maxLane + 1) * (Self.lineWidth + Self.lineGap)
    }

    /// Width of the titles column to the left of the lines: by the longest title, but not more than `Appearance.maxTitleWidth`.
    var titleWidth: Double { desktop.appearance.periodTitleWidth }

    /// Left inset of the feed: room for the "today" bar and week numbers, and with periods also for lines and titles.
    var leadingInset: Double {
        guard desktop.appearance.showsPeriodMarks else { return Self.highlightInset }
        let lines = max(Self.highlightInset, lineColumnEdge + lineColumnWidth + 2)
        return lines + (titleWidth > 0 ? Self.titleGap + titleWidth : 0)
    }

    /// First day of the running period in "Period" mode.
    var activePeriodStart: Date? {
        // A period that does not fit in the window is not shown separately: the feed rests on "today".
        guard desktop.appearance.viewKind == .period, desktop.periodFits else { return nil }
        return desktop.appearance.activePeriod.map { Self.calendar.startOfDay(for: $0.start) }
    }

    /// "Period" mode in locked and move: the days of the running period as a separate static layer, the start `periodOffset` pt
    /// below the top of the window (exactly, without scrolling). The feed under it is invisible but stands the same way and fades in on scroll and edit.
    @ViewBuilder var periodLayer: some View {
        // In edit the layer is removed: its input fields would duplicate the feed's fields (shared focus). By then it is already invisible.
        if desktop.appearance.viewKind == .period, desktop.mode != .edit, let period = desktop.appearance.activePeriod {
            let start = Self.calendar.startOfDay(for: period.start)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<period.dayCount, id: \.self) { offset in
                    if let day = Self.calendar.date(byAdding: .day, value: offset, to: start) { dayItem(day) }
                }
            }
            // The period's height decides whether it fits in the window (otherwise the mode shows the feed).
            .onGeometryChange(for: Double.self) { $0.size.height } action: { desktop.periodContentHeight = $0 }
            .padding(.leading, leadingInset)
            .padding(.top, desktop.periodOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(desktop.shownPeriod != nil ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: desktop.shownPeriod != nil)
            .allowsHitTesting(false)
        }
    }

    /// Where the first day of the period sits in the window: `periodOffset` pt below the top of the window. The scroll anchor sets a fraction
    /// of the height at which the same point of the row and of the window lies, so the row height is subtracted.
    var periodAnchor: UnitPoint {
        let free = desktop.screenFrame.height - periodItemHeight
        guard free > 0 else { return .top }
        return UnitPoint(x: 0, y: min(max(desktop.periodOffset / free, 0), 1))
    }

    /// Thin vertical lines to the left of the dates along the periods. `starting`: only periods starting
    /// on this day (the line goes from their title), otherwise only those that started earlier. Nested ones sit closer to the dates.
    func periodLines(on day: Date, starting: Bool) -> some View {
        let active = !desktop.appearance.showsPeriodMarks ? [] : desktop.appearance.periods.filter {
            $0.contains(day) && (Self.calendar.startOfDay(for: $0.start) == day) == starting
        }
        return ZStack(alignment: .topLeading) {
            ForEach(active) { period in
                Rectangle()
                    .fill(desktop.appearance.textColor.opacity(0.6 * desktop.appearance.textOpacity))
                    .frame(width: Self.lineWidth)
                    .offset(x: lineX(period.id))
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// "Period" mode: the feed hides (smoothly) and a static period layer lies over it. Outside this mode the view does not change.
struct PeriodSwap<Layer: View>: ViewModifier {
    let isActive: Bool
    let hidesContent: Bool
    let layer: Layer

    func body(content: Content) -> some View {
        if isActive {
            content
                .opacity(hidesContent ? 0 : 1)
                .animation(.easeOut(duration: 0.25), value: hidesContent)
                .overlay(alignment: .topLeading) { layer }
        } else {
            content
        }
    }
}
