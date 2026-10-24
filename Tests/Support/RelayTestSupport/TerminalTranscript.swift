import Foundation
import RelaySSH

/// Collects a terminal session's output and end for assertions, optionally
/// acknowledging output as consumed (as a terminal would) so flow control
/// keeps data moving.
public final class TerminalTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var byteCount = 0
    private var end: SSHTerminalEnd?
    private var endCount = 0
    private var unacknowledged = 0
    private var session: SSHTerminalSession?
    private var autoConsume: Bool
    private let keepData: Bool

    /// `keepData: false` only counts bytes (for very large transfers).
    public init(autoConsume: Bool = true, keepData: Bool = true) {
        self.autoConsume = autoConsume
        self.keepData = keepData
    }

    public var onOutput: @Sendable (Data) -> Void {
        { [self] chunk in received(chunk) }
    }

    public var onEnd: @Sendable (SSHTerminalEnd) -> Void {
        { [self] end in lock.withLock { self.end = end; endCount += 1 } }
    }

    /// Call once the session is open; output that arrived before is
    /// acknowledged now if auto-consuming.
    public func attach(_ session: SSHTerminalSession) {
        let pending: Int = lock.withLock {
            self.session = session
            guard autoConsume else { return 0 }
            defer { unacknowledged = 0 }
            return unacknowledged
        }
        if pending > 0 { session.outputConsumed(pending) }
    }

    /// Starts or stops acknowledging output; starting acknowledges all
    /// output so far.
    public func setAutoConsume(_ on: Bool) {
        let (session, pending): (SSHTerminalSession?, Int) = lock.withLock {
            autoConsume = on
            guard on else { return (nil, 0) }
            defer { unacknowledged = 0 }
            return (self.session, unacknowledged)
        }
        if let session, pending > 0 { session.outputConsumed(pending) }
    }

    private func received(_ chunk: Data) {
        let session: SSHTerminalSession? = lock.withLock {
            if keepData { data.append(chunk) }
            byteCount += chunk.count
            guard autoConsume, let session = self.session else {
                unacknowledged += chunk.count
                return nil
            }
            return session
        }
        session?.outputConsumed(chunk.count)
    }

    public var output: Data { lock.withLock { data } }
    public var text: String { String(decoding: output, as: UTF8.self) }
    public var receivedBytes: Int { lock.withLock { byteCount } }
    public var ended: SSHTerminalEnd? { lock.withLock { end } }
    public var endCallCount: Int { lock.withLock { endCount } }

    public struct Timeout: Error, CustomStringConvertible {
        public let waitingFor: String
        public let transcript: String
        public var description: String { "timed out waiting for \(waitingFor); output so far:\n\(transcript)" }
    }

    /// Waits until the output contains `needle`.
    public func waitFor(_ needle: String, timeout: Duration = .seconds(10)) async throws {
        try await waitUntil("\"\(needle)\"", timeout: timeout) { $0.text.contains(needle) }
    }

    /// Waits until `condition` holds.
    public func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: (TerminalTranscript) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(self) {
            guard ContinuousClock.now < deadline else {
                throw Timeout(waitingFor: what, transcript: String(text.suffix(2000)))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits for the session's end.
    public func waitForEnd(timeout: Duration = .seconds(10)) async throws -> SSHTerminalEnd {
        try await waitUntil("the session to end", timeout: timeout) { $0.ended != nil }
        return ended!
    }
}

/// Makes a scratch directory for a test.
public func makeScratchDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-\(label)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes `count` deterministic pseudo-random bytes to a file.
public func writeRandomFile(at url: URL, count: Int, seed: UInt64 = 0x5EED) throws -> Data {
    var state = seed
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        bytes[i] = UInt8(truncatingIfNeeded: (state &* 0x2545F4914F6CDD1D) >> 56)
    }
    let data = Data(bytes)
    try data.write(to: url)
    return data
}
