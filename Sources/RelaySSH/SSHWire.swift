import Foundation

/// Minimal reader/writer for the SSH wire encoding (RFC 4251 §5) over
/// `Data`: the agent protocol and OpenSSH key files use it.
struct SSHWireReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }
    var remaining: Data { data[offset...] }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.endIndex else { throw SSHWireError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(4)
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw SSHWireError.truncated }
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    mutating func readString() throws -> Data {
        try readBytes(Int(readUInt32()))
    }

    mutating func readUTF8() throws -> String {
        guard let string = String(data: try readString(), encoding: .utf8) else { throw SSHWireError.malformed }
        return string
    }
}

struct SSHWireWriter {
    private(set) var data = Data()

    mutating func writeByte(_ byte: UInt8) {
        data.append(byte)
    }

    mutating func writeUInt32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func writeString<D: DataProtocol>(_ bytes: D) {
        writeUInt32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    mutating func writeString(_ string: String) {
        writeString(Data(string.utf8))
    }
}

enum SSHWireError: Error {
    case truncated
    case malformed
}

extension Data {
    /// Splits an SSH key or signature blob — `string algorithm` followed by
    /// algorithm-specific fields — into the algorithm name and the rest.
    func splitSSHBlob() throws -> (algorithm: String, rest: Data) {
        var reader = SSHWireReader(self)
        let algorithm = try reader.readUTF8()
        return (algorithm, Data(reader.remaining))
    }
}
