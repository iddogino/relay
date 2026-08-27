import Foundation
import RelayCore

/// The full acceptance run. Every remote artifact lives under a mktemp root
/// with a validated sentinel, and every tmux session carries the run marker
/// `@rterm_e2e_run=<run-id>`. See docs/remote-project-terminal-v1-spec.md §21.
final class E2ERun {
    let runner = SSHCommandRunner()
    let provider = SSHTmuxRuntimeProvider()
    let runID: String
    var state: E2EState
    var failures: [String] = []
    var passes = 0

    /// tmux session names that existed before the run, per alias (AC-13).
    var preexisting: [String: Set<String>] = [:]

    init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let suffix = String(format: "%06x", UInt32.random(in: 0...0xFFFFFF))
        self.runID = "rterm-e2e-\(formatter.string(from: Date()))-\(suffix)"
        self.state = E2EState(runID: runID, hosts: [])
    }

    var statePath: String {
        stateDirectory().appendingPathComponent("\(runID).json").path
    }

    func saveState() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: URL(fileURLWithPath: statePath))
        }
    }

    // MARK: Assertions

    func check(_ condition: Bool, _ label: String) {
        if condition {
            passes += 1
            print("  ✓ \(label)")
        } else {
            failures.append(label)
            print("  ✗ FAIL: \(label)")
        }
    }

    func fail(_ label: String) { check(false, label) }

    @discardableResult
    func ssh(_ alias: String, _ script: String, timeout: Duration = .seconds(30)) async -> SSHCommandRunner.CommandResult {
        (try? await runner.runScript(alias: alias, script: script, timeout: timeout))
            ?? SSHCommandRunner.CommandResult(exitCode: -1, stdout: "", stderr: "local run failure")
    }

    // MARK: Main flow

    func runAll() async {
        print("run id: \(runID)")
        do {
            let pair = try await HostDiscovery.discoverPair(verbose: false)
            state.hosts = [E2EHostState(alias: pair.darwin), E2EHostState(alias: pair.ubuntu)]
            saveState()

            for i in state.hosts.indices {
                try await prepareHost(&state.hosts[i])
                saveState()
            }

            for host in state.hosts {
                print("\n=== \(host.alias) ===")
                await runHostSuite(host)
            }

            // Worktree + shutdown-hook flows (AC-08, AC-24) on Ubuntu, the
            // preferred host per spec (cheap enough to also run on macOS).
            for host in state.hosts {
                print("\n=== \(host.alias): worktree + shutdown hook ===")
                await runWorktreeSuite(host)
            }
        } catch {
            fail("setup: \(error)")
        }

        print("\n=== cleanup ===")
        for host in state.hosts {
            await cleanupHost(host)
        }
        for host in state.hosts {
            await verifyHostClean(host)
        }
        try? FileManager.default.removeItem(atPath: statePath)

        print("\n\(passes) checks passed, \(failures.count) failed")
        if !failures.isEmpty {
            for failure in failures { print("  ✗ \(failure)") }
            exit(1)
        }
        exit(0)
    }

    // MARK: Host preparation

    func prepareHost(_ host: inout E2EHostState) async throws {
        // Snapshot pre-existing tmux sessions (AC-13).
        let list = await ssh(host.alias, """
        for c in tmux /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
          if command -v "$c" >/dev/null 2>&1; then tp=$(command -v "$c"); break; fi
        done
        [ -n "${tp:-}" ] || exit 21
        "$tp" list-sessions -F '#{session_name}' 2>/dev/null || true
        """)
        guard list.exitCode == 0 else {
            throw E2EError.fatal("\(host.alias): tmux missing or unreachable")
        }
        preexisting[host.alias] = Set(list.stdout.split(separator: "\n").map(String.init))
        print("\(host.alias): \(preexisting[host.alias]!.count) pre-existing tmux session(s)")

        // Create the temp root with sentinel (§21.2).
        let make = await ssh(host.alias, """
        root="$(mktemp -d "${TMPDIR:-/tmp}/rterm-e2e.XXXXXX")" || exit 30
        printf '%s\\n' \(POSIXShellQuote.quote(runID)) > "$root/.rterm-e2e-sentinel"
        # Record the canonical path so later exact-path comparisons hold
        # (macOS mktemp returns /var/... which canonicalizes to /private/var/...).
        cd "$root" || exit 31
        printf 'RTERM_ROOT=%s\\n' "$(pwd -P)"
        """)
        guard make.exitCode == 0, let root = make.markers()["RTERM_ROOT"], root.contains("rterm-e2e.") else {
            throw E2EError.fatal("\(host.alias): couldn't create temp root")
        }
        host.tempRoot = root
        print("\(host.alias): temp root \(root)")
    }

    func makeProject(
        _ host: E2EHostState,
        name: String,
        subdir: String? = nil,
        pathOverride: String? = nil,
        launch: String? = nil,
        shutdown: String? = nil
    ) async -> Project? {
        let path = pathOverride ?? (subdir.map { host.tempRoot + "/" + $0 } ?? host.tempRoot)
        var project = Project(
            name: name,
            workspace: WorkspaceRef(provider: .sshTmux, opaqueID: host.alias),
            pathInput: path,
            resolvedPath: "",
            launchCommand: launch,
            shutdownCommand: shutdown)
        do {
            let validation = try await provider.validate(project: project)
            project.resolvedPath = validation.resolvedPath
            project.runtimeMetadata = validation.runtimeMetadata
            return project
        } catch {
            fail("\(name): validation failed: \(error.localizedDescription)")
            return nil
        }
    }

    func createSession(_ project: Project, name: String) async -> RemoteSession? {
        do {
            return try await provider.createSession(
                for: project,
                request: NewSessionRequest(
                    displayName: name,
                    extraMetadata: ["@rterm_e2e_run": runID]))
        } catch {
            fail("createSession(\(name)): \(error.localizedDescription)")
            return nil
        }
    }

    func tmuxOnHost(_ project: Project) -> String {
        project.runtimeMetadata["tmuxPath"] ?? "tmux"
    }

    // MARK: Core suite per host (AC-03..AC-07, AC-09, AC-11, AC-12, AC-23)

    func runHostSuite(_ host: E2EHostState) async {
        // --- AC-03/04: validation ---------------------------------------
        let before = await ssh(host.alias, "ls -a \(POSIXShellQuote.quote(host.tempRoot)) | sort")
        guard let project = await makeProject(host, name: "E2E \(host.alias)") else { return }
        let after = await ssh(host.alias, "ls -a \(POSIXShellQuote.quote(host.tempRoot)) | sort")
        check(project.resolvedPath.hasPrefix("/"), "AC-03 validation resolves canonical path (\(project.resolvedPath))")
        check(before.stdout == after.stdout, "AC-03 validation creates no files")
        check(project.runtimeMetadata["tmuxPath"]?.hasPrefix("/") == true, "AC-03 tmux resolved (\(project.runtimeMetadata["tmuxPath"] ?? "?"))")

        // Validation errors are actionable.
        do {
            var bad = project
            bad.pathInput = host.tempRoot + "/does-not-exist"
            _ = try await provider.validate(project: bad)
            fail("AC-03 missing path must fail validation")
        } catch let error as RuntimeProviderError {
            if case .pathInvalid = error {
                check(true, "AC-03 missing path fails with pathInvalid")
            } else {
                fail("AC-03 unexpected validation error: \(error)")
            }
        } catch {
            fail("AC-03 unexpected validation error type")
        }

        // --- AC-05/06: plain shell session -------------------------------
        guard let plain = await createSession(project, name: "plain shell ✨") else { return }
        let tmux = tmuxOnHost(project)
        let paneInfo = await ssh(host.alias, """
        "\(tmux)" has-session -t =\(plain.backendID) || exit 40
        "\(tmux)" display-message -p -t \(plain.backendID) '#{pane_current_path}'
        """)
        check(paneInfo.exitCode == 0, "AC-05 tmux session exists after create")
        check(
            paneInfo.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == project.resolvedPath,
            "AC-05 session starts in project directory")

        // Session discovery round-trip (metadata codec over real tmux).
        do {
            let listed = try await provider.listSessions(for: project)
            check(listed.contains { $0.id == plain.id && $0.displayName == "plain shell ✨" },
                  "AC-05 listSessions rediscovers session with unicode name")
        } catch {
            fail("AC-05 listSessions: \(error.localizedDescription)")
        }

        // --- AC-18: hostile display name --------------------------------
        let hostileMarker = host.tempRoot + "/pwned"
        guard let hostile = await createSession(project, name: "fix $PATH; echo nope ' \" $(touch pwned) `touch pwned`") else { return }
        let pwned = await ssh(host.alias, "[ -e \(POSIXShellQuote.quote(hostileMarker)) ] && echo RTERM_PWNED=1 || echo RTERM_PWNED=0")
        check(pwned.markers()["RTERM_PWNED"] == "0", "AC-18 hostile session name executes no shell code")
        do {
            let listed = try await provider.listSessions(for: project)
            check(listed.contains { $0.id == hostile.id }, "AC-18 hostile name round-trips through metadata")
        } catch {
            fail("AC-18 listSessions: \(error.localizedDescription)")
        }
        try? await provider.destroySession(hostile, project: project)

        // --- AC-07: launch command + RTERM environment -------------------
        let envProject = await makeProject(
            host, name: "E2E env \(host.alias)",
            launch: """
            { pwd; env | grep '^RTERM_' | sort; } > "$RTERM_PROJECT_PATH/launch-marker.txt" 2>&1; exec "${SHELL:-/bin/sh}"
            """)
        guard let envProject else { return }
        guard let envSession = await createSession(envProject, name: "env probe") else { return }
        try? await Task.sleep(for: .seconds(2))
        let markerOut = await ssh(host.alias, "cat \(POSIXShellQuote.quote(host.tempRoot + "/launch-marker.txt")) 2>/dev/null")
        let marker = markerOut.stdout
        check(marker.contains("RTERM_PROJECT_ID=\(envProject.id.uuid.uuidString)"), "AC-07 RTERM_PROJECT_ID correct")
        check(marker.contains("RTERM_PROJECT_PATH=\(envProject.resolvedPath)"), "AC-07 RTERM_PROJECT_PATH correct")
        check(marker.contains("RTERM_SESSION_ID=\(envSession.id.uuid.uuidString)"), "AC-07 RTERM_SESSION_ID correct")
        check(marker.contains("RTERM_SESSION_NAME=env probe"), "AC-07 RTERM_SESSION_NAME correct")
        check(marker.contains("RTERM_REMOTE=\(host.alias)"), "AC-07 RTERM_REMOTE correct")
        check(marker.hasPrefix(envProject.resolvedPath + "\n"), "AC-07 launch command ran in project directory")
        let envAlive = await ssh(host.alias, "\"\(tmux)\" has-session -t =\(envSession.backendID) && echo RTERM_ALIVE=1")
        check(envAlive.markers()["RTERM_ALIVE"] == "1", "AC-07 session still alive after launch command")
        try? await provider.destroySession(envSession, project: envProject)

        // --- AC-09/AC-11: persistence without any client -----------------
        let counterFile = host.tempRoot + "/counter"
        let counterProject = await makeProject(
            host, name: "E2E counter \(host.alias)",
            launch: "i=0; while :; do i=$((i+1)); printf '%s\\n' \"$i\" > \(POSIXShellQuote.quote(counterFile)); sleep 1; done")
        guard let counterProject else { return }
        guard let counter = await createSession(counterProject, name: "counter") else { return }
        try? await Task.sleep(for: .seconds(3))
        let read1 = await ssh(host.alias, "cat \(POSIXShellQuote.quote(counterFile)) 2>/dev/null")
        try? await Task.sleep(for: .seconds(3))
        let read2 = await ssh(host.alias, "cat \(POSIXShellQuote.quote(counterFile)) 2>/dev/null")
        let v1 = Int(read1.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        let v2 = Int(read2.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        check(v1 > 0 && v2 > v1, "AC-09 process keeps running with no attachment (counter \(v1)→\(v2))")

        // AC-11: a fresh provider instance (fresh app) rediscovers it.
        let freshProvider = SSHTmuxRuntimeProvider()
        do {
            let rediscovered = try await freshProvider.listSessions(for: counterProject)
            check(rediscovered.contains { $0.id == counter.id }, "AC-11 fresh provider rediscovers session")
            let exists = try await freshProvider.sessionExists(counter, project: counterProject)
            check(exists, "AC-11 sessionExists confirms live session")
        } catch {
            fail("AC-11: \(error.localizedDescription)")
        }

        // --- AC-12: kill exactness ---------------------------------------
        // Control session: NOT app-owned (no @rterm schema), tagged for
        // cleanup only via the e2e marker.
        let controlName = "e2ectl-\(runID.suffix(6))"
        let mkControl = await ssh(host.alias, """
        "\(tmux)" new-session -d -s \(controlName) || exit 41
        "\(tmux)" set-option -t \(controlName) @rterm_e2e_run \(POSIXShellQuote.quote(runID)) || exit 42
        echo RTERM_OK=1
        """)
        check(mkControl.markers()["RTERM_OK"] == "1", "AC-12 control session created")

        do {
            try await provider.destroySession(counter, project: counterProject)
            check(true, "AC-12 kill succeeds")
        } catch {
            fail("AC-12 kill: \(error.localizedDescription)")
        }
        let postKill = await ssh(host.alias, """
        "\(tmux)" has-session -t =\(counter.backendID) 2>/dev/null && k=1 || k=0
        "\(tmux)" has-session -t =\(controlName) 2>/dev/null && c=1 || c=0
        printf 'RTERM_KILLED=%s\\nRTERM_CONTROL=%s\\n' "$k" "$c"
        """)
        check(postKill.markers()["RTERM_KILLED"] == "0", "AC-12 killed session is gone (has-session fails)")
        check(postKill.markers()["RTERM_CONTROL"] == "1", "AC-12 unrelated control session remains alive")

        // Control session must not be adopted by discovery (§11.5).
        do {
            let listed = try await provider.listSessions(for: counterProject)
            check(!listed.contains { $0.backendID == controlName }, "AC-13 discovery never adopts unrelated sessions")
        } catch {
            fail("AC-13 listSessions: \(error.localizedDescription)")
        }

        // --- AC-23: archive without hook ---------------------------------
        check(plain.id == plain.id, "AC-23 using session \(plain.backendID)")
        do {
            try await provider.archiveSession(plain, project: project)
            check(true, "AC-23 archive succeeds")
        } catch {
            fail("AC-23 archive: \(error.localizedDescription)")
        }
        let postArchive = await ssh(host.alias, """
        "\(tmux)" has-session -t =\(plain.backendID) 2>/dev/null && echo RTERM_STILL=1 || echo RTERM_STILL=0
        """)
        check(postArchive.markers()["RTERM_STILL"] == "0", "AC-23 archived tmux session no longer exists")
    }

    // MARK: Worktree suite (AC-08, AC-24)

    func runWorktreeSuite(_ host: E2EHostState) async {
        let repo = host.tempRoot + "/repo"
        let setup = await ssh(host.alias, """
        set -e
        mkdir -p \(POSIXShellQuote.quote(repo))
        cd \(POSIXShellQuote.quote(repo))
        git init -q
        git config user.email e2e@example.invalid
        git config user.name "Relay E2E"
        echo hello > file.txt
        git add file.txt
        git commit -q -m init
        echo RTERM_OK=1
        """)
        guard setup.markers()["RTERM_OK"] == "1" else {
            fail("AC-08 repo setup failed: \(setup.stderr)")
            return
        }

        // Launch script: create a worktree keyed by session ID inside the
        // temp root, cd into it, write a marker, exec a shell.
        let launch = """
        set -e
        wt="$RTERM_PROJECT_PATH-worktrees/$RTERM_SESSION_ID"
        git -C "$RTERM_PROJECT_PATH" worktree add "$wt" -b "e2e/$RTERM_SESSION_ID" >/dev/null 2>&1
        cd "$wt"
        pwd > "$RTERM_PROJECT_PATH/wt-marker.txt"
        exec "${SHELL:-/bin/sh}"
        """
        // Shutdown script: validate paths stay inside the temp root, record
        // context, remove the worktree WITHOUT --force.
        let shutdown = """
        set -e
        case "$RTERM_PROJECT_PATH" in \(host.tempRoot)/*) ;; *) echo "unsafe path" >&2; exit 90 ;; esac
        wt="$RTERM_PROJECT_PATH-worktrees/$RTERM_SESSION_ID"
        env | grep '^RTERM_' | sort > "$RTERM_PROJECT_PATH/shutdown-env.txt"
        if [ -e "$RTERM_PROJECT_PATH/fail-cleanup" ]; then echo "simulated cleanup failure" >&2; exit 91; fi
        git -C "$RTERM_PROJECT_PATH" worktree remove "$wt"
        git -C "$RTERM_PROJECT_PATH" branch -D "e2e/$RTERM_SESSION_ID" >/dev/null
        """
        guard let project = await makeProject(
            host, name: "E2E worktree \(host.alias)", subdir: "repo",
            launch: launch, shutdown: shutdown) else { return }
        let tmux = tmuxOnHost(project)

        guard let session = await createSession(project, name: "wt session") else { return }
        try? await Task.sleep(for: .seconds(2))

        let worktreePath = "\(project.resolvedPath)-worktrees/\(session.id.uuid.uuidString)"
        let wtCheck = await ssh(host.alias, """
        { [ -d \(POSIXShellQuote.quote(worktreePath)) ] && grep -q \(POSIXShellQuote.quote(worktreePath)) \(POSIXShellQuote.quote(project.resolvedPath + "/wt-marker.txt")); } && echo RTERM_WT=1 || echo RTERM_WT=0
        "\(tmux)" display-message -p -t \(session.backendID) '#{pane_current_path}' 2>/dev/null | sed 's/^/RTERM_PANE=/'
        """)
        check(wtCheck.markers()["RTERM_WT"] == "1", "AC-08 worktree created by launch script")
        check(wtCheck.markers()["RTERM_PANE"]?.hasSuffix(session.id.uuid.uuidString) == true,
              "AC-08 pane cwd is the worktree")

        // --- AC-24 failure path first: archive with simulated hook failure.
        _ = await ssh(host.alias, "touch \(POSIXShellQuote.quote(project.resolvedPath + "/fail-cleanup"))")
        do {
            try await provider.archiveSession(session, project: project)
            fail("AC-24 archive should have thrown cleanupFailed")
        } catch let error as RuntimeProviderError {
            if case .cleanupFailed = error {
                check(true, "AC-24 hook failure surfaces as cleanupFailed")
            } else {
                fail("AC-24 unexpected error: \(error)")
            }
        } catch {
            fail("AC-24 unexpected error type")
        }
        let midState = await ssh(host.alias, """
        "\(tmux)" has-session -t =\(session.backendID) 2>/dev/null && s=1 || s=0
        [ -d \(POSIXShellQuote.quote(worktreePath)) ] && w=1 || w=0
        printf 'RTERM_SESSION=%s\\nRTERM_WT=%s\\n' "$s" "$w"
        """)
        check(midState.markers()["RTERM_SESSION"] == "0", "AC-24 tmux session terminated before/despite hook failure")
        check(midState.markers()["RTERM_WT"] == "1", "AC-24 worktree intact after failed cleanup")

        // --- Retry after fixing the condition (Retry Cleanup path).
        _ = await ssh(host.alias, "rm -f \(POSIXShellQuote.quote(project.resolvedPath + "/fail-cleanup"))")
        do {
            try await provider.archiveSession(session, project: project)
            check(true, "AC-24 retry cleanup succeeds")
        } catch {
            fail("AC-24 retry: \(error.localizedDescription)")
        }
        let final = await ssh(host.alias, """
        [ -d \(POSIXShellQuote.quote(worktreePath)) ] && w=1 || w=0
        cat \(POSIXShellQuote.quote(project.resolvedPath + "/shutdown-env.txt")) 2>/dev/null | grep -c RTERM_ | sed 's/^/RTERM_ENVC=/'
        grep -q 'RTERM_SHUTDOWN_REASON=archive' \(POSIXShellQuote.quote(project.resolvedPath + "/shutdown-env.txt")) 2>/dev/null && r=1 || r=0
        printf 'RTERM_WT=%s\\nRTERM_REASON=%s\\n' "$w" "$r"
        """)
        check(final.markers()["RTERM_WT"] == "0", "AC-24 worktree removed by shutdown hook (no --force)")
        check(final.markers()["RTERM_REASON"] == "1", "AC-24 hook received RTERM_SHUTDOWN_REASON=archive")

        // --- Kill never runs the hook.
        guard let killVictim = await createSession(project, name: "kill victim") else { return }
        try? await Task.sleep(for: .seconds(2))
        _ = await ssh(host.alias, "rm -f \(POSIXShellQuote.quote(project.resolvedPath + "/shutdown-env.txt"))")
        try? await provider.destroySession(killVictim, project: project)
        let killCheck = await ssh(host.alias, """
        [ -f \(POSIXShellQuote.quote(project.resolvedPath + "/shutdown-env.txt")) ] && echo RTERM_HOOK=1 || echo RTERM_HOOK=0
        """)
        check(killCheck.markers()["RTERM_HOOK"] == "0", "AC-24 Kill Session never runs the shutdown hook")
        // The kill victim's worktree is inside the temp root; removed with it.
    }

    // MARK: Cleanup (§21.4, AC-14)

    func cleanupHost(_ host: E2EHostState) async {
        let result = await ssh(host.alias, E2ECleanup.cleanupScript(runID: runID, tempRoot: host.tempRoot))
        if result.exitCode != 0 {
            fail("cleanup on \(host.alias): exit \(result.exitCode) \(result.stderr)")
        } else {
            print("\(host.alias): cleaned up")
        }
    }

    func verifyHostClean(_ host: E2EHostState) async {
        let verify = await ssh(host.alias, """
        for c in tmux /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
          if command -v "$c" >/dev/null 2>&1; then tp=$(command -v "$c"); break; fi
        done
        marked=$("$tp" list-sessions -F '#{session_name} #{@rterm_e2e_run}' 2>/dev/null | grep -c \(POSIXShellQuote.quote(runID)) || true)
        printf 'RTERM_MARKED=%s\\n' "$marked"
        [ -d \(POSIXShellQuote.quote(host.tempRoot)) ] && echo RTERM_ROOT=1 || echo RTERM_ROOT=0
        "$tp" list-sessions -F '#{session_name}' 2>/dev/null || true
        """)
        check(verify.markers()["RTERM_MARKED"] == "0", "AC-14 no e2e-marked tmux sessions remain on \(host.alias)")
        check(verify.markers()["RTERM_ROOT"] == "0", "AC-14 temp root removed on \(host.alias)")

        // AC-13: every pre-existing session is still present.
        let now = Set(
            verify.stdout.split(separator: "\n")
                .map(String.init)
                .filter { !$0.hasPrefix("RTERM_") })
        let missing = (preexisting[host.alias] ?? []).subtracting(now)
        check(missing.isEmpty, "AC-13 pre-existing tmux sessions untouched on \(host.alias)\(missing.isEmpty ? "" : " (missing: \(missing))")")
    }
}
