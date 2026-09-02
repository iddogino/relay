import Foundation

/// Minimal GitHub REST client for the PR badge. Runs entirely on this Mac
/// with a bearer token (from the local `gh` CLI or our own device-flow
/// login) — nothing here touches the remote host or shells out.
public struct GitHubAPIClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public enum APIError: Error, Equatable {
        /// 401 — the token is invalid or revoked. Callers flip the app's
        /// auth state on this; other failures are transient.
        case unauthorized
        case http(Int)
        case invalidResponse
    }

    public var token: String
    private let transport: Transport

    public init(token: String, transport: Transport? = nil) {
        self.token = token
        self.transport = transport ?? { request in
            try await URLSession.shared.data(for: request)
        }
    }

    /// Validates the token and identifies the account (`GET /user`).
    public func viewerLogin() async throws -> String {
        struct User: Decodable { let login: String }
        let user: User = try await get("https://api.github.com/user")
        return user.login
    }

    /// Mergeability + checks for one PR: the pull itself, then check runs
    /// and legacy commit statuses for its head commit (many CI systems
    /// still report through the statuses API), fetched concurrently.
    public func pullStatus(owner: String, repo: String, number: Int) async throws -> PullRequestStatus {
        let allowed = CharacterSet.urlPathAllowed
        guard let safeOwner = owner.addingPercentEncoding(withAllowedCharacters: allowed),
              let safeRepo = repo.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw APIError.invalidResponse
        }
        let base = "https://api.github.com/repos/\(safeOwner)/\(safeRepo)"
        let pull: PullResponse = try await get("\(base)/pulls/\(number)")
        async let checkRuns: CheckRunsResponse =
            get("\(base)/commits/\(pull.head.sha)/check-runs?per_page=100")
        async let combined: CombinedStatusResponse =
            get("\(base)/commits/\(pull.head.sha)/status?per_page=100")
        return Self.status(pull: pull, checkRuns: try await checkRuns, combined: try await combined)
    }

    // MARK: Request plumbing

    private func get<T: Decodable>(_ urlString: String) async throws -> T {
        guard let url = URL(string: urlString) else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 15
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        do {
            return try Self.decoder().decode(T.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Response models (raw API shapes)

    struct PullResponse: Decodable {
        struct Head: Decodable { let sha: String }
        let state: String          // "open" | "closed"
        let merged: Bool
        let draft: Bool?
        let mergeable: Bool?       // null while GitHub computes the merge
        let mergeableState: String?
        let head: Head
    }

    struct CheckRunsResponse: Decodable {
        struct Run: Decodable {
            let name: String
            let status: String     // queued | in_progress | completed | waiting | requested | pending
            let conclusion: String?
            let startedAt: Date?
            let completedAt: Date?
            let htmlUrl: String?
        }
        let totalCount: Int
        let checkRuns: [Run]
    }

    struct CombinedStatusResponse: Decodable {
        struct Item: Decodable {
            let context: String
            let state: String      // pending | success | failure | error
            let createdAt: Date?
            let targetUrl: String?
        }
        // NOTE: with zero statuses this endpoint still reports
        // state="pending" — only the per-item states mean anything.
        let totalCount: Int
        let statuses: [Item]
    }

    // MARK: Mapping

    static func status(
        pull: PullResponse,
        checkRuns: CheckRunsResponse,
        combined: CombinedStatusResponse
    ) -> PullRequestStatus {
        let prState: PullRequestStatus.PhaseState =
            pull.merged ? .merged : (pull.state == "closed" ? .closed : .open)

        var checks: [PRCheck] = []
        var seen = Set<String>()
        var duplicates = 0
        for run in checkRuns.checkRuns {
            guard seen.insert(run.name).inserted else { duplicates += 1; continue }
            checks.append(check(from: run))
        }
        for item in combined.statuses {
            guard seen.insert(item.context).inserted else { duplicates += 1; continue }
            checks.append(check(from: item))
        }
        // Failures first, then running, then the rest — original order kept
        // within each band (matches how GitHub presents the list).
        let band: (PRCheck) -> Int = {
            if $0.outcome.isFailureLike { return 0 }
            if $0.outcome.isPendingLike { return 1 }
            return 2
        }
        let sorted = checks.enumerated()
            .sorted { (band($0.element), $0.offset) < (band($1.element), $1.offset) }
            .map(\.element)

        return PullRequestStatus(
            prState: prState,
            mergeState: mergeState(
                mergeable: pull.mergeable,
                state: pull.mergeableState,
                draft: pull.draft ?? false),
            checks: sorted,
            totalCheckCount: max(0, checkRuns.totalCount + combined.totalCount - duplicates))
    }

    static func mergeState(
        mergeable: Bool?,
        state: String?,
        draft: Bool
    ) -> PullRequestStatus.MergeState {
        if draft || state == "draft" { return .draft }
        if mergeable == false { return .conflicts }
        switch state {
        case "dirty": return .conflicts
        case "behind": return .behind
        case "blocked": return .blocked
        case "clean", "has_hooks", "unstable": return .clean
        default: return mergeable == true ? .clean : .computing
        }
    }

    private static func check(from run: CheckRunsResponse.Run) -> PRCheck {
        let outcome: PRCheck.Outcome
        var detail: String
        if run.status == "completed" {
            switch run.conclusion {
            case "success":
                outcome = .success
                detail = "Successful"
            case "neutral", "stale":
                outcome = .neutral
                detail = "Neutral"
            case "skipped":
                outcome = .skipped
                detail = "Skipped"
            case "cancelled":
                outcome = .cancelled
                detail = "Cancelled"
            default: // failure | timed_out | action_required | nil
                outcome = .failure
                detail = run.conclusion == "timed_out" ? "Timed out" : "Failing"
            }
            if let started = run.startedAt, let completed = run.completedAt,
               completed > started, outcome == .success || outcome == .failure {
                let span = durationText(completed.timeIntervalSince(started))
                detail = outcome == .success ? "Successful in \(span)" : "Failing after \(span)"
            }
        } else if run.status == "in_progress" {
            outcome = .inProgress
            detail = "In progress"
        } else { // queued | waiting | requested | pending
            outcome = .queued
            detail = "Queued"
        }
        return PRCheck(
            name: run.name,
            outcome: outcome,
            detail: detail,
            startedAt: outcome == .inProgress ? run.startedAt : nil,
            detailsURL: run.htmlUrl.flatMap(URL.init(string:)))
    }

    private static func check(from item: CombinedStatusResponse.Item) -> PRCheck {
        let outcome: PRCheck.Outcome
        let detail: String
        switch item.state {
        case "success":
            outcome = .success
            detail = "Successful"
        case "pending":
            outcome = .inProgress
            detail = "In progress"
        default: // failure | error
            outcome = .failure
            detail = item.state == "error" ? "Errored" : "Failing"
        }
        return PRCheck(
            name: item.context,
            outcome: outcome,
            detail: detail,
            startedAt: outcome == .inProgress ? item.createdAt : nil,
            detailsURL: item.targetUrl.flatMap(URL.init(string:)))
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }
}
