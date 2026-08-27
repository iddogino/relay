import AppKit
import Observation
import RelayCore

/// Drives the single terminal attachment: connect, attached, reconnect with
/// bounded backoff, ended/error. There is at most one live surface (and one
/// local ssh child) at any time.
@MainActor
@Observable
final class TerminalAttachmentController {
    enum Phase: Equatable {
        case idle
        case connecting
        case attached
        /// Waiting to retry after an unexpected disconnect.
        case reconnecting(attempt: Int)
        /// The remote session no longer exists.
        case ended
        /// Persistent failure; manual retry available.
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var session: RemoteSession?
    private(set) var project: Project?
    private(set) var surfaceView: TerminalSurfaceView?
    private(set) var terminalTitle: String = ""

    /// Called when the controller discovers the session no longer exists.
    var onSessionEnded: ((RemoteSession) -> Void)?

    private let provider: any RuntimeProvider
    private var attachTask: Task<Void, Never>?
    private var generation = 0

    private static let backoffDelays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(10),
    ]
    private static let maxAutoRetries = 8

    init(provider: any RuntimeProvider) {
        self.provider = provider
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)
    }

    // MARK: Public API

    func attach(session: RemoteSession, project: Project) {
        detach()
        self.session = session
        self.project = project
        phase = .connecting
        startAttach(attempt: 0)
    }

    /// Terminates the local attachment only; the remote session keeps running.
    func detach() {
        generation &+= 1
        attachTask?.cancel()
        attachTask = nil
        tearDownSurface()
        session = nil
        project = nil
        terminalTitle = ""
        phase = .idle
    }

    func retryNow() {
        guard session != nil, project != nil else { return }
        switch phase {
        case .reconnecting, .failed, .connecting:
            generation &+= 1
            attachTask?.cancel()
            tearDownSurface()
            phase = .connecting
            startAttach(attempt: 0)
        default:
            break
        }
    }

    // MARK: Lifecycle internals

    private func tearDownSurface() {
        if let view = surfaceView {
            view.shutdown()
            view.removeFromSuperview()
        }
        surfaceView = nil
    }

    private func startAttach(attempt: Int) {
        guard let session, let project else { return }
        let gen = generation
        attachTask = Task { [provider] in
            do {
                let spec = try await provider.makeTerminalLaunch(for: session, project: project)
                guard !Task.isCancelled, gen == self.generation else { return }
                self.createSurface(spec: spec, attempt: attempt)
            } catch {
                guard !Task.isCancelled, gen == self.generation else { return }
                self.phase = .failed(message: error.localizedDescription)
            }
        }
    }

    private func createSurface(spec: TerminalLaunchSpec, attempt: Int) {
        // The surface runs its command as a shell command line (libghostty
        // itself wraps it in `exec -l …` via its login-shell wrapper, so no
        // exec prefix here). Every argv element is fully quoted.
        let command = POSIXShellQuote.quoteJoin([spec.executable.path] + spec.arguments)
        guard let view = TerminalSurfaceView(command: command, environment: spec.environment) else {
            phase = .failed(message: GhosttyRuntime.shared.initError ?? "Couldn't create the terminal surface.")
            return
        }
        let gen = generation
        view.onTitleChange = { [weak self] title in
            guard let self, gen == self.generation else { return }
            self.terminalTitle = title
        }
        view.onProcessExit = { [weak self] in
            guard let self, gen == self.generation else { return }
            self.handleProcessExit(previousAttempt: attempt)
        }
        surfaceView = view
        lastAttachTime = Date()
        phase = .attached
    }

    private var lastAttachTime = Date.distantPast

    /// The local ssh child exited. Never touches the remote session: decide
    /// between ended (session gone) and reconnect (transient failure).
    private func handleProcessExit(previousAttempt: Int) {
        guard let session, let project else { return }
        tearDownSurface()

        // An attachment that survived a while resets the backoff; one that
        // died immediately continues escalating it.
        let quickFailure = Date().timeIntervalSince(lastAttachTime) < 5
        let attempt = quickFailure ? previousAttempt + 1 : 0
        guard attempt < Self.maxAutoRetries else {
            phase = .failed(message: "Can't reach \(project.workspace.opaqueID). The connection keeps dropping.")
            return
        }
        phase = .reconnecting(attempt: attempt)

        let gen = generation
        let delay = Self.backoffDelays[min(attempt, Self.backoffDelays.count - 1)]
        attachTask = Task { [provider] in
            do {
                // Ask the remote whether the session still exists before
                // reattaching; never create a replacement session.
                let exists = try await provider.sessionExists(session, project: project)
                guard !Task.isCancelled, gen == self.generation else { return }
                guard exists else {
                    self.phase = .ended
                    self.onSessionEnded?(session)
                    return
                }
            } catch {
                // Host unreachable right now — keep backing off and retry.
            }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, gen == self.generation else { return }
            self.startAttach(attempt: attempt)
        }
    }

    @objc private func systemDidWake(_ note: Notification) {
        // Make reconnect-after-sleep feel immediate.
        switch phase {
        case .reconnecting, .failed:
            retryNow()
        default:
            break
        }
    }
}
