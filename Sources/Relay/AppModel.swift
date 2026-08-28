import AppKit
import Observation
import RelayCore

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
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Context for the project editor sheet: adding to a remote, or editing.
struct ProjectEditorContext: Identifiable {
    enum Mode {
        case create(workspace: WorkspaceRef)
        case edit(Project)
    }
    let id = UUID()
    let mode: Mode
}

/// Central UI state. Talks exclusively to `RuntimeProvider` — no SSH/tmux
/// concepts appear here or anywhere above.
@MainActor
@Observable
final class AppModel {
    let provider: any RuntimeProvider
    let attachment: TerminalAttachmentController
    private let store: ProjectStore

    // Remotes (rediscovered from provider, never persisted)
    private(set) var remotes: [WorkspaceDescriptor] = []
    private(set) var remotesLoaded = false

    // Local configuration
    private(set) var projects: [Project] = []
    private(set) var tombstones: [CleanupTombstone] = []
    private(set) var hiddenWorkspaces: Set<WorkspaceRef> = []
    /// Transient: when on, hidden remotes render (dimmed) so they can be unhidden.
    var showHiddenRemotes = false

    // Remote-reconciled session lists
    private(set) var sessions: [ProjectID: [RemoteSession]] = [:]
    private(set) var sessionsLoading: Set<ProjectID> = []
    private(set) var sessionErrors: [ProjectID: String] = [:]

    // Selection & transient UI state
    var selectedSessionID: SessionID? {
        didSet { selectionDidChange(from: oldValue) }
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
    var confirmKillSession: RemoteSession?
    var confirmRemoveProject: Project?

    private var restoredSelection: SessionID?

    init(provider: any RuntimeProvider, store: ProjectStore = ProjectStore()) {
        self.provider = provider
        self.store = store
        self.attachment = TerminalAttachmentController(provider: provider)

        // When a session ends we keep its sidebar row until the user acts
        // (Remove From Sidebar / New Session) or a refresh reconciles it away,
        // so the "session ended" state is visible rather than vanishing.

        Task { await self.bootstrap() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applicationDidActivate()
            }
        }
    }

    // MARK: Startup

    private func bootstrap() async {
        do {
            let state = try await store.load()
            projects = state.projects
            tombstones = state.tombstones
            hiddenWorkspaces = state.hiddenWorkspaces
            restoredSelection = state.lastSelectedSessionID
        } catch ProjectStoreError.corruptState(let backupPath) {
            alert = AppAlert(
                title: "Settings Reset",
                message: "Relay's local configuration was unreadable and has been moved to:\n\(backupPath)\n\nYour remote sessions are unaffected."
            )
        } catch {
            alert = AppAlert(title: "Couldn't Load Settings", message: error.localizedDescription)
        }
        await refreshRemotes()
        // All projects are visible (expanded) in the sidebar, so reconcile
        // each once at launch; restore the last-selected session when found
        // (selection triggers reattachment).
        var selectionToRestore: SessionID?
        for project in projects {
            await refreshSessions(for: project)
            if let restored = restoredSelection,
               sessions[project.id]?.contains(where: { $0.id == restored }) == true {
                selectionToRestore = restored
                restoredSelection = nil
            }
        }
        restoredSelection = nil
        if let selectionToRestore {
            // Let the sidebar finish inserting rows before applying selection.
            try? await Task.sleep(for: .milliseconds(100))
            selectedSessionID = selectionToRestore
        }
    }

    private func applicationDidActivate() {
        Task { await refreshRemotes() }
        // Only refresh the project that's currently in use — no polling sweep.
        if let project = selectedProject {
            Task { await refreshSessions(for: project) }
        }
    }

    // MARK: Remotes

    func refreshRemotes() async {
        do {
            remotes = try await provider.discoverWorkspaces()
        } catch {
            alert = AppAlert(title: "Couldn't Read SSH Config", message: error.localizedDescription)
        }
        remotesLoaded = true
    }

    /// Remotes to render: discovered ones, plus placeholders for projects
    /// whose remote disappeared from SSH config (shown as Missing Remote).
    /// User-hidden remotes are filtered out unless `showHiddenRemotes` is on.
    var sidebarRemotes: [(descriptor: WorkspaceDescriptor, missing: Bool, hidden: Bool)] {
        var rows: [(WorkspaceDescriptor, Bool, Bool)] = remotes.map {
            ($0, false, hiddenWorkspaces.contains($0.id))
        }
        let known = Set(remotes.map(\.id))
        for project in projects where !known.contains(project.workspace) {
            if !rows.contains(where: { $0.0.id == project.workspace }) {
                rows.append((
                    WorkspaceDescriptor(
                        id: project.workspace,
                        displayName: project.workspace.opaqueID,
                        providerID: project.workspace.provider),
                    true,
                    hiddenWorkspaces.contains(project.workspace)
                ))
            }
        }
        return rows.filter { !$0.2 || showHiddenRemotes }
    }

    var hasHiddenRemotes: Bool { !hiddenWorkspaces.isEmpty }

    func hideRemote(_ workspace: WorkspaceRef) {
        hiddenWorkspaces.insert(workspace)
        // Hiding a remote hides its projects; drop any selection under it.
        if let project = selectedProject, project.workspace == workspace {
            selectedSessionID = nil
        }
        persist()
    }

    func showRemote(_ workspace: WorkspaceRef) {
        hiddenWorkspaces.remove(workspace)
        persist()
    }

    func projects(for workspace: WorkspaceRef) -> [Project] {
        projects.filter { $0.workspace == workspace }
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

    private func selectionDidChange(from oldValue: SessionID?) {
        guard selectedSessionID != oldValue else { return }
        // Selection changes arrive mid view-update (List binding); defer the
        // attach/detach side effects out of the current render pass.
        let skipPersist = preserveSelectionOnDisk
        Task { @MainActor in
            guard let session = self.selectedSession,
                  let project = self.projects.first(where: { $0.id == session.projectID }) else {
                self.attachment.detach()
                if !skipPersist { self.persist() }
                return
            }
            self.attachment.attach(session: session, project: project)
            self.persist()
        }
    }

    /// Closing the window is detach-only, and must not clobber the
    /// last-selected session stored for next-launch restore.
    func windowDidClose() {
        preserveSelectionOnDisk = true
        selectedSessionID = nil
        preserveSelectionOnDisk = false
    }

    // MARK: Sessions

    /// Incremented whenever local mutations (create/archive/kill) change what
    /// a concurrent refresh's results would mean; stale results are dropped.
    private var sessionListEpoch: [ProjectID: Int] = [:]

    private func bumpSessionEpoch(_ projectID: ProjectID) {
        sessionListEpoch[projectID, default: 0] += 1
    }

    func refreshSessions(for project: Project) async {
        guard !sessionsLoading.contains(project.id) else { return }
        sessionsLoading.insert(project.id)
        defer { sessionsLoading.remove(project.id) }
        let epoch = sessionListEpoch[project.id, default: 0]
        do {
            let list = try await provider.listSessions(for: project)
            guard sessionListEpoch[project.id, default: 0] == epoch else { return }
            sessions[project.id] = list
            sessionErrors[project.id] = nil
        } catch {
            sessionErrors[project.id] = error.localizedDescription
        }
    }

    /// Records a session the New Session sheet just created, selects it
    /// (attaching the terminal), and reconciles with the remote.
    func noteCreatedSession(_ session: RemoteSession, project: Project) {
        bumpSessionEpoch(project.id)
        sessions[project.id, default: []].append(session)
        selectedSessionID = session.id
        Task { await refreshSessions(for: project) }
    }

    func archiveSession(_ session: RemoteSession) async {
        guard let project = projects.first(where: { $0.id == session.projectID }) else { return }
        if selectedSessionID == session.id {
            selectedSessionID = nil
        }
        archivingSessions.insert(session.id)
        defer { archivingSessions.remove(session.id) }
        do {
            try await provider.archiveSession(session, project: project)
            bumpSessionEpoch(project.id)
            sessions[project.id]?.removeAll { $0.id == session.id }
            tombstones.removeAll { $0.id == session.id }
            persist()
            await refreshSessions(for: project)
        } catch let error as RuntimeProviderError {
            if case .cleanupFailed = error {
                // The runtime session is gone; keep a tombstone for retry.
                bumpSessionEpoch(project.id)
                sessions[project.id]?.removeAll { $0.id == session.id }
                tombstones.removeAll { $0.id == session.id }
                tombstones.append(CleanupTombstone(
                    session: session,
                    projectID: project.id,
                    failureMessage: error.localizedDescription))
                persist()
            }
            alert = AppAlert(title: "Archive Failed", message: error.localizedDescription)
        } catch {
            alert = AppAlert(title: "Archive Failed", message: error.localizedDescription)
        }
    }

    func killSession(_ session: RemoteSession) async {
        guard let project = projects.first(where: { $0.id == session.projectID }) else { return }
        if selectedSessionID == session.id {
            selectedSessionID = nil
        }
        do {
            try await provider.destroySession(session, project: project)
            bumpSessionEpoch(project.id)
            sessions[project.id]?.removeAll { $0.id == session.id }
            await refreshSessions(for: project)
        } catch {
            alert = AppAlert(title: "Couldn't Kill Session", message: error.localizedDescription)
        }
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
        if selectedSessionID == session.id {
            selectedSessionID = nil
        }
        noteSessionGone(session)
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
        if let session = selectedSession, session.projectID == project.id {
            selectedSessionID = nil
        }
        projects.removeAll { $0.id == project.id }
        sessions[project.id] = nil
        sessionErrors[project.id] = nil
        tombstones.removeAll { $0.projectID == project.id }
        persist()
    }

    // MARK: Persistence

    private var persistChain: Task<Void, Never>?

    func persist() {
        let state = PersistedState(
            projects: projects,
            tombstones: tombstones,
            lastSelectedSessionID: selectedSessionID,
            collapsedProjectIDs: [],
            hiddenWorkspaces: hiddenWorkspaces
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
