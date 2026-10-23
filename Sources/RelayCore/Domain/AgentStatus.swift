import Foundation

/// A coding agent whose turns Relay can follow through the agent's own
/// hook system (see `SSHTmuxScripts.agentReporter`).
public enum CodingAgent: String, Sendable, Hashable, CaseIterable, Codable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The agent a launch command starts, judged by its first command
    /// word (after `exec`, env assignments, or a `&&`/`;` chain — the shape
    /// of the worktree presets). nil for shells and unknown commands.
    public static func detect(launchCommand: String?) -> CodingAgent? {
        guard let launch = launchCommand else { return nil }
        for agent in allCases where AgentLaunchInjection.range(of: agent, in: launch) != nil {
            return agent
        }
        return nil
    }
}

/// Where an agent stands in its current turn, as reported by its hooks.
public enum AgentActivityState: String, Sendable, Hashable {
    /// Running but no turn yet (session just started, or interrupted).
    case idle
    /// A turn is in progress.
    case working
    /// The agent is waiting on the user: a permission prompt or a question.
    case blocked
    /// The agent is compacting its conversation (manual or automatic).
    case compacting
    /// The turn finished.
    case done
    /// The turn ended on an error (API failure, etc.).
    case failed
}

/// The latest hook report for one session: the `@relay_agent` tmux option,
/// wire form `"<agent> <state> <epoch seconds>"`.
public struct AgentActivity: Sendable, Hashable {
    public var agent: CodingAgent
    public var state: AgentActivityState
    /// When the state was reported, on the remote's clock.
    public var since: Date

    public init(agent: CodingAgent, state: AgentActivityState, since: Date) {
        self.agent = agent
        self.state = state
        self.since = since
    }

    public init?(wire: String) {
        let parts = wire.split(separator: " ")
        guard parts.count == 3,
              let agent = CodingAgent(rawValue: String(parts[0])),
              let state = AgentActivityState(rawValue: String(parts[1])),
              let epoch = TimeInterval(parts[2])
        else { return nil }
        self.init(agent: agent, state: state, since: Date(timeIntervalSince1970: epoch))
    }

    public var wire: String {
        "\(agent.rawValue) \(state.rawValue) \(Int(since.timeIntervalSince1970))"
    }
}

/// One session's raw status inputs from the remote watch loop.
public struct AgentStatusReport: Sendable, Hashable {
    /// The provider's backend ID (tmux session name).
    public var backendID: String
    /// nil when no hook has reported (or the agent ended its session).
    public var activity: AgentActivity?
    /// The pane's foreground command (`zsh`, `claude`, … — on macOS
    /// Claude Code shows up as its version, e.g. `2.1.304`).
    public var foregroundCommand: String
    public var paneTitle: String

    public init(backendID: String, activity: AgentActivity?, foregroundCommand: String, paneTitle: String) {
        self.backendID = backendID
        self.activity = activity
        self.foregroundCommand = foregroundCommand
        self.paneTitle = paneTitle
    }

    /// The report with an animated title spinner (Claude Code cycles
    /// ◐/◑ and braille frames while working) folded to one frame, so a
    /// busy agent doesn't register as a change on every poll. The idle
    /// "✳" stays distinct.
    public var settled: AgentStatusReport {
        guard let first = paneTitle.unicodeScalars.first,
              (0x2800...0x28FF).contains(first.value) || (0x25D0...0x25D3).contains(first.value)
        else { return self }
        var copy = self
        copy.paneTitle = "◐" + String(paneTitle.unicodeScalars.dropFirst())
        return copy
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "login"]

    /// The state worth showing, or nil. Hook reports are authoritative,
    /// with two corrections for the gaps hooks leave:
    /// - the pane is back at a shell → the agent exited without its
    ///   end hook (crash, kill), so the report is stale;
    /// - Claude Code reports no hook on Esc-interrupt, but its title drops
    ///   the spinner back to the idle "✳" — a "working" report older than
    ///   a few seconds next to an idle title means the turn was cut short.
    public func effectiveActivity(now: Date = Date()) -> AgentActivity? {
        guard var activity else { return nil }
        let command = foregroundCommand.hasPrefix("-") ? String(foregroundCommand.dropFirst()) : foregroundCommand
        if Self.shells.contains(command) { return nil }
        if activity.agent == .claude, activity.state == .working,
           paneTitle.hasPrefix("✳"), now.timeIntervalSince(activity.since) > 5 {
            activity.state = .idle
        }
        return activity
    }
}

/// Per-agent install state of Relay's status reporter on one machine.
public struct AgentReporterStatus: Sendable, Hashable {
    /// The agent's CLI is on the machine (needed for the global install).
    public var cliFound: Bool
    /// Relay's global plugin is installed and enabled for every session.
    public var globalInstalled: Bool

    public init(cliFound: Bool, globalInstalled: Bool) {
        self.cliFound = cliFound
        self.globalInstalled = globalInstalled
    }
}

/// Rewrites a launch command so one session's agent loads Relay's hooks
/// without any global install: `claude` gains `--settings <file>`, `codex`
/// gains the equivalent `-c hooks.*` overrides.
public enum AgentLaunchInjection {
    /// Where the reporter files live on the remote (relative to `$HOME`).
    public static let reporterDirectory = ".relay/agent-status"

    /// The arguments to splice in right after the agent's command word.
    /// Expanded by the remote shell, so `$HOME` resolves there.
    public static func arguments(for agent: CodingAgent) -> String {
        switch agent {
        case .claude:
            return #"--settings "$HOME/\#(reporterDirectory)/claude-settings.json""#
        case .codex:
            // Codex keys hook trust by the hook's text, so these must stay
            // byte-identical across sessions: one "trust" click covers all.
            return CodexHooks.events.map { event, state in
                "-c " + POSIXShellQuote.quote(
                    "hooks.\(event)=[{hooks=[{type='command',command='\(SSHTmuxScripts.reporterInvocation(agent: .codex, state: state))'}]}]")
            }.joined(separator: " ")
        }
    }

    /// The launch command with the hooks injected, or nil when the agent's
    /// command word can't be found (the caller then launches unchanged).
    public static func inject(into launch: String, agent: CodingAgent) -> String? {
        guard let range = range(of: agent, in: launch) else { return nil }
        var result = launch
        result.insert(contentsOf: " " + arguments(for: agent), at: range.upperBound)
        return result
    }

    /// The range of the agent's command word where it is invoked: at the
    /// start, after `exec`, after env assignments, or after `&&`, `||`,
    /// `;`, `|`. Never inside an argument (`echo claude`) or a path.
    static func range(of agent: CodingAgent, in launch: String) -> Range<String.Index>? {
        let name = NSRegularExpression.escapedPattern(for: agent.rawValue)
        let pattern = #"(?:^|&&|\|\||[;|(])\s*(?:(?:exec|env|command)\s+|[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*("# + name + #")(?=\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: launch, range: NSRange(launch.startIndex..., in: launch)),
              let range = Range(match.range(at: 1), in: launch)
        else { return nil }
        return range
    }
}

/// The hook events each agent reports, mapped to the state they set.
/// `end` clears the report (the agent exited cleanly); `restore` puts back
/// the state from before `compacting` (done after a manual /compact,
/// working after an automatic one mid-turn).
enum ClaudeHooks {
    struct Hook {
        let event: String
        let matcher: String?
        let state: String
    }

    static let hooks: [Hook] = [
        // Not "compact": that SessionStart follows a compaction, which
        // restores the state from before it instead.
        Hook(event: "SessionStart", matcher: "startup|resume|clear", state: "idle"),
        Hook(event: "PreCompact", matcher: nil, state: "compacting"),
        Hook(event: "PostCompact", matcher: nil, state: "restore"),
        Hook(event: "SessionStart", matcher: "compact", state: "restore"),
        Hook(event: "UserPromptSubmit", matcher: nil, state: "working"),
        // A question to the user is a tool call that waits on them.
        Hook(event: "PreToolUse", matcher: "AskUserQuestion", state: "blocked"),
        Hook(event: "PermissionRequest", matcher: nil, state: "blocked"),
        Hook(event: "Notification", matcher: "elicitation_dialog", state: "blocked"),
        // Any finished tool means the agent is moving again (clears
        // "blocked" after a granted permission or an answered question).
        Hook(event: "PostToolUse", matcher: nil, state: "working"),
        Hook(event: "Stop", matcher: nil, state: "done"),
        Hook(event: "StopFailure", matcher: nil, state: "failed"),
        Hook(event: "SessionEnd", matcher: nil, state: "end"),
    ]
}

enum CodexHooks {
    static let events: [(event: String, state: String)] = [
        ("SessionStart", "idle"),
        ("UserPromptSubmit", "working"),
        ("PermissionRequest", "blocked"),
        ("PostToolUse", "working"),
        ("Stop", "done"),
        ("Interrupt", "idle"),
        ("SessionEnd", "end"),
    ]
}
