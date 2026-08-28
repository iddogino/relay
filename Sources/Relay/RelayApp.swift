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
                Toggle("Show Hidden Remotes", isOn: Binding(
                    get: { model.showHiddenRemotes },
                    set: { model.showHiddenRemotes = $0 }))
                Picker("Appearance", selection: Binding(
                    get: { model.appearance },
                    set: { model.appearance = $0 })) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
            }
            CommandMenu("Session") {
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
            }
        }
    }
}
