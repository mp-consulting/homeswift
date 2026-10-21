import Foundation

/// Random material and comparisons for secrets, shared by pairing, the MCP tokens and the UI's sessions.
public enum Secrets {
    public static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// 32 random bytes as URL-safe base64 without padding: an MCP client token, a session cookie.
    public static func randomToken() -> String {
        randomBytes(32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Equal, in a time that does not depend on where the first difference is: the whole of the longer
    /// value is always compared.
    public static func constantTimeEqual(_ lhs: some Collection<UInt8>, _ rhs: some Collection<UInt8>) -> Bool {
        var difference = lhs.count == rhs.count ? 0 : 1
        var left = lhs.makeIterator()
        var right = rhs.makeIterator()
        for _ in 0..<max(lhs.count, rhs.count) {
            difference |= Int((left.next() ?? 0) ^ (right.next() ?? 0))
        }
        return difference == 0
    }
}
