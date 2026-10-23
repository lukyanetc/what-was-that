import SwiftUI
import Carbon

/// locked → scroll → edit → locked по Opt+M. move (перемещение окна) включается отдельной кнопкой в меню.
enum Mode: String, CaseIterable {
    case locked, scroll, edit, move

    var next: Mode {
        switch self {
        case .locked: .scroll
        case .scroll: .edit
        case .edit, .move: .locked
        }
    }
}

/// Безрамочное окно не может стать key по умолчанию, а для edit и move это нужно.
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    /// Окно занимает весь экран по высоте, в том числе под строкой меню и Dock: система не должна его сдвигать.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// В режиме move мышь двигает окно: у ленты (окно на всю высоту) только по горизонтали,
    /// у месяца и недели (окно по размеру контента) в любое место экрана.
    var isMoveMode = false
    var canMoveVertically = false
    /// Вызывается после каждого шага перемещения.
    var onMoved: (() -> Void)?
    /// Вертикальный сдвиг мыши, когда окно само по вертикали не двигается (режим «Период»): сдвигает период в окне.
    var onVerticalDrag: ((Double) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        guard isMoveMode else { return super.sendEvent(event) }
        switch event.type {
        case .leftMouseDragged:
            let area = (screen ?? NSScreen.main)?.frame ?? frame
            let x = min(max(frame.minX + event.deltaX, area.minX), area.maxX - frame.width)
            // deltaY положителен при движении мыши вниз, а ось y окна направлена вверх.
            let y = canMoveVertically ? min(max(frame.minY - event.deltaY, area.minY), area.maxY - frame.height) : frame.minY
            setFrameOrigin(NSPoint(x: x, y: y))
            if !canMoveVertically { onVerticalDrag?(event.deltaY) }
            onMoved?()
        case .leftMouseDown, .leftMouseUp:
            break
        default:
            super.sendEvent(event)
        }
    }
}

/// Окно на уровне обоев + текущий режим.
@Observable final class DesktopController {
    var mode = Mode.locked {
        didSet {
            if oldValue == .move { savePeriodTop() }
            apply()
            if oldValue == .edit { fitWindow() }
        }
    }
    let appearance = Appearance()
    /// События системного календаря (только чтение).
    let events = CalendarEvents()
    /// Проверка обновлений через GitHub Releases.
    let updates = UpdateChecker()
    /// Период, который окно показывает сейчас: режим «Период», пока период идёт, и только в locked и move.
    /// Остальные дни при этом прозрачны; в scroll и edit они проявляются, окно и лента не меняются.
    /// Период, который не помещается в окно, не показывается отдельно: тогда режим «Период» показывает ленту.
    var shownPeriod: Period? {
        guard appearance.viewKind == .period, mode == .locked || mode == .move, periodFits else { return nil }
        return appearance.activePeriod
    }
    /// Высота периода в ленте; измеряет статичный слой периода, даже когда он невидим.
    var periodContentHeight = 0.0
    var periodFits: Bool { periodContentHeight <= appearance.periodRoom(screenHeight: screenFrame.height) }
    /// Окно по размеру содержимого (месяц, неделя), а не на весь экран. Период, как и лента, на весь экран.
    var isCompact: Bool { appearance.viewKind.isPaged }
    /// Высота затухания у верхнего и нижнего края. Настройка действует только в окне на весь экран (Feed, Range).
    /// В месяце и неделе окно по размеру содержимого: затухание там постоянное, иначе настройка двигала бы окно и текст.
    var edgeFade: Double { isCompact ? Self.compactEdgeFade : appearance.edgeFade }
    private static let compactEdgeFade = 24.0
    /// Отступ первого дня периода от верха окна (хранится в настройках внешнего вида).
    var periodOffset: Double {
        get { appearance.periodOffset }
        set { appearance.periodOffset = newValue }
    }
    /// Переносит фокус ввода на соседний день; выставляет лента.
    @ObservationIgnored var moveFocus: ((Int) -> Void)?
    /// Листает месяц или неделю на соседний отрезок (+1 вперёд, -1 назад); выставляет лента.
    @ObservationIgnored var shiftPeriod: ((Int) -> Void)?
    /// Записывает несохранённый текст в файл (при выходе из приложения); выставляет лента.
    @ObservationIgnored var flushPending: (() -> Void)?
    /// Колесо и жесты в scroll: накопленная прокрутка текущего жеста и признак, что он уже перелистнул отрезок.
    @ObservationIgnored private var scrollAccum = 0.0
    @ObservationIgnored private var scrollLocked = false
    @ObservationIgnored private var lastWheelShift = Date.distantPast

    @ObservationIgnored private var window: DesktopWindow?
    @ObservationIgnored private var hotKey: HotKey?
    /// Esc как глобальный хоткей, пока включён scroll: в scroll приложение не активно (фокус у другого приложения),
    /// и обычные нажатия клавиш до нас не доходят.
    @ObservationIgnored private var escapeKey: HotKey?
    /// Последнее активное приложение, кроме нашего: ему возвращается фокус при выходе из edit/move.
    @ObservationIgnored private var lastExternalApp: NSRunningApplication?
    /// Момент последнего ввода пользователя в окне (клавиша или мышь), см. снятие выделения при фокусе.
    @ObservationIgnored private var lastUserInput = Date.distantPast
    /// Позиция курсора в строке в момент перехода на другой день (стрелка вверх/вниз или Enter).
    @ObservationIgnored private var lastMove: (column: Int, time: Date, step: Int)?

    /// Высота содержимого месяца или недели; измеряет лента. По ней подгоняется окно в этих режимах.
    /// Дробные колебания (меньше пункта) игнорируются, чтобы окно не дёргалось. В edit окно только растёт (когда
    /// запись переносится на новую строку), но не сжимается: частая смена размера окна сбивала фокус и вызывала
    /// мигание. После выхода из edit окно подгоняется под актуальную высоту.
    @ObservationIgnored var periodHeight = 0.0 {
        didSet {
            guard abs(periodHeight - oldValue) >= 1, mode != .edit || periodHeight > oldValue else { return }
            fitWindow()
        }
    }
    /// Верхний край окна месяца или недели (его двигает пользователь в move); nil — под строкой меню.
    @ObservationIgnored private var periodTop = UserDefaults.standard.object(forKey: "periodTop") as? Double

    /// Запоминает верхний край окна месяца или недели: при смене числа строк (28–31 день) окно растёт вниз,
    /// а не прыгает, и место сохраняется между запусками.
    private func savePeriodTop() {
        // Окно сейчас по размеру содержимого, если при последней подгонке оно было таким (canMoveVertically).
        guard let window, window.canMoveVertically, periodHeight > 0 else { return }
        periodTop = window.frame.maxY
        UserDefaults.standard.set(window.frame.maxY, forKey: "periodTop")
    }

    /// Лента: высота и y окна по всему экрану (лента уходит под строку меню и Dock). Месяц и неделя: окно по размеру
    /// содержимого, верхний край на месте, пока пользователь его не передвинет. Ширина из настроек, окно целиком на экране.
    func fitWindow() {
        guard let window, let screen = (window.screen ?? NSScreen.main)?.frame else { return }
        let width = min(appearance.width, screen.width)
        let x = min(max(window.frame.minX, screen.minX), screen.maxX - width)
        window.canMoveVertically = isCompact && periodHeight > 0
        if !isCompact || periodHeight == 0 {
            window.setFrame(NSRect(x: x, y: screen.minY, width: width, height: screen.height), display: true)
        } else {
            let height = min(ceil(periodHeight), screen.height)
            let top = periodTop ?? screen.maxY - 120
            let y = min(max(top - height, screen.minY), screen.maxY - height)
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
    }

    /// Глобальный хоткей переключения режимов (по умолчанию Opt+M); комбинация задаётся в настройках.
    func registerHotKey() {
        hotKey?.unregister()
        hotKey = HotKey(keyCode: appearance.hotKeyCode, modifiers: appearance.hotKeyModifiers) { [weak self] in
            self?.mode = self?.mode.next ?? .locked
        }
    }

    /// На время записи новой комбинации хоткей снимается, иначе система перехватит нажатие раньше окна настроек.
    func pauseHotKey(_ paused: Bool) {
        if paused {
            hotKey?.unregister()
            hotKey = nil
        } else {
            registerHotKey()
        }
    }

    var screenFrame: NSRect { (window?.screen ?? NSScreen.main)?.frame ?? .zero }

    func start() {
        // Файл данных переименован вместе с приложением: прежний (d-cal.json) копируется под новым именем.
        DayStore.migrateLegacyFile(in: DayStore.defaultURL.deletingLastPathComponent())
        let window = DesktopWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // Положение запоминается между запусками, но из него берётся только x (см. fitWindow).
        let hasSavedFrame = UserDefaults.standard.object(forKey: "NSWindow Frame d-cal") != nil
        window.setFrameAutosaveName("d-cal")
        // Первый запуск (положения ещё нет): левый край окна на трети ширины экрана. Дальше работает запомненное
        // положение (его двигает пользователь в режиме move).
        if !hasSavedFrame, let screen = NSScreen.main?.frame {
            window.setFrameOrigin(NSPoint(x: screen.minX + screen.width / 3, y: screen.minY))
        }
        // Размер окна задаётся до того, как появится лента: иначе она прокручивается к сегодняшнему дню
        // в окне нулевого размера и после подгонки оказывается не на месте.
        self.window = window
        fitWindow()
        window.contentView = NSHostingView(rootView: ContentView(desktop: self))
        window.orderFrontRegardless()
        appearance.onLayoutChange = { [weak self] in self?.fitWindow() }
        window.onMoved = { [weak self] in self?.savePeriodTop() }
        window.onVerticalDrag = { [weak self] delta in
            guard let self, appearance.viewKind == .period else { return }
            // Период не выходит за верх экрана и оставляет внизу место хотя бы под одну строку.
            periodOffset = min(max(periodOffset + delta, appearance.edgeFade), max(screenFrame.height - 100, 0))
        }
        apply()
        events.refreshAuthorization()
        enableLoginItemOnFirstLaunch()
        if appearance.checksUpdatesAtLaunch { Task { await updates.checkAtLaunch() } }

        // Opt+M: locked → scroll → edit → locked
        registerHotKey()
        appearance.onHotKeyChange = { [weak self] in self?.registerHotKey() }
        // Запоминаем, какое приложение было активным до нас. Нельзя брать его только в момент входа в edit:
        // приложение может быть активным уже в locked (например, сразу после запуска), и тогда запоминать нечего.
        let current = NSRunningApplication.current
        if let front = NSWorkspace.shared.frontmostApplication, !front.isEqual(current) { lastExternalApp = front }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !app.isEqual(NSRunningApplication.current) else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }
        // Обои у каждого Space свои: при переключении измеряем заново.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWallpaper() }
        }
        // Клавиши окна (работают, когда окно в фокусе, то есть в edit и move). Монитор получает и повторы при
        // зажатой клавише. Esc → locked; стрелки вверх/вниз и Enter переносят фокус на соседний день.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Клавиши обрабатываются только в окне на рабочем столе: в окне настроек Esc, стрелки и Enter остаются его.
            guard let self, event.window === window, mode != .locked else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape: mode = .locked
            case kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_ANSI_KeypadEnter:
                let code = Int(event.keyCode)
                let isReturn = code != kVK_UpArrow && code != kVK_DownArrow
                let editor = self.window?.firstResponder as? NSTextView
                if let editor {
                    // Несколько строк в дне: Shift+Enter, Cmd+Enter или Opt+Enter добавляют строку, стрелки сначала
                    // ходят по строкам дня и переходят на другой день только с первой (вверх) или последней (вниз) строки.
                    if isReturn, !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
                        lastUserInput = .now
                        editor.insertNewlineIgnoringFieldEditor(nil)
                        return nil
                    }
                    let text = editor.string as NSString
                    let location = editor.selectedRange().location
                    if code == kVK_UpArrow, text.substring(to: location).contains("\n") { return event }
                    if code == kVK_DownArrow, text.substring(from: location).contains("\n") { return event }
                }
                // Переход на другой день: предыдущая клавиша (например, стрелка влево) не должна считаться
                // вводом, иначе выделение нового поля не снимется. Позиция курсора в строке переносится
                // в новое поле, как в обычных редакторах.
                lastUserInput = .distantPast
                let step = code == kVK_UpArrow ? -1 : 1
                if let editor {
                    let text = editor.string as NSString
                    let location = editor.selectedRange().location
                    let column = location - text.lineRange(for: NSRange(location: location, length: 0)).location
                    lastMove = (column, .now, step)
                }
                moveFocus?(step)
            default:
                lastUserInput = .now
                return event
            }
            return nil
        }
        // Месяц и неделя в scroll и edit: один жест (или щелчок колеса) листает на один отрезок.
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Только колесо над окном на рабочем столе: над окном настроек и другими окнами приложения листать нельзя.
            guard let self, event.window === window, mode == .scroll || mode == .edit,
                  appearance.viewKind.isPaged else { return event }
            // Прокрутка вниз (контент уезжает вверх) — следующий отрезок; направление уже учитывает натуральную прокрутку.
            let step = event.scrollingDeltaY < 0 ? 1 : -1
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                scrollAccum = 0
                scrollLocked = false
            }
            if event.phase.isEmpty && event.momentumPhase.isEmpty {
                // Колесо мыши: щелчки приходят без фаз, повторы подряд сглаживаем паузой.
                if event.scrollingDeltaY != 0, Date.now.timeIntervalSince(lastWheelShift) > 0.25 {
                    lastWheelShift = .now
                    shiftPeriod?(step)
                }
            } else if !scrollLocked {
                scrollAccum += event.scrollingDeltaY
                if abs(scrollAccum) > 30 {
                    scrollLocked = true
                    scrollAccum = 0
                    shiftPeriod?(step)
                }
            }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.lastUserInput = .now
            return event
        }
        // Поле, получая фокус, выделяет весь текст. Выделение всей строки, которое пришло не от пользователя
        // (не от клавиши и не от мыши), сворачиваем сразу в уведомлении, до отрисовки: так нет мигания.
        NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.mode == .edit, let editor = note.object as? NSTextView,
                      editor.isFieldEditor, editor.window === self.window else { return }
                // Выделение полупрозрачное цветом текста: буквы рисует слой под полем, а обычное непрозрачное выделение
                // их закрывало, и выделенный текст не был виден.
                editor.selectedTextAttributes = [.backgroundColor: NSColor(self.appearance.textColor).withAlphaComponent(0.3)]
                let range = editor.selectedRange()
                guard range.length > 0, range.length == editor.string.utf16.count,
                      Date.now.timeIntervalSince(self.lastUserInput) > 0.3 else { return }
                // После перехода между днями курсор встаёт в ту же позицию строки, иначе в конец.
                // Вверх попадаем на последнюю строку дня, вниз на первую.
                var location = range.upperBound
                if let move = self.lastMove, Date.now.timeIntervalSince(move.time) < 0.3 {
                    let text = editor.string as NSString
                    let line = text.lineRange(for: NSRange(location: move.step < 0 ? text.length : 0, length: 0))
                    let hasBreak = line.length > 0 && text.character(at: line.upperBound - 1) == 10
                    location = line.location + min(move.column, line.length - (hasBreak ? 1 : 0))
                }
                self.lastMove = nil
                editor.setSelectedRange(NSRange(location: location, length: 0))
            }
        }
    }

    /// Курсор в поле ввода не рисуется, пока окно не key. Пока окно ещё не key, просим систему сделать его key.
    /// Если это не удаётся несколько попыток подряд, переоткрываем окно (NSApp.keyWindow мог остаться указывать
    /// на окно, и тогда makeKey ничего не делает); это даёт заметное мигание, поэтому только как крайняя мера.
    /// Когда окно key, перезапускаем курсор у редактора поля. Возвращает true, когда всё готово.
    func refreshCaret(attempt: Int) -> Bool {
        if let window, !window.isKeyWindow {
            if attempt >= 5 { window.orderOut(nil) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        guard let window, window.isKeyWindow, let editor = window.firstResponder as? NSTextView else { return false }
        collapseSelection()
        // Текст поля прозрачен (буквы рисует Text поверх него), а курсор по умолчанию берёт цвет текста: задаём явно.
        editor.insertionPointColor = NSColor(appearance.textColor)
        editor.selectedTextAttributes = [.backgroundColor: NSColor(appearance.textColor).withAlphaComponent(0.3)]
        editor.updateInsertionPointStateAndRestartTimer(true)
        editor.needsDisplay = true
        return true
    }

    /// Следующее выделение всей строки при получении фокуса будет свёрнуто сразу, без мигания: клик, после которого
    /// поле получает фокус (например, выбор цвета), не должен считаться вводом пользователя в это поле.
    func expectProgrammaticFocus() {
        lastUserInput = .distantPast
        lastMove = nil
    }

    /// Поле при получении фокуса выделяет весь текст; оставляем только курсор в конце строки.
    func collapseSelection() {
        guard let editor = window?.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    }

    /// Яркость обоев пересчитывается при каждой смене режима: так учитываются сдвиг окна и смена обоев.
    private func refreshWallpaper() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        appearance.refresh(window: window.frame, on: screen)
    }

    private func apply() {
        refreshWallpaper()
        if mode == .scroll {
            if escapeKey == nil { escapeKey = HotKey(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.mode = .locked } }
        } else {
            escapeKey?.unregister()
            escapeKey = nil
        }
        window?.isMoveMode = mode == .move
        window?.ignoresMouseEvents = mode == .locked
        // locked: под значками рабочего стола. Остальные режимы: чуть выше значков (но всё равно ниже обычных окон),
        // иначе клики перехватывает рабочий стол Finder.
        let key: CGWindowLevelKey = mode == .locked ? .desktopWindow : .desktopIconWindow
        window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(key)) + 1)
        if mode == .edit || mode == .move {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        } else if NSApp.isActive {
            // NSApp.deactivate() ненадёжен: приложение остаётся активным, а окно теряет key (в диагностике так и было
            // после Esc, и окно потом не могло снова стать key). Фокус возвращается прежнему приложению явно.
            if lastExternalApp?.activate(from: NSRunningApplication.current, options: []) != true { NSApp.deactivate() }
        }
    }
}
