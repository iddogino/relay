import Foundation
import Testing
@testable import RelayCore

@Suite("agent alerts")
struct AgentAlertTests {
    private func activity(_ state: AgentActivityState, _ epoch: TimeInterval, _ agent: CodingAgent = .claude) -> AgentActivity {
        AgentActivity(agent: agent, state: state, since: Date(timeIntervalSince1970: epoch))
    }

    @Test func statesShowingAtStartStayQuiet() {
        var tracker = AgentAlertTracker()
        #expect(tracker.observe(["a": activity(.done, 1), "b": activity(.blocked, 1), "c": nil]).isEmpty)
        #expect(tracker.observe(["a": activity(.done, 1), "b": activity(.blocked, 1), "c": nil]).isEmpty)
    }

    @Test func eachNewTurnEndOrQuestionAlertsOnce() {
        var tracker = AgentAlertTracker()
        _ = tracker.observe(["a": activity(.idle, 1)])
        #expect(tracker.observe(["a": activity(.working, 2)]).isEmpty)
        #expect(tracker.observe(["a": activity(.blocked, 3)]) == ["a": AgentAlert(kind: .needsInput, agent: .claude)])
        #expect(tracker.observe(["a": activity(.blocked, 3)]).isEmpty)
        #expect(tracker.observe(["a": activity(.working, 4)]).isEmpty)
        #expect(tracker.observe(["a": activity(.done, 5)]) == ["a": AgentAlert(kind: .finished, agent: .claude)])
        // A quick turn whose "working" fell between two polls.
        #expect(tracker.observe(["a": activity(.done, 9)]) == ["a": AgentAlert(kind: .finished, agent: .claude)])
        #expect(tracker.observe(["a": activity(.failed, 12, .claude)]) == ["a": AgentAlert(kind: .failed, agent: .claude)])
    }

    @Test func aReportThatFlickersAwayAndBackDoesNotRealert() {
        var tracker = AgentAlertTracker()
        _ = tracker.observe(["a": activity(.working, 1, .codex)])
        #expect(tracker.observe(["a": activity(.done, 2, .codex)]) == ["a": AgentAlert(kind: .finished, agent: .codex)])
        #expect(tracker.observe(["a": nil]).isEmpty)
        #expect(tracker.observe(["a": activity(.done, 2, .codex)]).isEmpty)
        // Present at the first sighting, gone, then back: still quiet.
        _ = tracker.observe(["a": activity(.done, 2, .codex), "b": activity(.blocked, 7)])
        #expect(tracker.observe(["a": activity(.done, 2, .codex), "b": nil]).isEmpty)
        #expect(tracker.observe(["a": activity(.done, 2, .codex), "b": activity(.blocked, 7)]).isEmpty)
    }

    @Test func aSessionThatLeavesAndReturnsPrimesAgain() {
        var tracker = AgentAlertTracker()
        _ = tracker.observe(["a": activity(.working, 1)])
        #expect(tracker.observe([:]).isEmpty)
        #expect(tracker.observe(["a": activity(.done, 2)]).isEmpty)
        #expect(tracker.observe(["a": activity(.done, 3)]) == ["a": AgentAlert(kind: .finished, agent: .claude)])
    }

    @Test func titlesNameTheAgent() {
        #expect(AgentAlert(kind: .needsInput, agent: .claude).title == "Claude Code needs you")
        #expect(AgentAlert(kind: .finished, agent: .codex).title == "Codex finished")
        #expect(AgentAlert(kind: .failed, agent: .claude).title == "Claude Code's turn failed")
    }

    @Test func theTaskComesFromClaudeCodesPaneTitle() {
        func report(_ title: String, _ agent: CodingAgent = .claude) -> AgentStatusReport {
            AgentStatusReport(backendID: "rterm-a", activity: activity(.done, 1, agent),
                              foregroundCommand: "claude", paneTitle: title)
        }
        #expect(report("✳ Fix the flaky test").agentTaskTitle == "Fix the flaky test")
        #expect(report("⠂ Fix the flaky test").agentTaskTitle == "Fix the flaky test")
        #expect(report("◐ Refactor").agentTaskTitle == "Refactor")
        #expect(report("✳ Claude Code").agentTaskTitle == nil)
        #expect(report("✳ ").agentTaskTitle == nil)
        #expect(report("host.local").agentTaskTitle == nil)
        #expect(report("✳ Task", .codex).agentTaskTitle == nil)
    }
}
