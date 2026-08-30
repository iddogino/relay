import Foundation
import Testing
@testable import RelayCore

@Suite("persistence")
struct PersistenceTests {
    private func tempStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-store-\(UUID().uuidString)/state.json")
    }

    @Test func saveAndLoadRoundTrip() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ProjectStore(fileURL: url)

        let project = Project(
            name: "My iOS App",
            workspace: WorkspaceRef(provider: .sshTmux, opaqueID: "macmini"),
            pathInput: "~/code/my-ios-app",
            resolvedPath: "/Users/me/code/my-ios-app",
            launchCommand: "claude",
            runtimeMetadata: ["tmuxPath": "/opt/homebrew/bin/tmux"]
        )
        var state = PersistedState(projects: [project])
        state.lastSelectedSessionID = SessionID()
        state.sessionOrder = [SessionID(), SessionID()]
        try await store.save(state)

        let loaded = try await store.load()
        #expect(loaded.projects == [project])
        #expect(loaded.lastSelectedSessionID == state.lastSelectedSessionID)
        #expect(loaded.sessionOrder == state.sessionOrder)
    }

    @Test func missingFileLoadsEmpty() async throws {
        let store = ProjectStore(fileURL: tempStoreURL())
        let state = try await store.load()
        #expect(state.projects.isEmpty)
    }

    @Test func corruptFileFailsRecoverablyWithBackup() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ not json !!".write(to: url, atomically: true, encoding: .utf8)

        let store = ProjectStore(fileURL: url)
        await #expect(throws: ProjectStoreError.self) {
            _ = try await store.load()
        }
        // Original moved aside; a subsequent load starts fresh.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let fresh = try await store.load()
        #expect(fresh.projects.isEmpty)
    }

    @Test func hiddenWorkspacesRoundTripAndOldStateFilesLoad() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ProjectStore(fileURL: url)

        // Round trip with hidden workspaces.
        let hidden = WorkspaceRef(provider: .sshTmux, opaqueID: "github.com")
        try await store.save(PersistedState(hiddenWorkspaces: [hidden]))
        #expect(try await store.load().hiddenWorkspaces == [hidden])

        // A state file from an older build (no hiddenWorkspaces key, and
        // missing other optional keys) must load, not trip corrupt-state.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"projects": [], "tombstones": []}"#.write(to: url, atomically: true, encoding: .utf8)
        let migrated = try await store.load()
        #expect(migrated.hiddenWorkspaces.isEmpty)
        #expect(migrated.projects.isEmpty)
    }

    @Test func projectsWithMissingAliasSurvive() async throws {
        // Persistence must not drop projects whose SSH alias disappeared.
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ProjectStore(fileURL: url)
        let orphan = Project(
            name: "Orphaned",
            workspace: WorkspaceRef(provider: .sshTmux, opaqueID: "gone-host"),
            pathInput: "~/x",
            resolvedPath: "/home/u/x"
        )
        try await store.save(PersistedState(projects: [orphan]))
        let loaded = try await store.load()
        #expect(loaded.projects.first?.workspace.opaqueID == "gone-host")
    }
}

/// A fully in-memory provider proving the domain layer (and anything built on
/// it) runs with zero SSH/tmux knowledge. Also exercised by view-model logic.
actor FakeRuntimeState {
    var sessions: [ProjectID: [RemoteSession]] = [:]
    var archived: [SessionID] = []
    var destroyed: [SessionID] = []
    var shutdownHookRuns = 0

    func create(_ session: RemoteSession) {
        sessions[session.projectID, default: []].append(session)
    }

    func remove(_ session: RemoteSession) {
        sessions[session.projectID]?.removeAll { $0.id == session.id }
    }
}

struct FakeRuntimeProvider: RuntimeProvider {
    let id = ProviderID(rawValue: "fake")
    let capabilities: RuntimeCapabilities = [.persistentSessions, .staticWorkspaces]
    let state = FakeRuntimeState()

    func discoverWorkspaces() async throws -> [WorkspaceDescriptor] {
        [WorkspaceDescriptor(
            id: WorkspaceRef(provider: id, opaqueID: "fake-box"),
            displayName: "fake-box",
            providerID: id
        )]
    }

    func validate(project: Project) async throws -> ProjectValidation {
        ProjectValidation(resolvedPath: "/resolved" + project.pathInput.replacingOccurrences(of: "~", with: "/home/fake"))
    }

    func listSessions(for project: Project) async throws -> [RemoteSession] {
        await state.sessions[project.id] ?? []
    }

    func createSession(for project: Project, request: NewSessionRequest) async throws -> RemoteSession {
        let session = RemoteSession(
            id: SessionID(),
            projectID: project.id,
            displayName: request.displayName,
            createdAt: Date(),
            backendID: "fake-\(UUID().uuidString)"
        )
        await state.create(session)
        return session
    }

    func makeTerminalLaunch(for session: RemoteSession, project: Project) async throws -> TerminalLaunchSpec {
        TerminalLaunchSpec(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:])
    }

    func sessionExists(_ session: RemoteSession, project: Project) async throws -> Bool {
        await state.sessions[project.id]?.contains { $0.id == session.id } ?? false
    }

    func archiveSession(_ session: RemoteSession, project: Project) async throws {
        await state.remove(session)
        await MainActor.run {} // no-op hop, mirrors async hook execution
    }

    func destroySession(_ session: RemoteSession, project: Project) async throws {
        await state.remove(session)
    }
}

@Suite("runtime abstraction")
struct RuntimeAbstractionTests {
    @Test func fullLifecycleThroughProtocolOnly() async throws {
        // Everything below goes through `any RuntimeProvider` — the same
        // surface the UI uses — proving no SSH/tmux types leak upward.
        let provider: any RuntimeProvider = FakeRuntimeProvider()

        let workspaces = try await provider.discoverWorkspaces()
        let workspace = try #require(workspaces.first)

        var project = Project(
            name: "P",
            workspace: workspace.id,
            pathInput: "~/code",
            resolvedPath: ""
        )
        let validation = try await provider.validate(project: project)
        project.resolvedPath = validation.resolvedPath

        let session = try await provider.createSession(
            for: project,
            request: NewSessionRequest(displayName: "work")
        )
        #expect(try await provider.listSessions(for: project).map(\.id) == [session.id])
        #expect(try await provider.sessionExists(session, project: project))

        let launch = try await provider.makeTerminalLaunch(for: session, project: project)
        #expect(launch.executable.path.hasPrefix("/"))

        try await provider.archiveSession(session, project: project)
        #expect(try await provider.listSessions(for: project).isEmpty)
    }

    @Test func sessionNameValidation() {
        if case .success = SessionNameValidator.validate("   ") {
            Issue.record("blank names must fail")
        }
        if case .success = SessionNameValidator.validate("bad\nname") {
            Issue.record("newlines must fail")
        }
        if case .success = SessionNameValidator.validate(String(repeating: "x", count: 101)) {
            Issue.record("over-long names must fail")
        }
        if case .failure = SessionNameValidator.validate("  fix auth flow 日本語 🚀  ") {
            Issue.record("unicode names must pass")
        }
        #expect(try! SessionNameValidator.validate("  padded  ").get() == "padded")
    }
}
