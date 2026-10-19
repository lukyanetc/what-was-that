import Testing
import Foundation
import CoreGraphics
@testable import d_cal

struct DayStoreTests {
    private func makeStore() -> DayStore {
        DayStore(url: FileManager.default.temporaryDirectory.appending(path: "wwt-\(UUID().uuidString).json"))
    }

    @Test func missingFileIsEmpty() throws {
        #expect(try makeStore().load().isEmpty)
    }

    @Test func setAndLoadRoundTrip() throws {
        let store = makeStore()
        try store.set("🚧 Ремонт", for: "2026-03-10")
        try store.set("Сантехник", for: "2026-03-12")
        #expect(try store.load() == ["2026-03-10": DayEntry(text: "🚧 Ремонт"), "2026-03-12": DayEntry(text: "Сантехник")])
    }

    @Test func emptyTextRemovesEntry() throws {
        let store = makeStore()
        try store.set("текст", for: "2026-03-10")
        try store.set("", for: "2026-03-10")
        #expect(try store.load().isEmpty)
    }

    @Test func corruptFileThrowsAndIsNotOverwritten() throws {
        let store = makeStore()
        try Data("не json".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.set("текст", for: "2026-03-10") }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "не json")
    }

    @Test func multilineTextIsKeptAsTyped() throws {
        let store = makeStore()
        try store.set("Первая\n\n  вторая  \nтретья", for: "2026-03-10")
        #expect(try store.load()["2026-03-10"]?.text == "Первая\n\n  вторая  \nтретья")
    }

    @Test func colorSurvivesTextChangesAndEntryWithOnlyColorIsKept() throws {
        let store = makeStore()
        try store.setColor(3, for: "2026-03-10")
        #expect(try store.load() == ["2026-03-10": DayEntry(text: "", color: 3)])
        try store.set("Ремонт", for: "2026-03-10")
        try store.set("", for: "2026-03-10")
        #expect(try store.load()["2026-03-10"]?.color == 3)
        try store.setColor(nil, for: "2026-03-10")
        #expect(try store.load().isEmpty)
    }

    @Test func evictedICloudFileThrowsInsteadOfBeingOverwritten() throws {
        let store = makeStore()
        let placeholder = store.url.deletingLastPathComponent().appending(path: ".\(store.url.lastPathComponent).icloud")
        try Data().write(to: placeholder)
        defer { try? FileManager.default.removeItem(at: placeholder) }
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.set("текст", for: "2026-03-10") }
        #expect(!FileManager.default.fileExists(atPath: store.url.path(percentEncoded: false)))
    }

    @Test func problemTextTellsCorruptFromEvictedFromWriteError() throws {
        let store = makeStore()
        try Data("не json".utf8).write(to: store.url)
        defer { try? FileManager.default.removeItem(at: store.url) }
        do { _ = try store.load() } catch { #expect(DayStore.problemText(for: error).contains("corrupted")) }
        #expect(DayStore.problemText(for: CocoaError(.fileReadNoSuchFile)).contains("iCloud"))
        #expect(DayStore.problemText(for: CocoaError(.fileWriteNoPermission)).contains("Could not"))
    }

    @Test func pathWithSpacesIsFound() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "d cal \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DayStore(url: folder.appending(path: DayStore.fileName))
        try store.set("текст", for: "2026-03-10")
        #expect(try store.load()["2026-03-10"]?.text == "текст")
        #expect(store.modificationDate != nil)
    }

    @Test func legacyFileIsCopiedUnderNewNameOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "wwt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appending(path: "d-cal.json")
        try DayStore(url: old).set("старая запись", for: "2026-03-10")
        DayStore.migrateLegacyFile(in: folder)
        let new = DayStore(url: folder.appending(path: DayStore.fileName))
        #expect(try new.load()["2026-03-10"]?.text == "старая запись")
        #expect(FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        // Повторно новый файл не перезаписывается.
        try new.set("новая запись", for: "2026-03-11")
        DayStore.migrateLegacyFile(in: folder)
        #expect(try new.load()["2026-03-11"]?.text == "новая запись")
    }

    @Test func keyUsesLocalDay() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 23, minute: 30))!
        #expect(DayStore.key(for: date) == "2026-03-10")
    }
}

struct ExportTests {
    private func day(_ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    @Test func daysRunFromFirstEntryToTodayIncludingEmpty() {
        let entries = ["2026-03-10": DayEntry(text: "a"), "2026-03-12": DayEntry(text: "b")]
        #expect(Export.days(entries, today: day(3, 11)) == ["2026-03-10", "2026-03-11", "2026-03-12"])
        #expect(Export.days(entries, today: day(3, 14)).last == "2026-03-14")
        #expect(Export.days([:], today: day(3, 14)).isEmpty)
    }

    @Test func markdownListsEmptyDaysAndIndentsLines() {
        let entries = ["2026-03-10": DayEntry(text: "Ремонт\nвторая", note: "https://example.com/n"),
                       "2026-03-12": DayEntry(text: "b", note: AppleNotes.prefix + "x-coredata://1")]
        #expect(Export.markdown(entries, today: day(3, 11)) == """
            - 2026-03-10 — Ремонт
              вторая [note](https://example.com/n)
            - 2026-03-11
            - 2026-03-12 — b

            """)
    }

    @Test func jsonHasEveryDayAndLoadsBack() throws {
        let entries = ["2026-03-10": DayEntry(text: "a", color: 2), "2026-03-12": DayEntry(text: "b")]
        let data = try Export.json(entries, today: day(3, 11))
        let decoded = try JSONDecoder().decode([String: DayEntry].self, from: data)
        #expect(decoded.keys.sorted() == ["2026-03-10", "2026-03-11", "2026-03-12"])
        #expect(decoded["2026-03-11"] == DayEntry(text: ""))
        #expect(decoded["2026-03-10"] == entries["2026-03-10"])
    }
}

struct SettingsFileTests {
    @Test func partialFileDecodesAndIgnoresUnknownKeys() throws {
        let json = Data(#"{"fontSize": 15, "uppercase": false, "future": 1}"#.utf8)
        let file = try JSONDecoder().decode(SettingsFile.self, from: json)
        #expect(file.fontSize == 15)
        #expect(file.uppercase == false)
        #expect(file.width == nil)
        #expect(file.periods == nil)
    }

    @Test func periodsSurviveRoundTrip() throws {
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let period = Period(name: "Ремонт", start: start, end: start.addingTimeInterval(86400 * 9))
        let data = try JSONEncoder().encode(SettingsFile(periods: [period]))
        #expect(try JSONDecoder().decode(SettingsFile.self, from: data).periods == [period])
    }

    @Test func notAJsonObjectThrows() {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SettingsFile.self, from: Data("не json".utf8)) }
    }
}

struct PeriodTests {
    private func day(_ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    private func period(_ name: String, _ start: Date, _ end: Date) -> Period {
        Period(name: name, start: start, end: end)
    }

    @Test func containsIsInclusiveAndIgnoresTime() {
        let sprint = period("Спринт", day(10, 1), day(10, 24))
        let evening = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 59))!
        #expect(sprint.contains(day(10, 1)))
        #expect(sprint.contains(evening))
        #expect(!sprint.contains(day(9, 30)))
        #expect(!sprint.contains(day(10, 25)))
        #expect(sprint.dayCount == 24)
    }

    @Test func dayNumberCountsFromOne() {
        let sprint = period("Спринт", day(10, 1), day(10, 24))
        #expect(sprint.dayNumber(on: day(10, 1)) == 1)
        #expect(sprint.dayNumber(on: day(10, 18)) == 18)
        #expect(sprint.dayNumber(on: day(10, 24)) == sprint.dayCount)
    }

    @Test func estimatedHeightGrowsWithLengthAndFlagsLongPeriod() {
        let appearance = Appearance()
        let week = appearance.estimatedHeight(of: period("Неделя", day(10, 5), day(10, 11)))
        let quarter = appearance.estimatedHeight(of: period("Квартал", day(10, 5), day(1, 3).addingTimeInterval(86400 * 365)))
        #expect(week > 0)
        #expect(quarter > week * 10)
    }

    @Test func expiredOnlyAfterEndDay() {
        let sprint = period("Спринт", day(10, 1), day(10, 24))
        #expect(!sprint.isExpired(on: day(10, 24)))
        #expect(sprint.isExpired(on: day(10, 25)))
    }

    @Test func noActivePeriodOutsideAll() {
        let periods = [period("Спринт", day(10, 1), day(10, 24))]
        #expect(Period.active(in: periods, on: day(10, 25)) == nil)
        #expect(Period.active(in: periods, on: day(9, 30)) == nil)
    }

    @Test func laterStartWinsAndOuterReturnsAfterNestedEnds() {
        let outer = period("Квартал", day(10, 1), day(12, 31))
        let nested = period("Спринт", day(10, 10), day(10, 20))
        #expect(Period.active(in: [outer, nested], on: day(10, 15))?.name == "Спринт")
        #expect(Period.active(in: [nested, outer], on: day(10, 15))?.name == "Спринт")
        #expect(Period.active(in: [outer, nested], on: day(10, 21))?.name == "Квартал")
    }

    @Test func nestedPeriodStandsCloserToDates() {
        let outer = period("Квартал", day(10, 1), day(12, 31))
        let nested = period("Спринт", day(10, 10), day(10, 20))
        let lone = period("Отпуск", day(1, 5), day(1, 10))
        let lanes = Period.lanes([nested, outer, lone])
        #expect(lanes[nested.id] == 0)
        #expect(lanes[outer.id] == 1)
        #expect(lanes[lone.id] == 0)
    }

    @Test func partlyOverlappingPeriodsGetDifferentLanes() {
        let first = period("А", day(10, 1), day(10, 24))
        let second = period("Б", day(10, 20), day(11, 5))
        let lanes = Period.lanes([first, second])
        #expect(Set(lanes.values) == [0, 1])
    }

    @Test func longestPeriodIsShownAndShorterOnesStayInside() {
        let outer = period("Квартал", day(10, 1), day(12, 31))
        let nested = period("Спринт", day(10, 10), day(10, 20))
        #expect(Period.longest(in: [nested, outer], on: day(10, 15))?.name == "Квартал")
        #expect(Period.longest(in: [outer, nested], on: day(11, 15))?.name == "Квартал")
        #expect(Period.longest(in: [outer, nested], on: day(9, 15)) == nil)
    }

    @Test func equalLengthEarlierStartWins() {
        let first = period("Первый", day(10, 1), day(10, 10))
        let second = period("Второй", day(10, 5), day(10, 14))
        #expect(Period.longest(in: [second, first], on: day(10, 7))?.name == "Первый")
    }

    @Test func sameStartShorterWins() {
        let long = period("Долгий", day(10, 1), day(10, 31))
        let short = period("Короткий", day(10, 1), day(10, 7))
        #expect(Period.active(in: [long, short], on: day(10, 5))?.name == "Короткий")
        #expect(Period.active(in: [long, short], on: day(10, 8))?.name == "Долгий")
    }
}

struct AppearanceTests {
    @Test func darkWallpaperLightensColor() {
        #expect(Appearance.adjust(brightness: 0.2, luminance: 0.1) == 0.9)
        #expect(Appearance.adjust(brightness: 0.95, luminance: 0.1) == 0.95)
    }

    @Test func lightWallpaperDarkensColor() {
        #expect(Appearance.adjust(brightness: 1, luminance: 0.9) == 0.25)
        #expect(Appearance.adjust(brightness: 0.1, luminance: 0.9) == 0.1)
    }

    @Test func cropRectWhenImageMatchesScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let rect = Wallpaper.cropRect(window: CGRect(x: 0, y: 0, width: 500, height: 500), screen: screen,
                                      imageSize: CGSize(width: 2000, height: 1000))
        #expect(rect == CGRect(x: 0, y: 0, width: 0.5, height: 1))
    }

    @Test func cropRectCutsSidesOfWiderImage() {
        // Картинка вдвое шире экрана: на экране видна только средняя половина по ширине.
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let rect = Wallpaper.cropRect(window: screen, screen: screen, imageSize: CGSize(width: 2000, height: 1000))
        #expect(rect == CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
    }

}

struct MomentFormatTests {
    /// 10 марта 2026 — вторник, 69-й день года, ISO-неделя 11.
    private let date = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!

    @Test(arguments: [
        ("DD ddd", "10 Tue"), ("ddd DD", "Tue 10"), ("DD.MM", "10.03"), ("DD.MM.YYYY", "10.03.2026"),
        ("MM/DD/YYYY", "03/10/2026"), ("YYYY-MM-DD", "2026-03-10"), ("MMMM Do, YYYY", "March 10th, 2026"),
        ("D M YY", "10 3 26"), ("dddd MMM", "Tuesday Mar"), ("dd", "Tu"),
    ])
    func formats(pattern: String, expected: String) {
        #expect(MomentFormat.string(from: date, pattern: pattern) == expected)
    }

    @Test(arguments: [
        ("DDD DDDo DDDD", "69 69th 069"), ("Q Qo", "1 1st"), ("W WW Wo", "11 11 11th"),
        ("GGGG GG", "2026 26"), ("E d do", "2 2 2nd"),
    ])
    func calendarTokens(pattern: String, expected: String) {
        #expect(MomentFormat.string(from: date, pattern: pattern) == expected)
    }

    @Test func escapedTextAndUnknownCharactersAreKept() {
        #expect(MomentFormat.string(from: date, pattern: "[Today:] DD, hh") == "Today: 10, hh")
    }

    @Test func ordinals() {
        let first = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 12))!
        let second = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 22, hour: 12))!
        let eleventh = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 12))!
        #expect(MomentFormat.string(from: first, pattern: "Do") == "1st")
        #expect(MomentFormat.string(from: second, pattern: "Do") == "22nd")
        #expect(MomentFormat.string(from: eleventh, pattern: "Do") == "11th")
    }
}
