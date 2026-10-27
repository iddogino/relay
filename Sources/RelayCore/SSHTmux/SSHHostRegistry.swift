import Foundation

/// Relay's host list, shared by everything that connects (thread-safe):
/// the provider and the SSH router look hosts up here by alias.
public final class SSHHostRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var _hosts: [SSHHost] = []

    public init(hosts: [SSHHost] = []) {
        _hosts = hosts
    }

    public var hosts: [SSHHost] {
        lock.withLock { _hosts }
    }

    public func host(alias: String) -> SSHHost? {
        lock.withLock { _hosts.first { $0.alias == alias } }
    }

    /// Called after every `setHosts` (e.g. to drop connection state tied
    /// to old settings).
    public var onHostsChanged: (@Sendable () -> Void)? {
        get { lock.withLock { _onHostsChanged } }
        set { lock.withLock { _onHostsChanged = newValue } }
    }
    private var _onHostsChanged: (@Sendable () -> Void)?

    public func setHosts(_ hosts: [SSHHost]) {
        lock.withLock { _hosts = hosts }
        onHostsChanged?()
    }
}
