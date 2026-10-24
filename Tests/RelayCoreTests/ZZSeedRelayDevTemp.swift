import Foundation
import Testing
@testable import RelayCore

// TEMPORARY (not committed): seeds a Relay Dev test session.
@Suite struct ZZSeedRelayDevTemp {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_DEV_SEED_PROJECT"] != nil))
    func seed() async throws {
        let projectID = UUID(uuidString: ProcessInfo.processInfo.environment["RELAY_DEV_SEED_PROJECT"]!)!
        let provider = SSHTmuxRuntimeProvider()
        var project = Project(id: ProjectID(uuid: projectID), name: "Built-in terminal test",
                              workspace: WorkspaceRef(provider: .sshTmux, opaqueID: "iddos-mac-mini"),
                              pathInput: "/tmp/relay-dev-terminal-test", resolvedPath: "")
        let validation = try await provider.validate(project: project)
        project.resolvedPath = validation.resolvedPath
        project.runtimeMetadata = validation.runtimeMetadata
        let session = try await provider.createSession(for: project, request: NewSessionRequest(displayName: "builtin-terminal-test"))
        print("SEED session=\(session.id.uuid.uuidString) backend=\(session.backendID) resolved=\(project.resolvedPath) meta=\(project.runtimeMetadata)")
    }
}
