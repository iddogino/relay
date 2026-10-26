import Foundation
import RelayTestSupport
import Testing
@testable import RelaySSH

/// Passphrase-protected key files and writing keys back out, checked
/// against the real ssh-keygen in both directions.
@Suite("OpenSSH key files: decryption and export", .serialized)
struct OpenSSHKeyCryptoTests {
    let scratch: URL

    init() throws {
        scratch = try makeScratchDirectory("keycrypto")
    }

    @discardableResult
    func sshKeygen(_ arguments: [String], output: Pipe? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func keygen(_ name: String, _ arguments: [String], passphrase: String) throws -> String {
        let path = scratch.appendingPathComponent(name).path
        #expect(try sshKeygen(["-q", "-N", passphrase, "-C", "me@laptop", "-f", path] + arguments) == 0)
        return path
    }

    /// The `<type> <base64>` part of the `.pub` ssh-keygen wrote.
    func publicKey(_ path: String) throws -> String {
        let text = try String(contentsOfFile: path + ".pub", encoding: .utf8)
        return text.split(separator: " ").prefix(2).joined(separator: " ")
    }

    @Test(arguments: [
        ["-t", "ed25519"],
        ["-t", "ed25519", "-Z", "aes128-ctr"],
        ["-t", "ed25519", "-Z", "aes192-ctr"],
        ["-t", "ed25519", "-Z", "aes128-cbc"],
        ["-t", "ed25519", "-Z", "aes256-cbc"],
        ["-t", "ecdsa", "-b", "256"],
        ["-t", "ecdsa", "-b", "384"],
        ["-t", "ecdsa", "-b", "521"],
    ])
    func decryptsWhatSSHKeygenEncrypts(arguments: [String]) throws {
        // Few KDF rounds keep the suite fast; the default count is below.
        let path = try keygen("key-\(arguments.joined())", arguments + ["-a", "2"], passphrase: "correct horse")
        let text = try OpenSSHKeyFile.contents(ofFileAt: path)
        #expect(OpenSSHKeyFile.isEncrypted(text))
        let key = try OpenSSHKeyFile.read(text, passphrase: "correct horse")
        #expect(key.publicKey == (try publicKey(path)))
        #expect(key.comment == "me@laptop")
    }

    @Test func decryptsAKeyWithDefaultSettings() throws {
        let path = try keygen("default", ["-t", "ed25519"], passphrase: "pass")
        let key = try OpenSSHKeyFile.read(try OpenSSHKeyFile.contents(ofFileAt: path), passphrase: "pass")
        #expect(key.publicKey == (try publicKey(path)))
    }

    @Test func aWrongOrMissingPassphraseIsReported() throws {
        let path = try keygen("wrong", ["-t", "ed25519", "-a", "2"], passphrase: "right")
        let text = try OpenSSHKeyFile.contents(ofFileAt: path)
        #expect(throws: OpenSSHKeyFile.KeyFileError.wrongPassphrase) { try OpenSSHKeyFile.read(text, passphrase: "wrong") }
        #expect(throws: OpenSSHKeyFile.KeyFileError.encrypted) { try OpenSSHKeyFile.read(text, passphrase: nil) }
        #expect(throws: OpenSSHKeyFile.KeyFileError.encrypted) { try OpenSSHKeyFile.load(path: path) }
    }

    @Test func unencryptedFilesNeedNoPassphrase() throws {
        let path = try keygen("plain", ["-t", "ed25519"], passphrase: "")
        let text = try OpenSSHKeyFile.contents(ofFileAt: path)
        #expect(!OpenSSHKeyFile.isEncrypted(text))
        #expect(try OpenSSHKeyFile.read(text, passphrase: "ignored").publicKey == (try publicKey(path)))
    }

    @Test func unsupportedCiphersAndKeyTypesAreNamed() throws {
        let chacha = try keygen("chacha", ["-t", "ed25519", "-a", "2", "-Z", "chacha20-poly1305@openssh.com"], passphrase: "p")
        #expect(throws: OpenSSHKeyFile.KeyFileError.unsupportedCipher("chacha20-poly1305@openssh.com")) {
            try OpenSSHKeyFile.read(try OpenSSHKeyFile.contents(ofFileAt: chacha), passphrase: "p")
        }
        let rsa = try keygen("rsa", ["-t", "rsa", "-b", "2048", "-a", "2"], passphrase: "p")
        #expect(throws: OpenSSHKeyFile.KeyFileError.unsupportedKeyType("ssh-rsa")) {
            try OpenSSHKeyFile.read(try OpenSSHKeyFile.contents(ofFileAt: rsa), passphrase: "p")
        }
    }

    @Test(arguments: ["ed25519", "ecdsa-256", "ecdsa-384", "ecdsa-521"])
    func exportedKeysAreReadableByOpenSSH(kind: String) throws {
        let key: SSHPrivateKeyMaterial
        if kind == "ed25519" {
            key = .generateEd25519(comment: "relay")
        } else {
            let bits = kind.split(separator: "-")[1]
            let source = try keygen("src-\(kind)", ["-t", "ecdsa", "-b", String(bits)], passphrase: "")
            key = try OpenSSHKeyFile.read(try OpenSSHKeyFile.contents(ofFileAt: source), passphrase: nil)
        }
        let exported = scratch.appendingPathComponent("exported-\(kind)")
        try key.openSSHPrivateKey(comment: "relay").write(to: exported, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exported.path)

        // ssh-keygen derives the public key from our file: same key.
        let pipe = Pipe()
        #expect(try sshKeygen(["-y", "-f", exported.path], output: pipe) == 0)
        let derived = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(derived.split(separator: " ").prefix(2).joined(separator: " ") == key.publicKey)

        // And we read our own output back.
        let reread = try OpenSSHKeyFile.read(key.openSSHPrivateKey(), passphrase: nil)
        #expect(reread.publicKey == key.publicKey)
    }
}
