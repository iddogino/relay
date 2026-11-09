import SwiftUI
import RelayCore

/// The window: projects and sessions in the sidebar, the selected
/// session's terminal beside it. On iPhone the split collapses to a stack:
/// the session list, then one terminal.
struct MainWindowView: View {
    @Bindable var model: AppModel
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    /// The GitHub sign-in, from the window — unless Settings is up (on iOS
    /// a sheet itself), which presents it over itself instead.
    private var gitHubLoginPresented: Binding<Bool> {
        Binding(
            get: { model.gitHubLoginPresented && !settingsShowing },
            set: { model.gitHubLoginPresented = $0 })
    }

    private var settingsShowing: Bool {
        #if os(iOS)
        model.settingsPresented
        #else
        false
        #endif
    }

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                #if os(iOS)
                // Session names and their status lines need the room on an
                // iPad (an iPhone shows the list full width).
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 440)
                #else
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
                #endif
        } detail: {
            TerminalDetailView(model: model)
                #if os(iOS)
                .toolbar {
                    // With the sidebar collapsed, the way back to it (the
                    // terminal's own toolbar leaves none).
                    if !Platform.isPhone && columnVisibility == .detailOnly {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation { columnVisibility = .all }
                            } label: {
                                Label("Show Sidebar", systemImage: "sidebar.left")
                            }
                            .accessibilityIdentifier("showSidebar")
                        }
                    }
                }
                #endif
        }
        #if os(macOS)
        // Closing the window is a detach-only operation: the local ssh
        // attachment ends, the remote session keeps running.
        .background(WindowCloseObserver {
            model.windowDidClose()
        })
        #else
        .preferredColorScheme(model.appearance.colorScheme)
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(to: phase)
        }
        .sheet(isPresented: $model.settingsPresented) {
            SettingsSheet(model: model)
        }
        .sheet(item: $model.hostToSetUp) { host in
            HostEditorSheet(model: model, mode: .edit(host)) { _ in
                Task { await model.refreshAll() }
            }
        }
        #endif
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")))
        }
        .sheet(item: $model.projectEditor) { context in
            ProjectEditorSheet(model: model, context: context)
        }
        .sheet(item: $model.newSessionProject) { project in
            NewSessionSheet(model: model, project: project)
        }
        .sheet(isPresented: $model.createSheetPresented) {
            CreateSheet(model: model)
        }
        .sheet(isPresented: gitHubLoginPresented) {
            GitHubLoginSheet(model: model)
        }
        .confirmationDialog(
            "Kill Session?",
            isPresented: killDialogPresented,
            titleVisibility: .visible,
            presenting: model.confirmKillSession
        ) { session in
            Button("Kill \u{201C}\(session.displayName)\u{201D}", role: .destructive) {
                Task { await model.killSession(session) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("This force-kills the remote session and everything running in it. The project's cleanup command will NOT run — any user-managed cleanup (like removing a worktree) is skipped.")
        }
        .confirmationDialog(
            "Remove Project?",
            isPresented: removeProjectDialogPresented,
            titleVisibility: .visible,
            presenting: model.confirmRemoveProject
        ) { project in
            Button("Remove \u{201C}\(project.name)\u{201D}", role: .destructive) {
                model.removeProject(project)
            }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            let count = model.sessions[project.id]?.count ?? 0
            if count > 0 {
                Text("This only removes the project from Relay. \(count) running session\(count == 1 ? "" : "s") will keep running on \(project.workspace.opaqueID). No remote files are deleted.")
            } else {
                Text("This only removes the project from Relay. No remote files are deleted.")
            }
        }
    }

    private var killDialogPresented: Binding<Bool> {
        Binding(
            get: { model.confirmKillSession != nil },
            set: { if !$0 { model.confirmKillSession = nil } })
    }

    private var removeProjectDialogPresented: Binding<Bool> {
        Binding(
            get: { model.confirmRemoveProject != nil },
            set: { if !$0 { model.confirmRemoveProject = nil } })
    }
}

#if os(macOS)
/// Invokes `onClose` when this view's own window closes.
private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    final class ObserverView: NSView {
        var onClose: (() -> Void)?
        private var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            if let observedWindow {
                center.removeObserver(self, name: NSWindow.willCloseNotification, object: observedWindow)
            }
            observedWindow = window
            if let window {
                center.addObserver(
                    self, selector: #selector(windowWillClose(_:)),
                    name: NSWindow.willCloseNotification, object: window)
            }
        }

        @objc private func windowWillClose(_ note: Notification) {
            onClose?()
        }
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onClose = onClose
    }
}
#endif
