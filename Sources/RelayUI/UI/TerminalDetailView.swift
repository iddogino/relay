import SwiftUI
import RelayCore

struct TerminalDetailView: View {
    @Bindable var model: AppModel
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var keyboard = KeyboardObserver.shared

    init(model: AppModel) {
        self.model = model
    }

    /// An iPhone on its side with the keyboard up has room for a few rows;
    /// the navigation bar gives way (hiding the keyboard brings it back).
    private var navigationBarHidden: Bool {
        verticalSizeClass == .compact && keyboard.softwareKeyboardShown
    }
    #endif

    var body: some View {
        Group {
            if let session = model.selectedSession, let project = model.selectedProject {
                #if os(macOS)
                VStack(spacing: 0) {
                    TerminalHeaderBar(
                        project: project,
                        session: session,
                        terminalTitle: model.attachment.terminalTitle,
                        phase: model.attachment.phase)
                    Divider()
                    TerminalStage(model: model, session: session, project: project)
                }
                #else
                // The header's line is the navigation bar's title here.
                TerminalStage(model: model, session: session, project: project)
                    .navigationTitle(session.displayName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(navigationBarHidden ? .hidden : .automatic, for: .navigationBar)
                    .animation(.default, value: navigationBarHidden)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            TerminalNavigationTitle(
                                project: project, session: session, phase: model.attachment.phase)
                        }
                        TerminalToolbarItems(model: model, session: session, project: project)
                    }
                #endif
            } else if model.selectedSessionIDs.count > 1, model.selectedSessions.count > 1 {
                MultipleSelectionView(sessionCount: model.selectedSessions.count)
            } else {
                EmptyDetailView(model: model)
            }
        }
        #if os(macOS)
        .toolbar {
            ToolbarItemGroup {
                if let project = model.selectedProject,
                   let load = model.selectedMachineLoad {
                    MachineLoadBadge(
                        model: model,
                        machineName: model.remotes.first { $0.id == project.workspace }?.displayName
                            ?? project.workspace.opaqueID,
                        history: load)
                }
                if let session = model.selectedSession,
                   let git = model.gitState(for: session.id) {
                    if let pr = git.pullRequest {
                        PRBadge(model: model, sessionID: session.id, pr: pr)
                    }
                    Button {
                        model.diffTrayVisible.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Text("+\(git.additions)")
                                .foregroundStyle(.green)
                            Text("−\(git.deletions)")
                                .foregroundStyle(.red)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                    .help("Changes on \(git.branch)\(git.baseRef.map { " vs \($0)" } ?? "") — click for the diff")
                }
            }
        }
        // AppKit lays the detail column's title-bar background out from
        // the split divider's 4pt hit area, so it starts ~2pt inside the
        // sidebar — visible as an overhang whenever the window is key (the
        // two sections differ in shade). Without that background the title
        // bar shows the window's own material, flush with the sidebar.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        .inspector(isPresented: $model.diffTrayVisible) {
            DiffTrayView(model: model)
                .inspectorColumnWidth(min: 340, ideal: 480, max: 900)
        }
    }
}

private struct TerminalHeaderBar: View {
    let project: Project
    let session: RemoteSession
    let terminalTitle: String
    let phase: TerminalAttachmentController.Phase

    private var statusText: String? { phase.statusText }

    private var statusColor: Color { phase.statusColor }

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
        // Shape-style backgrounds ignore every safe-area edge by default,
        // which stretched this bar up under the toolbar and left under the
        // sidebar divider — a band overhanging the column edge.
        .background(.bar, ignoresSafeAreaEdges: [])
    }
}

private struct TerminalStage: View {
    @Bindable var model: AppModel
    let session: RemoteSession
    let project: Project

    var body: some View {
        ZStack {
            // Terminal background: match the surface's reported background
            // when available so resize gaps don't flash. Bottom edge only:
            // the column's top/leading safe areas reach under the toolbar
            // and the sidebar divider, and the dark terminal color bleeding
            // there shows through the (translucent) title-bar separator and
            // divider as a black line overhanging the column edge.
            #if os(macOS)
            Color(nsColor: model.attachment.surfaceView?.terminalBackgroundColor ?? .textBackgroundColor)
                .ignoresSafeArea(edges: .bottom)
            #else
            // The terminal's own background (its theme's) until it reports
            // one, so nothing flashes around it as it resizes.
            Color(uiColor: model.attachment.surfaceView?.terminalBackgroundColor
                  ?? GhosttyRuntime.shared.configuredBackground ?? .black)
                .ignoresSafeArea(.container, edges: .bottom)
            #endif

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

            dropOverlays
        }
    }

    @ViewBuilder private var dropOverlays: some View {
        switch model.attachment.dropActivity {
        case .targeted:
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(6)
                VStack(spacing: 6) {
                    Image(systemName: "arrow.up.doc")
                        .font(.title)
                    Text("Drop to upload to \(project.workspace.opaqueID)")
                        .fontWeight(.medium)
                    Text("Hold ⌥ to insert the local path instead")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .allowsHitTesting(false)
        case .uploading(let label, let fraction, let detail):
            OverlayCard {
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 280)
                        .animation(.linear(duration: 0.3), value: fraction)
                } else {
                    ProgressView()
                }
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { model.attachment.cancelUpload() }
            }
        case .idle:
            EmptyView()
        }

        if let notice = model.previewNotice {
            VStack {
                Spacer()
                Text(notice)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 10, y: 4)
                    .padding(.bottom, 16)
            }
            .transition(.opacity)
            .allowsHitTesting(false)
        }

        if let notice = model.attachment.dropNotice {
            VStack {
                Spacer()
                Text(notice)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 10, y: 4)
                    .padding(.bottom, 16)
            }
            .transition(.opacity)
            .allowsHitTesting(false)
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

/// Several sessions selected in the sidebar, Mail-style: no terminal, just
/// how many and where their actions are.
private struct MultipleSelectionView: View {
    let sessionCount: Int

    var body: some View {
        ContentUnavailableView {
            Label("\(sessionCount) Sessions Selected", systemImage: "square.stack")
        } description: {
            Text("Right-click the selection to act on all of them, or use the Session menu.")
        }
    }
}

private struct EmptyDetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Relay", systemImage: "terminal")
        } description: {
            if model.projects.isEmpty {
                Text("Add a project — a folder on one of your hosts — to get started.")
            } else if Platform.isTouch {
                Text("Select a session, or create one.")
            } else {
                Text("Select a session, or create one with ⌘N.")
            }
        } actions: {
            if model.projects.isEmpty {
                Button("Add Project…") {
                    model.projectEditor = ProjectEditorContext(mode: .create(workspace: nil))
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

#if os(macOS)
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
#else
/// Hosts the UIKit terminal surface inside SwiftUI. With a hardware
/// keyboard it takes keys right away; otherwise a tap brings up the
/// software keyboard (which would cover half the terminal unasked).
private struct TerminalHostView: UIViewRepresentable {
    let surfaceView: TerminalSurfaceView

    func makeUIView(context: Context) -> UIView {
        UIView()
    }

    func updateUIView(_ container: UIView, context: Context) {
        if surfaceView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            surfaceView.frame = container.bounds
            surfaceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(surfaceView)
            if TerminalSurfaceView.hardwareKeyboardConnected {
                DispatchQueue.main.async { _ = surfaceView.becomeFirstResponder() }
            }
        }
    }
}

/// The terminal screen's title: the session, and under it the project
/// and host with the connection's state.
private struct TerminalNavigationTitle: View {
    let project: Project
    let session: RemoteSession
    let phase: TerminalAttachmentController.Phase

    private var statusColor: Color { phase.statusColor }

    private var statusText: String? { phase.statusText }

    var body: some View {
        VStack(spacing: 1) {
            Text(session.displayName)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusText ?? "\(project.name) · \(project.workspace.opaqueID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal.title")
    }
}

/// The terminal screen's buttons: the machine's load and the PR (with
/// room for them), the changes, and the session's actions.
/// The terminal's toolbar on iOS, each part in a pill of its own: a
/// popover or menu grows out of its item's pill, which would take the
/// others with it if they shared one.
private struct TerminalToolbarItems: ToolbarContent {
    @Bindable var model: AppModel
    let session: RemoteSession
    let project: Project

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some ToolbarContent {
        // The load and the pull request: wide layouts (the menu has the
        // pull request otherwise).
        if sizeClass == .regular, let load = model.selectedMachineLoad {
            ToolbarItem(placement: .topBarTrailing) {
                MachineLoadBadge(
                    model: model,
                    machineName: model.remotes.first { $0.id == project.workspace }?.displayName
                        ?? project.workspace.opaqueID,
                    history: load)
            }
            separator
        }
        if sizeClass == .regular, let pr = model.gitState(for: session.id)?.pullRequest {
            ToolbarItem(placement: .topBarTrailing) {
                PRBadge(model: model, sessionID: session.id, pr: pr)
            }
            separator
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            SessionToolbarItems(model: model, session: session, project: project)
        }
    }

    @ToolbarContentBuilder
    private var separator: some ToolbarContent {
        if #available(iOS 26, *) {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
    }
}

/// The changes (opening the diff tray) and the session's menu.
private struct SessionToolbarItems: View {
    @Bindable var model: AppModel
    let session: RemoteSession
    let project: Project
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let git = model.gitState(for: session.id)
        if let git {
            Button {
                model.diffTrayVisible.toggle()
            } label: {
                HStack(spacing: 3) {
                    Text("+\(git.additions)")
                        .foregroundStyle(.green)
                    Text("−\(git.deletions)")
                        .foregroundStyle(.red)
                }
                .font(.system(size: 13, design: .monospaced))
            }
            .accessibilityLabel("Changes: \(git.additions) added, \(git.deletions) removed")
        }
        Menu {
            if sizeClass != .regular, let pr = git?.pullRequest {
                Button {
                    Platform.open(pr.url)
                } label: {
                    Label("Pull Request #\(pr.number)", systemImage: "arrow.triangle.pull")
                }
            }
            Button {
                model.attachment.retryNow()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            Button {
                model.newSessionProject = project
            } label: {
                Label("New Session…", systemImage: "plus")
            }
            Divider()
            Button {
                Task { await model.archiveSession(session) }
            } label: {
                Label("Archive Session", systemImage: "archivebox")
            }
            Button(role: .destructive) {
                model.confirmKillSessions = [session]
            } label: {
                Label("Kill Session…", systemImage: "xmark.octagon")
            }
        } label: {
            Label("Session", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("terminal.menu")
    }
}
#endif
