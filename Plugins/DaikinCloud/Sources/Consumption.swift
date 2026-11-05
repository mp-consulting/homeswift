import Foundation
import HomeswiftPlugin

/// A unit's electricity use as the Daikin cloud reports it (`consumptionData`, kWh): per management point and mode
/// (`heating`, `cooling`), `d` is 24 two-hour slots, yesterday's 12 then today's; `w` is 14 days, last week's Monday to
/// Sunday then this week's; `m`, 24 months, is left out (too coarse for days). Slots not reached yet are null.
enum DaikinConsumption {
    /// Each two-hour slot of yesterday and today, and each day of the two weeks, summed over the unit's management
    /// points and modes: by the slot's or the day's start, in kWh.
    struct Totals: Sendable, Equatable {
        var slots: [Date: Double] = [:]
        var days: [Date: Double] = [:]
    }

    static func totals(of raw: JSONValue, now: Date, calendar: Calendar) -> Totals {
        var totals = Totals()
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return totals }
        // This week's Monday: the week the cloud counts from (ISO weeks).
        let weekday = calendar.component(.weekday, from: today)
        let sinceMonday = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -sinceMonday, to: today),
              let lastMonday = calendar.date(byAdding: .day, value: -7, to: monday) else { return totals }
        for point in raw["managementPoints"]?.arrayValue ?? [] {
            guard let electrical = point["consumptionData"]?["value"]?["electrical"]?.objectValue else { continue }
            // Watt-hours are what the Energy section counts; any other unit is not read.
            if let unit = point["consumptionData"]?["value"]?["electrical"]?["unit"]?.stringValue, unit != "kWh" { continue }
            for (mode, series) in electrical where mode != "unit" {
                for (index, value) in (series["d"]?.arrayValue ?? []).prefix(24).enumerated() {
                    guard let kWh = value.doubleValue, kWh.isFinite, kWh >= 0 else { continue }
                    let day = index < 12 ? yesterday : today
                    guard let start = calendar.date(byAdding: .hour, value: (index % 12) * 2, to: day) else { continue }
                    totals.slots[start, default: 0] += kWh
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

    /// The hours the Energy section takes as the home's use, in watt-hours: yesterday's and today's two-hour slots split
    /// evenly over their two hours, the other days of the two weeks over their 24; only slots and days already over.
    static func hours(_ totals: Totals, now: Date, calendar: Calendar) -> [EnergyHourImport] {
        var hours: [Date: Double] = [:]
        let covered = Set(totals.slots.keys.map { calendar.startOfDay(for: $0) })
        for (start, kWh) in totals.slots {
            guard let end = calendar.date(byAdding: .hour, value: 2, to: start), end <= now else { continue }
            for offset in 0..<2 {
                if let hour = calendar.date(byAdding: .hour, value: offset, to: start) { hours[hour, default: 0] += kWh * 1000 / 2 }
            }
        }
        for (day, kWh) in totals.days where !covered.contains(day) {
            guard let end = calendar.date(byAdding: .day, value: 1, to: day), end <= now else { continue }
            let count = calendar.dateComponents([.hour], from: day, to: end).hour ?? 24
            for offset in 0..<max(count, 1) {
                if let hour = calendar.date(byAdding: .hour, value: offset, to: day) { hours[hour, default: 0] += kWh * 1000 / Double(max(count, 1)) }
            }
        }
        return hours.keys.sorted().map { EnergyHourImport(start: $0, flows: EnergyFlows(home: hours[$0])) }
    }

    /// Today's kWh so far: the slots of today.
    static func today(_ totals: Totals, now: Date, calendar: Calendar) -> Double {
        let today = calendar.startOfDay(for: now)
        return totals.slots.filter { calendar.startOfDay(for: $0.key) == today }.values.reduce(0, +)
    }
}
