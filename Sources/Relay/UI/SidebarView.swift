import SwiftUI
import RelayCore

/// The sidebar's layout grid. Every row is a fixed-width glyph gutter
/// followed by text, and child rows shift by exactly one step — so the
/// text forms two clean columns (projects, sessions) and glyphs align
/// within each level. SwiftUI `Label`s are avoided on purpose: their icon
/// column metrics are private and don't line up with custom rows.
private enum SidebarGrid {
    static let glyphWidth: CGFloat = 18
    static let gap: CGFloat = 5
    static let childIndent: CGFloat = 20
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

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedSessionID) {
            if model.remotesLoaded && model.sidebarRemotes.isEmpty {
                ContentUnavailableView(
                    "No SSH Hosts",
                    systemImage: "network.slash",
                    description: Text("Add hosts to ~/.ssh/config and they'll appear here.")
                )
            } else {
                ForEach(model.sidebarRemotes, id: \.descriptor.id) { entry in
                    RemoteSection(
                        model: model,
                        descriptor: entry.descriptor,
                        missing: entry.missing,
                        hidden: entry.hidden)
                }
                if model.hasHiddenRemotes && !model.showHiddenRemotes {
                    Button {
                        model.showHiddenRemotes = true
                    } label: {
                        GridRow {
                            Image(systemName: "eye.slash")
                        } content: {
                            Text("\(model.hiddenWorkspaces.count) hidden remote\(model.hiddenWorkspaces.count == 1 ? "" : "s")")
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Show hidden remotes")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Relay")
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(model.remotes.filter { !model.hiddenWorkspaces.contains($0.id) }) { remote in
                        Button(remote.displayName) {
                            model.projectEditor = ProjectEditorContext(mode: .create(workspace: remote.id))
                        }
                    }
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .disabled(model.remotes.allSatisfy { model.hiddenWorkspaces.contains($0.id) })
                .help("Add a project to a remote")
            }
        }
        .overlay(alignment: .bottom) {
            if !model.remotesLoaded {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
            }
        }
    }
}

private struct RemoteSection: View {
    @Bindable var model: AppModel
    let descriptor: WorkspaceDescriptor
    let missing: Bool
    let hidden: Bool

    var body: some View {
        Section {
            let projects = model.projects(for: descriptor.id)
            if projects.isEmpty && !missing && !hidden {
                Button {
                    model.projectEditor = ProjectEditorContext(mode: .create(workspace: descriptor.id))
                } label: {
                    GridRow {
                        Image(systemName: "plus.circle")
                    } content: {
                        Text("Add Project…")
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ForEach(projects) { project in
                ProjectRows(model: model, project: project, remoteMissing: missing)
            }
        } header: {
            GridRow {
                Image(systemName: hidden ? "eye.slash" : (missing ? "exclamationmark.triangle" : "server.rack"))
                    .foregroundStyle(missing ? .orange : .secondary)
            } content: {
                Text(descriptor.displayName)
                if missing {
                    Text("Missing Remote")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            .opacity(hidden ? 0.5 : 1)
            .contextMenu {
                if !missing && !hidden {
                    Button("Add Project…") {
                        model.projectEditor = ProjectEditorContext(mode: .create(workspace: descriptor.id))
                    }
                }
                Button("Copy SSH Alias") {
                    NSPasteboard.general.declareTypes([.string], owner: nil)
                    NSPasteboard.general.setString(descriptor.id.opaqueID, forType: .string)
                }
                Button("Refresh") {
                    Task {
                        await model.refreshRemotes()
                        for project in model.projects(for: descriptor.id) {
                            await model.refreshSessions(for: project)
                        }
                    }
                }
                Divider()
                if hidden {
                    Button("Show Remote") {
                        model.showRemote(descriptor.id)
                    }
                } else {
                    Button("Hide Remote") {
                        model.hideRemote(descriptor.id)
                    }
                }
            }
        }
    }
}

private struct ProjectRows: View {
    @Bindable var model: AppModel
    let project: Project
    let remoteMissing: Bool

    var body: some View {
        // Project header row
        GridRow {
            Image(systemName: "folder")
                .foregroundStyle(Color.accentColor)
        } content: {
            Text(project.name)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer()
            if model.sessionsLoading.contains(project.id) {
                ProgressView().controlSize(.mini)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await model.refreshSessions(for: project) }
        }
        .contextMenu {
            Button("New Session…") { model.newSessionProject = project }
                .disabled(remoteMissing)
            Button("Project Settings…") {
                model.projectEditor = ProjectEditorContext(mode: .edit(project))
            }
            Button("Refresh Sessions") {
                Task { await model.refreshSessions(for: project) }
            }
            Divider()
            Button("Remove Project…", role: .destructive) {
                model.confirmRemoveProject = project
            }
        }

        // Session rows
        if let error = model.sessionErrors[project.id] {
            GridRow {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } content: {
                Text(error)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, SidebarGrid.childIndent)
            Button {
                Task { await model.refreshSessions(for: project) }
            } label: {
                GridRow {
                    Image(systemName: "arrow.clockwise")
                } content: {
                    Text("Retry")
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.leading, SidebarGrid.childIndent)
        }

        ForEach(model.sessions[project.id] ?? []) { session in
            SessionRow(model: model, session: session)
                .padding(.leading, SidebarGrid.childIndent)
                .tag(session.id)
        }

        // Cleanup-failed tombstones
        ForEach(model.tombstones.filter { $0.projectID == project.id }) { tombstone in
            TombstoneRow(model: model, tombstone: tombstone)
                .padding(.leading, SidebarGrid.childIndent)
        }

        // New session row
        if !remoteMissing {
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
            .padding(.leading, SidebarGrid.childIndent)
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
