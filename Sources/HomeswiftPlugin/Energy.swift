import Foundation

/// What a recorded reading is to the Status page's Energy section: any plugin that measures a home's energy (a
/// battery system, a plug, a meter) tags its readings with a role, and the section sums them whatever plugin
/// recorded them. Powers are watts, the level a percent.
public enum EnergyRole: String, Sendable, CaseIterable, Codable {
    /// Solar production, zero or above.
    case solar
    /// What the home uses.
    case home
    /// The grid connection: positive while importing, negative while exporting.
    case grid
    /// A battery's power: positive while charging, negative while discharging.
    case battery
    /// A battery's charge, 0 to 100.
    case batteryLevel

    /// A power in watts, summed across devices; the level is drawn per device instead.
    public var isPower: Bool { self != .batteryLevel }
}

/// A recorded series' role, the device it comes from, and whether other devices report the same figure.
public struct EnergyTag: Sendable, Equatable, Codable {
    public var role: EnergyRole
    /// The device's name, as the page shows it.
    public var device: String
    /// For a figure several devices report alike (a system's home use, reported by each of its units): series with
    /// the same role and `shared` value count once, their average, instead of adding up.
    public var shared: String?

    public init(role: EnergyRole, device: String, shared: String? = nil) {
        self.role = role
        self.device = device
        self.shared = shared
    }
}

/// The Energy section's figures over a span, from the per-minute averages of the tagged series (`Metrics.energy`).
public struct EnergyReport: Sendable {
    /// One step of the power chart: each role's watts, summed across devices.
    public struct PowerPoint: Sendable, Equatable {
        public var start: Date
        public var watts: [EnergyRole: Double]
    }

    /// One device's battery level over the span.
    public struct Level: Sendable, Equatable {
        public var series: String
        public var device: String
        public var points: [(start: Date, percent: Double)]

        public static func == (a: Level, b: Level) -> Bool {
            a.series == b.series && a.device == b.device && a.points.map(\.start) == b.points.map(\.start) && a.points.map(\.percent) == b.points.map(\.percent)
        }
    }

    /// The roles some series has, the range's or not.
    public var roles: Set<EnergyRole>
    public var step: TimeInterval
    public var power: [PowerPoint]
    public var levels: [Level]
    /// Today and the days before it, newest first.
    public var days: [EnergyDay]
}

/// A day's energy in kWh, from the minutes recorded in it: each minute's average watts for one sixtieth of an hour.
/// A minute with no reading counts as nothing.
public struct EnergyDay: Sendable, Equatable {
    /// Midnight, in the time zone the days were counted in.
    public var start: Date
    /// Minutes with a power reading.
    public var minutes = 0
    public var solar = 0.0
    public var home = 0.0
    public var gridImport = 0.0
    public var gridExport = 0.0
    public var batteryCharge = 0.0
    public var batteryDischarge = 0.0
    /// The part of `home` solar covered as it was produced: each minute, the lesser of the two.
    public var homeFromSolar = 0.0

    public init(start: Date) { self.start = start }

    /// The share of the home's use solar covered as it was produced, 0 to 1; nil without home use.
    public var solarShare: Double? { home > 0 ? min(1, homeFromSolar / home) : nil }

    /// Adds a minute whose roles averaged `watts`.
    mutating func add(_ watts: [EnergyRole: Double]) {
        guard !watts.isEmpty else { return }
        let hours = 1.0 / 60, kilo = 1.0 / 1000
        minutes += 1
        if let solar = watts[.solar] { self.solar += max(0, solar) * hours * kilo }
        if let home = watts[.home] { self.home += max(0, home) * hours * kilo }
        if let grid = watts[.grid] {
            if grid > 0 { gridImport += grid * hours * kilo } else { gridExport += -grid * hours * kilo }
        }
        if let battery = watts[.battery] {
            if battery > 0 { batteryCharge += battery * hours * kilo } else { batteryDischarge += -battery * hours * kilo }
        }
        if let solar = watts[.solar], let home = watts[.home] { homeFromSolar += max(0, min(solar, home)) * hours * kilo }
    }
}

extension Metrics {
    /// Each power role's watts in each minute of `minutes`: the tagged series' averages, those of one `shared` figure
    /// averaged, then added up. Minutes with no tagged power reading are left out.
    static func energyMinutes(_ minutes: [(start: Date, values: [String: Values])], tags: [String: EnergyTag]) -> [(start: Date, watts: [EnergyRole: Double])] {
        let power = tags.filter { $0.value.role.isPower }
        guard !power.isEmpty else { return [] }
        return minutes.compactMap { minute in
            // Per role, per figure (a shared one, or the series itself): the sum and count of the averages.
            var figures: [EnergyRole: [String: (sum: Double, count: Int)]] = [:]
            for (series, tag) in power {
                guard let average = minute.values[series]?.average else { continue }
                let figure = tag.shared.map { "shared:\($0)" } ?? "series:\(series)"
                let known = figures[tag.role]?[figure] ?? (0, 0)
                figures[tag.role, default: [:]][figure] = (known.sum + average, known.count + 1)
            }
            guard !figures.isEmpty else { return nil }
            return (minute.start, figures.mapValues { $0.values.reduce(0) { $0 + $1.sum / Double($1.count) } })
        }
    }

    /// The Energy section from `from` to `to` in at most about `points` steps (the same steps as `history`), and the
    /// energy of today and the `days - 1` days before it, midnight to midnight in `timeZone`. The minute under way
    /// counts in the charts, not in the days' energy.
    public func energy(from: Date, to: Date, points: Int = 240, days: Int = 8, timeZone: TimeZone = .current) -> EnergyReport {
        let tags = energyTags
        let span = max(to.timeIntervalSince(from), 60)
        let step = max(60, (span / Double(max(points, 1)) / 60).rounded(.up) * 60)
        let base = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / step).rounded(.down) * step)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now())
        let starts = (0..<max(days, 0)).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let earliest = min(base, starts.last ?? base)
        let recorded = valueMinutes(from: earliest, to: max(to, now()), series: Set(tags.keys))
        let closed = recorded.filter { !$0.current }.map { ($0.start, $0.values) }
        let charted = recorded.filter { $0.start >= base && $0.start <= to }.map { ($0.start, $0.values) }

        // The power chart: per step, each role's average over the minutes that had it.
        var buckets: [Int: [EnergyRole: (sum: Double, count: Int)]] = [:]
        for minute in Self.energyMinutes(charted, tags: tags) {
            let index = max(0, Int(minute.start.timeIntervalSince(base) / step))
            for (role, watts) in minute.watts {
                let known = buckets[index]?[role] ?? (0, 0)
                buckets[index, default: [:]][role] = (known.sum + watts, known.count + 1)
            }
        }
        let power = buckets.keys.sorted().map { index in
            EnergyReport.PowerPoint(start: base.addingTimeInterval(Double(index) * step), watts: buckets[index]!.mapValues { $0.sum / Double($0.count) })
        }

        // The battery levels: a line per series, by device name.
        let levels = tags.filter { $0.value.role == .batteryLevel }.sorted { ($0.value.device, $0.key) < ($1.value.device, $1.key) }.map { series, tag in
            var steps: [Int: Values] = [:]
            for minute in charted {
                guard let values = minute.1[series] else { continue }
                steps[max(0, Int(minute.0.timeIntervalSince(base) / step)), default: Values()].merge(values)
            }
            let points = steps.keys.sorted().compactMap { index in
                steps[index]?.average.map { (start: base.addingTimeInterval(Double(index) * step), percent: $0) }
            }
            return EnergyReport.Level(series: series, device: tag.device, points: points)
        }

        // The days' energy, from the closed minutes.
        var energyDays = starts.map(EnergyDay.init(start:))
        for minute in Self.energyMinutes(closed, tags: tags) {
            guard let index = starts.firstIndex(where: { $0 <= minute.start }) else { continue }
            energyDays[index].add(minute.watts)
        }
        return EnergyReport(roles: Set(tags.values.map(\.role)), step: step, power: power, levels: levels, days: energyDays)
    }
}
