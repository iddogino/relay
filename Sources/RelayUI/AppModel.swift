#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation
import SwiftUI
import RelayCore
import RelaySSH

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Manual appearance override (View ▸ Appearance). Stored in UserDefaults.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static let defaultsKey = "appearancePreference"

    static func stored() -> AppearancePreference {
        AppearancePreference(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    @MainActor
    func apply() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        #if os(macOS)
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        #endif
        // iOS: the root view applies `colorScheme`.
    }

    /// The scheme a view forces, nil for the system's.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Context for the project editor sheet: creating (optionally with a
/// preselected host) or editing.
struct ProjectEditorContext: Identifiable {
    enum Mode {
        case create(workspace: WorkspaceRef?)
        case edit(Project)
    }
    let id = UUID()
    let mode: Mode
}

/// Central UI state. Sessions go exclusively through `RuntimeProvider`; the
/// one SSH concept here is the host list Relay owns (`SSHHostRegistry`).
@MainActor
@Observable
public final class AppModel {
    let provider: any RuntimeProvider
    /// Warm terminal attachments, one per recently-visited session (LRU,
    /// capped). The selected session's controller is what the detail view
    /// renders; the others stay connected in the background so switching
    /// back is instant and their titles stay live. Ownership contract: a
    /// controller exists only for a session the user visited, and dies on
    /// disconnect, archive/kill/remove, remote end, LRU eviction, window
    /// close, or app quit.
    private var attachmentPool: [SessionID: TerminalAttachmentController] = [:]
    /// Least-recently-visited first.
    private var warmOrder: [SessionID] = []
    /// How many recently-visited sessions keep their connections warm.
    /// Device-local preference (Session ▸ Warm Connections). Lowering it
    /// evicts immediately, LRU-first; the selected session is never evicted.
    var warmAttachmentCap: Int {
        didSet {
            guard warmAttachmentCap != oldValue else { return }
            UserDefaults.standard.set(warmAttachmentCap, forKey: Self.warmAttachmentCapKey)
            trimWarmPool()
        }
    }
    static let warmAttachmentCapKey = "warmAttachmentCap"
    private static let warmAttachmentCapDefault = 4
    /// Placeholder the detail view renders when nothing is selected.
    private let idleAttachment: TerminalAttachmentController

    var attachment: TerminalAttachmentController {
        guard let id = selectedSessionID, let controller = attachmentPool[id] else {
            return idleAttachment
        }
        return controller
    }
    private let store: ProjectStore
    /// Relay's own host list, which every connection uses. `hosts` mirrors
    /// it for the UI and persistence.
    let hostRegistry: SSHHostRegistry?
    private(set) var hosts: [SSHHost] = []
    /// Relay's SSH client, with its keys and trusted host keys.
    let builtInSSH: BuiltInSSHRouter?
    /// The hosts and projects in iCloud (Settings ▸ iCloud).
    let cloudSync: CloudSync
    /// The known_hosts files, read for the host keys hosts sync with.
    /// Dropped when trust changes and when the app comes forward.
    private var knownHostsCache: KnownHosts?

    /// Sync with iCloud, a per-device choice: on unless turned off here.
    /// Covers the hosts and projects (CloudKit) and the secrets that go
    /// with them — host passwords, the GitHub sign-in (iCloud Keychain).
    var syncEnabled: Bool = AppModel.syncEnabledDefault {
        didSet {
            guard syncEnabled != oldValue else { return }
            UserDefaults.standard.set(syncEnabled, forKey: Self.syncDefaultsKey)
            GitHubTokenStore.secrets.syncChanged(enabled: syncEnabled)
            SSHPasswordStore.secrets.syncChanged(enabled: syncEnabled)
            builtInSSH?.hostsChanged()
            if syncEnabled {
                cloudSync.start()
            } else {
                cloudSync.stop()
            }
        }
    }
    nonisolated static let syncDefaultsKey = "syncWithICloud"
    /// The stored choice (registered as on), readable off the main actor.
    nonisolated static var syncEnabledDefault: Bool {
        UserDefaults.standard.object(forKey: syncDefaultsKey) as? Bool ?? true
    }

    // Remotes: the provider's view of the host list.
    private(set) var remotes: [WorkspaceDescriptor] = []
    private(set) var remotesLoaded = false

    // Local configuration. `projects` order is the sidebar order.
    private(set) var projects: [Project] = []
    private(set) var tombstones: [CleanupTombstone] = []
    /// Drag-to-reorder overlay for session rows (see SessionOrdering).
    private var sessionOrder: [SessionID] = []
    /// Projects whose session rows are folded away in the sidebar.
    private(set) var collapsedProjects: Set<ProjectID> = []

    // Remote-reconciled session lists
    private(set) var sessions: [ProjectID: [RemoteSession]] = [:]
    private(set) var sessionsLoading: Set<ProjectID> = []
    private var sessionSweepTimer: Timer?
    private(set) var sessionErrors: [ProjectID: String] = [:]

    // Selection & transient UI state

    /// The sidebar's selection. Usually one session, the one on screen. On
    /// the Mac, ⌘-click and ⇧-click select several for batch actions, and
    /// then no terminal is shown.
    var selectedSessionIDs: Set<SessionID> = [] {
        didSet {
            let previous = Self.onScreen(oldValue)
            if let onScreen = selectedSessionID { lastOnScreenSessionID = onScreen }
            else if selectedSessionIDs.isEmpty { lastOnScreenSessionID = nil }
            selectionDidChange(from: previous)
        }
    }
    /// The session on screen: the selection, when it's exactly one session.
    /// Setting it selects just that session (nil clears the selection).
    var selectedSessionID: SessionID? {
        get { Self.onScreen(selectedSessionIDs) }
        set { selectedSessionIDs = newValue.map { [$0] } ?? [] }
    }
    private static func onScreen(_ selection: Set<SessionID>) -> SessionID? {
        selection.count == 1 ? selection.first : nil
    }
    /// The session last on screen, saved for next launch while several are
    /// selected (none of them is on screen then).
    private var lastOnScreenSessionID: SessionID?

    /// Drops sessions from the selection; whatever is left stays selected.
    private func deselect<S: Sequence>(_ ids: S) where S.Element == SessionID {
        let remaining = selectedSessionIDs.subtracting(ids)
        if remaining != selectedSessionIDs { selectedSessionIDs = remaining }
    }
    /// When true, clearing the selection detaches but does not persist the
    /// cleared value (used for window close, which races app termination).
    private var preserveSelectionOnDisk = false
    var appearance: AppearancePreference = AppearancePreference.stored() {
        didSet { appearance.apply() }
    }
    private(set) var archivingSessions: Set<SessionID> = []
    var alert: AppAlert?
    var projectEditor: ProjectEditorContext?
    var newSessionProject: Project?
    /// The sidebar's + sheet: create a session or a project, user's choice.
    var createSheetPresented = false
    /// Sessions waiting on the Kill confirmation (one, or a batch).
    var confirmKillSessions: [RemoteSession] = []
    var confirmRemoveProject: Project?
    /// iOS: Settings, as a sheet (the Mac has a Settings window).
    var settingsPresented = false
    /// iOS: a host to set up for this device (from the session list).
    var hostToSetUp: SSHHost?

    private var restoredSelection: SessionID?

    init(
        provider: any RuntimeProvider,
        store: ProjectStore = ProjectStore(),
        hostRegistry: SSHHostRegistry? = nil,
        builtInSSH: BuiltInSSHRouter? = nil,
        cloudSync: CloudSync = CloudSync(containerIdentifier: nil)
    ) {
        self.provider = provider
        self.store = store
        self.hostRegistry = hostRegistry
        self.builtInSSH = builtInSSH
        self.cloudSync = cloudSync
        self.idleAttachment = TerminalAttachmentController(provider: provider)
        // Clamped on read so a hand-edited default can't disable attachment
        // (0/missing means unset) or leak connections without bound.
        let storedCap = UserDefaults.standard.integer(forKey: Self.warmAttachmentCapKey)
        // An iPhone shows one terminal at a time, so it keeps one
        // connection: the session on screen (or last on screen).
        self.warmAttachmentCap = Platform.isPhone ? 1 : storedCap == 0
            ? Self.warmAttachmentCapDefault
            : max(1, min(storedCap, 16))

        // When a session ends we keep its sidebar row until the user acts
        // (Remove From Sidebar / New Session) or a refresh reconciles it away,
        // so the "session ended" state is visible rather than vanishing.

        cloudSync.onStateChange = { [weak self] in self?.persist() }
        cloudSync.onRemoteChanges = { [weak self] in self?.applySyncChanges($0) }
        cloudSync.onCloudDataDeleted = { [weak self] in self?.syncEnabled = false }

        Task { await self.bootstrap() }
        Task { await self.refreshLocalIdentity(force: true) }
        Task { await self.recheckGitHubAuth() }

        agentNotifier.onOpen = { [weak self] id in
            guard let self, self.sessions.values.contains(where: { $0.contains { $0.id == id } }) else { return }
            self.selectedSessionID = id
        }

        NotificationCenter.default.addObserver(
            forName: Platform.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applicationDidActivate()
                // Remote Login may have been turned on or off meanwhile.
                Task { await self?.refreshLocalIdentity() }
            }
        }

        #if os(macOS)
        // ⌘-held tracking for the sidebar's ⌘1–⌘9 badges. Local monitors
        // run on the main thread; the resign observer clears a stuck flag
        // when the release lands in another app (⌘-Tab away). (iPadOS
        // shows its own shortcut overlay while ⌘ is held.)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.commandKeyHeld = event.modifierFlags.contains(.command)
            }
            return event
        }
        #endif
        NotificationCenter.default.addObserver(
            forName: Platform.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.commandKeyHeld = false
                self?.isAppActive = false
                self?.syncLoadMonitor()
                self?.syncAgentMonitors()
            }
        }

        // While a window is showing, the sidebar re-reads every project's
        // sessions periodically: pane titles (detached sessions keep
        // reporting status through them; tmux tracks OSC titles server-side),
        // and names and sessions changed from another device.
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // PR-status polling is NOT on this timer: it self-schedules
                // adaptively off the git-state chain (10s while checks run,
                // 60s once settled, paused while the app is inactive).
                self.refreshGitState()
                self.syncLoadMonitor()
                self.syncAgentMonitors()
                await self.sweepSessions()
            }
        }
        timer.tolerance = 5
        sessionSweepTimer = timer

        GhosttyRuntime.shared.urlOpener = { [weak self] text in
            self?.openTerminalLink(text)
        }
    }

    // MARK: Terminal links

    /// Dispatches a link clicked in the terminal: web URLs open in the
    /// browser (loopback hosts rewritten to the remote), file-ish matches
    /// are fetched from the session's machine and shown in Quick Look.
    func openTerminalLink(_ text: String) {
        switch TerminalLink.classify(text) {
        case .web(let url):
            openTerminalURL(url)
        case .email(let url):
            Platform.open(url)
        case .remoteFile(let path):
            previewRemoteFile(path)
        case nil:
            break
        }
    }

    /// Opens a URL clicked in the terminal. Loopback URLs are rewritten to
    /// the attached session's remote host first — "listening on
    /// http://localhost:3000" printed by a remote dev server should open the
    /// remote's port 3000 in the local browser, not the Mac's.
    func openTerminalURL(_ url: URL) {
        guard LocalhostURLRewriter.isRewritable(url),
              let project = attachment.project else {
            Platform.open(url)
            return
        }
        let alias = project.workspace.opaqueID
        let savedHost = hosts.first { $0.alias == alias }
        // A session on this Mac: localhost already is the right machine
        // (and a server bound to 127.0.0.1 answers under no other name).
        if let savedHost, isThisMac(savedHost) {
            Platform.open(url)
            return
        }
        let host = SSHHostNameResolver.browserHost(alias: alias, host: savedHost)
        Platform.open(LocalhostURLRewriter.rewrite(url, remoteHost: host) ?? url)
    }

    // MARK: Remote file preview

    /// Transient status/error for a file-link preview fetch.
    private(set) var previewNotice: String?
    private var previewTask: Task<Void, Never>?
    private var previewNoticeTask: Task<Void, Never>?

    /// Fetches a file the user clicked in the terminal into the OS temp
    /// area and shows it in Quick Look. One fetch at a time; repeat clicks
    /// during a fetch are ignored.
    func previewRemoteFile(_ path: String) {
        guard previewTask == nil,
              let session = selectedSession,
              let project = projects.first(where: { $0.id == session.projectID }) else { return }
        let name = (path as NSString).lastPathComponent
        previewNoticeTask?.cancel()
        previewNotice = "Fetching \u{201C}\(name)\u{201D} from \(project.workspace.opaqueID)…"
        previewTask = Task { [provider] in
            defer { self.previewTask = nil }
            do {
                let local = try await provider.fetchPreviewFile(
                    linkPath: path, for: session, project: project)
                self.previewNotice = nil
                QuickLookPreviewer.shared.preview(local)
            } catch {
                self.showPreviewNotice(error.localizedDescription)
            }
        }
    }

    private func showPreviewNotice(_ message: String) {
        previewNotice = message
        previewNoticeTask?.cancel()
        previewNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self.previewNotice = nil
        }
    }

    // MARK: Startup

    private func bootstrap() async {
        var loadedHosts: [SSHHost]?
        do {
            let state = try await store.load()
            projects = state.projects
            tombstones = state.tombstones
            sessionOrder = state.sessionOrder
            collapsedProjects = state.collapsedProjectIDs
            restoredSelection = state.lastSelectedSessionID
            loadedHosts = state.hosts
            unreadableHosts = (state.unreadableHosts, state.unreadableHostAliases)
            if !state.unreadableHosts.isEmpty {
                ghosttyLogger.error("\(state.unreadableHosts.count, privacy: .public) host record(s) in state.json couldn't be read; kept as they are")
            }
            cloudSync.restore(state.sync)
        } catch ProjectStoreError.corruptState(let backupPath) {
            cloudSync.restore(nil)
            alert = AppAlert(
                title: "Settings Reset",
                message: "Relay's local configuration was unreadable and has been moved to:\n\(backupPath)\n\nYour remote sessions are unaffected."
            )
        } catch {
            alert = AppAlert(title: "Couldn't Load Settings", message: error.localizedDescription)
            cloudSync.restore(nil)
        }
        await loadHosts(loadedHosts)
        // Record the hosts and projects for sync (the first launch with
        // sync: all of them), keeping the selection to restore on disk.
        persist(lastSelected: restoredSelection)
        if syncEnabled { cloudSync.start() }
        #if os(iOS)
        await waitUntilOnScreen()
        #endif
        await refreshRemotes()
        // All projects are visible (expanded) in the sidebar, so reconcile
        // each once at launch; restore the last-selected session when found
        // (selection triggers reattachment).
        // Restored as soon as its project has been read, and only while
        // nothing is selected: a slow or unreachable host further down
        // the list must not hold it back, nor take the user away from a
        // session they've picked meanwhile.
        for project in projects {
            await refreshSessions(for: project)
            if let restored = restoredSelection,
               sessions[project.id]?.contains(where: { $0.id == restored }) == true {
                restoredSelection = nil
                // Let the sidebar finish inserting rows before applying selection.
                try? await Task.sleep(for: .milliseconds(100))
                if selectedSessionIDs.isEmpty { selectedSessionID = restored }
            }
        }
        restoredSelection = nil
    }

    private func applicationDidActivate() {
        isAppActive = true
        // Known hosts, saved passwords and the GitHub sign-in may have
        // changed meanwhile (in a terminal, or synced from another device).
        knownHostsCache = nil
        builtInSSH?.hostsChanged()
        cloudSync.fetchIfStale()
        if case .notConnected = gitHub, GitHubTokenStore.load() != nil {
            Task { await recheckGitHubAuth() }
        }
        // Back on the session: its notification has been seen.
        if let id = selectedSessionID { agentNotifier.clear(id) }
        Task { await refreshRemotes() }
        // The project in use right away; the 30s sweep covers the rest.
        if let project = selectedProject {
            Task { await refreshSessions(for: project) }
        }
        // PR polling pauses while inactive; catch up right away on return.
        refreshPRStatus()
        syncLoadMonitor()
        syncAgentMonitors()
        markSelectedAgentSeen()
    }

    // MARK: Hosts

    /// Installs the persisted host list. State from before Relay owned its
    /// hosts has none: every host a project uses is imported from
    /// `~/.ssh/config` (same alias, so projects keep working untouched).
    private func loadHosts(_ loaded: [SSHHost]?) async {
        guard let hostRegistry else { return }
        if let loaded {
            hosts = loaded
        } else {
            var imported: [SSHHost] = []
            for project in projects where project.workspace.provider == .sshTmux {
                let alias = project.workspace.opaqueID
                guard !imported.contains(where: { $0.alias == alias }), SSHHost.isValidAlias(alias) else { continue }
                imported += SSHConfigImporter.importHosts(
                    alias: alias, existing: Set(imported.map(\.alias)), evaluate: SSHConfigImporter.effectiveConfig)
            }
            hosts = imported
            ghosttyLogger.info("migrated \(imported.count, privacy: .public) hosts from ssh config")
        }
        hostRegistry.setHosts(hosts)
        if loaded == nil { persist() }
    }

    func host(for workspace: WorkspaceRef) -> SSHHost? {
        hosts.first { $0.workspace == workspace }
    }

    /// Projects living on the host (a host in use can't be removed).
    func projects(on host: SSHHost) -> [Project] {
        projects.filter { $0.workspace == host.workspace }
    }

    /// Adds or replaces (by alias) a host and applies it to every
    /// connection from now on. Live terminals keep their connection.
    func saveHost(_ host: SSHHost, password: String?) async {
        if let index = hosts.firstIndex(where: { $0.alias == host.alias }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        if case .password = host.auth {
            if let password, !password.isEmpty { SSHPasswordStore.save(password, alias: host.alias) }
        } else {
            SSHPasswordStore.delete(alias: host.alias)
        }
        hostRegistry?.setHosts(hosts)
        persist()
        await refreshRemotes()
    }

    // MARK: Relay keys

    var keyStore: (any SSHKeyStore)? { builtInSSH?.keyStore }

    /// The flow that puts a Relay key on a host (nil without the built-in
    /// client).
    func relayKeySetup() -> RelayKeySetup? {
        guard let builtInSSH, let store = builtInSSH.keyStore else { return nil }
        let registry = hostRegistry
        return RelayKeySetup(
            store: store, pool: builtInSSH.pool, trustedHostsFile: builtInSSH.trustedHostsFile,
            hosts: { registry?.host(alias: $0) })
    }

    /// The Relay key `host` signs in with on this device, if it has it.
    func relayKey(for host: SSHHost) -> SSHKeyInfo? {
        guard let id = host.auth.storedKeyID else { return nil }
        return keyStore?.key(id: id)
    }

    /// Why Relay can't connect to a saved host on this device as it's set
    /// up (its Relay key isn't here, no password saved, a key file it can't
    /// read…), or nil. Such a host "needs connection" here.
    func connectionProblem(_ host: SSHHost) -> String? {
        builtInSSH?.setupProblem(for: host.alias)
    }

    func needsConnection(_ host: SSHHost) -> Bool {
        connectionProblem(host) != nil
    }

    /// Test Connection, with the host's settings as they stand in the
    /// editor (`password` for a password host not saved yet).
    func testConnection(_ host: SSHHost, password: String?) async -> SSHConnectionTest.Outcome {
        guard let builtInSSH else { return .unreachable("Relay can\u{2019}t connect to hosts here.") }
        let registry = hostRegistry
        return await SSHConnectionTest.run(
            host: host, password: password ?? SSHPasswordStore.load(alias: host.alias),
            hosts: { registry?.host(alias: $0) }, pool: builtInSSH.pool, keyStore: builtInSSH.keyStore)
    }

    /// Trusts the host key the built-in client was shown for `host`.
    func trustHostKey(_ presentedKey: String, for host: SSHHost) throws {
        guard let file = builtInSSH?.trustedHostsFile else { return }
        try KnownHosts.trust(host: host.hostname, port: host.port ?? 22, presentedKey: presentedKey, in: file)
        builtInSSH?.hostsChanged()
        // The host's record now carries the key to the other devices.
        knownHostsCache = nil
        persist()
    }

    /// The keys in a saved host's authorized_keys.
    func authorizedKeys(on host: SSHHost) async throws -> [SSHKeyInstaller.AuthorizedKey] {
        guard let provider = provider as? SSHTmuxRuntimeProvider else { return [] }
        return try await provider.authorizedKeys(alias: host.alias)
    }

    func removeAuthorizedKey(_ key: SSHKeyInstaller.AuthorizedKey, from host: SSHHost) async throws {
        guard let provider = provider as? SSHTmuxRuntimeProvider else { return }
        try await provider.removeAuthorizedKey(alias: host.alias, publicKeyBlob: key.publicKeyBlob)
    }

    /// The hosts that connect through `host`.
    func hostsJumping(through host: SSHHost) -> [SSHHost] {
        hosts.filter { $0.proxyJump == host.alias }
    }

    /// Why `host` can't be removed, or nil when it can.
    func removalBlocker(for host: SSHHost) -> String? {
        let projectCount = projects(on: host).count
        if projectCount > 0 {
            return projectCount == 1 ? "A project uses this host." : "\(projectCount) projects use this host."
        }
        let dependents = hostsJumping(through: host).map(\.alias)
        if !dependents.isEmpty {
            return "\(dependents.joined(separator: ", ")) \(dependents.count == 1 ? "connects" : "connect") through this host."
        }
        return nil
    }

    func removeHost(_ host: SSHHost) async {
        guard removalBlocker(for: host) == nil else { return }
        hosts.removeAll { $0.alias == host.alias }
        SSHPasswordStore.delete(alias: host.alias)
        hostRegistry?.setHosts(hosts)
        persist()
        await refreshRemotes()
    }

    // MARK: Remotes

    func refreshRemotes() async {
        do {
            remotes = try await provider.discoverWorkspaces()
        } catch {
            alert = AppAlert(title: "Couldn't Read SSH Config", message: error.localizedDescription)
        }
        remotesLoaded = true
        syncLoadMonitor()
        syncAgentMonitors()
    }

    /// True when the project's host isn't in the host list. Only
    /// meaningful once discovery has completed (before that, nothing is
    /// "missing" — it just hasn't been found yet).
    func isRemoteMissing(_ project: Project) -> Bool {
        remotesLoaded && !remotes.contains { $0.id == project.workspace }
    }

    func refreshAll() async {
        await refreshRemotes()
        for project in projects {
            await refreshSessions(for: project)
        }
    }

    // MARK: Selection

    var selectedSession: RemoteSession? {
        guard let id = selectedSessionID else { return nil }
        for (_, list) in sessions {
            if let match = list.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    var selectedProject: Project? {
        guard let session = selectedSession else { return nil }
        return projects.first { $0.id == session.projectID }
    }

    /// Every selected session, in sidebar order.
    var selectedSessions: [RemoteSession] {
        guard !selectedSessionIDs.isEmpty else { return [] }
        return projects.flatMap { sessions[$0.id] ?? [] }.filter { selectedSessionIDs.contains($0.id) }
    }

    /// What a session row's context menu acts on, Finder-style: the whole
    /// selection when the row is part of a multiple selection, otherwise
    /// just that row (right-clicking outside the selection leaves it be).
    func contextTargets(for session: RemoteSession) -> [RemoteSession] {
        guard selectedSessionIDs.count > 1, selectedSessionIDs.contains(session.id) else { return [session] }
        let selected = selectedSessions
        return selected.count > 1 ? selected : [session]
    }

    private func selectionDidChange(from oldValue: SessionID?) {
        guard selectedSessionID != oldValue else { return }
        // Selection changes arrive mid view-update (List binding); defer the
        // attach/detach side effects out of the current render pass.
        let skipPersist = preserveSelectionOnDisk
        Task { @MainActor in
            // The departing session stays warm: its connection, scrollback,
            // and live title survive in the background — only presentation
            // (rendering + focus) is handed over.
            if let old = oldValue, let previous = self.attachmentPool[old] {
                self.carryOverLiveTitle(for: old)
                previous.setPresented(false)
            }
            self.syncLoadMonitor()
            if let selected = self.selectedSessionID {
                self.markedUnread.remove(selected)
                self.agentNotifier.clear(selected)
            }
            self.markSelectedAgentSeen()
            guard let session = self.selectedSession,
                  let project = self.projects.first(where: { $0.id == session.projectID }) else {
                if !skipPersist { self.persist() }
                return
            }
            self.warmAttachment(for: session, project: project)
            self.refreshGitState()
            // Switching to a session with a known PR refreshes its status
            // immediately (first visits have no cached git state yet — the
            // git-state chain above does their first fetch instead).
            self.refreshPRStatusNow()
            if self.diffTrayVisible {
                self.diff = nil
                self.diffError = nil
                Task { await self.loadDiff() }
            }
            self.persist()
        }
    }

    /// Ensures the session has a live controller: first visit attaches,
    /// revisits are instant, and a controller that ran out of retries (or
    /// saw its session end) gets a fresh start.
    private func warmAttachment(for session: RemoteSession, project: Project) {
        let controller: TerminalAttachmentController
        if let existing = attachmentPool[session.id] {
            controller = existing
            switch existing.phase {
            case .ended, .failed, .idle:
                existing.attach(session: session, project: project)
            default:
                break
            }
        } else {
            controller = TerminalAttachmentController(provider: provider)
            // Push live titles into the observed session list as they arrive,
            // so a connected session's caption tracks its terminal in real
            // time — even while it's a warm background tab, not just on focus.
            controller.onLiveTitleChange = { [weak self] _ in
                self?.carryOverLiveTitle(for: session.id)
            }
            attachmentPool[session.id] = controller
            controller.attach(session: session, project: project)
        }
        controller.setPresented(true)
        warmOrder.removeAll { $0 == session.id }
        warmOrder.append(session.id)
        trimWarmPool()
    }

    private func trimWarmPool() {
        while warmOrder.count > warmAttachmentCap {
            guard let victim = warmOrder.first(where: { $0 != selectedSessionID }) else { break }
            dropAttachment(for: victim)
        }
    }

    /// Tears down one warm attachment. Detach-only: the remote session
    /// keeps running unless an archive/kill did that separately.
    private func dropAttachment(for sessionID: SessionID) {
        warmOrder.removeAll { $0 == sessionID }
        guard let controller = attachmentPool[sessionID] else { return }
        carryOverLiveTitle(for: sessionID)
        controller.detach()
        attachmentPool[sessionID] = nil
    }

    /// User-facing "Disconnect": drop the warm ssh attachment without
    /// touching the remote session. A selected session is deselected first.
    func disconnectSession(_ session: RemoteSession) {
        disconnectSessions([session])
    }

    func disconnectSessions(_ sessions: [RemoteSession]) {
        if let id = selectedSessionID, sessions.contains(where: { $0.id == id }) {
            selectedSessionID = nil
        }
        for session in sessions { dropAttachment(for: session.id) }
    }

    /// The connection phase for a session's warm controller, or nil when
    /// the session has no live attachment (grey dot).
    func connectionPhase(for sessionID: SessionID) -> TerminalAttachmentController.Phase? {
        guard let controller = attachmentPool[sessionID] else { return nil }
        if case .idle = controller.phase { return nil }
        return controller.phase
    }

    // MARK: Host reachability

    enum HostStatus {
        case online, offline, unknown
    }

    /// Outcome of the most recent operation that dialed a host.
    private struct HostContact {
        var reachable: Bool
        var at: Date
    }

    private var hostContact: [WorkspaceRef: HostContact] = [:]

    private func noteHostContact(_ workspace: WorkspaceRef, ok: Bool) {
        hostContact[workspace] = HostContact(reachable: ok, at: Date())
    }

    /// Whether the host is online, for the project row's dot. Evidence-based
    /// rather than actively probed: a live attachment proves it, otherwise
    /// the last contact's outcome (explicit refreshes and the 30s title
    /// sweep both dial the host) decides. No contact yet means unknown.
    func hostStatus(for workspace: WorkspaceRef) -> HostStatus {
        for controller in attachmentPool.values
        where controller.project?.workspace == workspace {
            if case .attached = controller.phase { return .online }
        }
        guard let contact = hostContact[workspace] else { return .unknown }
        return contact.reachable ? .online : .offline
    }

    /// Live surface title for any warm-attached session (selected or not);
    /// cold sessions fall back to the 30s pane-title sweep.
    func liveTitle(for sessionID: SessionID) -> String? {
        guard let controller = attachmentPool[sessionID],
              case .attached = controller.phase else { return nil }
        let title = controller.terminalTitle
        return title.isEmpty ? nil : title
    }

    /// Copies a controller's live surface title into the observed session
    /// list. Called on every title change (so a connected background row
    /// updates in real time — `sessions` is tracked; the controller's title,
    /// read cross-object, is not) and on backgrounding/dropping an attachment
    /// (so the caption never downgrades to a stale poll).
    private func carryOverLiveTitle(for sessionID: SessionID) {
        guard let controller = attachmentPool[sessionID],
              case .attached = controller.phase,
              let session = controller.session else { return }
        let live = controller.terminalTitle
        guard !live.isEmpty else { return }
        guard var list = sessions[session.projectID],
              let index = list.firstIndex(where: { $0.id == session.id }) else { return }
        list[index].paneTitle = live
        sessions[session.projectID] = list
    }

    /// Closing the window tears down every warm attachment (no window → no
    /// connections), and must not clobber the last-selected session stored
    /// for next-launch restore.
    func windowDidClose() {
        preserveSelectionOnDisk = true
        selectedSessionID = nil
        preserveSelectionOnDisk = false
        for id in warmOrder.reversed() { dropAttachment(for: id) }
    }

    // MARK: Sessions

    /// Incremented whenever local mutations (create/rename/archive/kill)
    /// change what a concurrent read's results would mean, and when an
    /// explicit refresh starts; reads that began before are dropped.
    private var sessionListEpoch: [ProjectID: Int] = [:]

    private func bumpSessionEpoch(_ projectID: ProjectID) {
        sessionListEpoch[projectID, default: 0] += 1
    }

    func refreshSessions(for project: Project) async {
        guard !sessionsLoading.contains(project.id) else { return }
        sessionsLoading.insert(project.id)
        defer { sessionsLoading.remove(project.id) }
        // Supersedes a background sweep's read that's already under way.
        bumpSessionEpoch(project.id)
        let epoch = sessionListEpoch[project.id, default: 0]
        do {
            let list = try await provider.listSessions(for: project)
            noteHostContact(project.workspace, ok: true)
            applySessionList(list, for: project, readAt: epoch)
        } catch {
            noteHostContact(project.workspace, ok: false)
            sessionErrors[project.id] = error.localizedDescription
        }
    }

    /// Makes a fresh read the project's rows (see
    /// `SessionOrdering.reconcile`), unless the list changed locally, or a
    /// newer read started, after it began (`epoch`).
    private func applySessionList(_ list: [RemoteSession], for project: Project, readAt epoch: Int) {
        guard sessionListEpoch[project.id, default: 0] == epoch,
              projects.contains(where: { $0.id == project.id }) else { return }
        let merged = SessionOrdering.reconcile(
            previous: sessions[project.id] ?? [],
            fresh: list,
            order: sessionOrder,
            keeping: selectedSessionID)
        if merged.sessions != sessions[project.id] { sessions[project.id] = merged.sessions }
        sessionErrors[project.id] = nil
        // Order entries for sessions that vanished remotely are dead;
        // pruning here (where project membership is still known) keeps
        // the overlay from accreting stale IDs.
        if !merged.vanished.isEmpty {
            sessionOrder.removeAll { merged.vanished.contains($0) }
            // Out of a multiple selection, so batch actions and the
            // count shown match the rows. (A session on screen keeps its
            // row and stays selected: its "session ended" overlay explains it.)
            if selectedSessionIDs.count > 1 { deselect(merged.vanished) }
            persist()
        }
        // Warm attachments for this project's vanished sessions have
        // nothing to reattach to; drop them (the selected one keeps its
        // controller so the "session ended" overlay can appear).
        let liveIDs = Set(list.map(\.id))
        for id in warmOrder
        where id != selectedSessionID && !liveIDs.contains(id)
            && attachmentPool[id]?.session?.projectID == project.id {
            dropAttachment(for: id)
        }
    }

    private var sessionSweepRunning = false

    /// Re-reads every project's sessions in the background and applies them
    /// whole, so changes made elsewhere — renames, sessions created or ended
    /// on another device or on the host — show up without a manual refresh.
    /// Quiet: no spinner, and a failed read leaves the rows (and any error
    /// shown) as they are.
    private func sweepSessions() async {
        // A slow host can make one pass outlast the timer; never overlap,
        // or an older read could land after a newer one.
        guard Platform.hasVisibleWindow, !sessionSweepRunning else { return }
        sessionSweepRunning = true
        defer { sessionSweepRunning = false }
        for project in projects {
            guard !sessionsLoading.contains(project.id), !isRemoteMissing(project) else { continue }
            let epoch = sessionListEpoch[project.id, default: 0]
            do {
                let list = try await provider.listSessions(for: project)
                noteHostContact(project.workspace, ok: true)
                applySessionList(list, for: project, readAt: epoch)
            } catch {
                // The sweep doubles as the host-reachability heartbeat, so a
                // failed dial is recorded, not just skipped.
                noteHostContact(project.workspace, ok: false)
            }
        }
    }

    /// The harness picked last time a session was created in each project
    /// (device-local; UserDefaults keyed by project UUID), so mixing and
    /// matching doesn't mean re-picking every time.
    struct StoredStartChoice: Codable {
        var kind: String // "default" | "shell" | "preset" | "custom"
        var presetID: String?
        var customLaunch: String?
        var customCleanup: String?
    }
    private static let startChoicesKey = "sessionStartChoices"

    func lastStartChoice(for projectID: ProjectID) -> StoredStartChoice? {
        guard let data = UserDefaults.standard.data(forKey: Self.startChoicesKey),
              let choices = try? JSONDecoder().decode([String: StoredStartChoice].self, from: data)
        else { return nil }
        return choices[projectID.uuid.uuidString]
    }

    func rememberStartChoice(_ choice: StoredStartChoice, for projectID: ProjectID) {
        var choices: [String: StoredStartChoice] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.startChoicesKey),
           let existing = try? JSONDecoder().decode([String: StoredStartChoice].self, from: data) {
            choices = existing
        }
        choices[projectID.uuid.uuidString] = choice
        if let data = try? JSONEncoder().encode(choices) {
            UserDefaults.standard.set(data, forKey: Self.startChoicesKey)
        }
    }

    /// Records a session the New Session sheet just created, selects it
    /// (attaching the terminal), and reconciles with the remote.
    func noteCreatedSession(_ session: RemoteSession, project: Project) {
        bumpSessionEpoch(project.id)
        sessions[project.id, default: []].append(session)
        // New sessions take the bottom slot of their project's list and stay
        // there across refreshes.
        sessionOrder.removeAll { $0 == session.id }
        sessionOrder.append(session.id)
        selectedSessionID = session.id
        syncAgentMonitors()
        Task { await refreshSessions(for: project) }
    }

    // MARK: Git state & diff tray

    /// Latest git snapshot per session (cached so revisits render
    /// immediately). Only the selected session is actively refreshed.
    private(set) var gitStates: [SessionID: SessionGitState] = [:]
    private var gitStateTask: Task<Void, Never>?

    var diffTrayVisible = false {
        didSet {
            guard diffTrayVisible, !oldValue else { return }
            Task { await self.loadDiff() }
        }
    }
    private(set) var diff: SessionGitDiff?
    private(set) var diffLoading = false
    private(set) var diffError: String?

    func gitState(for sessionID: SessionID) -> SessionGitState? {
        gitStates[sessionID]
    }

    /// Refreshes the selected session's git snapshot. Serialized (a slow
    /// probe never stacks); results for a stale selection still land in the
    /// cache but never clobber another session's entry.
    func refreshGitState() {
        guard gitStateTask == nil,
              let session = selectedSession,
              let project = projects.first(where: { $0.id == session.projectID }),
              !isRemoteMissing(project) else { return }
        gitStateTask = Task { [provider] in
            defer {
                self.gitStateTask = nil
                // The selection moved on while this probe ran: the new
                // session's turn now, not at the next tick.
                if self.selectedSessionID != session.id { self.refreshGitState() }
            }
            let state: SessionGitState?
            do {
                state = try await provider.gitState(for: session, project: project)
            } catch {
                // A transient failure (the host didn't answer this time)
                // keeps what was known.
                return
            }
            guard let state else {
                self.gitStates[session.id] = nil
                self.prStatuses[session.id] = nil
                return
            }
            self.gitStates[session.id] = state
            if state.pullRequest == nil {
                self.prStatuses[session.id] = nil
            } else if self.prStatuses[session.id] == nil {
                // Newly discovered PR (or first look at this session): fetch
                // now. Once a status is cached, cadence belongs to the
                // adaptive poll below — re-fetching here would pin polling
                // to this chain's 30s tick and defeat the backoff.
                self.refreshPRStatus()
            } else {
                self.armPRPoll()
            }
        }
    }

    /// Counts diff loads, so only the latest one's result is shown: a
    /// slow host's answer for a session the user has since left must not
    /// land under another session's header.
    private var diffLoadGeneration = 0

    func loadDiff() async {
        diffLoadGeneration += 1
        let generation = diffLoadGeneration
        guard let session = selectedSession,
              let project = projects.first(where: { $0.id == session.projectID }) else {
            diffLoading = false
            return
        }
        diffLoading = true
        diffError = nil
        let result: Result<SessionGitDiff?, Error>
        do {
            result = .success(try await provider.gitDiff(for: session, project: project))
        } catch {
            result = .failure(error)
        }
        guard generation == diffLoadGeneration, selectedSessionID == session.id else { return }
        diffLoading = false
        switch result {
        case .success(let loaded): diff = loaded
        case .failure(let error): diffError = error.localizedDescription
        }
    }

    /// Fetches one file's full working-tree content from the selected
    /// session's repo, for the diff tray's full-file mode. Returns nil when
    /// the file can't be fetched (missing, too large, unreachable) — the
    /// caller falls back to the hunks-only view.
    func fullFileContent(repoRelativePath: String) async -> String? {
        guard let session = selectedSession,
              let project = projects.first(where: { $0.id == session.projectID }) else { return nil }
        return try? await provider.gitFileContent(
            for: session, project: project, repoRelativePath: repoRelativePath)
    }

    // MARK: Machine load

    /// Recent load samples per machine, oldest first, trimmed to
    /// `loadHistoryWindow`. In memory only: history is a nicety, not state.
    private(set) var machineLoadHistory: [WorkspaceRef: [MachineLoadSample]] = [:]
    /// Machines whose latest sampling run failed; their pill hides until a
    /// sample arrives again (best-effort feature — never an error UI).
    private var machineLoadUnavailable: Set<WorkspaceRef> = []
    /// True while the load details popover is open: sampling switches to
    /// the provider's fast, detailed mode.
    var loadDetailsVisible = false {
        didSet {
            guard loadDetailsVisible != oldValue else { return }
            syncLoadMonitor()
        }
    }
    private var loadMonitorTask: Task<Void, Never>?
    private var loadMonitorKey: LoadMonitorKey?
    private struct LoadMonitorKey: Equatable {
        var workspace: WorkspaceRef
        var detailed: Bool
    }
    static let loadHistoryWindow: TimeInterval = 30 * 60
    /// A run that produces no sample for this long is considered hung
    /// (e.g. the network dropped mid-stream) and is replaced.
    private static let loadStallTimeout: TimeInterval = 45
    /// Samples older than this aren't shown (the machine may have changed
    /// a lot since; better no pill than a misleading one).
    private static let loadDisplayMaxAge: TimeInterval = 120

    /// The selected session's machine's recent samples, or nil when there's
    /// nothing current to show.
    var selectedMachineLoad: [MachineLoadSample]? {
        guard let workspace = selectedProject?.workspace,
              !machineLoadUnavailable.contains(workspace),
              let history = machineLoadHistory[workspace],
              let latest = history.last,
              Date().timeIntervalSince(latest.date) < Self.loadDisplayMaxAge
        else { return nil }
        return history
    }

    /// Samples only the currently viewed machine, only while the app is
    /// active — and in detailed mode only while the popover is open.
    /// Idempotent: a no-op when the right monitor is already running.
    private func syncLoadMonitor() {
        var desired: LoadMonitorKey?
        if isAppActive, let project = selectedProject, !isRemoteMissing(project) {
            desired = LoadMonitorKey(workspace: project.workspace, detailed: loadDetailsVisible)
        }
        guard desired != loadMonitorKey else { return }
        loadMonitorTask?.cancel()
        loadMonitorTask = nil
        loadMonitorKey = desired
        guard let desired else { return }
        loadMonitorTask = Task { await self.runLoadMonitor(desired) }
    }

    /// Back-to-back bounded provider runs: a run that ends cleanly restarts
    /// right away; failures hide the pill and back off (30s … 5 min).
    private func runLoadMonitor(_ key: LoadMonitorKey) async {
        var failures = 0
        while !Task.isCancelled {
            let ok = await runLoadSampling(key)
            guard !Task.isCancelled else { return }
            if ok {
                failures = 0
            } else {
                failures += 1
                machineLoadUnavailable.insert(key.workspace)
            }
            let delay = ok ? 1 : min(30 * (1 << min(failures - 1, 4)), 300)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// One provider run under a stall watchdog. True when it ended cleanly
    /// having delivered at least one sample.
    private func runLoadSampling(_ key: LoadMonitorKey) async -> Bool {
        let started = Date()
        let provider = self.provider
        let run = Task {
            do {
                try await provider.monitorMachineLoad(workspace: key.workspace, detailed: key.detailed) { sample in
                    Task { @MainActor in self.recordLoadSample(sample, for: key.workspace) }
                }
                return true
            } catch {
                return false
            }
        }
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                let last = max(self.machineLoadHistory[key.workspace]?.last?.date ?? started, started)
                if Date().timeIntervalSince(last) > Self.loadStallTimeout {
                    run.cancel()
                    return
                }
            }
        }
        let finishedCleanly = await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            run.cancel()
        }
        watchdog.cancel()
        let lastSample = machineLoadHistory[key.workspace]?.last?.date ?? .distantPast
        return finishedCleanly && lastSample >= started
    }

    private func recordLoadSample(_ sample: MachineLoadSample, for workspace: WorkspaceRef) {
        var history = machineLoadHistory[workspace] ?? []
        history.append(sample)
        let cutoff = sample.date.addingTimeInterval(-Self.loadHistoryWindow)
        if let firstKept = history.firstIndex(where: { $0.date >= cutoff }), firstKept > 0 {
            history.removeFirst(firstKept)
        }
        machineLoadHistory[workspace] = history
        machineLoadUnavailable.remove(workspace)
    }

    // MARK: Agent status

    /// Latest agent report per session, by backend ID, per machine — from
    /// one watch stream per machine with projects (all sessions, attached
    /// or not). In memory only.
    private var agentReports: [WorkspaceRef: [String: AgentStatusReport]] = [:]
    /// When each machine's stream last delivered (snapshot or heartbeat);
    /// reports from a stream silent for `agentReportMaxAge` aren't shown.
    private var agentReportsReceived: [WorkspaceRef: Date] = [:]
    private var agentMonitorTasks: [WorkspaceRef: Task<Void, Never>] = [:]
    /// The `since` of the finished turn the user has looked at, per session:
    /// a done/failed report with any other `since` is unseen.
    private var agentSeen: [SessionID: Date] = [:]
    private static let agentReportMaxAge: TimeInterval = 60
    private static let agentStallTimeout: TimeInterval = 60
    /// Bumped on every applied snapshot, so views can cheaply re-derive.
    private(set) var agentStatusRevision = 0
    /// Turns each machine's reports into "needs you" / "finished" alerts.
    private var agentAlerts: [WorkspaceRef: AgentAlertTracker] = [:]
    let agentNotifier = AgentNotifier()
    #if os(macOS)
    let keepAwake = KeepAwake()
    #endif
    /// The host key this Mac's own sshd presents (Remote Login on), or nil.
    /// Hosts trusted with this key are this Mac (`isThisMac`). The
    /// observable copy of `LocalSSHIdentity.hostKey`, set only by
    /// `refreshLocalIdentity`, so views update when Remote Login changes.
    var localHostKey: String?

    /// What the agent in this session is doing, or nil (no agent, no
    /// reporter, or no current data).
    func agentActivity(for session: RemoteSession) -> AgentActivity? {
        guard let project = projects.first(where: { $0.id == session.projectID }),
              let received = agentReportsReceived[project.workspace],
              Date().timeIntervalSince(received) < Self.agentReportMaxAge,
              let report = agentReports[project.workspace]?[session.backendID]
        else { return nil }
        return report.effectiveActivity()
    }

    /// Sessions the user marked unread (sidebar context menu), Mail-style:
    /// cleared when the session is next selected. Persisted.
    private(set) var markedUnread: Set<SessionID> = AppModel.loadMarkedUnread() {
        didSet {
            UserDefaults.standard.set(markedUnread.map(\.uuid.uuidString), forKey: Self.markedUnreadKey)
        }
    }
    private static let markedUnreadKey = "markedUnreadSessions"

    private static func loadMarkedUnread() -> Set<SessionID> {
        let strings = UserDefaults.standard.stringArray(forKey: markedUnreadKey) ?? []
        return Set(strings.compactMap(UUID.init(uuidString:)).map { SessionID(uuid: $0) })
    }

    func setMarkedUnread(_ unread: Bool, for session: RemoteSession) {
        setMarkedUnread(unread, for: [session])
    }

    func setMarkedUnread(_ unread: Bool, for sessions: [RemoteSession]) {
        let ids = sessions.map(\.id)
        if unread { markedUnread.formUnion(ids) } else { markedUnread.subtract(ids) }
        guard !unread else { return }
        for session in sessions {
            if let activity = agentActivity(for: session),
               activity.state == .done || activity.state == .failed {
                agentSeen[session.id] = activity.since
            }
        }
    }

    /// A finished (or failed) turn the user hasn't looked at yet, or a
    /// session marked unread.
    func agentUnseen(for session: RemoteSession) -> Bool {
        if markedUnread.contains(session.id) { return true }
        guard let activity = agentActivity(for: session),
              activity.state == .done || activity.state == .failed
        else { return false }
        return agentSeen[session.id] != activity.since
    }

    /// Sessions in the project whose agent is waiting on the user.
    func agentsNeedingYou(in project: Project) -> Int {
        (sessions[project.id] ?? []).filter { agentActivity(for: $0)?.state == .blocked }.count
    }

    /// Looking at a session (app active, session selected) marks its
    /// finished turn as seen.
    private func markSelectedAgentSeen() {
        guard isAppActive, let session = selectedSession,
              let activity = agentActivity(for: session),
              activity.state == .done || activity.state == .failed,
              agentSeen[session.id] != activity.since
        else { return }
        agentSeen[session.id] = activity.since
    }

    /// One watch stream per machine that has projects, for as long as the
    /// app runs — "needs you" matters most while the user is elsewhere.
    /// Idempotent.
    func syncAgentMonitors() {
        var desired = Set<WorkspaceRef>()
        for project in projects where !isRemoteMissing(project) && !connectionsSuspended {
            desired.insert(project.workspace)
        }
        for (workspace, task) in agentMonitorTasks where !desired.contains(workspace) {
            task.cancel()
            agentMonitorTasks[workspace] = nil
            agentReports[workspace] = nil
            agentReportsReceived[workspace] = nil
            agentAlerts[workspace] = nil
        }
        for workspace in desired where agentMonitorTasks[workspace] == nil {
            agentMonitorTasks[workspace] = Task { await self.runAgentMonitor(workspace) }
        }
    }

    /// Back-to-back bounded runs; failures back off (30s … 5 min).
    private func runAgentMonitor(_ workspace: WorkspaceRef) async {
        // The probe upgrades already-installed reporter files to this
        // build's version, so new hooks reach the machine's agents without
        // waiting for the New Session sheet.
        await refreshAgentReporterStatus(workspace)
        var failures = 0
        while !Task.isCancelled {
            let ok = await runAgentWatch(workspace)
            guard !Task.isCancelled else { return }
            failures = ok ? 0 : failures + 1
            let delay = ok ? 1 : min(30 * (1 << min(failures - 1, 4)), 300)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// One provider run under a stall watchdog (the remote loop heartbeats
    /// every ~20s). True when it ended cleanly having delivered data.
    private func runAgentWatch(_ workspace: WorkspaceRef) async -> Bool {
        let started = Date()
        let provider = self.provider
        let run = Task {
            do {
                try await provider.monitorAgentStatus(workspace: workspace) { snapshot in
                    Task { @MainActor in self.applyAgentSnapshot(snapshot, for: workspace) }
                }
                return true
            } catch {
                return false
            }
        }
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                let last = max(self.agentReportsReceived[workspace] ?? started, started)
                if Date().timeIntervalSince(last) > Self.agentStallTimeout {
                    run.cancel()
                    return
                }
            }
        }
        let finishedCleanly = await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            run.cancel()
        }
        watchdog.cancel()
        return finishedCleanly && (agentReportsReceived[workspace] ?? .distantPast) >= started
    }

    private func applyAgentSnapshot(_ snapshot: [AgentStatusReport], for workspace: WorkspaceRef) {
        guard agentMonitorTasks[workspace] != nil else { return }
        agentReportsReceived[workspace] = Date()
        let byID = Dictionary(snapshot.map { ($0.backendID, $0.settled) }, uniquingKeysWith: { first, _ in first })
        guard byID != agentReports[workspace] else { return }
        agentReports[workspace] = byID
        agentStatusRevision &+= 1
        postAgentAlerts(byID, for: workspace)
        // The stream carries pane titles too: fresher than the 30s sweep.
        for project in projects where project.workspace == workspace {
            guard var list = sessions[project.id] else { continue }
            var changed = false
            for index in list.indices {
                // Empty clears, as in the 30s sweep — the two writers must
                // agree or the caption flips between them.
                guard let report = byID[list[index].backendID] else { continue }
                let title: String? = report.paneTitle.isEmpty ? nil : report.paneTitle
                if list[index].paneTitle != title {
                    list[index].paneTitle = title
                    changed = true
                }
            }
            if changed { sessions[project.id] = list }
        }
        markSelectedAgentSeen()
    }

    /// Notifies about agents that need the user or finished a turn, except
    /// in the session the user is looking at.
    private func postAgentAlerts(_ reports: [String: AgentStatusReport], for workspace: WorkspaceRef) {
        let alerts = agentAlerts[workspace, default: AgentAlertTracker()]
            .observe(reports.mapValues { $0.effectiveActivity() })
        guard !alerts.isEmpty else { return }
        for project in projects where project.workspace == workspace {
            for session in sessions[project.id] ?? [] {
                guard let alert = alerts[session.backendID],
                      !(isAppActive && selectedSessionID == session.id)
                else { continue }
                agentNotifier.post(alert, session: session, project: project,
                                   task: reports[session.backendID]?.agentTaskTitle)
            }
        }
    }

    // Reporter installation

    /// Per machine: each agent's CLI presence and global-reporter state.
    private(set) var agentReporterStatus: [WorkspaceRef: [CodingAgent: AgentReporterStatus]] = [:]
    private(set) var agentReporterProbing: Set<WorkspaceRef> = []
    private(set) var agentReporterInstalling: Set<WorkspaceRef> = []

    /// Whether new agent sessions load the reporter for themselves when no
    /// global one is installed (the New Session checkbox; remembered).
    var agentReporterPerSession: Bool = UserDefaults.standard.object(forKey: AppModel.agentReporterPerSessionKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(agentReporterPerSession, forKey: Self.agentReporterPerSessionKey) }
    }
    static let agentReporterPerSessionKey = "agentReporterPerSession"

    /// Re-reads the machine's reporter install state. Best-effort: on
    /// failure the previous answer stays (or none, which hides the line).
    func refreshAgentReporterStatus(_ workspace: WorkspaceRef) async {
        guard !agentReporterProbing.contains(workspace) else { return }
        agentReporterProbing.insert(workspace)
        defer { agentReporterProbing.remove(workspace) }
        if let status = try? await provider.probeAgentReporters(workspace: workspace), !status.isEmpty {
            agentReporterStatus[workspace] = status
        }
    }

    /// Installs the global reporter for one agent, then re-probes. Throws
    /// the provider's error for the caller to show inline.
    func installGlobalAgentReporter(_ workspace: WorkspaceRef, agent: CodingAgent) async throws {
        agentReporterInstalling.insert(workspace)
        defer { agentReporterInstalling.remove(workspace) }
        try await provider.installGlobalAgentReporter(workspace: workspace, agent: agent)
        await refreshAgentReporterStatus(workspace)
    }

    // MARK: GitHub connection & PR status

    /// Whether the app can talk to the GitHub API (powers the PR badge).
    /// Resolved at launch and on demand: the device-flow token from the
    /// keychain, validated with a live `/user` call before claiming
    /// "connected".
    private(set) var gitHub: GitHubConnection = .checking
    /// The validated token, held only in memory (the keychain stays its
    /// durable home).
    private var gitHubToken: String?
    var gitHubLoginPresented = false
    private(set) var gitHubLogin: GitHubLoginProgress?
    private var gitHubLoginTask: Task<Void, Never>?

    private(set) var prStatuses: [SessionID: PullRequestStatus] = [:]
    private var prStatusTask: Task<Void, Never>?
    /// The self-scheduling poll driving PR-status freshness. Adaptive: fast
    /// while the selected PR is settling, slow once quiet, dead while the
    /// app is inactive or no PR session is selected (each fetch schedules
    /// the next; the git-state chain re-arms it after selection changes).
    private var prPollTask: Task<Void, Never>?
    private var prPollTaskInterval: Duration = .zero
    /// Mirrors app activation; PR polling pauses while false.
    private(set) var isAppActive = Platform.isAppActive

    /// True while a PR-status fetch is in flight (the popover's refresh
    /// button shows a spinner).
    var prStatusRefreshing: Bool { prStatusTask != nil }

    func prStatus(for sessionID: SessionID) -> PullRequestStatus? {
        prStatuses[sessionID]
    }

    /// Poll cadence warranted by a status: checks running or mergeability
    /// computing deserve near-live updates; a settled PR just needs a
    /// slow heartbeat to notice new pushes/reviews.
    private func prPollInterval(for status: PullRequestStatus?) -> Duration {
        guard let status else { return .seconds(30) }
        return status.isSettling ? .seconds(10) : .seconds(60)
    }

    /// Ensures a poll is scheduled at (at least) the cadence the selected
    /// session's cached status warrants. Never lengthens an armed poll —
    /// the 30s git-state chain calls this repeatedly, and rescheduling a
    /// slow poll on every tick would reset its countdown forever.
    private func armPRPoll() {
        guard isAppActive, prStatusTask == nil else { return }
        let desired = prPollInterval(for: selectedSession.flatMap { prStatuses[$0.id] })
        if let task = prPollTask, !task.isCancelled, prPollTaskInterval <= desired { return }
        schedulePRPoll(after: desired)
    }

    private func schedulePRPoll(after interval: Duration) {
        prPollTask?.cancel()
        prPollTaskInterval = interval
        prPollTask = Task {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self.prPollTask = nil
            guard self.isAppActive else { return }
            self.refreshPRStatus()
        }
    }

    /// User-intent refresh (session switch, popover opening, the popover's
    /// refresh button): fetch immediately — even while the app is
    /// technically inactive, since an interaction just happened — then let
    /// the fetch re-derive the cadence.
    func refreshPRStatusNow() {
        prPollTask?.cancel()
        prPollTask = nil
        fetchPRStatus(requireActive: false)
    }

    func recheckGitHubAuth() async {
        gitHub = .checking
        gitHubToken = nil
        guard let stored = GitHubTokenStore.load() else {
            gitHub = .notConnected
            return
        }
        gitHub = await validatedConnection(token: stored)
        if gitHub.isConnected { refreshPRStatus() }
    }

    private func validatedConnection(token: String) async -> GitHubConnection {
        do {
            let login = try await GitHubAPIClient(token: token).viewerLogin()
            gitHubToken = token
            return .connected(login: login)
        } catch GitHubAPIClient.APIError.unauthorized {
            return .failed("GitHub rejected the saved sign-in (it may have been revoked). Log in again.")
        } catch {
            return .failed("Couldn't reach GitHub — check the connection and retry.")
        }
    }

    /// Starts the device flow (Relay's OAuth app) and polls until GitHub
    /// authorizes (token → keychain), the code expires, or the user closes
    /// the sheet.
    func beginGitHubLogin() {
        gitHubLoginTask?.cancel()
        gitHubLogin = .requesting
        gitHubLoginTask = Task {
            do {
                let flow = GitHubDeviceFlow()
                let auth = try await flow.begin()
                self.gitHubLogin = .waiting(
                    userCode: auth.userCode,
                    verificationURL: auth.verificationURL)
                var interval = auth.interval
                let deadline = ContinuousClock.now + .seconds(auth.expiresIn)
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    guard ContinuousClock.now < deadline else {
                        self.gitHubLogin = .failed("The code expired before it was entered. Try again.")
                        return
                    }
                    switch try await flow.poll(
                        deviceCode: auth.deviceCode,
                        currentInterval: interval
                    ) {
                    case .authorized(let token):
                        GitHubTokenStore.save(token)
                        self.gitHub = await self.validatedConnection(token: token)
                        self.gitHubLogin = nil
                        self.gitHubLoginPresented = false
                        self.refreshPRStatus()
                        return
                    case .pending(let retryAfter):
                        interval = retryAfter
                    case .denied:
                        self.gitHubLogin = .failed("Authorization was denied on GitHub.")
                        return
                    case .expired:
                        self.gitHubLogin = .failed("The code expired before it was entered. Try again.")
                        return
                    }
                }
            } catch is CancellationError {
                // Sheet closed; nothing to show.
            } catch let GitHubDeviceFlow.FlowError.badResponse(message) {
                self.gitHubLogin = .failed(message)
            } catch {
                self.gitHubLogin = .failed(error.localizedDescription)
            }
        }
    }

    func cancelGitHubLogin() {
        gitHubLoginTask?.cancel()
        gitHubLoginTask = nil
        gitHubLogin = nil
    }

    /// Removes the device-flow token from the keychain. (The grant itself
    /// stays listed on GitHub until revoked there.)
    func signOutGitHub() {
        GitHubTokenStore.delete()
        gitHubToken = nil
        prStatuses = [:]
        gitHub = .notConnected
    }

    /// Refreshes the selected session's PR status via the GitHub API.
    /// Serialized like `refreshGitState`; needs a connection and a detected
    /// PR. Transient failures keep the last status; a 401 flips the app
    /// into the auth-error state (a dead token reveals itself by failing).
    func refreshPRStatus() {
        fetchPRStatus(requireActive: true)
    }

    private func fetchPRStatus(requireActive: Bool) {
        guard prStatusTask == nil, isAppActive || !requireActive,
              case .connected = gitHub, let token = gitHubToken,
              let session = selectedSession,
              let pr = gitStates[session.id]?.pullRequest,
              let coords = GitHubRemote.pullCoordinates(from: pr.url) else { return }
        prStatusTask = Task {
            defer { prStatusTask = nil }
            do {
                let status = try await GitHubAPIClient(token: token).pullStatus(
                    owner: coords.owner, repo: coords.repo, number: coords.number)
                self.prStatuses[session.id] = status
                self.schedulePRPoll(after: self.prPollInterval(for: status))
            } catch GitHubAPIClient.APIError.unauthorized {
                // No reschedule: polling resumes via recheck/login.
                self.gitHubToken = nil
                self.gitHub = .failed("GitHub rejected the stored credentials — recheck or log in again.")
            } catch {
                // Offline / rate-limited: keep showing the last known
                // status and retry at a moderate pace.
                self.schedulePRPoll(after: .seconds(30))
            }
        }
    }

    func setProjectCollapsed(_ project: Project, collapsed: Bool) {
        let changed = collapsed
            ? collapsedProjects.insert(project.id).inserted
            : collapsedProjects.remove(project.id) != nil
        if changed { persist() }
    }

    // MARK: Session shortcuts (⌘1–⌘9)

    /// True while the command key is down — the sidebar shows ⌘N badges.
    private(set) var commandKeyHeld = false

    /// Sessions in sidebar display order (project order × per-project
    /// session order): the ⌘1–⌘9 tab order. Only VISIBLE rows count —
    /// collapsing a project hands its numbers to the rows below (matches
    /// what the ⌘-held badges show).
    var shortcutOrderedSessions: [RemoteSession] {
        projects
            .filter { !collapsedProjects.contains($0.id) }
            .flatMap { sessions[$0.id] ?? [] }
    }

    func shortcutNumber(for sessionID: SessionID) -> Int? {
        guard let index = shortcutOrderedSessions.prefix(9)
            .firstIndex(where: { $0.id == sessionID }) else { return nil }
        return index + 1
    }

    func selectSession(number: Int) {
        let ordered = shortcutOrderedSessions
        guard (1...9).contains(number), number <= ordered.count else { return }
        selectedSessionID = ordered[number - 1].id
    }

    // MARK: Sidebar ordering

    func moveProjects(fromOffsets source: IndexSet, toOffset destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func moveSessions(in projectID: ProjectID, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard var list = sessions[projectID] else { return }
        list.move(fromOffsets: source, toOffset: destination)
        sessions[projectID] = list
        // Re-record the whole project's arrangement: the overlay is global,
        // but only relative order within a project matters, so appending the
        // project's IDs in their new order is sufficient and idempotent.
        let moved = Set(list.map(\.id))
        sessionOrder.removeAll { moved.contains($0) }
        sessionOrder.append(contentsOf: list.map(\.id))
        persist()
    }

    /// Renames a session in place (sidebar edit). Metadata-only on the
    /// remote — the backend session ID never changes, so attachments and
    /// selection are untouched. Invalid/unchanged names are a silent no-op
    /// (the row just snaps back, Finder-style).
    func renameSession(_ session: RemoteSession, to rawName: String) async {
        guard let project = projects.first(where: { $0.id == session.projectID }),
              case .success(let name) = SessionNameValidator.validate(rawName),
              name != session.displayName else { return }
        do {
            try await provider.renameSession(session, to: name, project: project)
            // A read already under way may predate the rename; it mustn't
            // land and put the old name back.
            bumpSessionEpoch(project.id)
            // Reflect immediately; the next refresh re-reads the same value
            // from the remote metadata.
            if var list = sessions[project.id],
               let index = list.firstIndex(where: { $0.id == session.id }) {
                let old = list[index]
                list[index] = RemoteSession(
                    id: old.id,
                    projectID: old.projectID,
                    displayName: name,
                    createdAt: old.createdAt,
                    backendID: old.backendID,
                    // The launch slug survives renames; a pre-slug session
                    // just had its slug backfilled by the rename script, so
                    // the old computed value is still the right one.
                    launchSlug: old.launchSlug
                        ?? SessionSlug.make(displayName: old.displayName, sessionID: old.id),
                    cleanup: old.cleanup,
                    paneTitle: old.paneTitle)
                sessions[project.id] = list
            }
        } catch {
            alert = AppAlert(title: "Couldn't Rename Session", message: error.localizedDescription)
        }
    }

    func archiveSession(_ session: RemoteSession) async {
        await archiveSessions([session])
    }

    /// Ends each session and runs the cleanup it recorded at launch.
    func archiveSessions(_ targets: [RemoteSession]) async {
        // Once at a time: a cleanup command mustn't run twice.
        let targets = targets.filter { !archivingSessions.contains($0.id) }
        let failures = await forEachSession(targets, starting: { self.archivingSessions.insert($0.id) }) { session, project in
            defer { self.archivingSessions.remove(session.id) }
            do {
                try await self.provider.archiveSession(session, project: project)
                self.bumpSessionEpoch(project.id)
                self.sessions[project.id]?.removeAll { $0.id == session.id }
                self.tombstones.removeAll { $0.id == session.id }
                self.sessionOrder.removeAll { $0 == session.id }
                self.persist()
                return nil
            } catch let error as RuntimeProviderError {
                if case .cleanupFailed = error {
                    // The runtime session is gone; keep a tombstone for retry.
                    self.bumpSessionEpoch(project.id)
                    self.sessions[project.id]?.removeAll { $0.id == session.id }
                    self.tombstones.removeAll { $0.id == session.id }
                    self.sessionOrder.removeAll { $0 == session.id }
                    self.tombstones.append(CleanupTombstone(
                        session: session,
                        projectID: project.id,
                        failureMessage: error.localizedDescription))
                    self.persist()
                }
                return error.localizedDescription
            } catch {
                return error.localizedDescription
            }
        }
        reportBatchFailures(failures, of: targets.count, title: "Archive Failed", verb: "Archive")
    }

    func killSession(_ session: RemoteSession) async {
        await killSessions([session])
    }

    /// Force-kills each session; no cleanup runs.
    func killSessions(_ targets: [RemoteSession]) async {
        let failures = await forEachSession(targets) { session, project in
            do {
                try await self.provider.destroySession(session, project: project)
                self.bumpSessionEpoch(project.id)
                self.sessions[project.id]?.removeAll { $0.id == session.id }
                self.sessionOrder.removeAll { $0 == session.id }
                self.persist()
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        reportBatchFailures(failures, of: targets.count, title: "Couldn't Kill Session", verb: "Kill")
    }

    /// Takes the sessions out of the selection and drops their connections,
    /// then runs `operation` on each, which returns an error message or
    /// nil. A project's sessions go one after another — their cleanups
    /// mostly work in the same git repository, where concurrent `git
    /// worktree` and `git branch` runs trip over each other's lock files —
    /// while different projects go at once, each refreshed when done.
    private func forEachSession(
        _ targets: [RemoteSession],
        starting: (RemoteSession) -> Void = { _ in },
        _ operation: @escaping @MainActor @Sendable (RemoteSession, Project) async -> String?
    ) async -> [(session: RemoteSession, message: String)] {
        let groups: [(project: Project, sessions: [RemoteSession])] = projects.compactMap { project in
            let mine = targets.filter { $0.projectID == project.id }
            return mine.isEmpty ? nil : (project, mine)
        }
        let all = groups.flatMap(\.sessions)
        guard !all.isEmpty else { return [] }
        deselect(all.map(\.id))
        for session in all {
            dropAttachment(for: session.id)
            starting(session)
        }
        let runs = groups.map { group in
            Task { @MainActor in
                var failures: [(session: RemoteSession, message: String)] = []
                for session in group.sessions {
                    if let message = await operation(session, group.project) {
                        failures.append((session, message))
                    }
                }
                await self.refreshSessions(for: group.project)
                return failures
            }
        }
        var failures: [(session: RemoteSession, message: String)] = []
        for run in runs { failures += await run.value }
        return failures
    }

    /// One alert for a batch: `title` and the error itself for a lone
    /// session, else each failed session's name with its error.
    private func reportBatchFailures(
        _ failures: [(session: RemoteSession, message: String)], of total: Int, title: String, verb: String
    ) {
        guard let first = failures.first else { return }
        if total == 1 {
            alert = AppAlert(title: title, message: first.message)
            return
        }
        alert = AppAlert(
            title: "Couldn't \(verb) \(failures.count) of \(total) Sessions",
            message: failures
                .map { "\u{201C}\($0.session.displayName)\u{201D}: \($0.message)" }
                .joined(separator: "\n\n"))
    }

    func retryCleanup(_ tombstone: CleanupTombstone) async {
        guard let project = projects.first(where: { $0.id == tombstone.projectID }) else {
            dismissTombstone(tombstone)
            return
        }
        archivingSessions.insert(tombstone.id)
        defer { archivingSessions.remove(tombstone.id) }
        do {
            try await provider.archiveSession(tombstone.session, project: project)
            tombstones.removeAll { $0.id == tombstone.id }
            persist()
        } catch {
            var updated = tombstone
            updated.failureMessage = error.localizedDescription
            tombstones.removeAll { $0.id == tombstone.id }
            tombstones.append(updated)
            persist()
            alert = AppAlert(title: "Cleanup Failed Again", message: error.localizedDescription)
        }
    }

    func dismissTombstone(_ tombstone: CleanupTombstone) {
        tombstones.removeAll { $0.id == tombstone.id }
        persist()
    }

    private func noteSessionGone(_ session: RemoteSession) {
        sessions[session.projectID]?.removeAll { $0.id == session.id }
    }

    /// Remove a session that ended (used from the "session ended" overlay).
    func clearEndedSession(_ session: RemoteSession) {
        deselect([session.id])
        dropAttachment(for: session.id)
        noteSessionGone(session)
        sessionOrder.removeAll { $0 == session.id }
        persist()
    }

    // MARK: Projects

    func addProject(_ project: Project) {
        projects.append(project)
        persist()
        Task { await refreshSessions(for: project) }
    }

    func updateProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
        persist()
    }

    func removeProject(_ project: Project) {
        forgetProject(project.id)
        persist()
    }

    /// Everything Relay keeps about a project, gone (not saved yet).
    private func forgetProject(_ id: ProjectID) {
        deselect((sessions[id] ?? []).map(\.id))
        for (sessionID, controller) in attachmentPool where controller.session?.projectID == id {
            dropAttachment(for: sessionID)
        }
        let sessionIDs = Set((sessions[id] ?? []).map(\.id))
        projects.removeAll { $0.id == id }
        sessions[id] = nil
        sessionErrors[id] = nil
        tombstones.removeAll { $0.projectID == id }
        sessionOrder.removeAll { sessionIDs.contains($0) }
    }

    // MARK: iCloud sync

    /// What syncs: each host (with the host keys trusted for it), each
    /// project, and the projects' order. Sessions don't — they're
    /// discovered on the hosts — nor does anything about this device's
    /// window (selection, collapsed projects, session order).
    private func syncItems() -> [SyncItem] {
        var items: [SyncItem] = []
        if hostRegistry != nil {
            let known = knownHostsForSync()
            items += hosts.map { host in
                .host(SyncedHost(host: host, trustedHostKeys: known.trustedKeys(host: host.hostname, port: host.port ?? 22)))
            }
        }
        items += projects.map(SyncItem.project)
        items.append(.projectOrder(SyncedProjectOrder(projects: projects.map(\.id))))
        return items
    }

    /// The user's known_hosts and Relay's own: a host trusted either way
    /// is trusted on the other devices too.
    private func knownHostsForSync() -> KnownHosts {
        if let knownHostsCache { return knownHostsCache }
        let files = KnownHosts.defaultFiles + [builtInSSH?.trustedHostsFile].compactMap { $0 }
        let known = KnownHosts.load(files: files)
        knownHostsCache = known
        return known
    }

    /// Applies hosts and projects changed on another device, then saves
    /// (which records them as they now are — not a change to send back).
    func applySyncChanges(_ changes: [SyncState.Change]) {
        var hostsChanged = false
        var projectsToRefresh: [Project] = []
        for change in SyncState.Change.inApplyOrder(changes) {
            switch change {
            case .upsert(.host(let synced)):
                if let index = hosts.firstIndex(where: { $0.alias == synced.host.alias }) {
                    hosts[index] = synced.host
                } else {
                    hosts.append(synced.host)
                }
                trustSyncedHostKeys(synced)
                hostsChanged = true
            case .remove(.host(let synced)):
                // A host a project here still uses stays — and goes back
                // to iCloud with the save below.
                guard projects(on: synced.host).isEmpty else { continue }
                hosts.removeAll { $0.alias == synced.host.alias }
                SSHPasswordStore.delete(alias: synced.host.alias)
                hostsChanged = true
            case .upsert(.project(let project)):
                if let index = projects.firstIndex(where: { $0.id == project.id }) {
                    let old = projects[index]
                    projects[index] = project
                    if old.workspace != project.workspace || old.resolvedPath != project.resolvedPath {
                        projectsToRefresh.append(project)
                    }
                } else {
                    projects.append(project)
                    projectsToRefresh.append(project)
                }
            case .remove(.project(let project)):
                forgetProject(project.id)
            case .upsert(.projectOrder), .remove(.projectOrder):
                break
            }
        }
        if let order = cloudSync.state.projectOrder {
            projects = SyncedProjectOrder(projects: order).arrange(projects)
        }
        if hostsChanged {
            hostRegistry?.setHosts(hosts)
            builtInSSH?.hostsChanged()
        }
        persist()
        if hostsChanged {
            Task { await refreshRemotes() }
        }
        for project in projectsToRefresh {
            Task { await refreshSessions(for: project) }
        }
    }

    /// Trusts here the host keys another device trusts for the host —
    /// except one this device has revoked.
    private func trustSyncedHostKeys(_ synced: SyncedHost) {
        guard let file = builtInSSH?.trustedHostsFile, !synced.trustedHostKeys.isEmpty else { return }
        let known = knownHostsForSync()
        let port = synced.host.port ?? 22
        for key in synced.trustedHostKeys {
            let fields = key.split(separator: " ")
            guard fields.count == 2, let blob = Data(base64Encoded: String(fields[1])) else { continue }
            switch known.verify(host: synced.host.hostname, port: port, keyType: String(fields[0]), key: blob) {
            case .trusted, .revoked:
                continue
            case .unknown, .changed:
                do {
                    try KnownHosts.trust(host: synced.host.hostname, port: port, presentedKey: key, in: file)
                } catch {
                    ghosttyLogger.error("couldn't trust a synced key for \(synced.host.alias, privacy: .public): \(error, privacy: .public)")
                }
            }
        }
        knownHostsCache = nil
    }

    // MARK: iOS app lifecycle

    /// iOS: whether the app's connections are down while it's in the
    /// background (it can't keep them: iOS suspends it).
    private(set) var connectionsSuspended = false

    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var suspendTask: Task<Void, Never>?
    /// The pooled connections' close, which a reconnect waits for (so it
    /// can't close the new ones).
    private var closingConnections: Task<Void, Never>?
    /// Whether a window has been active (on screen) yet, and who's waiting
    /// for one (`waitUntilOnScreen`).
    private var windowActive = false
    private var onScreenWaiters: [CheckedContinuation<Void, Never>] = []
    /// How long connections outlive a trip to the background, so a quick
    /// switch to another app and back finds the terminal still connected.
    private static let backgroundGrace: Duration = .seconds(25)

    func scenePhaseChanged(to phase: ScenePhase) {
        if phase == .active {
            windowActive = true
            let waiters = onScreenWaiters
            onScreenWaiters = []
            waiters.forEach { $0.resume() }
        }
        switch phase {
        case .background:
            // No drawing in the background (iOS refuses GPU work there).
            for controller in attachmentPool.values { controller.setPresented(false) }
            guard !connectionsSuspended, suspendTask == nil else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Relay connections") { [weak self] in
                MainActor.assumeIsolated { self?.suspendConnections(expiring: true) }
            }
            suspendTask = Task { [weak self] in
                try? await Task.sleep(for: Self.backgroundGrace)
                guard !Task.isCancelled else { return }
                self?.suspendConnections()
            }
        case .active:
            suspendTask?.cancel()
            suspendTask = nil
            endBackgroundTask()
            resumeConnections()
        default:
            break
        }
    }

    /// Ends every connection — terminals (the remote sessions keep
    /// running), monitors, the SSH client's pooled ones — keeping the
    /// selection to reconnect to.
    /// `expiring`: iOS's background time is up, and the background task
    /// must end now.
    private func suspendConnections(expiring: Bool = false) {
        suspendTask?.cancel()
        suspendTask = nil
        if !connectionsSuspended {
            ghosttyLogger.info("in the background: closing connections")
            connectionsSuspended = true
            for id in warmOrder.reversed() { dropAttachment(for: id) }
            syncAgentMonitors()
            syncLoadMonitor()
            if let pool = builtInSSH?.pool {
                closingConnections = Task { await pool.closeAll() }
            }
        }
        guard !expiring, let closing = closingConnections else {
            // Out of time: iOS needs the task ended now.
            endBackgroundTask()
            return
        }
        // The background task keeps the app running until they're closed.
        let task = backgroundTask
        Task { [weak self] in
            await closing.value
            self?.endBackgroundTask(task)
        }
    }

    /// Ends the background task (`task`: only if it's still that one).
    private func endBackgroundTask(_ task: UIBackgroundTaskIdentifier? = nil) {
        guard backgroundTask != .invalid, task == nil || task == backgroundTask else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Launched in the background (by a sync push, with no window): nothing
    /// connects until a window is on screen — iOS would suspend the app
    /// with connections open. A normal launch waits only for its window.
    private func waitUntilOnScreen() async {
        guard !windowActive else { return }
        connectionsSuspended = true
        await withCheckedContinuation { onScreenWaiters.append($0) }
        connectionsSuspended = false
        syncAgentMonitors()
    }

    /// Back on screen: reconnects the session on screen, or shows the one
    /// still connected again.
    private func resumeConnections() {
        if connectionsSuspended {
            ghosttyLogger.info("back from the background: reconnecting")
            connectionsSuspended = false
            syncAgentMonitors()
        }
        let closing = closingConnections
        closingConnections = nil
        guard let session = selectedSession,
              let project = projects.first(where: { $0.id == session.projectID }) else { return }
        guard let closing else {
            warmAttachment(for: session, project: project)
            return
        }
        // After the close, which would otherwise take the new connection.
        Task { [weak self] in
            await closing.value
            guard let self, !self.connectionsSuspended, self.selectedSessionID == session.id else { return }
            self.warmAttachment(for: session, project: project)
        }
    }
    #endif

    // MARK: Persistence

    private var persistChain: Task<Void, Never>?

    /// Host records the state file holds that this build can't read (see
    /// PersistedState.unreadableHosts): saved back as found, and never
    /// synced as deletions.
    private var unreadableHosts: (records: [JSONValue], aliases: [String]) = ([], [])

    func persist() {
        persist(lastSelected: selectedSessionID ?? lastOnScreenSessionID)
    }

    private func persist(lastSelected: SessionID?) {
        // Every change to the hosts and projects comes through here, so
        // this is where sync notices them.
        cloudSync.recordLocal(
            syncItems(),
            keeping: Set(unreadableHosts.aliases.map(SyncItem.recordName(hostAlias:))))
        let state = PersistedState(
            projects: projects,
            tombstones: tombstones,
            lastSelectedSessionID: lastSelected,
            collapsedProjectIDs: collapsedProjects,
            sessionOrder: sessionOrder,
            hosts: hostRegistry == nil ? nil : hosts,
            unreadableHosts: unreadableHosts.records,
            sync: cloudSync.state
        )
        // Chain saves so an older snapshot can never overwrite a newer one.
        persistChain = Task { [store, previous = persistChain] in
            await previous?.value
            do {
                try await store.save(state)
            } catch {
                ghosttyLogger.error("persist failed: \(error, privacy: .public)")
            }
        }
    }
}
