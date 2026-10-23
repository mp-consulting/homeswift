import Foundation

/// ISO 8601 times in UTC, `2026-10-21T10:00:00Z`: the text of `Date.formatted(.iso8601)`, without its format
/// style machinery, which cost several microseconds a line on logs of thousands of lines.
public enum Timestamp {
    /// `2026-10-21T10:00:00Z`, or with `separator: " "` `2026-10-21 10:00:00Z`; seconds truncated.
    public static func iso8601(_ date: Date, separator: UInt8 = UInt8(ascii: "T")) -> String {
        let seconds = Int(floor(date.timeIntervalSince1970))
        let (days, time) = seconds.quotientAndRemainder(dividingBy: 86_400)
        let (day, second) = time < 0 ? (days - 1, time + 86_400) : (days, time)
        // The civil date of a day count (Howard Hinnant's days_from_civil, inverted): no calendar, no libc call.
        let shifted = day + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let monthDay = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        guard (0...9999).contains(year) else { return date.formatted(.iso8601.dateTimeSeparator(separator == UInt8(ascii: "T") ? .standard : .space)) }
        // Twenty bytes written straight into the string: no array to make first.
        return String(unsafeUninitializedCapacity: 20) { bytes in
            func put(_ value: Int, _ at: Int, digits: Int) {
                var value = value
                for index in stride(from: at + digits - 1, through: at, by: -1) {
                    bytes[index] = UInt8(ascii: "0") + UInt8(value % 10)
                    value /= 10
                }
            }
            put(year, 0, digits: 4)
            bytes[4] = UInt8(ascii: "-")
            put(month, 5, digits: 2)
            bytes[7] = UInt8(ascii: "-")
            put(monthDay, 8, digits: 2)
            bytes[10] = separator
            put(second / 3600, 11, digits: 2)
            bytes[13] = UInt8(ascii: ":")
            put(second / 60 % 60, 14, digits: 2)
            bytes[16] = UInt8(ascii: ":")
            put(second % 60, 17, digits: 2)
            bytes[19] = UInt8(ascii: "Z")
            return 20
        }
    }
}
