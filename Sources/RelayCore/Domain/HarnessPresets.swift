import Foundation

/// One selectable session harness: a launch command plus the cleanup that
/// undoes what it created.
public struct HarnessPreset: Identifiable, Hashable, Sendable {
    /// Stable key — persisted in the per-project "last used" memory.
    public let id: String
    /// Menu row label.
    public let title: String
    public let launch: String
    public let cleanup: String?

    public init(id: String, title: String, launch: String, cleanup: String?) {
        self.id = id
        self.title = title
        self.launch = launch
        self.cleanup = cleanup
    }
}

/// The built-in harness catalog, grouped for menu display. Shared by the
/// project editor (picking a project default) and the new-session sheet
/// (picking a harness for one session).
public enum HarnessCatalog {
    public struct Group: Identifiable, Sendable {
        public let name: String
        public let presets: [HarnessPreset]
        public var id: String { name }
    }

    /// Launch: fresh worktree named after the session, run `command` in it.
    /// `git worktree add` with a plain path creates a branch named after its
    /// basename — the slug — which is what the cleanup deletes.
    public static func worktreeLaunch(running command: String) -> String {
        #"git worktree add ".worktrees/$RTERM_SESSION_SLUG" && cd ".worktrees/$RTERM_SESSION_SLUG" && exec "# + command
    }

    public static let worktreeCleanup =
        #"git worktree remove ".worktrees/$RTERM_SESSION_SLUG" && git branch -d "$RTERM_SESSION_SLUG""#

    /// Agents without a native worktree flag get the generic git-worktree
    /// wrapper.
    private static let wrapperAgents: [(name: String, command: String)] = [
        ("Codex", "codex"),
        ("Pi", "pi"),
        ("OpenCode", "opencode"),
    ]

    public static let groups: [Group] = {
        var groups: [Group] = [
            Group(name: "Claude Code", presets: [
                HarnessPreset(id: "claude", title: "claude", launch: "claude", cleanup: nil),
                // claude --worktree=NAME puts the tree at
                // .claude/worktrees/NAME on a LOCKED branch named
                // worktree-NAME (verified empirically), hence the unlock.
                HarnessPreset(
                    id: "claude-worktree",
                    title: "claude in a new worktree",
                    launch: #"claude --worktree="$RTERM_SESSION_SLUG""#,
                    cleanup: #"git worktree unlock ".claude/worktrees/$RTERM_SESSION_SLUG" 2>/dev/null; git worktree remove ".claude/worktrees/$RTERM_SESSION_SLUG" && git branch -d "worktree-$RTERM_SESSION_SLUG""#),
            ]),
        ]
        for agent in wrapperAgents {
            groups.append(Group(name: agent.name, presets: [
                HarnessPreset(id: agent.command, title: agent.command, launch: agent.command, cleanup: nil),
                HarnessPreset(
                    id: "\(agent.command)-worktree",
                    title: "\(agent.command) in a new worktree",
                    launch: worktreeLaunch(running: agent.command),
                    cleanup: worktreeCleanup),
            ]))
        }
        groups.append(Group(name: "Git worktree", presets: [
            HarnessPreset(
                id: "shell-worktree",
                title: "worktree + shell (with cleanup)",
                launch: worktreeLaunch(running: #""$SHELL""#),
                cleanup: worktreeCleanup),
        ]))
        return groups
    }()

    public static func preset(id: String) -> HarnessPreset? {
        groups.flatMap(\.presets).first { $0.id == id }
    }
}
