import Foundation

/// Remote scripts for agent status: Relay's hook reporter (installed under
/// `~/.relay/agent-status`), the plugin manifests that wire it into each
/// agent globally, the install probe, and the watch loop that streams every
/// session's reported state back.
///
/// The flow: an agent hook runs `report.sh <agent> <state>`, which records
/// `"<agent> <state> <epoch>"` as the `@relay_agent` option of the agent's
/// Relay tmux session (found through `$RTERM_SESSION_ID`, which every
/// Relay session's environment carries). The watch loop reads that option
/// for all sessions — attached or not — with `tmux list-sessions`.
extension SSHTmuxScripts {
    /// Bumped whenever any reporter file changes; the probe compares it so
    /// stale files get rewritten.
    static let agentReporterVersion = "1"

    static let agentStatusBegin = "RAGENT_BEGIN"
    static let agentStatusEnd = "RAGENT_END"

    /// The hook command for one event. Never fails the hook: a missing
    /// script (files removed, home not mounted) is silently skipped.
    static func reporterInvocation(agent: CodingAgent, state: String) -> String {
        #"sh "$HOME/\#(AgentLaunchInjection.reporterDirectory)/report.sh" \#(agent.rawValue) \#(state) 2>/dev/null || true"#
    }

    /// report.sh. Silent on stdout (hook output can reach the agent's
    /// context), drains stdin (hook payloads can exceed a pipe buffer),
    /// and always exits 0.
    static let reporterScript = #"""
    #!/bin/sh
    # Relay agent status reporter (v\#(agentReporterVersion)). Run by coding-agent hooks:
    #   report.sh <agent> <state>
    # Records the state on the agent's Relay tmux session as @relay_agent,
    # where the Relay app reads it. Safe to delete: hooks skip a missing file.
    cat >/dev/null 2>&1
    {
      agent=$1 state=$2
      [ -n "${RTERM_SESSION_ID:-}" ] || exit 0
      t=$(command -v tmux 2>/dev/null)
      if [ -z "$t" ]; then
        for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux /opt/local/bin/tmux "$HOME/.local/bin/tmux" "$HOME/bin/tmux"; do
          if [ -x "$p" ]; then t=$p; break; fi
        done
      fi
      [ -n "$t" ] || exit 0
      s=$("$t" list-sessions -F '#{session_name} #{@rterm_session_id}' 2>/dev/null \
        | awk -v id="$RTERM_SESSION_ID" '$2 == id { print $1; exit }')
      [ -n "$s" ] || exit 0
      if [ "$state" = end ]; then
        "$t" set-option -u -t "$s" @relay_agent
      else
        "$t" set-option -t "$s" @relay_agent "$agent $state $(date +%s)"
      fi
    } >/dev/null 2>&1 </dev/null
    exit 0
    """#

    // MARK: Hook configuration

    /// Claude Code's `hooks` object, shared by the per-session settings
    /// file and the global plugin.
    static func claudeHooksObject() -> [String: Any] {
        var hooks: [String: [[String: Any]]] = [:]
        for hook in ClaudeHooks.hooks {
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": reporterInvocation(agent: .claude, state: hook.state), "timeout": 10]],
            ]
            if let matcher = hook.matcher { group["matcher"] = matcher }
            hooks[hook.event, default: []].append(group)
        }
        return hooks
    }

    static func codexHooksObject() -> [String: Any] {
        var hooks: [String: [[String: Any]]] = [:]
        for (event, state) in CodexHooks.events {
            hooks[event, default: []].append([
                "hooks": [["type": "command", "command": reporterInvocation(agent: .codex, state: state)]],
            ])
        }
        return hooks
    }

    private static func json(_ object: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Plugin identity, shared by both agents' marketplaces.
    static let pluginName = "relay-status"
    static let marketplaceName = "relay"
    static var pluginKey: String { "\(pluginName)@\(marketplaceName)" }
    private static let pluginDescription = "Reports agent status (working, needs input, done) to the Relay app."

    /// Every reporter file, relative to the reporter directory.
    static func agentReporterFiles() -> [(path: String, contents: String)] {
        let version = "1.0.\(agentReporterVersion)"
        let claudePlugin = "claude-marketplace/plugins/\(pluginName)"
        let codexPlugin = "codex-marketplace/plugins/\(pluginName)"
        return [
            ("report.sh", reporterScript),
            ("claude-settings.json", json(["hooks": claudeHooksObject()])),
            ("claude-marketplace/.claude-plugin/marketplace.json", json([
                "name": marketplaceName,
                "owner": ["name": "Relay"],
                "plugins": [["name": pluginName, "source": "./plugins/\(pluginName)", "description": pluginDescription, "version": version]],
            ])),
            ("\(claudePlugin)/.claude-plugin/plugin.json", json([
                "name": pluginName, "version": version, "description": pluginDescription,
            ])),
            ("\(claudePlugin)/hooks/hooks.json", json(["description": pluginDescription, "hooks": claudeHooksObject()])),
            ("codex-marketplace/.agents/plugins/marketplace.json", json([
                "name": marketplaceName,
                "owner": ["name": "Relay"],
                "plugins": [[
                    "name": pluginName, "source": "./plugins/\(pluginName)", "description": pluginDescription,
                    "version": version, "category": "productivity",
                    "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"],
                ]],
            ])),
            ("\(codexPlugin)/.codex-plugin/plugin.json", json([
                "name": pluginName, "version": version, "description": pluginDescription, "author": ["name": "Relay"],
            ])),
            ("\(codexPlugin)/hooks/hooks.json", json(["hooks": codexHooksObject()])),
            ("VERSION", agentReporterVersion),
        ]
    }

    /// Shell fragment writing every reporter file into `$rd` (created).
    /// Each file goes through a temp file + rename, so a hook never runs a
    /// half-written script.
    static func writeAgentReporterFilesFragment() -> String {
        var lines = [
            #"rd="$HOME/\#(AgentLaunchInjection.reporterDirectory)""#,
            #"mkdir -p "$rd" || { printf 'RTERM_AGENT_STATUS=mkdir_failed\n'; exit 31; }"#,
        ]
        for file in agentReporterFiles() {
            precondition(!file.contents.contains("RELAY_AGENT_EOF"))
            let dir = (file.path as NSString).deletingLastPathComponent
            if !dir.isEmpty { lines.append(#"mkdir -p "$rd/\#(dir)""#) }
            lines.append(#"cat > "$rd/\#(file.path).tmp" <<'RELAY_AGENT_EOF'"#)
            lines.append(file.contents)
            lines.append("RELAY_AGENT_EOF")
            lines.append(#"mv -f "$rd/\#(file.path).tmp" "$rd/\#(file.path)" || { printf 'RTERM_AGENT_STATUS=write_failed\n'; exit 32; }"#)
        }
        lines.append(#"chmod +x "$rd/report.sh" 2>/dev/null || true"#)
        return lines.joined(separator: "\n")
    }

    /// Shell function `find_agent_cli <name>`: the agent CLI's path, looking
    /// past the bare non-interactive PATH (agents usually live in
    /// ~/.local/bin or a version manager the login shell sets up).
    private static let findAgentCLIFragment = #"""
    find_agent_cli() {
      for p in "$HOME/.local/bin/$1" "$HOME/.claude/local/$1" "$HOME/bin/$1" "/opt/homebrew/bin/$1" "/usr/local/bin/$1"; do
        if [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
      done
      if command -v "$1" >/dev/null 2>&1; then command -v "$1"; return 0; fi
      p=$("${SHELL:-/bin/sh}" -l -c "command -v $1" 2>/dev/null </dev/null | tail -n 1)
      case "$p" in /*) if [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi ;; esac
      return 1
    }
    """#

    /// Shell fragment setting `$claude_global` / `$codex_global` to 1 when
    /// Relay's plugin is installed and enabled.
    private static let globalInstallChecksFragment = #"""
    cd_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    claude_global=0
    if grep -q '"\#(pluginKey)"' "$cd_dir/plugins/installed_plugins.json" 2>/dev/null \
      && grep -q '"\#(pluginKey)": *true' "$cd_dir/settings.json" 2>/dev/null; then
      claude_global=1
    fi
    cx_dir="${CODEX_HOME:-$HOME/.codex}"
    codex_global=0
    if [ -f "$cx_dir/config.toml" ]; then
      codex_global=$(awk '
        $0 == "[plugins.\"\#(pluginKey)\"]" { inside = 1; next }
        /^\[/ { inside = 0 }
        inside && /^[ \t]*enabled[ \t]*=[ \t]*true/ { found = 1 }
        END { print found ? 1 : 0 }' "$cx_dir/config.toml" 2>/dev/null)
    fi
    """#

    /// Reports, per agent, whether its CLI exists and Relay's global plugin
    /// is installed, plus the installed reporter file version.
    static func probeAgentReporters() -> String {
        """
        set -u
        \(findAgentCLIFragment)
        \(globalInstallChecksFragment)
        claude_cli=$(find_agent_cli claude) || claude_cli=""
        codex_cli=$(find_agent_cli codex) || codex_cli=""
        printf 'RTERM_AGENT_CLAUDE_CLI=%s\\n' "$claude_cli"
        printf 'RTERM_AGENT_CLAUDE_GLOBAL=%s\\n' "$claude_global"
        printf 'RTERM_AGENT_CODEX_CLI=%s\\n' "$codex_cli"
        printf 'RTERM_AGENT_CODEX_GLOBAL=%s\\n' "$codex_global"
        # Keep already-installed reporter files current (global plugins
        # call report.sh in place, so this upgrades them too).
        files=$(cat "$HOME/\(AgentLaunchInjection.reporterDirectory)/VERSION" 2>/dev/null) || files=""
        if [ -n "$files" ] && [ "$files" != \(agentReporterVersion) ]; then
          ( \(writeAgentReporterFilesFragment()) ) >/dev/null 2>&1 && files=\(agentReporterVersion)
        fi
        printf 'RTERM_AGENT_FILES=%s\\n' "$files"
        printf 'RTERM_AGENT_STATUS=ok\\n'
        """
    }

    /// Writes the reporter files (no agent configuration changes) — all a
    /// per-session reporter needs.
    static func installAgentReporterFiles() -> String {
        """
        set -u
        \(writeAgentReporterFilesFragment())
        printf 'RTERM_AGENT_STATUS=ok\\n'
        """
    }

    /// Writes the reporter files, then registers Relay's local marketplace
    /// with the agent and installs the plugin from it (both idempotent).
    static func installGlobalAgentReporter(agent: CodingAgent) -> String {
        let commands: String
        switch agent {
        case .claude:
            commands = #"""
            "$cli" plugin marketplace add "$rd/claude-marketplace" </dev/null || exit 34
            "$cli" plugin install \#(pluginKey) </dev/null || exit 35
            """#
        case .codex:
            commands = #"""
            "$cli" plugin marketplace add "$rd/codex-marketplace" </dev/null || exit 34
            "$cli" plugin add \#(pluginKey) </dev/null || exit 35
            """#
        }
        return """
        set -u
        \(findAgentCLIFragment)
        cli=$(find_agent_cli \(agent.rawValue)) || { printf 'RTERM_AGENT_STATUS=no_cli\\n'; exit 33; }
        \(writeAgentReporterFilesFragment())
        \(commands)
        \(globalInstallChecksFragment)
        [ "$\(agent.rawValue)_global" = 1 ] || { printf 'RTERM_AGENT_STATUS=not_enabled\\n'; exit 36; }
        printf 'RTERM_AGENT_STATUS=ok\\n'
        """
    }

    // MARK: Watch loop

    /// Streams every Relay session's agent report: one
    /// `RAGENT_BEGIN` … `RAGENT_END` block (tab-separated
    /// `name, @relay_agent, pane command, pane title` lines) whenever
    /// anything changed, and at least every `heartbeat` polls so the
    /// caller can tell a quiet host from a dead connection. Bounded like
    /// the load loop; dies with its ssh connection.
    static func agentStatusWatch(knownTmuxPath: String?, interval: Int, iterations: Int, heartbeat: Int = 10) -> String {
        let interval = min(max(interval, 1), 60)
        let iterations = min(max(iterations, 1), 100_000)
        return """
        set -u
        trap 'exit 0' HUP PIPE TERM
        \(tmuxPreamble(knownTmuxPath: knownTmuxPath))
        fmt=$(printf '#{session_name}\\t#{@relay_agent}\\t#{pane_current_command}\\t#{host}\\t#{pane_title}')
        prev=""
        quiet=0
        i=0
        while [ "$i" -lt \(iterations) ]; do
          cur=$("$tmux_path" list-sessions -F "$fmt" 2>/dev/null | grep '^\(TmuxNaming.prefix)')
          if [ "$cur" != "$prev" ] || [ "$quiet" -ge \(heartbeat) ]; then
            printf '\(agentStatusBegin)\\n%s\\n\(agentStatusEnd)\\n' "$cur" || exit 0
            prev=$cur
            quiet=0
          else
            quiet=$((quiet + 1))
          fi
          i=$((i + 1))
          sleep \(interval)
        done
        """
    }
}

/// Incrementally parses `agentStatusWatch` output into snapshots.
public struct AgentStatusParser: Sendable {
    /// Undecoded bytes: a chunk can end mid-line, even mid-character.
    private var pending = Data()
    private var block: [AgentStatusReport]?

    public init() {}

    /// Feeds raw output; returns every snapshot completed by this chunk.
    public mutating func feed(_ data: Data) -> [[AgentStatusReport]] {
        pending.append(data)
        var snapshots: [[AgentStatusReport]] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            var line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            pending.removeSubrange(pending.startIndex...newline)
            switch line {
            case SSHTmuxScripts.agentStatusBegin:
                block = []
            case SSHTmuxScripts.agentStatusEnd:
                if let reports = block { snapshots.append(reports) }
                block = nil
            default:
                guard block != nil, let report = Self.parse(line: line) else { continue }
                block?.append(report)
                if (block?.count ?? 0) > 2000 { block = nil }
            }
        }
        if pending.count > 65_536 { pending.removeAll() }
        return snapshots
    }

    static func parse(line: String) -> AgentStatusReport? {
        let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0].hasPrefix(TmuxNaming.prefix) else { return nil }
        let activity = fields[1].isEmpty ? nil : AgentActivity(wire: String(fields[1]))
        // Same rule as the session sweep (`TmuxSessionCodec`): tmux defaults
        // an untouched pane's title to the hostname, which is not a status.
        let title = fields[4].trimmingCharacters(in: .whitespaces)
        return AgentStatusReport(
            backendID: String(fields[0]),
            activity: activity,
            foregroundCommand: String(fields[2]),
            paneTitle: title == fields[3] ? "" : title)
    }
}
