import SwiftUI
import Carbon

/// solid → scroll → edit → solid по Opt+M. move (перемещение окна) включается отдельной кнопкой в меню.
enum Mode: String, CaseIterable {
    case solid, scroll, edit, move

    var next: Mode {
        switch self {
        case .solid: .scroll
        case .scroll: .edit
        case .edit, .move: .solid
        }
    }
}

/// Безрамочное окно не может стать key по умолчанию, а для edit и move это нужно.
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    /// Окно занимает весь экран по высоте, в том числе под строкой меню и Dock: система не должна его сдвигать.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// В режиме move мышь только двигает окно по горизонтали, по вертикали окно закреплено.
    var isMoveMode = false

    override func sendEvent(_ event: NSEvent) {
        guard isMoveMode else { return super.sendEvent(event) }
        switch event.type {
        case .leftMouseDragged:
            let area = (screen ?? NSScreen.main)?.frame ?? frame
            let x = min(max(frame.minX + event.deltaX, area.minX), area.maxX - frame.width)
            setFrameOrigin(NSPoint(x: x, y: frame.minY))
        case .leftMouseDown, .leftMouseUp:
            break
        default:
            super.sendEvent(event)
        }
    }
}

/// Окно на уровне обоев + текущий режим.
@Observable final class DesktopController {
    var mode = Mode.solid { didSet { apply() } }
    let appearance = Appearance()
    /// Переносит фокус ввода на соседний день; выставляет лента.
    @ObservationIgnored var moveFocus: ((Int) -> Void)?

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

    /// Высота и y окна всегда по всему экрану (лента уходит под строку меню и Dock), ширина из настроек,
    /// по горизонтали окно целиком на экране.
    private func fitWindow() {
        guard let window, let screen = (window.screen ?? NSScreen.main)?.frame else { return }
        let width = min(appearance.width, screen.width)
        let x = min(max(window.frame.minX, screen.minX), screen.maxX - width)
        window.setFrame(NSRect(x: x, y: screen.minY, width: width, height: screen.height), display: true)
    }

    func start() {
        let window = DesktopWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // Положение запоминается между запусками, но из него берётся только x (см. fitWindow).
        window.setFrameAutosaveName("d-cal")
        // Размер окна задаётся до того, как появится лента: иначе она прокручивается к сегодняшнему дню
        // в окне нулевого размера и после подгонки оказывается не на месте.
        self.window = window
        fitWindow()
        window.contentView = NSHostingView(rootView: ContentView(desktop: self))
        window.orderFrontRegardless()
        appearance.onWidthChange = { [weak self] in self?.fitWindow() }
        apply()

        // Opt+M: solid → scroll → edit → solid
        hotKey = HotKey(keyCode: kVK_ANSI_M, modifiers: optionKey) { [weak self] in
            self?.mode = self?.mode.next ?? .solid
        }
        // Запоминаем, какое приложение было активным до нас. Нельзя брать его только в момент входа в edit:
        // приложение может быть активным уже в solid (например, сразу после запуска), и тогда запоминать нечего.
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
        // зажатой клавише. Esc → solid; стрелки вверх/вниз и Enter переносят фокус на соседний день.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, mode != .solid else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape: mode = .solid
            case kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_ANSI_KeypadEnter:
                let code = Int(event.keyCode)
                let isReturn = code != kVK_UpArrow && code != kVK_DownArrow
                let editor = self.window?.firstResponder as? NSTextView
                if appearance.allowsMultiline, let editor {
                    // Несколько строк в дне: Shift+Enter добавляет строку, стрелки сначала ходят по строкам дня
                    // и переходят на другой день только с первой (вверх) или последней (вниз) строки.
                    if isReturn, event.modifierFlags.contains(.shift) {
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
            if escapeKey == nil { escapeKey = HotKey(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.mode = .solid } }
        } else {
            escapeKey?.unregister()
            escapeKey = nil
        }
        window?.isMoveMode = mode == .move
        window?.ignoresMouseEvents = mode == .solid
        // solid: под значками рабочего стола. Остальные режимы: чуть выше значков (но всё равно ниже обычных окон),
        // иначе клики перехватывает рабочий стол Finder.
        let key: CGWindowLevelKey = mode == .solid ? .desktopWindow : .desktopIconWindow
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
