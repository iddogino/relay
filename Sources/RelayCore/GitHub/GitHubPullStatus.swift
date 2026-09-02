import Foundation

/// Live status of a pull request as reported by the GitHub API: whether it
/// can merge, plus the CI checks on its head commit. Built by
/// `GitHubAPIClient`; consumed by the PR badge and its hover popover.
public struct PullRequestStatus: Sendable, Equatable {
    public enum PhaseState: Sendable, Equatable {
        case open, closed, merged
    }

    /// GitHub's mergeability verdict, folded down from `mergeable` +
    /// `mergeable_state`. `.blocked` (branch protections unmet — review
    /// required, etc.) deliberately does NOT make the indicator orange:
    /// with green CI and no conflicts that's the normal resting state of a
    /// PR awaiting review, so it stays green with the reason in the popover.
    public enum MergeState: Sendable, Equatable {
        /// `mergeable: null` — GitHub is still computing the merge.
        case computing
        case clean
        case blocked
        case conflicts
        case behind
        case draft
    }

    public enum Indicator: Sendable, Equatable {
        case inProgress
        case good
        case ciFailed
        case notMergeable
        case merged
        case closed
    }

    public var prState: PhaseState
    public var mergeState: MergeState
    /// Deduped union of check runs and legacy commit statuses, failures
    /// first. May be capped (see `totalCheckCount`).
    public var checks: [PRCheck]
    /// True check population; exceeds `checks.count` when pagination capped
    /// the listing.
    public var totalCheckCount: Int

    public init(
        prState: PhaseState,
        mergeState: MergeState,
        checks: [PRCheck],
        totalCheckCount: Int? = nil
    ) {
        self.prState = prState
        self.mergeState = mergeState
        self.checks = checks
        self.totalCheckCount = max(totalCheckCount ?? checks.count, checks.count)
    }

    /// The one dot the toolbar shows. Priority: a failed check is decisive
    /// (red) even while others still run; then anything pending (spinner);
    /// then can't-merge states (orange); else green.
    public var indicator: Indicator {
        switch prState {
        case .merged: return .merged
        case .closed: return .closed
        case .open: break
        }
        if checks.contains(where: { $0.outcome.isFailureLike }) { return .ciFailed }
        if checks.contains(where: { $0.outcome.isPendingLike }) || mergeState == .computing {
            return .inProgress
        }
        switch mergeState {
        case .conflicts, .behind, .draft: return .notMergeable
        case .clean, .blocked, .computing: return .good
        }
    }

    /// Popover title, GitHub-style.
    public var headline: String {
        switch indicator {
        case .merged: return "Pull request merged"
        case .closed: return "Pull request closed"
        case .ciFailed: return "Some checks were not successful"
        case .inProgress:
            return checks.contains(where: { $0.outcome.isPendingLike })
                ? "Some checks haven't completed yet"
                : "Determining mergeability…"
        case .notMergeable:
            switch mergeState {
            case .conflicts: return "This branch has conflicts"
            case .behind: return "This branch is out of date with the base"
            case .draft: return "This pull request is still a draft"
            default: return "This branch can't be merged yet"
            }
        case .good:
            if checks.isEmpty { return "No checks reported" }
            return "All checks have passed"
        }
    }

    /// Secondary line naming what stands between the PR and the merge
    /// button, when the headline doesn't already say it.
    public var mergeabilityNote: String? {
        guard prState == .open else { return nil }
        switch mergeState {
        case .blocked: return "Merging is blocked — review or other branch protections required."
        case .computing: return "GitHub is still computing mergeability."
        case .conflicts, .behind, .draft, .clean: return nil
        }
    }

    /// "1 failing, 2 in progress, and 11 successful checks" — nil when
    /// there are no checks at all.
    public var checkSummary: String? {
        guard !checks.isEmpty else { return nil }
        var parts: [String] = []
        let failing = checks.count { $0.outcome.isFailureLike }
        let pending = checks.count { $0.outcome.isPendingLike }
        let successful = checks.count { $0.outcome == .success }
        let skipped = checks.count - failing - pending - successful
        if failing > 0 { parts.append("\(failing) failing") }
        if pending > 0 { parts.append("\(pending) in progress") }
        if successful > 0 { parts.append("\(successful) successful") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        let joined: String
        switch parts.count {
        case 1: joined = parts[0]
        case 2: joined = "\(parts[0]) and \(parts[1])"
        default: joined = parts.dropLast().joined(separator: ", ") + ", and \(parts.last!)"
        }
        return joined + (checks.count == 1 ? " check" : " checks")
    }
}

/// One row of the checks list: a check run or a legacy commit status.
public struct PRCheck: Sendable, Equatable, Identifiable {
    public enum Outcome: Sendable, Equatable {
        case queued
        case inProgress
        case success
        case failure
        case cancelled
        case skipped
        case neutral

        /// Counts against the PR (red).
        public var isFailureLike: Bool {
            self == .failure || self == .cancelled
        }

        /// Still running (spinner).
        public var isPendingLike: Bool {
            self == .queued || self == .inProgress
        }
    }

    public var name: String
    public var outcome: Outcome
    /// Short status phrase for the row ("Successful in 2m 11s").
    public var detail: String
    /// When a still-running check started — lets the UI tick a live
    /// elapsed counter instead of a static "In progress…".
    public var startedAt: Date?
    public var detailsURL: URL?

    public var id: String { name }

    public init(
        name: String,
        outcome: Outcome,
        detail: String,
        startedAt: Date? = nil,
        detailsURL: URL? = nil
    ) {
        self.name = name
        self.outcome = outcome
        self.detail = detail
        self.startedAt = startedAt
        self.detailsURL = detailsURL
    }
}

extension GitHubRemote {
    /// (owner, repo, number) from a GitHub PR web URL
    /// (https://github.com/owner/repo/pull/N…), the inverse of
    /// `pullRequestURL`. API calls address the PR with these.
    public static func pullCoordinates(from url: URL) -> (owner: String, repo: String, number: Int)? {
        guard url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]), number > 0 else {
            return nil
        }
        return (parts[0], parts[1], number)
    }
}
