import AppKit
import SwiftUI
import RelayCore

/// Settings ▸ iCloud: whether this Mac syncs its hosts and projects, how
/// that's going, and why it can't when it can't.
struct SyncSettingsView: View {
    @Bindable var model: AppModel

    private var sync: CloudSync { model.cloudSync }

    var body: some View {
        Form {
            Section {
                // Off, not just disabled, where the build can't sync.
                Toggle("Sync with iCloud", isOn: sync.availability == .notInThisBuild ? .constant(false) : $model.syncEnabled)
                    .disabled(sync.availability == .notInThisBuild)
                if model.syncEnabled, sync.availability == .available {
                    status
                }
            } footer: {
                Text("Hosts, projects and the host keys you trust sync to your devices signed in to the same Apple Account, end-to-end encrypted. Host passwords and your GitHub sign-in go through iCloud Keychain, when it\u{2019}s on.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.icloud.fill")
                            .foregroundStyle(.orange)
                        Text(problem.message)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if problem.opensSystemSettings {
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                Text("Terminal and notification settings, the sidebar\u{2019}s layout, and Relay keys kept in this Mac\u{2019}s Secure Enclave.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Stays on this Mac")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await sync.refreshAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await sync.refreshAvailability() }
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            if sync.isSyncing {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing\u{2026}")
            } else if let error = sync.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if sync.pendingCount > 0 {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("\(sync.pendingCount) change\(sync.pendingCount == 1 ? "" : "s") waiting to sync")
            } else if let date = sync.lastSyncedAt {
                Image(systemName: "checkmark.icloud")
                TimelineView(.everyMinute) { _ in
                    Text("Up to date \u{2014} synced \(date, format: .relative(presentation: .named))")
                }
            } else {
                Text("Waiting for iCloud\u{2026}")
            }
            Spacer()
            Button("Sync Now") {
                Task { await sync.syncNow() }
            }
            .disabled(sync.isSyncing)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private struct Problem {
        let message: String
        var opensSystemSettings = false
    }

    private var problem: Problem? {
        if sync.availability == .notInThisBuild {
            return Problem(message: "This build of Relay isn\u{2019}t signed for iCloud, so it can\u{2019}t sync.")
        }
        guard model.syncEnabled else {
            // Why sync turned itself off (iCloud's copy was deleted).
            return sync.lastError.map { Problem(message: $0) }
        }
        switch sync.availability {
        case .noAccount:
            return Problem(message: "Sign in to iCloud to sync your hosts and projects.", opensSystemSettings: true)
        case .restricted:
            return Problem(message: "iCloud is restricted on this Mac (by Screen Time or device management), so Relay can\u{2019}t sync.")
        case .temporarilyUnavailable:
            return Problem(message: "iCloud needs your attention before Relay can sync.", opensSystemSettings: true)
        case .unknown(let reason):
            return Problem(message: "Relay couldn\u{2019}t check your iCloud account. \(reason)")
        case .checking, .available, .notInThisBuild:
            return nil
        }
    }
}
