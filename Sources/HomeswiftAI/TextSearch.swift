import Foundation

/// Substring tests for text that is nearly always ASCII, the shape of log lines: byte by byte, without the
/// allocations of `lowercased()` or the cost of a regular expression.
public enum TextSearch {
    /// Whether every byte of the text is ASCII, which makes the byte-wise tests exact.
    public static func isASCII(_ text: String) -> Bool {
        text.utf8.withContiguousStorageIfAvailable { $0.allSatisfy { $0 < 0x80 } } ?? text.utf8.allSatisfy { $0 < 0x80 }
    }

    /// Whether `needle` occurs in `text`, ignoring case: ASCII case for ASCII text, Foundation's case-insensitive
    /// search otherwise.
    public static func contains(_ text: String, caseless needle: String) -> Bool {
        if needle.isEmpty { return true }
        guard isASCII(text), isASCII(needle) else { return text.range(of: needle, options: .caseInsensitive) != nil }
        let lowered = needle.utf8.map(lower)
        return withBytes(text) { find(lowered, in: $0, caseless: true) }
    }

    /// An ASCII needle prepared once, for a search repeated over many lines: no bytes to copy per line.
    public struct Needle: Sendable {
        let bytes: [UInt8]
        let caseless: Bool

        /// `text` is ASCII; `caseless` ignores ASCII case.
        public init(_ text: String, caseless: Bool = false) {
            self.caseless = caseless
            bytes = caseless ? text.utf8.map(TextSearch.lower) : Array(text.utf8)
        }
    }

    /// Whether the needle occurs in the text, byte by byte: exact for ASCII text.
    public static func contains(_ text: String, _ needle: Needle) -> Bool {
        withBytes(text) { find(needle.bytes, in: $0, caseless: needle.caseless) }
    }

    /// Whether ASCII `needle` occurs in `text` exactly.
    public static func contains(_ text: String, ascii needle: String) -> Bool {
        let bytes = Array(needle.utf8)
        return withBytes(text) { find(bytes, in: $0, caseless: false) }
    }

    /// Whether any of these ASCII needles occurs in the text, ignoring ASCII case, byte by byte whatever the text: a
    /// UTF-8 text's other bytes never equal an ASCII one, so text with an accent or an emoji (a log line) is searched
    /// in place too, not through Foundation. Only ASCII letters fold.
    public static func containsAny(_ text: String, asciiCaseless needles: [String]) -> Bool {
        let lowered = needles.map { $0.utf8.map(lower) }
        return withBytes(text) { bytes in lowered.contains { find($0, in: bytes, caseless: true) } }
    }

    /// Whether any of these lower-case ASCII needles occurs in ASCII text, ignoring case.
    static func containsAny(_ text: String, caseless needles: [[UInt8]]) -> Bool {
        withBytes(text) { bytes in needles.contains { find($0, in: bytes, caseless: true) } }
    }

    static func withBytes<T>(_ text: String, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        if let result = text.utf8.withContiguousStorageIfAvailable(body) { return result }
        return Array(text.utf8).withUnsafeBufferPointer(body)
    }

    @inline(__always) static func lower(_ byte: UInt8) -> UInt8 {
        byte &- UInt8(ascii: "A") < 26 ? byte | 0x20 : byte
    }

    static func find(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, caseless: Bool) -> Bool {
        let count = needle.count
        guard count > 0 else { return true }
        guard bytes.count >= count else { return false }
        let first = needle[0]
        var start = 0
        while start <= bytes.count - count {
            if (caseless ? lower(bytes[start]) : bytes[start]) == first {
                var offset = 1
                while offset < count, (caseless ? lower(bytes[start + offset]) : bytes[start + offset]) == needle[offset] { offset += 1 }
                if offset == count { return true }
            }
            start += 1
        }
        return false
    }
}
