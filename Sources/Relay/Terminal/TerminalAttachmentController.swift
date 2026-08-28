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

    /// Drag & drop upload state for the attached terminal.
    enum DropActivity: Equatable {
        case idle
        /// A file drag is hovering over the terminal.
        case targeted
        case uploading(label: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var session: RemoteSession?
    private(set) var project: Project?
    private(set) var surfaceView: TerminalSurfaceView?
    private(set) var terminalTitle: String = ""
    private(set) var dropActivity: DropActivity = .idle
    /// Transient user-facing message about the last drop (error or note).
    private(set) var dropNotice: String?

    private let provider: any RuntimeProvider
    private var attachTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var dropNoticeTask: Task<Void, Never>?
    private var generation = 0
    /// Whether this attachment is the one on screen. Background (warm)
    /// attachments keep their connection and terminal state but stop
    /// rendering and report unfocused.
    private var presented = true

    /// Hands presentation (rendering + focus) to or away from this
    /// attachment; the connection itself is unaffected.
    func setPresented(_ newValue: Bool) {
        presented = newValue
        surfaceView?.setPresented(newValue)
    }

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
        // A running upload continues (its result falls back to the
        // clipboard); only the overlay state belongs to the old attachment.
        dropActivity = .idle
        dropNotice = nil
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

    private func createSurface(spec: TerminalLaunchSpec, attempt: Int, creationTry: Int = 0) {
        // The surface runs its command as a shell command line (libghostty
        // itself wraps it in `exec -l …` via its login-shell wrapper, so no
        // exec prefix here). Every argv element is fully quoted.
        let command = POSIXShellQuote.quoteJoin([spec.executable.path] + spec.arguments)
        guard let view = TerminalSurfaceView(command: command, environment: spec.environment) else {
            // ghostty_surface_new can fail transiently in the first moments
            // of a launch (a restored selection may attach before the window
            // is fully realized); retry briefly before declaring failure.
            if GhosttyRuntime.shared.initError == nil, creationTry < 6 {
                let gen = generation
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard gen == self.generation, !Task.isCancelled else { return }
                    self.createSurface(spec: spec, attempt: attempt, creationTry: creationTry + 1)
                }
                return
            }
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
        view.canAcceptFileDrop = { [weak self] in
            guard let self, gen == self.generation,
                  self.provider.capabilities.contains(.fileUpload),
                  case .attached = self.phase
            else { return false }
            if case .uploading = self.dropActivity { return false }
            return true
        }
        view.onDragTargeted = { [weak self] targeted in
            guard let self, gen == self.generation else { return }
            if case .uploading = self.dropActivity { return }
            self.dropActivity = targeted ? .targeted : .idle
        }
        view.onFilesDropped = { [weak self] urls, preferLocalPaths in
            guard let self, gen == self.generation else { return }
            self.handleFileDrop(urls: urls, preferLocalPaths: preferLocalPaths)
        }
        surfaceView = view
        view.setPresented(presented)
        lastAttachTime = Date()
        phase = .attached
    }

    // MARK: Drag & drop upload

    private func handleFileDrop(urls: [URL], preferLocalPaths: Bool) {
        guard case .attached = phase, let session, let project else { return }
        if case .uploading = dropActivity { return }
        let localPaths = urls.map(\.path)

        if preferLocalPaths {
            // ⌥-drop: classic behavior — insert the local paths.
            surfaceView?.injectText(POSIXShellQuote.quoteJoin(localPaths) + " ")
            return
        }

        let gen = generation
        let alias = project.workspace.opaqueID
        let baseLabel = urls.count == 1
            ? "Uploading \u{201C}\(urls[0].lastPathComponent)\u{201D} to \(alias)…"
            : "Uploading \(urls.count) items to \(alias)…"
        dropActivity = .uploading(label: baseLabel)

        // Upgrade the label with a size once it's known; never delay the
        // transfer for it (large trees can take a moment to measure).
        Task { @MainActor [weak self] in
            let size = await Task.detached { Self.measureDropSize(paths: localPaths) }.value
            guard let size, let self, gen == self.generation,
                  case .uploading = self.dropActivity else { return }
            let sizeLabel = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            self.dropActivity = .uploading(label: baseLabel.replacingOccurrences(
                of: "…", with: " (\(sizeLabel))…"))
        }

        uploadTask = Task { [provider] in
            do {
                let remotePaths = try await provider.uploadFiles(
                    localPaths: localPaths, for: session, project: project)
                let pasteText = POSIXShellQuote.quoteJoin(remotePaths) + " "
                guard gen == self.generation else {
                    // The user switched sessions mid-upload: don't type into
                    // an unrelated terminal — hand the result over instead.
                    NSPasteboard.general.declareTypes([.string], owner: nil)
                    NSPasteboard.general.setString(String(pasteText.dropLast()), forType: .string)
                    self.showDropNotice("Upload to \(alias) finished after the session changed — remote path copied to the clipboard.")
                    return
                }
                self.surfaceView?.injectText(pasteText)
                self.dropActivity = .idle
            } catch is CancellationError {
                if gen == self.generation {
                    self.dropActivity = .idle
                    self.showDropNotice("Upload canceled.")
                }
            } catch {
                if gen == self.generation {
                    self.dropActivity = .idle
                    self.showDropNotice(error.localizedDescription)
                } else {
                    self.showDropNotice("Upload to \(alias) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelUpload() {
        uploadTask?.cancel()
    }

    private func showDropNotice(_ message: String) {
        dropNotice = message
        dropNoticeTask?.cancel()
        dropNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self.dropNotice = nil
        }
    }

    /// Total size of the dropped items (recursive), or nil when it can't be
    /// measured quickly. Bounded so a giant tree can't stall the label.
    private nonisolated static func measureDropSize(paths: [String]) -> Int64? {
        let fm = FileManager.default
        var total: Int64 = 0
        var visited = 0
        for path in paths {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let enumerator = fm.enumerator(atPath: path) else { continue }
                while let entry = enumerator.nextObject() as? String {
                    visited += 1
                    if visited > 50_000 { return nil }
                    let attrs = try? fm.attributesOfItem(atPath: (path as NSString).appendingPathComponent(entry))
                    total += (attrs?[.size] as? Int64) ?? 0
                }
            } else {
                let attrs = try? fm.attributesOfItem(atPath: path)
                total += (attrs?[.size] as? Int64) ?? 0
            }
        }
        return total
    }

    private var lastAttachTime = Date.distantPast

    /// The local ssh child exited. Never touches the remote session: decide
    /// between ended (session gone) and reconnect (transient failure).
    private func handleProcessExit(previousAttempt: Int) {
        guard let session, let project else { return }
        tearDownSurface()

        // An attachment that survived a while resets the backoff; one that
        // died quickly continues escalating it. The threshold must exceed the
        // ssh ConnectTimeout so slow connection failures still escalate and
        // the bounded-retry limit stays reachable.
        let quickFailure = Date().timeIntervalSince(lastAttachTime) < 30
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
