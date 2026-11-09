import Foundation
import RelaySSH

/// This Mac as an SSH host: whether Remote Login is on, and the host key
/// its `sshd` presents on loopback. A host whose trusted key is that key
/// *is* this Mac, however it's named (a tailnet name, `.local`, an IP) —
/// so Relay reaches it over loopback instead, which works with no network
/// and never leaves the machine. Nothing is stored: it's worked out again
/// on each device, every time it might have changed.
public final class LocalSSHIdentity: @unchecked Sendable {
    /// Where this Mac's sshd listens. 22 (Remote Login) in the app; dev
    /// builds can point it at a test sshd.
    public let port: Int
    private let lock = NSLock()
    private var key: String?
    private var lastProbe: ContinuousClock.Instant?
    private var probing: Task<String?, Never>?

    public init(port: Int = 22) {
        self.port = port
    }

    /// The host key this Mac's sshd presented at the last probe, or nil
    /// (Remote Login off, or not probed yet).
    public var hostKey: String? {
        lock.withLock { key }
    }

    /// Asks this Mac's sshd for its host key again — at most every
    /// `minimumInterval`, unless `force`. Returns the current key.
    @discardableResult
    public func refresh(pool: SSHConnectionPool, force: Bool = false, minimumInterval: Duration = .seconds(20)) async -> String? {
        let task: Task<String?, Never> = lock.withLock {
            if let probing { return probing }
            if !force, let lastProbe, ContinuousClock.now - lastProbe < minimumInterval {
                let current = key
                return Task { current }
            }
            let port = self.port
            let task = Task { await pool.probeHostKey(host: "127.0.0.1", port: port) }
            probing = task
            return task
        }
        let presented = await task.value
        lock.withLock {
            guard probing == task else { return }
            probing = nil
            lastProbe = .now
            key = presented
        }
        return presented
    }

    /// Whether `trustedKeys` (`<type> <base64>` lines) include this Mac's
    /// key `localKey`. Pure; unit-tested.
    public static func matches(trustedKeys: [String], localKey: String?) -> Bool {
        guard let local = normalized(localKey) else { return false }
        return trustedKeys.contains { normalized($0) == local }
    }

    /// `<type> <base64>`, dropping any comment.
    static func normalized(_ key: String?) -> String? {
        guard let fields = key?.split(separator: " ", omittingEmptySubsequences: true), fields.count >= 2 else { return nil }
        return "\(fields[0]) \(fields[1])"
    }
}
