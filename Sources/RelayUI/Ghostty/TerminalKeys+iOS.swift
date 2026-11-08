#if os(iOS)
import GhosttyKit
import UIKit

/// Keys as libghostty takes them on iOS: macOS virtual keycodes (its iOS
/// build reads keycodes with its macOS table), plus the text a key types.
enum TerminalKey {
    /// A key with no text of its own, from the key bar or a hardware
    /// keyboard.
    enum Named: String, CaseIterable {
        case escape, tab, enter, backspace, up, down, left, right
        case home, end, pageUp, pageDown, forwardDelete

        var keycode: UInt32 {
            switch self {
            case .enter: return 0x24
            case .tab: return 0x30
            case .backspace: return 0x33
            case .escape: return 0x35
            case .left: return 0x7B
            case .right: return 0x7C
            case .down: return 0x7D
            case .up: return 0x7E
            case .home: return 0x73
            case .pageUp: return 0x74
            case .forwardDelete: return 0x75
            case .end: return 0x77
            case .pageDown: return 0x79
            }
        }
    }

    /// No key types it: text-only input (emoji, other scripts).
    static let unidentified: UInt32 = 0xFFFF

    /// The US-layout keys of the printable ASCII characters.
    private static let characterKeycodes: [Character: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, " ": 0x31, "`": 0x32,
    ]

    /// Shifted characters, by the unshifted character of their key.
    private static let shiftedBase: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
        ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
        ">": ".", "?": "/", "~": "`",
    ]

    /// The US-layout key typing `character`: its keycode, its unshifted
    /// character, and whether Shift is held. nil for anything else.
    static func lookup(_ character: Character) -> (keycode: UInt32, base: Character, shifted: Bool)? {
        if let keycode = characterKeycodes[character] { return (keycode, character, false) }
        if character.isUppercase, character.isASCII, let lower = character.lowercased().first,
           let keycode = characterKeycodes[lower] {
            return (keycode, lower, true)
        }
        if let base = shiftedBase[character], let keycode = characterKeycodes[base] { return (keycode, base, true) }
        return nil
    }

    static func mods(_ flags: UIKeyModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.alternate) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.alphaShift) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    /// A hardware keyboard key's macOS keycode, by its USB HID usage.
    static func keycode(hid usage: UIKeyboardHIDUsage) -> UInt32? {
        hidKeycodes[usage.rawValue]
    }

    /// Whether the key types a character (letters, digits, punctuation,
    /// space, the keypad's): other keys' `UIKey.characters` are control
    /// codes or names like "UIKeyInputUpArrow", never text.
    static func typesText(_ usage: UIKeyboardHIDUsage) -> Bool {
        switch usage.rawValue {
        case UIKeyboardHIDUsage.keyboardA.rawValue...UIKeyboardHIDUsage.keyboard0.rawValue,
             UIKeyboardHIDUsage.keyboardSpacebar.rawValue...UIKeyboardHIDUsage.keyboardSlash.rawValue,
             UIKeyboardHIDUsage.keypadSlash.rawValue...UIKeyboardHIDUsage.keypadPlus.rawValue,
             UIKeyboardHIDUsage.keypad1.rawValue...UIKeyboardHIDUsage.keypadPeriod.rawValue,
             UIKeyboardHIDUsage.keyboardNonUSBackslash.rawValue,
             UIKeyboardHIDUsage.keypadEqualSign.rawValue:
            return true
        default:
            return false
        }
    }

    /// Whether the key is a modifier on its own (Shift, Control…).
    static func isModifier(_ usage: UIKeyboardHIDUsage) -> Bool {
        (UIKeyboardHIDUsage.keyboardLeftControl.rawValue...UIKeyboardHIDUsage.keyboardRightGUI.rawValue)
            .contains(usage.rawValue) || usage == .keyboardCapsLock
    }

    private static let hidKeycodes: [Int: UInt32] = {
        typealias U = UIKeyboardHIDUsage
        var table: [U: UInt32] = [
            .keyboardA: 0x00, .keyboardS: 0x01, .keyboardD: 0x02, .keyboardF: 0x03, .keyboardH: 0x04,
            .keyboardG: 0x05, .keyboardZ: 0x06, .keyboardX: 0x07, .keyboardC: 0x08, .keyboardV: 0x09,
            .keyboardNonUSBackslash: 0x0A, .keyboardB: 0x0B, .keyboardQ: 0x0C, .keyboardW: 0x0D,
            .keyboardE: 0x0E, .keyboardR: 0x0F, .keyboardY: 0x10, .keyboardT: 0x11, .keyboard1: 0x12,
            .keyboard2: 0x13, .keyboard3: 0x14, .keyboard4: 0x15, .keyboard6: 0x16, .keyboard5: 0x17,
            .keyboardEqualSign: 0x18, .keyboard9: 0x19, .keyboard7: 0x1A, .keyboardHyphen: 0x1B,
            .keyboard8: 0x1C, .keyboard0: 0x1D, .keyboardCloseBracket: 0x1E, .keyboardO: 0x1F,
            .keyboardU: 0x20, .keyboardOpenBracket: 0x21, .keyboardI: 0x22, .keyboardP: 0x23,
            .keyboardReturnOrEnter: 0x24, .keyboardL: 0x25, .keyboardJ: 0x26, .keyboardQuote: 0x27,
            .keyboardK: 0x28, .keyboardSemicolon: 0x29, .keyboardBackslash: 0x2A, .keyboardComma: 0x2B,
            .keyboardSlash: 0x2C, .keyboardN: 0x2D, .keyboardM: 0x2E, .keyboardPeriod: 0x2F,
            .keyboardTab: 0x30, .keyboardSpacebar: 0x31, .keyboardGraveAccentAndTilde: 0x32,
            .keyboardDeleteOrBackspace: 0x33, .keyboardEscape: 0x35,
            .keypadPeriod: 0x41, .keypadAsterisk: 0x43, .keypadPlus: 0x45, .keypadNumLock: 0x47,
            .keypadSlash: 0x4B, .keypadEnter: 0x4C, .keypadHyphen: 0x4E, .keypadEqualSign: 0x51,
            .keypad0: 0x52, .keypad1: 0x53, .keypad2: 0x54, .keypad3: 0x55, .keypad4: 0x56,
            .keypad5: 0x57, .keypad6: 0x58, .keypad7: 0x59, .keypad8: 0x5B, .keypad9: 0x5C,
            .keyboardF5: 0x60, .keyboardF6: 0x61, .keyboardF7: 0x62, .keyboardF3: 0x63, .keyboardF8: 0x64,
            .keyboardF9: 0x65, .keyboardF11: 0x67, .keyboardF13: 0x69, .keyboardF16: 0x6A,
            .keyboardF14: 0x6B, .keyboardF10: 0x6D, .keyboardF12: 0x6F, .keyboardF15: 0x71,
            .keyboardInsert: 0x72, .keyboardHome: 0x73, .keyboardPageUp: 0x74,
            .keyboardDeleteForward: 0x75, .keyboardF4: 0x76, .keyboardEnd: 0x77, .keyboardF2: 0x78,
            .keyboardPageDown: 0x79, .keyboardF1: 0x7A, .keyboardLeftArrow: 0x7B,
            .keyboardRightArrow: 0x7C, .keyboardDownArrow: 0x7D, .keyboardUpArrow: 0x7E,
            .keyboardF17: 0x40, .keyboardF18: 0x4F, .keyboardF19: 0x50, .keyboardF20: 0x5A,
        ]
        table[.keyboardNonUSPound] = 0x2A
        return Dictionary(uniqueKeysWithValues: table.map { ($0.key.rawValue, $0.value) })
    }()
}
#endif
