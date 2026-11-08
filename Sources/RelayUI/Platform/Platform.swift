import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few platform services the shared UI needs, one spelling for both
/// AppKit and UIKit. Everything else that differs lives in its own
/// per-platform file.
enum Platform {
    /// Whether this is an iPhone: one screen at a time (the session list,
    /// or one terminal), so one connection at a time.
    @MainActor
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// iPhone and iPad: touch first, where tapping a selected row opens it
    /// rather than renaming it.
    static var isTouch: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// What to call this device in the UI: "Mac", "iPhone" or "iPad".
    @MainActor
    static var deviceKind: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// Puts `text` on the general pasteboard.
    @MainActor
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.declareTypes([.string], owner: nil)
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// The general pasteboard's text. (On iOS, reading it outside a paste
    /// the user started asks them first.)
    @MainActor
    static func pasteboardText() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }

    /// Opens a URL in the app that handles it (the browser, Mail…).
    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Whether the app is the active (frontmost, foreground) one.
    @MainActor
    static var isAppActive: Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    /// Whether any of the app's windows is on screen.
    @MainActor
    static var hasVisibleWindow: Bool {
        #if os(macOS)
        NSApp.windows.contains(where: { $0.isVisible })
        #else
        UIApplication.shared.applicationState != .background
        #endif
    }

    /// Posted when the app becomes active.
    static var didBecomeActiveNotification: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }

    /// Posted when the app has stopped being active (iOS: is about to).
    static var didResignActiveNotification: Notification.Name {
        #if os(macOS)
        NSApplication.didResignActiveNotification
        #else
        UIApplication.willResignActiveNotification
        #endif
    }

    /// Posted when the app stops being active.
    static var willResignActiveNotification: Notification.Name {
        #if os(macOS)
        NSApplication.willResignActiveNotification
        #else
        UIApplication.willResignActiveNotification
        #endif
    }
}

#if os(macOS)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif

extension Color {
    init(platformColor: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: platformColor)
        #else
        self.init(uiColor: platformColor)
        #endif
    }

    /// Tertiary label text (dimmer than `.secondary`).
    static var tertiaryLabelText: Color {
        #if os(macOS)
        Color(nsColor: .tertiaryLabelColor)
        #else
        Color(uiColor: .tertiaryLabel)
        #endif
    }

    /// Behind editable text.
    static var textBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    /// A light/dark sRGB hex pair, resolved per appearance.
    static func dynamic(light: Int, dark: Int) -> Color {
        func color(_ hex: Int) -> PlatformColor {
            let (red, green, blue) = (
                CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
            #if os(macOS)
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            #else
            return UIColor(red: red, green: green, blue: blue, alpha: 1)
            #endif
        }
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            color(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

extension View {
    /// A Settings pane's size: fixed in the Mac's Settings window; on iOS
    /// the pane fills its screen of the Settings sheet.
    func settingsPaneWidth(_ width: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
        #else
        self
        #endif
    }

    /// Forms as each platform lays them out: label columns on the Mac,
    /// grouped rows on iOS.
    func relayFormStyle() -> some View {
        #if os(macOS)
        formStyle(.columns)
        #else
        formStyle(.grouped)
        #endif
    }

    /// A link-styled button on the Mac; a plain borderless one on iOS.
    func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// A checkbox on the Mac; iOS's switch.
    func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.switch)
        #endif
    }

    /// Radio buttons on the Mac; an inline list of choices on iOS.
    func radioGroupPickerStyle() -> some View {
        #if os(macOS)
        pickerStyle(.radioGroup)
        #else
        pickerStyle(.inline)
        #endif
    }

    /// A bordered list on the Mac (in a pane); grouped rows on iOS.
    func borderedListStyle() -> some View {
        #if os(macOS)
        listStyle(.bordered)
        #else
        listStyle(.insetGrouped)
        #endif
    }
}
