import AppKit
import GhosttyKit

/// A single libghostty terminal surface bound to one local child process.
/// Rendering is done by Ghostty's Metal renderer directly into this view's
/// layer. Adapted from Ghostty's own macOS app (MIT licensed), trimmed to
/// Relay's single-surface embedding.
@MainActor
final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {
    private(set) var surface: ghostty_surface_t?

    /// Terminal-reported title (escape sequences).
    /// File drag & drop (upload-to-remote). All optional: without handlers
    /// the view simply refuses drops.
    var onFilesDropped: ((_ urls: [URL], _ preferLocalPaths: Bool) -> Void)?
    var onDragTargeted: ((Bool) -> Void)?
    var canAcceptFileDrop: (() -> Bool)?

    var terminalTitle: String = "" {
        didSet { onTitleChange?(terminalTitle) }
    }

    /// Terminal-reported background color (OSC 11), if any.
    var terminalBackgroundColor: NSColor?

    var onTitleChange: ((String) -> Void)?
    var onProcessExit: (() -> Void)?

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var suppressNextLeftMouseUp = false
    private var focused = false
    /// Warm-pool presentation state; a hidden surface is never focused.
    private var presented = true
    private var processExitReported = false
    private var eventMonitor: Any?
    private var currentCursor: NSCursor = .iBeam

    override var acceptsFirstResponder: Bool { true }

    init?(command: String, environment: [String: String]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        guard let app = GhosttyRuntime.shared.app else { return nil }

        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        config.font_size = 0
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let envPairs = environment.map { (key: $0.key, value: $0.value) }
        let created: ghostty_surface_t? = command.withCString { commandPointer in
            config.command = commandPointer
            return withCStringArray(envPairs) { envVars in
                envVars.withUnsafeMutableBufferPointer { buffer in
                    config.env_vars = buffer.baseAddress
                    config.env_var_count = buffer.count
                    return ghostty_surface_new(app, &config)
                }
            }
        }

        guard let created else { return nil }
        self.surface = created

        updateTrackingAreas()
        registerForDraggedTypes([.fileURL])

        // Command+key keyUp events never reach the responder chain; observe
        // them locally so key release reaches the terminal.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            guard let self else { return event }
            guard event.modifierFlags.contains(.command), self.focused else { return event }
            self.keyUp(with: event)
            return nil
        }

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(windowFocusDidChange(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(
            self, selector: #selector(windowFocusDidChange(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: File drag & drop

    private func fileURLs(from info: NSDraggingInfo) -> [URL]? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        guard let urls, !urls.isEmpty else { return nil }
        return urls
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onFilesDropped != nil,
              canAcceptFileDrop?() ?? false,
              fileURLs(from: sender) != nil
        else { return [] }
        onDragTargeted?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTargeted?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragTargeted?(false)
        guard canAcceptFileDrop?() ?? false,
              let urls = fileURLs(from: sender)
        else { return false }
        // ⌥ at drop time keeps the classic terminal behavior: insert the
        // local path instead of uploading.
        let preferLocal = NSEvent.modifierFlags.contains(.option)
        onFilesDropped?(urls, preferLocal)
        return true
    }

    /// Presentation state for warm-but-hidden surfaces: occluded surfaces
    /// stop rendering, and a hidden surface reports unfocused.
    func setPresented(_ presented: Bool) {
        self.presented = presented
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, presented)
        syncFocus()
    }

    /// Types `text` into the terminal as if entered locally (used to insert
    /// uploaded file paths). Never interpreted as keystrokes or bindings.
    func injectText(_ text: String) {
        guard let surface else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { cPointer in
                ghostty_surface_text(surface, cPointer, UInt(buffer.count))
            }
        }
    }

    /// Frees the surface, terminating the local child process. The remote
    /// session is unaffected (detach-only semantics). Must be called exactly
    /// once before releasing the view; the attachment controller owns this.
    func shutdown() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
        NotificationCenter.default.removeObserver(self)
        onTitleChange = nil
        onProcessExit = nil
    }

    func reportProcessExit() {
        guard !processExitReported else { return }
        processExitReported = true
        onProcessExit?()
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { syncFocus() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        // AppKit sends resign before repointing window.firstResponder, so
        // the derived check would still see this view as focused.
        if result { syncFocus(assumeFirstResponder: false) }
        return result
    }

    @objc private func windowFocusDidChange(_ note: Notification) {
        guard let window, (note.object as? NSWindow) === window else { return }
        syncFocus()
    }

    /// The single writer of ghostty's focus flag, derived from AppKit truth
    /// on every call — never from a cached bool. (Multiple paths used to
    /// write the flag directly while `focused` tracked it separately with a
    /// dedupe guard; once they drifted, becomeFirstResponder became a silent
    /// no-op and a focused, typing terminal kept the hollow cursor.)
    private func syncFocus(assumeFirstResponder: Bool? = nil) {
        guard let surface else { return }
        let isFirstResponder = assumeFirstResponder
            ?? (window?.firstResponder === self)
        let focused = presented
            && isFirstResponder
            && (window?.isKeyWindow ?? false)
        self.focused = focused
        if !focused { suppressNextLeftMouseUp = false }
        ghostty_surface_set_focus(surface, focused)
    }

    // MARK: Geometry

    override func layout() {
        super.layout()
        syncSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        guard let surface else { return }
        let fbFrame = convertToBacking(frame)
        guard frame.size.width > 0, frame.size.height > 0 else { return }
        ghostty_surface_set_content_scale(
            surface,
            fbFrame.size.width / frame.size.width,
            fbFrame.size.height / frame.size.height)
        syncSurfaceSize()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let surface else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ghostty_surface_set_color_scheme(surface, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface else { return }
        if let screen = window?.screen {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            ghostty_surface_set_display_id(surface, displayID)
        }
        viewDidChangeBackingProperties()
        // Mount/unmount is a focus edge too: an unmounted surface is never
        // focused, and a remount re-derives before the responder handoff.
        syncFocus()
    }

    private func syncSurfaceSize() {
        guard let surface else { return }
        let scaled = convertToBacking(frame.size)
        guard scaled.width > 0, scaled.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    // MARK: Tracking & cursor

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: frame,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
    }

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: cursor = .resizeUpDown
        default: cursor = .arrow
        }
        currentCursor = cursor
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        // A click that transfers focus into the terminal should not reach the pty.
        if let window, window.firstResponder !== self {
            window.makeFirstResponder(self)
            if NSApp.isActive && window.isKeyWindow {
                suppressNextLeftMouseUp = true
                return
            }
        }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT,
            GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT,
            GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        if ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT,
            GhosttyInput.ghosttyMods(event.modifierFlags)) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        if ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT,
            GhosttyInput.ghosttyMods(event.modifierFlags)) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS,
            GhosttyInput.mouseButton(fromButtonNumber: event.buttonNumber),
            GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE,
            GhosttyInput.mouseButton(fromButtonNumber: event.buttonNumber),
            GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let position = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(
            surface, position.x, frame.height - position.y,
            GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func mouseEntered(with event: NSEvent) { sendMousePosition(event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        if NSEvent.pressedMouseButtons != 0 { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(
            surface, x, y,
            GhosttyInput.scrollMods(precision: precision, phase: event.momentumPhase))
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard focused else { return false }
        guard let surface else { return false }

        // App menu shortcuts (⌘N, ⌘⇧E, ⌘Q, …) take priority over terminal
        // keybinds: Ghostty's defaults bind things like super+n to window
        // actions this embedding doesn't support, and consuming them here
        // would make the menu unreachable while the terminal is focused.
        if event.modifierFlags.contains(.command),
           let mainMenu = NSApp.mainMenu,
           mainMenu.performKeyEquivalent(with: event) {
            return true
        }

        // If this matches a Ghostty keybind, let the terminal handle it.
        var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        var bindingFlags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { pointer in
            ghosttyEvent.text = pointer
            return ghostty_surface_key_is_binding(surface, ghosttyEvent, &bindingFlags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // Treat C-/ as C-_ (avoids the system beep).
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
            else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            // See Ghostty's SurfaceView: command-modded keys that fall through
            // the responder chain (via doCommand) come back here for encoding.
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        let synthesized = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )
        keyDown(with: synthesized ?? event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Translation modifiers may differ (option-as-alt etc.).
        let translationModsGhostty = GhosttyInput.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(
                surface,
                GhosttyInput.ghosttyMods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0

        lastPerformKeyEvent = nil
        interpretKeyEvents([translationEvent])

        syncPreedit(clearIfNeeded: markedTextBefore)

        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                _ = sendKey(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = sendKey(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: markedText.length > 0 || markedTextBefore)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }

        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = event.modifierFlags.rawValue & GhosttyInput.deviceRightShiftMask != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & GhosttyInput.deviceRightCtrlMask != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & GhosttyInput.deviceRightAltMask != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & GhosttyInput.deviceRightCmdMask != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = sendKey(action, event: event)
    }

    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var keyEvent = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing

        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { pointer in
                keyEvent.text = pointer
                return ghostty_surface_key(surface, keyEvent)
            }
        }
        return ghostty_surface_key(surface, keyEvent)
    }

    // MARK: Clipboard confirmation

    func confirmClipboard(contents: String, isPaste: Bool, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = isPaste ? "Confirm Paste" : "Allow Clipboard Access?"
        alert.informativeText = isPaste
            ? "Pasting this text may execute commands in the terminal.\n\n\(contents.prefix(300))"
            : "The remote terminal wants to access your clipboard."
        alert.alertStyle = .warning
        alert.addButton(withTitle: isPaste ? "Paste" : "Allow")
        alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    // MARK: Menu / standard edit actions

    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown else { return nil }
        let menu = NSMenu()
        if let surface, ghostty_surface_has_selection(surface) {
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    private func performBinding(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    @IBAction func copy(_ sender: Any?) { performBinding("copy_to_clipboard") }
    @IBAction func paste(_ sender: Any?) { performBinding("paste_from_clipboard") }
    @IBAction override func selectAll(_ sender: Any?) { performBinding("select_all") }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String:
            markedText = NSMutableAttributedString(string: plain)
        default:
            break
        }
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { pointer in
                ghostty_surface_preedit(surface, pointer, UInt(str.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let cText = text.text else { return nil }
        return NSAttributedString(string: String(cString: cText))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 8
        var height: Double = 16
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: width, height: height)
        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        guard let surface else { return }

        let chars: String
        switch string {
        case let attributed as NSAttributedString: chars = attributed.string
        case let plain as String: chars = plain
        default: return
        }

        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        chars.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(chars.utf8.count))
        }
    }

    override func doCommand(by selector: Selector) {
        // Re-dispatch command-modded keys that AppKit converted to selectors
        // so they reach keyDown for terminal encoding (e.g. Cmd+Period).
        if let last = lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           last == current.timestamp {
            NSApp.sendEvent(current)
            return
        }
        switch selector {
        case #selector(moveToBeginningOfDocument(_:)):
            performBinding("scroll_to_top")
        case #selector(moveToEndOfDocument(_:)):
            performBinding("scroll_to_bottom")
        case #selector(scrollPageUp(_:)):
            performBinding("scroll_page_up")
        case #selector(scrollPageDown(_:)):
            performBinding("scroll_page_down")
        default:
            // Swallow everything else (prevents the system beep).
            break
        }
    }
}

/// Runs `body` with a C array of ghostty_env_var_s valid for its duration.
private func withCStringArray<T>(
    _ pairs: [(key: String, value: String)],
    _ body: (inout [ghostty_env_var_s]) -> T
) -> T {
    func recurse(
        _ remaining: ArraySlice<(key: String, value: String)>,
        _ collected: inout [ghostty_env_var_s],
        _ body: (inout [ghostty_env_var_s]) -> T
    ) -> T {
        guard let pair = remaining.first else {
            return body(&collected)
        }
        return pair.key.withCString { keyPointer in
            pair.value.withCString { valuePointer in
                collected.append(ghostty_env_var_s(key: keyPointer, value: valuePointer))
                defer { collected.removeLast() }
                return recurse(remaining.dropFirst(), &collected, body)
            }
        }
    }
    var collected: [ghostty_env_var_s] = []
    collected.reserveCapacity(pairs.count)
    return recurse(pairs[...], &collected, body)
}
