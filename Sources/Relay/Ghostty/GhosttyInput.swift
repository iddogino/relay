import AppKit
import GhosttyKit

/// Keyboard/mouse translation helpers between AppKit events and libghostty.
/// Adapted from Ghostty's own macOS app (MIT licensed).
enum GhosttyInput {
    // Device-side modifier masks from IOKit's IOLLEvent.h.
    static let deviceRightShiftMask: UInt = 0x0000_0004
    static let deviceRightCtrlMask: UInt = 0x0000_2000
    static let deviceRightAltMask: UInt = 0x0000_0040
    static let deviceRightCmdMask: UInt = 0x0000_0010

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        let raw = flags.rawValue
        if raw & deviceRightShiftMask != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & deviceRightCtrlMask != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & deviceRightAltMask != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & deviceRightCmdMask != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    static func mouseButton(fromButtonNumber number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    static func momentum(_ phase: NSEvent.Phase) -> UInt32 {
        switch phase {
        case .began: return 1 // began
        case .stationary: return 2
        case .changed: return 3
        case .ended: return 4
        case .cancelled: return 5
        case .mayBegin: return 6
        default: return 0 // none
        }
    }

    /// Packs scroll modifiers matching src/input/mouse.zig's ScrollMods:
    /// bit 0 = precision, bits 1–3 = momentum.
    static func scrollMods(precision: Bool, phase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var value: Int32 = precision ? 1 : 0
        value |= Int32(momentum(phase)) << 1
        return ghostty_input_scroll_mods_t(value)
    }
}

extension NSEvent {
    /// Builds a libghostty key event from this NSEvent. Text and composing
    /// state cannot be set safely here; callers fill them in.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(keyCode)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.mods = GhosttyInput.ghosttyMods(modifierFlags)
        // Control and command never contribute to text translation.
        keyEvent.consumed_mods = GhosttyInput.ghosttyMods(
            (translationMods ?? modifierFlags).subtracting([.control, .command]))

        keyEvent.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }
        }
        return keyEvent
    }

    /// The text to encode for a key event, excluding control characters
    /// (Ghostty encodes those itself) and private-use function keys.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }
}
