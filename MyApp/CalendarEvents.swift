import EventKit
import SwiftUI

/// Как показывать события календаря рядом с записью дня.
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

/// Событие календаря (только чтение): название, начало и признак «весь день».
struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// Цвет календаря события.
    let color: Color
}

/// События системного календаря Mac через EventKit. Google Calendar виден здесь, если аккаунт добавлен в системные настройки.
/// События не копируются в d-cal.json: они только читаются и показываются.
@Observable final class CalendarEvents {
    /// Календари, доступные для выбора (после выдачи доступа).
    private(set) var calendars: [(id: String, title: String, source: String, color: Color)] = []
    private(set) var isAuthorized = false
    /// События по дням: ключ как у `DayStore.key`; сначала события на весь день, дальше по времени.
    private(set) var byDay: [String: [CalendarEvent]] = [:]

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var range: ClosedRange<Date>?
    @ObservationIgnored private var calendarIDs: Set<String> = []
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// Запрашивает доступ (системный диалог появляется один раз) и обновляет список календарей.
    func requestAccess() async {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        updateAuthorization(granted)
    }

    /// Проверяет уже выданный доступ без диалога: вызывается при запуске.
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

    /// Загружает события выбранных календарей за диапазон дней ленты (границы — начало первого и конец последнего дня).
    func load(days: [Date], calendarIDs: Set<String>) {
        guard let first = days.first, let last = days.last else { return }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last
        range = first...end
        self.calendarIDs = calendarIDs
        reload()
    }

    private func reload() {
        guard isAuthorized, let range, !calendarIDs.isEmpty else { byDay = [:]; return }
        let selected = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { byDay = [:]; return }
        let predicate = store.predicateForEvents(withStart: range.lowerBound, end: range.upperBound, calendars: selected)
        var result: [String: [CalendarEvent]] = [:]
        let calendar = Calendar.current
        // Одно и то же событие бывает сразу в нескольких календарях (например, приглашение в Google и копия в iCloud):
        // событие с тем же названием, началом и концом показывается один раз.
        var seen: Set<String> = []
        for event in store.events(matching: predicate) {
            let id = "\(event.title ?? "")|\(event.startDate.timeIntervalSince1970)|\(event.endDate.timeIntervalSince1970)|\(event.isAllDay)"
            guard seen.insert(id).inserted else { continue }
            let item = CalendarEvent(id: id, title: event.title ?? "", start: event.startDate, end: event.endDate,
                                     isAllDay: event.isAllDay,
                                     color: event.calendar.cgColor.map { Color(cgColor: $0) } ?? .gray)
            // Многодневное событие попадает в каждый свой день. Конец у событий «до полуночи» не включается.
            var day = calendar.startOfDay(for: event.startDate)
            repeat {
                result[DayStore.key(for: day), default: []].append(item)
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? .distantFuture
            } while day < event.endDate && day <= range.upperBound
        }
        byDay = result.mapValues { $0.sorted { $0.isAllDay != $1.isAllDay ? $0.isAllDay : $0.start < $1.start } }
    }

    /// События дня с учётом режима. В режиме «только будущие» прошедшие события не возвращаются, а считаются в `hidden`.
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
