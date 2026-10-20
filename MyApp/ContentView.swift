import SwiftUI

/// Лента дней: год назад от самой ранней записи и два года вперёд от сегодняшнего дня, либо один месяц или неделя
/// (см. `ViewKind`). В edit текст каждого дня редактируется.
struct ContentView: View {
    let desktop: DesktopController
    @State private var entries: [String: DayEntry] = [:]
    /// Дни, изменённые, но ещё не записанные в файл.
    @State private var dirty: Set<String> = []
    /// Что не так с файлом данных (повреждён, скачивается, не записывается); nil — всё в порядке. Показывается в углу окна.
    @State private var dataProblem: String?
    /// Отложенное переразложение событий после смены приоритета календарей.
    @State private var orderTask: Task<Void, Never>?
    /// Отложенная запись текста, см. `scheduleSave`.
    @State private var saveTask: Task<Void, Never>?
    /// Время изменения файла при последнем чтении: по нему замечаем правки с другого Mac (iCloud).
    @State private var fileStamp: Date?
    /// Запасной интервал сверки файла, сек. Сверка читает только время изменения, сам файл перечитывается, если оно сменилось.
    private static let syncInterval = 600.0
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
    /// Месяц и неделя: на сколько отрезков окно сдвинуто от текущего (листание в scroll и edit; в locked всегда 0).
    @State private var periodOffset = 0
    /// Курсор ушёл за край отрезка стрелкой или Enter: +1 — встанет на первый день следующего, -1 — на последний предыдущего.
    @State private var pendingEdge: Int?
    /// Ширина колонки записей (одинакова у всех строк); по ней решается, можно ли рисовать запись поверх поля.
    @State private var recordWidth = 0.0
    /// Текущая попытка поставить курсор (см. `focusEditor`); новая отменяет предыдущую.
    @State private var focusTask: Task<Void, Never>?
    /// Высота первого дня идущего периода (с названием), см. `periodAnchor`.
    @State var periodItemHeight = 0.0
    /// Положение строк начала и конца периодов в окне ленты, см. `StickyPeriodTitles`.
    @State private var periodFrames = PeriodFrames()
    private static let feedSpace = "feed"

    // Константы без `private`: ими пользуются и файлы с периодами (PeriodViews) и рядом выбора цвета.
    static let calendar = Calendar.current
    /// «Сегодня» стоит примерно на трети высоты окна.
    private static let todayAnchor = UnitPoint(x: 0, y: 0.3)
    /// Приглушение для выходных и заголовков месяцев.
    static let mutedOpacity = 0.5
    /// Насколько полоса «сегодня» выходит влево за текст. ScrollView обрезает содержимое по своим границам,
    /// поэтому этот запас задан отступом внутри ленты, а не отступом окна.
    static let highlightInset = 35.0
    /// Линия периода: толщина и промежуток до соседней линии и до дат.
    static let lineWidth = 1.5
    static let lineGap = 3.0
    /// Промежуток между названием периода и линиями.
    static let titleGap = 6.0
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
                .padding(.vertical, desktop.isCompact ? desktop.edgeFade : 0)
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
                desktop.flushPending = { flush() }
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
            // Приоритет календарей меняется перетаскиванием в настройках: события переразбираются чуть позже, когда
            // перетаскивание уже закончилось (иначе картинка строки висит на экране, пока лента перерисовывается).
            .onChange(of: desktop.appearance.eventCalendarOrder) {
                orderTask?.cancel()
                orderTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    loadEvents()
                }
            }
            .onChange(of: desktop.events.isAuthorized) { loadEvents() }
            // Сменился идущий период (правка списка, начало или конец) или его место в окне: лента встаёт заново.
            .onChange(of: activePeriodStart) { restorePosition(proxy) }
            // Высота первого дня меняется и при входе в edit (поле вместо текста, события): ленту двигать нельзя,
            // иначе она сдвигается на пункт-два. Подгонка нужна только там, где лента стоит по якорю периода.
            .onChange(of: periodItemHeight) {
                if desktop.mode == .locked || desktop.mode == .move { restorePosition(proxy) }
            }
            .onChange(of: desktop.periodOffset) { restorePosition(proxy) }
            // После смены ширины лента возвращается на место: в locked к сегодняшнему дню, в остальных режимах
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
                if mode == .locked {
                    periodOffset = 0
                    if activePeriodStart == nil {
                        scrollHome(proxy)
                    } else {
                        // Лента под слоем периода встаёт на место, когда слой уже её закрыл (не видно прыжка).
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            if desktop.mode == .locked { scrollHome(proxy) }
                        }
                    }
                }
            }
            // Ленивая лента при первой прокрутке к далёкой строке оценивает её положение приблизительно:
            // после отрисовки при запуске прокручиваем ещё раз, уже точно.
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                if desktop.mode == .locked { scrollHome(proxy) }
            }
            // Окно становится key не сразу: активация приложения асинхронна. Фокус, поставленный до этого,
            // не даёт курсора (лента «листает фокус», но курсора нет), поэтому ставим его заново, когда окно готово.
            .task {
                for await note in NotificationCenter.default.notifications(named: NSWindow.didBecomeKeyNotification) {
                    if note.object is DesktopWindow, desktop.mode == .edit { focusEditor() }
                }
            }
            // Файл мог измениться на другом Mac (iCloud). Сверяем время его изменения в естественные моменты:
            // после пробуждения, при смене Space и (на случай, если ничего этого долго нет) по редкому таймеру.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.syncInterval))
                    syncIfFileChanged()
                }
            }
            .task {
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                    syncIfFileChanged()
                }
            }
            .task {
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.activeSpaceDidChangeNotification) {
                    syncIfFileChanged()
                }
            }
            // Файл данных переехал в другую папку (меню «Папка данных…»).
            .task {
                for await _ in NotificationCenter.default.notifications(named: .dataFolderChanged) { reload() }
            }
            // Смена даты (полночь, пробуждение после сна): лента едет вместе с «сегодня».
            .task {
                for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
                    today = Self.calendar.startOfDay(for: .now)
                    syncIfFileChanged()
                    // Период мог начаться или кончиться: окно подгоняется заново.
                    rebuildDays(proxy)
                    desktop.fitWindow()
                    if desktop.mode == .locked { scrollHome(proxy) }
                }
            }
        }
        // Режим «Период» в locked: ленту заменяет статичный слой периода, лента под ним невидима. В остальных видах
        // лента остаётся без этих надстроек.
        .modifier(PeriodSwap(isActive: desktop.appearance.viewKind == .period,
                             hidesContent: desktop.shownPeriod != nil, layer: periodLayer))
        // Без отступов сверху и снизу: лента уходит за края окна, а затухание у краёв создаёт ощущение бесконечности.
        // К затуханию у краёв добавляется мягкое «окно» под названием режима: лента под ним прозрачна до рабочего стола,
        // и название не сливается с текстом.
        .mask {
            edgeFadeMask
                .overlay(alignment: .topTrailing) { modePlateHole }
                .compositingGroup()
        }
        .font(desktop.appearance.font)
        .foregroundStyle(desktop.appearance.textColor.opacity(desktop.appearance.textOpacity))
        .padding(.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 0) {
                modeIndicator
                dataProblemLabel
            }
        }
    }

    /// Предупреждение о проблеме с файлом данных (под индикатором режима, виден во всех режимах).
    @ViewBuilder private var dataProblemLabel: some View {
        if let dataProblem {
            Text("⚠ \(dataProblem)")
                .font(desktop.appearance.smallFont)
                .foregroundStyle(desktop.appearance.textColor)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 240, alignment: .trailing)
                .padding(.horizontal)
                .opacity(0.8)
                .allowsHitTesting(false)
        }
    }

    /// День ленты: заголовок месяца, строка дня и линии периодов. Один и тот же вид в ленте и в статичном слое периода.
    func dayItem(_ day: Date, reportsFrames: Bool = false) -> some View {
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

    /// Домашняя позиция ленты: при идущем периоде («Период») его начало на заданном месте, иначе «сегодня».
    private func scrollHome(_ proxy: ScrollViewProxy) {
        if let start = activePeriodStart, days.contains(start) {
            proxy.scrollTo(start, anchor: periodAnchor)
        } else {
            proxy.scrollTo(today, anchor: Self.todayAnchor)
        }
    }

    /// Маска: лента плавно уходит в прозрачность у верхнего и нижнего края окна.
    private var edgeFadeMask: some View {
        let fade = desktop.edgeFade
        return VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: fade)
        }
    }

    /// Режим в правом верхнем углу: появляется сразу при смене режима. Горит в scroll, edit и move;
    /// locked показывается секунду и плавно гаснет.
    /// Строка «> режим»: промежуток в полпробела, а знак «>» опущен на пару пунктов, чтобы стоять по центру строчных букв.
    private var modeLabel: some View {
        HStack(spacing: 4) {
            Text(">").baselineOffset(-1)
            // Невидимое «scroll» (самое длинное слово) задаёт ширину: «>» стоит на месте, слово меняется за ним.
            ZStack(alignment: .leading) {
                Text("scroll").hidden()
                Text(desktop.mode.rawValue)
            }
        }
        .font(desktop.appearance.font)
    }

    /// Отступ строки режима сверху. Лента: ниже строки меню, окно уходит под неё. Месяц и неделя: окно небольшое.
    private var modeTopInset: Double { desktop.isCompact ? 8 : 56 }

    /// Прозрачное «окно» в маске ленты под строкой режима: ровный прямоугольник с небольшим скруглением, вырезает ленту
    /// до рабочего стола. Подгоняется под слово: начинается от «>» (он стоит на месте) и кончается за словом режима.
    /// Положение задаёт невидимая строка `modeLabel` той же ширины, что и настоящая, а плашка рисуется за ней.
    /// Гаснет вместе с самим названием.
    private var modePlateHole: some View {
        modeLabel
            .foregroundStyle(.clear)
            .background(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(">").baselineOffset(-1)
                    Text(desktop.mode.rawValue)
                }
                .font(desktop.appearance.font)
                .foregroundStyle(.clear)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.black))
                .padding(.leading, -10)
            }
            .padding(.top, modeTopInset)
            .blendMode(.destinationOut)
            .opacity(isIndicatorVisible ? 1 : 0)
    }

    private var modeIndicator: some View {
        modeLabel
        .foregroundStyle(desktop.appearance.textColor)
        .padding(.horizontal)
        .padding(.top, modeTopInset)
        .opacity(isIndicatorVisible ? 0.5 : 0)
        .task(id: desktop.mode) {
            isIndicatorVisible = true
            guard desktop.mode == .locked else { return }
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
                    // Буквы рисует тот же Text, что и в locked (поле ввода рисует тот же шрифт на пиксель иначе, и
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
                        // Высоту строки задаёт тот же Text, что и в locked, а поле лежит поверх и на размер не влияет:
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
        desktop.events.load(days: days, calendarIDs: ids, order: desktop.appearance.eventCalendarOrder)
    }

    /// Запись в ленте (locked, scroll) и поверх поля в edit: одна и та же вёрстка, чтобы буквы стояли в одном месте.
    private func recordText(_ text: AttributedString) -> some View {
        // Текст, дойдя до края окна, переносится на следующую строку и виден целиком.
        // Пустая запись рисуется пробелом: пустой Text ниже обычной строки на пиксель, и события календаря под ней
        // сдвигались вниз, как только появлялась первая буква.
        Text(text.characters.isEmpty ? AttributedString(" ") : text)
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
    /// Есть ссылка: стрелка видна всегда, в scroll и edit открывает заметку (в locked клики проходят сквозь окно);
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
                if hasNote && isEdit { Button("Remove Note Link") { setNote(nil, for: day) } }
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
        if desktop.mode == .locked || (desktop.mode == .move && activePeriodStart != nil) {
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
                scheduleSave()
            })
    }

    /// Файл пишется через полторы секунды после последней буквы, а не на каждую (иначе каждый символ перезаписывает
    /// весь файл и гоняет синхронизацию iCloud). Дальше сброс при выходе из edit, при перечитывании файла и при выходе
    /// из приложения (`flushPending`), так что потерять можно не больше последних секунд при сбое.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            flush()
        }
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

    /// Перечитывает файл, если он изменился с прошлого чтения. В edit не трогаем: пользователь печатает,
    /// а свои записи он уже сохранил.
    private func syncIfFileChanged() {
        if desktop.mode != .edit, DayStore().modificationDate != fileStamp { reload() }
    }

    private func reload() {
        // Несохранённый текст уходит в файл до перечитывания, иначе его затёрли бы записи из файла.
        flush()
        let store = DayStore()
        do {
            entries = try store.load()
            dataProblem = nil
        } catch {
            // Не прочиталось (файл скачивается из iCloud или повреждён): остаются прежние записи, а не пустая лента,
            // и в углу окна появляется предупреждение.
            dataProblem = DayStore.problemText(for: error)
        }
        fileStamp = store.modificationDate
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
        do {
            try DayStore().set(entries[key]?.text ?? "", for: key)
            dirty.remove(key)
            dataProblem = nil
        } catch {
            dataProblem = DayStore.problemText(for: error)
        }
    }

    private func flush() {
        for key in dirty { save(key) }
    }
}


