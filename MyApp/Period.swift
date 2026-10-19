import Foundation

/// Персональный отрезок времени: название и границы (оба дня включительно, локальный часовой пояс).
struct Period: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var start: Date
    var end: Date

    /// Количество дней отрезка.
    var dayCount: Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
        return days + 1
    }

    /// Номер дня внутри периода (первый день это 1); для дней вне периода значение не имеет смысла.
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

    /// Колонки линий слева от дат: 0 стоит ближе всего к датам. Пересекающиеся отрезки получают разные колонки,
    /// внешний (начавшийся раньше и более длинный) стоит дальше вложенных. Непересекающиеся отрезки колонку делят.
    static func lanes(_ periods: [Period]) -> [UUID: Int] {
        let calendar = Calendar.current
        let items = periods
            .map { (id: $0.id, start: calendar.startOfDay(for: $0.start), end: calendar.startOfDay(for: $0.end)) }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
        var result: [UUID: Int] = [:]
        // Группа — цепочка пересекающихся отрезков; её глубина определяет, сколько колонок рядом.
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

    /// Активный отрезок: из содержащих день побеждает начавшийся позже; при равном начале более короткий.
    /// Когда вложенный отрезок кончается, активным снова становится объемлющий.
    static func active(in periods: [Period], on day: Date) -> Period? {
        periods.filter { $0.contains(day) }.max { a, b in
            a.start != b.start ? a.start < b.start : a.end > b.end
        }
    }

    /// Период, который показывает режим «Период»: самый длинный из идущих в этот день. Более короткие идут внутри него
    /// (линиями и названиями). При равной длине побеждает начавшийся раньше.
    static func longest(in periods: [Period], on day: Date) -> Period? {
        periods.filter { $0.contains(day) }.max { a, b in
            a.dayCount != b.dayCount ? a.dayCount < b.dayCount : a.start > b.start
        }
    }
}
