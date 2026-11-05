import Foundation
import HomeswiftPlugin

/// A unit's electricity use as the Daikin cloud reports it (`consumptionData`, kWh): per management point and mode
/// (`heating`, `cooling`), `d` is 24 two-hour slots, yesterday's 12 then today's; `w` is 14 days, last week's Monday to
/// Sunday then this week's; `m`, 24 months, is left out (too coarse for days). Slots not reached yet are null. The
/// slots and days are the unit's wall clock: its gateway's `timeZone`.
enum DaikinConsumption {
    /// Each two-hour slot of yesterday and today, and each day of the two weeks, summed over the unit's management
    /// points and modes: by the slot's or the day's start, in kWh. `slotEnds` is where each slot ends (two hours later
    /// on the wall clock: one or three on the days the clocks change).
    struct Totals: Sendable, Equatable {
        var slots: [Date: Double] = [:]
        var slotEnds: [Date: Date] = [:]
        var days: [Date: Double] = [:]
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
              let lastMonday = calendar.date(byAdding: .day, value: -7, to: monday) else { return totals }
        // The 24 slots' starts on the wall clock, and today's midnight ends yesterday's last one.
        let starts = [yesterday, today].flatMap { day in
            (0..<12).map { calendar.date(bySettingHour: $0 * 2, minute: 0, second: 0, of: day) }
        }
        for point in raw["managementPoints"]?.arrayValue ?? [] {
            guard let electrical = point["consumptionData"]?["value"]?["electrical"]?.objectValue else { continue }
            // Watt-hours are what the Energy section counts; any other unit is not read.
            if let unit = electrical["unit"]?.stringValue, unit != "kWh" { continue }
            for (mode, series) in electrical where mode != "unit" {
                for (index, value) in (series["d"]?.arrayValue ?? []).prefix(24).enumerated() {
                    guard let kWh = value.doubleValue, kWh.isFinite, kWh >= 0, let start = starts[index] else { continue }
                    let end = index == 11 ? today : index == 23 ? tomorrow : starts[index + 1]
                    guard let end, end > start else { continue }
                    totals.slots[start, default: 0] += kWh
                    totals.slotEnds[start] = end
                }
                for (index, value) in (series["w"]?.arrayValue ?? []).prefix(14).enumerated() {
                    guard let kWh = value.doubleValue, kWh.isFinite, kWh >= 0,
                          let day = calendar.date(byAdding: .day, value: index, to: lastMonday) else { continue }
                    totals.days[day, default: 0] += kWh
                }
            }
        }
        return totals
    }

    /// The hours the Energy section takes as the home's use, in watt-hours, and the days they cover from the slots:
    /// yesterday's and today's two-hour slots split evenly over their hours, the other days of the two weeks over
    /// their 24; only slots and days already over. A day in `detailed` (its slots were imported before) is left out
    /// of the days: its hours in the Energy section are already the slots', which a flat day would replace.
    static func hours(_ totals: Totals, now: Date, calendar: Calendar, detailed: Set<Date> = []) -> (hours: [Date: Double], detailed: Set<Date>) {
        var hours: [Date: Double] = [:]
        var covered: Set<Date> = []
        for (start, kWh) in totals.slots {
            guard let end = totals.slotEnds[start], end <= now else { continue }
            covered.insert(calendar.startOfDay(for: start))
            spread(kWh * 1000, from: start, to: end, into: &hours)
        }
        let skipped = detailed.union(Set(totals.slots.keys.map { calendar.startOfDay(for: $0) }))
        for (day, kWh) in totals.days where !skipped.contains(day) {
            guard let end = calendar.date(byAdding: .day, value: 1, to: day), end <= now else { continue }
            spread(kWh * 1000, from: day, to: end, into: &hours)
        }
        return (hours, covered)
    }

    /// `wh` split evenly over the hours from `start` to `end` (23 or 25 in a day the clocks change).
    private static func spread(_ wh: Double, from start: Date, to end: Date, into hours: inout [Date: Double]) {
        let count = max(Int((end.timeIntervalSince(start) / 3600).rounded()), 1)
        for offset in 0..<count {
            hours[start.addingTimeInterval(Double(offset) * 3600), default: 0] += wh / Double(count)
        }
    }

    /// The hours as the Energy section's imports, in order.
    static func imports(_ hours: [Date: Double]) -> [EnergyHourImport] {
        hours.keys.sorted().map { EnergyHourImport(start: $0, flows: EnergyFlows(home: hours[$0])) }
    }

    /// Today's kWh so far: the slots of today.
    static func today(_ totals: Totals, now: Date, calendar: Calendar) -> Double {
        let today = calendar.startOfDay(for: now)
        return totals.slots.filter { calendar.startOfDay(for: $0.key) == today }.values.reduce(0, +)
    }
}
