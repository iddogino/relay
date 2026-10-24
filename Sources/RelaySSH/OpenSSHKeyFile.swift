import Crypto
import Foundation
@preconcurrency import NIOSSH

/// Reads OpenSSH-format private key files (`-----BEGIN OPENSSH PRIVATE
/// KEY-----`, the default since OpenSSH 7.8) holding an Ed25519 or ECDSA
/// key. Passphrase-protected files aren't decrypted: on the Mac the agent
/// signs for those; elsewhere they need importing (later).
public enum OpenSSHKeyFile {
    public enum KeyFileError: Error, Equatable, Sendable {
        case notOpenSSHFormat
        case encrypted
        case unsupportedKeyType(String)
        case malformed
    }

    public static func load(path: String) throws -> NIOSSHPrivateKey {
        let expanded = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw KeyFileError.malformed
        }
        return try parse(text)
    }

    /// The public key blob from the `.pub` next to a private key file,
    /// used to pick the matching agent identity.
    public static func publicKeyBlob(forPrivateKeyAt path: String) -> Data? {
        let expanded = (path as NSString).expandingTildeInPath + ".pub"
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else { return nil }
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard fields.count >= 2 else { return nil }
        return Data(base64Encoded: String(fields[1]))
    }

    static let magic = Data("openssh-key-v1\0".utf8)

    static func parse(_ text: String) throws -> NIOSSHPrivateKey {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        guard let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else {
            throw KeyFileError.notOpenSSHFormat
        }
        let base64 = text[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(base64)), data.starts(with: magic) else {
            throw KeyFileError.malformed
        }
        do {
            var reader = SSHWireReader(data.dropFirst(magic.count))
            let cipher = try reader.readUTF8()
            let kdf = try reader.readUTF8()
            _ = try reader.readString() // kdf options
            guard cipher == "none", kdf == "none" else { throw KeyFileError.encrypted }
            guard try reader.readUInt32() == 1 else { throw KeyFileError.malformed }
            _ = try reader.readString() // public key
            var section = SSHWireReader(try reader.readString())
            guard try section.readUInt32() == section.readUInt32() else { throw KeyFileError.malformed }
            let type = try section.readUTF8()
            switch type {
            case "ssh-ed25519":
                _ = try section.readString() // public
                let secret = try section.readString() // seed ‖ public
                guard secret.count == 64 else { throw KeyFileError.malformed }
                return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32)))
            case "ecdsa-sha2-nistp256":
                return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: ecdsaScalar(&section, size: 32)))
            case "ecdsa-sha2-nistp384":
                return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: ecdsaScalar(&section, size: 48)))
            case "ecdsa-sha2-nistp521":
                return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: ecdsaScalar(&section, size: 66)))
            default:
                throw KeyFileError.unsupportedKeyType(type)
            }
        } catch let error as KeyFileError {
            throw error
        } catch {
            throw KeyFileError.malformed
        }
    }

    /// ECDSA private fields: `string curve`, `string Q`, `mpint d`; returns
    /// d as a fixed-width big-endian scalar.
    private static func ecdsaScalar(_ reader: inout SSHWireReader, size: Int) throws -> Data {
        _ = try reader.readString() // curve name
        _ = try reader.readString() // public point
        var scalar = try reader.readString()
        while scalar.count > size, scalar.first == 0 { scalar = scalar.dropFirst() }
        guard scalar.count <= size else { throw KeyFileError.malformed }
        return Data(repeating: 0, count: size - scalar.count) + scalar
    }
}
