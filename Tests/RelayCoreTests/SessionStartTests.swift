import Foundation
import Testing
@testable import RelayCore

@Suite("per-session harness")
struct SessionStartTests {
    private func makeProject(launch: String? = "claude", shutdown: String? = "cleanup.sh") -> Project {
        Project(
            name: "P",
            workspace: WorkspaceRef(provider: .sshTmux, opaqueID: "box"),
            pathInput: "~/code",
            resolvedPath: "/home/u/code",
            launchCommand: launch,
            shutdownCommand: shutdown)
    }

    private func makeSession(cleanup: SessionCleanup?) -> RemoteSession {
        RemoteSession(
            id: SessionID(),
            projectID: ProjectID(),
            displayName: "s",
            createdAt: Date(),
            backendID: "rterm-0123456789abcdef",
            cleanup: cleanup)
    }

    @Test func projectDefaultUsesProjectCommands() {
        let resolved = SSHTmuxRuntimeProvider.resolveStart(.projectDefault, project: makeProject())
        #expect(resolved.launchCommand == "claude")
        #expect(resolved.cleanup == .projectDefault)
        // A project with no launch command still records "default" — the
        // session tracks the project's shutdown hook either way.
        let bare = SSHTmuxRuntimeProvider.resolveStart(.projectDefault, project: makeProject(launch: nil))
        #expect(bare.launchCommand == nil)
        #expect(bare.cleanup == .projectDefault)
    }

    @Test func shellDisablesCleanupExplicitly() {
        // The distinction that matters: a plain-shell session in a worktree
        // project must NOT run the project's worktree cleanup at archive.
        let resolved = SSHTmuxRuntimeProvider.resolveStart(.shell, project: makeProject())
        #expect(resolved.launchCommand == nil)
        #expect(resolved.cleanup == .disabled)
    }

    @Test func explicitCommandCarriesItsCleanup() {
        let resolved = SSHTmuxRuntimeProvider.resolveStart(
            .command(launch: "codex", cleanup: "git worktree remove x"),
            project: makeProject())
        #expect(resolved.launchCommand == "codex")
        #expect(resolved.cleanup == .command("git worktree remove x"))

        let noCleanup = SSHTmuxRuntimeProvider.resolveStart(
            .command(launch: "codex", cleanup: "   "),
            project: makeProject())
        #expect(noCleanup.cleanup == .disabled)

        let cleanupOnly = SSHTmuxRuntimeProvider.resolveStart(
            .command(launch: "", cleanup: "rm -rf .scratch"),
            project: makeProject())
        #expect(cleanupOnly.launchCommand == nil)
        #expect(cleanupOnly.cleanup == .command("rm -rf .scratch"))
    }

    @Test func archiveHonorsRecordedCleanup() {
        let project = makeProject(shutdown: "project-hook.sh")
        // Recorded at launch → wins over whatever the project says now.
        #expect(SSHTmuxRuntimeProvider.shutdownCommand(
            for: makeSession(cleanup: .command("undo-worktree")), project: project) == "undo-worktree")
        // Explicitly disabled → nothing runs even though the project has a hook.
        #expect(SSHTmuxRuntimeProvider.shutdownCommand(
            for: makeSession(cleanup: .disabled), project: project) == nil)
        // Default and pre-recording sessions defer to the project.
        #expect(SSHTmuxRuntimeProvider.shutdownCommand(
            for: makeSession(cleanup: .projectDefault), project: project) == "project-hook.sh")
        #expect(SSHTmuxRuntimeProvider.shutdownCommand(
            for: makeSession(cleanup: nil), project: project) == "project-hook.sh")
        #expect(SSHTmuxRuntimeProvider.shutdownCommand(
            for: makeSession(cleanup: nil), project: makeProject(shutdown: nil)) == nil)
    }

    @Test func legacySessionJSONStillDecodes() throws {
        // Tombstones persisted by builds that predate `cleanup` (and older
        // ones that predate `launchSlug`) must keep decoding.
        let json = """
        {"id":"11111111-2222-3333-4444-555555555555",
         "projectID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
         "displayName":"old session",
         "createdAt":700000000,
         "backendID":"rterm-0123456789abcdef"}
        """
        let session = try JSONDecoder().decode(RemoteSession.self, from: Data(json.utf8))
        #expect(session.launchSlug == nil)
        #expect(session.cleanup == nil)
        #expect(session.displayName == "old session")
    }
}
