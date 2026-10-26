import CommonCrypto
import Crypto
import Foundation
@preconcurrency import NIOSSH

/// Reads and writes OpenSSH-format private keys (`-----BEGIN OPENSSH
/// PRIVATE KEY-----`, the default since OpenSSH 7.8) holding an Ed25519 or
/// ECDSA key. Passphrase-protected files (bcrypt KDF, AES-CTR/CBC — what
/// ssh-keygen writes) decrypt when given the passphrase.
public enum OpenSSHKeyFile {
    public enum KeyFileError: Error, Equatable, Sendable {
        case notOpenSSHFormat
        /// Passphrase-protected, and no passphrase was given.
        case encrypted
        case wrongPassphrase
        case unsupportedCipher(String)
        case unsupportedKeyType(String)
        case malformed
    }

    /// An unencrypted key file, ready to sign with.
    public static func load(path: String) throws -> NIOSSHPrivateKey {
        try parse(try contents(ofFileAt: path))
    }

    public static func contents(ofFileAt path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw KeyFileError.malformed
        }
        return text
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
    static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let end = "-----END OPENSSH PRIVATE KEY-----"

    static func parse(_ text: String) throws -> NIOSSHPrivateKey {
        try read(text, passphrase: nil).nioKey
    }

    /// Whether `text` is an OpenSSH key file that needs a passphrase.
    public static func isEncrypted(_ text: String) -> Bool {
        guard let data = try? body(text) else { return false }
        var reader = SSHWireReader(data.dropFirst(magic.count))
        return (try? reader.readUTF8()).map { $0 != "none" } ?? false
    }

    /// The key in `text`, decrypted with `passphrase` if it's protected.
    public static func read(_ text: String, passphrase: String?) throws -> SSHPrivateKeyMaterial {
        let data = try body(text)
        do {
            var reader = SSHWireReader(data.dropFirst(magic.count))
            let cipher = try reader.readUTF8()
            let kdf = try reader.readUTF8()
            let kdfOptions = try reader.readString()
            guard try reader.readUInt32() == 1 else { throw KeyFileError.malformed }
            let publicBlob = try reader.readString()
            var section = try reader.readString()

            if cipher != "none" {
                guard let passphrase else { throw KeyFileError.encrypted }
                guard let spec = CipherSpec(name: cipher) else { throw KeyFileError.unsupportedCipher(cipher) }
                guard kdf == "bcrypt" else { throw KeyFileError.unsupportedCipher("\(cipher) with \(kdf)") }
                var options = SSHWireReader(kdfOptions)
                let salt = try options.readString()
                let rounds = Int(try options.readUInt32())
                guard (1...1_000_000).contains(rounds), section.count % spec.blockSize == 0 else {
                    throw KeyFileError.malformed
                }
                let derived = BcryptPBKDF.derive(
                    passphrase: Data(passphrase.utf8), salt: salt, rounds: rounds,
                    keyLength: spec.keyLength + spec.ivLength)
                section = try spec.decrypt(
                    section, key: derived.prefix(spec.keyLength), iv: derived.suffix(spec.ivLength))
            } else {
                guard kdf == "none" else { throw KeyFileError.malformed }
            }

            var privateReader = SSHWireReader(section)
            // Equal check words: the passphrase was right.
            guard try privateReader.readUInt32() == privateReader.readUInt32() else {
                throw cipher == "none" ? KeyFileError.malformed : KeyFileError.wrongPassphrase
            }
            let material = try SSHPrivateKeyMaterial.read(from: &privateReader)
            guard material.publicKeyBlob == publicBlob else { throw KeyFileError.malformed }
            return material
        } catch let error as KeyFileError {
            throw error
        } catch {
            throw KeyFileError.malformed
        }
    }

    /// The decoded payload between the armor lines (magic included).
    private static func body(_ text: String) throws -> Data {
        guard let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else {
            throw KeyFileError.notOpenSSHFormat
        }
        let base64 = text[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(base64)), data.starts(with: magic) else {
            throw KeyFileError.malformed
        }
        return data
    }

    /// The ciphers ssh-keygen can protect a key with that are worth
    /// supporting (aes256-ctr has been its default since 2014).
    struct CipherSpec {
        let keyLength: Int
        let ivLength = 16
        let blockSize = 16
        let mode: CCMode

        init?(name: String) {
            switch name {
            case "aes128-ctr": keyLength = 16; mode = CCMode(kCCModeCTR)
            case "aes192-ctr": keyLength = 24; mode = CCMode(kCCModeCTR)
            case "aes256-ctr": keyLength = 32; mode = CCMode(kCCModeCTR)
            case "aes128-cbc": keyLength = 16; mode = CCMode(kCCModeCBC)
            case "aes192-cbc": keyLength = 24; mode = CCMode(kCCModeCBC)
            case "aes256-cbc": keyLength = 32; mode = CCMode(kCCModeCBC)
            default: return nil
            }
        }

        func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
            var cryptor: CCCryptorRef?
            let options = mode == CCMode(kCCModeCTR) ? CCModeOptions(kCCModeOptionCTR_BE) : 0
            let created = key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCryptorCreateWithMode(
                        CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                        ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0, options, &cryptor)
                }
            }
            guard created == kCCSuccess, let cryptor else { throw KeyFileError.malformed }
            defer { CCCryptorRelease(cryptor) }
            var output = Data(count: data.count)
            var moved = 0
            let status = output.withUnsafeMutableBytes { out in
                data.withUnsafeBytes { input in
                    CCCryptorUpdate(cryptor, input.baseAddress, data.count, out.baseAddress, data.count, &moved)
                }
            }
            guard status == kCCSuccess, moved == data.count else { throw KeyFileError.malformed }
            return output
        }
    }
}

/// A private key Relay holds itself (generated, or imported from a file),
/// as opposed to one an agent or the Secure Enclave signs with.
public struct SSHPrivateKeyMaterial: @unchecked Sendable {
    enum Backing {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
        case p384(P384.Signing.PrivateKey)
        case p521(P521.Signing.PrivateKey)
    }

    let backing: Backing
    /// The comment stored with the key (usually user@host), may be empty.
    public let comment: String

    init(_ backing: Backing, comment: String = "") {
        self.backing = backing
        self.comment = comment
    }

    public static func generateEd25519(comment: String = "") -> SSHPrivateKeyMaterial {
        SSHPrivateKeyMaterial(.ed25519(Curve25519.Signing.PrivateKey()), comment: comment)
    }

    public var nioKey: NIOSSHPrivateKey {
        switch backing {
        case .ed25519(let key): return NIOSSHPrivateKey(ed25519Key: key)
        case .p256(let key): return NIOSSHPrivateKey(p256Key: key)
        case .p384(let key): return NIOSSHPrivateKey(p384Key: key)
        case .p521(let key): return NIOSSHPrivateKey(p521Key: key)
        }
    }

    public var algorithm: String {
        switch backing {
        case .ed25519: return "ssh-ed25519"
        case .p256: return "ecdsa-sha2-nistp256"
        case .p384: return "ecdsa-sha2-nistp384"
        case .p521: return "ecdsa-sha2-nistp521"
        }
    }

    private var curveName: String {
        switch backing {
        case .ed25519: return ""
        case .p256: return "nistp256"
        case .p384: return "nistp384"
        case .p521: return "nistp521"
        }
    }

    public var publicKeyBlob: Data {
        var writer = SSHWireWriter()
        writer.writeString(algorithm)
        switch backing {
        case .ed25519(let key):
            writer.writeString(key.publicKey.rawRepresentation)
        case .p256(let key):
            writer.writeString(curveName)
            writer.writeString(key.publicKey.x963Representation)
        case .p384(let key):
            writer.writeString(curveName)
            writer.writeString(key.publicKey.x963Representation)
        case .p521(let key):
            writer.writeString(curveName)
            writer.writeString(key.publicKey.x963Representation)
        }
        return writer.data
    }

    /// `<algorithm> <base64 blob>` — an authorized_keys line without a comment.
    public var publicKey: String {
        "\(algorithm) \(publicKeyBlob.base64EncodedString())"
    }

    /// The key as an unencrypted OpenSSH private key file.
    public func openSSHPrivateKey(comment: String? = nil) -> String {
        var section = SSHWireWriter()
        let check = UInt32.random(in: .min ... .max)
        section.writeUInt32(check)
        section.writeUInt32(check)
        section.writeString(algorithm)
        switch backing {
        case .ed25519(let key):
            let publicKey = key.publicKey.rawRepresentation
            section.writeString(publicKey)
            section.writeString(key.rawRepresentation + publicKey)
        case .p256(let key):
            Self.writeECDSA(&section, curve: curveName, point: key.publicKey.x963Representation, scalar: key.rawRepresentation)
        case .p384(let key):
            Self.writeECDSA(&section, curve: curveName, point: key.publicKey.x963Representation, scalar: key.rawRepresentation)
        case .p521(let key):
            Self.writeECDSA(&section, curve: curveName, point: key.publicKey.x963Representation, scalar: key.rawRepresentation)
        }
        section.writeString(comment ?? self.comment)
        var pad: UInt8 = 1
        while section.data.count % 8 != 0 {
            section.writeByte(pad)
            pad += 1
        }

        var file = SSHWireWriter()
        for byte in OpenSSHKeyFile.magic { file.writeByte(byte) }
        file.writeString("none")
        file.writeString("none")
        file.writeString(Data())
        file.writeUInt32(1)
        file.writeString(publicKeyBlob)
        file.writeString(section.data)
        let base64 = file.data.base64EncodedString()
        var lines = [OpenSSHKeyFile.begin]
        var index = base64.startIndex
        while index < base64.endIndex {
            let next = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<next]))
            index = next
        }
        lines.append(OpenSSHKeyFile.end)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func writeECDSA(_ writer: inout SSHWireWriter, curve: String, point: Data, scalar: Data) {
        writer.writeString(curve)
        writer.writeString(point)
        // mpint: minimal big-endian, a leading zero when the top bit is set.
        var bytes = scalar.drop { $0 == 0 }
        if let first = bytes.first, first & 0x80 != 0 { bytes = Data([0]) + bytes }
        writer.writeString(bytes)
    }

    /// The key-type-specific private fields and comment of a key file's
    /// private section.
    static func read(from section: inout SSHWireReader) throws -> SSHPrivateKeyMaterial {
        let type = try section.readUTF8()
        let backing: Backing
        switch type {
        case "ssh-ed25519":
            _ = try section.readString() // public
            let secret = try section.readString() // seed ‖ public
            guard secret.count == 64 else { throw OpenSSHKeyFile.KeyFileError.malformed }
            backing = .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32)))
        case "ecdsa-sha2-nistp256":
            backing = .p256(try P256.Signing.PrivateKey(rawRepresentation: ecdsaScalar(&section, size: 32)))
        case "ecdsa-sha2-nistp384":
            backing = .p384(try P384.Signing.PrivateKey(rawRepresentation: ecdsaScalar(&section, size: 48)))
        case "ecdsa-sha2-nistp521":
            backing = .p521(try P521.Signing.PrivateKey(rawRepresentation: ecdsaScalar(&section, size: 66)))
        default:
            throw OpenSSHKeyFile.KeyFileError.unsupportedKeyType(type)
        }
        let comment = (try? section.readUTF8()) ?? ""
        return SSHPrivateKeyMaterial(backing, comment: comment)
    }

    /// ECDSA private fields: `string curve`, `string Q`, `mpint d`; returns
    /// d as a fixed-width big-endian scalar.
    private static func ecdsaScalar(_ reader: inout SSHWireReader, size: Int) throws -> Data {
        _ = try reader.readString() // curve name
        _ = try reader.readString() // public point
        var scalar = try reader.readString()
        while scalar.count > size, scalar.first == 0 { scalar = scalar.dropFirst() }
        guard scalar.count <= size else { throw OpenSSHKeyFile.KeyFileError.malformed }
        return Data(repeating: 0, count: size - scalar.count) + scalar
    }
}
