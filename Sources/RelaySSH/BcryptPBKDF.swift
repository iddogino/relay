import Crypto
import Foundation

/// OpenBSD's `bcrypt_pbkdf`: the key derivation OpenSSH uses for
/// passphrase-protected private key files (`kdfname "bcrypt"`). A PBKDF2
/// variant whose PRF is a bcrypt hash over SHA-512 digests.
enum BcryptPBKDF {
    static func derive(passphrase: Data, salt: Data, rounds: Int, keyLength: Int) -> Data {
        precondition(rounds >= 1 && keyLength >= 1)
        let hashLength = 32
        let stride = (keyLength + hashLength - 1) / hashLength
        var amount = (keyLength + stride - 1) / stride
        var key = [UInt8](repeating: 0, count: keyLength)
        let sha2pass = [UInt8](SHA512.hash(data: passphrase))

        var remaining = keyLength
        var count: UInt32 = 1
        while remaining > 0 {
            var countSalt = salt
            countSalt.append(contentsOf: [UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)])
            var sha2salt = [UInt8](SHA512.hash(data: countSalt))
            var block = hash(sha2pass: sha2pass, sha2salt: sha2salt)
            var output = block
            for _ in 1..<rounds {
                sha2salt = [UInt8](SHA512.hash(data: block))
                block = hash(sha2pass: sha2pass, sha2salt: sha2salt)
                for i in 0..<output.count { output[i] ^= block[i] }
            }
            // Output bytes are spread across the key, not concatenated.
            amount = min(amount, remaining)
            var written = 0
            for i in 0..<amount {
                let destination = i * stride + Int(count - 1)
                if destination >= keyLength { break }
                key[destination] = output[i]
                written += 1
            }
            remaining -= written
            count += 1
        }
        return Data(key)
    }

    /// bcrypt_hash: eksblowfish keyed by the passphrase and salt digests,
    /// then 64 encryptions of a fixed string; output words little-endian.
    static func hash(sha2pass: [UInt8], sha2salt: [UInt8]) -> [UInt8] {
        var cipher = Blowfish()
        cipher.expandState(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            cipher.expand0State(key: sha2salt)
            cipher.expand0State(key: sha2pass)
        }
        let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)
        var words = [UInt32](repeating: 0, count: 8)
        var position = 0
        for i in 0..<8 { words[i] = Blowfish.streamToWord(magic, &position) }
        for _ in 0..<64 {
            for block in 0..<4 {
                let (left, right) = cipher.encipher(words[2 * block], words[2 * block + 1])
                words[2 * block] = left
                words[2 * block + 1] = right
            }
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            out[4 * i + 3] = UInt8(words[i] >> 24 & 0xFF)
            out[4 * i + 2] = UInt8(words[i] >> 16 & 0xFF)
            out[4 * i + 1] = UInt8(words[i] >> 8 & 0xFF)
            out[4 * i] = UInt8(words[i] & 0xFF)
        }
        return out
    }
}

/// Just enough Blowfish for bcrypt: the key schedule variants and block
/// encryption.
struct Blowfish {
    var p: [UInt32] = Blowfish.initialP
    /// The four S-boxes, back to back.
    var s: [UInt32] = Blowfish.initialS

    /// The next 4 bytes of `data` as a big-endian word, wrapping around.
    static func streamToWord(_ data: [UInt8], _ position: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            if position >= data.count { position = 0 }
            word = (word << 8) | UInt32(data[position])
            position += 1
        }
        return word
    }

    @inline(__always)
    private func f(_ x: UInt32) -> UInt32 {
        s.withUnsafeBufferPointer { s in
            ((s[Int(x >> 24)] &+ s[256 + Int(x >> 16 & 0xFF)]) ^ s[512 + Int(x >> 8 & 0xFF)]) &+ s[768 + Int(x & 0xFF)]
        }
    }

    func encipher(_ left: UInt32, _ right: UInt32) -> (UInt32, UInt32) {
        var l = left ^ p[0]
        var r = right
        var i = 1
        while i <= 16 {
            r ^= f(l) ^ p[i]
            l ^= f(r) ^ p[i + 1]
            i += 2
        }
        return (r ^ p[17], l)
    }

    /// Blowfish_expandstate: the salted key schedule.
    mutating func expandState(data: [UInt8], key: [UInt8]) {
        var position = 0
        for i in 0..<18 { p[i] ^= Self.streamToWord(key, &position) }
        position = 0
        var left: UInt32 = 0
        var right: UInt32 = 0
        var i = 0
        while i < 18 {
            left ^= Self.streamToWord(data, &position)
            right ^= Self.streamToWord(data, &position)
            (left, right) = encipher(left, right)
            p[i] = left
            p[i + 1] = right
            i += 2
        }
        i = 0
        while i < 1024 {
            left ^= Self.streamToWord(data, &position)
            right ^= Self.streamToWord(data, &position)
            (left, right) = encipher(left, right)
            s[i] = left
            s[i + 1] = right
            i += 2
        }
    }

    /// Blowfish_expand0state: the plain key schedule.
    mutating func expand0State(key: [UInt8]) {
        var position = 0
        for i in 0..<18 { p[i] ^= Self.streamToWord(key, &position) }
        var left: UInt32 = 0
        var right: UInt32 = 0
        var i = 0
        while i < 18 {
            (left, right) = encipher(left, right)
            p[i] = left
            p[i + 1] = right
            i += 2
        }
        i = 0
        while i < 1024 {
            (left, right) = encipher(left, right)
            s[i] = left
            s[i + 1] = right
            i += 2
        }
    }
}
