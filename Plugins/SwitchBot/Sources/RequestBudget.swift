import Foundation
import HomeswiftPlugin

/// The account's requests of the day. SwitchBot allows `limit` (10,000) a day and answers 401 past it, so polls stop
/// while fewer than `reserve` (1,000) are left, keeping those for commands. Every request counts; the count starts again
/// at midnight (UTC, or local time with `dailyApiResetLocalMidnight`), and survives a restart in `file`.
actor RequestBudget {
    struct Day: Codable, Equatable {
        var day: String
        var count: Int
    }

    let limit: Int
    let reserve: Int
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let file: JSONFile<Day>?
    private var current: Day
    private var warned = false
    private var unsaved = 0

    init(limit: Int, reserve: Int, localMidnight: Bool, file: JSONFile<Day>?, now: @escaping @Sendable () -> Date = Date.init) {
        self.limit = max(limit, 1000)
        self.reserve = min(max(reserve, 0), self.limit - 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = localMidnight ? .current : TimeZone(identifier: "UTC")!
        self.calendar = calendar
        self.now = now
        self.file = file
        let today = Self.day(now(), calendar)
        let saved = file?.load()
        current = saved?.day == today ? saved! : Day(day: today, count: 0)
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private func rollOver() {
        let today = Self.day(now(), calendar)
        if current.day != today {
            current = Day(day: today, count: 0)
            warned = false
        }
    }

    /// The requests made today.
    var used: Int {
        rollOver()
        return current.count
    }

    /// Counts a request; saved every 20, so a restart loses few.
    func record() {
        rollOver()
        current.count += 1
        unsaved += 1
        if unsaved >= 20 { save() }
    }

    func save() {
        unsaved = 0
        try? file?.save(current)
    }

    /// Whether a poll may run now, leaving the reserve for commands. The first refusal of a day says so in the log
    /// (`warn` is called once).
    func allowsPoll(warn: (Int) -> Void = { _ in }) -> Bool {
        rollOver()
        guard current.count + reserve >= limit else { return true }
        if !warned {
            warned = true
            warn(current.count)
        }
        return false
    }

    /// The seconds between polls that keep `devices` polls of one request each within the day's polling share (`limit − reserve`).
    static func pollSeconds(devices: Int, limit: Int, reserve: Int) -> Double {
        Double(max(devices, 0)) * 86_400 / Double(max(limit - reserve, 1))
    }
}
