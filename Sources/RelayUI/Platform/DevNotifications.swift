import Foundation
#if os(iOS)
import notify
#endif

/// How the dev-only automation hooks are triggered from outside the app:
/// a distributed notification on macOS; a Darwin notification on iOS
/// (`xcrun simctl spawn <device> notifyutil -p <name>` in the Simulator).
@MainActor
enum DevNotifications {
    /// Calls `handler` on the main actor each time `name` is posted.
    static func observe(_ name: String, handler: @escaping @MainActor () -> Void) {
        #if os(macOS)
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        })
        #else
        var token: Int32 = NOTIFY_TOKEN_INVALID
        notify_register_dispatch(name, &token, .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        tokens.append(token)
        #endif
    }

    #if os(macOS)
    private static var observers: [NSObjectProtocol] = []
    #else
    private static var tokens: [Int32] = []
    #endif
}
