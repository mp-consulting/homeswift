import Crypto
import Foundation
import Homeswift
import _CryptoExtras

/// AES-CCM (RFC 3610, NIST SP 800-38C) on swift-crypto's AES block function: BTHome and Xiaomi's MiBeacon encrypt
/// their advertisements with it, and neither CryptoKit nor swift-crypto has the mode. Checked against RFC 3610's vectors.
enum AESCCM {
    enum Failure: Error, Equatable {
        case badParameters
        case authenticationFailed
    }

    /// Decrypts `ciphertext` and checks its `tag`; throws `authenticationFailed` for another key or altered bytes.
    static func open(_ ciphertext: [UInt8], tag: [UInt8], key: [UInt8], nonce: [UInt8], associatedData: [UInt8] = []) throws -> [UInt8] {
        let keystream = try stream(count: ciphertext.count, key: key, nonce: nonce)
        let plaintext = zip(ciphertext, keystream.payload).map { $0 ^ $1 }
        let expected = try mac(plaintext, key: key, nonce: nonce, associatedData: associatedData, tagLength: tag.count, s0: keystream.s0)
        guard Secrets.constantTimeEqual(expected, tag) else { throw Failure.authenticationFailed }
        return plaintext
    }

    /// Encrypts `plaintext`: the ciphertext and its tag of `tagLength` bytes.
    static func seal(
        _ plaintext: [UInt8], key: [UInt8], nonce: [UInt8], associatedData: [UInt8] = [], tagLength: Int
    ) throws -> (ciphertext: [UInt8], tag: [UInt8]) {
        let keystream = try stream(count: plaintext.count, key: key, nonce: nonce)
        let tag = try mac(plaintext, key: key, nonce: nonce, associatedData: associatedData, tagLength: tagLength, s0: keystream.s0)
        return (zip(plaintext, keystream.payload).map { $0 ^ $1 }, tag)
    }

    private static func block(_ input: [UInt8], key: SymmetricKey) throws -> [UInt8] {
        var block = input
        try AES.permute(&block, key: key)
        return block
    }

    /// The counter blocks' keystream: S0 (for the tag) and the payload's.
    private static func stream(count: Int, key: [UInt8], nonce: [UInt8]) throws -> (s0: [UInt8], payload: [UInt8]) {
        guard [16, 24, 32].contains(key.count), (7...13).contains(nonce.count) else { throw Failure.badParameters }
        let lengthSize = 15 - nonce.count
        guard lengthSize >= 8 || count < 1 << (8 * lengthSize) else { throw Failure.badParameters }
        let symmetric = SymmetricKey(data: key)
        func counter(_ index: Int) -> [UInt8] {
            [UInt8(lengthSize - 1)] + nonce + (0..<lengthSize).reversed().map { UInt8(truncatingIfNeeded: index >> (8 * $0)) }
        }
        let s0 = try block(counter(0), key: symmetric)
        var payload: [UInt8] = []
        payload.reserveCapacity(count)
        var index = 1
        while payload.count < count {
            payload += try block(counter(index), key: symmetric)
            index += 1
        }
        return (s0, Array(payload.prefix(count)))
    }

    /// The CBC-MAC of B0, the associated data and the plaintext, encrypted with S0.
    private static func mac(_ plaintext: [UInt8], key: [UInt8], nonce: [UInt8], associatedData: [UInt8], tagLength: Int, s0: [UInt8]) throws -> [UInt8] {
        guard [4, 6, 8, 10, 12, 14, 16].contains(tagLength), associatedData.count < 0xFF00 else { throw Failure.badParameters }
        let symmetric = SymmetricKey(data: key)
        let lengthSize = 15 - nonce.count
        let flags = UInt8((associatedData.isEmpty ? 0 : 0x40) | ((tagLength - 2) / 2) << 3 | (lengthSize - 1))
        var input = [flags] + nonce + (0..<lengthSize).reversed().map { UInt8(truncatingIfNeeded: plaintext.count >> (8 * $0)) }
        if !associatedData.isEmpty {
            input += [UInt8(associatedData.count >> 8), UInt8(associatedData.count & 0xFF)] + associatedData
            input += [UInt8](repeating: 0, count: (16 - input.count % 16) % 16)
        }
        input += plaintext + [UInt8](repeating: 0, count: (16 - plaintext.count % 16) % 16)
        var state = [UInt8](repeating: 0, count: 16)
        for start in stride(from: 0, to: input.count, by: 16) {
            state = try block(zip(state, input[start..<start + 16]).map { $0 ^ $1 }, key: symmetric)
        }
        return zip(state.prefix(tagLength), s0).map { $0 ^ $1 }
    }
}

enum Hex {
    /// The bytes of hex text (`231d39c1…`), spaces and colons ignored; nil for anything else.
    static func bytes(_ text: String) -> [UInt8]? {
        let digits = Array(text.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }
}
