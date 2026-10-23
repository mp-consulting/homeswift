import Crypto
import Foundation
import Homeswift

/// Time-based one-time passwords (RFC 6238, over RFC 4226's HOTP) as authenticator apps expect them: HMAC-SHA-1,
/// 6 digits, 30-second steps, a 160-bit secret shown as Base32 in an `otpauth://` URI. The other algorithms and
/// lengths are there for the RFC's test vectors.
public enum TOTP {
    public enum Algorithm: String, Sendable {
        case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
    }

    public static let digits = 6
    public static let period: TimeInterval = 30
    /// RFC 4226 §4 asks for 128 bits at least and recommends 160, the size of an HMAC-SHA-1.
    public static let secretBytes = 20

    public static func newSecret() -> Data { Secrets.randomBytes(secretBytes) }

    /// The time step a date falls in: seconds since the epoch over the period.
    public static func step(at date: Date, period: TimeInterval = period) -> UInt64 {
        UInt64(max(0, (date.timeIntervalSince1970 / period).rounded(.down)))
    }

    /// RFC 4226 §5.3: the HMAC of the counter, dynamically truncated to 31 bits, modulo 10^digits.
    public static func hotp(secret: Data, counter: UInt64, digits: Int = digits, algorithm: Algorithm = .sha1) -> String {
        let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac: [UInt8] = switch algorithm {
        case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = UInt64(mac[offset] & 0x7F) << 24 | UInt64(mac[offset + 1]) << 16 | UInt64(mac[offset + 2]) << 8 | UInt64(mac[offset + 3])
        var modulus: UInt64 = 1
        for _ in 0..<digits { modulus *= 10 }
        let value = String(binary % modulus)
        return String(repeating: "0", count: max(0, digits - value.count)) + value
    }

    /// The code for the step `date` falls in.
    public static func code(secret: Data, at date: Date, digits: Int = digits, period: TimeInterval = period, algorithm: Algorithm = .sha1) -> String {
        hotp(secret: secret, counter: step(at: date, period: period), digits: digits, algorithm: algorithm)
    }

    /// The step whose code this is, within `window` steps either side of `date`'s (RFC 6238 §5.2 allows one step
    /// of clock drift and network delay), or nil. Spaces and dashes in the typed code do not matter; every step
    /// of the window is compared, in constant time.
    public static func matchingStep(_ typed: String, secret: Data, at date: Date, window: Int = 1) -> UInt64? {
        let code = typed.filter { !$0.isWhitespace && $0 != "-" }
        guard code.count == digits, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let now = Int64(step(at: date))
        var found: UInt64?
        for delta in -Int64(window)...Int64(window) where now + delta >= 0 {
            let candidate = UInt64(now + delta)
            if Secrets.constantTimeEqual(Array(hotp(secret: secret, counter: candidate).utf8), Array(code.utf8)) { found = candidate }
        }
        return found
    }

    /// The Key URI Format authenticator apps read from a QR code:
    /// `otpauth://totp/Issuer:account?secret=…&issuer=Issuer&algorithm=SHA1&digits=6&period=30`.
    public static func uri(secret: Data, account: String, issuer: String) -> String {
        let label = "\(encode(issuer)):\(encode(account))"
        return "otpauth://totp/\(label)?secret=\(Base32.encode(secret))&issuer=\(encode(issuer))&algorithm=SHA1&digits=\(digits)&period=\(Int(period))"
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

/// RFC 4648 Base32 (A–Z, 2–7), as authenticator apps take secrets: written without padding, read whatever the
/// case, spaces or padding.
public enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    public static func encode(_ data: Data) -> String {
        var output: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[Int(buffer >> UInt32(bits - 5) & 0x1F)])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[Int(buffer << UInt32(5 - bits) & 0x1F)]) }
        return String(decoding: output, as: UTF8.self)
    }

    public static func decode(_ text: String) -> Data? {
        var output = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for character in text.uppercased().utf8 where character != UInt8(ascii: " ") && character != UInt8(ascii: "=") && character != UInt8(ascii: "-") {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = buffer << 5 | UInt32(value)
            bits += 5
            if bits >= 8 {
                output.append(UInt8(buffer >> UInt32(bits - 8) & 0xFF))
                bits -= 8
            }
        }
        return output
    }
}
