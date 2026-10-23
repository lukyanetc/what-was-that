import SwiftUI
import Carbon.HIToolbox

/// The time span the window shows: a continuous feed, a calendar month or a week (Mon–Sun).
enum ViewKind: String, CaseIterable {
    // Order in the menu and in settings: Range next to Feed, Month and Week after (they have their own role).
    case feed, period, month, week

    var title: String {
        switch self {
        case .feed: "Feed"
        case .month: "Month"
        case .week: "Week"
        case .period: "Range"
        }
    }

    /// Month and week page by span; the feed and period do not.
    var isPaged: Bool { self == .month || self == .week }
}

/// The notes app in which the day's note opens.
enum NoteApp: String, CaseIterable {
    case obsidian, appleNotes, manual

    var title: String {
        switch self {
        case .obsidian: "Obsidian"
        case .appleNotes: "Apple Notes"
        case .manual: "Other (manual)"
        }
    }
}

/// Appearance: text color (adjusted to the brightness of the wallpaper under the feed), opacity, window width,
/// the highlight line of today, the date and month heading formats. Everything is stored in UserDefaults.
@Observable final class Appearance {
    /// The time span shown.
    var viewKind: ViewKind {
        didSet {
            UserDefaults.standard.set(viewKind.rawValue, forKey: "viewKind")
            onLayoutChange?()
        }
    }
    /// Color chosen by the user (hue).
    var color: Color { didSet { UserDefaults.standard.set(color.hex, forKey: "textColor") } }
    /// Adjust the lightness of the color to the wallpaper.
    var adapts: Bool { didSet { UserDefaults.standard.set(adapts, forKey: "adaptsToWallpaper") } }
    /// Text opacity, 0.2 ... 1.
    var textOpacity: Double { didSet { UserDefaults.standard.set(textOpacity, forKey: "textOpacity") } }
    /// Window width (line length).
    var width: Double {
        didSet {
            UserDefaults.standard.set(width, forKey: "windowWidth")
            onLayoutChange?()
        }
    }
    /// Height of the feed fade at the top and bottom edge of the window, pt.
    var edgeFade: Double { didSet { UserDefaults.standard.set(edgeFade, forKey: "edgeFade") } }
    /// Personal periods (UserDefaults, JSON). Lines and titles are visible in all views; "Period" mode shows the active one.
    var periods: [Period] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(periods), forKey: "periods")
            updatePeriodMetrics()
            onLayoutChange?()
        }
    }
    /// Whether to show periods in "Feed" mode. In "Period" mode they are always visible, in "Month" and "Week" they are absent.
    var showsPeriodsInFeed: Bool { didSet { UserDefaults.standard.set(showsPeriodsInFeed, forKey: "showsPeriodsInFeed") } }
    /// Day counter under the title of the running period ("12 / 90").
    var showsPeriodCounter: Bool {
        didSet {
            UserDefaults.standard.set(showsPeriodCounter, forKey: "showsPeriodCounter")
            updatePeriodMetrics()
        }
    }
    /// Offset of the period's first day from the top of the window, pt; in "Move window" mode it is moved vertically with the mouse.
    /// By default the period sits closer to the middle of the screen (30% of the height).
    var periodOffset: Double { didSet { UserDefaults.standard.set(periodOffset, forKey: "periodOffset") } }

    /// Room for the period in the window: from its start to the bottom of the screen minus the fade.
    func periodRoom(screenHeight: Double) -> Double { screenHeight - periodOffset - edgeFade }

    /// Estimate of the period's height in the feed: rows, month headings and week gaps. Settings need it to
    /// warn that the period will not fit in the window (the window itself measures the height).
    func estimatedHeight(of period: Period) -> Double {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: period.start)
        var height = 0.0
        for offset in 0..<period.dayCount {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            height += lineHeight + 2 * rowPadding
            if calendar.component(.day, from: day) == 1 {
                if showsMonth { height += lineHeight + 24 }
            } else if weekGap && calendar.component(.weekday, from: day) == 2 {
                height += 12
            }
        }
        return height
    }

    /// "12 / 90" for the running period, if the counter is on.
    func counterText(_ period: Period) -> String? {
        guard showsPeriodCounter, period.contains(.now) else { return nil }
        return "\(period.dayNumber(on: .now)) / \(period.dayCount)"
    }

    /// Whether period lines and titles are being drawn now.
    var showsPeriodMarks: Bool {
        !periods.isEmpty && (viewKind == .period || (viewKind == .feed && showsPeriodsInFeed))
    }
    /// Line column of each period (0 is closer to the dates) and the width of the titles column; recomputed when the
    /// list, font and case change, not on every row render.
    private(set) var periodLanes: [UUID: Int] = [:]
    private(set) var periodTitleWidth = 0.0
    static let maxTitleWidth = 96.0
    /// The period shown by "Period" mode: the longest of those running today (the others go inside it).
    var activePeriod: Period? { Period.longest(in: periods, on: .now) }
    /// Color and opacity of today's highlight line; nil means the text color at 15% opacity.
    var highlight: Color? { didSet { UserDefaults.standard.set(highlight?.hex, forKey: "highlightColor") } }
    /// Date format in a day row (moment.js style, see MomentFormat).
    var dateFormat: String {
        didSet {
            UserDefaults.standard.set(dateFormat, forKey: "dateFormatPattern")
            dateColumnWidth = measureDateColumn()
        }
    }
    /// Whether to show month headings and in which format.
    var showsMonth: Bool { didSet { UserDefaults.standard.set(showsMonth, forKey: "showsMonth") } }
    var monthFormat: String { didSet { UserDefaults.standard.set(monthFormat, forKey: "monthFormatPattern") } }
    /// Month heading in bold.
    var monthBold: Bool { didSet { UserDefaults.standard.set(monthBold, forKey: "monthBold") } }
    /// Date and month in uppercase.
    var uppercase: Bool {
        didSet {
            UserDefaults.standard.set(uppercase, forKey: "uppercase")
            dateColumnWidth = measureDateColumn()
            updatePeriodMetrics()
        }
    }
    /// Feed font: a family from `fonts` or `systemFont` (system monospaced).
    var fontName: String {
        didSet {
            UserDefaults.standard.set(fontName, forKey: "fontName")
            dateColumnWidth = measureDateColumn()
            updatePeriodMetrics()
        }
    }
    /// Size of the main font, pt (13 by default, like `.body`).
    var fontSize: Double {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
            dateColumnWidth = measureDateColumn()
            updatePeriodMetrics()
        }
    }
    /// Vertical padding above and below inside a day row, pt; the gap between rows is twice as large.
    var rowPadding: Double { didSet { UserDefaults.standard.set(rowPadding, forKey: "rowPadding") } }
    /// Width of the date column, see `measureDateColumn`.
    private(set) var dateColumnWidth = 0.0
    /// Week number (ISO) on the right in the Monday row.
    var showsWeekNumber: Bool { didSet { UserDefaults.standard.set(showsWeekNumber, forKey: "showsWeekNumber") } }
    /// Larger gap before every Monday.
    var weekGap: Bool { didSet { UserDefaults.standard.set(weekGap, forKey: "weekGap") } }
    /// How to show calendar events and from which calendars (EventKit identifiers).
    var eventsMode: EventsMode { didSet { UserDefaults.standard.set(eventsMode.rawValue, forKey: "eventsMode") } }
    /// Calendar priority (order in the settings list): identifiers, the first is shown higher.
    var eventCalendarOrder: [String] {
        didSet { UserDefaults.standard.set(eventCalendarOrder, forKey: "eventCalendarOrder") }
    }
    var eventCalendarIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(eventCalendarIDs), forKey: "eventCalendarIDs") }
    }
    /// Notes app and Obsidian settings: vault, folder and file name format (moment.js style).
    var noteApp: NoteApp { didSet { UserDefaults.standard.set(noteApp.rawValue, forKey: "noteApp") } }
    var obsidianVault: String { didSet { UserDefaults.standard.set(obsidianVault, forKey: "obsidianVault") } }
    var obsidianFolder: String { didSet { UserDefaults.standard.set(obsidianFolder, forKey: "obsidianFolder") } }
    var obsidianFileFormat: String {
        didSet { UserDefaults.standard.set(obsidianFileFormat, forKey: "obsidianFileFormat") }
    }
    /// Apple Notes: folder (empty means the default folder) and the day's note name format.
    var appleNotesFolder: String { didSet { UserDefaults.standard.set(appleNotesFolder, forKey: "appleNotesFolder") } }
    var appleNotesFormat: String { didSet { UserDefaults.standard.set(appleNotesFormat, forKey: "appleNotesFormat") } }
    /// Check for updates at launch (at most once a day).
    var checksUpdatesAtLaunch: Bool {
        didSet { UserDefaults.standard.set(checksUpdatesAtLaunch, forKey: "checksUpdatesAtLaunch") }
    }
    /// Global hotkey: key code, Carbon modifiers and a label for display ("⌥M"). Changed via `setHotKey`.
    var hotKeyCode: Int { didSet { UserDefaults.standard.set(hotKeyCode, forKey: "hotKeyCode") } }
    var hotKeyModifiers: Int { didSet { UserDefaults.standard.set(hotKeyModifiers, forKey: "hotKeyModifiers") } }
    var hotKeyLabel: String { didSet { UserDefaults.standard.set(hotKeyLabel, forKey: "hotKeyLabel") } }
    /// Called after the hotkey changes: the controller re-registers it.
    @ObservationIgnored var onHotKeyChange: (() -> Void)?
    /// Opt+M.
    static let defaultHotKey = (code: kVK_ANSI_M, modifiers: optionKey, label: "⌥M")

    func setHotKey(code: Int, modifiers: Int, label: String) {
        hotKeyCode = code
        hotKeyModifiers = modifiers
        hotKeyLabel = label
        onHotKeyChange?()
    }

    /// "Other (manual)": a link template (`scheme://…`) or a file path (`/…`, `~/…`); `{date format}` is replaced
    /// with the day's date (as in moment.js).
    var noteTemplate: String { didSet { UserDefaults.standard.set(noteTemplate, forKey: "noteTemplate") } }
    /// Brightness of the wallpaper under the feed, 0 (black) ... 1 (white).
    private(set) var luminance = 0.2
    /// Whether the wallpaper could be measured (otherwise brightness is derived from the system dark/light theme).
    private(set) var isMeasured = false
    /// Called when the width or time span changes: the window is fitted to them.
    @ObservationIgnored var onLayoutChange: (() -> Void)?

    static let widthRange = 240.0...800.0
    static let fontSizeRange = 10.0...24.0
    static let rowPaddingRange = 0.0...6.0
    /// 9 pastel colors of the day indicator (hue, saturation 0.52, brightness 0.95); the file stores the number.
    static let indicatorColors: [Color] = [0.0, 0.07, 0.14, 0.33, 0.48, 0.6, 0.75, 0.9]
        .map { Color(hue: $0, saturation: 0.52, brightness: 0.95) } + [Color(white: 0.75)]
    /// Opacity with which indicator colors are shown in the feed and in the color picker row.
    static let indicatorOpacity = 0.65

    static let systemFont = "System"
    /// Default font (first launch): the bundled JetBrains Mono.
    static let defaultFont = "JetBrains Mono"
    /// Bundled Google Fonts (OFL license, files in MyApp/Fonts), all with Cyrillic.
    static let fonts = ["JetBrains Mono", "IBM Plex Mono", "Fira Code", "Geist Mono"]

    /// Registers the bundled fonts in the process (once).
    private static let registerFonts: Void = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, nil)
    }()

    init() {
        _ = Self.registerFonts
        let defaults = UserDefaults.standard
        // A saved font that is no longer in the list (for example, the removed Inter) is replaced with the system one.
        let savedFont = defaults.string(forKey: "fontName") ?? Self.defaultFont
        fontName = savedFont == Self.systemFont || Self.fonts.contains(savedFont) ? savedFont : Self.systemFont
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 14
        viewKind = defaults.string(forKey: "viewKind").flatMap { ViewKind(rawValue: $0) } ?? .feed
        periods = defaults.data(forKey: "periods").flatMap { try? JSONDecoder().decode([Period].self, from: $0) } ?? []
        showsPeriodsInFeed = defaults.object(forKey: "showsPeriodsInFeed") as? Bool ?? true
        showsPeriodCounter = defaults.object(forKey: "showsPeriodCounter") as? Bool ?? false
        periodOffset = defaults.object(forKey: "periodOffset") as? Double ?? (NSScreen.main?.frame.height ?? 800) * 0.3
        rowPadding = defaults.object(forKey: "rowPadding") as? Double ?? 2
        color = defaults.string(forKey: "textColor").flatMap { Color(hex: $0) } ?? .white
        adapts = defaults.object(forKey: "adaptsToWallpaper") as? Bool ?? true
        textOpacity = defaults.object(forKey: "textOpacity") as? Double ?? 1
        width = defaults.object(forKey: "windowWidth") as? Double ?? 400
        edgeFade = defaults.object(forKey: "edgeFade") as? Double ?? 48
        highlight = defaults.string(forKey: "highlightColor").flatMap { Color(hex: $0) }
        dateFormat = defaults.string(forKey: "dateFormatPattern") ?? "DD ddd"
        showsMonth = defaults.object(forKey: "showsMonth") as? Bool ?? true
        monthFormat = defaults.string(forKey: "monthFormatPattern") ?? "MMMM YYYY"
        monthBold = defaults.object(forKey: "monthBold") as? Bool ?? false
        uppercase = defaults.object(forKey: "uppercase") as? Bool ?? true
        showsWeekNumber = defaults.object(forKey: "showsWeekNumber") as? Bool ?? false
        weekGap = defaults.object(forKey: "weekGap") as? Bool ?? true
        eventsMode = defaults.string(forKey: "eventsMode").flatMap { EventsMode(rawValue: $0) } ?? .hide
        eventCalendarIDs = Set(defaults.stringArray(forKey: "eventCalendarIDs") ?? [])
        eventCalendarOrder = defaults.stringArray(forKey: "eventCalendarOrder") ?? []
        noteApp = defaults.string(forKey: "noteApp").flatMap { NoteApp(rawValue: $0) } ?? .obsidian
        obsidianVault = defaults.string(forKey: "obsidianVault") ?? ""
        obsidianFolder = defaults.string(forKey: "obsidianFolder") ?? ""
        obsidianFileFormat = defaults.string(forKey: "obsidianFileFormat") ?? "YYYY-MM-DD"
        appleNotesFolder = defaults.string(forKey: "appleNotesFolder") ?? ""
        appleNotesFormat = defaults.string(forKey: "appleNotesFormat") ?? "YYYY-MM-DD"
        noteTemplate = defaults.string(forKey: "noteTemplate") ?? ""
        checksUpdatesAtLaunch = defaults.object(forKey: "checksUpdatesAtLaunch") as? Bool ?? true
        hotKeyCode = defaults.object(forKey: "hotKeyCode") as? Int ?? Self.defaultHotKey.code
        hotKeyModifiers = defaults.object(forKey: "hotKeyModifiers") as? Int ?? Self.defaultHotKey.modifiers
        hotKeyLabel = defaults.string(forKey: "hotKeyLabel") ?? Self.defaultHotKey.label
        dateColumnWidth = measureDateColumn()
        updatePeriodMetrics()
    }

    private static func percentEncoded(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Substitutes the date into the template: each `{format}` is replaced with the day in that format (as in moment.js).
    private func fill(_ template: String, day: Date, encoded: Bool) -> String {
        var result = "", rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            let value = MomentFormat.string(from: day, pattern: String(rest[rest.index(after: open)..<close]))
            result += encoded ? Self.percentEncoded(value) : value
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// URLs of the day's note in the chosen notes app: `open` opens it, `create` (if present) creates it first.
    /// nil until a notes app is set up. Apple Notes works through AppleScript and is not covered here.
    func noteTargets(for day: Date) -> (create: URL?, open: URL)? {
        switch noteApp {
        case .obsidian:
            guard !obsidianVault.isEmpty else { return nil }
            let name = MomentFormat.string(from: day, pattern: obsidianFileFormat)
            let folder = obsidianFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let file = folder.isEmpty ? name : "\(folder)/\(name)"
            let query = "?vault=\(Self.percentEncoded(obsidianVault))&file=\(Self.percentEncoded(file))"
            // append: if the day's note already exists it is not duplicated (behavior without append is not described in the documentation).
            guard let create = URL(string: "obsidian://new" + query + "&append=true"),
                  let open = URL(string: "obsidian://open" + query) else { return nil }
            return (create, open)
        case .manual:
            let template = noteTemplate.trimmingCharacters(in: .whitespaces)
            if template.hasPrefix("/") || template.hasPrefix("~") {
                // File path: the name is substituted as is.
                let path = (fill(template, day: day, encoded: false) as NSString).expandingTildeInPath
                return (nil, URL(filePath: path))
            }
            // Link: values in `{}` are encoded for the URL.
            return URL(string: fill(template, day: day, encoded: true)).flatMap { $0.scheme == nil ? nil : (nil, $0) }
        case .appleNotes:
            return nil
        }
    }

    /// Template on today's date (an example for settings).
    var noteTemplateExample: String { noteTargets(for: .now)?.open.absoluteString ?? "" }

    /// "Other: file": creates the day's note file (and folders) if it does not exist yet.
    func createNoteFileIfNeeded(_ url: URL) {
        guard url.isFileURL, !FileManager.default.fileExists(atPath: url.path()) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    func weekText(_ date: Date) -> String { MomentFormat.string(from: date, pattern: "W") }

    /// Main feed font (size like `.body`).
    var font: Font { Font(nsFont(size: fontSize)) }
    /// Small font (week number): 10/13 of the main one, like `.caption` relative to `.body`.
    var smallFont: Font { Font(nsFont(size: (fontSize * 10 / 13).rounded())) }

    /// Height of one line of the main font (to align the indicator with the first line of an entry).
    var lineHeight: Double {
        let font = nsFont(size: fontSize)
        return font.ascender - font.descender + font.leading
    }

    /// Distance from the top of a row to the visual center of capital letters and digits.
    var capCenter: Double {
        let font = nsFont(size: fontSize)
        return font.ascender - font.capHeight / 2
    }

    /// Same for the small font (calendar events).
    var smallCapCenter: Double {
        let font = nsFont(size: (fontSize * 10 / 13).rounded())
        return font.ascender - font.capHeight / 2
    }

    /// Built fonts by size: building from a descriptor costs tens of microseconds, but feed rows access
    /// the font several times per redraw (on every arrow key press in edit).
    @ObservationIgnored private var fontCache: [Double: NSFont] = [:]
    @ObservationIgnored private var fontCacheName = ""

    private func nsFont(size: Double) -> NSFont {
        if fontCacheName != fontName {
            fontCache = [:]
            fontCacheName = fontName
        }
        if let cached = fontCache[size] { return cached }
        let font = makeFont(size: size)
        fontCache[size] = font
        return font
    }

    private func makeFont(size: Double) -> NSFont {
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        guard fontName != Self.systemFont else { return system }
        // The fonts are variable: without an explicit weight the family may open in its thinnest style.
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: fontName,
            .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.regular.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? system
    }

    /// Width of the date column: the widest date in a year in the current font and format. Needed so all entries
    /// start at the same place (for proportional fonts too).
    private func measureDateColumn() -> Double {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)) ?? .now
        let attributes: [NSAttributedString.Key: Any] = [.font: nsFont(size: fontSize)]
        let widths = (0..<366).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            .map { (dayText($0) as NSString).size(withAttributes: attributes).width }
        return ceil(widths.max() ?? 0)
    }

    /// Width of the longest line of text in the main font.
    func textWidth(_ text: String) -> Double {
        let attributes: [NSAttributedString.Key: Any] = [.font: nsFont(size: fontSize)]
        return text.components(separatedBy: .newlines)
            .map { ($0 as NSString).size(withAttributes: attributes).width }
            .max() ?? 0
    }

    private func updatePeriodMetrics() {
        periodLanes = Period.lanes(periods)
        let widest = periods.map { period in
            max(smallTextWidth(uppercase ? period.name.uppercased() : period.name),
                counterText(period).map(smallTextWidth) ?? 0)
        }.max() ?? 0
        periodTitleWidth = min(ceil(widest), Self.maxTitleWidth)
    }

    /// Text width in the small font (period titles).
    func smallTextWidth(_ text: String) -> Double {
        (text as NSString).size(withAttributes: [.font: nsFont(size: (fontSize * 10 / 13).rounded())]).width
    }

    /// Entry text for display in the feed: the space right after an emoji at the start of the line is halved.
    /// In the file and in the input field (edit) the text stays as typed.
    func displayText(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let first = text.first, text.dropFirst().first == " ",
              first.unicodeScalars.contains(where: {
                  $0.properties.isEmojiPresentation || ($0.properties.isEmoji && first.unicodeScalars.contains("\u{FE0F}"))
              })
        else { return result }
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: nsFont(size: fontSize)]).width
        let start = result.characters.index(after: result.startIndex)
        let end = result.characters.index(after: start)
        // Kerning shifts the character after the space: a negative value narrows the gap.
        result[start..<end].kern = -spaceWidth / 2
        return result
    }

    func dayText(_ date: Date) -> String { text(date, pattern: dateFormat) }

    func monthText(_ date: Date) -> String { text(date, pattern: monthFormat) }

    private func text(_ date: Date, pattern: String) -> String {
        let text = MomentFormat.string(from: date, pattern: pattern)
        return uppercase ? text.uppercased() : text
    }

    var highlightColor: Color { highlight ?? textColor.opacity(0.15) }

    /// Final text color.
    var textColor: Color {
        guard adapts, let rgb = NSColor(color).usingColorSpace(.sRGB) else { return color }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(hue: hue, saturation: saturation, brightness: Self.adjust(brightness: brightness, luminance: luminance))
    }

    /// On dark wallpaper the color's lightness is raised, on light wallpaper lowered; hue and saturation stay.
    static func adjust(brightness: Double, luminance: Double) -> Double {
        luminance < 0.5 ? max(brightness, 0.9) : min(brightness, 0.25)
    }

    /// Measures the wallpaper under the window again.
    func refresh(window: CGRect, on screen: NSScreen) {
        if let measured = Wallpaper.luminance(under: window, on: screen) {
            luminance = measured
            isMeasured = true
        } else {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            luminance = isDark ? 0.2 : 0.8
            isMeasured = false
        }
    }
}

enum Wallpaper {
    /// The part of the wallpaper image (fractions 0...1, origin at the top left) lying under the window.
    /// The wallpaper is assumed stretched in "Fill" mode: the image centered, the excess cropped.
    static func cropRect(window: CGRect, screen: CGRect, imageSize: CGSize) -> CGRect {
        let imageAspect = imageSize.width / imageSize.height
        let screenAspect = screen.width / screen.height
        let visibleWidth = imageAspect > screenAspect ? screenAspect / imageAspect : 1
        let visibleHeight = imageAspect > screenAspect ? 1 : imageAspect / screenAspect
        let originX = (1 - visibleWidth) / 2
        let originY = (1 - visibleHeight) / 2
        return CGRect(
            x: originX + (window.minX - screen.minX) / screen.width * visibleWidth,
            y: originY + (screen.maxY - window.maxY) / screen.height * visibleHeight,
            width: window.width / screen.width * visibleWidth,
            height: window.height / screen.height * visibleHeight)
    }

    /// The last read downscaled wallpaper image. Decoding a large file takes tens of milliseconds
    /// (Xcode warned about main thread latency), and brightness is recomputed on every mode and Space change:
    /// the image is reread only if the wallpaper file or its modification time changed.
    private static var cachedThumbnail: (url: URL, modified: Date?, image: CGImage)?

    private static func thumbnail(for url: URL) -> CGImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = cachedThumbnail, cached.url == url, cached.modified == modified { return cached.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512,
              ] as CFDictionary)
        else { return nil }
        cachedThumbnail = (url, modified, image)
        return image
    }

    /// Average brightness of the wallpaper under the window (0...1) or nil if the wallpaper image could not be obtained
    /// (for example, dynamic and video wallpapers may not have one).
    static func luminance(under window: CGRect, on screen: NSScreen) -> Double? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = thumbnail(for: url)
        else { return nil }
        let width = Double(image.width), height = Double(image.height)
        let fraction = cropRect(window: window, screen: screen.frame, imageSize: CGSize(width: width, height: height))
        let crop = CGRect(x: fraction.minX * width, y: fraction.minY * height,
                          width: fraction.width * width, height: fraction.height * height)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !crop.isNull, crop.width >= 1, crop.height >= 1, let part = image.cropping(to: crop) else { return nil }

        // The area is squeezed into one pixel: its color is the average.
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(part, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }
}

extension Color {
    /// RRGGBB or RRGGBBAA.
    init?(hex: String) {
        guard hex.count == 6 || hex.count == 8, var value = UInt32(hex, radix: 16) else { return nil }
        if hex.count == 6 { value = value << 8 | 0xFF }
        self.init(red: Double(value >> 24 & 0xFF) / 255, green: Double(value >> 16 & 0xFF) / 255,
                  blue: Double(value >> 8 & 0xFF) / 255, opacity: Double(value & 0xFF) / 255)
    }

    /// RRGGBBAA.
    var hex: String {
        let rgb = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X%02X", Int(rgb.redComponent * 255 + 0.5), Int(rgb.greenComponent * 255 + 0.5),
                      Int(rgb.blueComponent * 255 + 0.5), Int(rgb.alphaComponent * 255 + 0.5))
    }
}
