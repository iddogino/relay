import SwiftUI
import RelayCore

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
                        Label("\(model.hiddenWorkspaces.count) hidden remote\(model.hiddenWorkspaces.count == 1 ? "" : "s")", systemImage: "eye.slash")
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
                    Label("Add Project…", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ForEach(projects) { project in
                ProjectRows(model: model, project: project, remoteMissing: missing)
            }
        } header: {
            HStack(spacing: 5) {
                Image(systemName: hidden ? "eye.slash" : (missing ? "exclamationmark.triangle" : "server.rack"))
                    .foregroundStyle(missing ? .orange : .secondary)
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
        HStack(spacing: 6) {
            Label {
                Text(project.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "folder")
                    .foregroundStyle(Color.accentColor)
            }
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
            Label {
                Text(error)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .padding(.leading, 12)
            Button {
                Task { await model.refreshSessions(for: project) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.leading, 12)
        }

        ForEach(model.sessions[project.id] ?? []) { session in
            SessionRow(model: model, session: session)
                .padding(.leading, 12)
                .tag(session.id)
        }

        // Cleanup-failed tombstones
        ForEach(model.tombstones.filter { $0.projectID == project.id }) { tombstone in
            TombstoneRow(model: model, tombstone: tombstone)
                .padding(.leading, 12)
        }

        // New session row
        if !remoteMissing {
            Button {
                model.newSessionProject = project
            } label: {
                Label("New Session", systemImage: "plus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
        }
    }
}

private struct SessionRow: View {
    @Bindable var model: AppModel
    let session: RemoteSession

    private var isSelected: Bool { model.selectedSessionID == session.id }
    private var isArchiving: Bool { model.archivingSessions.contains(session.id) }

    private var statusColor: Color {
        guard isSelected else { return .secondary.opacity(0.5) }
        switch model.attachment.phase {
        case .attached: return .green
        case .connecting, .reconnecting: return .yellow
        case .ended, .failed: return .red
        case .idle: return .secondary.opacity(0.5)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(session.displayName)
                .lineLimit(1)
            Spacer()
            if isArchiving {
                ProgressView().controlSize(.mini)
            }
        }
        .opacity(isArchiving ? 0.5 : 1)
        .contextMenu {
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                    .foregroundStyle(.orange)
                Text(tombstone.session.displayName)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                if isRetrying {
                    ProgressView().controlSize(.mini)
                }
            }
            Text("Cleanup failed")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.leading, 21)
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
