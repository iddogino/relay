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

    // Remotes (rediscovered from provider, never persisted)
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
        // Clamped on read so a hand-edited default can't disable attachment
        // (0/missing means unset) or leak connections without bound.
        let storedCap = UserDefaults.standard.integer(forKey: Self.warmAttachmentCapKey)
        self.warmAttachmentCap = storedCap == 0
            ? Self.warmAttachmentCapDefault
            : max(1, min(storedCap, 16))

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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshGitState()
                await self.refreshSessionTitles()
            }
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
            sessionOrder = state.sessionOrder
            collapsedProjects = state.collapsedProjectIDs
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

    /// True when the project's host no longer appears in SSH config. Only
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
            self.refreshGitState()
            if self.diffTrayVisible {
                self.diff = nil
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
            noteHostContact(project.workspace, ok: true)
            guard sessionListEpoch[project.id, default: 0] == epoch else { return }
            let previousIDs = (sessions[project.id] ?? []).map(\.id)
            sessions[project.id] = SessionOrdering.apply(order: sessionOrder, to: list)
            sessionErrors[project.id] = nil
            let liveIDs = Set(list.map(\.id))
            // Order entries for sessions that vanished remotely are dead;
            // pruning here (where project membership is still known) keeps
            // the overlay from accreting stale IDs.
            let vanished = previousIDs.filter { !liveIDs.contains($0) }
            if !vanished.isEmpty {
                sessionOrder.removeAll { vanished.contains($0) }
                persist()
            }
            // Warm attachments for this project's vanished sessions have
            // nothing to reattach to; drop them (the selected one keeps its
            // controller so the "session ended" overlay can appear).
            for id in warmOrder
            where id != selectedSessionID && !liveIDs.contains(id)
                && attachmentPool[id]?.session?.projectID == project.id {
                dropAttachment(for: id)
            }
        } catch {
            noteHostContact(project.workspace, ok: false)
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
            guard !sessionsLoading.contains(project.id), !isRemoteMissing(project) else { continue }
            let fresh: [RemoteSession]
            do {
                fresh = try await provider.listSessions(for: project)
                noteHostContact(project.workspace, ok: true)
            } catch {
                // The sweep doubles as the host-reachability heartbeat, so a
                // failed dial is recorded, not just skipped.
                noteHostContact(project.workspace, ok: false)
                continue
            }
            guard let known = sessions[project.id], !known.isEmpty else { continue }
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
        // New sessions take the bottom slot of their project's list and stay
        // there across refreshes.
        sessionOrder.removeAll { $0 == session.id }
        sessionOrder.append(session.id)
        selectedSessionID = session.id
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
            defer { self.gitStateTask = nil }
            guard let state = try? await provider.gitState(for: session, project: project) else {
                self.gitStates[session.id] = nil
                return
            }
            self.gitStates[session.id] = state
        }
    }

    func loadDiff() async {
        guard let session = selectedSession,
              let project = projects.first(where: { $0.id == session.projectID }) else { return }
        diffLoading = true
        diffError = nil
        defer { diffLoading = false }
        do {
            diff = try await provider.gitDiff(for: session, project: project)
        } catch {
            diffError = error.localizedDescription
        }
    }

    func setProjectCollapsed(_ project: Project, collapsed: Bool) {
        let changed = collapsed
            ? collapsedProjects.insert(project.id).inserted
            : collapsedProjects.remove(project.id) != nil
        if changed { persist() }
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
            sessionOrder.removeAll { $0 == session.id }
            persist()
            await refreshSessions(for: project)
        } catch let error as RuntimeProviderError {
            if case .cleanupFailed = error {
                // The runtime session is gone; keep a tombstone for retry.
                bumpSessionEpoch(project.id)
                sessions[project.id]?.removeAll { $0.id == session.id }
                tombstones.removeAll { $0.id == session.id }
                sessionOrder.removeAll { $0 == session.id }
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
            sessionOrder.removeAll { $0 == session.id }
            persist()
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
        if let session = selectedSession, session.projectID == project.id {
            selectedSessionID = nil
        }
        for (id, controller) in attachmentPool where controller.session?.projectID == project.id {
            dropAttachment(for: id)
        }
        let sessionIDs = Set((sessions[project.id] ?? []).map(\.id))
        projects.removeAll { $0.id == project.id }
        sessions[project.id] = nil
        sessionErrors[project.id] = nil
        tombstones.removeAll { $0.projectID == project.id }
        sessionOrder.removeAll { sessionIDs.contains($0) }
        persist()
    }

    // MARK: Persistence

    private var persistChain: Task<Void, Never>?

    func persist() {
        let state = PersistedState(
            projects: projects,
            tombstones: tombstones,
            lastSelectedSessionID: selectedSessionID,
            collapsedProjectIDs: collapsedProjects,
            sessionOrder: sessionOrder
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
