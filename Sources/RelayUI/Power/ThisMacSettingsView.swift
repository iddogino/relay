#if os(macOS)
import AppKit
import SwiftUI

/// Settings ▸ This Mac: running sessions on this Mac, and keeping it
/// reachable for your other devices.
struct ThisMacSettingsView: View {
    @Bindable var model: AppModel

    @AppStorage(KeepAwake.enabledKey) private var keepAwakeEnabled = false
    @State private var power = PowerSettings.read()
    @State private var setupPresented = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                if let host = model.thisMacHost {
                    LabeledContent {
                        Button("Add Project\u{2026}") {
                            // The editor is a sheet on the main window.
                            openWindow(id: "main")
                            NSApp.activate()
                            model.projectEditor = ProjectEditorContext(mode: .create(workspace: host.workspace))
                        }
                    } label: {
                        Label {
                            Text("\u{201C}\(host.alias)\u{201D} is this Mac")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Text("Reached over loopback here, and as \(host.hostname) from your other devices.")
                    }
                } else {
                    LabeledContent {
                        Button("Add This Mac\u{2026}") { setupPresented = true }
                    } label: {
                        Text("Run sessions on this Mac")
                        Text(model.localHostKey == nil
                             ? "Uses Remote Login, so sessions keep running after Relay quits."
                             : "Remote Login is on. Add this Mac as a host to start projects on it.")
                    }
                }
            } header: {
                Text("Sessions")
            }

            Section {
                Toggle("Keep this Mac awake while Relay is open", isOn: $keepAwakeEnabled)
            } header: {
                Text("Staying reachable")
            } footer: {
                Text("Stops this Mac from going to sleep when idle, so your other devices can reach its sessions. The display can still turn off. A laptop with its lid closed sleeps anyway.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(power.hints) { hint in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(hint.state))
                            .foregroundStyle(tint(hint.state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hint.title)
                            Text(hint.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Open System Settings") { power.openSystemSettings() }
                }
            } header: {
                Text("To stay reachable when Relay isn\u{2019}t open")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: keepAwakeEnabled) { model.keepAwake.apply() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            power = PowerSettings.read()
        }
        .sheet(isPresented: $setupPresented) {
            ThisMacSetupSheet(model: model)
        }
    }

    private func icon(_ state: PowerSettings.Hint.State) -> String {
        switch state {
        case .good: return "checkmark.circle.fill"
        case .needsChange: return "exclamationmark.triangle.fill"
        case .unknown: return "info.circle"
        }
    }

    private func tint(_ state: PowerSettings.Hint.State) -> Color {
        switch state {
        case .good: return .green
        case .needsChange: return .orange
        case .unknown: return .secondary
        }
    }
}
#endif
