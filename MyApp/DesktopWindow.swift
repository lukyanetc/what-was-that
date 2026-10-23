import SwiftUI
import Carbon

/// locked → scroll → edit → locked on Opt+M. move (moving the window) is turned on by a separate menu button.
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

/// A borderless window cannot become key by default, but edit and move need that.
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    /// The window takes the full screen height, including under the menu bar and the Dock: the system must not move it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// In move mode the mouse moves the window: for the feed (full-height window) only horizontally,
    /// for month and week (window sized to content) anywhere on the screen.
    var isMoveMode = false
    var canMoveVertically = false
    /// Called after every move step.
    var onMoved: (() -> Void)?
    /// Vertical mouse shift when the window itself does not move vertically ("Period" mode): moves the period within the window.
    var onVerticalDrag: ((Double) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        guard isMoveMode else { return super.sendEvent(event) }
        switch event.type {
        case .leftMouseDragged:
            let area = (screen ?? NSScreen.main)?.frame ?? frame
            let x = min(max(frame.minX + event.deltaX, area.minX), area.maxX - frame.width)
            // deltaY is positive when the mouse moves down, while the window's y axis points up.
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

/// A window at wallpaper level + the current mode.
@Observable final class DesktopController {
    var mode = Mode.locked {
        didSet {
            if oldValue == .move { savePeriodTop() }
            apply()
            if oldValue == .edit { fitWindow() }
        }
    }
    let appearance = Appearance()
    /// System calendar events (read-only).
    let events = CalendarEvents()
    /// Update check via GitHub Releases.
    let updates = UpdateChecker()
    /// The period the window shows now: "Period" mode, while the period is running, and only in locked and move.
    /// The other days are transparent; in scroll and edit they fade in, the window and the feed do not change.
    /// A period that does not fit in the window is not shown separately: then "Period" mode shows the feed.
    var shownPeriod: Period? {
        guard appearance.viewKind == .period, mode == .locked || mode == .move, periodFits else { return nil }
        return appearance.activePeriod
    }
    /// Height of the period in the feed; measured by the static period layer even when it is invisible.
    var periodContentHeight = 0.0
    var periodFits: Bool { periodContentHeight <= appearance.periodRoom(screenHeight: screenFrame.height) }
    /// Window sized to content (month, week), not full screen. The period, like the feed, is full screen.
    var isCompact: Bool { appearance.viewKind.isPaged }
    /// Height of the fade at the top and bottom edge. The setting applies only in the full-screen window (Feed, Range).
    /// In month and week the window is sized to content: the fade there is constant, otherwise the setting would move the window and the text.
    var edgeFade: Double { isCompact ? Self.compactEdgeFade : appearance.edgeFade }
    private static let compactEdgeFade = 24.0
    /// Offset of the period's first day from the top of the window (stored in the appearance settings).
    var periodOffset: Double {
        get { appearance.periodOffset }
        set { appearance.periodOffset = newValue }
    }
    /// Moves input focus to the neighboring day; set by the feed.
    @ObservationIgnored var moveFocus: ((Int) -> Void)?
    /// Pages month or week to the neighboring span (+1 forward, -1 back); set by the feed.
    @ObservationIgnored var shiftPeriod: ((Int) -> Void)?
    /// Writes unsaved text to the file (on app quit); set by the feed.
    @ObservationIgnored var flushPending: (() -> Void)?
    /// Wheel and gestures in scroll: accumulated scroll of the current gesture and a flag that it has already turned a span.
    @ObservationIgnored private var scrollAccum = 0.0
    @ObservationIgnored private var scrollLocked = false
    @ObservationIgnored private var lastWheelShift = Date.distantPast

    @ObservationIgnored private var window: DesktopWindow?
    @ObservationIgnored private var hotKey: HotKey?
    /// Esc as a global hotkey while scroll is on: in scroll the app is not active (focus is in another app),
    /// and ordinary key presses do not reach us.
    @ObservationIgnored private var escapeKey: HotKey?
    /// The last active app other than ours: focus is returned to it on leaving edit/move.
    @ObservationIgnored private var lastExternalApp: NSRunningApplication?
    /// Moment of the user's last input in the window (key or mouse), see deselection on focus.
    @ObservationIgnored private var lastUserInput = Date.distantPast
    /// Cursor position within the line at the moment of moving to another day (up/down arrow or Enter).
    @ObservationIgnored private var lastMove: (column: Int, time: Date, step: Int)?

    /// Height of the month or week content; measured by the feed. The window is fitted to it in these modes.
    /// Fractional fluctuations (under a point) are ignored so the window does not jitter. In edit the window only grows (when
    /// an entry wraps to a new line) but does not shrink: frequent window resizing broke focus and caused
    /// flicker. After leaving edit the window is fitted to the current height.
    @ObservationIgnored var periodHeight = 0.0 {
        didSet {
            guard abs(periodHeight - oldValue) >= 1, mode != .edit || periodHeight > oldValue else { return }
            fitWindow()
        }
    }
    /// Top edge of the month or week window (the user moves it in move); nil means under the menu bar.
    @ObservationIgnored private var periodTop = UserDefaults.standard.object(forKey: "periodTop") as? Double

    /// Remembers the top edge of the month or week window: when the number of rows changes (28–31 days) the window grows downward
    /// instead of jumping, and the position is kept between launches.
    private func savePeriodTop() {
        // The window is sized to content now if it was at the last fit (canMoveVertically).
        guard let window, window.canMoveVertically, periodHeight > 0 else { return }
        periodTop = window.frame.maxY
        UserDefaults.standard.set(window.frame.maxY, forKey: "periodTop")
    }

    /// Feed: window height and y over the whole screen (the feed goes under the menu bar and the Dock). Month and week: window sized to
    /// content, top edge in place until the user moves it. Width from settings, the window entirely on screen.
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

    /// Global hotkey that switches modes (Opt+M by default); the combination is set in settings.
    func registerHotKey() {
        hotKey?.unregister()
        hotKey = HotKey(keyCode: appearance.hotKeyCode, modifiers: appearance.hotKeyModifiers) { [weak self] in
            self?.mode = self?.mode.next ?? .locked
        }
    }

    /// While a new combination is being recorded the hotkey is removed, otherwise the system would catch the key press before the settings window.
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
        // The data file was renamed along with the app: the previous one (d-cal.json) is copied under the new name.
        DayStore.migrateLegacyFile(in: DayStore.defaultURL.deletingLastPathComponent())
        let window = DesktopWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // The position is remembered between launches, but only x is taken from it (see fitWindow).
        let hasSavedFrame = UserDefaults.standard.object(forKey: "NSWindow Frame d-cal") != nil
        window.setFrameAutosaveName("d-cal")
        // First launch (no position yet): the window's left edge at a third of the screen width. After that the remembered
        // position works (the user moves it in move mode).
        if !hasSavedFrame, let screen = NSScreen.main?.frame {
            window.setFrameOrigin(NSPoint(x: screen.minX + screen.width / 3, y: screen.minY))
        }
        // The window size is set before the feed appears: otherwise it scrolls to today
        // in a zero-sized window and ends up in the wrong place after fitting.
        self.window = window
        fitWindow()
        window.contentView = NSHostingView(rootView: ContentView(desktop: self))
        window.orderFrontRegardless()
        appearance.onLayoutChange = { [weak self] in self?.fitWindow() }
        window.onMoved = { [weak self] in self?.savePeriodTop() }
        window.onVerticalDrag = { [weak self] delta in
            guard let self, appearance.viewKind == .period else { return }
            // The period does not go above the top of the screen and leaves room for at least one row at the bottom.
            periodOffset = min(max(periodOffset + delta, appearance.edgeFade), max(screenFrame.height - 100, 0))
        }
        apply()
        events.refreshAuthorization()
        enableLoginItemOnFirstLaunch()
        if appearance.checksUpdatesAtLaunch { Task { await updates.checkAtLaunch() } }

        // Opt+M: locked → scroll → edit → locked
        registerHotKey()
        appearance.onHotKeyChange = { [weak self] in self?.registerHotKey() }
        // Remember which app was active before us. It cannot be taken only at the moment of entering edit:
        // the app may already be active in locked (for example, right after launch), and then there is nothing to remember.
        let current = NSRunningApplication.current
        if let front = NSWorkspace.shared.frontmostApplication, !front.isEqual(current) { lastExternalApp = front }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !app.isEqual(NSRunningApplication.current) else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }
        // Each Space has its own wallpaper: measure again on switching.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWallpaper() }
        }
        // Window keys (work when the window has focus, that is in edit and move). The monitor also gets repeats while
        // a key is held. Esc → locked; up/down arrows and Enter move focus to the neighboring day.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Keys are handled only in the desktop window: in the settings window Esc, arrows and Enter stay with it.
            guard let self, event.window === window, mode != .locked else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape: mode = .locked
            case kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_ANSI_KeypadEnter:
                let code = Int(event.keyCode)
                let isReturn = code != kVK_UpArrow && code != kVK_DownArrow
                let editor = self.window?.firstResponder as? NSTextView
                if let editor {
                    // Several lines in a day: Shift+Enter, Cmd+Enter or Opt+Enter add a line; arrows first
                    // walk through the day's lines and move to another day only from the first (up) or last (down) line.
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
                // Moving to another day: the previous key (for example, the left arrow) must not count as
                // input, otherwise the new field's selection will not be cleared. The cursor position within the line is carried
                // to the new field, as in ordinary editors.
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
        // Month and week in scroll and edit: one gesture (or wheel click) turns one span.
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Only the wheel over the desktop window: over the settings window and other app windows paging is not allowed.
            guard let self, event.window === window, mode == .scroll || mode == .edit,
                  appearance.viewKind.isPaged else { return event }
            // Scrolling down (content moves up) is the next span; the direction already accounts for natural scrolling.
            let step = event.scrollingDeltaY < 0 ? 1 : -1
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                scrollAccum = 0
                scrollLocked = false
            }
            if event.phase.isEmpty && event.momentumPhase.isEmpty {
                // Mouse wheel: clicks arrive without phases, consecutive repeats are smoothed with a pause.
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
        // A field that receives focus selects all its text. A whole-line selection that did not come from the user
        // (not from a key or the mouse) is collapsed right in the notification, before drawing: so there is no flicker.
        NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.mode == .edit, let editor = note.object as? NSTextView,
                      editor.isFieldEditor, editor.window === self.window else { return }
                // The selection is translucent in the text color: the letters are drawn by the layer under the field, and the ordinary opaque selection
                // covered them, so the selected text was not visible.
                editor.selectedTextAttributes = [.backgroundColor: NSColor(self.appearance.textColor).withAlphaComponent(0.3)]
                let range = editor.selectedRange()
                guard range.length > 0, range.length == editor.string.utf16.count,
                      Date.now.timeIntervalSince(self.lastUserInput) > 0.3 else { return }
                // After moving between days the cursor lands at the same position in the line, otherwise at the end.
                // Going up we land on the day's last line, going down on the first.
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

    /// The caret in the input field is not drawn until the window is key. While the window is not yet key, ask the system to make it key.
    /// If that fails several attempts in a row, reopen the window (NSApp.keyWindow may have stayed pointing
    /// at another window, and then makeKey does nothing); this causes noticeable flicker, so it is only a last resort.
    /// When the window is key, restart the caret in the field editor. Returns true when everything is ready.
    func refreshCaret(attempt: Int) -> Bool {
        if let window, !window.isKeyWindow {
            if attempt >= 5 { window.orderOut(nil) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        guard let window, window.isKeyWindow, let editor = window.firstResponder as? NSTextView else { return false }
        collapseSelection()
        // The field text is transparent (the letters are drawn by Text over it) and the caret takes the text color by default: set it explicitly.
        editor.insertionPointColor = NSColor(appearance.textColor)
        editor.selectedTextAttributes = [.backgroundColor: NSColor(appearance.textColor).withAlphaComponent(0.3)]
        editor.updateInsertionPointStateAndRestartTimer(true)
        editor.needsDisplay = true
        return true
    }

    /// The next whole-line selection on gaining focus will be collapsed immediately, without flicker: a click after which
    /// the field gains focus (for example, choosing a color) must not count as the user's input in that field.
    func expectProgrammaticFocus() {
        lastUserInput = .distantPast
        lastMove = nil
    }

    /// A field selects all its text on gaining focus; leave only the caret at the end of the line.
    func collapseSelection() {
        guard let editor = window?.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    }

    /// Wallpaper brightness is recomputed on every mode change: this accounts for window moves and wallpaper changes.
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
        // locked: under the desktop icons. Other modes: slightly above the icons (but still below ordinary windows),
        // otherwise the Finder desktop catches the clicks.
        let key: CGWindowLevelKey = mode == .locked ? .desktopWindow : .desktopIconWindow
        window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(key)) + 1)
        if mode == .edit || mode == .move {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        } else if NSApp.isActive {
            // NSApp.deactivate() is unreliable: the app stays active while the window loses key (that is what diagnostics showed
            // after Esc, and the window then could not become key again). Focus is returned to the previous app explicitly.
            if lastExternalApp?.activate(from: NSRunningApplication.current, options: []) != true { NSApp.deactivate() }
        }
    }
}
