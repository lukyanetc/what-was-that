import Foundation

/// A personal span of time: a name and bounds (both days inclusive, local time zone).
struct Period: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var start: Date
    var end: Date

    /// Number of days in the span.
    var dayCount: Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
        return days + 1
    }

    /// Day number within the period (the first day is 1); meaningless for days outside the period.
    func dayNumber(on day: Date) -> Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: day)).day ?? 0
        return days + 1
    }

    func contains(_ day: Date) -> Bool {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: day)
        return calendar.startOfDay(for: start) <= day && day <= calendar.startOfDay(for: end)
    }

    func isExpired(on day: Date) -> Bool {
        let calendar = Calendar.current
        return calendar.startOfDay(for: end) < calendar.startOfDay(for: day)
    }

    /// Line columns to the left of the dates: 0 is closest to the dates. Overlapping spans get different columns,
    /// the outer one (started earlier and longer) sits farther out than nested ones. Non-overlapping spans share a column.
    static func lanes(_ periods: [Period]) -> [UUID: Int] {
        let calendar = Calendar.current
        let items = periods
            .map { (id: $0.id, start: calendar.startOfDay(for: $0.start), end: calendar.startOfDay(for: $0.end)) }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
        var result: [UUID: Int] = [:]
        // A group is a chain of overlapping spans; its depth determines how many columns sit side by side.
        var group: [(id: UUID, end: Date, lane: Int)] = []
        var groupEnd = Date.distantPast
        func closeGroup() {
            let depth = (group.map(\.lane).max() ?? -1) + 1
            for item in group { result[item.id] = depth - 1 - item.lane }
            group = []
        }
        for item in items {
            if item.start > groupEnd { closeGroup() }
            let used = Set(group.filter { $0.end >= item.start }.map(\.lane))
            let lane = (0...).first { !used.contains($0) } ?? 0
            group.append((item.id, item.end, lane))
            groupEnd = max(groupEnd, item.end)
        }
        closeGroup()
        return result
    }

    /// Active span: among those containing the day, the one that started later wins; on equal start, the shorter one.
    /// When a nested span ends, the enclosing one becomes active again.
    static func active(in periods: [Period], on day: Date) -> Period? {
        periods.filter { $0.contains(day) }.max { a, b in
            a.start != b.start ? a.start < b.start : a.end > b.end
        }
    }

    /// The period shown by "Period" mode: the longest of those running on this day. Shorter ones go inside it
    /// (as lines and titles). On equal length, the one that started earlier wins.
    static func longest(in periods: [Period], on day: Date) -> Period? {
        periods.filter { $0.contains(day) }.max { a, b in
            a.dayCount != b.dayCount ? a.dayCount < b.dayCount : a.start > b.start
        }
    }
}
