import SwiftUI
import RelayCore

@main
struct RelayApp: App {
    @State private var model: AppModel
    @StateObject private var updater = UpdaterModel()
    @AppStorage(UpdaterModel.earlyBuildsDefaultsKey) private var receiveEarlyBuilds = false

    init() {
        // Initialize libghostty before any UI exists.
        _ = GhosttyRuntime.shared
        AppearancePreference.stored().apply()
        _model = State(initialValue: AppModel(provider: SSHTmuxRuntimeProvider()))
    }

    /// Standard cap choices, plus the current value if it was set to
    /// something else (e.g. via `defaults write`) so the picker never shows
    /// an empty selection.
    private var warmCapOptions: [Int] {
        Array(Set([1, 2, 4, 6, 8] + [model.warmAttachmentCap])).sorted()
    }

    var body: some Scene {
        Window("Relay", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
                Toggle("Receive Early Builds", isOn: $receiveEarlyBuilds)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Session…") {
                    if let project = model.selectedProject ?? model.projects.first {
                        model.newSessionProject = project
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.projects.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task {
                        await model.refreshRemotes()
                        if let project = model.selectedProject {
                            await model.refreshSessions(for: project)
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Picker("Appearance", selection: Binding(
                    get: { model.appearance },
                    set: { model.appearance = $0 })) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
            }
            CommandMenu("Session") {
                // Tab-style switching: sessions in sidebar order. The menu
                // is what registers ⌘1–⌘9 app-wide (the terminal surface
                // hands ⌘-equivalents to the main menu first).
                Menu("Switch to Session") {
                    let ordered = Array(model.shortcutOrderedSessions.prefix(9))
                    if ordered.isEmpty {
                        Text("No Sessions")
                    }
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, session in
                        Button(sessionMenuLabel(session)) {
                            model.selectSession(number: index + 1)
                        }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(index + 1)")),
                            modifiers: .command)
                    }
                }

                Divider()

                Button("Archive Session…") {
                    if let session = model.selectedSession {
                        Task { await model.archiveSession(session) }
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selectedSession == nil)

                Button("Reconnect") {
                    model.attachment.retryNow()
                }
                .disabled(model.selectedSession == nil)

                Divider()

                Button("Kill Session…") {
                    if let session = model.selectedSession {
                        model.confirmKillSession = session
                    }
                }
                .disabled(model.selectedSession == nil)

                Divider()

                // How many recently-visited sessions keep their ssh
                // connections warm (green dot) after switching away.
                Picker("Warm Connections", selection: Binding(
                    get: { model.warmAttachmentCap },
                    set: { model.warmAttachmentCap = $0 })) {
                    ForEach(warmCapOptions, id: \.self) { cap in
                        Text("\(cap) Session\(cap == 1 ? "" : "s")").tag(cap)
                    }
                }
            }
            CommandMenu("GitHub") {
                // Disabled status line: where PR badges get their API access.
                Text(gitHubStatusLine)
                Divider()
                if case .connected(.device, _) = model.gitHub {
                    Button("Sign Out of GitHub") {
                        model.signOutGitHub()
                    }
                } else {
                    Button("Log In to GitHub…") {
                        model.gitHubLoginPresented = true
                    }
                }
                Button("Recheck Connection") {
                    Task { await model.recheckGitHubAuth() }
                }
            }
        }
    }

    private func sessionMenuLabel(_ session: RemoteSession) -> String {
        guard let project = model.projects.first(where: { $0.id == session.projectID }) else {
            return session.displayName
        }
        return "\(project.name) / \(session.displayName)"
    }

    private var gitHubStatusLine: String {
        switch model.gitHub {
        case .checking:
            return "Status: Checking…"
        case .connected(.cli, let login):
            return "Status: Connected via gh CLI (@\(login))"
        case .connected(.device, let login):
            return "Status: Connected (@\(login))"
        case .notConnected:
            return "Status: Not Connected"
        case .failed:
            return "Status: Connection Error"
        }
    }
}
