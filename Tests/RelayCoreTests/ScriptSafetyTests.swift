import Foundation
import Testing
@testable import RelayCore

/// Runs generated management scripts against a local /bin/sh with a fake
/// `tmux` binary that records its argv, proving that hostile project paths,
/// display names, and launch commands never execute as shell code.
@Suite("management script safety", .serialized)
struct ScriptSafetyTests {
    struct Sandbox {
        let dir: URL
        let fakeTmux: URL
        let log: URL
        let projectDir: URL

        /// Argv records: one invocation per element, args separated by \u{1F}.
        func invocations() throws -> [[String]] {
            guard let contents = try? String(contentsOf: log, encoding: .utf8) else { return [] }
            return contents.split(separator: "\n").map { line in
                line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            }
        }
    }

    private func withSandbox<T>(_ body: (Sandbox) async throws -> T) async throws -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-scripts-\(UUID().uuidString)")
        let projectDir = dir.appendingPathComponent("project dir with 'quote")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("tmux.log")
        let fakeTmux = dir.appendingPathComponent("tmux")
        // Records argv joined by the unit separator, one line per call.
        // `has-session` reports "no such session" so kill scripts see success.
        let script = """
        #!/bin/sh
        out=""
        for a in "$@"; do out="$out$a\u{1F}"; done
        printf '%s\\n' "$out" >> \(POSIXShellQuote.quote(log.path))
        [ "$1" = "has-session" ] && exit 1
        exit 0
        """
        try script.write(to: fakeTmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTmux.path)

        return try await body(Sandbox(dir: dir, fakeTmux: fakeTmux, log: log, projectDir: projectDir))
    }

    private func runScript(_ script: String) async throws -> SSHCommandRunner.CommandResult {
        try await SSHCommandRunner.runProcess(
            executable: "/bin/sh",
            arguments: ["-s"],
            stdin: script,
            timeout: .seconds(15)
        )
    }

    @Test func hostileNamesNeverExecute() async throws {
        try await withSandbox { sandbox in
            let pwnMarker = sandbox.dir.appendingPathComponent("pwned").path
            let hostileName = "fix $PATH; echo nope ' \" $(touch \(pwnMarker)) `touch \(pwnMarker)`"

            let script = SSHTmuxScripts.createSession(.init(
                tmuxName: "rterm-cafe0123beef4567",
                windowName: "hostile-test",
                pathInput: sandbox.projectDir.path,
                knownTmuxPath: sandbox.fakeTmux.path,
                launchCommand: "echo \"launch with 'quotes' and $HOME\"",
                environment: [
                    ("RTERM_PROJECT_NAME", "name with ' quote; rm -rf /"),
                    ("RTERM_SESSION_NAME", hostileName),
                ],
                metadata: [
                    ("@rterm_schema", "1"),
                    ("@rterm_session_name_b64", TmuxSessionCodec.encodeDisplayName(hostileName)),
                ]
            ))

            let result = try await runScript(script)
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            #expect(result.markers()["RTERM_STATUS"] == "ok")
            #expect(!FileManager.default.fileExists(atPath: pwnMarker),
                    "hostile session name executed shell code")

            let calls = try sandbox.invocations()
            let newSession = try #require(calls.first { $0.first == "new-session" })
            // The hostile name must arrive as ONE argv element, verbatim.
            #expect(newSession.contains("RTERM_SESSION_NAME=\(hostileName)"))
            // The resolved project path (with spaces and quote) is one element.
            let cIndex = try #require(newSession.firstIndex(of: "-c"))
            #expect(newSession[cIndex + 1].hasSuffix("project dir with 'quote"))
        }
    }

    @Test func launchCommandsGetUserBinPATHAndFailureRetention() async throws {
        try await withSandbox { sandbox in
            let script = SSHTmuxScripts.createSession(.init(
                tmuxName: "rterm-feedbeef00112233",
                windowName: "some-tool",
                pathInput: sandbox.projectDir.path,
                knownTmuxPath: sandbox.fakeTmux.path,
                launchCommand: "some-tool",
                environment: [],
                metadata: [("@rterm_schema", "1")]
            ))
            let result = try await runScript(script)
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")

            let calls = try sandbox.invocations()
            let newSession = try #require(calls.first { $0.first == "new-session" })
            // The pane bootstrap prepends user bin dirs before the login shell
            // (installers put claude/codex PATH exports in interactive-only rc
            // files, which login non-interactive shells never read).
            let paneCommand = try #require(newSession.last(where: { !$0.isEmpty }))
            #expect(paneCommand.contains("$HOME/.local/bin"))
            #expect(paneCommand.contains("-l -i -c"), "launch runs in an interactive login shell (pane has a tty)")
            // tmux is an invisible persistence layer: launched tools must not
            // see $TMUX (they change behavior when they do), and get the
            // truecolor the ghostty side always provides.
            #expect(paneCommand.contains("unset TMUX TMUX_PANE"))
            #expect(paneCommand.contains("COLORTERM=truecolor"))
            // Failed launches keep their dead pane visible.
            #expect(calls.contains { $0.first == "set-option" && $0.contains("remain-on-exit") && $0.contains("failed") })
            // The tmux status strip is hidden for app-owned sessions.
            #expect(calls.contains { $0.first == "set-option" && $0.contains("status") && $0.contains("off") })
            // Session-scoped native-feel options are applied to our session
            // only. Mouse stays off: selection and scrolling belong to the
            // terminal, not tmux.
            for opt in [["mouse", "off"], ["allow-passthrough", "on"], ["set-titles", "on"]] {
                #expect(calls.contains { $0.first == "set-option" && $0.contains("-t") && $0.contains(opt[0]) && $0.contains(opt[1]) },
                        "missing session option \(opt[0])")
            }
            // Relay-only servers keep attach clients out of the alternate
            // screen so scrollback is native.
            #expect(calls.contains { $0.first == "set-option" && $0.contains("terminal-overrides") && $0.contains(",xterm-256color:smcup@:rmcup@") })
        }
    }

    @Test func plainShellSessionsDoNotRetainDeadPanes() async throws {
        try await withSandbox { sandbox in
            let script = SSHTmuxScripts.createSession(.init(
                tmuxName: "rterm-feedbeef44556677",
                windowName: "plain",
                pathInput: sandbox.projectDir.path,
                knownTmuxPath: sandbox.fakeTmux.path,
                launchCommand: nil,
                environment: [],
                metadata: [("@rterm_schema", "1")]
            ))
            _ = try await runScript(script)
            let calls = try sandbox.invocations()
            #expect(!calls.contains { $0.contains("remain-on-exit") })
        }
    }

    @Test func killTargetsExactSession() async throws {
        try await withSandbox { sandbox in
            let script = SSHTmuxScripts.killSession(
                tmuxName: "rterm-0123456789abcdef",
                knownTmuxPath: sandbox.fakeTmux.path
            )
            let result = try await runScript(script)
            #expect(result.exitCode == 0)
            #expect(result.markers()["RTERM_STATUS"] == "ok")

            let calls = try sandbox.invocations()
            let killCall = try #require(calls.first { $0.first == "kill-session" })
            #expect(killCall.contains("=rterm-0123456789abcdef"))
            // Never a broad kill.
            #expect(!calls.contains { $0.first == "kill-server" })
        }
    }

    @Test func gitStateScriptHandlesMissingPaneAsNotARepo() async throws {
        try await withSandbox { sandbox in
            let script = SSHTmuxScripts.gitState(
                tmuxName: "rterm-0123456789abcdef",
                knownTmuxPath: sandbox.fakeTmux.path
            )
            let result = try await runScript(script)
            // The fake tmux prints nothing for display-message, so the
            // script must take the graceful "no git context" exit.
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            #expect(result.markers()[SSHTmuxScripts.Marker.git] == "none")

            // Regression guard: display-message targets the plain session
            // name — tmux silently rejects the `=` exact-match prefix here.
            let calls = try sandbox.invocations()
            let display = try #require(calls.first { $0.first == "display-message" })
            #expect(display.contains("rterm-0123456789abcdef"))
            #expect(!display.contains("=rterm-0123456789abcdef"))
        }
    }

    @Test func validateScriptResolvesCanonicalPath() async throws {
        try await withSandbox { sandbox in
            // Validation resolves the tmux on PATH; give it ours.
            var script = SSHTmuxScripts.validate(pathInput: sandbox.projectDir.path)
            script = "PATH=\(POSIXShellQuote.quote(sandbox.dir.path)):$PATH\n" + script
            let result = try await runScript(script)
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            let markers = result.markers()
            #expect(markers["RTERM_STATUS"] == "ok")
            #expect(markers["RTERM_TMUX"] == sandbox.fakeTmux.path)
            let resolved = try #require(markers["RTERM_PWD"])
            #expect(resolved.hasSuffix("project dir with 'quote"))
        }
    }

    @Test func validateScriptRejectsMissingDirectory() async throws {
        try await withSandbox { sandbox in
            var script = SSHTmuxScripts.validate(pathInput: sandbox.dir.appendingPathComponent("missing").path)
            script = "PATH=\(POSIXShellQuote.quote(sandbox.dir.path)):$PATH\n" + script
            let result = try await runScript(script)
            #expect(result.exitCode == 22)
            #expect(result.markers()["RTERM_STATUS"] == "no_dir")
        }
    }

    @Test func shutdownHookReceivesContext() async throws {
        try await withSandbox { sandbox in
            let envDump = sandbox.dir.appendingPathComponent("env.txt").path
            let script = SSHTmuxScripts.shutdownHook(.init(
                pathInput: sandbox.projectDir.path,
                shutdownCommand: "env | grep '^RTERM_' | sort > \(POSIXShellQuote.quote(envDump)); pwd >> \(POSIXShellQuote.quote(envDump))",
                environment: [
                    ("RTERM_SESSION_NAME", "weird ' name $HOME"),
                    ("RTERM_SHUTDOWN_REASON", "archive"),
                ]
            ))
            let result = try await runScript(script)
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            let dump = try String(contentsOfFile: envDump, encoding: .utf8)
            #expect(dump.contains("RTERM_SESSION_NAME=weird ' name $HOME"))
            #expect(dump.contains("RTERM_SHUTDOWN_REASON=archive"))
            #expect(dump.contains("project dir with 'quote"))
        }
    }
}
