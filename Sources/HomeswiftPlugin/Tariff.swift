import Foundation

/// What the home pays per kWh of electricity, or per m³ of gas or water (`kind`), from a day on (GLOSSARY.md, "Tariff"): by period of the day and the week, and optionally
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
        /// Per kWh (per m³ for gas and water), in the Tariff's currency.
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
    /// What a kWh sent back to the grid is paid, when the home is; electricity only.
    public var exportPrice: Double?
    /// What it prices: gas or water, by the m³; nil for electricity, by the kWh. Each kind has its own Tariffs.
    public var kind: MeterKind?

    public init(start: String, currency: String, periods: [Period], exportPrice: Double? = nil, kind: MeterKind? = nil) {
        self.start = start
        self.currency = currency
        self.periods = periods
        self.exportPrice = exportPrice
        self.kind = kind == .electricity ? nil : kind
    }

    /// What it prices, electricity when it says nothing.
    public var meterKind: MeterKind { kind ?? .electricity }

    /// Minutes since midnight of an `HH:mm`, 0 to 1440; nil for anything else.
    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...24).contains(hours), (0..<60).contains(minutes), hours * 60 + minutes <= 1440 else { return nil }
        return hours * 60 + minutes
    }

    /// The minutes of the week (Monday 00:00 first) and which period covers each: `-1` for none; nil when a time is not
    /// one, and with whether some minute has two periods. A period past midnight belongs to the day it starts on.
    func week() -> (periods: [Int16], overlap: Bool)? {
        var cover = [Int16](repeating: -1, count: 7 * 1440)
        var overlap = false
        for (index, period) in periods.enumerated() {
            guard let from = Self.minutes(period.from), let to = Self.minutes(period.to) else { return nil }
            for day in 1...7 where period.days.map({ $0.contains(day) }) ?? true {
                let base = (day - 1) * 1440, next = (day % 7) * 1440
                // Its spans that day: until the evening, or the evening then the next morning.
                let spans = from < to ? [base + from ..< base + to] : from == to ? [base ..< base + 1440] : [base + from ..< base + 1440, next ..< next + to]
                for span in spans {
                    for minute in span {
                        if cover[minute] >= 0 { overlap = true }
                        cover[minute] = Int16(index)
                    }
                }
            }
        }
        return (cover, overlap)
    }

    /// What is wrong with a list of Tariffs, in words a person can act on; empty when nothing is. Each needs a day, a
    /// currency and periods with times and prices; the periods of each must cover the week once, no gap, no overlap.
    public static func problems(_ tariffs: [Tariff]) -> [String] {
        var problems: [String] = []
        var starts: Set<String> = []
        for (index, tariff) in tariffs.enumerated() {
            let at = "tariffs[\(index)]"
            if EnergyCalendar.day(tariff.start) == nil { problems.append("\(at).start must be a day, YYYY-MM-DD") }
            // One Tariff a day for each kind: gas and electricity may change on the same day.
            if !starts.insert("\(tariff.meterKind.rawValue) \(tariff.start)").inserted {
                problems.append(tariff.meterKind == .electricity ? "\(at).start: another Tariff starts that day" : "\(at).start: another \(tariff.meterKind.rawValue) Tariff starts that day")
            }
            if tariff.meterKind != .electricity, tariff.exportPrice != nil { problems.append("\(at).exportPrice: only electricity is sent back") }
            if tariff.currency.count != 3 || !tariff.currency.allSatisfy({ $0.isASCII && $0.isUppercase }) {
                problems.append("\(at).currency must be a currency code, such as EUR or USD")
            }
            if let price = tariff.exportPrice, !(price.isFinite && price >= 0) { problems.append("\(at).exportPrice must be a price, 0 or more") }
            if tariff.periods.isEmpty { problems.append("\(at).periods must have a period at least") }
            for (number, period) in tariff.periods.enumerated() {
                let place = "\(at).periods[\(number)]"
                if minutes(period.from) == nil || minutes(period.to) == nil { problems.append("\(place): from and to must be times, HH:mm") }
                if !(period.price.isFinite && period.price >= 0) { problems.append("\(place).price must be a price, 0 or more") }
                if let days = period.days, days.isEmpty || !days.allSatisfy({ (1...7).contains($0) }) {
                    problems.append("\(place).days must be days of the week, 1 (Monday) to 7 (Sunday)")
                }
            }
            // Every minute of the week, once.
            guard !tariff.periods.isEmpty, let week = tariff.week() else { continue }
            if week.periods.contains(-1) { problems.append("\(at).periods leave part of the week without a price") }
            if week.overlap { problems.append("\(at).periods overlap: each moment of the week needs one price") }
        }
        return problems
    }
}

/// The Tariffs of one kind in force over time, in a time zone: what a kWh (or an m³) cost at a moment, and what one sent back was paid. Each
/// Tariff's week is worked out once, a period for every minute of it.
public struct TariffSchedule: Sendable {
    /// The Tariffs by their first moment, oldest first, each with its week (`Tariff.week`).
    let tariffs: [(start: Date, tariff: Tariff, week: [Int16])]
    let timeZone: TimeZone

    /// `kind` keeps the Tariffs of what it prices: electricity's unless told.
    public init(_ tariffs: [Tariff], kind: MeterKind = .electricity, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.timeZone = timeZone
        self.tariffs = tariffs.filter { $0.meterKind == kind }.compactMap { tariff in
            guard let start = EnergyCalendar.day(tariff.start).flatMap({ calendar.date(from: $0) }), let week = tariff.week() else { return nil }
            return (start, tariff, week.periods)
        }.sorted { $0.start < $1.start }
    }

    public var isEmpty: Bool { tariffs.isEmpty }

    /// The currency of the Tariff in force now, else the latest one's.
    public var currency: String? { (tariff(at: Date()) ?? tariffs.last?.tariff)?.currency }

    /// The Tariff in force at `date`: the one that started last before it.
    public func tariff(at date: Date) -> Tariff? { tariffs.last { $0.start <= date }?.tariff }

    /// The price of a kWh at `date` and what one sent back was paid: the Tariff that started last before it, and its
    /// period then; nil before the first Tariff or in a part of the week it gives no price.
    func price(at date: Date) -> (price: Double, exportPrice: Double?)? {
        guard let entry = tariffs.last(where: { $0.start <= date }) else { return nil }
        // The minute of the local week, Monday first: 1970-01-01 was a Thursday, the fourth day.
        let local = Int((date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))) / 60.0.rounded(.down))
        let minute = ((local + 3 * 1440) % (7 * 1440) + 7 * 1440) % (7 * 1440)
        let period = Int(entry.week[minute])
        guard period >= 0 else { return nil }
        return (entry.tariff.periods[period].price, entry.tariff.exportPrice)
    }

    /// What an hour's energy cost (`drawn` kWh) less what its export was paid (`sent` kWh), at the price of the hour's
    /// middle; nil when the hour has no price.
    public func cost(hour start: Date, drawn: Double?, sent: Double? = nil) -> Double? {
        guard let price = price(at: start.addingTimeInterval(1800)) else { return nil }
        return (drawn ?? 0) * price.price - (sent ?? 0) * (price.exportPrice ?? 0)
    }

    /// The cost of hours (kWh drawn and sent back) by the periods (days, months) that start at `starts`, oldest first,
    /// and in all; nil for a period, or the whole, with no priced hour. Hours before the first period are left out.
    public func costs(of hours: [(start: Date, drawn: Double?, sent: Double?)], in starts: [Date]) -> (periods: [Double?], total: Double?) {
        var periods = [Double?](repeating: nil, count: starts.count)
        var total: Double?
        guard let first = starts.first else { return (periods, nil) }
        for hour in hours where hour.start >= first {
            guard let cost = cost(hour: hour.start, drawn: hour.drawn, sent: hour.sent) else { continue }
            let index = EnergyCalendar.index(of: hour.start, in: starts)
            periods[index] = (periods[index] ?? 0) + cost
            total = (total ?? 0) + cost
        }
        return (periods, total)
    }
}
