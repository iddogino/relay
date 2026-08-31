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

    var body: some View {
        List(selection: $model.selectedSessionID) {
            if model.remotesLoaded && model.projects.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(model.projects) { project in
                        ProjectGroup(model: model, project: project)
                    }
                    .onMove { source, destination in
                        model.moveProjects(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    sectionHeader
                }
                .collapsible(false)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Relay")
        .overlay(alignment: .bottom) {
            if !model.remotesLoaded {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 2) {
            Text("Projects")
            Spacer()
            Menu {
                Button("Refresh All") {
                    Task { await model.refreshAll() }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            Button {
                model.createSheetPresented = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(model.remotes.isEmpty && model.projects.isEmpty)
            .help("New session or project")
        }
        // Trailing inset chosen so the + sits on the project rows' status
        // dot column below it.
        .padding(.trailing, 10)
    }

    @ViewBuilder private var emptyState: some View {
        if model.remotes.isEmpty {
            ContentUnavailableView(
                "No SSH Hosts",
                systemImage: "network.slash",
                description: Text("Add hosts to ~/.ssh/config and they'll appear here.")
            )
        } else {
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
}

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
        if remoteMissing { return "\(hostAlias) is missing from ~/.ssh/config" }
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
            Text(hostAlias)
                .font(.caption)
                .foregroundStyle(remoteMissing ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .truncationMode(.tail)
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
                NSPasteboard.general.declareTypes([.string], owner: nil)
                NSPasteboard.general.setString(hostAlias, forType: .string)
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
            Button {
                Task { await model.refreshSessions(for: project) }
            } label: {
                Text("Retry")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.leading, SidebarGrid.textInset)
        }
    }
}

private struct SessionRow: View {
    @Bindable var model: AppModel
    let session: RemoteSession

    private var isSelected: Bool { model.selectedSessionID == session.id }
    private var isArchiving: Bool { model.archivingSessions.contains(session.id) }
    private var isConnected: Bool { model.connectionPhase(for: session.id) != nil }

    /// Green = live ssh connection (selected or warm in the background);
    /// grey = no local connection. Yellow/red show connection trouble.
    private var statusColor: Color {
        switch model.connectionPhase(for: session.id) {
        case .attached: return .green
        case .connecting, .reconnecting: return .yellow
        case .ended, .failed: return .red
        case .idle, nil: return .secondary.opacity(0.5)
        }
    }

    /// What runs inside the session, as reported by its terminal title
    /// (e.g. Claude Code's "✳ task" status). Connected sessions use the
    /// live surface title; grey sessions fall back to the tmux pane title
    /// from the 30s sweep.
    private var statusTitle: String? {
        model.liveTitle(for: session.id) ?? session.paneTitle
    }

    var body: some View {
        GridRow {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
        } content: {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                    .lineLimit(1)
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
            }
        }
        .opacity(isArchiving ? 0.5 : 1)
        .contextMenu {
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
                model.confirmKillSession = session
            }
        }
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
