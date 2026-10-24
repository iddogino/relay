import AppKit
import RelayGhosttyIO
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
        /// `fraction` is nil until progress is measurable (indeterminate);
        /// `detail` is the size/rate line under the label.
        case uploading(label: String, fraction: Double?, detail: String?)
    }

    private(set) var phase: Phase = .idle
    private(set) var session: RemoteSession?
    private(set) var project: Project?
    private(set) var surfaceView: TerminalSurfaceView?
    /// The SSH session behind a built-in-client terminal.
    private var terminalLink: SSHTerminalLink?
    private(set) var terminalTitle: String = "" {
        didSet { onLiveTitleChange?(terminalTitle) }
    }
    /// Fired on every live title change so the app can push it into the
    /// sidebar's observed session list. Without it a green *background*
    /// session's caption only refreshes when the row re-renders for some
    /// other reason (focus, or the 30s sweep) — the live value is there but
    /// the row reads it cross-object and SwiftUI never invalidates on it.
    @ObservationIgnored var onLiveTitleChange: ((String) -> Void)?
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
        terminalLink?.close()
        terminalLink = nil
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
        let created = Self.makeSurface(spec: spec, command: command)
        guard let view = created?.view else {
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
        terminalLink = created?.link
        terminalLink?.start()
        view.setPresented(presented)
        lastAttachTime = Date()
        phase = .attached
    }

    /// The surface for `spec`: a local `ssh` process, or — when the
    /// built-in client takes this host's terminals — a manual-I/O surface
    /// and the SSH session that feeds it (started by the caller).
    private static func makeSurface(spec: TerminalLaunchSpec, command: String) -> (view: TerminalSurfaceView, link: SSHTerminalLink?)? {
        guard let builtIn = spec.builtIn else {
            return TerminalSurfaceView(command: command, environment: spec.environment).map { ($0, nil) }
        }
        let io = ManualTerminalIO()
        guard let view = TerminalSurfaceView(manualIO: io) else { return nil }
        let link = SSHTerminalLink(
            io: io,
            pool: builtIn.pool,
            configuration: .init(target: builtIn.target, command: builtIn.command, environment: builtIn.environment),
            onEnd: { _, openError in
                // The surface reports the end like a process exit (and the
                // reconnect logic takes it from there); an open failure
                // also moves this host to the system ssh for a while.
                if let openError { builtIn.reportOpenFailure(openError) }
            })
        return (view, link)
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
        let label = urls.count == 1
            ? "Uploading \u{201C}\(urls[0].lastPathComponent)\u{201D} to \(alias)…"
            : "Uploading \(urls.count) items to \(alias)…"
        dropActivity = .uploading(label: label, fraction: nil, detail: nil)
        let tracker = UploadProgressTracker(
            singleFile: urls.count == 1 && !((try? urls[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false))

        // Measure the total once, off the main actor; never delay the
        // transfer for it (large trees can take a moment to measure).
        Task { @MainActor [weak self] in
            let size = await Task.detached { Self.measureDropSize(paths: localPaths) }.value
            guard let size, let self, gen == self.generation,
                  case .uploading = self.dropActivity else { return }
            tracker.totalBytes = size
            self.dropActivity = .uploading(label: label, fraction: tracker.fraction, detail: tracker.detail)
        }

        uploadTask = Task { [provider] in
            do {
                let remotePaths = try await provider.uploadFiles(
                    localPaths: localPaths, for: session, project: project,
                    progress: { update in
                        Task { @MainActor [weak self] in
                            guard let self, gen == self.generation,
                                  case .uploading = self.dropActivity else { return }
                            tracker.record(update)
                            self.dropActivity = .uploading(label: label, fraction: tracker.fraction, detail: tracker.detail)
                        }
                    })
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

    /// Turns raw scp progress into the overlay's bar fraction and detail
    /// line. Main-actor only.
    @MainActor private final class UploadProgressTracker {
        let singleFile: Bool
        var totalBytes: Int64?
        private var latest: UploadProgress?
        private var firstSample: (time: ContinuousClock.Instant, bytes: Int64)?

        init(singleFile: Bool) { self.singleFile = singleFile }

        func record(_ update: UploadProgress) {
            latest = update
            if firstSample == nil { firstSample = (.now, update.bytesTransferred) }
        }

        /// One file: scp's exact percentage. Several: approximate bytes over
        /// the measured total, held short of full until scp actually exits.
        var fraction: Double? {
            guard let latest else { return nil }
            if singleFile { return latest.currentFileFraction }
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(Double(latest.bytesTransferred) / Double(totalBytes), 0.99)
        }

        /// "120 MB of 300 MB · 19.7 MB/s · 9s left", degrading gracefully.
        var detail: String? {
            let fmt = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
            guard let latest else { return totalBytes.map(fmt) }
            let sent = totalBytes.map { total in
                singleFile ? Int64(latest.currentFileFraction * Double(total)) : min(latest.bytesTransferred, total)
            } ?? latest.bytesTransferred
            var parts = [totalBytes.map { "\(fmt(sent)) of \(fmt($0))" } ?? fmt(sent)]
            if let firstSample {
                let elapsed = (ContinuousClock.now - firstSample.time) / .seconds(1)
                let rate = Double(latest.bytesTransferred - firstSample.bytes) / elapsed
                if elapsed >= 1, rate > 0 {
                    parts.append("\(fmt(Int64(rate)))/s")
                    if let totalBytes, totalBytes > sent {
                        let remaining = Double(totalBytes - sent) / rate
                        let formatter = DateComponentsFormatter()
                        formatter.unitsStyle = .abbreviated
                        formatter.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute, .second]
                        formatter.maximumUnitCount = 2
                        if let text = formatter.string(from: max(remaining, 1)) { parts.append("\(text) left") }
                    }
                }
            }
            return parts.joined(separator: " · ")
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
