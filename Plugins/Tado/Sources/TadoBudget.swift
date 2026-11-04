import Foundation
import HomeswiftPlugin

// tado allows an account without a subscription about 100 requests a day (docs/clean-room/Tado.md, section 5.20). The
// Homebridge plugin counted its requests and polled every 5 minutes whatever the count; this one counts them the same
// way, and polls as often as the day's budget allows unless the block sets `polling`.

/// The requests of one account today: the API's and the login server's. The day is Europe/Berlin's, as tado's; the
/// count is kept in `tado-api-<h>.json` (`counterData`, as the Homebridge plugin wrote it).
actor RequestCounter {
    struct Stored: Codable, Sendable {
        struct CounterData: Codable, Sendable {
            var counter: Int
            var counterTimestamp: String
            /// The API's part of `counter` (the rest is the login server's).
            var apiCounter: Int?
        }
        var counterData: CounterData
    }

    private let file: JSONFile<Stored>?
    private let now: @Sendable () -> Date
    private(set) var api = 0
    private(set) var login = 0
    private var day: String
    private var lastSaved = Date.distantPast

    init(file: JSONFile<Stored>?, now: @escaping @Sendable () -> Date = Date.init) {
        self.file = file
        self.now = now
        day = Self.day(of: now())
        if let stored = file?.load(), let date = ISO8601DateFormatter().date(from: stored.counterData.counterTimestamp), Self.day(of: date) == day {
            api = stored.counterData.apiCounter ?? stored.counterData.counter
            login = max(stored.counterData.counter - api, 0)
        }
    }

    static let berlin = TimeZone(identifier: "Europe/Berlin") ?? TimeZone(secondsFromGMT: 3600)!

    static let berlinCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        return calendar
    }()

    static func day(of date: Date) -> String { day(of: date, calendar: berlinCalendar) }

    /// `yyyy-MM-dd` in a calendar.
    static func day(of date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func count(login isLogin: Bool) {
        rollOver()
        if isLogin { login += 1 } else { api += 1 }
        if now().timeIntervalSince(lastSaved) >= 300 { save() }
    }

    /// Today's counts.
    func today() -> (api: Int, login: Int) {
        rollOver()
        return (api, login)
    }

    func save() {
        lastSaved = now()
        try? file?.save(Stored(counterData: .init(counter: api + login, counterTimestamp: ISO8601DateFormatter().string(from: now()), apiCounter: api)))
    }

    private func rollOver() {
        let today = Self.day(of: now())
        guard today != day else { return }
        day = today
        api = 0
        login = 0
    }
}

/// How often a home polls so that a day of polling fits the account's daily limit.
enum TadoBudget {
    /// tado's limit for an account without a subscription.
    static let defaultDailyLimit = 100
    /// The shortest interval the plugin picks itself (the Homebridge plugin's default).
    static let defaultFloor = 300
    /// The block's shortest `polling`.
    static let minimumPolling = 30
    /// Requests made every `slowInterval` rather than every poll: the zone list (batteries, open-window detection).
    static let slowInterval: TimeInterval = 6 * 3600

    /// What a day leaves for polling once writes and token refreshes are put aside: a fifth, 10 at least.
    static func pollingBudget(dailyLimit: Int, slowRequestsPerDay: Int) -> Int {
        max(dailyLimit - max(dailyLimit / 5, 10) - slowRequestsPerDay, 1)
    }

    /// The interval, in seconds, that spends `pollingBudget` on `requestsPerPoll` a poll; `defaultFloor` at least.
    static func interval(requestsPerPoll: Int, slowRequestsPerDay: Int, dailyLimit: Int) -> Int {
        let budget = pollingBudget(dailyLimit: dailyLimit, slowRequestsPerDay: slowRequestsPerDay)
        let needed = Int((86400 * Double(max(requestsPerPoll, 1)) / Double(budget)).rounded(.up))
        return max(needed, defaultFloor)
    }

    /// The requests a day of polling every `interval` seconds makes.
    static func requestsPerDay(requestsPerPoll: Int, slowRequestsPerDay: Int, interval: Int) -> Int {
        Int((86400 / Double(max(interval, 1))).rounded(.up)) * requestsPerPoll + slowRequestsPerDay
    }
}
