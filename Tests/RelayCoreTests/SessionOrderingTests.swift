import Foundation
import Testing
@testable import RelayCore

@Suite("session ordering")
struct SessionOrderingTests {
    private func session(_ name: String, id: SessionID, project: ProjectID) -> RemoteSession {
        RemoteSession(
            id: id, projectID: project, displayName: name,
            createdAt: Date(timeIntervalSince1970: 0), backendID: "rterm-\(name)")
    }

    @Test func appliesOverlayOrderWithinAProject() {
        let project = ProjectID()
        let (a, b, c) = (SessionID(), SessionID(), SessionID())
        let remote = [session("a", id: a, project: project),
                      session("b", id: b, project: project),
                      session("c", id: c, project: project)]

        let ordered = SessionOrdering.apply(order: [c, a, b], to: remote)
        #expect(ordered.map(\.displayName) == ["c", "a", "b"])
    }

    @Test func unknownSessionsKeepRemoteOrderAfterKnownOnes() {
        let project = ProjectID()
        let (a, b) = (SessionID(), SessionID())
        let (x, y) = (SessionID(), SessionID())
        // x and y were never reordered locally (adopted/external sessions).
        let remote = [session("x", id: x, project: project),
                      session("b", id: b, project: project),
                      session("y", id: y, project: project),
                      session("a", id: a, project: project)]

        let ordered = SessionOrdering.apply(order: [a, b], to: remote)
        #expect(ordered.map(\.displayName) == ["a", "b", "x", "y"])
    }

    @Test func emptyOrderIsPassthrough() {
        let project = ProjectID()
        let remote = [session("one", id: SessionID(), project: project),
                      session("two", id: SessionID(), project: project)]
        #expect(SessionOrdering.apply(order: [], to: remote) == remote)
    }

    @Test func globalOrderOnlyConstrainsWithinEachProject() {
        // The overlay is one global list; interleaved entries from another
        // project must not disturb this project's relative order.
        let mine = ProjectID()
        let theirs = ProjectID()
        let (a, b) = (SessionID(), SessionID())
        let (t1, t2) = (SessionID(), SessionID())
        let remote = [session("b", id: b, project: mine),
                      session("a", id: a, project: mine)]

        let ordered = SessionOrdering.apply(order: [t1, a, t2, b], to: remote)
        #expect(ordered.map(\.displayName) == ["a", "b"])
    }
}
