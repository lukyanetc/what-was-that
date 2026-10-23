import EventKit
import SwiftUI

/// How to show calendar events next to a day's entry.
enum EventsMode: String, CaseIterable {
    case show, future, hide

    var title: String {
        switch self {
        case .show: "Show all"
        case .future: "Future only (past ones as “+N”)"
        case .hide: "Hide"
        }
    }
}

/// Calendar event (read-only): title, start and an "all day" flag.
struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// Color of the event's calendar.
    let color: Color
    /// Calendar priority (0 is the most important): decides the order of events with the same time and which copy stays.
    let rank: Int
}

/// Events of the Mac's system calendar via EventKit. Google Calendar shows up here if the account is added in System Settings.
/// Events are not copied into the data file: they are only read and displayed.
@Observable final class CalendarEvents {
    /// Calendars available for selection (after access is granted).
    private(set) var calendars: [(id: String, title: String, source: String, color: Color)] = []
    private(set) var isAuthorized = false
    /// Events by day: key as in `DayStore.key`; all-day events first, then by time.
    private(set) var byDay: [String: [CalendarEvent]] = [:]

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var range: ClosedRange<Date>?
    @ObservationIgnored private var calendarIDs: Set<String> = []
    /// Calendar priority: identifiers in order (the first is more important). The rest come after them.
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// Requests access (the system dialog appears once) and refreshes the list of calendars.
    func requestAccess() async {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        updateAuthorization(granted)
    }

    /// Checks already granted access without a dialog: called at launch.
    func refreshAuthorization() {
        updateAuthorization(EKEventStore.authorizationStatus(for: .event) == .fullAccess)
    }

    private func updateAuthorization(_ granted: Bool) {
        isAuthorized = granted
        guard granted else { calendars = []; byDay = [:]; return }
        calendars = store.calendars(for: .event).map {
            ($0.calendarIdentifier, $0.title, $0.source.title, $0.cgColor.map { Color(cgColor: $0) } ?? .gray)
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        }
        reload()
    }

    /// Loads events of the selected calendars for the feed's day range (bounds are the start of the first day and the end of the last).
    func load(days: [Date], calendarIDs: Set<String>, order: [String]) {
        guard let first = days.first, let last = days.last else { return }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last
        let newRange = first...end
        // Same range, same calendars and same priority: the fetch is already in place. Entering scroll and refreshing the feed
        // no longer reread events (a three-year query runs on the main thread); calendar edits arrive
        // through EKEventStoreChanged.
        let sameQuery = newRange == range && calendarIDs == self.calendarIDs
        guard !sameQuery || order != self.order else { return }
        range = newRange
        self.calendarIDs = calendarIDs
        self.order = order
        // Only the priority changed (dragging in settings): events are already read, they just need to be rearranged
        // without a new EventKit query, which was the cause of the delay while dragging.
        if sameQuery { rebuild() } else { reload() }
    }

    /// Events read from EventKit by the last query (before splitting by day and removing duplicates).
    @ObservationIgnored private var fetched: [EKEvent] = []

    private func reload() {
        guard isAuthorized, let range, !calendarIDs.isEmpty else { fetched = []; byDay = [:]; return }
        let selected = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { fetched = []; byDay = [:]; return }
        let predicate = store.predicateForEvents(withStart: range.lowerBound, end: range.upperBound, calendars: selected)
        fetched = store.events(matching: predicate)
        rebuild()
    }

    /// Distributes the events read onto days: removes duplicates and sorts with calendar priority.
    private func rebuild() {
        guard let range else { return }
        var result: [String: [CalendarEvent]] = [:]
        let calendar = Calendar.current
        // The same event can be in several calendars at once (for example, a Google invitation and an iCloud copy):
        // an event with the same title, start and end is shown once.
        // The copy from the higher-priority calendar goes first and stays (the dot color comes from it as well).
        let ranks = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func rank(_ event: EKEvent) -> Int { ranks[event.calendar.calendarIdentifier] ?? order.count }
        var seen: Set<String> = []
        for event in fetched.sorted(by: { rank($0) < rank($1) }) {
            let id = "\(event.title ?? "")|\(event.startDate.timeIntervalSince1970)|\(event.endDate.timeIntervalSince1970)|\(event.isAllDay)"
            guard seen.insert(id).inserted else { continue }
            let item = CalendarEvent(id: id, title: event.title ?? "", start: event.startDate, end: event.endDate,
                                     isAllDay: event.isAllDay,
                                     color: event.calendar.cgColor.map { Color(cgColor: $0) } ?? .gray, rank: rank(event))
            // A multi-day event lands on each of its days. The end of "until midnight" events is not included.
            var day = calendar.startOfDay(for: event.startDate)
            repeat {
                result[DayStore.key(for: day), default: []].append(item)
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? .distantFuture
            } while day < event.endDate && day <= range.upperBound
        }
        // All-day events first, then by start time; with equal time the higher-priority calendar goes first.
        byDay = result.mapValues {
            $0.sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return $0.start != $1.start ? $0.start < $1.start : $0.rank < $1.rank
            }
        }
    }

    /// A day's events according to the mode. In "future only" mode, past events are not returned but counted in `hidden`.
    func events(on day: Date, mode: EventsMode, now: Date = .now) -> (shown: [CalendarEvent], hidden: Int) {
        let all = byDay[DayStore.key(for: day)] ?? []
        switch mode {
        case .hide: return ([], 0)
        case .show: return (all, 0)
        case .future:
            let shown = all.filter { $0.end > now }
            return (shown, all.count - shown.count)
        }
    }
}
