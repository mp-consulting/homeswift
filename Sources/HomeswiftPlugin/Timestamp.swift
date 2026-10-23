import Foundation

/// ISO 8601 times in UTC, `2026-10-21T10:00:00Z`: the text of `Date.formatted(.iso8601)`, without its format
/// style machinery, which cost several microseconds a line on logs of thousands of lines.
public enum Timestamp {
    /// `2026-10-21T10:00:00Z`, or with `separator: " "` `2026-10-21 10:00:00Z`; seconds truncated.
    public static func iso8601(_ date: Date, separator: UInt8 = UInt8(ascii: "T")) -> String {
        var seconds = time_t(floor(date.timeIntervalSince1970))
        var parts = tm()
        gmtime_r(&seconds, &parts)
        var bytes = [UInt8](repeating: 0, count: 20)
        func put(_ value: Int, _ at: Int, digits: Int) {
            var value = value
            for index in stride(from: at + digits - 1, through: at, by: -1) {
                bytes[index] = UInt8(ascii: "0") + UInt8(value % 10)
                value /= 10
            }
        }
        let year = Int(parts.tm_year) + 1900
        guard (0...9999).contains(year) else { return date.formatted(.iso8601.dateTimeSeparator(separator == UInt8(ascii: "T") ? .standard : .space)) }
        put(year, 0, digits: 4)
        bytes[4] = UInt8(ascii: "-")
        put(Int(parts.tm_mon) + 1, 5, digits: 2)
        bytes[7] = UInt8(ascii: "-")
        put(Int(parts.tm_mday), 8, digits: 2)
        bytes[10] = separator
        put(Int(parts.tm_hour), 11, digits: 2)
        bytes[13] = UInt8(ascii: ":")
        put(Int(parts.tm_min), 14, digits: 2)
        bytes[16] = UInt8(ascii: ":")
        put(Int(parts.tm_sec), 17, digits: 2)
        bytes[19] = UInt8(ascii: "Z")
        return String(decoding: bytes, as: UTF8.self)
    }
}
