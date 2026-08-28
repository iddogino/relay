import Foundation

/// Builders for the POSIX management scripts the SSH+tmux provider sends to a
/// remote `/bin/sh -s`. Pure string construction — unit-testable without SSH.
///
/// Every dynamic value is either POSIX-quoted or validated-safe ASCII.
enum SSHTmuxScripts {
    /// Marker keys emitted by scripts.
    enum Marker {
        static let status = "RTERM_STATUS"
        static let tmuxPath = "RTERM_TMUX"
        static let tmuxVersion = "RTERM_TMUX_VERSION"
        static let resolvedPath = "RTERM_PWD"
        static let exists = "RTERM_EXISTS"
    }

    /// Shell fragment that resolves a usable tmux binary into `$tmux_path`,
    /// covering login-manager PATHs that non-interactive SSH doesn't get
    /// (Homebrew, MacPorts, local installs).
    private static let resolveTmuxFragment = """
    find_tmux() {
      if command -v tmux >/dev/null 2>&1; then command -v tmux; return 0; fi
      for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux /opt/local/bin/tmux /usr/pkg/bin/tmux "$HOME/.local/bin/tmux" "$HOME/bin/tmux"; do
        if [ -x "$p" ]; then printf '%s\\n' "$p"; return 0; fi
      done
      return 1
    }
    tmux_path=$(find_tmux) || { printf 'RTERM_STATUS=no_tmux\\n'; exit 21; }
    """

    /// Prefers a previously validated tmux path, falling back to discovery.
    private static func tmuxPreamble(knownTmuxPath: String?) -> String {
        guard let known = knownTmuxPath, !known.isEmpty else { return resolveTmuxFragment }
        return """
        tmux_path=\(POSIXShellQuote.quote(known))
        if [ ! -x "$tmux_path" ]; then
        \(resolveTmuxFragment)
        fi
        """
    }

    // MARK: Validation

    static func validate(pathInput: String) -> String {
        let pathExpr = RemotePath.shellExpression(for: pathInput)
        return """
        set -u
        \(resolveTmuxFragment)
        tmux_version=$("$tmux_path" -V 2>/dev/null || printf 'unknown')
        cd \(pathExpr) 2>/dev/null || { printf 'RTERM_STATUS=no_dir\\n'; exit 22; }
        printf 'RTERM_STATUS=ok\\n'
        printf 'RTERM_TMUX=%s\\n' "$tmux_path"
        printf 'RTERM_TMUX_VERSION=%s\\n' "$tmux_version"
        printf 'RTERM_PWD=%s\\n' "$(pwd -P)"
        """
    }

    // MARK: Session creation

    /// Shell fragment prepending well-known user bin dirs to PATH (see the
    /// launch-command note in `createSession`).
    private static let pathBolster =
        "PATH=\"$HOME/.local/bin:$HOME/bin:$PATH\"; export PATH; "

    struct CreateContext {
        let tmuxName: String
        /// Human-readable tmux window name (the status-bar label); slug-safe.
        let windowName: String
        let pathInput: String
        let knownTmuxPath: String?
        let launchCommand: String?
        /// KEY=value environment exposed to the session (values raw, unquoted).
        let environment: [(String, String)]
        /// `@option` → value tmux user options to set.
        let metadata: [(String, String)]
    }

    static func createSession(_ ctx: CreateContext) -> String {
        precondition(TmuxNaming.isSafeSessionName(ctx.tmuxName))
        let pathExpr = RemotePath.shellExpression(for: ctx.pathInput)

        var envFlags = ""
        for (key, value) in ctx.environment {
            precondition(key.hasPrefix("RTERM_") && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
            envFlags += " -e \(POSIXShellQuote.quote("\(key)=\(value)"))"
        }
        // The resolved project path is computed remotely, so it is appended
        // at runtime from `$rp` rather than quoted locally.
        envFlags += " -e \"RTERM_PROJECT_PATH=$rp\""

        // If a launch command is configured, the pane runs it via the user's
        // login INTERACTIVE shell (`-l -i`): the pane has a real tty, and
        // interactive mode reads .zshrc/.bashrc so the command sees exactly
        // the environment the user gets when typing it — aliases, version
        // managers, PATH exports and all. (Standard per-user bin dirs are
        // still prepended as a safety net for rc files that guard on
        // interactivity oddly.) tmux runs this single argument via sh -c.
        var paneCommand = ""
        if let launch = ctx.launchCommand, !launch.isEmpty {
            let inner = pathBolster
                + "exec \"${SHELL:-/bin/sh}\" -l -i -c \(POSIXShellQuote.quote(launch))"
            paneCommand = " \(POSIXShellQuote.quote(inner))"
        }

        var setOptions = ""
        for (key, value) in ctx.metadata {
            precondition(key.hasPrefix("@") && key.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
            // NOTE: set-option rejects the `=` exact-match prefix (unlike
            // has-session/kill-session); the generated name is unique and
            // fixed-length so a plain-name target cannot prefix-collide.
            setOptions += "\"$tmux_path\" set-option -t \(ctx.tmuxName) \(key) \(POSIXShellQuote.quote(value)) || meta_fail=1\n"
        }

        // A failed launch command keeps its dead pane (and the error it
        // printed) visible instead of silently vanishing; clean exits still
        // end the session normally. Best-effort: option value needs tmux 3.2+.
        var remainOnExit = ""
        if ctx.launchCommand?.isEmpty == false {
            remainOnExit = "\"$tmux_path\" set-option -w -t \(ctx.tmuxName) remain-on-exit failed 2>/dev/null || true\n"
        }

        return """
        set -u
        \(tmuxPreamble(knownTmuxPath: ctx.knownTmuxPath))
        cd \(pathExpr) 2>/dev/null || { printf 'RTERM_STATUS=no_dir\\n'; exit 22; }
        rp=$(pwd -P)
        "$tmux_path" new-session -d -s \(ctx.tmuxName) -n \(POSIXShellQuote.quote(ctx.windowName)) -c "$rp"\(envFlags)\(paneCommand) || { printf 'RTERM_STATUS=create_failed\\n'; exit 23; }
        \(remainOnExit)meta_fail=0
        \(setOptions)if [ "$meta_fail" -ne 0 ]; then
          "$tmux_path" kill-session -t =\(ctx.tmuxName) 2>/dev/null
          printf 'RTERM_STATUS=meta_failed\\n'
          exit 24
        fi
        printf 'RTERM_STATUS=ok\\n'
        """
    }

    // MARK: Discovery

    static func listSessions(knownTmuxPath: String?) -> String {
        """
        set -u
        \(tmuxPreamble(knownTmuxPath: knownTmuxPath))
        printf 'RTERM_STATUS=ok\\n'
        "$tmux_path" list-sessions -F \(POSIXShellQuote.quote(TmuxSessionCodec.listFormat)) 2>/dev/null || true
        """
    }

    static func sessionExists(tmuxName: String, knownTmuxPath: String?) -> String {
        precondition(TmuxNaming.isSafeSessionName(tmuxName))
        return """
        set -u
        \(tmuxPreamble(knownTmuxPath: knownTmuxPath))
        if "$tmux_path" has-session -t =\(tmuxName) 2>/dev/null; then
          printf 'RTERM_EXISTS=1\\n'
        else
          printf 'RTERM_EXISTS=0\\n'
        fi
        """
    }

    // MARK: Termination

    /// Kills exactly one app-owned session. Succeeds if it is already gone.
    static func killSession(tmuxName: String, knownTmuxPath: String?) -> String {
        precondition(TmuxNaming.isSafeSessionName(tmuxName))
        return """
        set -u
        \(tmuxPreamble(knownTmuxPath: knownTmuxPath))
        "$tmux_path" kill-session -t =\(tmuxName) 2>/dev/null || true
        if "$tmux_path" has-session -t =\(tmuxName) 2>/dev/null; then
          printf 'RTERM_STATUS=kill_failed\\n'
          exit 25
        fi
        printf 'RTERM_STATUS=ok\\n'
        """
    }

    // MARK: Shutdown hook

    struct ShutdownContext {
        let pathInput: String
        let shutdownCommand: String
        /// KEY=value environment exposed to the hook (values raw, unquoted).
        let environment: [(String, String)]
    }

    /// Runs the project's shutdown command from the project base path with the
    /// session context exported, using the user's login shell.
    static func shutdownHook(_ ctx: ShutdownContext) -> String {
        let pathExpr = RemotePath.shellExpression(for: ctx.pathInput)
        var exports = ""
        for (key, value) in ctx.environment {
            precondition(key.hasPrefix("RTERM_") && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
            exports += "\(key)=\(POSIXShellQuote.quote(value)); export \(key)\n"
        }
        return """
        set -u
        cd \(pathExpr) 2>/dev/null || { printf 'RTERM_STATUS=no_dir\\n'; exit 22; }
        \(exports)\(pathBolster)exec "${SHELL:-/bin/sh}" -l -c \(POSIXShellQuote.quote(ctx.shutdownCommand))
        """
    }
}
