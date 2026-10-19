import SwiftUI

/// Лента дней: год назад от самой ранней записи и два года вперёд от сегодняшнего дня, либо один месяц или неделя
/// (см. `ViewKind`). В edit текст каждого дня редактируется.
struct ContentView: View {
    let desktop: DesktopController
    @State private var entries: [String: DayEntry] = [:]
    /// Дни, изменённые, но ещё не записанные в файл.
    @State private var dirty: Set<String> = []
    @FocusState private var focusedDay: Date?
    /// День, у которого сейчас раскрыт ряд выбора цвета индикатора.
    @State private var pickerDay: Date?
    /// День, в котором стоял курсор в текущем сеансе edit. Когда окно возвращает себе фокус (например, после
    /// выбора эмодзи во внешней панели), курсор встаёт обратно в этот день, а не прыгает на «сегодня».
    @State private var editingDay: Date?
    /// Индексы полностью видимых в окне дней.
    @State private var visibleRange = 0...0
    @State private var isIndicatorVisible = true
    /// Сегодняшний день и лента вокруг него; обновляются при смене даты.
    @State private var today = Calendar.current.startOfDay(for: .now)
    @State private var days = ContentView.days(around: Calendar.current.startOfDay(for: .now))
    /// Месяц и неделя: на сколько отрезков окно сдвинуто от текущего (листание в scroll и edit; в solid всегда 0).
    @State private var periodOffset = 0
    /// Курсор ушёл за край отрезка стрелкой или Enter: +1 — встанет на первый день следующего, -1 — на последний предыдущего.
    @State private var pendingEdge: Int?
    /// Ширина колонки записей (одинакова у всех строк); по ней решается, можно ли рисовать запись поверх поля.
    @State private var recordWidth = 0.0
    /// Текущая попытка поставить курсор (см. `focusEditor`); новая отменяет предыдущую.
    @State private var focusTask: Task<Void, Never>?
    /// Высота первого дня идущего периода (с названием), см. `periodAnchor`.
    @State private var periodItemHeight = 0.0
    /// Положение строк начала и конца периодов в окне ленты, см. `StickyPeriodTitles`.
    @State private var periodFrames = PeriodFrames()
    private static let feedSpace = "feed"

    private static let calendar = Calendar.current
    /// «Сегодня» стоит примерно на трети высоты окна.
    private static let todayAnchor = UnitPoint(x: 0, y: 0.3)
    /// Приглушение для выходных и заголовков месяцев.
    private static let mutedOpacity = 0.5
    /// Насколько полоса «сегодня» выходит влево за текст. ScrollView обрезает содержимое по своим границам,
    /// поэтому этот запас задан отступом внутри ленты, а не отступом окна.
    private static let highlightInset = 35.0
    /// Линия периода: толщина и промежуток до соседней линии и до дат.
    private static let lineWidth = 1.5
    private static let lineGap = 3.0
    /// Промежуток между названием периода и линиями.
    private static let titleGap = 6.0
    /// Дополнительный отступ перед понедельником, когда он включён.
    private static let weekGapHeight = 12.0

    /// Самый ранний день с записью (ключи "yyyy-MM-dd" сортируются как строки).
    private static func earliestDay(in entries: [String: DayEntry]) -> Date? {
        guard let key = entries.keys.min() else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Дни окна. Лента: см. ниже. Месяц и неделя: один отрезок, сдвинутый на `offset` отрезков от текущего.
    private static func days(around today: Date, earliest: Date? = nil, kind: ViewKind = .feed, offset: Int = 0) -> [Date] {
        if kind != .feed {
            let component: Calendar.Component = kind == .month ? .month : .weekOfYear
            // Неделя всегда с понедельника, независимо от региональных настроек.
            var cal = kind == .month ? calendar : Calendar(identifier: .iso8601)
            cal.timeZone = calendar.timeZone
            guard let anchor = cal.date(byAdding: component, value: offset, to: today),
                  let interval = cal.dateInterval(of: component, for: anchor) else { return [today] }
            let count = cal.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
            return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: interval.start) }
        }
        // Год назад от самой ранней записи (или от сегодня, если она позже) и два года вперёд от сегодняшнего дня.
        let anchor = min(earliest ?? today, today)
        let first = calendar.date(byAdding: .year, value: -1, to: anchor) ?? today
        let last = calendar.date(byAdding: .year, value: 2, to: today) ?? today
        let count = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        return (0...count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        dayItem(day, reportsFrames: true)
                    }
                }
                .scrollTargetLayout()
                .padding(.leading, leadingInset)
                // Месяц, неделя и период: окно по размеру содержимого, поля сверху и снизу равны затуханию у краёв,
                // чтобы строки не попадали в затухание.
                .padding(.vertical, desktop.isCompact ? desktop.appearance.edgeFade : 0)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
                    if desktop.isCompact { desktop.periodHeight = height }
                }
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: Self.feedSpace)
            // Названия периодов в scroll и edit: под лентой (не поверх полей ввода), плавно едут по линии.
            .background(alignment: .topLeading) {
                StickyPeriodTitles(desktop: desktop, days: days, frames: periodFrames, leadingInset: leadingInset,
                                   visibleRange: $visibleRange)
            }
            .onScrollTargetVisibilityChange(idType: Date.self, threshold: 0.9) { ids in
                let indices = ids.compactMap { days.firstIndex(of: $0) }
                if let first = indices.min(), let last = indices.max() { visibleRange = first...last }
            }
            .onAppear {
                reload()
                scrollHome(proxy)
                desktop.moveFocus = { step in move(by: step, proxy: proxy) }
                desktop.shiftPeriod = { step in periodOffset += step }
            }
            // Смена отрезка (настройки, меню) и листание в scroll: набор дней строится заново.
            .onChange(of: desktop.appearance.viewKind) {
                periodOffset = 0
                rebuildDays(proxy)
            }
            .onChange(of: periodOffset) { rebuildDays(proxy) }
            // Настройки календаря: режим, выбранные календари, выданный доступ.
            .onChange(of: desktop.appearance.eventsMode) { loadEvents() }
            .onChange(of: desktop.appearance.eventCalendarIDs) { loadEvents() }
            .onChange(of: desktop.events.isAuthorized) { loadEvents() }
            // Сменился идущий период (правка списка, начало или конец) или его место в окне: лента встаёт заново.
            .onChange(of: activePeriodStart) { restorePosition(proxy) }
            // Высота первого дня меняется и при входе в edit (поле вместо текста, события): ленту двигать нельзя,
            // иначе она сдвигается на пункт-два. Подгонка нужна только там, где лента стоит по якорю периода.
            .onChange(of: periodItemHeight) {
                if desktop.mode == .solid || desktop.mode == .move { restorePosition(proxy) }
            }
            .onChange(of: desktop.periodOffset) { restorePosition(proxy) }
            // После смены ширины лента возвращается на место: в solid к сегодняшнему дню, в остальных режимах
            // к верхнему из видимых дней.
            .onChange(of: desktop.appearance.width) { restorePosition(proxy) }
            // Смена размера шрифта меняет высоту строк: лента возвращается на место так же.
            .onChange(of: desktop.appearance.fontSize) { restorePosition(proxy) }
            .onChange(of: desktop.appearance.rowPadding) { restorePosition(proxy) }
            .onChange(of: focusedDay) { _, day in
                if let day {
                    pickerDay = nil
                    editingDay = day
                }
            }
            .onChange(of: desktop.mode) { oldMode, mode in
                pickerDay = nil
                if oldMode == .edit { flush() }
                if mode == .scroll { reload() }
                if mode == .edit {
                    // Новый сеанс edit начинается с «сегодня» (или верхнего видимого дня).
                    editingDay = nil
                    // Поля ввода появляются не мгновенно, поэтому фокус ставится с небольшой паузой.
                    Task {
                        try? await Task.sleep(for: .milliseconds(50))
                        if desktop.mode == .edit { focusEditor() }
                    }
                }
                if oldMode == .edit { focusedDay = nil }
                // Выход из просмотра возвращает ленту к сегодняшнему дню (месяц и неделю к текущему отрезку).
                if mode == .solid {
                    periodOffset = 0
                    if activePeriodStart == nil {
                        scrollHome(proxy)
                    } else {
                        // Лента под слоем периода встаёт на место, когда слой уже её закрыл (не видно прыжка).
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            if desktop.mode == .solid { scrollHome(proxy) }
                        }
                    }
                }
            }
            // Ленивая лента при первой прокрутке к далёкой строке оценивает её положение приблизительно:
            // после отрисовки при запуске прокручиваем ещё раз, уже точно.
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                if desktop.mode == .solid { scrollHome(proxy) }
            }
            // Окно становится key не сразу: активация приложения асинхронна. Фокус, поставленный до этого,
            // не даёт курсора (лента «листает фокус», но курсора нет), поэтому ставим его заново, когда окно готово.
            .task {
                for await note in NotificationCenter.default.notifications(named: NSWindow.didBecomeKeyNotification) {
                    if note.object is DesktopWindow, desktop.mode == .edit { focusEditor() }
                }
            }
            // Смена даты (полночь, пробуждение после сна): лента едет вместе с «сегодня».
            .task {
                for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
                    today = Self.calendar.startOfDay(for: .now)
                    // Период мог начаться или кончиться: окно подгоняется заново.
                    rebuildDays(proxy)
                    desktop.fitWindow()
                    if desktop.mode == .solid { scrollHome(proxy) }
                }
            }
        }
        // Режим «Период» в solid: ленту заменяет статичный слой периода, лента под ним невидима. В остальных видах
        // лента остаётся без этих надстроек.
        .modifier(PeriodSwap(isActive: desktop.appearance.viewKind == .period,
                             hidesContent: desktop.shownPeriod != nil, layer: periodLayer))
        // Без отступов сверху и снизу: лента уходит за края окна, а затухание у краёв создаёт ощущение бесконечности.
        .mask { edgeFadeMask }
        .font(desktop.appearance.font)
        .foregroundStyle(desktop.appearance.textColor.opacity(desktop.appearance.textOpacity))
        .padding(.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) { modeIndicator }
    }

    /// Положение строк начала и конца периодов в окне ленты (верх и низ, pt). По нему названия в scroll и edit плавно
    /// едут по линии. Это отдельный наблюдаемый объект: при прокрутке обновляется только слой названий, а не вся лента.
    @Observable fileprivate final class PeriodFrames {
        var frames: [Date: ClosedRange<Double>] = [:]
    }

    /// Название периода в строке его первого дня, слева от линий (solid и move).
    private struct PeriodTitles: View {
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
    private struct StickyPeriodTitles: View {
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
    private static func titleText(_ period: Period, _ appearance: Appearance) -> some View {
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
    private static func titleHeight(_ period: Period, _ appearance: Appearance) -> Double {
        appearance.lineHeight * (appearance.counterText(period) == nil ? 1 : 2)
    }

    /// Расстояние от левого края дат до левого края колонки названий (колонка названий → линии → даты).
    private static func titleOffset(_ appearance: Appearance) -> Double {
        let edge = appearance.showsWeekNumber ? highlightInset : 4
        let lines = Double((appearance.periodLanes.values.max() ?? 0) + 1) * (lineWidth + lineGap)
        return edge + lines + titleGap + appearance.periodTitleWidth
    }

    private var lanes: [UUID: Int] { desktop.appearance.periodLanes }

    /// Правый край колонки линий: за колонкой номеров недель (если она включена), иначе у самых дат.
    private var lineColumnEdge: Double { desktop.appearance.showsWeekNumber ? Self.highlightInset : 4 }

    /// Левый край линии периода; колонка 0 (вложенные) ближе к датам.
    private func lineX(_ id: UUID) -> Double {
        -(lineColumnEdge + Self.lineGap + Self.lineWidth + Double(lanes[id] ?? 0) * (Self.lineWidth + Self.lineGap))
    }

    /// Ширина колонок линий (внешняя линия дальше всех от дат).
    private var lineColumnWidth: Double {
        guard let maxLane = lanes.values.max() else { return 0 }
        return Double(maxLane + 1) * (Self.lineWidth + Self.lineGap)
    }

    /// Ширина колонки названий слева от линий: по самому длинному названию, но не больше `Appearance.maxTitleWidth`.
    private var titleWidth: Double { desktop.appearance.periodTitleWidth }

    /// Отступ ленты слева: запас под полосу «сегодня» и номера недель, а при периодах ещё под линии и названия.
    private var leadingInset: Double {
        guard desktop.appearance.showsPeriodMarks else { return Self.highlightInset }
        let lines = max(Self.highlightInset, lineColumnEdge + lineColumnWidth + 2)
        return lines + (titleWidth > 0 ? Self.titleGap + titleWidth : 0)
    }

    /// Первый день идущего периода в режиме «Период».
    private var activePeriodStart: Date? {
        // Период, который не помещается в окно, отдельно не показывается: лента встаёт на «сегодня».
        guard desktop.appearance.viewKind == .period, desktop.periodFits else { return nil }
        return desktop.appearance.activePeriod.map { Self.calendar.startOfDay(for: $0.start) }
    }

    /// День ленты: заголовок месяца, строка дня и линии периодов. Один и тот же вид в ленте и в статичном слое периода.
    private func dayItem(_ day: Date, reportsFrames: Bool = false) -> some View {
        // Строки начала и конца периодов сообщают своё положение в окне ленты (для плавных названий в scroll и edit).
        let calendar = Self.calendar
        let isBoundary = reportsFrames && desktop.appearance.showsPeriodMarks && desktop.appearance.periods.contains {
            calendar.startOfDay(for: $0.start) == day || calendar.startOfDay(for: $0.end) == day
        }
        return VStack(alignment: .leading, spacing: 0) {
            if desktop.appearance.showsMonth && isMonthStart(day) {
                Text(desktop.appearance.monthText(day))
                    .bold(desktop.appearance.monthBold)
                    .opacity(Self.mutedOpacity)
                    .padding(.vertical, 12)
            }
            row(day)
                .background(alignment: .topLeading) { periodLines(on: day, starting: true) }
                .onGeometryChange(for: ClosedRange<Double>?.self) { proxy in
                    guard isBoundary else { return nil }
                    let frame = proxy.frame(in: .named(Self.feedSpace))
                    return frame.minY...frame.maxY
                } action: { range in
                    if let range { periodFrames.frames[day] = range }
                }
        }
        // Отступ перед понедельником; у заголовка месяца свой отступ, первый день не сдвигаем.
        .padding(.top, desktop.appearance.weekGap && isMonday(day) && !isMonthStart(day) ? Self.weekGapHeight : 0)
        // Линии периодов, начавшихся раньше, идут через заголовки месяцев и отступы без разрыва.
        .background(alignment: .topLeading) { periodLines(on: day, starting: false) }
        // Высота первого дня периода нужна, чтобы лента встала так же, как стоит статичный слой периода.
        .onGeometryChange(for: Double.self) { $0.size.height } action: { height in
            if day == activePeriodStart { periodItemHeight = height }
        }
    }

    /// Режим «Период» в solid и move: дни идущего периода отдельным статичным слоем, начало на `periodOffset` pt
    /// ниже верха окна (точно, без прокрутки). Лента под ним невидима, но стоит так же и проявляется в scroll и edit.
    @ViewBuilder private var periodLayer: some View {
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
    private var periodAnchor: UnitPoint {
        let free = desktop.screenFrame.height - periodItemHeight
        guard free > 0 else { return .top }
        return UnitPoint(x: 0, y: min(max(desktop.periodOffset / free, 0), 1))
    }

    /// Домашняя позиция ленты: при идущем периоде («Период») его начало на заданном месте, иначе «сегодня».
    private func scrollHome(_ proxy: ScrollViewProxy) {
        if let start = activePeriodStart, days.contains(start) {
            proxy.scrollTo(start, anchor: periodAnchor)
        } else {
            proxy.scrollTo(today, anchor: Self.todayAnchor)
        }
    }

    /// Тонкие вертикальные линии слева от дат на протяжении периодов. `starting`: только периоды, начинающиеся
    /// в этот день (линия идёт от их названия), иначе только начавшиеся раньше. Ближе к датам стоят вложенные.
    private func periodLines(on day: Date, starting: Bool) -> some View {
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

    /// Маска: лента плавно уходит в прозрачность у верхнего и нижнего края окна.
    private var edgeFadeMask: some View {
        let fade = desktop.appearance.edgeFade
        return VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: fade)
        }
    }

    /// Режим в правом верхнем углу: появляется сразу при смене режима. Горит в scroll, edit и move;
    /// solid показывается секунду и плавно гаснет.
    private var modeIndicator: some View {
        // Промежуток в полпробела, а знак «>» опущен на пару пунктов, чтобы стоять по центру строчных букв.
        HStack(spacing: 4) {
            Text(">").baselineOffset(-1)
            // Невидимое «scroll» (самое длинное слово) задаёт ширину: «>» стоит на месте, слово меняется за ним.
            ZStack(alignment: .leading) {
                Text("scroll").hidden()
                Text(desktop.mode.rawValue)
            }
        }
        .font(desktop.appearance.font)
        .foregroundStyle(desktop.appearance.textColor)
        .padding(.horizontal)
        // Лента: ниже строки меню, окно уходит под неё. Месяц и неделя: окно небольшое и стоит где угодно.
        .padding(.top, desktop.isCompact ? 8 : 56)
        .opacity(isIndicatorVisible ? 0.5 : 0)
        .task(id: desktop.mode) {
            isIndicatorVisible = true
            guard desktop.mode == .solid else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { isIndicatorVisible = false }
        }
        .allowsHitTesting(false)
    }

    private func row(_ day: Date) -> some View {
        let label = desktop.appearance.dayText(day)
        let isWeekend = Self.calendar.isDateInWeekend(day)
        let key = DayStore.key(for: day)
        // Дата стоит на уровне первой строки записи, остальные строки идут под ней в колонке записей.
        return HStack(alignment: .firstTextBaseline, spacing: Self.dotGap) {
            Text(label)
                .opacity(isWeekend ? Self.mutedOpacity : 1)
                // Колонка даты фиксированной ширины: индикаторы и записи стоят на одной вертикали при любом шрифте.
                .frame(width: desktop.appearance.dateColumnWidth, alignment: .leading)
            // Место под индикатор (сам он рисуется поверх, см. `indicator`), между датой и записью.
            Color.clear.frame(width: Self.dotWidth, height: 0)
            // Запись дня, под ней события календаря столбиком (сначала на весь день, дальше по времени).
            VStack(alignment: .leading, spacing: 0) {
            // Пока раскрыт выбор цвета, запись скрыта: ряд цветов открывается вдоль линии ввода, на её месте.
            Group {
                // Пока раскрыт выбор цвета, поля ввода нет вовсе: даже скрытое, оно заставляет курсор мыши
                // над рядом цветов становиться текстовым. Вместо него обычный текст.
                if desktop.mode == .edit && pickerDay != day {
                    // Буквы рисует тот же Text, что и в solid (поле ввода рисует тот же шрифт на пиксель иначе, и
                    // записи «подскакивали» при входе в edit). Поле остаётся для курсора, выделения и ввода, а его
                    // собственный текст прозрачен. Если строка шире колонки, она переносится, и перенос в поле
                    // и в Text мог бы отличаться: тогда текст показывает само поле.
                    let text = entries[key]?.text ?? ""
                    let overlaysText = fitsInColumn(text)
                    // Несколько строк в дне (Shift+Enter): запись переносится и растёт вниз.
                    let field = TextField("", text: binding(for: key), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...20)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(overlaysText ? Color.clear : desktop.appearance.textColor)
                        .opacity(desktop.appearance.textOpacity)
                        .focused($focusedDay, equals: day)
                    if overlaysText {
                        // Высоту строки задаёт тот же Text, что и в solid, а поле лежит поверх и на размер не влияет:
                        // поле чуть выше текста, и строки ленты (вместе с событиями под ними) сдвигались при входе в edit.
                        recordText(AttributedString(text))
                            .allowsHitTesting(false)
                            .overlay(alignment: .topLeading) { field }
                    } else {
                        field
                    }
                } else {
                    let text = entries[key]?.text ?? ""
                    recordText(desktop.appearance.displayText(text.trimmingCharacters(in: .newlines)))
                }
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { recordWidth = $0 }
            .opacity(pickerDay == day ? 0 : 1)
            .overlay(alignment: .topTrailing) {
                // Режим «только будущие»: сколько прошедших событий скрыто.
                let hidden = desktop.events.events(on: day, mode: desktop.appearance.eventsMode).hidden
                if hidden > 0 {
                    Text("+\(hidden)").font(desktop.appearance.smallFont).opacity(Self.mutedOpacity).allowsHitTesting(false)
                }
            }
            eventLines(day)
            }
            // Место под стрелку заметки в конце строки (сама стрелка рисуется поверх, см. `noteArrow`).
            Color.clear.frame(width: Self.noteArrowWidth, height: 0)
        }
        // Названия периодов, начинающихся в этот день: слева от линий, в отдельной колонке (название → линия → даты).
        // Под строкой, а не поверх: слой над полем ввода в edit заставлял ленту дребезжать.
        .background(alignment: .topLeading) {
            PeriodTitles(desktop: desktop, day: day)
        }
        // Номер недели стоит слева от даты, в запасе под полосу «сегодня», и не сдвигает текст.
        .overlay(alignment: .topLeading) {
            if desktop.appearance.showsWeekNumber && isMonday(day) {
                Text(desktop.appearance.weekText(day))
                    .font(desktop.appearance.smallFont)
                    .opacity(0.4)
                    // Высота рамки равна высоте строки даты: номер стоит по её центру, а не прижат к верху.
                    .frame(width: Self.highlightInset - 6, height: desktop.appearance.lineHeight, alignment: .trailing)
                    .offset(x: -Self.highlightInset, y: 0)
            }
        }
        .padding(.vertical, desktop.appearance.rowPadding)
        .overlay(alignment: .topLeading) { indicator(for: day) }
        .overlay(alignment: .topTrailing) { noteArrow(day) }
        .overlay(alignment: .topLeading) {
            if pickerDay == day {
                // Ряд цветов стоит на уровне первой строки записи, как и сам индикатор.
                GeometryReader { geo in
                    // Квадраты со стороной в высоту планки стоят справа от неё: прежний цвет остаётся виден.
                    ColorStrip(size: markerHeight) { choose($0, for: day) }
                        .offset(x: dotX + Self.dotWidth + Self.dotGap - ColorStrip.slotPadding,
                                y: centerY(in: geo.size.height) - markerHeight / 2 - ColorStrip.slotPadding)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if day == today { todayHighlight }
        }
    }

    /// События календаря дня столбиком: время и название (у событий на весь день только название).
    @ViewBuilder private func eventLines(_ day: Date) -> some View {
        let shown = desktop.events.events(on: day, mode: desktop.appearance.eventsMode).shown
        ForEach(shown) { event in
            let startsToday = !event.isAllDay && Self.calendar.startOfDay(for: event.start) == day
            // Вид записи дня, но мельче и светлее, чтобы не перевешивать её; событие отличает кружок цвета календаря.
            HStack(alignment: .top, spacing: Self.dotGap + 2) {
                Circle()
                    .fill(event.color)
                    .frame(width: Self.eventDot, height: Self.eventDot)
                    .padding(.top, desktop.appearance.smallCapCenter - Self.eventDot / 2)
                recordText(AttributedString(startsToday ? "\(event.start.formatted(.dateTime.hour().minute())) \(event.title)" : event.title))
                    .font(desktop.appearance.smallFont)
            }
            .opacity(Self.eventOpacity)
            .allowsHitTesting(false)
        }
    }

    /// Загружает события календаря за дни ленты (в режиме «Не показывать» ничего не читается).
    private func loadEvents() {
        let ids = desktop.appearance.eventsMode == .hide ? [] : desktop.appearance.eventCalendarIDs
        desktop.events.load(days: days, calendarIDs: ids)
    }

    /// Запись в ленте (solid, scroll) и поверх поля в edit: одна и та же вёрстка, чтобы буквы стояли в одном месте.
    private func recordText(_ text: AttributedString) -> some View {
        // Текст, дойдя до края окна, переносится на следующую строку и виден целиком.
        Text(text)
            .fadedLikeText(desktop.appearance)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Помещается ли самая длинная строка записи в колонку записей (с запасом на отступы поля ввода).
    private func fitsInColumn(_ text: String) -> Bool {
        recordWidth > 0 && desktop.appearance.textWidth(text) + 8 <= recordWidth
    }

    /// Индикатор — вертикальная планка: ширина, а высота одиночного дня как доля высоты строки.
    private static let dotWidth = 4.0
    private static let markerHeightFactor = 0.8
    /// Высота планки одиночного дня; ряд выбора цвета состоит из таких же планок.
    private var markerHeight: Double { desktop.appearance.lineHeight * Self.markerHeightFactor }
    /// Ширина места под стрелку заметки в конце строки.
    private static let noteArrowWidth = 20.0

    /// Косая стрелка в конце строки. Нет ссылки: бледная кнопка только в edit, по нажатию заметка связывается с днём.
    /// Есть ссылка: стрелка видна всегда, в scroll и edit открывает заметку (в solid клики проходят сквозь окно);
    /// убрать ссылку можно только в edit.
    @ViewBuilder private func noteArrow(_ day: Date) -> some View {
        let key = DayStore.key(for: day)
        let hasNote = entries[key]?.note != nil
        let isEdit = desktop.mode == .edit
        let isActive = hasNote ? (desktop.mode == .scroll || isEdit) : isEdit
        // Кнопка есть в строке всегда, а в нужных режимах только проявляется: если вставлять её при входе в edit,
        // в каждой видимой строке появляется новый вид в тот же момент, когда меняются поля ввода (гипотеза мигания).
        Group {
            Button { openOrLinkNote(day) } label: {
                Image(systemName: "arrow.up.right")
                    .font(desktop.appearance.smallFont)
                    .frame(width: Self.noteArrowWidth, height: desktop.appearance.lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hasNote ? 0.6 : (isEdit ? 0.2 : 0))
            .padding(.top, desktop.appearance.rowPadding)
            .allowsHitTesting(isActive)
            .contextMenu {
                if hasNote && isEdit { Button("Убрать ссылку на заметку") { setNote(nil, for: day) } }
            }
        }
    }

    /// Есть ссылка — открывает заметку. Нет — связывает день с заметкой: Obsidian и Apple Notes создают заметку дня
    /// (если её нет) и открывают её.
    private func openOrLinkNote(_ day: Date) {
        if let link = entries[DayStore.key(for: day)]?.note {
            if link.hasPrefix(AppleNotes.prefix) {
                Task { await AppleNotes.show(id: String(link.dropFirst(AppleNotes.prefix.count))) }
            } else if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        switch desktop.appearance.noteApp {
        case .obsidian, .manual:
            guard let urls = desktop.appearance.noteTargets(for: day) else { NSSound.beep(); return }
            // Для пути к файлу: создаёт файл, если его нет (для ссылок ничего не делает).
            desktop.appearance.createNoteFileIfNeeded(urls.open)
            setNote(urls.open.absoluteString, for: day)
            NSWorkspace.shared.open(urls.create ?? urls.open)
        case .appleNotes:
            let name = MomentFormat.string(from: day, pattern: desktop.appearance.appleNotesFormat)
            let folder = desktop.appearance.appleNotesFolder
            Task {
                // Notes создаёт заметку дня (если её нет) и открывает её; id заметки запоминается в записи дня.
                guard let id = await AppleNotes.openOrCreate(name: name, folder: folder), !id.isEmpty else {
                    NSSound.beep()
                    return
                }
                setNote(AppleNotes.prefix + id, for: day)
            }
        }
    }

    /// Сохраняет ссылку на заметку дня сразу в файл (nil убирает её).
    private func setNote(_ note: String?, for day: Date) {
        let key = DayStore.key(for: day)
        var entry = entries[key] ?? DayEntry(text: "")
        entry.note = note
        entries[key] = entry.isEmpty ? nil : entry
        try? DayStore().setNote(note, for: key)
    }

    /// Диаметр кружка календаря перед событием.
    private static let eventDot = 5.0
    /// Прозрачность события относительно записи дня.
    private static let eventOpacity = 0.65
    /// Промежуток между колонкой даты, индикатором и записью.
    private static let dotGap = 4.0
    /// Левый край индикатора: сразу за колонкой даты, перед записью.
    private var dotX: Double { desktop.appearance.dateColumnWidth + Self.dotGap }

    /// Высота центра индикатора в строке: визуальный центр заглавных букв и цифр первой строки записи
    /// (середина между базовой линией и верхом заглавных), где стоит дата. Не геометрический центр строки:
    /// у большинства шрифтов он выше или ниже и планка выглядела бы сдвинутой.
    private func centerY(in height: Double) -> Double {
        desktop.appearance.rowPadding + desktop.appearance.capCenter
    }

    private func indicatorColor(_ day: Date) -> Int? {
        entries[DayStore.key(for: day)]?.color.flatMap { Appearance.indicatorColors.indices.contains($0) ? $0 : nil }
    }

    /// Перед этим днём стоит заголовок месяца или увеличенный отступ недели: период через него не тянется.
    private func startsBlock(_ day: Date) -> Bool {
        isMonthStart(day) || (desktop.appearance.weekGap && isMonday(day))
    }

    /// Круглый индикатор в начале строки. Соседние дни одного цвета сливаются в одну полосу с круглыми концами.
    /// В edit у дня без цвета виден бледный контур, по клику на него раскрывается выбор цвета.
    @ViewBuilder private func indicator(for day: Date) -> some View {
        let w = Self.dotWidth
        let cap = w / 2
        // Половина высоты одиночного индикатора.
        let half = markerHeight / 2
        let color = indicatorColor(day)
        let isEdit = desktop.mode == .edit
        ZStack(alignment: .topLeading) {
            if let color {
                let prev = Self.calendar.date(byAdding: .day, value: -1, to: day)
                let next = Self.calendar.date(byAdding: .day, value: 1, to: day)
                let linkedPrev = !startsBlock(day) && prev.map { indicatorColor($0) == color } == true
                let linkedNext = next.map { !startsBlock($0) && indicatorColor($0) == color } == true
                GeometryReader { geo in
                    let h = geo.size.height
                    let top = linkedPrev ? 0 : centerY(in: h) - half
                    let bottom = linkedNext ? h : centerY(in: h) + half
                    UnevenRoundedRectangle(
                        topLeadingRadius: linkedPrev ? 0 : cap, bottomLeadingRadius: linkedNext ? 0 : cap,
                        bottomTrailingRadius: linkedNext ? 0 : cap, topTrailingRadius: linkedPrev ? 0 : cap)
                        .fill(Appearance.indicatorColors[color].opacity(Appearance.indicatorOpacity))
                        .frame(width: w, height: bottom - top)
                        .offset(x: dotX, y: top)
                }
                .allowsHitTesting(false)
            } else if isEdit {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: cap).strokeBorder(lineWidth: 1)
                        .opacity(0.25)
                        .frame(width: w, height: 2 * half)
                        .offset(x: dotX, y: centerY(in: geo.size.height) - half)
                }
                .allowsHitTesting(false)
            }
            if isEdit {
                Button {
                    if pickerDay == day { closePicker(for: day) } else { withAnimation(.easeOut(duration: 0.2)) { pickerDay = day } }
                } label: {
                    Color.clear.frame(width: w + 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: dotX - 6)
            }
        }
        // Форма полосы (концы, длина) меняется у соседей сразу при выборе цвета. Без этого SwiftUI «дорисовывает»
        // её анимацией, и круглые концы и высота плывут по-разному в соседних строках: меняем мгновенно.
        .transaction { $0.animation = nil }
    }

    /// Ставит цвет дню и сразу пишет его в файл.
    private func choose(_ index: Int?, for day: Date) {
        let key = DayStore.key(for: day)
        var entry = entries[key] ?? DayEntry(text: "")
        entry.color = index
        entries[key] = entry.isEmpty ? nil : entry
        try? DayStore().setColor(index, for: key)
        closePicker(for: day)
    }

    /// Закрывает ряд цветов и возвращает курсор в поле этого дня (на время выбора поля нет).
    private func closePicker(for day: Date) {
        withAnimation(.easeOut(duration: 0.2)) { pickerDay = nil }
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard desktop.mode == .edit, pickerDay == nil else { return }
            // Поле при фокусе выделяет весь текст; клик по цвету только что был вводом, поэтому говорим окну,
            // что выделение надо свернуть сразу (курсор в конце), иначе оно мигнёт.
            desktop.expectProgrammaticFocus()
            focusedDay = day
        }
    }

    /// Полоса сегодняшнего дня: выходит влево за текст (в отступ окна) и плавно уходит в прозрачность по краям.
    private var todayHighlight: some View {
        let color = desktop.appearance.highlightColor
        return LinearGradient(
            stops: [
                .init(color: color.opacity(0), location: 0),
                .init(color: color, location: 0.10),
                .init(color: color, location: 0.75),
                .init(color: color.opacity(0), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
        .padding(.leading, -Self.highlightInset)
    }

    /// Верхний полностью видимый день (индекс зажат в границы: набор дней мог смениться).
    private var topVisibleDay: Date {
        days[min(visibleRange.lowerBound, days.count - 1)]
    }

    private func restorePosition(_ proxy: ScrollViewProxy) {
        if desktop.mode == .solid || (desktop.mode == .move && activePeriodStart != nil) {
            scrollHome(proxy)
        } else {
            proxy.scrollTo(topVisibleDay, anchor: .top)
        }
    }

    private func isMonday(_ day: Date) -> Bool {
        Self.calendar.component(.weekday, from: day) == 2
    }

    private func isMonthStart(_ day: Date) -> Bool {
        Self.calendar.component(.day, from: day) == 1 || day == days.first
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { entries[key]?.text ?? "" },
            set: {
                var entry = entries[key] ?? DayEntry(text: "")
                entry.text = $0
                entries[key] = entry.isEmpty ? nil : entry
                dirty.insert(key)
                // Пишем сразу, а не при выходе: так текст не теряется при выходе из приложения или сбое.
                save(key)
            })
    }

    /// Ставит курсор в поле заново: на сегодня, если оно на экране, иначе на верхний видимый день.
    private func focusEditor() {
        focusedDay = nil
        // Предыдущая попытка отменяется: иначе каждое didBecomeKey (в том числе от переоткрытия окна в refreshCaret)
        // запускало бы ещё один цикл, циклы копились, переоткрывали окно друг за другом, и лента мигала.
        focusTask?.cancel()
        focusTask = Task {
            await Task.yield()
            guard !Task.isCancelled, desktop.mode == .edit else { return }
            let todayIsVisible = days.firstIndex(of: today).map(visibleRange.contains) ?? false
            focusedDay = editingDay.flatMap { days.contains($0) ? $0 : nil }
                ?? (todayIsVisible ? today : topVisibleDay)
            // Фокус уже стоит, но курсор при повторном входе в edit может не нарисоваться, пока окно не стало key:
            // повторяем попытку (до секунды), пока курсор не заработает.
            for attempt in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, desktop.mode == .edit else { return }
                if desktop.refreshCaret(attempt: attempt) { break }
            }
        }
    }

    /// Переносит фокус на соседний день (вызывается из монитора клавиш окна).
    private func move(by step: Int, proxy: ScrollViewProxy) {
        guard let current = focusedDay, let index = days.firstIndex(of: current) else { return }
        // Месяц и неделя: за краем отрезка идёт соседний отрезок, как в ленте.
        if !days.indices.contains(index + step) {
            if desktop.appearance.viewKind.isPaged {
                pendingEdge = step
                periodOffset += step
            }
            return
        }
        let target = index + step
        focusedDay = days[target]
        // Лента стоит, пока фокус идёт по окну. У края она едет вслед по одной строке: показываем строку на
        // `margin` дальше фокуса, так фокус не доходит до края, а строки перед ним уже отрисованы (лента ленивая).
        let margin = 4
        if target < visibleRange.lowerBound + margin || target > visibleRange.upperBound - margin {
            let ahead = min(max(target + step * margin, 0), days.count - 1)
            proxy.scrollTo(days[ahead])
        }
    }

    private func reload() {
        entries = (try? DayStore().load()) ?? [:]
        // Начало ленты зависит от самой ранней записи; меняем массив, только если границы сдвинулись.
        let newDays = buildDays()
        if newDays != days { days = newDays }
        loadEvents()
    }

    private func buildDays() -> [Date] {
        let kind = desktop.appearance.viewKind
        return Self.days(around: today, earliest: Self.earliestDay(in: entries),
                         kind: kind.isPaged ? kind : .feed, offset: periodOffset)
    }

    /// Набор дней сменился: курсор edit и видимый диапазон относились к прежнему набору.
    private func rebuildDays(_ proxy: ScrollViewProxy) {
        days = buildDays()
        loadEvents()
        visibleRange = 0...0
        editingDay = pendingEdge.map { $0 > 0 ? days.first : days.last } ?? nil
        pendingEdge = nil
        pickerDay = nil
        if !desktop.appearance.viewKind.isPaged {
            scrollHome(proxy)
            // Ленивая лента точно встаёт на место только после отрисовки: прокручиваем с паузой.
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                scrollHome(proxy)
            }
        }
        if desktop.mode == .edit {
            focusedDay = nil
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                if desktop.mode == .edit { focusEditor() }
            }
        }
    }

    /// Пишет день в файл. Если запись не удалась, день остаётся в dirty и сохранится при следующей попытке.
    private func save(_ key: String) {
        guard dirty.contains(key) else { return }
        if (try? DayStore().set(entries[key]?.text ?? "", for: key)) != nil {
            dirty.remove(key)
        }
    }

    private func flush() {
        for key in dirty { save(key) }
    }
}

/// Режим «Период»: лента скрывается (плавно) и поверх неё лежит статичный слой периода. Вне этого режима вид не меняется.
private struct PeriodSwap<Layer: View>: ViewModifier {
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

private extension View {
    /// Прозрачность текста записи. Цветные эмодзи не берут прозрачность из цвета текста (`foregroundStyle`),
    /// поэтому она применяется как прозрачность самого вида, а цвет текста идёт без неё (иначе она сложилась бы дважды).
    func fadedLikeText(_ appearance: Appearance) -> some View {
        foregroundStyle(appearance.textColor).opacity(appearance.textOpacity)
    }
}

/// Ряд из 9 цветов и «без цвета» в виде скруглённых квадратов со стороной `size`.
/// Они выезжают из места индикатора вправо вдоль линии ввода, один за другим, и слегка проявляются. Выбор вызывает `onChoose` (nil — без цвета).
private struct ColorStrip: View {
    let size: Double
    let onChoose: (Int?) -> Void
    @State private var isOpen = false

    /// Невидимое поле вокруг кружка: по нему тоже можно попасть кликом.
    static let slotPadding = 2.0

    var body: some View {
        let count = Appearance.indicatorColors.count
        let slot = size + 2 * Self.slotPadding
        HStack(spacing: 0) {
            ForEach(0...count, id: \.self) { index in
                Button { onChoose(index < count ? index : nil) } label: {
                    swatch(index < count ? index : nil)
                        .frame(width: size, height: size)
                        .padding(Self.slotPadding)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .scaleEffect(isOpen ? 1 : 0.3)
                .opacity(isOpen ? 1 : 0)
                .offset(x: isOpen ? 0 : -Double(index) * slot)
                .animation(.spring(duration: 0.2, bounce: 0.15).delay(Double(index) * 0.01), value: isOpen)
            }
        }
        .onAppear { isOpen = true }
    }

    @ViewBuilder private func swatch(_ index: Int?) -> some View {
        if let index {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(Appearance.indicatorColors[index].opacity(Appearance.indicatorOpacity))
        } else {
            // «Без цвета»: пустой контур с крестиком.
            RoundedRectangle(cornerRadius: size * 0.25).strokeBorder(lineWidth: 1).opacity(0.5)
                .overlay { Image(systemName: "xmark").font(.system(size: size * 0.4)).opacity(0.5) }
        }
    }
}

