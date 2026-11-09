import Foundation
import IOKit.pwr_mgt

/// "Keep this Mac awake while Relay is open": a power assertion that stops
/// idle system sleep (the display may still sleep), so other devices can
/// reach this Mac's sessions. Device-local, off unless turned on. It can't
/// keep a laptop awake with its lid closed — macOS sleeps it regardless.
@MainActor
final class KeepAwake {
    static let enabledKey = "keepMacAwakeWhileOpen"

    private var assertion: IOPMAssertionID?

    init() {
        apply()
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            apply()
        }
    }

    /// Takes or releases the assertion to match the stored choice. The
    /// assertion goes away by itself when the app quits.
    func apply() {
        if isEnabled {
            guard assertion == nil else { return }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Relay is keeping this Mac reachable for remote sessions" as CFString,
                &id)
            if result == kIOReturnSuccess { assertion = id }
        } else if let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}
