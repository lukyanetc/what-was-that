import SwiftUI

/// Всё, что относится к периодам в ленте: линии, названия, статичный слой режима «Период».
extension ContentView {
    /// Положение строк начала и конца периодов в окне ленты (верх и низ, pt). По нему названия в scroll и edit плавно
    /// едут по линии. Это отдельный наблюдаемый объект: при прокрутке обновляется только слой названий, а не вся лента.
    @Observable final class PeriodFrames {
        var frames: [Date: ClosedRange<Double>] = [:]
    }

    /// Название периода в строке его первого дня, слева от линий (locked и move).
    struct PeriodTitles: View {
        let desktop: DesktopController
        let day: Date

        var body: some View {
            let appearance = desktop.appearance
            if appearance.showsPeriodMarks, desktop.shownPeriod != nil {
                let calendar = Calendar.current
                // Период, начавшийся раньше показанного, получает название в первой строке показанного периода.
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

    /// Названия периодов в scroll и edit: стоят у верхнего края окна, пока период виден, и плавно едут по линии.
    /// До начала периода название едет вместе со строкой начала, в конце упирается в нижнюю границу периода.
    struct StickyPeriodTitles: View {
        let desktop: DesktopController
        let days: [Date]
        let frames: PeriodFrames
        let leadingInset: Double
        @Binding var visibleRange: ClosedRange<Int>

        /// Индекс дня в ленте; вне ленты: до первого дня -1, после последнего `days.count`.
        private func index(of day: Date) -> Int {
            if let index = days.firstIndex(of: day) { return index }
            return day < (days.first ?? day) ? -1 : days.count
        }

        /// Верх названия каждого видимого периода в окне ленты.
        private func placedTitles(_ appearance: Appearance) -> [(period: Period, y: Double)] {
            let calendar = Calendar.current
            // Верхняя граница названия: ниже затухания у края окна.
            let stickyY = appearance.edgeFade
            var items: [(period: Period, y: Double)] = []
            for period in appearance.periods {
                let start = calendar.startOfDay(for: period.start)
                let end = calendar.startOfDay(for: period.end)
                let first = index(of: start), last = index(of: end)
                // Начало выше окна (идёт сверху вниз) или в окне; ниже окна период ещё не виден.
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
            // Названия, которые сошлись в одном месте, встают одно под другим.
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

    /// Название периода: мелкий приглушённый шрифт, по правому краю колонки названий, рамка высотой в строку даты.
    /// Под названием идущего периода, если включён счётчик, стоит «12 / 90».
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

    /// Высота названия: одна строка, а со счётчиком две.
    static func titleHeight(_ period: Period, _ appearance: Appearance) -> Double {
        appearance.lineHeight * (appearance.counterText(period) == nil ? 1 : 2)
    }

    /// Расстояние от левого края дат до левого края колонки названий (колонка названий → линии → даты).
    static func titleOffset(_ appearance: Appearance) -> Double {
        let edge = appearance.showsWeekNumber ? highlightInset : 4
        let lines = Double((appearance.periodLanes.values.max() ?? 0) + 1) * (lineWidth + lineGap)
        return edge + lines + titleGap + appearance.periodTitleWidth
    }

    var lanes: [UUID: Int] { desktop.appearance.periodLanes }

    /// Правый край колонки линий: за колонкой номеров недель (если она включена), иначе у самых дат.
    var lineColumnEdge: Double { desktop.appearance.showsWeekNumber ? Self.highlightInset : 4 }

    /// Левый край линии периода; колонка 0 (вложенные) ближе к датам.
    func lineX(_ id: UUID) -> Double {
        -(lineColumnEdge + Self.lineGap + Self.lineWidth + Double(lanes[id] ?? 0) * (Self.lineWidth + Self.lineGap))
    }

    /// Ширина колонок линий (внешняя линия дальше всех от дат).
    var lineColumnWidth: Double {
        guard let maxLane = lanes.values.max() else { return 0 }
        return Double(maxLane + 1) * (Self.lineWidth + Self.lineGap)
    }

    /// Ширина колонки названий слева от линий: по самому длинному названию, но не больше `Appearance.maxTitleWidth`.
    var titleWidth: Double { desktop.appearance.periodTitleWidth }

    /// Отступ ленты слева: запас под полосу «сегодня» и номера недель, а при периодах ещё под линии и названия.
    var leadingInset: Double {
        guard desktop.appearance.showsPeriodMarks else { return Self.highlightInset }
        let lines = max(Self.highlightInset, lineColumnEdge + lineColumnWidth + 2)
        return lines + (titleWidth > 0 ? Self.titleGap + titleWidth : 0)
    }

    /// Первый день идущего периода в режиме «Период».
    var activePeriodStart: Date? {
        // Период, который не помещается в окно, отдельно не показывается: лента встаёт на «сегодня».
        guard desktop.appearance.viewKind == .period, desktop.periodFits else { return nil }
        return desktop.appearance.activePeriod.map { Self.calendar.startOfDay(for: $0.start) }
    }

    /// Режим «Период» в locked и move: дни идущего периода отдельным статичным слоем, начало на `periodOffset` pt
    /// ниже верха окна (точно, без прокрутки). Лента под ним невидима, но стоит так же и проявляется в scroll и edit.
    @ViewBuilder var periodLayer: some View {
        // В edit слой убран: его поля ввода дублировали бы поля ленты (общий фокус). К этому моменту он уже невидим.
        if desktop.appearance.viewKind == .period, desktop.mode != .edit, let period = desktop.appearance.activePeriod {
            let start = Self.calendar.startOfDay(for: period.start)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<period.dayCount, id: \.self) { offset in
                    if let day = Self.calendar.date(byAdding: .day, value: offset, to: start) { dayItem(day) }
                }
            }
            // Высота периода решает, поместится ли он в окно (иначе режим показывает ленту).
            .onGeometryChange(for: Double.self) { $0.size.height } action: { desktop.periodContentHeight = $0 }
            .padding(.leading, leadingInset)
            .padding(.top, desktop.periodOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(desktop.shownPeriod != nil ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: desktop.shownPeriod != nil)
            .allowsHitTesting(false)
        }
    }

    /// Где в окне стоит первый день периода: на `periodOffset` pt ниже верха окна. Якорь прокрутки задаёт долю
    /// высоты, в которой лежит одна и та же точка строки и окна, поэтому высота строки вычитается.
    var periodAnchor: UnitPoint {
        let free = desktop.screenFrame.height - periodItemHeight
        guard free > 0 else { return .top }
        return UnitPoint(x: 0, y: min(max(desktop.periodOffset / free, 0), 1))
    }

    /// Тонкие вертикальные линии слева от дат на протяжении периодов. `starting`: только периоды, начинающиеся
    /// в этот день (линия идёт от их названия), иначе только начавшиеся раньше. Ближе к датам стоят вложенные.
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

/// Режим «Период»: лента скрывается (плавно) и поверх неё лежит статичный слой периода. Вне этого режима вид не меняется.
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
