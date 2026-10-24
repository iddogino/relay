import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// NIOSSH private keys whose signing happens in ssh-agent: the key material
/// never leaves the agent (and a passphrase-protected key needs no
/// passphrase here once the agent holds it).
///
/// NIOSSH serializes a custom key as `string <static prefix>` followed by
/// the type's own bytes, so each algorithm is its own type; the bytes are
/// the agent's blob minus its leading algorithm string, passed through
/// verbatim. RSA isn't offered: NIOSSH would label it `ssh-rsa` (SHA-1),
/// which modern servers refuse.
enum AgentKeys {
    static func privateKey(for identity: SSHAgent.Identity, agent: SSHAgent) -> NIOSSHPrivateKey? {
        guard let (algorithm, rest) = try? identity.blob.splitSSHBlob() else { return nil }
        switch algorithm {
        case Ed25519.name:
            return NIOSSHPrivateKey(custom: AgentPrivateKey<Ed25519>(agent: agent, blob: identity.blob, keyFields: rest))
        case P256.name:
            return NIOSSHPrivateKey(custom: AgentPrivateKey<P256>(agent: agent, blob: identity.blob, keyFields: rest))
        case P384.name:
            return NIOSSHPrivateKey(custom: AgentPrivateKey<P384>(agent: agent, blob: identity.blob, keyFields: rest))
        case P521.name:
            return NIOSSHPrivateKey(custom: AgentPrivateKey<P521>(agent: agent, blob: identity.blob, keyFields: rest))
        default:
            return nil
        }
    }

    enum Ed25519: AgentAlgorithm { static let name = "ssh-ed25519" }
    enum P256: AgentAlgorithm { static let name = "ecdsa-sha2-nistp256" }
    enum P384: AgentAlgorithm { static let name = "ecdsa-sha2-nistp384" }
    enum P521: AgentAlgorithm { static let name = "ecdsa-sha2-nistp521" }
}

protocol AgentAlgorithm {
    static var name: String { get }
}

enum AgentKeyError: Error {
    case unsupported
    case wrongSignatureAlgorithm(String)
}

struct AgentPublicKey<Algorithm: AgentAlgorithm>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Algorithm.name }

    let keyFields: Data

    var rawRepresentation: Data { keyFields }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        // Client-side only: the server verifies; we never need to.
        false
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(keyFields)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        throw AgentKeyError.unsupported
    }
}

struct AgentSignature<Algorithm: AgentAlgorithm>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Algorithm.name }

    let signatureFields: Data

    var rawRepresentation: Data { signatureFields }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(signatureFields)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        throw AgentKeyError.unsupported
    }
}

struct AgentPrivateKey<Algorithm: AgentAlgorithm>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { Algorithm.name }

    let agent: SSHAgent
    let blob: Data
    let keyFields: Data

    var publicKey: NIOSSHPublicKeyProtocol { AgentPublicKey<Algorithm>(keyFields: keyFields) }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let signature = try agent.sign(keyBlob: blob, data: Data(data))
        let (algorithm, fields) = try signature.splitSSHBlob()
        guard algorithm == Algorithm.name else { throw AgentKeyError.wrongSignatureAlgorithm(algorithm) }
        return AgentSignature<Algorithm>(signatureFields: fields)
    }
}
