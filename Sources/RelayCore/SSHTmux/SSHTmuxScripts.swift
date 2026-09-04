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
        static let git = "RTERM_GIT"
        static let gitBranch = "RTERM_GIT_BRANCH"
        static let gitBase = "RTERM_GIT_BASE"
        static let gitAdditions = "RTERM_GIT_ADD"
        static let gitDeletions = "RTERM_GIT_DEL"
        static let gitFiles = "RTERM_GIT_FILES"
        static let gitOrigin = "RTERM_GIT_ORIGIN"
        static let pullRequest = "RTERM_PR"
        /// Sentinel line separating markers from a raw diff body.
        static let diffBegin = "RTERM_DIFF_BEGIN"
        static let preview = "RTERM_PREVIEW"
        static let previewPath = "RTERM_PREVIEW_PATH"
        static let previewSize = "RTERM_PREVIEW_SIZE"
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

    // MARK: Directory autocomplete

    /// Row cap for directory listings (a node_modules-sized folder must not
    /// flood the wire).
    static let directoryListCap = 500

    /// Lists the child directories of `pathInput`, one `D<name>` line each
    /// (the prefix keeps entries unmistakable amid markers). A missing
    /// directory is a state, not an error — autocomplete just shows nothing.
    /// The trailing-slash glob matches directories and symlinks to them;
    /// dot entries ride along and the client decides when to show them.
    static func listChildDirectories(pathInput: String) -> String {
        let pathExpr = RemotePath.shellExpression(for: pathInput)
        return """
        set -u
        cd \(pathExpr) 2>/dev/null || { printf 'RTERM_STATUS=no_dir\\n'; exit 0; }
        printf 'RTERM_STATUS=ok\\n'
        for d in */ .*/; do
          case "$d" in './'|'../'|'*/'|'.*/') continue ;; esac
          printf 'D%s\\n' "${d%/}"
        done | head -n \(directoryListCap)
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
        //
        // TMUX/TMUX_PANE are scrubbed: Relay uses tmux purely as an invisible
        // persistence layer, and tools change behavior when they see $TMUX
        // (Claude Code statics its title spinner and clamps to 256 colors).
        // TERM_PROGRAM=tmux is deliberately KEPT so input-protocol and
        // hyperlink handling stay tmux-aware. COLORTERM advertises the
        // truecolor the ghostty side always provides (tmux downconverts if a
        // shared server lacks RGB).
        var paneCommand = ""
        if let launch = ctx.launchCommand, !launch.isEmpty {
            let inner = "unset TMUX TMUX_PANE; COLORTERM=truecolor; export COLORTERM; "
                + pathBolster
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
        # Native-terminal polish, server-scoped half. Only applied when every
        # session on the server is app-owned (or the server is fresh), so a
        # server shared with the user's own tmux sessions keeps their setup.
        # Values the user configured away from defaults are respected.
        "$tmux_path" start-server 2>/dev/null || true
        if ! "$tmux_path" list-sessions -F '#{session_name}' 2>/dev/null | grep -qv '^rterm-'; then
          [ "$("$tmux_path" show-option -gv history-limit 2>/dev/null)" = "2000" ] \\
            && "$tmux_path" set-option -g history-limit 50000 2>/dev/null || true
          [ "$("$tmux_path" show-option -sv escape-time 2>/dev/null)" = "500" ] \\
            && "$tmux_path" set-option -s escape-time 10 2>/dev/null || true
          "$tmux_path" set-option -s focus-events on 2>/dev/null || true
          "$tmux_path" set-option -sa terminal-features ',xterm-256color:RGB' 2>/dev/null || true
          # Keep attach clients out of the alternate screen so scrolled lines
          # land in the local terminal's native scrollback (and history can
          # be replayed into it on attach).
          case "$("$tmux_path" show-options -sv terminal-overrides 2>/dev/null)" in
            *smcup@*) ;;
            *) "$tmux_path" set-option -sa terminal-overrides ',xterm-256color:smcup@:rmcup@' 2>/dev/null || true ;;
          esac
        fi
        "$tmux_path" new-session -d -s \(ctx.tmuxName) -n \(POSIXShellQuote.quote(ctx.windowName)) -c "$rp"\(envFlags)\(paneCommand) || { printf 'RTERM_STATUS=create_failed\\n'; exit 23; }
        # Native-terminal polish, session-scoped half (never affects the
        # user's own sessions): no status strip, mouse left entirely to the
        # terminal (native selection and scrolling — tmux never intercepts),
        # passthrough sequences (image protocols etc.), and pane-title
        # forwarding so the app header can show what's running.
        "$tmux_path" set-option -t \(ctx.tmuxName) status off 2>/dev/null || true
        "$tmux_path" set-option -t \(ctx.tmuxName) mouse off 2>/dev/null || true
        "$tmux_path" set-option -t \(ctx.tmuxName) allow-passthrough on 2>/dev/null || true
        "$tmux_path" set-option -t \(ctx.tmuxName) set-titles on 2>/dev/null || true
        "$tmux_path" set-option -t \(ctx.tmuxName) set-titles-string '#T' 2>/dev/null || true
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

    // MARK: Rename

    /// Rewrites the session's display-name metadata
    /// (`@rterm_session_name_b64`). The tmux session name — the stable
    /// backend ID — never changes. Before the name changes, `@rterm_slug`
    /// is backfilled (if absent) with the slug of the CURRENT name, so a
    /// session created before slugs were recorded keeps a cleanup-correct
    /// slug across its first rename. NOTE: `set-option -t` rejects the `=`
    /// exact-match prefix (same silent trap as display-message), so the
    /// target is the plain name; `has-session` does take `=`.
    static func renameSession(
        tmuxName: String,
        displayNameB64: String,
        fallbackSlug: String,
        knownTmuxPath: String?
    ) -> String {
        precondition(TmuxNaming.isSafeSessionName(tmuxName))
        return """
        set -u
        \(tmuxPreamble(knownTmuxPath: knownTmuxPath))
        if ! "$tmux_path" has-session -t =\(tmuxName) 2>/dev/null; then
          printf 'RTERM_STATUS=not_found\\n'
          exit 24
        fi
        slug=$("$tmux_path" show-options -qv -t \(tmuxName) @rterm_slug 2>/dev/null) || slug=""
        if [ -z "$slug" ]; then
          if ! "$tmux_path" set-option -t \(tmuxName) @rterm_slug \(POSIXShellQuote.quote(fallbackSlug)); then
            printf 'RTERM_STATUS=rename_failed\\n'
            exit 25
          fi
        fi
        if ! "$tmux_path" set-option -t \(tmuxName) @rterm_session_name_b64 \(POSIXShellQuote.quote(displayNameB64)); then
          printf 'RTERM_STATUS=rename_failed\\n'
          exit 25
        fi
        printf 'RTERM_STATUS=ok\\n'
        """
    }

    // MARK: Git state

    /// Byte cap for diff bodies sent back over the wire; huge diffs arrive
    /// truncated (the UI says so) instead of stalling the connection.
    static let diffByteCap = 400_000

    /// Shared fragment: resolve the session pane's current directory into
    /// `$p` and its git comparison context into `$branch` / `$base` / `$mb`
    /// (merge-base with the default remote branch, falling back to plain
    /// HEAD). Prints `RTERM_GIT=none` and exits 0 when the pane isn't in a
    /// git work tree — not-a-repo is a state, not an error.
    ///
    /// NOTE: `display-message -t` silently rejects the `=` exact-match
    /// prefix, so the session name is targeted plain (generated names are
    /// fixed-length and cannot prefix-collide).
    private static func gitContextFragment(tmuxName: String) -> String {
        precondition(TmuxNaming.isSafeSessionName(tmuxName))
        return """
        p=$("$tmux_path" display-message -p -t \(tmuxName) -F '#{pane_current_path}' 2>/dev/null) || p=""
        [ -n "$p" ] && [ -d "$p" ] || { printf 'RTERM_GIT=none\\n'; exit 0; }
        command -v git >/dev/null 2>&1 || { printf 'RTERM_GIT=none\\n'; exit 0; }
        git -C "$p" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf 'RTERM_GIT=none\\n'; exit 0; }
        branch=$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=HEAD
        base=""
        for cand in "$(git -C "$p" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" origin/main origin/master; do
          [ -n "$cand" ] || continue
          if git -C "$p" rev-parse -q --verify "$cand^{commit}" >/dev/null 2>&1; then base="$cand"; break; fi
        done
        mb=""
        [ -n "$base" ] && mb=$(git -C "$p" merge-base HEAD "$base" 2>/dev/null) || mb=""
        [ -n "$mb" ] || { mb=HEAD; base=""; }
        """
    }

    /// Reports the session pane's git state: branch, comparison base,
    /// aggregate diff counts, origin URL — and, when the branch's pushed sha
    /// matches an advertised `refs/pull/N/head`, the PR number. The PR probe
    /// is pure git protocol using the remote host's own credentials; no
    /// tokens or API involvement.
    static func gitState(tmuxName: String, knownTmuxPath: String?) -> String {
        """
        set -u
        \(tmuxPreamble(knownTmuxPath: knownTmuxPath))
        \(gitContextFragment(tmuxName: tmuxName))
        printf 'RTERM_GIT=ok\\n'
        printf 'RTERM_GIT_BRANCH=%s\\n' "$branch"
        [ -n "$base" ] && printf 'RTERM_GIT_BASE=%s\\n' "$base"
        git -C "$p" diff --numstat "$mb" -- 2>/dev/null | awk '
          $1 ~ /^[0-9]+$/ { a += $1 }
          $2 ~ /^[0-9]+$/ { d += $2 }
          { f += 1 }
          END { printf "RTERM_GIT_ADD=%d\\nRTERM_GIT_DEL=%d\\nRTERM_GIT_FILES=%d\\n", a, d, f }
        '
        origin=$(git -C "$p" remote get-url origin 2>/dev/null) || origin=""
        [ -n "$origin" ] && printf 'RTERM_GIT_ORIGIN=%s\\n' "$origin"
        case "$origin" in
          *github.com*)
            refs=$(git -C "$p" ls-remote -q origin 'refs/pull/*/head' "refs/heads/$branch" 2>/dev/null) || refs=""
            if [ -n "$refs" ]; then
              sha=$(printf '%s\\n' "$refs" | awk -v r="refs/heads/$branch" '$2 == r { print $1; exit }')
              [ -n "$sha" ] || sha=$(git -C "$p" rev-parse HEAD 2>/dev/null) || sha=""
              if [ -n "$sha" ]; then
                pr=$(printf '%s\\n' "$refs" | awk -v s="$sha" '$1 == s && index($2, "refs/pull/") == 1 { split($2, parts, "/"); if (parts[4] == "head") { print parts[3]; exit } }')
                [ -n "$pr" ] && printf 'RTERM_PR=%s\\n' "$pr"
              fi
            fi
          ;;
        esac
        exit 0
        """
    }

    /// Emits the session pane's unified diff against the same base
    /// `gitState` uses: markers first, then the `RTERM_DIFF_BEGIN` sentinel,
    /// then the raw (uncolored) diff body, capped at `diffByteCap` bytes.
    static func gitDiff(tmuxName: String, knownTmuxPath: String?) -> String {
        """
        set -u
        \(tmuxPreamble(knownTmuxPath: knownTmuxPath))
        \(gitContextFragment(tmuxName: tmuxName))
        printf 'RTERM_GIT=ok\\n'
        printf 'RTERM_GIT_BRANCH=%s\\n' "$branch"
        [ -n "$base" ] && printf 'RTERM_GIT_BASE=%s\\n' "$base"
        printf 'RTERM_DIFF_BEGIN\\n'
        git -C "$p" diff --no-color --no-ext-diff "$mb" -- 2>/dev/null | head -c \(diffByteCap)
        exit 0
        """
    }

    // MARK: File preview

    /// Byte cap for files fetched for preview.
    static let previewByteCap = 209_715_200 // 200 MB

    /// Resolves a clicked file link against the session pane's context and
    /// reports whether it's fetchable: `~/` expands against $HOME, relative
    /// paths against the pane's current directory, and the result must be a
    /// readable regular file under the size cap. The link text is a single
    /// quoted value — it never executes.
    static func resolvePreviewFile(tmuxName: String, linkPath: String, knownTmuxPath: String?) -> String {
        precondition(TmuxNaming.isSafeSessionName(tmuxName))
        return """
        set -u
        \(tmuxPreamble(knownTmuxPath: knownTmuxPath))
        raw=\(POSIXShellQuote.quote(linkPath))
        case "$raw" in
          /*) f="$raw" ;;
          '~/'*) f="$HOME${raw#'~'}" ;;
          *)
            p=$("$tmux_path" display-message -p -t \(tmuxName) -F '#{pane_current_path}' 2>/dev/null) || p=""
            [ -n "$p" ] || { printf 'RTERM_PREVIEW=missing\\n'; exit 0; }
            f="$p/$raw"
            ;;
        esac
        if [ -d "$f" ]; then printf 'RTERM_PREVIEW=dir\\n'; exit 0; fi
        if [ ! -f "$f" ] || [ ! -r "$f" ]; then printf 'RTERM_PREVIEW=missing\\n'; exit 0; fi
        size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
        case "$size" in ''|*[!0-9]*) printf 'RTERM_PREVIEW=missing\\n'; exit 0 ;; esac
        if [ "$size" -gt \(previewByteCap) ]; then
          printf 'RTERM_PREVIEW=too_big\\n'
          printf 'RTERM_PREVIEW_SIZE=%s\\n' "$size"
          exit 0
        fi
        d=$(cd "$(dirname -- "$f")" 2>/dev/null && pwd -P) || { printf 'RTERM_PREVIEW=missing\\n'; exit 0; }
        b=$(basename -- "$f")
        printf 'RTERM_PREVIEW=ok\\n'
        printf 'RTERM_PREVIEW_PATH=%s\\n' "$d/$b"
        printf 'RTERM_PREVIEW_SIZE=%s\\n' "$size"
        exit 0
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
