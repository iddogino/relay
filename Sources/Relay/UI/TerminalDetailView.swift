import SwiftUI
import RelayCore

struct TerminalDetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let session = model.selectedSession, let project = model.selectedProject {
                VStack(spacing: 0) {
                    TerminalHeaderBar(
                        project: project,
                        session: session,
                        terminalTitle: model.attachment.terminalTitle,
                        phase: model.attachment.phase)
                    Divider()
                    TerminalStage(model: model, session: session, project: project)
                }
            } else {
                EmptyDetailView(model: model)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if let project = model.selectedProject {
                    Button {
                        model.newSessionProject = project
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                    .help("New session in \(project.name) (⌘N)")
                }
            }
        }
    }
}

private struct TerminalHeaderBar: View {
    let project: Project
    let session: RemoteSession
    let terminalTitle: String
    let phase: TerminalAttachmentController.Phase

    private var statusText: String? {
        switch phase {
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .ended: return "Ended"
        case .failed: return "Disconnected"
        case .attached, .idle: return nil
        }
    }

    private var statusColor: Color {
        switch phase {
        case .attached: return .green
        case .connecting, .reconnecting: return .yellow
        case .ended, .failed: return .red
        case .idle: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            HStack(spacing: 5) {
                Text(project.name)
                    .foregroundStyle(.secondary)
                Text("/")
                    .foregroundStyle(.tertiary)
                Text(session.displayName)
                    .fontWeight(.medium)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(project.workspace.opaqueID)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .lineLimit(1)

            Spacer()

            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !terminalTitle.isEmpty {
                Text(terminalTitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct TerminalStage: View {
    @Bindable var model: AppModel
    let session: RemoteSession
    let project: Project

    var body: some View {
        ZStack {
            // Terminal background: match the surface's reported background
            // when available so resize gaps don't flash.
            Color(nsColor: model.attachment.surfaceView?.terminalBackgroundColor ?? .textBackgroundColor)
                .ignoresSafeArea()

            if let surfaceView = model.attachment.surfaceView {
                TerminalHostView(surfaceView: surfaceView)
            }

            switch model.attachment.phase {
            case .connecting:
                OverlayCard {
                    ProgressView()
                    Text("Connecting to \(project.workspace.opaqueID)…")
                        .foregroundStyle(.secondary)
                }
            case .reconnecting(let attempt):
                OverlayCard {
                    ProgressView()
                    Text("Reconnecting to \(project.workspace.opaqueID)…")
                        .foregroundStyle(.secondary)
                    if attempt > 1 {
                        Text("Attempt \(attempt + 1)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Button("Retry Now") { model.attachment.retryNow() }
                }
            case .ended:
                OverlayCard {
                    Image(systemName: "moon.zzz")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("This session no longer exists on \(project.workspace.opaqueID).")
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("Remove From Sidebar") {
                            model.clearEndedSession(session)
                        }
                        Button("New Session…") {
                            model.clearEndedSession(session)
                            model.newSessionProject = project
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .failed(let message):
                OverlayCard {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button("Retry") { model.attachment.retryNow() }
                        .buttonStyle(.borderedProminent)
                }
            case .attached, .idle:
                EmptyView()
            }
        }
    }
}

private struct OverlayCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 12) {
            content
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 18, y: 8)
        .padding()
    }
}

private struct EmptyDetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Relay", systemImage: "terminal")
        } description: {
            if model.projects.isEmpty {
                Text("Add a project to a remote to get started.")
            } else {
                Text("Select a session, or create one with ⌘N.")
            }
        } actions: {
            if model.projects.isEmpty, let firstRemote = model.remotes.first {
                Button("Add Project…") {
                    model.projectEditor = ProjectEditorContext(mode: .create(workspace: firstRemote.id))
                }
                .buttonStyle(.borderedProminent)
            } else if let project = model.selectedProject ?? model.projects.first {
                Button("New Session…") {
                    model.newSessionProject = project
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Hosts the AppKit terminal surface inside SwiftUI and keeps it focused.
private struct TerminalHostView: NSViewRepresentable {
    let surfaceView: TerminalSurfaceView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if surfaceView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            surfaceView.frame = container.bounds
            surfaceView.autoresizingMask = [.width, .height]
            container.addSubview(surfaceView)
            DispatchQueue.main.async {
                surfaceView.window?.makeFirstResponder(surfaceView)
            }
        }
    }
}
