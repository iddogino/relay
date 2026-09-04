import Foundation
import Testing
@testable import RelayCore

@Suite("github PR coordinates")
struct PullCoordinatesTests {
    @Test func parsesPullURLs() throws {
        let coords = try #require(
            GitHubRemote.pullCoordinates(from: URL(string: "https://github.com/iddogino/relay/pull/42")!))
        #expect(coords.owner == "iddogino")
        #expect(coords.repo == "relay")
        #expect(coords.number == 42)
        // Sub-pages of the PR still identify it.
        let files = try #require(
            GitHubRemote.pullCoordinates(from: URL(string: "https://github.com/o/r/pull/7/files")!))
        #expect(files.number == 7)
    }

    @Test func rejectsNonPullURLs() {
        #expect(GitHubRemote.pullCoordinates(from: URL(string: "https://github.com/o/r/issues/7")!) == nil)
        #expect(GitHubRemote.pullCoordinates(from: URL(string: "https://gitlab.com/o/r/pull/7")!) == nil)
        #expect(GitHubRemote.pullCoordinates(from: URL(string: "https://github.com/o/r/pull/zero")!) == nil)
        #expect(GitHubRemote.pullCoordinates(from: URL(string: "https://github.com/o/r")!) == nil)
    }
}

@Suite("github PR status mapping")
struct PullStatusMappingTests {
    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try GitHubAPIClient.decoder().decode(T.self, from: Data(json.utf8))
    }

    private let pullJSON = """
        {"state": "open", "merged": false, "draft": false,
         "mergeable": true, "mergeable_state": "blocked",
         "head": {"sha": "abc123"}}
        """

    private let checkRunsJSON = """
        {"total_count": 3, "check_runs": [
          {"name": "build", "status": "completed", "conclusion": "success",
           "started_at": "2026-08-31T13:52:14Z", "completed_at": "2026-08-31T13:54:25Z",
           "html_url": "https://github.com/x/y/runs/1"},
          {"name": "tests", "status": "in_progress", "conclusion": null,
           "started_at": "2026-08-31T13:52:14Z", "completed_at": null, "html_url": null},
          {"name": "lint", "status": "completed", "conclusion": "failure",
           "started_at": "2026-08-31T13:52:14Z", "completed_at": "2026-08-31T13:53:04Z",
           "html_url": null}
        ]}
        """

    // The statuses endpoint reports state="pending" even with zero
    // statuses — it must contribute nothing.
    private let emptyCombinedJSON = """
        {"state": "pending", "total_count": 0, "statuses": []}
        """

    @Test func mapsChecksSortedFailuresFirstWithDurations() throws {
        let status = GitHubAPIClient.status(
            pull: try decode(pullJSON, as: GitHubAPIClient.PullResponse.self),
            checkRuns: try decode(checkRunsJSON, as: GitHubAPIClient.CheckRunsResponse.self),
            combined: try decode(emptyCombinedJSON, as: GitHubAPIClient.CombinedStatusResponse.self))

        #expect(status.prState == .open)
        #expect(status.checks.map(\.name) == ["lint", "tests", "build"])
        #expect(status.checks[0].detail == "Failing after 50s")
        // Running checks carry their start time for the live elapsed counter;
        // finished ones don't (their duration is baked into the detail).
        #expect(status.checks[1].detail == "In progress")
        #expect(status.checks[1].startedAt == Date(timeIntervalSince1970: 1_788_184_334))
        #expect(status.checks[0].startedAt == nil)
        #expect(status.checks[2].detail == "Successful in 2m 11s")
        #expect(status.checks[2].detailsURL == URL(string: "https://github.com/x/y/runs/1"))
        #expect(status.totalCheckCount == 3)
        // A failure is decisive even while another check still runs.
        #expect(status.indicator == .ciFailed)
        #expect(status.checkSummary == "1 failing, 1 in progress, and 1 successful checks")
    }

    @Test func legacyStatusesMergeAndDedupe() throws {
        let combined = """
            {"state": "pending", "total_count": 2, "statuses": [
              {"context": "build", "state": "failure", "target_url": null},
              {"context": "ci/deploy-preview", "state": "pending",
               "target_url": "https://ci.example/1"}
            ]}
            """
        let checkRuns = """
            {"total_count": 1, "check_runs": [
              {"name": "build", "status": "completed", "conclusion": "success",
               "started_at": null, "completed_at": null, "html_url": null}
            ]}
            """
        let status = GitHubAPIClient.status(
            pull: try decode(pullJSON, as: GitHubAPIClient.PullResponse.self),
            checkRuns: try decode(checkRuns, as: GitHubAPIClient.CheckRunsResponse.self),
            combined: try decode(combined, as: GitHubAPIClient.CombinedStatusResponse.self))

        // The check run named "build" wins over the same-named legacy
        // status; the unique legacy context is appended.
        #expect(status.checks.map(\.name) == ["ci/deploy-preview", "build"])
        #expect(status.checks[0].outcome == .inProgress)
        #expect(status.totalCheckCount == 2)
        #expect(status.indicator == .inProgress)
    }

    @Test func cleanAndGreenIsGood() throws {
        let pull = """
            {"state": "open", "merged": false, "draft": false,
             "mergeable": true, "mergeable_state": "clean",
             "head": {"sha": "abc123"}}
            """
        let checkRuns = """
            {"total_count": 1, "check_runs": [
              {"name": "build", "status": "completed", "conclusion": "success",
               "started_at": null, "completed_at": null, "html_url": null}
            ]}
            """
        let status = GitHubAPIClient.status(
            pull: try decode(pull, as: GitHubAPIClient.PullResponse.self),
            checkRuns: try decode(checkRuns, as: GitHubAPIClient.CheckRunsResponse.self),
            combined: try decode(emptyCombinedJSON, as: GitHubAPIClient.CombinedStatusResponse.self))
        #expect(status.indicator == .good)
        #expect(status.headline == "All checks have passed")
        #expect(status.mergeabilityNote == nil)
    }

    @Test func mergeStateMapping() {
        typealias MS = PullRequestStatus.MergeState
        #expect(GitHubAPIClient.mergeState(mergeable: true, state: "clean", draft: false) == MS.clean)
        #expect(GitHubAPIClient.mergeState(mergeable: true, state: "unstable", draft: false) == MS.clean)
        #expect(GitHubAPIClient.mergeState(mergeable: false, state: "dirty", draft: false) == MS.conflicts)
        #expect(GitHubAPIClient.mergeState(mergeable: true, state: "behind", draft: false) == MS.behind)
        #expect(GitHubAPIClient.mergeState(mergeable: true, state: "blocked", draft: false) == MS.blocked)
        #expect(GitHubAPIClient.mergeState(mergeable: nil, state: "unknown", draft: false) == MS.computing)
        #expect(GitHubAPIClient.mergeState(mergeable: true, state: "clean", draft: true) == MS.draft)
    }

    @Test func indicatorPriorities() {
        func status(
            _ mergeState: PullRequestStatus.MergeState,
            _ outcomes: [PRCheck.Outcome],
            prState: PullRequestStatus.PhaseState = .open
        ) -> PullRequestStatus {
            PullRequestStatus(
                prState: prState,
                mergeState: mergeState,
                checks: outcomes.enumerated().map {
                    PRCheck(name: "c\($0.offset)", outcome: $0.element, detail: "")
                })
        }
        // Conflicts show once nothing is running and nothing failed.
        #expect(status(.conflicts, [.success]).indicator == .notMergeable)
        // Red beats orange; spinner beats orange.
        #expect(status(.conflicts, [.failure, .success]).indicator == .ciFailed)
        #expect(status(.conflicts, [.queued]).indicator == .inProgress)
        // Cancelled counts as a failure.
        #expect(status(.clean, [.cancelled]).indicator == .ciFailed)
        // Mergeability still computing → spinner even with green checks.
        #expect(status(.computing, [.success]).indicator == .inProgress)
        // Blocked (review required) with green CI stays green, but says why.
        let blocked = status(.blocked, [.success])
        #expect(blocked.indicator == .good)
        #expect(blocked.mergeabilityNote != nil)
        // Draft is orange; merged/closed override everything.
        #expect(status(.draft, [.success]).indicator == .notMergeable)
        #expect(status(.clean, [.failure], prState: .merged).indicator == .merged)
        #expect(status(.clean, [], prState: .closed).indicator == .closed)
        // Skipped/neutral checks alone are green.
        #expect(status(.clean, [.skipped, .neutral, .success]).indicator == .good)
    }

    @Test func durationFormatting() {
        #expect(GitHubAPIClient.durationText(50) == "50s")
        #expect(GitHubAPIClient.durationText(131) == "2m 11s")
        #expect(GitHubAPIClient.durationText(3_900) == "1h 5m")
    }

    @Test func settlingDrivesFasterPolling() {
        func status(
            _ mergeState: PullRequestStatus.MergeState,
            _ outcomes: [PRCheck.Outcome],
            prState: PullRequestStatus.PhaseState = .open
        ) -> PullRequestStatus {
            PullRequestStatus(
                prState: prState,
                mergeState: mergeState,
                checks: outcomes.enumerated().map {
                    PRCheck(name: "c\($0.offset)", outcome: $0.element, detail: "")
                })
        }
        // Anything still producing results — even alongside a failure —
        // keeps the fast cadence (the elapsed counters are live).
        #expect(status(.clean, [.inProgress, .success]).isSettling)
        #expect(status(.clean, [.queued, .failure]).isSettling)
        #expect(status(.computing, [.success]).isSettling)
        // Quiet states back off.
        #expect(!status(.clean, [.success]).isSettling)
        #expect(!status(.conflicts, [.failure]).isSettling)
        #expect(!status(.blocked, []).isSettling)
        // A merged/closed PR is settled even if stale runs linger.
        #expect(!status(.clean, [.inProgress], prState: .merged).isSettling)
        #expect(!status(.computing, [], prState: .closed).isSettling)
    }
}

@Suite("github API client transport")
struct GitHubAPIClientTransportTests {
    @Test func pullStatusFetchesAllThreeEndpoints() async throws {
        let client = GitHubAPIClient(token: "t0k") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
            let path = request.url!.path
            let json: String
            if path.hasSuffix("/pulls/7") {
                json = """
                    {"state": "open", "merged": false, "draft": false,
                     "mergeable": true, "mergeable_state": "clean",
                     "head": {"sha": "abc123"}}
                    """
            } else if path.contains("/commits/abc123/check-runs") {
                json = """
                    {"total_count": 1, "check_runs": [
                      {"name": "build", "status": "completed", "conclusion": "success",
                       "started_at": null, "completed_at": null, "html_url": null}]}
                    """
            } else if path.contains("/commits/abc123/status") {
                json = #"{"state": "pending", "total_count": 0, "statuses": []}"#
            } else {
                Issue.record("unexpected request: \(path)")
                json = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
        let status = try await client.pullStatus(owner: "o", repo: "r", number: 7)
        #expect(status.indicator == .good)
        #expect(status.checks.count == 1)
    }

    @Test func unauthorizedSurfacesAsAuthError() async {
        let client = GitHubAPIClient(token: "dead") { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }
        await #expect(throws: GitHubAPIClient.APIError.unauthorized) {
            _ = try await client.viewerLogin()
        }
    }
}

@Suite("github device flow")
struct GitHubDeviceFlowTests {
    @Test func parsesAuthorization() throws {
        let json = """
            {"device_code": "dc123", "user_code": "ABCD-1234",
             "verification_uri": "https://github.com/login/device",
             "expires_in": 899, "interval": 5}
            """
        let auth = try GitHubDeviceFlow.parseAuthorization(Data(json.utf8))
        #expect(auth.userCode == "ABCD-1234")
        #expect(auth.deviceCode == "dc123")
        #expect(auth.verificationURL == URL(string: "https://github.com/login/device"))
        #expect(auth.interval == 5)
    }

    @Test func pollOutcomes() throws {
        func poll(_ json: String, interval: Int = 5) throws -> GitHubDeviceFlow.PollOutcome {
            try GitHubDeviceFlow.parsePoll(Data(json.utf8), currentInterval: interval)
        }
        #expect(try poll(#"{"error": "authorization_pending"}"#) == .pending(retryAfter: 5))
        // slow_down bumps the interval (GitHub sends the new one).
        #expect(try poll(#"{"error": "slow_down", "interval": 10}"#) == .pending(retryAfter: 10))
        #expect(try poll(#"{"error": "slow_down"}"#) == .pending(retryAfter: 10))
        #expect(try poll(#"{"error": "access_denied"}"#) == .denied)
        #expect(try poll(#"{"error": "expired_token"}"#) == .expired)
        #expect(try poll(#"{"access_token": "gho_x", "token_type": "bearer", "scope": "repo"}"#)
            == .authorized(token: "gho_x"))
        #expect(throws: GitHubDeviceFlow.FlowError.self) {
            _ = try poll(#"{"error": "incorrect_client_credentials", "error_description": "bad id"}"#)
        }
    }
}
