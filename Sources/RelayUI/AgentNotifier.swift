import AppKit
import RelayCore
@preconcurrency import UserNotifications

/// macOS notifications for agent alerts (see `AgentAlertTracker`): one per
/// session at a time, replaced by the next, removed once the session is
/// looked at. Clicking one brings Relay forward on that session.
/// Permission is asked the first time there is something to say.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let needsInputKey = "notifyWhenAgentNeedsInput"
    static let finishedKey = "notifyWhenAgentFinishes"

    /// Called with the session of a clicked notification.
    var onOpen: ((SessionID) -> Void)?

    /// UserNotifications needs a bundled app (it traps under `swift run`
    /// and in tests).
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Self.needsInputKey: true, Self.finishedKey: true])
        center?.delegate = self
    }

    static func isEnabled(for kind: AgentAlert.Kind) -> Bool {
        switch kind {
        case .needsInput: return UserDefaults.standard.bool(forKey: needsInputKey)
        case .finished, .failed: return UserDefaults.standard.bool(forKey: finishedKey)
        }
    }

    func post(_ alert: AgentAlert, session: RemoteSession, project: Project, task: String?) {
        guard let center, Self.isEnabled(for: alert.kind) else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = "\(project.name) / \(session.displayName)"
        if let task { content.body = task }
        content.sound = .default
        content.threadIdentifier = Self.identifier(for: session.id)
        content.userInfo = ["session": session.id.uuid.uuidString]
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: session.id), content: content, trigger: nil)
        Task {
            guard await Self.authorized(center) else { return }
            try? await center.add(request)
        }
    }

    /// Removes the session's notification from Notification Center.
    func clear(_ session: SessionID) {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier(for: session)])
    }

    private static func identifier(for session: SessionID) -> String {
        "agent-\(session.uuid.uuidString)"
    }

    private static func authorized(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// The system's verdict for the settings pane.
    func authorizationStatus() async -> UNAuthorizationStatus? {
        await center?.notificationSettings().authorizationStatus
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // AppModel only posts for sessions the user isn't looking at, so a
        // banner is wanted even while Relay is frontmost.
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let string = response.notification.request.content.userInfo["session"] as? String,
              let uuid = UUID(uuidString: string)
        else { return }
        await MainActor.run {
            NSApp.activate()
            onOpen?(SessionID(uuid: uuid))
        }
    }
}
