import Foundation
import HomeswiftPlugin

/// A unit's electricity use as the Daikin cloud reports it (`consumptionData`, kWh): per management point and mode
/// (`heating`, `cooling`), `d` is 24 two-hour slots, yesterday's 12 then today's; `w` is 14 days, last week's Monday to
/// Sunday then this week's; `m`, 24 months, is left out (too coarse for days). Slots not reached yet are null. The
/// slots and days are the unit's wall clock: its gateway's `timeZone`.
enum DaikinConsumption {
    /// Each two-hour slot of yesterday and today, and each day of the two weeks, summed over the unit's management
    /// points and modes: by the slot's or the day's start, in kWh. A slot ends two hours later on the wall clock (one or
    /// three on the days the clocks change).
    struct Totals: Sendable, Equatable {
        struct Slot: Sendable, Equatable { var kWh: Double; var end: Date }
        var slots: [Date: Slot] = [:]
        var days: [Date: Double] = [:]
        /// Each month's kWh, by its first day.
        var months: [Date: Double] = [:]
    }

    /// The unit's calendar: its gateway's `timeZone`, else the bridge's.
    static func calendar(of raw: JSONValue) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        let zones = (raw["managementPoints"]?.arrayValue ?? []).compactMap { $0["timeZone"]?["value"]?.stringValue }
        calendar.timeZone = zones.lazy.compactMap { TimeZone(identifier: $0) }.first ?? .current
        return calendar
    }

    static func totals(of raw: JSONValue, now: Date, calendar: Calendar) -> Totals {
        var totals = Totals()
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return totals }
        // This week's Monday: the week the cloud counts from (ISO weeks).
        let weekday = calendar.component(.weekday, from: today)
        let sinceMonday = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -sinceMonday, to: today),
              let lastMonday = calendar.date(byAdding: .day, value: -7, to: monday),
              let lastJanuary = calendar.date(from: DateComponents(year: calendar.component(.year, from: today) - 1, month: 1, day: 1)) else { return totals }
        // The 24 slots' bounds on the wall clock: each slot ends where the next starts, today's midnight included.
        let bounds = [yesterday, today].flatMap { day in
            (0..<12).map { calendar.date(bySettingHour: $0 * 2, minute: 0, second: 0, of: day) }
        } + [tomorrow]
        for point in raw["managementPoints"]?.arrayValue ?? [] {
            guard let electrical = point["consumptionData"]?["value"]?["electrical"]?.objectValue else { continue }
            // Watt-hours are what the Energy section counts; any other unit is not read.
            if let unit = electrical["unit"]?.stringValue, unit != "kWh" { continue }
            for (mode, series) in electrical where mode != "unit" {
                for (index, value) in (series["d"]?.arrayValue ?? []).prefix(24).enumerated() {
                    guard let kWh = value.doubleValue, kWh.isFinite, kWh >= 0,
                          let start = bounds[index], let end = bounds[index + 1], end > start else { continue }
                    totals.slots[start, default: .init(kWh: 0, end: end)].kWh += kWh
                }
                for (index, value) in (series["w"]?.arrayValue ?? []).prefix(14).enumerated() {
                    guard let kWh = value.doubleValue, kWh.isFinite, kWh >= 0,
                          let day = calendar.date(byAdding: .day, value: index, to: lastMonday) else { continue }
                    totals.days[day, default: 0] += kWh
                }
                for (index, value) in (series["m"]?.arrayValue ?? []).prefix(24).enumerated() {
                    guard let kWh = value.doubleValue, kWh.isFinite, kWh >= 0,
                          let month = calendar.date(byAdding: .month, value: index, to: lastJanuary), month <= today else { continue }
                    totals.months[month, default: 0] += kWh
                }
            }
        }
        return totals
    }

    /// The hours of the unit's Meter, in watt-hours, and the days they cover from the slots:
    /// yesterday's and today's two-hour slots split evenly over their hours, the other days of the two weeks over
    /// their 24; only slots and days already over. A day in `detailed` (its slots were imported before) is left out
    /// of the days: its hours in the Energy section are already the slots', which a flat day would replace.
    static func hours(_ totals: Totals, now: Date, calendar: Calendar, detailed: Set<Date> = []) -> (hours: [Date: Double], detailed: Set<Date>) {
        var hours: [Date: Double] = [:]
        var covered: Set<Date> = []
        for (start, slot) in totals.slots where slot.end <= now {
            covered.insert(calendar.startOfDay(for: start))
            spread(slot.kWh * 1000, from: start, to: slot.end, into: &hours)
        }
        let skipped = detailed.union(Set(totals.slots.keys.map { calendar.startOfDay(for: $0) }))
        for (day, kWh) in totals.days where !skipped.contains(day) {
            guard let end = calendar.date(byAdding: .day, value: 1, to: day), end <= now else { continue }
            spread(kWh * 1000, from: day, to: end, into: &hours)
        }
        return (hours, covered)
    }

    /// The hours of the months before the two weeks' days, in watt-hours: each month's use spread evenly over its days
    /// (and each day over its hours), the month the days start in over its days before them, less what those days used.
    /// A month without use adds nothing. Coarse, but what the cloud keeps of the unit's past: up to two years.
    static func monthHours(_ totals: Totals, now: Date, calendar: Calendar) -> [Date: Double] {
        guard let first = totals.days.keys.min() else { return [:] }
        var hours: [Date: Double] = [:]
        for (month, kWh) in totals.months where month < first && kWh > 0 {
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { continue }
            // The month's days the two weeks do not have, and what the ones they have used.
            let end = min(next, first)
            let known = totals.days.filter { $0.key >= month && $0.key < next }.values.reduce(0, +)
            let rest = max(kWh - known, 0)
            var days: [Date] = []
            var day = month
            while day < end {
                days.append(day)
                guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = following
            }
            guard !days.isEmpty, rest > 0 else { continue }
            for day in days {
                guard let following = calendar.date(byAdding: .day, value: 1, to: day), following <= now else { continue }
                spread(rest * 1000 / Double(days.count), from: day, to: following, into: &hours)
            }
        }
        return hours
    }

    /// `wh` split evenly over the hours from `start` to `end` (23 or 25 in a day the clocks change).
    private static func spread(_ wh: Double, from start: Date, to end: Date, into hours: inout [Date: Double]) {
        let count = max(Int((end.timeIntervalSince(start) / 3600).rounded()), 1)
        for offset in 0..<count {
            hours[start.addingTimeInterval(Double(offset) * 3600), default: 0] += wh / Double(count)
        }
    }

    /// The hours as the unit's Meter's imports (watt-hours drawn), in order.
    static func imports(_ hours: [Date: Double]) -> [MeterHourImport] {
        hours.keys.sorted().map { MeterHourImport(start: $0, consumption: hours[$0]) }
    }

    /// Today's kWh so far: the slots of today.
    static func today(_ totals: Totals, now: Date, calendar: Calendar) -> Double {
        let today = calendar.startOfDay(for: now)
        return totals.slots.filter { calendar.startOfDay(for: $0.key) == today }.values.reduce(0) { $0 + $1.kWh }
    }
}
