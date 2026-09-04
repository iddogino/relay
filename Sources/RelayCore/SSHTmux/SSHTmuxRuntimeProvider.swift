import CryptoKit
import Foundation

/// v1 runtime provider: existing SSH hosts + vanilla remote tmux.
///
/// This is the only production module that knows the combined SSH+tmux
/// lifecycle. It never installs anything remotely and only ever targets
/// tmux sessions carrying the app's own metadata.
public struct SSHTmuxRuntimeProvider: RuntimeProvider {
    public let id = ProviderID.sshTmux
    public let capabilities: RuntimeCapabilities = [.persistentSessions, .staticWorkspaces, .fileUpload]

    /// Minimum remote tmux version (needed for `new-session -e`).
    public static let minimumTmuxVersion = (major: 3, minor: 2)

    static let tmuxPathMetadataKey = "tmuxPath"
    static let tmuxVersionMetadataKey = "tmuxVersion"

    private let runner: SSHCommandRunner
    private let configPath: String

    public init(runner: SSHCommandRunner = SSHCommandRunner(), sshConfigPath: String = SSHConfigDiscovery.defaultConfigPath) {
        self.runner = runner
        self.configPath = sshConfigPath
    }

    // MARK: Workspaces

    public func discoverWorkspaces() async throws -> [WorkspaceDescriptor] {
        let path = configPath
        let aliases = SSHConfigDiscovery.discoverAliases(configPath: path)
        return aliases.map { alias in
            WorkspaceDescriptor(
                id: WorkspaceRef(provider: id, opaqueID: alias),
                displayName: alias,
                providerID: id
            )
        }
    }

    // MARK: Validation

    public func validate(project: Project) async throws -> ProjectValidation {
        let alias = try self.alias(for: project)
        let pathInput: String
        switch RemotePath.validateInput(project.pathInput) {
        case .success(let value): pathInput = value
        case .failure(let error): throw error
        }

        let result = try await run(alias: alias, script: SSHTmuxScripts.validate(pathInput: pathInput))
        let markers = result.markers()

        switch (result.exitCode, markers[SSHTmuxScripts.Marker.status]) {
        case (0, "ok"):
            break
        case (21, _), (_, "no_tmux"):
            throw RuntimeProviderError.prerequisiteMissing(
                workspace: alias,
                what: "tmux",
                remedy: "Install tmux on the remote host, then retry."
            )
        case (22, _), (_, "no_dir"):
            throw RuntimeProviderError.pathInvalid(workspace: alias, path: project.pathInput)
        default:
            throw mapFailure(alias: alias, result: result)
        }

        guard let resolvedPath = markers[SSHTmuxScripts.Marker.resolvedPath], !resolvedPath.isEmpty else {
            throw RuntimeProviderError.operationFailed("Validation did not return a canonical path.")
        }
        let tmuxPath = markers[SSHTmuxScripts.Marker.tmuxPath] ?? ""
        let versionString = markers[SSHTmuxScripts.Marker.tmuxVersion] ?? "unknown"

        if let version = Self.parseTmuxVersion(versionString) {
            let min = Self.minimumTmuxVersion
            if version.major < min.major || (version.major == min.major && version.minor < min.minor) {
                throw RuntimeProviderError.prerequisiteMissing(
                    workspace: alias,
                    what: "tmux \(min.major).\(min.minor) or newer (found \(versionString))",
                    remedy: "Update tmux on the remote host, then retry."
                )
            }
        }

        var metadata: [String: String] = [:]
        if Self.isSafeExecutablePath(tmuxPath) {
            metadata[Self.tmuxPathMetadataKey] = tmuxPath
        }
        metadata[Self.tmuxVersionMetadataKey] = versionString

        return ProjectValidation(
            resolvedPath: resolvedPath,
            runtimeMetadata: metadata,
            notes: ["\(versionString) at \(tmuxPath)"]
        )
    }

    // MARK: Directory autocomplete

    public func listChildDirectories(workspace: WorkspaceRef, pathInput: String) async throws -> [String] {
        let alias = try self.alias(for: workspace)
        guard case .success(let path) = RemotePath.validateInput(pathInput) else { return [] }
        let result: SSHCommandRunner.CommandResult
        do {
            // Short timeout: a suggestion that arrives late is a suggestion
            // nobody wanted.
            result = try await runner.runScript(
                alias: alias,
                script: SSHTmuxScripts.listChildDirectories(pathInput: path),
                timeout: .seconds(8)
            )
        } catch {
            return []
        }
        guard result.exitCode == 0, result.markers()[SSHTmuxScripts.Marker.status] == "ok" else {
            return []
        }
        return result.stdout.split(separator: "\n").compactMap { line -> String? in
            guard line.first == "D" else { return nil }
            let name = String(line.dropFirst())
            guard !name.isEmpty, !POSIXShellQuote.containsControlCharacters(name) else { return nil }
            return name
        }
    }

    // MARK: Sessions

    public func listSessions(for project: Project) async throws -> [RemoteSession] {
        let alias = try self.alias(for: project)
        let result = try await run(
            alias: alias,
            script: SSHTmuxScripts.listSessions(knownTmuxPath: knownTmuxPath(for: project))
        )
        guard result.exitCode == 0, result.markers()[SSHTmuxScripts.Marker.status] == "ok" else {
            throw mapFailure(alias: alias, result: result)
        }

        return result.stdout
            .split(separator: "\n")
            .compactMap { TmuxSessionCodec.parse(line: String($0)) }
            .filter { $0.projectID == project.id }
            .map { discovered in
                RemoteSession(
                    id: discovered.sessionID,
                    projectID: discovered.projectID,
                    displayName: discovered.displayName,
                    createdAt: discovered.createdAt,
                    backendID: discovered.tmuxName,
                    launchSlug: discovered.launchSlug,
                    cleanup: discovered.cleanup,
                    paneTitle: discovered.paneTitle
                )
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func createSession(for project: Project, request: NewSessionRequest) async throws -> RemoteSession {
        let alias = try self.alias(for: project)
        let displayName: String
        switch SessionNameValidator.validate(request.displayName) {
        case .success(let value): displayName = value
        case .failure(let error): throw error
        }

        let sessionID = SessionID()
        let tmuxName = TmuxNaming.generateSessionName()
        let createdAt = Date()

        // The slug is remembered as metadata because the launch environment
        // bakes it into paths (worktree presets): cleanup must reuse the
        // launch-time value even if the session is later renamed. The cleanup
        // choice is remembered for the same reason: archive must undo what
        // this launch created, not what the project's defaults say later.
        let slug = SessionSlug.make(displayName: displayName, sessionID: sessionID)
        let (launchCommand, cleanup) = Self.resolveStart(request.start, project: project)
        var metadata: [(String, String)] = [
            ("@rterm_schema", TmuxSessionCodec.schemaVersion),
            ("@rterm_project_id", project.id.uuid.uuidString),
            ("@rterm_session_id", sessionID.uuid.uuidString),
            ("@rterm_session_name_b64", TmuxSessionCodec.encodeDisplayName(displayName)),
            ("@rterm_created_at", String(Int(createdAt.timeIntervalSince1970))),
            ("@rterm_slug", slug),
            ("@rterm_cleanup", TmuxSessionCodec.encodeCleanup(cleanup)),
        ]
        for (key, value) in request.extraMetadata.sorted(by: { $0.key < $1.key }) {
            guard key.hasPrefix("@"),
                  key.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  !POSIXShellQuote.containsControlCharacters(value)
            else {
                throw RuntimeProviderError.invalidInput("Invalid session metadata key: \(key)")
            }
            metadata.append((key, value))
        }

        let context = SSHTmuxScripts.CreateContext(
            tmuxName: tmuxName,
            windowName: slug,
            pathInput: project.resolvedPath.isEmpty ? project.pathInput : project.resolvedPath,
            knownTmuxPath: knownTmuxPath(for: project),
            launchCommand: launchCommand,
            environment: [
                ("RTERM_PROJECT_ID", project.id.uuid.uuidString),
                ("RTERM_PROJECT_NAME", project.name),
                ("RTERM_SESSION_ID", sessionID.uuid.uuidString),
                ("RTERM_SESSION_NAME", displayName),
                ("RTERM_SESSION_SLUG", slug),
                ("RTERM_REMOTE", alias),
            ],
            metadata: metadata
        )

        let result = try await run(alias: alias, script: SSHTmuxScripts.createSession(context))
        let status = result.markers()[SSHTmuxScripts.Marker.status]
        guard result.exitCode == 0, status == "ok" else {
            switch (result.exitCode, status) {
            case (21, _), (_, "no_tmux"):
                throw RuntimeProviderError.prerequisiteMissing(
                    workspace: alias, what: "tmux",
                    remedy: "Install tmux on the remote host, then retry."
                )
            case (22, _), (_, "no_dir"):
                throw RuntimeProviderError.pathInvalid(workspace: alias, path: project.resolvedPath)
            case (23, _), (24, _), (_, "create_failed"), (_, "meta_failed"):
                throw RuntimeProviderError.operationFailed(
                    "Couldn't create the session on \(alias).\n\(Self.sanitizedStderr(result.stderr))"
                )
            default:
                throw mapFailure(alias: alias, result: result)
            }
        }

        return RemoteSession(
            id: sessionID,
            projectID: project.id,
            displayName: displayName,
            createdAt: createdAt,
            backendID: tmuxName,
            launchSlug: slug,
            cleanup: cleanup
        )
    }

    /// Resolves a creation request's start choice into the launch command to
    /// run now and the cleanup to record for archive time. Pure — tested
    /// without SSH.
    static func resolveStart(_ start: SessionStart, project: Project) -> (launchCommand: String?, cleanup: SessionCleanup) {
        switch start {
        case .projectDefault:
            return (project.launchCommand?.isEmpty == false ? project.launchCommand : nil, .projectDefault)
        case .shell:
            return (nil, .disabled)
        case .command(let launch, let cleanup):
            let trimmedCleanup = cleanup?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (
                launch.isEmpty ? nil : launch,
                trimmedCleanup.isEmpty ? .disabled : .command(trimmedCleanup)
            )
        }
    }

    /// The shutdown command archive should run for this session, honoring
    /// the cleanup recorded at launch; sessions from before that recording
    /// fall back to the project's current shutdown command. Pure — tested
    /// without SSH.
    static func shutdownCommand(for session: RemoteSession, project: Project) -> String? {
        switch session.cleanup ?? .projectDefault {
        case .projectDefault:
            return project.shutdownCommand?.isEmpty == false ? project.shutdownCommand : nil
        case .disabled:
            return nil
        case .command(let command):
            return command
        }
    }

    public func makeTerminalLaunch(for session: RemoteSession, project: Project) async throws -> TerminalLaunchSpec {
        let alias = try self.alias(for: project)
        guard TmuxNaming.isSafeSessionName(session.backendID) else {
            throw RuntimeProviderError.invalidInput("Unsafe session identifier.")
        }
        var tmuxWord = knownTmuxPath(for: project) ?? "tmux"
        if !Self.isSafeExecutablePath(tmuxWord) { tmuxWord = "tmux" }

        // The attach runs a small POSIX script via `sh -c` (single-quoted, so
        // the remote login shell never interprets its contents; every dynamic
        // value in it is validated-safe or quoted).
        //
        // The terminal is the app's chrome; tmux stays invisible:
        // - When the server carries the smcup@ override (Relay-only servers;
        //   the client then runs in the main screen, so scrolled lines land
        //   in the terminal's native scrollback), the pane's tmux history is
        //   replayed first — full backscroll is available natively the
        //   moment the session connects.
        // - `status off` and `mouse off` are session-scoped and enforced on
        //   every attach so sessions created by older builds get them too;
        //   mouse off leaves selection and wheel to the terminal (native
        //   selection, app-owned scrolling).
        let name = session.backendID
        let attachScript = """
        tp=\(POSIXShellQuote.quote(tmuxWord))
        if "$tp" show-options -s terminal-overrides 2>/dev/null | grep -q smcup@; then
          "$tp" capture-pane -e -p -S -2000 -t \(name) 2>/dev/null || true
        fi
        exec "$tp" set-option -t \(name) status off ';' set-option -t \(name) mouse off ';' attach-session -t \(name)
        """
        return TerminalLaunchSpec(
            executable: URL(fileURLWithPath: SSHCommandRunner.sshPath),
            arguments: [
                "-tt",
                "-o", "ConnectTimeout=10",
                "--",
                alias,
                "sh", "-c", POSIXShellQuote.quote(attachScript),
            ],
            environment: [
                "TERM_PROGRAM": "Relay",
                "COLORTERM": "truecolor",
            ]
        )
    }

    public func sessionExists(_ session: RemoteSession, project: Project) async throws -> Bool {
        let alias = try self.alias(for: project)
        guard TmuxNaming.isSafeSessionName(session.backendID) else {
            throw RuntimeProviderError.invalidInput("Unsafe session identifier.")
        }
        let result = try await run(
            alias: alias,
            script: SSHTmuxScripts.sessionExists(tmuxName: session.backendID, knownTmuxPath: knownTmuxPath(for: project))
        )
        guard result.exitCode == 0 else {
            throw mapFailure(alias: alias, result: result)
        }
        return result.markers()[SSHTmuxScripts.Marker.exists] == "1"
    }

    public func archiveSession(_ session: RemoteSession, project: Project) async throws {
        let alias = try self.alias(for: project)
        // 1. The caller has already detached any local attachment.
        // 2. Terminate the tmux session (tolerates already-gone sessions, so
        //    a cleanup retry re-enters here safely).
        try await killManagedSession(session, project: project, alias: alias)

        // 3. Run the cleanup recorded at launch (or the project's shutdown
        //    hook for sessions that predate per-session cleanups).
        guard let shutdownCommand = Self.shutdownCommand(for: session, project: project) else { return }

        let context = SSHTmuxScripts.ShutdownContext(
            pathInput: project.resolvedPath.isEmpty ? project.pathInput : project.resolvedPath,
            shutdownCommand: shutdownCommand,
            environment: [
                ("RTERM_PROJECT_ID", project.id.uuid.uuidString),
                ("RTERM_PROJECT_NAME", project.name),
                ("RTERM_PROJECT_PATH", project.resolvedPath),
                ("RTERM_SESSION_ID", session.id.uuid.uuidString),
                ("RTERM_SESSION_NAME", session.displayName),
                // Launch-time slug when recorded — a renamed session must
                // clean up the paths it actually created.
                ("RTERM_SESSION_SLUG", session.launchSlug
                    ?? SessionSlug.make(displayName: session.displayName, sessionID: session.id)),
                ("RTERM_REMOTE", alias),
                ("RTERM_SHUTDOWN_REASON", "archive"),
            ]
        )

        // Every failure past this point must surface as .cleanupFailed: the
        // runtime session is already terminated, so the caller needs the
        // retry/tombstone path, not a generic error.
        let result: SSHCommandRunner.CommandResult
        do {
            result = try await runner.runScript(
                alias: alias,
                script: SSHTmuxScripts.shutdownHook(context),
                timeout: .seconds(120)
            )
        } catch SSHCommandRunner.RunnerError.timedOut {
            throw RuntimeProviderError.cleanupFailed("The cleanup command timed out.")
        } catch {
            throw RuntimeProviderError.cleanupFailed("Couldn't run the cleanup command: \(error)")
        }
        guard result.exitCode == 0 else {
            if result.exitCode == 255 {
                throw RuntimeProviderError.cleanupFailed("SSH connection failed while running cleanup.\n\(Self.sanitizedStderr(result.stderr))")
            }
            throw RuntimeProviderError.cleanupFailed(
                "Exit status \(result.exitCode).\n\(Self.sanitizedStderr(result.stderr))"
            )
        }
    }

    public func destroySession(_ session: RemoteSession, project: Project) async throws {
        let alias = try self.alias(for: project)
        try await killManagedSession(session, project: project, alias: alias)
    }

    public func renameSession(_ session: RemoteSession, to name: String, project: Project) async throws {
        let alias = try self.alias(for: project)
        guard TmuxNaming.isSafeSessionName(session.backendID) else {
            throw RuntimeProviderError.invalidInput("Unsafe session identifier.")
        }
        let validated = try SessionNameValidator.validate(name).get()
        // If the remote never recorded a launch slug, the current (pre-
        // rename) name is still the launch name — its slug is backfilled so
        // cleanup keeps targeting the paths the session actually created.
        let fallbackSlug = session.launchSlug
            ?? SessionSlug.make(displayName: session.displayName, sessionID: session.id)
        let result = try await run(
            alias: alias,
            script: SSHTmuxScripts.renameSession(
                tmuxName: session.backendID,
                displayNameB64: TmuxSessionCodec.encodeDisplayName(validated),
                fallbackSlug: fallbackSlug,
                knownTmuxPath: knownTmuxPath(for: project))
        )
        let status = result.markers()[SSHTmuxScripts.Marker.status]
        if status == "not_found" {
            throw RuntimeProviderError.sessionNotFound(workspace: alias)
        }
        guard result.exitCode == 0, status == "ok" else {
            throw mapFailure(alias: alias, result: result)
        }
    }

    // MARK: Git state

    public func gitState(for session: RemoteSession, project: Project) async throws -> SessionGitState? {
        let alias = try self.alias(for: project)
        guard TmuxNaming.isSafeSessionName(session.backendID) else {
            throw RuntimeProviderError.invalidInput("Unsafe session identifier.")
        }
        let result = try await run(
            alias: alias,
            script: SSHTmuxScripts.gitState(tmuxName: session.backendID, knownTmuxPath: knownTmuxPath(for: project))
        )
        guard result.exitCode == 0 else { throw mapFailure(alias: alias, result: result) }
        let markers = result.markers()
        guard markers[SSHTmuxScripts.Marker.git] == "ok" else { return nil }

        var pullRequest: PullRequestRef?
        if let prString = markers[SSHTmuxScripts.Marker.pullRequest],
           let number = Int(prString), number > 0,
           let origin = markers[SSHTmuxScripts.Marker.gitOrigin],
           let url = GitHubRemote.pullRequestURL(origin: origin, number: number) {
            pullRequest = PullRequestRef(number: number, url: url)
        }
        return SessionGitState(
            branch: markers[SSHTmuxScripts.Marker.gitBranch] ?? "HEAD",
            baseRef: markers[SSHTmuxScripts.Marker.gitBase],
            additions: Int(markers[SSHTmuxScripts.Marker.gitAdditions] ?? "") ?? 0,
            deletions: Int(markers[SSHTmuxScripts.Marker.gitDeletions] ?? "") ?? 0,
            filesChanged: Int(markers[SSHTmuxScripts.Marker.gitFiles] ?? "") ?? 0,
            pullRequest: pullRequest
        )
    }

    public func gitDiff(for session: RemoteSession, project: Project) async throws -> SessionGitDiff? {
        let alias = try self.alias(for: project)
        guard TmuxNaming.isSafeSessionName(session.backendID) else {
            throw RuntimeProviderError.invalidInput("Unsafe session identifier.")
        }
        let result: SSHCommandRunner.CommandResult
        do {
            result = try await runner.runScript(
                alias: alias,
                script: SSHTmuxScripts.gitDiff(tmuxName: session.backendID, knownTmuxPath: knownTmuxPath(for: project)),
                timeout: .seconds(60)
            )
        } catch SSHCommandRunner.RunnerError.timedOut {
            throw RuntimeProviderError.workspaceUnreachable(workspace: alias, detail: "Connection timed out.")
        } catch let error as SSHCommandRunner.RunnerError {
            throw RuntimeProviderError.operationFailed("Couldn't start ssh: \(error)")
        }
        guard result.exitCode == 0 else { throw mapFailure(alias: alias, result: result) }

        // Markers come before the sentinel; everything after it is the raw
        // diff body (which may itself contain RTERM-looking lines, hence the
        // split rather than markers()).
        let sentinel = SSHTmuxScripts.Marker.diffBegin + "\n"
        guard let sentinelRange = result.stdout.range(of: sentinel) else {
            guard result.markers()[SSHTmuxScripts.Marker.git] == "ok" else { return nil }
            throw RuntimeProviderError.operationFailed("Malformed diff response from \(alias).")
        }
        let head = String(result.stdout[..<sentinelRange.lowerBound])
        let headMarkers = SSHCommandRunner.CommandResult(
            exitCode: 0, stdout: head, stderr: "").markers()
        guard headMarkers[SSHTmuxScripts.Marker.git] == "ok" else { return nil }
        let body = String(result.stdout[sentinelRange.upperBound...])
        return SessionGitDiff(
            branch: headMarkers[SSHTmuxScripts.Marker.gitBranch] ?? "HEAD",
            baseRef: headMarkers[SSHTmuxScripts.Marker.gitBase],
            files: UnifiedDiffParser.parse(body),
            truncated: body.utf8.count >= SSHTmuxScripts.diffByteCap
        )
    }

    // MARK: File preview

    public func fetchPreviewFile(linkPath: String, for session: RemoteSession, project: Project) async throws -> URL {
        let alias = try self.alias(for: project)
        guard !alias.contains(":") else {
            throw RuntimeProviderError.invalidInput("SSH alias \"\(alias)\" can't be used as an scp source.")
        }
        guard TmuxNaming.isSafeSessionName(session.backendID) else {
            throw RuntimeProviderError.invalidInput("Unsafe session identifier.")
        }
        guard !POSIXShellQuote.containsControlCharacters(linkPath) else {
            throw RuntimeProviderError.invalidInput("The link contains control characters.")
        }

        let result = try await run(
            alias: alias,
            script: SSHTmuxScripts.resolvePreviewFile(
                tmuxName: session.backendID,
                linkPath: linkPath,
                knownTmuxPath: knownTmuxPath(for: project))
        )
        guard result.exitCode == 0 else { throw mapFailure(alias: alias, result: result) }
        let markers = result.markers()
        let name = (linkPath as NSString).lastPathComponent
        switch markers[SSHTmuxScripts.Marker.preview] {
        case "ok":
            break
        case "dir":
            throw RuntimeProviderError.operationFailed("\u{201C}\(name)\u{201D} is a folder — only files can be previewed.")
        case "too_big":
            let size = Int64(markers[SSHTmuxScripts.Marker.previewSize] ?? "") ?? 0
            let label = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            throw RuntimeProviderError.operationFailed("\u{201C}\(name)\u{201D} is \(label) — too large to preview.")
        default:
            throw RuntimeProviderError.operationFailed("\u{201C}\(name)\u{201D} doesn't exist (or isn't readable) on \(alias).")
        }
        guard let remotePath = markers[SSHTmuxScripts.Marker.previewPath], remotePath.hasPrefix("/") else {
            throw RuntimeProviderError.operationFailed("Malformed preview response from \(alias).")
        }

        // Local landing spot: the OS temp area (periodically reclaimed by
        // macOS), one directory per (host, remote path) so repeat previews
        // of the same file reuse a stable location.
        let digest = SHA256.hash(data: Data("\(alias)\n\(remotePath)".utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        var basename = (remotePath as NSString).lastPathComponent
            .filter { !$0.unicodeScalars.allSatisfy(CharacterSet.controlCharacters.contains) }
        if basename.isEmpty { basename = "file" }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-preview")
            .appendingPathComponent(String(key))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(basename)
        let partial = directory.appendingPathComponent(".part-\(UUID().uuidString)")

        // Always fetch fresh: sessions rewrite files constantly and staleness
        // is worse than an extra transfer.
        let scpResult = try await SSHCommandRunner.runProcess(
            executable: "/usr/bin/scp",
            arguments: ["-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--",
                        "\(alias):\(remotePath)", partial.path],
            stdin: nil,
            timeout: .seconds(600)
        )
        guard scpResult.exitCode == 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw RuntimeProviderError.operationFailed(
                "Couldn't fetch \u{201C}\(name)\u{201D} from \(alias).\n\(Self.sanitizedStderr(scpResult.stderr))")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    // MARK: Internals

    private func killManagedSession(_ session: RemoteSession, project: Project, alias: String) async throws {
        guard TmuxNaming.isSafeSessionName(session.backendID) else {
            throw RuntimeProviderError.invalidInput("Unsafe session identifier.")
        }
        let result = try await run(
            alias: alias,
            script: SSHTmuxScripts.killSession(tmuxName: session.backendID, knownTmuxPath: knownTmuxPath(for: project))
        )
        guard result.exitCode == 0, result.markers()[SSHTmuxScripts.Marker.status] == "ok" else {
            if result.exitCode == 25 {
                throw RuntimeProviderError.operationFailed(
                    "tmux refused to kill the session on \(alias).\n\(Self.sanitizedStderr(result.stderr))"
                )
            }
            throw mapFailure(alias: alias, result: result)
        }
    }

    // MARK: File upload

    /// Validates the basenames of a dropped item set: every item must have a
    /// usable name, no control characters (they could smuggle bytes into the
    /// terminal when the resulting path is inserted), and no duplicates
    /// (everything lands in one flat drop directory). Returns the basenames
    /// in input order. Static and pure for unit testing.
    static func validateDropBasenames(_ localPaths: [String]) throws -> [String] {
        guard !localPaths.isEmpty else {
            throw RuntimeProviderError.invalidInput("Nothing to upload.")
        }
        var seen = Set<String>()
        var basenames: [String] = []
        for path in localPaths {
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw RuntimeProviderError.invalidInput("Can't upload \"\(path)\": unusable file name.")
            }
            guard !POSIXShellQuote.containsControlCharacters(name) else {
                throw RuntimeProviderError.invalidInput("Can't upload \"\(name)\": the name contains control characters.")
            }
            guard seen.insert(name).inserted else {
                throw RuntimeProviderError.invalidInput("Two dropped items are both named \"\(name)\" — rename one and retry.")
            }
            basenames.append(name)
        }
        return basenames
    }

    /// The shape a remote drop directory must have before we will ever place
    /// it in a command line (defense in depth against a hostile remote).
    static func isSafeDropDirectory(_ path: String) -> Bool {
        guard path.hasPrefix("/tmp/relay-drop.") else { return false }
        let suffix = path.dropFirst("/tmp/relay-drop.".count)
        return !suffix.isEmpty && suffix.count <= 32
            && suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    public func uploadFiles(
        localPaths: [String],
        for session: RemoteSession,
        project: Project
    ) async throws -> [String] {
        let alias = try self.alias(for: project)
        // scp's target syntax splits on the first colon; an alias containing
        // one would misroute. (Config discovery never produces such aliases,
        // but the provider re-checks its own preconditions.)
        guard !alias.contains(":") else {
            throw RuntimeProviderError.invalidInput("SSH alias \"\(alias)\" can't be used as an scp target.")
        }
        let basenames = try Self.validateDropBasenames(localPaths)
        for path in localPaths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw RuntimeProviderError.invalidInput("\"\((path as NSString).lastPathComponent)\" no longer exists.")
            }
        }

        // 1. Create a fresh scratch directory on the remote. mktemp's
        // template syntax works on both BSD and GNU. /tmp keeps drops out of
        // the project tree and the OS reclaims them on reboot.
        let mktempScript = """
        set -u
        d=$(mktemp -d /tmp/relay-drop.XXXXXXXX) || { printf 'RTERM_STATUS=mktemp_failed\\n'; exit 26; }
        printf 'RTERM_STATUS=ok\\n'
        printf 'RTERM_DROP_DIR=%s\\n' "$d"
        """
        let mktempResult = try await run(alias: alias, script: mktempScript)
        guard mktempResult.exitCode == 0,
              mktempResult.markers()[SSHTmuxScripts.Marker.status] == "ok",
              let dropDir = mktempResult.markers()["RTERM_DROP_DIR"],
              Self.isSafeDropDirectory(dropDir)
        else {
            throw RuntimeProviderError.uploadFailed(
                "Couldn't create a drop directory on \(alias).\n\(Self.sanitizedStderr(mktempResult.stderr))"
            )
        }

        // 2. Transfer. -r covers directories; -- protects dash-leading
        // names; modern OpenSSH scp speaks SFTP, so remote names are taken
        // literally (no remote shell expansion).
        do {
            let scpResult = try await SSHCommandRunner.runProcess(
                executable: "/usr/bin/scp",
                arguments: ["-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-r", "--"]
                    + localPaths + ["\(alias):\(dropDir)/"],
                stdin: nil,
                timeout: .seconds(1800)
            )
            guard scpResult.exitCode == 0 else {
                bestEffortRemoveDropDirectory(dropDir, alias: alias)
                throw RuntimeProviderError.uploadFailed(
                    "scp exited with status \(scpResult.exitCode).\n\(Self.sanitizedStderr(scpResult.stderr))"
                )
            }
        } catch is CancellationError {
            bestEffortRemoveDropDirectory(dropDir, alias: alias)
            throw CancellationError()
        } catch let error as SSHCommandRunner.RunnerError {
            bestEffortRemoveDropDirectory(dropDir, alias: alias)
            switch error {
            case .timedOut:
                throw RuntimeProviderError.uploadFailed("The transfer timed out.")
            case .launchFailed(let detail):
                throw RuntimeProviderError.uploadFailed(detail)
            }
        }

        return basenames.map { dropDir + "/" + $0 }
    }

    /// Removes a failed/cancelled drop directory. Fire-and-forget on a
    /// detached task so a cancelled upload settles immediately and cleanup
    /// itself can't be cancelled away. Only ever touches paths that passed
    /// `isSafeDropDirectory`.
    private func bestEffortRemoveDropDirectory(_ dropDir: String, alias: String) {
        guard Self.isSafeDropDirectory(dropDir) else { return }
        let script = "rm -rf \(POSIXShellQuote.quote(dropDir))"
        let aliasCopy = alias
        let runnerCopy = runner
        Task.detached {
            _ = try? await runnerCopy.runScript(alias: aliasCopy, script: script, timeout: .seconds(30))
        }
    }

    private func alias(for project: Project) throws -> String {
        try alias(for: project.workspace)
    }

    private func alias(for workspace: WorkspaceRef) throws -> String {
        guard workspace.provider == id else {
            throw RuntimeProviderError.invalidInput("Project belongs to a different provider.")
        }
        let alias = workspace.opaqueID
        guard !alias.isEmpty,
              !alias.hasPrefix("-"),
              !POSIXShellQuote.containsControlCharacters(alias),
              !alias.contains(where: { $0 == " " || $0 == "\t" })
        else {
            throw RuntimeProviderError.invalidInput("Invalid SSH alias: \(alias)")
        }
        return alias
    }

    private func knownTmuxPath(for project: Project) -> String? {
        project.runtimeMetadata[Self.tmuxPathMetadataKey]
    }

    private func run(alias: String, script: String) async throws -> SSHCommandRunner.CommandResult {
        do {
            return try await runner.runScript(alias: alias, script: script)
        } catch SSHCommandRunner.RunnerError.timedOut {
            throw RuntimeProviderError.workspaceUnreachable(workspace: alias, detail: "Connection timed out.")
        } catch let error as SSHCommandRunner.RunnerError {
            throw RuntimeProviderError.operationFailed("Couldn't start ssh: \(error)")
        }
    }

    private func mapFailure(alias: String, result: SSHCommandRunner.CommandResult) -> RuntimeProviderError {
        let stderr = Self.sanitizedStderr(result.stderr)
        if result.exitCode == 255 {
            let lowered = stderr.lowercased()
            if lowered.contains("permission denied")
                || lowered.contains("host key verification failed")
                || lowered.contains("no supported authentication")
                || lowered.contains("authenticity of host") {
                return .authenticationRequired(workspace: alias)
            }
            return .workspaceUnreachable(workspace: alias, detail: "ssh exited with status 255.\n\(stderr)")
        }
        return .operationFailed("Command on \(alias) failed with status \(result.exitCode).\n\(stderr)")
    }

    /// Trims stderr for display: deduplicated, bounded, but never drops the
    /// first line (usually the root cause).
    static func sanitizedStderr(_ stderr: String) -> String {
        var lines: [String] = []
        for raw in stderr.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty && lines.last != line {
                lines.append(line)
            }
        }
        guard lines.count > 6 else { return lines.joined(separator: "\n") }
        return (lines.prefix(3) + ["…"] + lines.suffix(3)).joined(separator: "\n")
    }

    /// Version strings look like "tmux 3.4", "tmux 3.7c", "tmux next-3.6".
    static func parseTmuxVersion(_ versionString: String) -> (major: Int, minor: Int)? {
        guard let match = versionString.firstMatch(of: /(\d+)\.(\d+)/),
              let major = Int(match.1),
              let minor = Int(match.2)
        else { return nil }
        return (major, minor)
    }

    /// True if a stored executable path is safe to place, unquoted, on a
    /// command line parsed by an unknown login shell.
    static func isSafeExecutablePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.hasPrefix("/") else { return false }
        return path.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || "/._+-".contains(char))
        }
    }
}
