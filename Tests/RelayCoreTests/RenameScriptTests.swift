import Foundation
import Testing
@testable import RelayCore

@Suite("session rename script")
struct RenameScriptTests {
    @Test func renameTargetsPlainNameAndQuotedPayload() {
        let b64 = TmuxSessionCodec.encodeDisplayName("new name ✳")
        let script = SSHTmuxScripts.renameSession(
            tmuxName: "rterm-0123456789abcdef",
            displayNameB64: b64,
            fallbackSlug: "old-name",
            knownTmuxPath: nil)
        // set-option rejects the `=` exact-match prefix (same silent trap
        // as display-message) — the target must be the plain name.
        #expect(script.contains("set-option -t rterm-0123456789abcdef @rterm_session_name_b64"))
        #expect(!script.contains("set-option -t =rterm"))
        // has-session DOES take the exact-match prefix.
        #expect(script.contains("has-session -t =rterm-0123456789abcdef"))
        // The payload rides as base64 (quoted), never as raw user text.
        #expect(script.contains(b64))
        #expect(!script.contains("new name"))
        // Pre-slug sessions get their launch slug backfilled (if unset)
        // before the name changes, so worktree cleanup stays correct.
        #expect(script.contains("show-options -qv -t rterm-0123456789abcdef @rterm_slug"))
        #expect(script.contains("set-option -t rterm-0123456789abcdef @rterm_slug 'old-name'"))
    }
}
