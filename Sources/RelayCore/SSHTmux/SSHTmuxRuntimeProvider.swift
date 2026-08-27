import Foundation

/// v1 runtime provider: existing SSH hosts + vanilla remote tmux.
///
/// This is the only production module that knows the combined SSH+tmux
/// lifecycle. It never installs anything remotely and only ever targets
/// tmux sessions carrying the app's own metadata.
public struct SSHTmuxRuntimeProvider: RuntimeProvider {
    public let id = ProviderID.sshTmux
    public let capabilities: RuntimeCapabilities = [.persistentSessions, .staticWorkspaces]

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
                    backendID: discovered.tmuxName
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

        var metadata: [(String, String)] = [
            ("@rterm_schema", TmuxSessionCodec.schemaVersion),
            ("@rterm_project_id", project.id.uuid.uuidString),
            ("@rterm_session_id", sessionID.uuid.uuidString),
            ("@rterm_session_name_b64", TmuxSessionCodec.encodeDisplayName(displayName)),
            ("@rterm_created_at", String(Int(createdAt.timeIntervalSince1970))),
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
            pathInput: project.resolvedPath.isEmpty ? project.pathInput : project.resolvedPath,
            knownTmuxPath: knownTmuxPath(for: project),
            launchCommand: project.launchCommand?.isEmpty == false ? project.launchCommand : nil,
            environment: [
                ("RTERM_PROJECT_ID", project.id.uuid.uuidString),
                ("RTERM_PROJECT_NAME", project.name),
                ("RTERM_SESSION_ID", sessionID.uuid.uuidString),
                ("RTERM_SESSION_NAME", displayName),
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
            backendID: tmuxName
        )
    }

    public func makeTerminalLaunch(for session: RemoteSession, project: Project) async throws -> TerminalLaunchSpec {
        let alias = try self.alias(for: project)
        guard TmuxNaming.isSafeSessionName(session.backendID) else {
            throw RuntimeProviderError.invalidInput("Unsafe session identifier.")
        }
        // The attach command line is parsed by the remote user's login shell,
        // so it is built exclusively from validated-safe tokens (no quoting
        // dialect assumptions).
        var tmuxWord = knownTmuxPath(for: project) ?? "tmux"
        if !Self.isSafeExecutablePath(tmuxWord) { tmuxWord = "tmux" }

        return TerminalLaunchSpec(
            executable: URL(fileURLWithPath: SSHCommandRunner.sshPath),
            arguments: [
                "-tt",
                "-o", "ConnectTimeout=10",
                "--",
                alias,
                tmuxWord, "attach-session", "-t", session.backendID,
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

        // 3. Run the shutdown hook, if configured.
        guard let shutdownCommand = project.shutdownCommand, !shutdownCommand.isEmpty else { return }

        let context = SSHTmuxScripts.ShutdownContext(
            pathInput: project.resolvedPath.isEmpty ? project.pathInput : project.resolvedPath,
            shutdownCommand: shutdownCommand,
            environment: [
                ("RTERM_PROJECT_ID", project.id.uuid.uuidString),
                ("RTERM_PROJECT_NAME", project.name),
                ("RTERM_PROJECT_PATH", project.resolvedPath),
                ("RTERM_SESSION_ID", session.id.uuid.uuidString),
                ("RTERM_SESSION_NAME", session.displayName),
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

    private func alias(for project: Project) throws -> String {
        guard project.workspace.provider == id else {
            throw RuntimeProviderError.invalidInput("Project belongs to a different provider.")
        }
        let alias = project.workspace.opaqueID
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
