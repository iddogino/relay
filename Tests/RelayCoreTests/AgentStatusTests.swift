import Foundation
import Testing
@testable import RelayCore

@Suite("agent status")
struct AgentStatusTests {
    @Test func activityWireRoundTrips() throws {
        let activity = try #require(AgentActivity(wire: "claude blocked 1760000000"))
        #expect(activity.agent == .claude)
        #expect(activity.state == .blocked)
        #expect(activity.since == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(activity.wire == "claude blocked 1760000000")
        #expect(AgentActivity(wire: "") == nil)
        #expect(AgentActivity(wire: "gemini working 1") == nil)
        #expect(AgentActivity(wire: "claude dancing 1") == nil)
        #expect(AgentActivity(wire: "claude working") == nil)
    }

    @Test func detectsAgentsInLaunchCommands() {
        #expect(CodingAgent.detect(launchCommand: "claude") == .claude)
        #expect(CodingAgent.detect(launchCommand: #"claude --worktree="$RTERM_SESSION_SLUG""#) == .claude)
        for preset in HarnessCatalog.groups.flatMap(\.presets) where preset.id.hasPrefix("claude") {
            #expect(CodingAgent.detect(launchCommand: preset.launch) == .claude, "\(preset.id)")
        }
        for preset in HarnessCatalog.groups.flatMap(\.presets) where preset.id.hasPrefix("codex") {
            #expect(CodingAgent.detect(launchCommand: preset.launch) == .codex, "\(preset.id)")
        }
        #expect(CodingAgent.detect(launchCommand: "FOO=1 exec codex --full-auto") == .codex)
        #expect(CodingAgent.detect(launchCommand: "nvm use 22; claude") == .claude)
        #expect(CodingAgent.detect(launchCommand: nil) == nil)
        #expect(CodingAgent.detect(launchCommand: "opencode") == nil)
        #expect(CodingAgent.detect(launchCommand: "echo claude") == nil)
        #expect(CodingAgent.detect(launchCommand: "claude-monitor") == nil)
        #expect(CodingAgent.detect(launchCommand: "/opt/claude/run") == nil)
    }

    @Test func injectsPerSessionHooks() throws {
        let claude = try #require(AgentLaunchInjection.inject(into: "claude --resume", agent: .claude))
        #expect(claude == #"claude --settings "$HOME/.relay/agent-status/claude-settings.json" --resume"#)

        let worktree = try #require(AgentLaunchInjection.inject(
            into: HarnessCatalog.worktreeLaunch(running: "codex"), agent: .codex))
        #expect(worktree.hasPrefix(#"git worktree add ".worktrees/$RTERM_SESSION_SLUG" && cd ".worktrees/$RTERM_SESSION_SLUG" && exec codex -c "#))
        #expect(worktree.contains("hooks.Interrupt="))
        #expect(worktree.contains("report.sh\" codex done"))
        #expect(AgentLaunchInjection.inject(into: "zsh", agent: .claude) == nil)
    }

    @Test func parsesWatchStream() {
        var parser = AgentStatusParser()
        let stream = """
        RTERM_STATUS=ok
        RAGENT_BEGIN
        rterm-aaaa\tclaude working 1760000000\t2.1.304\thost.local\t⠂ Fix the bug
        rterm-bbbb\t\tzsh\thost.local\thost.local
        rterm-cccc\tclaude bogus\tclaude\thost.local\t✳ Title\twith tab
        not-ours\tclaude done 1\tclaude\th\tx
        RAGENT_END
        RAGENT_BEGIN

        RAGENT_END

        """
        var snapshots: [[AgentStatusReport]] = []
        let data = Data(stream.utf8)
        var index = data.startIndex
        while index < data.endIndex {
            let next = min(index + 5, data.endIndex)
            snapshots += parser.feed(data[index..<next])
            index = next
        }
        #expect(snapshots.count == 2)
        let first = snapshots[0]
        #expect(first.map(\.backendID) == ["rterm-aaaa", "rterm-bbbb", "rterm-cccc"])
        #expect(first[0].activity?.state == .working)
        #expect(first[0].foregroundCommand == "2.1.304")
        #expect(first[0].paneTitle == "⠂ Fix the bug")
        #expect(first[1].activity == nil)
        #expect(first[1].paneTitle == "", "the hostname default is not a title")
        #expect(first[2].activity == nil)
        #expect(first[2].paneTitle == "✳ Title\twith tab")
        #expect(snapshots[1].isEmpty)
    }

    @Test func effectiveActivityCorrections() {
        let now = Date(timeIntervalSince1970: 1_760_000_100)
        func report(_ wire: String, command: String = "claude", title: String = "⠂ busy") -> AgentStatusReport {
            AgentStatusReport(backendID: "rterm-x", activity: AgentActivity(wire: wire), foregroundCommand: command, paneTitle: title)
        }
        #expect(report("claude working 1760000090").effectiveActivity(now: now)?.state == .working)
        // Back at a shell: the agent exited without its end hook.
        #expect(report("claude done 1760000090", command: "zsh").effectiveActivity(now: now) == nil)
        #expect(report("claude done 1760000090", command: "-bash").effectiveActivity(now: now) == nil)
        // Esc-interrupt: idle title next to an old "working" report.
        #expect(report("claude working 1760000090", title: "✳ Fix").effectiveActivity(now: now)?.state == .idle)
        // …but not right after the prompt (the title may lag the hook).
        #expect(report("claude working 1760000098", title: "✳ Fix").effectiveActivity(now: now)?.state == .working)
        #expect(report("claude blocked 1760000000", title: "✳ Fix").effectiveActivity(now: now)?.state == .blocked)
        #expect(report("codex working 1760000000", command: "codex", title: "✳").effectiveActivity(now: now)?.state == .working)
    }

    @Test func spinnerFramesSettle() {
        func report(_ title: String) -> AgentStatusReport {
            AgentStatusReport(backendID: "rterm-x", activity: nil, foregroundCommand: "claude", paneTitle: title)
        }
        #expect(report("◐ Fix it").settled == report("◑ Fix it").settled)
        #expect(report("⠂ Fix it").settled == report("⠐ Fix it").settled)
        #expect(report("✳ Fix it").settled.paneTitle == "✳ Fix it")
        #expect(report("✳ Fix it").settled != report("◐ Fix it").settled)
        #expect(report("").settled.paneTitle == "")
    }

    @Test func hookConfigCoversEveryState() throws {
        let files = Dictionary(uniqueKeysWithValues: SSHTmuxScripts.agentReporterFiles().map { ($0.path, $0.contents) })
        let settings = try #require(files["claude-settings.json"])
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
        let hooks = try #require(parsed["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(ClaudeHooks.hooks.map(\.event)))
        #expect(files["claude-marketplace/plugins/relay-status/hooks/hooks.json"]?.contains("PermissionRequest") == true)
        let codex = try #require(files["codex-marketplace/plugins/relay-status/hooks/hooks.json"])
        #expect(codex.contains("Interrupt"))
        for (path, contents) in files where path.hasSuffix(".json") {
            #expect((try? JSONSerialization.jsonObject(with: Data(contents.utf8))) != nil, "\(path)")
        }
    }

    @Test func scriptsAreValidShell() async throws {
        for (name, script) in [
            ("probe", SSHTmuxScripts.probeAgentReporters()),
            ("files", SSHTmuxScripts.installAgentReporterFiles()),
            ("global-claude", SSHTmuxScripts.installGlobalAgentReporter(agent: .claude)),
            ("global-codex", SSHTmuxScripts.installGlobalAgentReporter(agent: .codex)),
            ("watch", SSHTmuxScripts.agentStatusWatch(knownTmuxPath: nil, interval: 2, iterations: 3)),
            ("report", SSHTmuxScripts.reporterScript),
        ] {
            let result = try await SSHCommandRunner.runProcess(
                executable: "/bin/sh", arguments: ["-n"], stdin: script, timeout: .seconds(10))
            #expect(result.exitCode == 0, "\(name): \(result.stderr)")
        }
    }

    /// Runs the real file installer and report.sh against a stub tmux that
    /// records its calls, in a throwaway HOME.
    @Test func reporterRecordsStateOnTheSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-agent-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("tmux.log").path
        let stub = """
        #!/bin/sh
        case "$1" in
          list-sessions) printf 'rterm-other OTHER-ID\\nrterm-mine MY-ID\\n' ;;
          *) printf '%s\\n' "$*" >> \(POSIXShellQuote.quote(log)) ;;
        esac
        """
        let stubPath = bin.appendingPathComponent("tmux").path
        try stub.write(toFile: stubPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath)

        let env = "HOME=\(POSIXShellQuote.quote(root.path)) PATH=\(POSIXShellQuote.quote(bin.path)):/usr/bin:/bin"
        let install = try await SSHCommandRunner.runProcess(
            executable: "/bin/sh", arguments: ["-c", "\(env) /bin/sh -s"],
            stdin: SSHTmuxScripts.installAgentReporterFiles(), timeout: .seconds(10))
        #expect(install.exitCode == 0, "\(install.stderr)")
        #expect(install.markers()["RTERM_AGENT_STATUS"] == "ok")

        // Exactly what a hook runs (stdin = the hook's JSON payload).
        let hook = SSHTmuxScripts.reporterInvocation(agent: .claude, state: "blocked")
        let run = try await SSHCommandRunner.runProcess(
            executable: "/bin/sh", arguments: ["-c", "\(env) RTERM_SESSION_ID=MY-ID /bin/sh -c \(POSIXShellQuote.quote(hook))"],
            stdin: "{\"hook_event_name\":\"PermissionRequest\"}", timeout: .seconds(10))
        #expect(run.exitCode == 0)
        #expect(run.stdout.isEmpty, "hooks must stay silent on stdout")

        let end = SSHTmuxScripts.reporterInvocation(agent: .claude, state: "end")
        _ = try await SSHCommandRunner.runProcess(
            executable: "/bin/sh", arguments: ["-c", "\(env) RTERM_SESSION_ID=MY-ID /bin/sh -c \(POSIXShellQuote.quote(end))"],
            stdin: "", timeout: .seconds(10))
        // Outside a Relay session the reporter does nothing.
        _ = try await SSHCommandRunner.runProcess(
            executable: "/bin/sh", arguments: ["-c", "\(env) /bin/sh -c \(POSIXShellQuote.quote(hook))"],
            stdin: "", timeout: .seconds(10))

        let calls = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(calls.count == 2)
        #expect(calls.first?.hasPrefix("set-option -t rterm-mine @relay_agent claude blocked ") == true)
        #expect(calls.last == "set-option -u -t rterm-mine @relay_agent")

        // The probe sees the files' version and no global installs.
        let probe = try await SSHCommandRunner.runProcess(
            executable: "/bin/sh", arguments: ["-c", "\(env) SHELL=/bin/sh /bin/sh -s"],
            stdin: SSHTmuxScripts.probeAgentReporters(), timeout: .seconds(20))
        // Through markers(), exactly as the provider reads it.
        let markers = probe.markers()
        #expect(markers["RTERM_AGENT_FILES"] == SSHTmuxScripts.agentReporterVersion)
        #expect(markers["RTERM_AGENT_CLAUDE_GLOBAL"] == "0")
        #expect(markers["RTERM_AGENT_STATUS"] == "ok")
    }
}
