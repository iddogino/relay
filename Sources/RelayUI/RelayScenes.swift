import SwiftUI
import RelayCore
import RelaySSH

extension AppModel {
    /// The model the app runs on: the saved projects, hosts and keys,
    /// with libghostty set up first. Call once, before any UI exists.
    public static func makeForApp() -> AppModel {
        // Initialize libghostty before any UI exists.
        _ = GhosttyRuntime.shared
        AppearancePreference.stored().apply()
        // Folders outside the container this build was granted (sandbox).
        _ = FolderGrants.ssh
        let hostRegistry = SSHHostRegistry()
        let keyStore = KeychainSSHKeyStore(
            accessGroup: AppVariant.keychainAccessGroup, deviceName: AppVariant.computerName)
        var poolOptions = SSHConnectionPool.Options()
        poolOptions.keyStore = keyStore
        poolOptions.knownHostsFiles = KnownHosts.defaultFiles + [AppVariant.knownHostsFile.path]
        let builtInSSH = BuiltInSSHRouter(
            registry: hostRegistry,
            pool: SSHConnectionPool(options: poolOptions),
            keyStore: keyStore,
            trustedHostsFile: AppVariant.knownHostsFile.path,
            passwordLookup: { SSHPasswordStore.load(alias: $0) })
        hostRegistry.onHostsChanged = { builtInSSH.hostsChanged() }
        // Secrets earlier builds kept in the login keychain move to where
        // they sync from.
        GitHubTokenStore.secrets.moveFromLoginKeychain()
        SSHPasswordStore.secrets.moveFromLoginKeychain()
        let model = AppModel(
            provider: SSHTmuxRuntimeProvider(hostRegistry: hostRegistry, builtInSSH: builtInSSH),
            store: ProjectStore(fileURL: AppVariant.dataDirectory.appendingPathComponent("state.json")),
            hostRegistry: hostRegistry,
            builtInSSH: builtInSSH,
            cloudSync: CloudSync(containerIdentifier: AppVariant.cloudKitContainer))
        HostKeyDevHook.installIfDevBuild(model: model)
        SyncDevHook.installIfDevBuild(model: model)
        return model
    }
}

/// The app's window, settings and menus. The app shell presents them and
/// adds its own items to the app menu (the Mac app's updater).
public struct RelayScenes<AppMenuCommands: Commands>: Scene {
    private let model: AppModel
    private let appMenuCommands: AppMenuCommands

    public init(model: AppModel, @CommandsBuilder appMenuCommands: () -> AppMenuCommands) {
        self.model = model
        self.appMenuCommands = appMenuCommands()
    }

    /// Standard cap choices, plus the current value if it was set to
    /// something else (e.g. via `defaults write`) so the picker never shows
    /// an empty selection.
    private var warmCapOptions: [Int] {
        Array(Set([1, 2, 4, 6, 8] + [model.warmAttachmentCap])).sorted()
    }

    public var body: some Scene {
        Window("Relay", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 760)
        Settings {
            TabView {
                HostsSettingsView(model: model)
                    .tabItem { Label("Hosts", systemImage: "server.rack") }
                TerminalSettingsView()
                    .tabItem { Label("Terminal", systemImage: "terminal") }
                NotificationsSettingsView(notifier: model.agentNotifier)
                    .tabItem { Label("Notifications", systemImage: "bell.badge") }
                SyncSettingsView(model: model)
                    .tabItem { Label("iCloud", systemImage: "icloud") }
            }
        }
        .commands {
            appMenuCommands
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
                if case .connected = model.gitHub {
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
        case .connected(let login):
            return "Status: Connected (@\(login))"
        case .notConnected:
            return "Status: Not Connected"
        case .failed:
            return "Status: Connection Error"
        }
    }
}
