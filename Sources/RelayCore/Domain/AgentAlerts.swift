import Foundation

/// Something an agent's hooks reported that the user should hear about
/// even while looking elsewhere: it needs them, or its turn ended.
public struct AgentAlert: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case needsInput
        case finished
        case failed
    }

    public var kind: Kind
    public var agent: CodingAgent

    public init(kind: Kind, agent: CodingAgent) {
        self.kind = kind
        self.agent = agent
    }

    public var title: String {
        switch kind {
        case .needsInput: return "\(agent.displayName) needs you"
        case .finished: return "\(agent.displayName) finished"
        case .failed: return "\(agent.displayName)'s turn failed"
        }
    }
}

/// Decides alerts from one machine's successive status reports, keyed by
/// session (backend ID). Each new "blocked", "done" or "failed" report
/// alerts once. A session's first report only primes the tracker, so
/// states already showing when the app launches (or a machine's stream
/// starts) stay quiet, and a report that flickers away and back (the
/// pane briefly at a shell, a stale stream) never alerts twice.
public struct AgentAlertTracker: Sendable {
    private var last: [String: AgentActivity] = [:]
    private var known: Set<String> = []
    private var alerted: [String: AgentActivity] = [:]

    public init() {}

    /// Feeds one snapshot (backend ID → effective activity, nil when no
    /// agent is reporting) and returns the alerts it raises. Sessions
    /// missing from the snapshot are forgotten.
    public mutating func observe(_ snapshot: [String: AgentActivity?]) -> [String: AgentAlert] {
        var alerts: [String: AgentAlert] = [:]
        for (key, activity) in snapshot {
            if let alert = observe(activity, for: key) { alerts[key] = alert }
        }
        for key in known.subtracting(snapshot.keys) {
            known.remove(key)
            last[key] = nil
            alerted[key] = nil
        }
        return alerts
    }

    private mutating func observe(_ activity: AgentActivity?, for key: String) -> AgentAlert? {
        let firstSighting = known.insert(key).inserted
        let previous = last[key]
        last[key] = activity
        guard !firstSighting, let activity, activity != previous, activity != alerted[key] else {
            if firstSighting, let activity { alerted[key] = activity }
            return nil
        }
        let kind: AgentAlert.Kind
        switch activity.state {
        case .blocked: kind = .needsInput
        case .done: kind = .finished
        case .failed: kind = .failed
        case .idle, .working, .compacting: return nil
        }
        alerted[key] = activity
        return AgentAlert(kind: kind, agent: activity.agent)
    }
}

extension AgentStatusReport {
    /// What the pane title says the agent is on, for an alert's body:
    /// Claude Code titles its pane "✳ <task>" (a spinner frame while
    /// working). nil for other agents and plain titles.
    public var agentTaskTitle: String? {
        guard activity?.agent == .claude, let first = paneTitle.unicodeScalars.first,
              first.value == 0x2733 || (0x2800...0x28FF).contains(first.value)
                || (0x25D0...0x25D3).contains(first.value)
        else { return nil }
        let task = String(paneTitle.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
        return task.isEmpty || task == "Claude Code" ? nil : task
    }
}
