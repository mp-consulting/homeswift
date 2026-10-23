import Foundation
import Testing

@testable import HomeswiftUI

@Suite struct TOTPTests {
    /// RFC 6238 appendix B: 8 digits, 30-second steps, a seed per algorithm.
    @Test func matchesTheRFC6238Vectors() {
        let sha1 = Data("12345678901234567890".utf8)
        let sha256 = Data("12345678901234567890123456789012".utf8)
        let sha512 = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)
        let vectors: [(TimeInterval, String, String, String)] = [
            (59, "94287082", "46119246", "90693936"),
            (1_111_111_109, "07081804", "68084774", "25091201"),
            (1_111_111_111, "14050471", "67062674", "99943326"),
            (1_234_567_890, "89005924", "91819424", "93441116"),
            (2_000_000_000, "69279037", "90698825", "38618901"),
            (20_000_000_000, "65353130", "77737706", "47863826"),
        ]
        for (time, one, two, five) in vectors {
            let date = Date(timeIntervalSince1970: time)
            #expect(TOTP.code(secret: sha1, at: date, digits: 8, algorithm: .sha1) == one, "SHA1 at \(time)")
            #expect(TOTP.code(secret: sha256, at: date, digits: 8, algorithm: .sha256) == two, "SHA256 at \(time)")
            #expect(TOTP.code(secret: sha512, at: date, digits: 8, algorithm: .sha512) == five, "SHA512 at \(time)")
        }
        #expect(TOTP.step(at: Date(timeIntervalSince1970: 1_111_111_109)) == 0x23523EC)
    }

    /// RFC 4226 appendix D: the HOTP values of the first ten counters, 6 digits, what the apps show.
    @Test func matchesTheRFC4226Vectors() {
        let secret = Data("12345678901234567890".utf8)
        let expected = ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]
        for (counter, code) in expected.enumerated() {
            #expect(TOTP.hotp(secret: secret, counter: UInt64(counter)) == code)
        }
    }

    @Test func acceptsOneStepOfDriftAndNothingElse() {
        let secret = Data("12345678901234567890".utf8)
        let now = Date(timeIntervalSince1970: 1_234_567_890)
        let code = TOTP.code(secret: secret, at: now)
        #expect(TOTP.matchingStep(code, secret: secret, at: now) == TOTP.step(at: now))
        #expect(TOTP.matchingStep(code, secret: secret, at: now.addingTimeInterval(30)) != nil)
        #expect(TOTP.matchingStep(code, secret: secret, at: now.addingTimeInterval(-30)) != nil)
        #expect(TOTP.matchingStep(code, secret: secret, at: now.addingTimeInterval(90)) == nil)
        // Spaces and dashes do not matter; letters and other lengths are refused.
        #expect(TOTP.matchingStep("\(code.prefix(3)) \(code.suffix(3))", secret: secret, at: now) != nil)
        #expect(TOTP.matchingStep("12345", secret: secret, at: now) == nil)
        #expect(TOTP.matchingStep("abcdef", secret: secret, at: now) == nil)
    }

    @Test func writesBase32AndTheKeyURI() {
        // RFC 4648 §10.
        let vectors = ["": "", "f": "MY", "fo": "MZXQ", "foo": "MZXW6", "foob": "MZXW6YQ", "fooba": "MZXW6YTB", "foobar": "MZXW6YTBOI"]
        for (text, encoded) in vectors {
            #expect(Base32.encode(Data(text.utf8)) == encoded)
            #expect(Base32.decode(encoded) == Data(text.utf8))
        }
        #expect(Base32.decode("mzxw 6ytb oi======") == Data("foobar".utf8))
        #expect(Base32.decode("MZ1") == nil)
        let secret = Data("12345678901234567890".utf8)
        #expect(Base32.encode(secret) == "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let uri = TOTP.uri(secret: secret, account: "rosaly", issuer: "Homeswift (UI Bridge)")
        #expect(uri == "otpauth://totp/Homeswift%20%28UI%20Bridge%29:rosaly?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Homeswift%20%28UI%20Bridge%29&algorithm=SHA1&digits=6&period=30")
        #expect(TOTP.newSecret().count == 20)
    }
}
