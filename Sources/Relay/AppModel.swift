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
    private static let warmAttachmentCap = 4
    /// Placeholder the detail view renders when nothing is selected.
    private let idleAttachment: TerminalAttachmentController

    var attachment: TerminalAttachmentController {
        guard let id = selectedSessionID, let controller = attachmentPool[id] else {
            return idleAttachment
        }
        return controller
    }
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
    private var titleRefreshTimer: Timer?
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
        self.idleAttachment = TerminalAttachmentController(provider: provider)

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

        // Detached sessions keep reporting status through their pane titles
        // (tmux tracks OSC titles server-side), so the sidebar merges fresh
        // titles in periodically while a window is showing. Title-only: this
        // sweep never adds or removes rows.
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshSessionTitles() }
        }
        timer.tolerance = 5
        titleRefreshTimer = timer

        GhosttyRuntime.shared.urlOpener = { [weak self] url in
            self?.openTerminalURL(url)
        }
    }

    // MARK: Terminal links

    /// Cache of alias → browser-usable host, resolved via `ssh -G`.
    private var resolvedLinkHosts: [String: String] = [:]

    /// Opens a URL clicked in the terminal. Loopback URLs are rewritten to
    /// the attached session's remote host first — "listening on
    /// http://localhost:3000" printed by a remote dev server should open the
    /// remote's port 3000 in the local browser, not the Mac's.
    func openTerminalURL(_ url: URL) {
        guard LocalhostURLRewriter.isRewritable(url),
              let project = attachment.project else {
            NSWorkspace.shared.open(url)
            return
        }
        let alias = project.workspace.opaqueID
        Task { @MainActor in
            let host: String
            if let cached = resolvedLinkHosts[alias] {
                host = cached
            } else {
                host = await SSHHostNameResolver.resolve(alias: alias)
                resolvedLinkHosts[alias] = host
            }
            NSWorkspace.shared.open(LocalhostURLRewriter.rewrite(url, remoteHost: host) ?? url)
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
        // Hiding a remote hides its projects; drop any selection under it,
        // plus any warm attachments to it (hidden rows own no connections).
        if let project = selectedProject, project.workspace == workspace {
            selectedSessionID = nil
        }
        let projectIDs = Set(projects.filter { $0.workspace == workspace }.map(\.id))
        for (id, controller) in attachmentPool
        where controller.session.map({ projectIDs.contains($0.projectID) }) == true {
            dropAttachment(for: id)
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
            // The departing session stays warm: its connection, scrollback,
            // and live title survive in the background — only presentation
            // (rendering + focus) is handed over.
            if let old = oldValue, let previous = self.attachmentPool[old] {
                self.carryOverLiveTitle(for: old)
                previous.setPresented(false)
            }
            guard let session = self.selectedSession,
                  let project = self.projects.first(where: { $0.id == session.projectID }) else {
                if !skipPersist { self.persist() }
                return
            }
            self.warmAttachment(for: session, project: project)
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
            attachmentPool[session.id] = controller
            controller.attach(session: session, project: project)
        }
        controller.setPresented(true)
        warmOrder.removeAll { $0 == session.id }
        warmOrder.append(session.id)
        while warmOrder.count > Self.warmAttachmentCap {
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
        if selectedSessionID == session.id {
            selectedSessionID = nil
        }
        dropAttachment(for: session.id)
    }

    /// The connection phase for a session's warm controller, or nil when
    /// the session has no live attachment (grey dot).
    func connectionPhase(for sessionID: SessionID) -> TerminalAttachmentController.Phase? {
        guard let controller = attachmentPool[sessionID] else { return nil }
        if case .idle = controller.phase { return nil }
        return controller.phase
    }

    /// Live surface title for any warm-attached session (selected or not);
    /// cold sessions fall back to the 30s pane-title sweep.
    func liveTitle(for sessionID: SessionID) -> String? {
        guard let controller = attachmentPool[sessionID],
              case .attached = controller.phase else { return nil }
        let title = controller.terminalTitle
        return title.isEmpty ? nil : title
    }

    /// The live surface title is fresher than the last title sweep; carry it
    /// into the session's row so backgrounding or dropping an attachment
    /// never downgrades the caption to a stale poll.
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
            // Warm attachments for this project's vanished sessions have
            // nothing to reattach to; drop them (the selected one keeps its
            // controller so the "session ended" overlay can appear).
            let liveIDs = Set(list.map(\.id))
            for id in warmOrder
            where id != selectedSessionID && !liveIDs.contains(id)
                && attachmentPool[id]?.session?.projectID == project.id {
                dropAttachment(for: id)
            }
        } catch {
            sessionErrors[project.id] = error.localizedDescription
        }
    }

    /// Re-reads pane titles for the sessions already in the sidebar and
    /// merges them in place. Deliberately title-only: existence
    /// reconciliation (rows appearing/disappearing) stays with the explicit
    /// refresh paths, so this background sweep never surprises the user.
    private func refreshSessionTitles() async {
        guard NSApp.windows.contains(where: { $0.isVisible }) else { return }
        for project in projects {
            guard let known = sessions[project.id], !known.isEmpty,
                  !sessionsLoading.contains(project.id),
                  let fresh = try? await provider.listSessions(for: project)
            else { continue }
            let titles = Dictionary(fresh.map { ($0.id, $0.paneTitle) },
                                    uniquingKeysWith: { first, _ in first })
            guard var updated = sessions[project.id] else { continue }
            for index in updated.indices {
                if let title = titles[updated[index].id] {
                    updated[index].paneTitle = title
                }
            }
            if updated != sessions[project.id] { sessions[project.id] = updated }
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
        dropAttachment(for: session.id)
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
        dropAttachment(for: session.id)
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
        dropAttachment(for: session.id)
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
        for (id, controller) in attachmentPool where controller.session?.projectID == project.id {
            dropAttachment(for: id)
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
