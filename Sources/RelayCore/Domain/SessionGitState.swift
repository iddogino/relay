import Foundation

/// Snapshot of the git state of a session's working directory, as reported
/// by the provider. Line counts are the session's changes relative to
/// `baseRef` (the merge-base with the default remote branch), or to HEAD
/// when the repo has no usable remote base — either way, "what this session
/// changed".
public struct SessionGitState: Sendable, Equatable {
    public var branch: String
    /// The comparison base (e.g. "origin/main"); nil when diffing against HEAD.
    public var baseRef: String?
    public var additions: Int
    public var deletions: Int
    public var filesChanged: Int
    public var pullRequest: PullRequestRef?

    public init(
        branch: String,
        baseRef: String? = nil,
        additions: Int = 0,
        deletions: Int = 0,
        filesChanged: Int = 0,
        pullRequest: PullRequestRef? = nil
    ) {
        self.branch = branch
        self.baseRef = baseRef
        self.additions = additions
        self.deletions = deletions
        self.filesChanged = filesChanged
        self.pullRequest = pullRequest
    }
}

/// A pull request the session's branch resolves to. Detection is pure git
/// protocol (`ls-remote refs/pull/*/head` sha-matching) — no API, no token.
public struct PullRequestRef: Sendable, Equatable {
    public var number: Int
    public var url: URL

    public init(number: Int, url: URL) {
        self.number = number
        self.url = url
    }
}

/// Parses GitHub `origin` remote URLs into their web equivalents.
public enum GitHubRemote {
    /// The https://github.com/owner/repo URL for an origin remote, or nil
    /// when the remote isn't a recognizable GitHub URL. Handles the scp-like
    /// (git@github.com:owner/repo.git), ssh://, and https:// forms.
    public static func webURL(fromOrigin origin: String) -> URL? {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        var ownerRepo: Substring?
        if let range = trimmed.range(of: "git@github.com:") {
            ownerRepo = trimmed[range.upperBound...]
        } else if let range = trimmed.range(of: "ssh://git@github.com/") {
            ownerRepo = trimmed[range.upperBound...]
        } else if let range = trimmed.range(of: "https://github.com/") {
            ownerRepo = trimmed[range.upperBound...]
        }
        guard var path = ownerRepo.map(String.init) else { return nil }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        while path.hasSuffix("/") { path = String(path.dropLast()) }
        let parts = path.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])")
    }

    public static func pullRequestURL(origin: String, number: Int) -> URL? {
        guard let base = webURL(fromOrigin: origin) else { return nil }
        return base.appendingPathComponent("pull").appendingPathComponent(String(number))
    }
}
