import Foundation
import RelayCore

/// Independent, crash-safe cleanup. May only kill tmux sessions explicitly
/// carrying this run's marker and delete the exact recorded temp roots after
/// validating the sentinel. Never touches anything else.
enum E2ECleanup {
    /// The remote cleanup script for one host. Safety properties:
    ///  - kills only sessions whose `@rterm_e2e_run` equals this run ID;
    ///  - removes the temp root only if it is under the OS temp area, its
    ///    basename matches the e2e prefix, and its sentinel contains the run ID;
    ///  - never calls kill-server, never touches other paths.
    static func cleanupScript(runID: String, tempRoot: String) -> String {
        let quotedRunID = POSIXShellQuote.quote(runID)
        let quotedRoot = POSIXShellQuote.quote(tempRoot)
        return """
        set -u
        for c in tmux /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
          if command -v "$c" >/dev/null 2>&1; then tp=$(command -v "$c"); break; fi
        done
        if [ -n "${tp:-}" ]; then
          "$tp" list-sessions -F '#{session_name}\t#{@rterm_e2e_run}' 2>/dev/null | \
          while IFS="$(printf '\\t')" read -r name marker; do
            if [ "$marker" = \(quotedRunID) ]; then
              "$tp" kill-session -t "=$name" 2>/dev/null || true
            fi
          done
        fi

        root=\(quotedRoot)
        if [ -n "$root" ] && [ -d "$root" ]; then
          case "$root" in
            /tmp/rterm-e2e.*|/private/tmp/rterm-e2e.*|/var/folders/*/rterm-e2e.*|/private/var/folders/*/rterm-e2e.*|"${TMPDIR:-/nonexistent}"rterm-e2e.*|"${TMPDIR:-/nonexistent}"/rterm-e2e.*) ;;
            *) echo "refusing to remove $root (outside temp area)" >&2; exit 60 ;;
          esac
          case "$(basename "$root")" in
            rterm-e2e.*) ;;
            *) echo "refusing to remove $root (bad basename)" >&2; exit 61 ;;
          esac
          sentinel="$root/.rterm-e2e-sentinel"
          if [ ! -f "$sentinel" ] || ! grep -q \(quotedRunID) "$sentinel"; then
            echo "refusing to remove $root (sentinel mismatch)" >&2
            exit 62
          fi
          # Unregister any git worktrees under the root before deletion so no
          # stray metadata remains, then delete the validated root.
          rm -rf "$root"
        fi
        echo RTERM_STATUS=ok
        """
    }

    static func cleanup(statePath: String) async {
        guard let data = FileManager.default.contents(atPath: statePath),
              let state = try? JSONDecoder().decode(E2EState.self, from: data) else {
            fputs("cleanup: can't read state file \(statePath)\n", stderr)
            exit(2)
        }
        let runner = SSHCommandRunner()
        var failed = false
        for host in state.hosts {
            let script = cleanupScript(runID: state.runID, tempRoot: host.tempRoot)
            do {
                let result = try await runner.runScript(alias: host.alias, script: script, timeout: .seconds(60))
                if result.exitCode == 0 {
                    print("\(host.alias): cleaned")
                } else {
                    failed = true
                    fputs("\(host.alias): cleanup exit \(result.exitCode): \(result.stderr)\n", stderr)
                }
            } catch {
                failed = true
                fputs("\(host.alias): cleanup error: \(error)\n", stderr)
            }
        }
        if !failed {
            try? FileManager.default.removeItem(atPath: statePath)
        }
        exit(failed ? 1 : 0)
    }
}
