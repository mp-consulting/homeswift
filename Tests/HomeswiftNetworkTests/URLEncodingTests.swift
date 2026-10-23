import Foundation
import HomeswiftNetwork
import Testing

/// The vectors come from the plugins' own encoders before they moved here (Daikin's FormEncoding, Dolphin's
/// formEncode, LG's QueryString, AWS Signature V4's uriEncode): signatures depend on every byte.
struct URLEncodingTests {
    /// Every ASCII byte, then two- three- and four-byte UTF-8.
    static let sample = String(decoding: (0...0x7F).map { UInt8($0) }, as: UTF8.self) + "é€😀ÿ"

    @Test func rfc3986() {
        #expect(URLEncoding.rfc3986(Self.sample) == "%00%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13%14%15%16%17%18%19%1A%1B%1C%1D%1E%1F%20%21%22%23%24%25%26%27%28%29%2A%2B%2C-.%2F0123456789%3A%3B%3C%3D%3E%3F%40ABCDEFGHIJKLMNOPQRSTUVWXYZ%5B%5C%5D%5E_%60abcdefghijklmnopqrstuvwxyz%7B%7C%7D~%7F%C3%A9%E2%82%AC%F0%9F%98%80%C3%BF")
        #expect(URLEncoding.query([("a b", "c&d"), ("e", "")]) == "a%20b=c%26d&e=")
    }

    @Test func uriComponent() {
        #expect(URLEncoding.uriComponent(Self.sample) == "%00%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13%14%15%16%17%18%19%1A%1B%1C%1D%1E%1F%20!%22%23%24%25%26'()*%2B%2C-.%2F0123456789%3A%3B%3C%3D%3E%3F%40ABCDEFGHIJKLMNOPQRSTUVWXYZ%5B%5C%5D%5E_%60abcdefghijklmnopqrstuvwxyz%7B%7C%7D~%7F%C3%A9%E2%82%AC%F0%9F%98%80%C3%BF")
    }

    @Test func form() {
        #expect(URLEncoding.form(Self.sample) == "%00%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13%14%15%16%17%18%19%1A%1B%1C%1D%1E%1F+%21%22%23%24%25%26%27%28%29*%2B%2C-.%2F0123456789%3A%3B%3C%3D%3E%3F%40ABCDEFGHIJKLMNOPQRSTUVWXYZ%5B%5C%5D%5E_%60abcdefghijklmnopqrstuvwxyz%7B%7C%7D%7E%7F%C3%A9%E2%82%AC%F0%9F%98%80%C3%BF")
        #expect(URLEncoding.form([("user name", "a+b@c"), ("x", "1")]) == "user+name=a%2Bb%40c&x=1")
    }

    @Test func decode() {
        #expect(URLEncoding.decode("a+b%20c%C3%A9") == "a b cé")
        #expect(URLEncoding.decode("100%") == "100%")
        #expect(URLEncoding.decode(URLEncoding.form(Self.sample)) == Self.sample)
    }
}
