import SwiftUI
import RelayCore

/// The sidebar's layout grid. Every row is a fixed-width glyph gutter
/// followed by text, so glyphs and text form clean columns within each
/// level. SwiftUI `Label`s are avoided on purpose: their icon column
/// metrics are private and don't line up with custom rows.
private enum SidebarGrid {
    static let glyphWidth: CGFloat = 18
    static let gap: CGFloat = 5
    /// Where text starts inside a row, for aligning second lines.
    static let textInset: CGFloat = glyphWidth + gap
}

/// One grid-aligned sidebar row: glyph centered in the fixed gutter, then
/// the content.
private struct GridRow<Glyph: View, Content: View>: View {
    @ViewBuilder let glyph: Glyph
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: SidebarGrid.gap) {
            glyph
                .frame(width: SidebarGrid.glyphWidth)
            content
        }
    }
}

/// One "Projects" section of DisclosureGroups: project rows at the top
/// level, session rows as their children. Reordering is two nested
/// ForEach+onMove scopes on purpose — SwiftUI constrains each drag (and its
/// insertion indicator) to the rows of the ForEach that owns it, so
/// projects can only be dropped between projects and sessions only within
/// their own project. A single flat ForEach would draw insertion lines at
/// every row gap, including meaningless ones.
struct SidebarView: View {
    @Bindable var model: AppModel

    /// On the Mac a set, so the list does multiple selection the AppKit way
    /// (⌘-click, ⇧-click, ⇧-arrows, ⌘A). iOS keeps single selection: a set
    /// there means edit mode, and the split view pushes on a single one.
    #if os(macOS)
    private var selection: Binding<Set<SessionID>> { $model.selectedSessionIDs }
    #else
    private var selection: Binding<SessionID?> { $model.selectedSessionID }
    #endif

    var body: some View {
        List(selection: selection) {
            if model.remotesLoaded && model.projects.isEmpty {
                emptyState
            } else {
                #if os(macOS)
                // The header is a plain row, not a Section header: on macOS
                // 27 a sidebar Section header shows a collapse chevron on
                // hover even with .collapsible(false) (shoving the + aside),
                // and clicking it traps inside SwiftUI's list code.
                sectionHeader
                    .selectionDisabled()
                    .moveDisabled(true)
                #endif
                ForEach(model.projects) { project in
                    ProjectGroup(model: model, project: project)
                }
                .onMove { source, destination in
                    model.moveProjects(fromOffsets: source, toOffset: destination)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(AppVariant.dataDirectoryName)
        .overlay(alignment: .bottom) {
            if !model.remotesLoaded {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
            }
        }
        #if os(iOS)
        .refreshable { await model.refreshAll() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.settingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("sidebar.settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.createSheetPresented = true
                } label: {
                    Label("New Session or Project", systemImage: "plus")
                }
                .accessibilityIdentifier("sidebar.add")
            }
        }
        #endif
    }

    #if os(macOS)
    private var sectionHeader: some View {
        HStack(spacing: 2) {
            Text("Projects")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            // A plain button popping an NSMenu rather than a SwiftUI Menu:
            // in a list row (vs. a Section header) the Menu's AppKit-drawn
            // label ignores dark mode and renders black.
            Button {
                PopUpMenu.show([("Refresh All", { Task { await model.refreshAll() } })])
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(.borderless)
            .padding(.trailing, 6)
            Button {
                model.createSheetPresented = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New session or project")
        }
        // Trailing inset chosen so the + sits on the project rows' status
        // dot column below it.
        .padding(.trailing, 10)
    }
    #endif

    @ViewBuilder private var emptyState: some View {
        ContentUnavailableView {
            Label("No Projects", systemImage: "folder.badge.plus")
        } description: {
            Text("A project is a folder on one of your hosts.")
        } actions: {
            Button("Add Project…") {
                model.projectEditor = ProjectEditorContext(mode: .create(workspace: nil))
            }
        }
    }
}

#if os(macOS)
/// Pops a context-style menu at the mouse pointer.
private enum PopUpMenu {
    private final class Item: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func fire() { handler() }
    }

    @MainActor static func show(_ items: [(String, () -> Void)]) {
        let menu = NSMenu()
        for (title, handler) in items {
            let target = Item(handler)
            let item = NSMenuItem(title: title, action: #selector(Item.fire), keyEquivalent: "")
            item.target = target
            item.representedObject = target  // NSMenuItem.target is weak
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
#endif

private struct ProjectGroup: View {
    @Bindable var model: AppModel
    let project: Project

    private var remoteMissing: Bool { model.isRemoteMissing(project) }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { !model.collapsedProjects.contains(project.id) },
            set: { model.setProjectCollapsed(project, collapsed: !$0) })
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            if let message = model.sessionErrors[project.id] {
                SessionsErrorRow(model: model, project: project, message: message)
                    .moveDisabled(true)
            }
            ForEach(model.sessions[project.id] ?? []) { session in
                SessionRow(model: model, session: session)
                    .tag(session.id)
            }
            .onMove { source, destination in
                model.moveSessions(in: project.id, fromOffsets: source, toOffset: destination)
            }
            ForEach(model.tombstones.filter { $0.projectID == project.id }) { tombstone in
                TombstoneRow(model: model, tombstone: tombstone)
                    .moveDisabled(true)
                    // ForEach tags each row with its ID — a SessionID, like
                    // the session rows' — which would make these selectable
                    // (and part of ⇧-click ranges) with nothing to show.
                    .selectionDisabled()
            }
            if !remoteMissing {
                NewSessionRow(model: model, project: project)
                    .moveDisabled(true)
            }
        } label: {
            ProjectRow(model: model, project: project, remoteMissing: remoteMissing)
        }
    }
}

private struct ProjectRow: View {
    @Bindable var model: AppModel
    let project: Project
    let remoteMissing: Bool

    private var hostAlias: String { project.workspace.opaqueID }
    private var needingYou: Int { model.agentsNeedingYou(in: project) }

    /// Host reachability: green = online (live attachment, or the last
    /// contact succeeded), red = the last contact failed, grey = no
    /// evidence yet.
    private var hostStatus: AppModel.HostStatus {
        model.hostStatus(for: project.workspace)
    }

    private var dotColor: Color {
        switch hostStatus {
        case .online: .green
        case .offline: .red
        case .unknown: .secondary.opacity(0.5)
        }
    }

    private var helpText: String {
        if remoteMissing { return "\(hostAlias) isn't in Relay's hosts — add it in Settings ▸ Hosts" }
        switch hostStatus {
        case .online: return "\(hostAlias) — online"
        case .offline: return "\(hostAlias) — unreachable"
        case .unknown: return hostAlias
        }
    }

    var body: some View {
        GridRow {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
        } content: {
            Text(project.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if needingYou > 0 {
                // Agents waiting on the user outrank the host label.
                Text("\(needingYou) needs you")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help("\(needingYou) agent\(needingYou == 1 ? " is" : "s are") waiting for input on \(hostAlias)")
            } else {
                Text(hostAlias)
                    .font(.caption)
                    .foregroundStyle(remoteMissing ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if model.sessionsLoading.contains(project.id) {
                ProgressView().controlSize(.mini)
            } else if remoteMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
            }
        }
        // NOTE: no row-level tap gesture here — a tap recognizer swallows
        // the mouse-down the List needs to start a row drag, killing
        // project reordering.
        .help(helpText)
        .contextMenu {
            Button("New Session…") { model.newSessionProject = project }
                .disabled(remoteMissing)
            Button("Project Settings…") {
                model.projectEditor = ProjectEditorContext(mode: .edit(project))
            }
            Button("Refresh Sessions") {
                Task { await model.refreshSessions(for: project) }
            }
            Button("Copy SSH Alias") {
                Platform.copy(hostAlias)
            }
            Divider()
            Button("Remove Project…", role: .destructive) {
                model.confirmRemoveProject = project
            }
        }
    }
}

private struct SessionsErrorRow: View {
    @Bindable var model: AppModel
    let project: Project
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GridRow {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } content: {
                Text(message)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Button {
                    Task { await model.refreshSessions(for: project) }
                } label: {
                    Text("Retry")
                        .font(.caption)
                }
                #if os(iOS)
                // A host set up on a Mac (its agent, a key file) needs a
                // Relay key or a password to connect from here.
                if let host = model.host(for: project.workspace), model.needsConnection(host) {
                    Button {
                        model.hostToSetUp = host
                    } label: {
                        Text("Set Up \(host.alias)\u{2026}")
                            .font(.caption)
                    }
                }
                #endif
            }
            .buttonStyle(.borderless)
            .padding(.leading, SidebarGrid.textInset)
        }
    }
}

/// The ⌘N hint shown at a session row's trailing edge while ⌘ is held —
/// the row's tab number for ⌘1–⌘9 switching.
private struct ShortcutKeyBadge: View {
    let number: Int

    var body: some View {
        Text("⌘\(number)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary.opacity(0.6)))
    }
}

private struct SessionRow: View {
    @Bindable var model: AppModel
    let session: RemoteSession

    @State private var isEditingName = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    private var isSelected: Bool { model.selectedSessionID == session.id }
    private var isArchiving: Bool { model.archivingSessions.contains(session.id) }
    private var isConnected: Bool { model.connectionPhase(for: session.id) != nil }

    /// Green = live ssh connection (selected or warm in the background);
    /// grey = no local connection. Yellow/red show connection trouble.
    private var statusColor: Color {
        model.connectionPhase(for: session.id)?.statusColor ?? .secondary.opacity(0.5)
    }

    /// The dot, in words (VoiceOver).
    private var connectionDescription: String {
        (model.connectionPhase(for: session.id) ?? .idle).spokenDescription
    }

    /// What runs inside the session, as reported by its terminal title
    /// (e.g. Claude Code's "✳ task" status). Connected sessions use the
    /// live surface title; grey sessions fall back to the tmux pane title
    /// from the 30s sweep.
    private var statusTitle: String? {
        model.liveTitle(for: session.id) ?? session.paneTitle
    }

    private var agentActivity: AgentActivity? { model.agentActivity(for: session) }
    private var agentUnseen: Bool { model.agentUnseen(for: session) }

    private func beginRename() {
        draftName = session.displayName
        isEditingName = true
    }

    /// Ends editing; an empty or unchanged draft just snaps back.
    private func commitRename() {
        guard isEditingName else { return }
        isEditingName = false
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != session.displayName else { return }
        Task { await model.renameSession(session, to: name) }
    }

    /// A click on the selected row's name. The gesture takes the click
    /// from the list, so a ⌘-click is done here: it deselects the row, as
    /// the list would. (A ⇧-click would select from the row to itself.)
    private func nameClicked() {
        #if os(macOS)
        let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if modifiers.contains(.command) {
            model.selectedSessionIDs.remove(session.id)
            return
        }
        if modifiers.contains(.shift) { return }
        #endif
        beginRename()
    }

    var body: some View {
        GridRow {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
        } content: {
            VStack(alignment: .leading, spacing: 1) {
                if isEditingName {
                    TextField("Session Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .focused($nameFieldFocused)
                        .onSubmit { commitRename() }
                        #if os(macOS)
                        .onExitCommand { isEditingName = false }
                        #endif
                        .onAppear { nameFieldFocused = true }
                        // Click-away unfocuses → commit, Finder-style.
                        .onChange(of: nameFieldFocused) { _, focused in
                            if !focused { commitRename() }
                        }
                } else if isSelected, !Platform.isTouch {
                    // Finder-style: clicking the name of the already-selected
                    // row begins the rename. The gesture is scoped to the
                    // text only — a row-level gesture would swallow the
                    // mouse-down the List needs to start a row drag.
                    Text(session.displayName)
                        .lineLimit(1)
                        .onTapGesture { nameClicked() }
                } else {
                    Text(session.displayName)
                        // A finished turn not looked at yet reads as unread.
                        .fontWeight(agentUnseen ? .semibold : nil)
                        .lineLimit(1)
                }
                if let statusTitle, statusTitle != session.displayName {
                    Text(statusTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            if isArchiving {
                ProgressView().controlSize(.mini)
            } else if model.commandKeyHeld, let number = model.shortcutNumber(for: session.id) {
                ShortcutKeyBadge(number: number)
            } else if let agentActivity, agentActivity.state != .idle {
                AgentStatusGlyph(activity: agentActivity, unseen: agentUnseen)
            } else if agentUnseen {
                UnreadDot()
            }
        }
        .opacity(isArchiving ? 0.5 : 1)
        .accessibilityValue(connectionDescription)
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            if !isArchiving {
                Button {
                    Task { await model.archiveSession(session) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.orange)
            }
            if isConnected {
                Button {
                    model.disconnectSession(session)
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                model.setMarkedUnread(!agentUnseen, for: session)
            } label: {
                Label(agentUnseen ? "Read" : "Unread", systemImage: agentUnseen ? "envelope.open" : "envelope.badge")
            }
            .tint(.blue)
        }
        #endif
        .contextMenu {
            let targets = model.contextTargets(for: session)
            if targets.count > 1 {
                SessionBatchMenuItems(model: model, sessions: targets)
            } else {
                Button("Rename") {
                    beginRename()
                }
                .disabled(isArchiving)
                if agentUnseen {
                    Button("Mark as Read") {
                        model.setMarkedUnread(false, for: session)
                    }
                } else {
                    Button("Mark as Unread") {
                        model.setMarkedUnread(true, for: session)
                    }
                }
                Button("Disconnect") {
                    model.disconnectSession(session)
                }
                .disabled(!isConnected)
                Button("Archive Session…") {
                    Task { await model.archiveSession(session) }
                }
                .disabled(isArchiving)
                Divider()
                Button("Kill Session…", role: .destructive) {
                    model.confirmKillSessions = [session]
                }
            }
        }
    }
}

/// The context menu for several selected sessions: what applies to all
/// of them at once.
private struct SessionBatchMenuItems: View {
    let model: AppModel
    let sessions: [RemoteSession]

    var body: some View {
        let unseen = sessions.filter { model.agentUnseen(for: $0) }
        let connected = sessions.filter { model.connectionPhase(for: $0.id) != nil }
        let archivable = sessions.filter { !model.archivingSessions.contains($0.id) }
        // Mail-style: whichever applies to some of them (both when mixed).
        if !unseen.isEmpty {
            Button("Mark as Read") {
                model.setMarkedUnread(false, for: sessions)
            }
        }
        if unseen.count < sessions.count {
            Button("Mark as Unread") {
                model.setMarkedUnread(true, for: sessions)
            }
        }
        Button("Disconnect") {
            model.disconnectSessions(connected)
        }
        .disabled(connected.isEmpty)
        Button("Archive \(Self.sessions(archivable.count))…") {
            Task { await model.archiveSessions(archivable) }
        }
        .disabled(archivable.isEmpty)
        Divider()
        Button("Kill \(Self.sessions(sessions.count))…", role: .destructive) {
            model.confirmKillSessions = sessions
        }
    }

    static func sessions(_ count: Int) -> String {
        count == 1 ? "1 Session" : "\(count) Sessions"
    }
}

private struct NewSessionRow: View {
    @Bindable var model: AppModel
    let project: Project

    var body: some View {
        Button {
            model.newSessionProject = project
        } label: {
            GridRow {
                Image(systemName: "plus.circle")
            } content: {
                Text("New Session")
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct TombstoneRow: View {
    @Bindable var model: AppModel
    let tombstone: CleanupTombstone

    private var isRetrying: Bool { model.archivingSessions.contains(tombstone.id) }

    var body: some View {
        GridRow {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.orange)
        } content: {
            VStack(alignment: .leading, spacing: 1) {
                Text(tombstone.session.displayName)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Text("Cleanup failed")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if isRetrying {
                ProgressView().controlSize(.mini)
            }
        }
        .help(tombstone.failureMessage)
        .contextMenu {
            Button("Retry Cleanup") {
                Task { await model.retryCleanup(tombstone) }
            }
            .disabled(isRetrying)
            Button("Dismiss") {
                model.dismissTombstone(tombstone)
            }
        }
    }
}
