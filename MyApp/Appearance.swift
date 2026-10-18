import SwiftUI

/// Какой отрезок времени показывает окно: непрерывная лента, календарный месяц или неделя (пн–вс).
enum ViewKind: String, CaseIterable {
    case feed, month, week, period

    var title: String {
        switch self {
        case .feed: "Лента"
        case .month: "Месяц"
        case .week: "Неделя"
        case .period: "Период"
        }
    }

    /// Месяц и неделя листаются по отрезкам; лента и период нет.
    var isPaged: Bool { self == .month || self == .week }
}

/// Внешний вид: цвет текста (с подстройкой под яркость обоев под лентой), прозрачность, ширина окна,
/// линия выделения сегодняшнего дня, формат даты и заголовков месяцев. Всё хранится в UserDefaults.
@Observable final class Appearance {
    /// Показываемый отрезок времени.
    var viewKind: ViewKind {
        didSet {
            UserDefaults.standard.set(viewKind.rawValue, forKey: "viewKind")
            onLayoutChange?()
        }
    }
    /// Выбранный пользователем цвет (оттенок).
    var color: Color { didSet { UserDefaults.standard.set(color.hex, forKey: "textColor") } }
    /// Подстраивать светлоту цвета под обои.
    var adapts: Bool { didSet { UserDefaults.standard.set(adapts, forKey: "adaptsToWallpaper") } }
    /// Прозрачность текста, 0.2 ... 1.
    var textOpacity: Double { didSet { UserDefaults.standard.set(textOpacity, forKey: "textOpacity") } }
    /// Ширина окна (длина строки).
    var width: Double {
        didSet {
            UserDefaults.standard.set(width, forKey: "windowWidth")
            onLayoutChange?()
        }
    }
    /// Высота затухания ленты у верхнего и нижнего края окна, pt.
    var edgeFade: Double { didSet { UserDefaults.standard.set(edgeFade, forKey: "edgeFade") } }
    /// Персональные периоды (UserDefaults, JSON). Линии и названия видны во всех видах; режим «Период» показывает активный.
    var periods: [Period] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(periods), forKey: "periods")
            updatePeriodMetrics()
            onLayoutChange?()
        }
    }
    /// Показывать ли периоды в режиме «Лента». В режиме «Период» они видны всегда, в «Месяце» и «Неделе» их нет.
    var showsPeriodsInFeed: Bool { didSet { UserDefaults.standard.set(showsPeriodsInFeed, forKey: "showsPeriodsInFeed") } }
    /// Счётчик дней под названием идущего периода («12 / 90»).
    var showsPeriodCounter: Bool {
        didSet {
            UserDefaults.standard.set(showsPeriodCounter, forKey: "showsPeriodCounter")
            updatePeriodMetrics()
        }
    }
    /// Отступ первого дня периода от верха окна, pt; в режиме «Переместить окно» двигается мышью по вертикали.
    /// По умолчанию период стоит ближе к середине экрана (30% высоты).
    var periodOffset: Double { didSet { UserDefaults.standard.set(periodOffset, forKey: "periodOffset") } }

    /// Место под период в окне: от его начала до низа экрана за вычетом затухания.
    func periodRoom(screenHeight: Double) -> Double { screenHeight - periodOffset - edgeFade }

    /// Оценка высоты периода в ленте: строки, заголовки месяцев и отступы недель. Нужна настройкам, чтобы
    /// предупредить, что период не поместится в окно (в самом окне высота измеряется).
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

    /// «12 / 90» для идущего периода, если счётчик включён.
    func counterText(_ period: Period) -> String? {
        guard showsPeriodCounter, period.contains(.now) else { return nil }
        return "\(period.dayNumber(on: .now)) / \(period.dayCount)"
    }

    /// Рисуются ли сейчас линии и названия периодов.
    var showsPeriodMarks: Bool {
        !periods.isEmpty && (viewKind == .period || (viewKind == .feed && showsPeriodsInFeed))
    }
    /// Колонка линии каждого периода (0 ближе к датам) и ширина колонки названий; пересчитываются при смене
    /// списка, шрифта и регистра, а не при каждой отрисовке строки.
    private(set) var periodLanes: [UUID: Int] = [:]
    private(set) var periodTitleWidth = 0.0
    static let maxTitleWidth = 96.0
    /// Период, который показывает режим «Период»: самый длинный из идущих сегодня (остальные идут внутри него).
    var activePeriod: Period? { Period.longest(in: periods, on: .now) }
    /// Цвет и прозрачность линии выделения сегодняшнего дня; nil — цвет текста с прозрачностью 15%.
    var highlight: Color? { didSet { UserDefaults.standard.set(highlight?.hex, forKey: "highlightColor") } }
    /// Формат даты в строке дня (в духе moment.js, см. MomentFormat).
    var dateFormat: String {
        didSet {
            UserDefaults.standard.set(dateFormat, forKey: "dateFormatPattern")
            dateColumnWidth = measureDateColumn()
        }
    }
    /// Показывать ли заголовки месяцев и в каком формате.
    var showsMonth: Bool { didSet { UserDefaults.standard.set(showsMonth, forKey: "showsMonth") } }
    var monthFormat: String { didSet { UserDefaults.standard.set(monthFormat, forKey: "monthFormatPattern") } }
    /// Заголовок месяца жирным шрифтом.
    var monthBold: Bool { didSet { UserDefaults.standard.set(monthBold, forKey: "monthBold") } }
    /// Дата и месяц заглавными буквами.
    var uppercase: Bool {
        didSet {
            UserDefaults.standard.set(uppercase, forKey: "uppercase")
            dateColumnWidth = measureDateColumn()
            updatePeriodMetrics()
        }
    }
    /// Шрифт ленты: семейство из `fonts` или `systemFont` (системный моноширинный).
    var fontName: String {
        didSet {
            UserDefaults.standard.set(fontName, forKey: "fontName")
            dateColumnWidth = measureDateColumn()
            updatePeriodMetrics()
        }
    }
    /// Размер основного шрифта, pt (по умолчанию 13, как у `.body`).
    var fontSize: Double {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
            dateColumnWidth = measureDateColumn()
            updatePeriodMetrics()
        }
    }
    /// Вертикальный отступ сверху и снизу внутри строки дня, pt; расстояние между строками вдвое больше.
    var rowPadding: Double { didSet { UserDefaults.standard.set(rowPadding, forKey: "rowPadding") } }
    /// Ширина колонки даты, см. `measureDateColumn`.
    private(set) var dateColumnWidth = 0.0
    /// Номер недели (ISO) справа в строке понедельника.
    var showsWeekNumber: Bool { didSet { UserDefaults.standard.set(showsWeekNumber, forKey: "showsWeekNumber") } }
    /// Увеличенный отступ перед каждым понедельником.
    var weekGap: Bool { didSet { UserDefaults.standard.set(weekGap, forKey: "weekGap") } }
    /// Яркость обоев под лентой, 0 (чёрные) ... 1 (белые).
    private(set) var luminance = 0.2
    /// Удалось ли измерить обои (иначе яркость выводится из тёмной/светлой темы системы).
    private(set) var isMeasured = false
    /// Вызывается при смене ширины или отрезка времени: окно подгоняется под них.
    @ObservationIgnored var onLayoutChange: (() -> Void)?

    static let widthRange = 240.0...800.0
    static let fontSizeRange = 10.0...24.0
    static let rowPaddingRange = 0.0...6.0
    /// 9 пастельных цветов индикатора дня (оттенок, насыщенность 0.52, яркость 0.95); в файле хранится номер.
    static let indicatorColors: [Color] = [0.0, 0.07, 0.14, 0.33, 0.48, 0.6, 0.75, 0.9]
        .map { Color(hue: $0, saturation: 0.52, brightness: 0.95) } + [Color(white: 0.75)]
    /// Прозрачность, с которой цвета индикатора показываются в ленте и в ряду выбора.
    static let indicatorOpacity = 0.65

    static let systemFont = "System"
    /// Встроенные шрифты Google Fonts (лицензия OFL, файлы в MyApp/Fonts), все с кириллицей.
    static let fonts = ["JetBrains Mono", "IBM Plex Mono", "Fira Code", "Geist Mono"]

    /// Регистрирует встроенные шрифты в процессе (один раз).
    private static let registerFonts: Void = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, nil)
    }()

    init() {
        _ = Self.registerFonts
        let defaults = UserDefaults.standard
        // Сохранённый шрифт, которого больше нет в списке (например, убранный Inter), заменяется системным.
        let savedFont = defaults.string(forKey: "fontName") ?? Self.systemFont
        fontName = savedFont == Self.systemFont || Self.fonts.contains(savedFont) ? savedFont : Self.systemFont
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 13
        viewKind = defaults.string(forKey: "viewKind").flatMap { ViewKind(rawValue: $0) } ?? .feed
        periods = defaults.data(forKey: "periods").flatMap { try? JSONDecoder().decode([Period].self, from: $0) } ?? []
        showsPeriodsInFeed = defaults.object(forKey: "showsPeriodsInFeed") as? Bool ?? true
        showsPeriodCounter = defaults.object(forKey: "showsPeriodCounter") as? Bool ?? false
        periodOffset = defaults.object(forKey: "periodOffset") as? Double ?? (NSScreen.main?.frame.height ?? 800) * 0.3
        rowPadding = defaults.object(forKey: "rowPadding") as? Double ?? 2
        color = defaults.string(forKey: "textColor").flatMap { Color(hex: $0) } ?? .white
        adapts = defaults.object(forKey: "adaptsToWallpaper") as? Bool ?? true
        textOpacity = defaults.object(forKey: "textOpacity") as? Double ?? 1
        width = defaults.object(forKey: "windowWidth") as? Double ?? 360
        edgeFade = defaults.object(forKey: "edgeFade") as? Double ?? 48
        highlight = defaults.string(forKey: "highlightColor").flatMap { Color(hex: $0) }
        dateFormat = defaults.string(forKey: "dateFormatPattern") ?? "DD ddd"
        showsMonth = defaults.object(forKey: "showsMonth") as? Bool ?? true
        monthFormat = defaults.string(forKey: "monthFormatPattern") ?? "MMMM YYYY"
        monthBold = defaults.object(forKey: "monthBold") as? Bool ?? false
        uppercase = defaults.object(forKey: "uppercase") as? Bool ?? true
        showsWeekNumber = defaults.object(forKey: "showsWeekNumber") as? Bool ?? false
        weekGap = defaults.object(forKey: "weekGap") as? Bool ?? false
        dateColumnWidth = measureDateColumn()
        updatePeriodMetrics()
    }

    func weekText(_ date: Date) -> String { MomentFormat.string(from: date, pattern: "W") }

    /// Основной шрифт ленты (размер как у `.body`).
    var font: Font { Font(nsFont(size: fontSize)) }
    /// Мелкий шрифт (номер недели): 10/13 от основного, как `.caption` относительно `.body`.
    var smallFont: Font { Font(nsFont(size: (fontSize * 10 / 13).rounded())) }

    /// Высота одной строки основного шрифта (для выравнивания индикатора по первой строке записи).
    var lineHeight: Double {
        let font = nsFont(size: fontSize)
        return font.ascender - font.descender + font.leading
    }

    /// Расстояние от верха строки до визуального центра заглавных букв и цифр.
    var capCenter: Double {
        let font = nsFont(size: fontSize)
        return font.ascender - font.capHeight / 2
    }

    /// Собранные шрифты по размеру: сборка из дескриптора стоит десятки микросекунд, а строки ленты обращаются
    /// к шрифту по нескольку раз при каждой перерисовке (на каждое нажатие стрелки в edit).
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
        // Шрифты переменные: без явного веса семейство может открыться самым тонким начертанием.
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: fontName,
            .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.regular.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? system
    }

    /// Ширина колонки даты: самая широкая дата за год в текущем шрифте и формате. Нужна, чтобы все записи
    /// начинались с одного места (и для пропорциональных шрифтов тоже).
    private func measureDateColumn() -> Double {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)) ?? .now
        let attributes: [NSAttributedString.Key: Any] = [.font: nsFont(size: fontSize)]
        let widths = (0..<366).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            .map { (dayText($0) as NSString).size(withAttributes: attributes).width }
        return ceil(widths.max() ?? 0)
    }

    /// Ширина самой длинной строки текста в основном шрифте.
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

    /// Ширина текста в мелком шрифте (названия периодов).
    func smallTextWidth(_ text: String) -> Double {
        (text as NSString).size(withAttributes: [.font: nsFont(size: (fontSize * 10 / 13).rounded())]).width
    }

    /// Текст записи для показа в ленте: пробел сразу после эмодзи в начале строки сужается вдвое.
    /// В файле и в поле ввода (edit) текст остаётся как напечатан.
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
        // Кернинг сдвигает следующий за пробелом символ: отрицательный сужает промежуток.
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

    /// Итоговый цвет текста.
    var textColor: Color {
        guard adapts, let rgb = NSColor(color).usingColorSpace(.sRGB) else { return color }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(hue: hue, saturation: saturation, brightness: Self.adjust(brightness: brightness, luminance: luminance))
    }

    /// На тёмных обоях светлота цвета подтягивается вверх, на светлых вниз; оттенок и насыщенность остаются.
    static func adjust(brightness: Double, luminance: Double) -> Double {
        luminance < 0.5 ? max(brightness, 0.9) : min(brightness, 0.25)
    }

    /// Заново измеряет обои под окном.
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
    /// Часть картинки обоев (доли 0...1, отсчёт от левого верхнего угла), лежащая под окном.
    /// Обои считаем растянутыми по режиму «Fill»: картинка по центру, лишнее обрезано.
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

    /// Средняя яркость обоев под окном (0...1) или nil, если картинку обоев получить не удалось
    /// (например, у динамических и видеообоев её может не быть).
    static func luminance(under window: CGRect, on screen: NSScreen) -> Double? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512,
              ] as CFDictionary)
        else { return nil }
        let width = Double(image.width), height = Double(image.height)
        let fraction = cropRect(window: window, screen: screen.frame, imageSize: CGSize(width: width, height: height))
        let crop = CGRect(x: fraction.minX * width, y: fraction.minY * height,
                          width: fraction.width * width, height: fraction.height * height)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !crop.isNull, crop.width >= 1, crop.height >= 1, let part = image.cropping(to: crop) else { return nil }

        // Область сжимается в один пиксель: его цвет и есть средний.
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

private extension Color {
    /// RRGGBB или RRGGBBAA.
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
