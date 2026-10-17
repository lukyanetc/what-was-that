import Testing
import Foundation
import CoreGraphics
@testable import d_cal

struct DayStoreTests {
    private func makeStore() -> DayStore {
        DayStore(url: FileManager.default.temporaryDirectory.appending(path: "d-cal-\(UUID().uuidString).json"))
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

    @Test func flattenLinesJoinsEntriesIntoOneLine() throws {
        let store = makeStore()
        try store.set("Первая\n\n  вторая  \nтретья", for: "2026-03-10")
        try store.set("одна строка", for: "2026-03-11")
        try store.flattenLines()
        #expect(try store.load() == ["2026-03-10": DayEntry(text: "Первая вторая третья"),
                                     "2026-03-11": DayEntry(text: "одна строка")])
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

    @Test func keyUsesLocalDay() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 23, minute: 30))!
        #expect(DayStore.key(for: date) == "2026-03-10")
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
