#if os(iOS)
import UIKit

/// The keys a terminal needs that iOS keyboards lack — Escape, Tab,
/// Control, Option, the arrows and the symbols buried on the keyboard's
/// other pages — in a row above the software keyboard (at the bottom of
/// the screen with a hardware one), plus Paste and Hide Keyboard.
///
/// Control and Option apply to the next key, from here or the keyboard:
/// tap to arm one for one key, double-tap to keep it on, tap again to
/// release. Arrows and Backspace repeat while held.
///
/// The keys scroll sideways where they don't fit (most of them, on an
/// iPhone), faded at an edge with more past it. A swipe that starts on a
/// key scrolls rather than pressing it.
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback {
    enum Key: Equatable {
        case named(TerminalKey.Named)
        case text(String)
        case modifier(StickyModifier)
    }

    weak var terminal: TerminalSurfaceView?

    private let scroll = KeyBarScrollView()
    private let stack = UIStackView()
    private let fade = CAGradientLayer()
    private var modifierButtons: [StickyModifier: UIButton] = [:]
    private var repeatTimer: Timer?

    /// In order of need: on most iPhones the keys up to the arrows fit, with
    /// the edge of the next showing; the rest scroll into reach.
    static let keys: [Key] = [
        .named(.escape), .named(.tab), .modifier(.control),
        .named(.left), .named(.down), .named(.up), .named(.right),
        .modifier(.alternate),
        .text("~"), .text("|"), .text("/"), .text("-"), .text("`"),
        .named(.home), .named(.end), .named(.pageUp), .named(.pageDown),
    ]

    private static let isPhone = UIDevice.current.userInterfaceIdiom == .phone

    init(terminal: TerminalSurfaceView) {
        self.terminal = terminal
        let height: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 52 : 46
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: height), inputViewStyle: .keyboard)
        // Sized by its intrinsic height (the system sets its width).
        autoresizingMask = .flexibleHeight
        build(height: height)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var enableInputClicksWhenVisible: Bool { true }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIDevice.current.userInterfaceIdiom == .pad ? 52 : 46)
    }

    private func build(height: CGFloat) {
        scroll.showsHorizontalScrollIndicator = false
        scroll.accessibilityIdentifier = "keybar.keys"
        // Touches wait a moment before reaching a key: long enough to tell a
        // swipe from a press, which then scrolls instead.
        scroll.delaysContentTouches = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.didLayout = { [weak self] in self?.updateFade() }
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        addSubview(scroll)

        stack.axis = .horizontal
        stack.spacing = Self.isPhone ? 4 : 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        for key in Self.keys { stack.addArrangedSubview(button(for: key)) }

        // Always in reach, outside the scrolling keys.
        let trailing = UIStackView()
        trailing.axis = .horizontal
        trailing.spacing = 6
        trailing.alignment = .center
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailing)
        if let terminal {
            // The system's paste button: pastes without asking first.
            let configuration = UIPasteControl.Configuration()
            configuration.displayMode = .iconOnly
            configuration.cornerStyle = .medium
            configuration.baseForegroundColor = .label
            configuration.baseBackgroundColor = Self.keyColor
            let paste = UIPasteControl(configuration: configuration)
            paste.target = terminal
            paste.translatesAutoresizingMaskIntoConstraints = false
            paste.accessibilityIdentifier = "keybar.paste"
            NSLayoutConstraint.activate([
                paste.widthAnchor.constraint(equalToConstant: 44),
                paste.heightAnchor.constraint(equalToConstant: Self.keyHeight),
            ])
            trailing.addArrangedSubview(paste)
        }
        let hide = keyButton(title: nil, image: "keyboard.chevron.compact.down", label: "Hide Keyboard")
        hide.accessibilityIdentifier = "keybar.hideKeyboard"
        hide.addAction(UIAction { [weak self] _ in
            _ = self?.terminal?.resignFirstResponder()
        }, for: .touchUpInside)
        trailing.addArrangedSubview(hide)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: separator.leadingAnchor, constant: -6),
            separator.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            separator.heightAnchor.constraint(equalToConstant: Self.keyHeight - 8),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -6),
            trailing.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),

            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Self.isPhone ? 4 : 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    /// Fades the keys out at an edge with more keys past it.
    private func updateFade() {
        let width = scroll.bounds.width
        let offset = scroll.contentOffset.x
        let before = offset > 1
        let after = offset + width < scroll.contentSize.width - 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if width > 0, before || after {
            // The mask is in the scroller's own coordinates, which scroll.
            fade.frame = scroll.bounds
            let edge = min(12, width / 4) / width
            fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
            let opaque = UIColor.black.cgColor, clear = UIColor.clear.cgColor
            fade.colors = [before ? clear : opaque, opaque, opaque, after ? clear : opaque]
            scroll.layer.mask = fade
        } else {
            scroll.layer.mask = nil
        }
        CATransaction.commit()
    }

    // MARK: Keys

    private static let keyHeight: CGFloat = 36
    private static let keyColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.22) : .white
    }

    private func button(for key: Key) -> UIButton {
        switch key {
        case .named(let named):
            let button = keyButton(title: Self.title(named), image: Self.symbol(named), label: Self.label(named))
            button.accessibilityIdentifier = "keybar.\(named.rawValue)"
            let repeats = [.left, .right, .up, .down, .backspace].contains(named)
            wire(button, repeats: repeats) { [weak self] in self?.terminal?.pressKeyBarKey(named) }
            return button
        case .text(let text):
            let button = keyButton(title: text, image: nil, label: text)
            button.accessibilityIdentifier = "keybar.text.\(text)"
            wire(button, repeats: false) { [weak self] in self?.terminal?.typeKeyBarText(text) }
            return button
        case .modifier(let modifier):
            let title = modifier == .control ? "ctrl" : "alt"
            let button = keyButton(title: title, image: nil, label: modifier == .control ? "Control" : "Option")
            button.accessibilityIdentifier = "keybar.\(title)"
            modifierButtons[modifier] = button
            let tap = UITapGestureRecognizer(target: self, action: #selector(modifierTapped(_:)))
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(modifierDoubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            // A single tap arms right away; a second one makes it stick.
            tap.delaysTouchesEnded = false
            button.addGestureRecognizer(tap)
            button.addGestureRecognizer(doubleTap)
            return button
        }
    }

    private func keyButton(title: String?, image: String?, label: String) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = Self.keyColor
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .medium
        let inset: CGFloat = Self.isPhone ? (image == nil ? 7 : 5) : 10
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset)
        if let image {
            configuration.image = UIImage(systemName: image, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        } else if let title {
            var attributed = AttributeContainer()
            attributed.font = UIFont.monospacedSystemFont(ofSize: title.count > 1 ? (Self.isPhone ? 13 : 14) : 17, weight: .medium)
            configuration.attributedTitle = AttributedString(title, attributes: attributed)
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: Self.keyHeight),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.isPhone ? 32 : 40),
        ])
        // Like a keyboard's keys: a hairline shadow underneath.
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.15
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        return button
    }

    /// Fires `action` when the key is released, as a keyboard's keys do;
    /// when `repeats`, when it's pressed instead, then repeating while held.
    /// Either way, a swipe across the keys cancels it.
    private func wire(_ button: UIButton, repeats: Bool, action: @escaping @MainActor () -> Void) {
        button.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            action()
            guard repeats else { return }
            self?.repeatTimer?.invalidate()
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                MainActor.assumeIsolated {
                    self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
                        MainActor.assumeIsolated { action() }
                    }
                }
            }
        }, for: repeats ? .touchDown : .touchUpInside)
        guard repeats else { return }
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit] {
            button.addAction(UIAction { [weak self] _ in
                self?.repeatTimer?.invalidate()
                self?.repeatTimer = nil
            }, for: event)
        }
    }

    @objc private func modifierTapped(_ gesture: UITapGestureRecognizer) {
        guard let modifier = modifier(of: gesture) else { return }
        UIDevice.current.playInputClick()
        terminal?.toggleStickyModifier(modifier)
    }

    @objc private func modifierDoubleTapped(_ gesture: UITapGestureRecognizer) {
        guard let modifier = modifier(of: gesture) else { return }
        terminal?.lockStickyModifier(modifier)
    }

    private func modifier(of gesture: UIGestureRecognizer) -> StickyModifier? {
        modifierButtons.first { $0.value === gesture.view }?.key
    }

    /// Shows each modifier's state: off, on for the next key, or locked.
    func showModifiers(_ states: [StickyModifier: StickyModifier.State]) {
        for (modifier, button) in modifierButtons {
            let state = states[modifier] ?? .off
            var configuration = button.configuration
            configuration?.baseBackgroundColor = state == .off ? Self.keyColor : .tintColor
            configuration?.baseForegroundColor = state == .off ? .label : .white
            if var title = configuration?.attributedTitle {
                title.underlineStyle = state == .locked ? .single : nil
                configuration?.attributedTitle = title
            }
            button.configuration = configuration
            button.accessibilityValue = switch state {
            case .off: "off"
            case .once: "on for the next key"
            case .locked: "locked"
            }
        }
    }

    // MARK: Labels

    private static func title(_ key: TerminalKey.Named) -> String? {
        switch key {
        case .escape: return "esc"
        case .tab: return "tab"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pgup"
        case .pageDown: return "pgdn"
        default: return nil
        }
    }

    private static func symbol(_ key: TerminalKey.Named) -> String? {
        switch key {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .backspace: return "delete.left"
        case .enter: return "return"
        case .forwardDelete: return "delete.right"
        default: return nil
        }
    }

    private static func label(_ key: TerminalKey.Named) -> String {
        switch key {
        case .escape: return "Escape"
        case .tab: return "Tab"
        case .enter: return "Return"
        case .backspace: return "Delete"
        case .forwardDelete: return "Forward Delete"
        case .up: return "Up Arrow"
        case .down: return "Down Arrow"
        case .left: return "Left Arrow"
        case .right: return "Right Arrow"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        }
    }
}

/// The key bar's scroller.
private final class KeyBarScrollView: UIScrollView {
    /// After each layout, which scrolling also causes.
    var didLayout: (() -> Void)?

    /// A drag that starts on a key scrolls too. (By default a scroll view
    /// never takes back a touch from a control.)
    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?()
    }
}

/// Control or Option from the key bar, applied to the next key.
enum StickyModifier: Hashable {
    case control, alternate

    enum State: Equatable {
        case off
        /// For the next key only.
        case once
        /// Until turned off.
        case locked
    }
}
#endif
