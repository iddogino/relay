import AppKit
import IOKit.ps
import SystemConfiguration

/// This Mac's sleep settings, as far as they decide whether other devices
/// can reach it — read from what powerd publishes in the dynamic store
/// (public, sandbox-safe), for the power source in use right now.
struct PowerSettings: Equatable {
    /// Has a battery (a laptop).
    var hasBattery: Bool
    /// Running on battery right now (the settings read are battery's).
    var onBattery: Bool
    /// Minutes of idle before system sleep; 0 means never.
    var systemSleepMinutes: Int?
    /// "Wake for network access".
    var wakeOnLAN: Bool?
    /// "Start up automatically after a power failure" (desktops).
    var restartAfterPowerFailure: Bool?
    /// macOS stays awake while a remote terminal session is active.
    var remoteSessionsPreventSleep: Bool?

    static func read() -> PowerSettings {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = info.flatMap { IOPSCopyPowerSourcesList($0)?.takeRetainedValue() as? [CFTypeRef] } ?? []
        let hasBattery = sources.contains { source in
            guard let info, let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
        let providing = info.map { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? } ?? nil
        let current = SCDynamicStoreCopyValue(nil, "State:/IOKit/PowerManagement/CurrentSettings" as CFString)
            as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (current[key] as? NSNumber)?.intValue }
        return PowerSettings(
            hasBattery: hasBattery,
            onBattery: providing == kIOPMBatteryPowerKey,
            systemSleepMinutes: int("System Sleep Timer"),
            wakeOnLAN: int("Wake On LAN").map { $0 != 0 },
            restartAfterPowerFailure: int("Automatic Restart On Power Loss").map { $0 != 0 },
            remoteSessionsPreventSleep: int("TTYSPreventSleep").map { $0 != 0 })
    }

    /// A row of advice: what to set, whether it's set, where to set it.
    struct Hint: Identifiable, Equatable {
        enum State: Equatable { case good, needsChange, unknown }
        let id: String
        let title: String
        let detail: String
        let state: State
    }

    /// The advice for this Mac. Pure; unit-tested through `hints(for:)`.
    private var sleepConsequence: String {
        guard let minutes = systemSleepMinutes else {
            return "Without it, this Mac may sleep when idle and your other devices lose it."
        }
        return "Without it, this Mac sleeps after \(minutes) minute\(minutes == 1 ? "" : "s") idle and your other devices lose it."
    }

    var hints: [Hint] {
        var hints: [Hint] = []
        let sleepState: Hint.State = systemSleepMinutes.map { $0 == 0 ? .good : .needsChange } ?? .unknown
        if hasBattery {
            if onBattery {
                hints.append(Hint(
                    id: "sleep", title: "Prevent automatic sleeping on power adapter when the display is off",
                    detail: "In Battery \u{25B8} Options. This Mac is on battery now, so Relay can\u{2019}t check the power adapter setting.",
                    state: .unknown))
            } else {
                hints.append(Hint(
                    id: "sleep", title: "Prevent automatic sleeping on power adapter when the display is off",
                    detail: sleepState == .good
                        ? "On: this Mac stays awake while it\u{2019}s plugged in."
                        : "In Battery \u{25B8} Options. \(sleepConsequence)",
                    state: sleepState))
            }
            hints.append(Hint(
                id: "lid", title: "Keep the lid open",
                detail: "A closed laptop sleeps unless it\u{2019}s plugged in with an external display.",
                state: .unknown))
        } else {
            hints.append(Hint(
                id: "sleep", title: "Prevent automatic sleeping when the display is off",
                detail: sleepState == .good
                    ? "On: this Mac never sleeps on its own."
                    : "In Energy. \(sleepConsequence)",
                state: sleepState))
            hints.append(Hint(
                id: "restart", title: "Start up automatically after a power failure",
                detail: "In Energy. Brings this Mac back after an outage.",
                state: restartAfterPowerFailure.map { $0 ? .good : .needsChange } ?? .unknown))
        }
        hints.append(Hint(
            id: "wake", title: "Wake for network access",
            detail: "Lets a sleeping Mac wake when a device on the same network connects. It doesn\u{2019}t work over Tailscale.",
            state: wakeOnLAN.map { $0 ? .good : .needsChange } ?? .unknown))
        if remoteSessionsPreventSleep == true {
            hints.append(Hint(
                id: "tty", title: "Awake during remote sessions",
                detail: "macOS doesn\u{2019}t idle-sleep while a terminal connected from another device is active.",
                state: .good))
        }
        return hints
    }

    /// System Settings at the pane that has these settings.
    func openSystemSettings() {
        let pane = hasBattery ? "com.apple.Battery-Settings.extension" : "com.apple.Energy-Saver-Settings.extension"
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}
