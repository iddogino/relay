import AppKit
import SwiftUI
import UserNotifications

/// Settings ▸ Notifications: which agent alerts become macOS notifications.
struct NotificationsSettingsView: View {
    let notifier: AgentNotifier

    @AppStorage(AgentNotifier.needsInputKey) private var needsInput = true
    @AppStorage(AgentNotifier.finishedKey) private var finished = true
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        Form {
            Section {
                Toggle("When an agent needs your input", isOn: $needsInput)
                Toggle("When an agent finishes its turn", isOn: $finished)
            } header: {
                Text("Coding agents")
            } footer: {
                Text("For Claude Code and Codex sessions with Relay's status hooks. Never for the session you're looking at.")
                    .foregroundStyle(.secondary)
            }
            if status == .denied {
                Section {
                    HStack {
                        Text("Notifications are turned off for Relay in System Settings.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { status = await notifier.authorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { status = await notifier.authorizationStatus() }
        }
    }
}
