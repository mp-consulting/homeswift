import Foundation

/// What the home pays per kWh from a day on (GLOSSARY.md, "Tariff"): by period of the day and the week, and optionally
/// what it is paid for the energy it sends back, in one currency. Kept in config.json's bridge block as `tariffs`, oldest
/// first; changing the price starts a new Tariff, so past ones keep theirs (docs/adr/0004-meters-and-consumption-history.md).
///
/// ```json
/// { "start": "2026-02-01", "currency": "EUR", "exportPrice": 0.04,
///   "periods": [{ "name": "Off-peak", "from": "22:00", "to": "06:00", "price": 0.1696 },
///               { "name": "Peak", "from": "06:00", "to": "22:00", "price": 0.2146 }] }
/// ```
public struct Tariff: Sendable, Equatable, Codable {
    /// A part of the week at one price: from `from` to `to` (HH:mm, `24:00` for midnight at the end; a `to` before
    /// `from` runs past midnight), on `days` (1 Monday to 7 Sunday; every day when left out).
    public struct Period: Sendable, Equatable, Codable {
        public var name: String?
        public var from: String
        public var to: String
        public var days: [Int]?
        /// Per kWh, in the Tariff's currency.
        public var price: Double

        public init(name: String? = nil, from: String, to: String, days: [Int]? = nil, price: Double) {
            self.name = name
            self.from = from
            self.to = to
            self.days = days
            self.price = price
        }
    }

    /// The first day it applies, YYYY-MM-DD, in the bridge's time zone.
    public var start: String
    /// An ISO 4217 code: EUR, USD, GBP…
    public var currency: String
    public var periods: [Period]
    /// What a kWh sent back to the grid is paid, when the home is.
    public var exportPrice: Double?

    public init(start: String, currency: String, periods: [Period], exportPrice: Double? = nil) {
        self.start = start
        self.currency = currency
        self.periods = periods
        self.exportPrice = exportPrice
    }

    /// Minutes since midnight of an `HH:mm`, 0 to 1440; nil for anything else.
    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...24).contains(hours), (0..<60).contains(minutes), hours * 60 + minutes <= 1440 else { return nil }
        return hours * 60 + minutes
    }

    /// Whether `period` covers minute `minute` (0 to 1439) of weekday `day` (1 Monday to 7 Sunday). A period past
    /// midnight belongs to the day it starts on.
    static func covers(_ period: Period, day: Int, minute: Int) -> Bool {
        guard let from = minutes(period.from), let to = minutes(period.to) else { return false }
        let onDay = { (day: Int) in period.days.map { $0.contains(day) } ?? true }
        if from < to { return onDay(day) && minute >= from && minute < to }
        if from == to { return onDay(day) }
        // Past midnight: the evening of its own day, the morning of the day after.
        return (onDay(day) && minute >= from) || (onDay(day == 1 ? 7 : day - 1) && minute < to)
    }

    /// What is wrong with a list of Tariffs, in words a person can act on; empty when nothing is. Each needs a day, a
    /// currency and periods with times and prices; the periods of each must cover the week once, no gap, no overlap.
    public static func problems(_ tariffs: [Tariff]) -> [String] {
        var problems: [String] = []
        var starts: Set<String> = []
        for (index, tariff) in tariffs.enumerated() {
            let at = "tariffs[\(index)]"
            if day(tariff.start) == nil { problems.append("\(at).start must be a day, YYYY-MM-DD") }
            if !starts.insert(tariff.start).inserted { problems.append("\(at).start: another Tariff starts that day") }
            if tariff.currency.count != 3 || !tariff.currency.allSatisfy({ $0.isASCII && $0.isUppercase }) {
                problems.append("\(at).currency must be a currency code, such as EUR or USD")
            }
            if let price = tariff.exportPrice, !(price.isFinite && price >= 0) { problems.append("\(at).exportPrice must be a price, 0 or more") }
            if tariff.periods.isEmpty { problems.append("\(at).periods must have a period at least") }
            var timesKnown = true
            for (number, period) in tariff.periods.enumerated() {
                let place = "\(at).periods[\(number)]"
                if minutes(period.from) == nil || minutes(period.to) == nil { problems.append("\(place): from and to must be times, HH:mm"); timesKnown = false }
                if !(period.price.isFinite && period.price >= 0) { problems.append("\(place).price must be a price, 0 or more") }
                if let days = period.days, days.isEmpty || !days.allSatisfy({ (1...7).contains($0) }) {
                    problems.append("\(place).days must be days of the week, 1 (Monday) to 7 (Sunday)")
                }
            }
            guard timesKnown, !tariff.periods.isEmpty else { continue }
            // Every minute of the week, once.
            var gap = false, overlap = false
            for day in 1...7 {
                for minute in 0..<1440 {
                    let count = tariff.periods.filter { covers($0, day: day, minute: minute) }.count
                    if count == 0 { gap = true } else if count > 1 { overlap = true }
                }
            }
            if gap { problems.append("\(at).periods leave part of the week without a price") }
            if overlap { problems.append("\(at).periods overlap: each moment of the week needs one price") }
        }
        return problems
    }

    /// A YYYY-MM-DD as its parts; nil for anything else.
    static func day(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, text.count == 10, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }
}

/// The Tariffs in force over time, in a time zone: what a kWh cost at a moment, and what one sent back was paid.
public struct TariffSchedule: Sendable {
    public struct Price: Sendable, Equatable {
        public var price: Double
        public var exportPrice: Double?
        public var currency: String
    }

    /// The Tariffs by their first moment, oldest first.
    let tariffs: [(start: Date, tariff: Tariff)]
    let calendar: Calendar

    public init(_ tariffs: [Tariff], timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        self.calendar = calendar
        self.tariffs = tariffs.compactMap { tariff in
            Tariff.day(tariff.start).flatMap { calendar.date(from: $0) }.map { ($0, tariff) }
        }.sorted { $0.start < $1.start }
    }

    public var isEmpty: Bool { tariffs.isEmpty }

    /// The currency of the Tariff in force now, else the latest one's.
    public var currency: String? { (tariffs.last { $0.start <= Date() } ?? tariffs.last)?.tariff.currency }

    /// The Tariff in force at `date`: the one that started last before it.
    public func tariff(at date: Date) -> Tariff? { tariffs.last { $0.start <= date }?.tariff }

    /// The price at `date`: the Tariff that started last before it, and its period then; nil before the first Tariff or
    /// in a part of the week it gives no price.
    public func price(at date: Date) -> Price? {
        guard let tariff = tariff(at: date) else { return nil }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        // Calendar's weekdays: 1 Sunday to 7 Saturday; the Tariff's: 1 Monday to 7 Sunday.
        let day = ((parts.weekday ?? 1) + 5) % 7 + 1
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard let period = tariff.periods.first(where: { Tariff.covers($0, day: day, minute: minute) }) else { return nil }
        return Price(price: period.price, exportPrice: tariff.exportPrice, currency: tariff.currency)
    }

    /// What an hour's energy cost (`drawn` kWh) less what its export was paid (`sent` kWh), at the price of the hour's
    /// middle; nil when the hour has no price.
    public func cost(hour start: Date, drawn: Double?, sent: Double? = nil) -> Double? {
        guard let price = price(at: start.addingTimeInterval(1800)) else { return nil }
        return (drawn ?? 0) * price.price - (sent ?? 0) * (price.exportPrice ?? 0)
    }
}
