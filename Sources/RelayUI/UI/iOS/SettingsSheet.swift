#if os(iOS)
import SwiftUI
import RelayCore

/// Settings on iPhone and iPad: the Mac's Settings panes, as a sheet.
struct SettingsSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        HostsSettingsView(model: model)
                            .navigationTitle("Hosts")
                    } label: {
                        Label("Hosts", systemImage: "server.rack")
                    }
                    NavigationLink {
                        TerminalSettingsView()
                            .navigationTitle("Terminal")
                    } label: {
                        Label("Terminal", systemImage: "terminal")
                    }
                    NavigationLink {
                        NotificationsSettingsView(notifier: model.agentNotifier)
                            .navigationTitle("Notifications")
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                    NavigationLink {
                        SyncSettingsView(model: model)
                            .navigationTitle("iCloud")
                    } label: {
                        Label("iCloud", systemImage: "icloud")
                    }
                }
                Section {
                    GitHubSettingsRow(model: model)
                } header: {
                    Text("GitHub")
                } footer: {
                    Text("For pull request status in the terminal\u{2019}s toolbar.")
                }
                Section {
                    Picker("Appearance", selection: $model.appearance) {
                        ForEach(AppearancePreference.allCases) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // Presented from here while Settings is up (the window can't
            // present a second sheet over this one).
            .sheet(isPresented: $model.gitHubLoginPresented) {
                GitHubLoginSheet(model: model)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The GitHub sign-in: who's signed in, or a way to sign in.
private struct GitHubSettingsRow: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.gitHub {
        case .checking:
            HStack {
                Text("Checking\u{2026}")
                Spacer()
                ProgressView()
            }
        case .connected(let login):
            LabeledContent("Signed in as", value: "@\(login)")
            Button("Sign Out", role: .destructive) { model.signOutGitHub() }
        case .notConnected:
            Button("Sign In to GitHub\u{2026}") { model.gitHubLoginPresented = true }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
            Button("Sign In Again\u{2026}") { model.gitHubLoginPresented = true }
            Button("Recheck") { Task { await model.recheckGitHubAuth() } }
        }
    }
}
#endif
