import SwiftUI

/// Лента дней: 180 дней назад и 180 вперёд от сегодняшнего. В edit текст каждого дня редактируется.
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

    private static let calendar = Calendar.current
    /// «Сегодня» стоит примерно на трети высоты окна.
    private static let todayAnchor = UnitPoint(x: 0, y: 0.3)
    /// Приглушение для выходных и заголовков месяцев.
    private static let mutedOpacity = 0.5
    /// Насколько полоса «сегодня» выходит влево за текст. ScrollView обрезает содержимое по своим границам,
    /// поэтому этот запас задан отступом внутри ленты, а не отступом окна.
    private static let highlightInset = 35.0
    /// Дополнительный отступ перед понедельником, когда он включён.
    private static let weekGapHeight = 12.0

    private static func days(around today: Date) -> [Date] {
        (-180...180).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        VStack(alignment: .leading, spacing: 0) {
                            if desktop.appearance.showsMonth && isMonthStart(day) {
                                Text(desktop.appearance.monthText(day))
                                    .bold(desktop.appearance.monthBold)
                                    .opacity(Self.mutedOpacity)
                                    .padding(.vertical, 12)
                            }
                            row(day)
                        }
                        // Отступ перед понедельником; у заголовка месяца свой отступ, первый день не сдвигаем.
                        .padding(.top, desktop.appearance.weekGap && isMonday(day) && !isMonthStart(day) ? Self.weekGapHeight : 0)
                    }
                }
                .scrollTargetLayout()
                .padding(.leading, Self.highlightInset)
            }
            .scrollIndicators(.hidden)
            .onScrollTargetVisibilityChange(idType: Date.self, threshold: 0.9) { ids in
                let indices = ids.compactMap { days.firstIndex(of: $0) }
                if let first = indices.min(), let last = indices.max() { visibleRange = first...last }
            }
            .onAppear {
                reload()
                proxy.scrollTo(today, anchor: Self.todayAnchor)
                desktop.moveFocus = { step in move(by: step, proxy: proxy) }
            }
            // После смены ширины лента возвращается на место: в solid к сегодняшнему дню, в остальных режимах
            // к верхнему из видимых дней.
            // Режим «несколько строк» выключили: все записи склеиваются в одну строку (в файле тоже).
            .onChange(of: desktop.appearance.allowsMultiline) { _, isOn in
                guard !isOn else { return }
                flush()
                try? DayStore().flattenLines()
                reload()
            }
            .onChange(of: desktop.appearance.width) { restorePosition(proxy) }
            // Смена размера шрифта меняет высоту строк: лента возвращается на место так же.
            .onChange(of: desktop.appearance.fontSize) { restorePosition(proxy) }
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
                // Выход из просмотра возвращает ленту к сегодняшнему дню.
                if mode == .solid { proxy.scrollTo(today, anchor: Self.todayAnchor) }
            }
            // Ленивая лента при первой прокрутке к далёкой строке оценивает её положение приблизительно:
            // после отрисовки при запуске прокручиваем ещё раз, уже точно.
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                if desktop.mode == .solid { proxy.scrollTo(today, anchor: Self.todayAnchor) }
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
                    days = Self.days(around: today)
                    if desktop.mode == .solid { proxy.scrollTo(today, anchor: Self.todayAnchor) }
                }
            }
        }
        // Без отступов сверху и снизу: лента уходит за края окна, а затухание у краёв создаёт ощущение бесконечности.
        .mask { edgeFadeMask }
        .font(desktop.appearance.font)
        .foregroundStyle(desktop.appearance.textColor.opacity(desktop.appearance.textOpacity))
        .padding(.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) { modeIndicator }
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
        // Ниже строки меню: окно уходит под неё.
        .padding(.top, 56)
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
        let multiline = desktop.appearance.allowsMultiline
        // Дата стоит на уровне первой строки записи, остальные строки идут под ней в колонке записей.
        return HStack(alignment: .firstTextBaseline, spacing: Self.dotGap) {
            Text(label)
                .opacity(isWeekend ? Self.mutedOpacity : 1)
                // Колонка даты фиксированной ширины: индикаторы и записи стоят на одной вертикали при любом шрифте.
                .frame(width: desktop.appearance.dateColumnWidth, alignment: .leading)
            // Место под индикатор (сам он рисуется поверх, см. `indicator`), между датой и записью.
            Color.clear.frame(width: Self.dotWidth, height: 0)
            // Пока раскрыт выбор цвета, запись скрыта: ряд цветов открывается вдоль линии ввода, на её месте.
            Group {
                // Пока раскрыт выбор цвета, поля ввода нет вовсе: даже скрытое, оно заставляет курсор мыши
                // над рядом цветов становиться текстовым. Вместо него обычный текст.
                if desktop.mode == .edit && pickerDay != day {
                    TextField("", text: binding(for: key), axis: multiline ? .vertical : .horizontal)
                        .textFieldStyle(.plain)
                        .lineLimit(multiline ? 1...20 : 1...1)
                        // Поле растёт вниз по мере переноса текста на новые строки.
                        .fixedSize(horizontal: false, vertical: true)
                        .fadedLikeText(desktop.appearance)
                        .focused($focusedDay, equals: day)
                } else {
                    let text = entries[key]?.text ?? ""
                    if multiline {
                        // Несколько строк: текст, дойдя до края окна, переносится на следующую строку и виден целиком.
                        Text(desktop.appearance.displayText(text.trimmingCharacters(in: .newlines)))
                            .fadedLikeText(desktop.appearance)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Одна строка: что не влезло, обрезается многоточием.
                        Text(desktop.appearance.displayText(text))
                            .fadedLikeText(desktop.appearance)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .opacity(pickerDay == day ? 0 : 1)
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
        .padding(.vertical, Self.rowPadding)
        // Линия в оверлее строки с отступами: у соседних дней она идёт сплошной.
        .overlay(alignment: .leading) {
            if desktop.appearance.showsDivider {
                Rectangle()
                    .frame(width: 1)
                    .opacity(0.25)
                    .offset(x: desktop.appearance.dateColumnWidth + Self.dotGap / 2)
            }
        }
        .overlay(alignment: .topLeading) { indicator(for: day) }
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

    /// Вертикальный отступ внутри строки дня (сверху и снизу).
    private static let rowPadding = 2.0
    /// Индикатор — вертикальная планка: ширина, а высота одиночного дня как доля высоты строки.
    private static let dotWidth = 4.0
    private static let markerHeightFactor = 0.8
    /// Высота планки одиночного дня; ряд выбора цвета состоит из таких же планок.
    private var markerHeight: Double { desktop.appearance.lineHeight * Self.markerHeightFactor }
    /// Промежуток между колонкой даты, индикатором и записью.
    private static let dotGap = 4.0
    /// Левый край индикатора: сразу за колонкой даты, перед записью.
    private var dotX: Double { desktop.appearance.dateColumnWidth + Self.dotGap }

    /// Высота центра индикатора в строке высотой `height`: середина первой строки записи
    /// (у однострочного дня это середина строки).
    private func centerY(in height: Double) -> Double {
        min(height / 2, Self.rowPadding + desktop.appearance.lineHeight / 2)
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
        entries[key] = entry.text.isEmpty && entry.color == nil ? nil : entry
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

    private func restorePosition(_ proxy: ScrollViewProxy) {
        if desktop.mode == .solid {
            proxy.scrollTo(today, anchor: Self.todayAnchor)
        } else {
            proxy.scrollTo(days[visibleRange.lowerBound], anchor: .top)
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
                entries[key] = entry.text.isEmpty && entry.color == nil ? nil : entry
                dirty.insert(key)
                // Пишем сразу, а не при выходе: так текст не теряется при выходе из приложения или сбое.
                save(key)
            })
    }

    /// Ставит курсор в поле заново: на сегодня, если оно на экране, иначе на верхний видимый день.
    private func focusEditor() {
        focusedDay = nil
        Task {
            await Task.yield()
            guard desktop.mode == .edit else { return }
            let todayIsVisible = days.firstIndex(of: today).map(visibleRange.contains) ?? false
            focusedDay = editingDay.flatMap { days.contains($0) ? $0 : nil }
                ?? (todayIsVisible ? today : days[visibleRange.lowerBound])
            // Фокус уже стоит, но курсор при повторном входе в edit может не нарисоваться, пока окно не стало key:
            // повторяем попытку (до секунды), пока курсор не заработает.
            for attempt in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                guard desktop.mode == .edit else { return }
                if desktop.refreshCaret(attempt: attempt) { break }
            }
        }
    }

    /// Переносит фокус на соседний день (вызывается из монитора клавиш окна).
    private func move(by step: Int, proxy: ScrollViewProxy) {
        guard let current = focusedDay, let index = days.firstIndex(of: current),
              days.indices.contains(index + step) else { return }
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

