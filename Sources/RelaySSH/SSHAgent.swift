import Foundation

/// Client for the ssh-agent protocol (draft-miller-ssh-agent) over the
/// agent's Unix socket — on macOS the launchd-managed agent that holds keys
/// unlocked via the Keychain (`UseKeychain`/`AddKeysToAgent`).
///
/// Calls are blocking and short (local socket, bounded by a timeout);
/// signing happens inside NIOSSH's synchronous signing hook.
public struct SSHAgent: Sendable {
    public struct Identity: Sendable, Hashable {
        /// The public key blob (`string algorithm` + key fields).
        public let blob: Data
        public let comment: String

        public var algorithm: String? { try? blob.splitSSHBlob().algorithm }
    }

    public enum AgentError: Error, Sendable {
        case unavailable
        case io(String)
        case refused
        case malformedReply
    }

    public let socketPath: String
    var timeoutSeconds = 10

    /// The agent named by `SSH_AUTH_SOCK`, if any.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> SSHAgent? {
        guard let path = environment["SSH_AUTH_SOCK"], !path.isEmpty else { return nil }
        return SSHAgent(socketPath: path)
    }

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    private static let requestIdentities: UInt8 = 11
    private static let identitiesAnswer: UInt8 = 12
    private static let signRequest: UInt8 = 13
    private static let signResponse: UInt8 = 14

    public func identities() throws -> [Identity] {
        var reader = try roundTrip(Data([Self.requestIdentities]), expecting: Self.identitiesAnswer)
        let count = try reader.readUInt32()
        guard count < 1024 else { throw AgentError.malformedReply }
        var result: [Identity] = []
        for _ in 0..<count {
            let blob = try reader.readString()
            let comment = String(data: try reader.readString(), encoding: .utf8) ?? ""
            result.append(Identity(blob: blob, comment: comment))
        }
        return result
    }

    /// Signs `data` with the agent key whose public blob is `keyBlob`;
    /// returns the signature blob (`string algorithm` + signature fields).
    public func sign(keyBlob: Data, data: Data, flags: UInt32 = 0) throws -> Data {
        var writer = SSHWireWriter()
        writer.writeByte(Self.signRequest)
        writer.writeString(keyBlob)
        writer.writeString(data)
        writer.writeUInt32(flags)
        var reader = try roundTrip(writer.data, expecting: Self.signResponse)
        return try reader.readString()
    }

    // MARK: Transport

    private func roundTrip(_ request: Data, expecting replyType: UInt8) throws -> SSHWireReader {
        let fd = try connectSocket()
        defer { close(fd) }

        var framed = SSHWireWriter()
        framed.writeString(request)
        try Self.writeAll(fd: fd, data: framed.data)

        let header = try Self.readExactly(fd: fd, count: 4)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length < 256 * 1024 else { throw AgentError.malformedReply }
        var reader = SSHWireReader(try Self.readExactly(fd: fd, count: length))
        let type = try reader.readByte()
        guard type == replyType else { throw AgentError.refused }
        return reader
    }

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError.io("socket: errno \(errno)") }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw AgentError.unavailable
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            close(fd)
            throw AgentError.unavailable
        }
        return fd
    }

    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                var n: Int
                repeat { n = write(fd, base + offset, buffer.count - offset) } while n == -1 && errno == EINTR
                guard n > 0 else { throw AgentError.io("write: errno \(errno)") }
                offset += n
            }
        }
    }

    static func readExactly(fd: Int32, count: Int) throws -> Data {
        var result = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: min(count, 65536))
        while result.count < count {
            var n: Int
            repeat { n = read(fd, &buffer, min(buffer.count, count - result.count)) } while n == -1 && errno == EINTR
            guard n > 0 else { throw AgentError.io(n == 0 ? "agent closed the connection" : "read: errno \(errno)") }
            result.append(contentsOf: buffer[0..<n])
        }
        return result
    }
}
