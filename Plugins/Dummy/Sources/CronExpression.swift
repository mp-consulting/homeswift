import Foundation

/// A cron expression of five fields (minute hour day-of-month month day-of-week) or six with seconds first, as the
/// Homebridge plugin's schedules take them: `*`, lists, ranges, steps, month and day names, day 0 and 7 for Sunday, and
/// the presets (`@daily`, `@weekdays`…). When both day fields are restricted, either matching is enough, as in cron.
/// Unlike the bridge's `CronSchedule` (minutes), it fires on the second.
struct CronExpression: Sendable, Equatable {
    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    let seconds: Set<Int>
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    let anyDay: Bool
    let anyWeekday: Bool

    static let presets: [String: String] = [
        "@secondly": "* * * * * *",
        "@minutely": "0 * * * * *",
        "@hourly": "0 0 * * * *",
        "@daily": "0 0 0 * * *",
        "@weekly": "0 0 0 * * 0",
        "@weekdays": "0 0 0 * * 1-5",
        "@weekends": "0 0 0 * * 0,6",
        "@monthly": "0 0 0 1 * *",
        "@yearly": "0 0 0 1 1 *",
        "@annually": "0 0 0 1 1 *",
    ]

    init(_ expression: String) throws {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        let text = Self.presets[trimmed.lowercased()] ?? trimmed
        var fields = text.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
        if fields.count == 5 { fields.insert("0", at: 0) }
        guard fields.count == 6 else { throw ParseError(description: "\(expression) does not have five or six fields") }
        let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        seconds = try Self.field(fields[0], 0...59)
        minutes = try Self.field(fields[1], 0...59)
        hours = try Self.field(fields[2], 0...23)
        days = try Self.field(fields[3], 1...31)
        months = try Self.field(fields[4], 1...12, names: monthNames, base: 1)
        weekdays = Set(try Self.field(fields[5], 0...7, names: dayNames, base: 0).map { $0 % 7 })
        anyDay = fields[3] == "*" || fields[3] == "?"
        anyWeekday = fields[5] == "*" || fields[5] == "?"
    }

    private static func field(_ text: String, _ range: ClosedRange<Int>, names: [String] = [], base: Int = 0) throws -> Set<Int> {
        func value(_ token: Substring) throws -> Int {
            if let index = names.firstIndex(of: String(token)) { return index + base }
            guard let number = Int(token), range.contains(number) else { throw ParseError(description: "\(token) is out of range") }
            return number
        }
        var result: Set<Int> = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2, !pieces[0].isEmpty else { throw ParseError(description: "\(part) is not valid") }
            var step = 1
            if pieces.count == 2 {
                guard let parsed = Int(pieces[1]), parsed > 0 else { throw ParseError(description: "\(pieces[1]) is not a step") }
                step = parsed
            }
            var span: ClosedRange<Int>
            if pieces[0] == "*" || pieces[0] == "?" {
                span = range
            } else if let dash = pieces[0].firstIndex(of: "-") {
                let low = try value(pieces[0][..<dash]), high = try value(pieces[0][pieces[0].index(after: dash)...])
                guard low <= high else { throw ParseError(description: "\(pieces[0]) is not a range") }
                span = low...high
            } else {
                let single = try value(pieces[0])
                // `5/10` starts at 5 and steps to the end of the field.
                span = pieces.count == 2 ? single...range.upperBound : single...single
            }
            result.formUnion(stride(from: span.lowerBound, through: span.upperBound, by: step))
        }
        return result
    }

    func matches(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.second, .minute, .hour, .day, .month, .weekday], from: date)
        guard let second = parts.second, let minute = parts.minute, let hour = parts.hour, let day = parts.day, let month = parts.month,
              let weekday = parts.weekday else { return false }
        guard seconds.contains(second), minutes.contains(minute), hours.contains(hour), months.contains(month) else { return false }
        let dayMatches = days.contains(day), weekdayMatches = weekdays.contains(weekday - 1)
        if anyDay && anyWeekday { return true }
        if anyDay { return weekdayMatches }
        if anyWeekday { return dayMatches }
        return dayMatches || weekdayMatches
    }

    /// The first whole second after `date` the expression matches, within about five years.
    func next(after date: Date, calendar: Calendar) -> Date? {
        var candidate = Date(timeIntervalSince1970: (date.timeIntervalSince1970 + 1).rounded(.down))
        let limit = date.addingTimeInterval(5 * 366 * 86_400)
        while candidate <= limit {
            let parts = calendar.dateComponents([.second, .minute, .hour, .day, .month, .weekday], from: candidate)
            // Skip whole months, days, hours and minutes that cannot match, then seconds.
            if let month = parts.month, !months.contains(month) {
                guard let start = calendar.dateInterval(of: .month, for: candidate)?.end else { return nil }
                candidate = start
                continue
            }
            if let day = parts.day, let weekday = parts.weekday, !dayMatches(day: day, weekday: weekday) {
                guard let start = calendar.dateInterval(of: .day, for: candidate)?.end else { return nil }
                candidate = start
                continue
            }
            if let hour = parts.hour, !hours.contains(hour) {
                guard let start = calendar.dateInterval(of: .hour, for: candidate)?.end else { return nil }
                candidate = start
                continue
            }
            if let minute = parts.minute, !minutes.contains(minute) {
                guard let start = calendar.dateInterval(of: .minute, for: candidate)?.end else { return nil }
                candidate = start
                continue
            }
            if matches(candidate, calendar: calendar) { return candidate }
            candidate = candidate.addingTimeInterval(1)
        }
        return nil
    }

    private func dayMatches(day: Int, weekday: Int) -> Bool {
        let dayMatches = days.contains(day), weekdayMatches = weekdays.contains(weekday - 1)
        if anyDay && anyWeekday { return true }
        if anyDay { return weekdayMatches }
        if anyWeekday { return dayMatches }
        return dayMatches || weekdayMatches
    }
}
