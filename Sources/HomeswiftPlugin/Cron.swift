import Foundation

/// A cron expression of five fields, minute hour day-of-month month day-of-week, in this machine's time zone:
/// numbers, `*`, ranges (`1-5`), lists (`1,15`), steps (`*/15`, `0-30/10`) and the names of months and days
/// (`JAN`, `MON`). Day 0 and 7 are Sunday. As in cron, when both day fields are restricted, either matching is
/// enough. Six fields have seconds first, which are ignored (Glass UI's scenes take them; schedules run on the
/// minute). The schedule of `scheduledRestartCron` and of scene automations.
public struct CronSchedule: Sendable, Equatable {
    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    let anyDay: Bool
    let anyWeekday: Bool
    public let expression: String

    public init(_ expression: String) throws {
        var fields = expression.split(whereSeparator: \.isWhitespace).map { String($0).uppercased() }
        if fields.count == 6 { fields.removeFirst() }
        guard fields.count == 5 else { throw ParseError(description: "\"\(expression)\" is not a cron expression of five fields (minute hour day month weekday), e.g. 0 4 * * *") }
        let monthNames = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let dayNames = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        minutes = try Self.field(fields[0], 0...59, name: "minute")
        hours = try Self.field(fields[1], 0...23, name: "hour")
        days = try Self.field(fields[2], 1...31, name: "day of the month")
        months = try Self.field(fields[3], 1...12, name: "month", names: monthNames, base: 1)
        weekdays = Set(try Self.field(fields[4], 0...7, name: "day of the week", names: dayNames, base: 0).map { $0 % 7 })
        anyDay = fields[2] == "*" || fields[2] == "?"
        anyWeekday = fields[4] == "*" || fields[4] == "?"
        self.expression = expression.trimmingCharacters(in: .whitespaces)
    }

    private static func field(_ text: String, _ range: ClosedRange<Int>, name: String, names: [String] = [], base: Int = 0) throws -> Set<Int> {
        func value(_ token: Substring) throws -> Int {
            if let index = names.firstIndex(of: String(token)) { return index + base }
            guard let number = Int(token), range.contains(number) else { throw ParseError(description: "\(token) is not a valid \(name) (\(range.lowerBound)–\(range.upperBound))") }
            return number
        }
        var result: Set<Int> = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2, !pieces[0].isEmpty else { throw ParseError(description: "\(part) is not a valid \(name)") }
            var step = 1
            if pieces.count == 2 {
                guard let parsed = Int(pieces[1]), parsed > 0 else { throw ParseError(description: "\(pieces[1]) is not a valid step for the \(name)") }
                step = parsed
            }
            let span: ClosedRange<Int>
            if pieces[0] == "*" || pieces[0] == "?" {
                span = range
            } else if let dash = pieces[0].firstIndex(of: "-") {
                let low = try value(pieces[0][..<dash]), high = try value(pieces[0][pieces[0].index(after: dash)...])
                guard low <= high else { throw ParseError(description: "\(pieces[0]) is not a valid range for the \(name)") }
                span = low...high
            } else {
                let start = try value(pieces[0])
                span = start...(pieces.count == 2 ? range.upperBound : start)
            }
            result.formUnion(stride(from: span.lowerBound, through: span.upperBound, by: step))
        }
        return result
    }

    func matchesDay(_ components: DateComponents) -> Bool {
        guard let day = components.day, let month = components.month, let weekday = components.weekday, months.contains(month) else { return false }
        let dayMatches = days.contains(day), weekdayMatches = weekdays.contains(weekday - 1)
        if anyDay && anyWeekday { return true }
        if anyDay { return weekdayMatches }
        if anyWeekday { return dayMatches }
        return dayMatches || weekdayMatches
    }

    /// Whether it names this local minute.
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: date)
        guard let minute = components.minute, let hour = components.hour else { return false }
        return minutes.contains(minute) && hours.contains(hour) && matchesDay(components)
    }

    /// The first minute after `date` the expression names, within the next four years.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        var candidate = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60)
        let limit = date.addingTimeInterval(4 * 366 * 86400)
        while candidate < limit {
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: candidate)
            if !matchesDay(components) {
                guard let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: candidate)) else { return nil }
                candidate = midnight
                continue
            }
            if let hour = components.hour, !hours.contains(hour) {
                guard let start = calendar.date(from: DateComponents(year: components.year, month: components.month, day: components.day, hour: hour)),
                      let next = calendar.date(byAdding: .hour, value: 1, to: start) else { return nil }
                candidate = next
                continue
            }
            if let minute = components.minute, minutes.contains(minute) { return candidate }
            candidate = candidate.addingTimeInterval(60)
        }
        return nil
    }
}
