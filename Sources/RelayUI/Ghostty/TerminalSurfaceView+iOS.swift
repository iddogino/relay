#if os(iOS)
import GameController
import GhosttyKit
import RelayGhosttyIO
import UIKit
import UniformTypeIdentifiers

/// A libghostty terminal surface on iOS and iPadOS, in manual I/O mode
/// (see `ManualTerminalIO`): libghostty's Metal renderer draws into a layer
/// it adds to this view's, the program's output comes in through the I/O,
/// and input goes out as libghostty key and mouse events.
///
/// Input: the software keyboard (`UITextInput`, for its trackpad and
/// composition — see TerminalSurfaceView+TextInput.swift) plus
/// `TerminalKeyBar` above it; hardware keyboards key by key
/// (`pressesBegan`), with ⌘ shortcuts left to the app's menus. Touch:
/// drag to scroll the scrollback (with momentum), long-press and drag to
/// select, pinch to change the text size; a pointer clicks, drags and
/// scrolls like a mouse.
@MainActor
final class TerminalSurfaceView: UIView, UIKeyInput {
    private(set) var surface: ghostty_surface_t?

    /// File drops (upload to the session's host). Not offered on iOS yet;
    /// kept so the attachment controller is the same on both platforms.
    var onFilesDropped: ((_ urls: [URL], _ preferLocalPaths: Bool) -> Void)?
    var onDragTargeted: ((Bool) -> Void)?
    var canAcceptFileDrop: (() -> Bool)?

    /// Terminal-reported title (escape sequences).
    var terminalTitle: String = "" {
        didSet { onTitleChange?(terminalTitle) }
    }

    /// Terminal-reported background color (OSC 11), if any.
    var terminalBackgroundColor: UIColor?

    var onTitleChange: ((String) -> Void)?
    var onProcessExit: (() -> Void)?

    /// Warm-pool presentation state; a hidden surface is never focused.
    private var presented = true
    private var processExitReported = false
    /// Set in manual I/O mode; the surface is then freed through it.
    private var manualIO: ManualTerminalIO?
    /// The layer libghostty renders into: a sublayer of this view's, which
    /// must be kept at the view's size (libghostty drops frames otherwise).
    private var renderLayer: CALayer?

    private lazy var keyBar = TerminalKeyBar(terminal: self)
    private var stickyModifiers: [StickyModifier: StickyModifier.State] = [:]

    /// `UITextInput`'s state (TerminalSurfaceView+TextInput.swift).
    var textInput = TextInputState()
    weak var inputDelegate: (any UITextInputDelegate)?
    var markedTextStyle: [NSAttributedString.Key: Any]?
    lazy var tokenizer: any UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    /// Hardware keys held down, by HID usage, for their release events and
    /// key repeat (UIKit doesn't repeat keys it hands over as presses).
    private var heldKeys: [UIKeyboardHIDUsage: ghostty_input_key_s] = [:]
    private var heldKeyText: [UIKeyboardHIDUsage: String] = [:]
    private var keyRepeatTimer: Timer?

    private var lastPanTranslation: CGPoint = .zero
    private var momentum: CADisplayLink?
    private var momentumVelocity: CGFloat = 0
    private var momentumStarted = false
    private var pinchStartSize: Double = TerminalFontSize.current
    private var fontSize: Double = TerminalFontSize.current
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    /// The navigation controller whose swipe-back gestures this terminal
    /// holds off (see `holdOffSwipeBack`).
    private weak var heldNavigation: UINavigationController?

    var isManualIO: Bool { manualIO != nil }
    var isPresented: Bool { presented }

    /// A surface in manual I/O mode: no local process; `io` carries the
    /// program's output in and the terminal's input and size out.
    convenience init?(manualIO io: ManualTerminalIO) {
        self.init { app, config in
            io.configure(&config)
            let surface = ghostty_surface_new(app, &config)
            io.attach(surface)
            return surface
        }
        manualIO = io
    }

    private init?(create: (ghostty_app_t, inout ghostty_surface_config_s) -> ghostty_surface_t?) {
        // Non-zero, so the renderer has something to size until layout.
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        guard let app = GhosttyRuntime.shared.app else { return nil }

        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(self).toOpaque()))
        config.scale_factor = Double(Self.screenScale(traitCollection))
        config.font_size = Float(fontSize)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        guard let created = create(app, &config) else { return nil }
        surface = created
        renderLayer = layer.sublayers?.last
        TerminalSnapshots.register(self)

        isMultipleTouchEnabled = true
        // The key bar is the shortcuts row here; iPad's own (undo, redo,
        // paste) would sit beside it.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.plainText.identifier, UTType.utf8PlainText.identifier, UTType.text.identifier,
            UTType.url.identifier,
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
        accessibilityIdentifier = "terminal"
        accessibilityTraits = [.allowsDirectInteraction, .updatesFrequently]
        addInteraction(editMenu)
        installGestures()
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontSizeChanged), name: TerminalFontSize.changed, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TerminalSurfaceView, _) in
            view.syncColorScheme()
        }
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: TerminalSurfaceView, _) in
            view.syncScale()
            view.syncSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Whether a hardware keyboard is attached: the terminal then takes
    /// keys as soon as it's shown (no software keyboard covers it).
    static var hardwareKeyboardConnected: Bool { GCKeyboard.coalesced != nil }

    // MARK: Lifecycle

    /// Presentation state for warm-but-hidden surfaces: occluded surfaces
    /// stop rendering, and a hidden surface reports unfocused.
    func setPresented(_ presented: Bool) {
        self.presented = presented
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, presented)
        syncFocus()
    }

    /// Types `text` into the terminal as a paste (bracketed when the
    /// program asks for that) — never as keystrokes or bindings.
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

    /// Frees the surface. The remote session is unaffected (detach-only
    /// semantics). In manual I/O mode the free happens a moment later, once
    /// no output is being fed (see `ManualTerminalIO.teardown`); the view
    /// is kept alive until then.
    func shutdown() {
        stopKeyRepeat()
        stopMomentum()
        heldKeys = [:]
        guard let surface else { return }
        self.surface = nil
        TerminalSnapshots.unregister(self)
        if let manualIO {
            let keepAlive = Unmanaged.passRetained(self)
            manualIO.teardown(free: { ghostty_surface_free($0) }, completion: { keepAlive.release() })
        } else {
            ghostty_surface_free(surface)
        }
        NotificationCenter.default.removeObserver(self, name: TerminalFontSize.changed, object: nil)
        onTitleChange = nil
        onProcessExit = nil
    }

    func reportProcessExit() {
        guard !processExitReported else { return }
        processExitReported = true
        onProcessExit?()
    }

    func ringBell() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Pointer shapes don't apply to touch; iPad's pointer keeps its own.
    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {}

    // MARK: Geometry

    private static func screenScale(_ traits: UITraitCollection) -> CGFloat {
        traits.displayScale > 0 ? traits.displayScale : 3
    }

    var scale: CGFloat { Self.screenScale(traitCollection) }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderLayer?.frame = bounds
        CATransaction.commit()
        syncSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncScale()
        syncSize()
        syncColorScheme()
        // Mount/unmount is a focus edge too: an unmounted surface is never
        // focused.
        syncFocus()
        if window == nil { stopMomentum() }
        holdOffSwipeBack(window != nil)
    }

    /// Horizontal drags on a terminal select text, so the swipe from
    /// anywhere that goes back (iOS 26) is off while one is on screen. The
    /// swipe from the screen's edge stays: a touch that starts there (the
    /// first column or so) is the system's.
    private func holdOffSwipeBack(_ hold: Bool) {
        if #available(iOS 26, *) {
            if hold, let navigation = enclosingNavigationController {
                heldNavigation = navigation
                navigation.interactiveContentPopGestureRecognizer?.isEnabled = false
            } else if !hold, let navigation = heldNavigation {
                navigation.interactiveContentPopGestureRecognizer?.isEnabled = true
                heldNavigation = nil
            }
        }
    }

    private var enclosingNavigationController: UINavigationController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller as? UINavigationController ?? controller.navigationController
            }
            responder = current.next
        }
        return nil
    }

    private func syncScale() {
        guard let surface else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    private func syncSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        ghostty_surface_set_size(
            surface, UInt32((bounds.width * scale).rounded(.down)), UInt32((bounds.height * scale).rounded(.down)))
    }

    private func syncColorScheme() {
        guard let surface else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        GhosttyRuntime.shared.setColorScheme(dark: dark)
    }

    // MARK: Focus

    override var canBecomeFirstResponder: Bool { surface != nil }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { syncFocus(firstResponder: true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            syncFocus(firstResponder: false)
            releaseHeldKeys()
        }
        return resigned
    }

    /// The single writer of libghostty's focus flag (a focused terminal
    /// draws a solid cursor), derived from UIKit's state on every call.
    private func syncFocus(firstResponder: Bool? = nil) {
        guard let surface else { return }
        let focused = presented && window != nil && (firstResponder ?? isFirstResponder)
        ghostty_surface_set_focus(surface, focused)
    }

    override var inputAccessoryView: UIView? { keyBar }

    // MARK: UIKeyInput (the software keyboard)

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var writingToolsBehavior: UIWritingToolsBehavior = .none
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    func insertText(_ text: String) {
        // In place of any composition (the text it was composed into).
        endComposition()
        // A hardware keyboard's Return (and other keys UIKit doesn't hand
        // over as presses) come as text too.
        for character in text {
            switch character {
            case "\n", "\r": pressNamed(.enter, mods: takeStickyMods())
            case "\t": pressNamed(.tab, mods: takeStickyMods())
            case "\u{1B}": pressNamed(.escape, mods: takeStickyMods())
            case "\u{7F}", "\u{8}": pressNamed(.backspace, mods: takeStickyMods())
            default: type(character, extraMods: takeStickyMods())
            }
        }
    }

    func deleteBackward() {
        pressNamed(.backspace, mods: takeStickyMods())
    }

    // MARK: The key bar

    func pressKeyBarKey(_ key: TerminalKey.Named) {
        pressNamed(key, mods: takeStickyMods())
    }

    func typeKeyBarText(_ text: String) {
        for character in text { type(character, extraMods: takeStickyMods()) }
    }

    func toggleStickyModifier(_ modifier: StickyModifier) {
        stickyModifiers[modifier] = (stickyModifiers[modifier] ?? .off) == .off ? .once : .off
        keyBar.showModifiers(stickyModifiers)
    }

    func lockStickyModifier(_ modifier: StickyModifier) {
        stickyModifiers[modifier] = .locked
        keyBar.showModifiers(stickyModifiers)
    }

    /// The key bar's modifiers for the key being sent; one-shot ones are
    /// used up.
    private func takeStickyMods() -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if (stickyModifiers[.control] ?? .off) != .off { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if (stickyModifiers[.alternate] ?? .off) != .off { raw |= GHOSTTY_MODS_ALT.rawValue }
        if stickyModifiers.values.contains(.once) {
            stickyModifiers = stickyModifiers.filter { $0.value == .locked }
            keyBar.showModifiers(stickyModifiers)
        }
        return ghostty_input_mods_e(rawValue: raw)
    }

    // MARK: Key events

    func pressNamed(_ key: TerminalKey.Named, mods: ghostty_input_mods_e) {
        sendKey(keycode: key.keycode, mods: mods, consumed: GHOSTTY_MODS_NONE, text: nil, unshifted: nil)
    }

    /// One character as the US-layout key that types it (Control and Alt
    /// apply to the key, as on a hardware keyboard); anything no key
    /// types goes as text.
    private func type(_ character: Character, extraMods: ghostty_input_mods_e) {
        guard let (keycode, base, shifted) = TerminalKey.lookup(character) else {
            sendKey(keycode: TerminalKey.unidentified, mods: extraMods, consumed: GHOSTTY_MODS_NONE,
                    text: String(character), unshifted: nil)
            return
        }
        let shift = shifted ? GHOSTTY_MODS_SHIFT.rawValue : 0
        sendKey(keycode: keycode,
                mods: ghostty_input_mods_e(rawValue: extraMods.rawValue | shift),
                consumed: ghostty_input_mods_e(rawValue: shift),
                text: String(character), unshifted: base)
    }

    /// A press and its release.
    private func sendKey(
        keycode: UInt32,
        mods: ghostty_input_mods_e,
        consumed: ghostty_input_mods_e,
        text: String?,
        unshifted: Character?
    ) {
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.mods = mods
        event.consumed_mods = consumed
        event.keycode = keycode
        event.unshifted_codepoint = unshifted?.unicodeScalars.first?.value ?? 0
        event.composing = false
        send(event, text: text)
        event.action = GHOSTTY_ACTION_RELEASE
        send(event, text: nil)
    }

    private func send(_ event: ghostty_input_key_s, text: String?) {
        guard let surface else { return }
        var event = event
        if let text, !text.isEmpty {
            text.withCString { pointer in
                event.text = pointer
                _ = ghostty_surface_key(surface, event)
            }
        } else {
            event.text = nil
            _ = ghostty_surface_key(surface, event)
        }
    }

    // MARK: Hardware keyboards

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, pressHardwareKey(key) else {
                unhandled.insert(press)
                continue
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseHardwareKeys(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseHardwareKeys(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    /// Sends a hardware key's press, unless it's for the system or the
    /// app's menus (⌘ shortcuts, modifiers on their own, keys libghostty
    /// has no code for). Returns whether the terminal took it.
    private func pressHardwareKey(_ key: UIKey) -> Bool {
        guard surface != nil, !key.modifierFlags.contains(.command),
              !TerminalKey.isModifier(key.keyCode),
              let keycode = TerminalKey.keycode(hid: key.keyCode) else { return false }
        let sticky = takeStickyMods()
        var flags = key.modifierFlags
        if sticky.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if sticky.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.alternate) }

        // The text the key types. With Control, the key's own character
        // (libghostty encodes the control code). Option is Alt (Meta), as
        // terminals want it — not the character macOS-style Option types.
        var text = TerminalKey.typesText(key.keyCode) ? key.characters : ""
        if !text.isEmpty, flags.contains(.control) || flags.contains(.alternate) {
            text = key.charactersIgnoringModifiers
            if flags.contains(.shift), text.count == 1, let upper = text.uppercased().first,
               text != String(upper) {
                text = String(upper)
            }
        }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) || $0.value == 0x7F }) {
            text = ""
        }
        let base = TerminalKey.typesText(key.keyCode)
            ? key.charactersIgnoringModifiers.first.map { TerminalKey.lookup($0)?.base ?? Character($0.lowercased()) }
            : nil

        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.mods = TerminalKey.mods(flags)
        // Shift went into the text; Control and Alt are libghostty's to encode.
        event.consumed_mods = flags.contains(.shift) && !text.isEmpty ? GHOSTTY_MODS_SHIFT : GHOSTTY_MODS_NONE
        event.keycode = keycode
        event.unshifted_codepoint = base?.unicodeScalars.first?.value ?? 0
        event.composing = false
        send(event, text: text)

        heldKeys[key.keyCode] = event
        heldKeyText[key.keyCode] = text
        startKeyRepeat(key.keyCode)
        return true
    }

    /// Sends the releases of the presses the terminal took; returns the
    /// rest.
    private func releaseHardwareKeys(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, var event = heldKeys.removeValue(forKey: key.keyCode) else {
                unhandled.insert(press)
                continue
            }
            heldKeyText[key.keyCode] = nil
            event.action = GHOSTTY_ACTION_RELEASE
            send(event, text: nil)
            if repeatingKey == key.keyCode { stopKeyRepeat() }
        }
        return unhandled
    }

    /// Releases every held key (focus moved away mid-press).
    private func releaseHeldKeys() {
        for (usage, var event) in heldKeys {
            event.action = GHOSTTY_ACTION_RELEASE
            send(event, text: nil)
            heldKeyText[usage] = nil
        }
        heldKeys = [:]
        stopKeyRepeat()
    }

    private var repeatingKey: UIKeyboardHIDUsage?

    /// Repeats the most recent key while it's held, at about the system's
    /// default rate.
    private func startKeyRepeat(_ usage: UIKeyboardHIDUsage) {
        stopKeyRepeat()
        repeatingKey = usage
        keyRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.repeatingKey == usage else { return }
                self.keyRepeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, var event = self.heldKeys[usage] else {
                            self?.stopKeyRepeat()
                            return
                        }
                        event.action = GHOSTTY_ACTION_REPEAT
                        self.send(event, text: self.heldKeyText[usage])
                    }
                }
            }
        }
    }

    private func stopKeyRepeat() {
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
        repeatingKey = nil
    }

    // MARK: ⌘ shortcuts

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(title: "Bigger Text", action: #selector(increaseTextSize), input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Bigger Text", action: #selector(increaseTextSize), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Smaller Text", action: #selector(decreaseTextSize), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Actual Size", action: #selector(resetTextSize), input: "0", modifierFlags: .command),
        ]
        // Return and Escape: key commands, because the views around the
        // terminal have key commands for them (open the selected row, go
        // back), and key commands are matched before presses are
        // delivered — the first responder's first.
        for input in ["\r", UIKeyCommand.inputEscape] {
            for flags in Self.terminalKeyModifiers {
                commands.append(UIKeyCommand(input: input, modifierFlags: flags, action: #selector(terminalKeyCommand(_:))))
            }
        }
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    /// Every combination of Shift, Control and Option (⌘ stays the app's).
    private static let terminalKeyModifiers: [UIKeyModifierFlags] = {
        let mods: [UIKeyModifierFlags] = [.shift, .control, .alternate]
        return (0..<(1 << mods.count)).map { bits in
            mods.indices.reduce(into: UIKeyModifierFlags()) { flags, index in
                if bits & (1 << index) != 0 { flags.insert(mods[index]) }
            }
        }
    }()

    @objc private func terminalKeyCommand(_ command: UIKeyCommand) {
        let key: TerminalKey.Named = command.input == UIKeyCommand.inputEscape ? .escape : .enter
        let mods = TerminalKey.mods(command.modifierFlags).rawValue | takeStickyMods().rawValue
        pressNamed(key, mods: ghostty_input_mods_e(rawValue: mods))
    }

    @objc private func increaseTextSize() { setFontSize(fontSize + 1, persist: true) }
    @objc private func decreaseTextSize() { setFontSize(fontSize - 1, persist: true) }
    @objc private func resetTextSize() { setFontSize(TerminalFontSize.defaultSize, persist: true) }

    @objc private func fontSizeChanged() {
        setFontSize(TerminalFontSize.current, persist: false)
    }

    /// Sets this terminal's text size (and, when `persist`, the size new
    /// terminals start at — and every open one follows).
    func setFontSize(_ size: Double, persist: Bool) {
        let clamped = TerminalFontSize.clamp(size)
        if clamped != fontSize {
            fontSize = clamped
            performBinding("set_font_size:\(clamped)")
        }
        if persist, clamped != TerminalFontSize.current { TerminalFontSize.current = clamped }
    }

    // MARK: Edit actions

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return surface.map { ghostty_surface_has_selection($0) } ?? false
        case #selector(paste(_:)):
            return surface != nil && UIPasteboard.general.hasStrings
        case #selector(selectAll(_:)):
            return surface != nil
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_ sender: Any?) {
        performBinding("copy_to_clipboard")
    }

    override func paste(_ sender: Any?) {
        // A paste the user asked for (menu, ⌘V): reading is allowed.
        if let text = UIPasteboard.general.string { injectText(text) }
    }

    override func selectAll(_ sender: Any?) {
        performBinding("select_all")
    }

    /// The key bar's paste button (`UIPasteControl`).
    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return }
        _ = provider.loadObject(ofClass: String.self) { [weak self] string, _ in
            guard let string else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.injectText(string) }
            }
        }
    }

    private func performBinding(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: Clipboard confirmation

    func confirmClipboard(contents: String, isPaste: Bool, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: isPaste ? "Confirm Paste" : "Allow Clipboard Access?",
            message: isPaste
                ? "Pasting this text may run commands in the terminal.\n\n\(contents.prefix(300))"
                : "The remote terminal wants to use your clipboard.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: isPaste ? "Paste" : "Allow", style: .default) { _ in completion(true) })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        guard let presenter = window?.rootViewController.map(Self.topmost) else {
            completion(false)
            return
        }
        presenter.present(alert, animated: true)
    }

    private static func topmost(_ controller: UIViewController) -> UIViewController {
        var top = controller
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    // MARK: Touch

    private func installGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = direct
        addGestureRecognizer(tap)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.35
        press.allowedTouchTypes = direct
        addGestureRecognizer(press)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = direct
        // Trackpad and mouse-wheel scrolling too.
        pan.allowedScrollTypesMask = .all
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = direct
        addGestureRecognizer(pinch)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    /// Tap: focus (bringing up the keyboard); once focused, a click — which
    /// clears a selection, and reaches programs that take the mouse.
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let surface else { return }
        stopMomentum()
        guard isFirstResponder else {
            _ = becomeFirstResponder()
            return
        }
        let point = gesture.location(in: self)
        ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
    }

    /// Long press, then drag: selects (a mouse drag); lifting shows the
    /// edit menu (Copy, Paste, Select All).
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let surface else { return }
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            stopMomentum()
            UISelectionFeedbackGenerator().selectionChanged()
            ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        case .changed:
            ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
        case .ended:
            ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        case .cancelled, .failed:
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        default:
            break
        }
    }

    /// Drag (or trackpad scroll): scrolls the scrollback, or reaches the
    /// program as the wheel when it takes the mouse. Momentum after a flick.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let surface else { return }
        switch gesture.state {
        case .began:
            stopMomentum()
            lastPanTranslation = .zero
            let point = gesture.location(in: self)
            ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
        case .changed:
            let translation = gesture.translation(in: self)
            let delta = translation.y - lastPanTranslation.y
            lastPanTranslation = translation
            scroll(by: delta, momentumPhase: 0)
        case .ended:
            startMomentum(velocity: gesture.velocity(in: self).y)
        default:
            break
        }
    }

    /// Momentum phases as libghostty's scroll mods carry them.
    private enum MomentumPhase {
        static let began: Int32 = 1
        static let changed: Int32 = 3
        static let ended: Int32 = 4
    }

    /// Scrolls by `points` (positive: back into the scrollback, as the
    /// content follows the finger down).
    private func scroll(by points: CGFloat, momentumPhase: Int32) {
        guard let surface, points != 0 || momentumPhase != 0 else { return }
        // Precise deltas are in pixels; bit 0 marks them precise.
        let mods = ghostty_input_scroll_mods_t(1 | (momentumPhase << 1))
        ghostty_surface_mouse_scroll(surface, 0, Double(points * scale), mods)
    }

    private func startMomentum(velocity: CGFloat) {
        stopMomentum()
        guard abs(velocity) > 80 else { return }
        momentumVelocity = velocity
        momentumStarted = false
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let elapsed = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        // UIScrollView's normal deceleration: 0.998 per millisecond.
        momentumVelocity *= pow(0.998, CGFloat(elapsed * 1000))
        guard abs(momentumVelocity) > 25 else {
            stopMomentum()
            return
        }
        scroll(by: momentumVelocity * CGFloat(elapsed),
               momentumPhase: momentumStarted ? MomentumPhase.changed : MomentumPhase.began)
        momentumStarted = true
    }

    private func stopMomentum() {
        guard let momentum else { return }
        momentum.invalidate()
        self.momentum = nil
        if momentumStarted { scroll(by: 0, momentumPhase: MomentumPhase.ended) }
        momentumStarted = false
    }

    /// Pinch: the text size, kept for new terminals when the pinch ends.
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopMomentum()
            pinchStartSize = fontSize
        case .changed:
            // Half-point steps: smooth enough, without a relayout per frame.
            setFontSize((pinchStartSize * Double(gesture.scale) * 2).rounded() / 2, persist: false)
        case .ended:
            setFontSize(fontSize, persist: true)
        default:
            break
        }
    }

    /// A pointer over the terminal moves libghostty's mouse.
    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard let surface else { return }
        switch gesture.state {
        case .began, .changed:
            let point = gesture.location(in: self)
            ghostty_surface_mouse_pos(surface, point.x, point.y, TerminalKey.mods(gesture.modifierFlags))
        case .ended, .cancelled:
            ghostty_surface_mouse_pos(surface, -1, -1, GHOSTTY_MODS_NONE)
        default:
            break
        }
    }

    // A pointer's buttons, as mouse buttons (touches are gestures above).

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        stopMomentum()
        guard let surface, let touch = touches.first(where: { $0.type == .indirectPointer }) else { return }
        if !isFirstResponder { _ = becomeFirstResponder() }
        let point = touch.location(in: self)
        let mods = TerminalKey.mods(event?.modifierFlags ?? [])
        ghostty_surface_mouse_pos(surface, point.x, point.y, mods)
        if event?.buttonMask.contains(.secondary) == true {
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            return
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let surface, let touch = touches.first(where: { $0.type == .indirectPointer }) else { return }
        let point = touch.location(in: self)
        ghostty_surface_mouse_pos(surface, point.x, point.y, TerminalKey.mods(event?.modifierFlags ?? []))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        releasePointer(touches, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        releasePointer(touches, event: event)
    }

    private func releasePointer(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let surface, touches.contains(where: { $0.type == .indirectPointer }) else { return }
        _ = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, TerminalKey.mods(event?.modifierFlags ?? []))
    }

    // MARK: Accessibility

    /// The visible text, for VoiceOver (and UI tests).
    override var accessibilityValue: String? {
        get { visibleText() }
        set {}
    }

    /// The text on screen, row by row.
    func visibleText() -> String {
        guard let surface else { return "" }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return "" }
        return String(decoding: Data(bytes: pointer, count: Int(text.text_len)), as: UTF8.self)
    }
}

extension TerminalSurfaceView: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        // The standard actions this view can perform (Copy, Paste, Select
        // All) — not AutoFill, which offers passwords and contacts.
        UIMenu(children: suggestedActions.filter { ($0 as? UIMenu)?.identifier != .autoFill })
    }
}

/// The terminal text size on iOS: Settings ▸ Terminal, pinch, and ⌘+/⌘−
/// change it; new terminals start at it.
enum TerminalFontSize {
    static let defaultsKey = "terminalFontSize"
    static let range: ClosedRange<Double> = 6...36

    /// Small enough for a useful width on an iPhone; the Mac's size on iPad.
    @MainActor
    static var defaultSize: Double { Platform.isPhone ? 11 : 13 }

    @MainActor
    static var current: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: defaultsKey)
            return stored > 0 ? clamp(stored) : defaultSize
        }
        set {
            UserDefaults.standard.set(clamp(newValue), forKey: defaultsKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Posted when the size changes: open terminals follow it.
    static let changed = Notification.Name("RelayTerminalFontSizeChanged")

    static func clamp(_ size: Double) -> Double {
        min(max(size, range.lowerBound), range.upperBound)
    }
}
#endif
