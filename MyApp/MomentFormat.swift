import Foundation

/// Формат даты в духе moment.js, только дата без времени: YYYY MM DD ddd dddd Do Q W и т.д.
/// Текст в [квадратных скобках] выводится как есть. Названия на английском, неизвестные символы выводятся как есть.
enum MomentFormat {
    private static let tokens = [
        "YYYY", "YY", "Y", "Q", "Qo", "MMMM", "MMM", "MM", "Mo", "M", "DDDD", "DDDo", "DDD", "DD", "Do", "D",
        "dddd", "ddd", "dd", "do", "d", "e", "E", "ww", "wo", "w", "WW", "Wo", "W", "gggg", "gg", "GGGG", "GG",
    ].sorted { $0.count > $1.count }

    /// Календари создаются один раз: форматируется каждая строка ленты при каждой перерисовке.
    private static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }()
    private static let isoCalendar = Calendar(identifier: .iso8601)

    static func string(from date: Date, pattern: String) -> String {
        let calendar = gregorian
        let iso = isoCalendar

        var result = ""
        var rest = Substring(pattern)
        while let first = rest.first {
            if first == "[", let close = rest.firstIndex(of: "]") {
                result += rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
            } else if let token = tokens.first(where: { rest.hasPrefix($0) }) {
                result += value(of: token, date: date, calendar: calendar, iso: iso)
                rest = rest.dropFirst(token.count)
            } else {
                result.append(first)
                rest = rest.dropFirst()
            }
        }
        return result
    }

    private static func value(of token: String, date: Date, calendar: Calendar, iso: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let year = parts.year ?? 0, month = parts.month ?? 1, day = parts.day ?? 1
        let weekday = (parts.weekday ?? 1) - 1  // 0 — воскресенье
        switch token {
        case "YYYY": return String(format: "%04d", year)
        case "YY": return String(format: "%02d", year % 100)
        case "Y": return String(year)
        case "Q": return String((month - 1) / 3 + 1)
        case "Qo": return ordinal((month - 1) / 3 + 1)
        case "M": return String(month)
        case "Mo": return ordinal(month)
        case "MM": return String(format: "%02d", month)
        case "MMM": return calendar.shortMonthSymbols[month - 1]
        case "MMMM": return calendar.monthSymbols[month - 1]
        case "D": return String(day)
        case "Do": return ordinal(day)
        case "DD": return String(format: "%02d", day)
        case "DDD": return String(dayOfYear(date, calendar))
        case "DDDo": return ordinal(dayOfYear(date, calendar))
        case "DDDD": return String(format: "%03d", dayOfYear(date, calendar))
        case "d", "e": return String(weekday)
        case "do": return ordinal(weekday)
        case "dd": return String(calendar.shortWeekdaySymbols[weekday].prefix(2))
        case "ddd": return calendar.shortWeekdaySymbols[weekday]
        case "dddd": return calendar.weekdaySymbols[weekday]
        case "E": return String(weekday == 0 ? 7 : weekday)
        case "w": return String(calendar.component(.weekOfYear, from: date))
        case "wo": return ordinal(calendar.component(.weekOfYear, from: date))
        case "ww": return String(format: "%02d", calendar.component(.weekOfYear, from: date))
        case "W": return String(iso.component(.weekOfYear, from: date))
        case "Wo": return ordinal(iso.component(.weekOfYear, from: date))
        case "WW": return String(format: "%02d", iso.component(.weekOfYear, from: date))
        case "gggg": return String(format: "%04d", calendar.component(.yearForWeekOfYear, from: date))
        case "gg": return String(format: "%02d", calendar.component(.yearForWeekOfYear, from: date) % 100)
        case "GGGG": return String(format: "%04d", iso.component(.yearForWeekOfYear, from: date))
        case "GG": return String(format: "%02d", iso.component(.yearForWeekOfYear, from: date) % 100)
        default: return token
        }
    }

    private static func dayOfYear(_ date: Date, _ calendar: Calendar) -> Int {
        calendar.ordinality(of: .day, in: .year, for: date) ?? 1
    }

    private static func ordinal(_ number: Int) -> String {
        let suffix = switch (number % 100, number % 10) {
        case (11...13, _): "th"
        case (_, 1): "st"
        case (_, 2): "nd"
        case (_, 3): "rd"
        default: "th"
        }
        return "\(number)\(suffix)"
    }
}
