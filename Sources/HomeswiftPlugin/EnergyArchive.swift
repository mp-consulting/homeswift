import Foundation
import Homeswift
import HomeswiftAI
import NIOConcurrencyHelpers

/// Watt-hours of each flow in an hour, or a span of hours; nil where the flow is not known (an import that has solar
/// and home use but no grid). Signs as `EnergyRole` gives them, split: the grid's import and export, the battery's
/// charge and discharge, each zero or above. `homeFromSolar` is the part of `home` solar covered as it was produced.
public struct EnergyFlows: Sendable, Equatable, Codable {
    public var solar: Double?
    public var home: Double?
    public var gridImport: Double?
    public var gridExport: Double?
    public var batteryCharge: Double?
    public var batteryDischarge: Double?
    public var homeFromSolar: Double?

    public init(solar: Double? = nil, home: Double? = nil, gridImport: Double? = nil, gridExport: Double? = nil,
                batteryCharge: Double? = nil, batteryDischarge: Double? = nil, homeFromSolar: Double? = nil) {
        self.solar = solar
        self.home = home
        self.gridImport = gridImport
        self.gridExport = gridExport
        self.batteryCharge = batteryCharge
        self.batteryDischarge = batteryDischarge
        self.homeFromSolar = homeFromSolar
    }

    // Key paths are immutable values; the array is never changed.
    nonisolated(unsafe) static let fields: [WritableKeyPath<EnergyFlows, Double?>] = [\.solar, \.home, \.gridImport, \.gridExport, \.batteryCharge, \.batteryDischarge, \.homeFromSolar]

    var isEmpty: Bool { Self.fields.allSatisfy { self[keyPath: $0] == nil } }

    /// Each flow added up; a flow known on either side is known.
    func adding(_ other: EnergyFlows) -> EnergyFlows {
        var sum = self
        for field in Self.fields where other[keyPath: field] != nil {
            sum[keyPath: field] = (sum[keyPath: field] ?? 0) + other[keyPath: field]!
        }
        return sum
    }

    /// A minute whose roles averaged `watts`: each power's watt-hours for a sixtieth of an hour, as `EnergyDay` counts it.
    static func minute(_ watts: [EnergyRole: Double]) -> EnergyFlows {
        let hours = 1.0 / 60
        var flows = EnergyFlows()
        if let solar = watts[.solar] { flows.solar = max(0, solar) * hours }
        if let home = watts[.home] { flows.home = max(0, home) * hours }
        if let grid = watts[.grid] {
            flows.gridImport = max(0, grid) * hours
            flows.gridExport = max(0, -grid) * hours
        }
        if let battery = watts[.battery] {
            flows.batteryCharge = max(0, battery) * hours
            flows.batteryDischarge = max(0, -battery) * hours
        }
        if let solar = watts[.solar], let home = watts[.home] { flows.homeFromSolar = max(0, min(solar, home)) * hours }
        return flows
    }

    /// An hour's flows as the average watts of each role over it, `minute`'s inverse: the grid imported less exported,
    /// the battery charged less discharged. A flow the hour has no figure for gives no role.
    var averageWatts: [EnergyRole: Double] {
        var watts: [EnergyRole: Double] = [:]
        if let solar { watts[.solar] = solar }
        if let home { watts[.home] = home }
        if gridImport != nil || gridExport != nil { watts[.grid] = (gridImport ?? 0) - (gridExport ?? 0) }
        if batteryCharge != nil || batteryDischarge != nil { watts[.battery] = (batteryCharge ?? 0) - (batteryDischarge ?? 0) }
        return watts
    }
}

/// An hour of a plugin's energy history (a cloud's record of the days before the bridge ran), in watt-hours; nil
/// where the history has nothing. `homeFromSolar`, when not given, is taken as the lesser of solar and home use.
public struct EnergyHourImport: Sendable, Equatable {
    public var start: Date
    public var flows: EnergyFlows

    public init(start: Date, flows: EnergyFlows) {
        self.start = start
        self.flows = flows
    }
}

/// Where a plugin's energy import stands, for the Status page: running (`done` of `total` steps, such as months),
/// done (the history covers `from` to `through`) or failed (`message` says why, in words a person can act on). The
/// plugin reports it with `PluginContext.reportEnergyImport`; the host fills in `source` (the plugin's key), `name`
/// (its block's name) and `updated`.
public struct EnergyImportProgress: Sendable, Equatable {
    public enum State: String, Sendable {
        case running, done, failed
    }

    public var source = ""
    public var name = ""
    public var state: State
    public var done: Int
    public var total: Int
    public var from: Date?
    public var through: Date?
    public var message: String?
    public var updated = Date(timeIntervalSince1970: 0)

    public init(state: State, done: Int = 0, total: Int = 0, from: Date? = nil, through: Date? = nil, message: String? = nil) {
        self.state = state
        self.done = done
        self.total = total
        self.from = from
        self.through = through
        self.message = message
    }
}

/// A day's or a month's energy from the archive, in watt-hours, with where the home's use came from: solar as it was
/// produced, the batteries, the grid, or not split (an hour known by its home use only).
public struct EnergyPeriod: Sendable, Equatable {
    public var start: Date
    public var flows = EnergyFlows()
    public var homeFromBattery: Double?
    public var homeFromGrid: Double?
    public var homeNotSplit: Double?
    /// Hours the bridge recorded (at least `EnergyArchive.wholeHour` minutes), and hours known from an import only.
    public var recordedHours = 0
    public var importedHours = 0

    public init(start: Date) { self.start = start }

    /// The share of the home's use solar covered as it was produced, 0 to 1; nil without home use.
    public var solarShare: Double? {
        guard let home = flows.home, home > 0 else { return nil }
        return min(1, (flows.homeFromSolar ?? 0) / home)
    }

    mutating func add(_ hour: EnergyFlows, recorded: Bool) {
        guard !hour.isEmpty else { return }
        if recorded { recordedHours += 1 } else { importedHours += 1 }
        flows = flows.adding(hour)
        guard let home = hour.home else { return }
        let rest = max(0, home - (hour.homeFromSolar ?? 0))
        if let imported = hour.gridImport {
            let grid = min(imported, rest)
            homeFromGrid = (homeFromGrid ?? 0) + grid
            if hour.batteryDischarge != nil {
                homeFromBattery = (homeFromBattery ?? 0) + (rest - grid)
            } else if rest - grid > 0 {
                homeNotSplit = (homeNotSplit ?? 0) + (rest - grid)
            }
        } else if rest > 0 {
            homeNotSplit = (homeNotSplit ?? 0) + rest
        }
    }
}

/// The long-term energy history: each hour's watt-hours of every flow, kept for years in `energy-hours.json` under the
/// metrics directory. Two sources feed it: the bridge's own readings (each closed minute of the series plugins tag,
/// `Metrics`) and imports (a plugin's cloud history, `PluginContext.importEnergy`), each import source on its own. An
/// hour the bridge recorded for most of it (`wholeHour` minutes) reads its own figures, else an import's where it has
/// them. Changes are written a minute later at most, and on `flush()`.
public final class EnergyArchive: @unchecked Sendable {
    struct Hour: Codable, Equatable {
        var recorded: EnergyFlows?
        var minutes: Int?
        var imported: [String: EnergyFlows]?
    }

    private struct Stored: Codable {
        var version: Int
        var hours: [String: Hour]
    }

    /// Minutes of an hour the bridge must have recorded for its own figures to stand over an import's.
    public static let wholeHour = 45
    static let fileName = "energy-hours.json"

    public let url: URL?
    private let hours: NIOLockedValueBox<[Int: Hour]>
    /// When the pending save runs; nil when nothing is to be written.
    private let saveDue = NIOLockedValueBox<DispatchTime?>(nil)
    private let queue = DispatchQueue(label: "homeswift.energy-archive", qos: .utility)
    private let saveDelay: DispatchTimeInterval
    /// The delay of a save after a recorded minute only. Years of hours are hundreds of kilobytes: written each minute,
    /// they were the largest part of a busy bridge's work.
    private let recordedSaveDelay: DispatchTimeInterval

    /// `url` nil keeps the archive in memory only.
    public init(url: URL?, saveDelay: DispatchTimeInterval = .seconds(60), recordedSaveDelay: DispatchTimeInterval = .seconds(3600)) {
        self.url = url
        self.saveDelay = saveDelay
        self.recordedSaveDelay = recordedSaveDelay
        var loaded: [Int: Hour] = [:]
        if let url, let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1 {
            for (key, hour) in stored.hours { if let start = Int(key) { loaded[start] = hour } }
        }
        hours = NIOLockedValueBox(loaded)
    }

    static func hourStart(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 3600).rounded(.down)) * 3600 }

    /// Adds a closed minute the bridge recorded.
    func addRecorded(_ start: Date, watts: [EnergyRole: Double]) {
        guard !watts.isEmpty else { return }
        let flows = EnergyFlows.minute(watts)
        hours.withLockedValue { hours in
            var hour = hours[Self.hourStart(start)] ?? Hour()
            hour.recorded = (hour.recorded ?? EnergyFlows()).adding(flows)
            hour.minutes = (hour.minutes ?? 0) + 1
            hours[Self.hourStart(start)] = hour
        }
        // The kept minutes make these hours again at start (`rebuildRecorded`): a minute need not reach the file soon.
        scheduleSave(after: recordedSaveDelay)
    }

    /// The recorded figures of whole hours, made again from the bridge's minutes (at start, from the days it keeps):
    /// each hour from `from` on is replaced, so a restart counts no minute twice.
    func rebuildRecorded(_ minutes: [(start: Date, watts: [EnergyRole: Double])], from: Date) {
        var rebuilt: [Int: (flows: EnergyFlows, minutes: Int)] = [:]
        for minute in minutes where minute.start >= from && !minute.watts.isEmpty {
            let key = Self.hourStart(minute.start)
            let known = rebuilt[key] ?? (EnergyFlows(), 0)
            rebuilt[key] = (known.flows.adding(EnergyFlows.minute(minute.watts)), known.minutes + 1)
        }
        let first = Self.hourStart(from)
        hours.withLockedValue { hours in
            for key in hours.keys where key >= first && rebuilt[key] == nil {
                hours[key]?.recorded = nil
                hours[key]?.minutes = nil
            }
            for (key, value) in rebuilt {
                var hour = hours[key] ?? Hour()
                hour.recorded = value.flows
                hour.minutes = value.minutes
                hours[key] = hour
            }
            hours = hours.filter { $0.value != Hour() }
        }
        scheduleSave()
    }

    /// Takes `source`'s history (a plugin's key): each hour replaces what the source said of it before.
    public func importHours(_ imported: [EnergyHourImport], source: String) {
        guard !imported.isEmpty else { return }
        hours.withLockedValue { hours in
            for one in imported {
                var flows = one.flows
                if flows.homeFromSolar == nil, let solar = flows.solar, let home = flows.home { flows.homeFromSolar = max(0, min(solar, home)) }
                let key = Self.hourStart(one.start)
                var hour = hours[key] ?? Hour()
                hour.imported = (hour.imported ?? [:]).merging([source: flows]) { $1 }
                hours[key] = hour
            }
        }
        scheduleSave()
    }

    /// An hour as the archive reads it: the bridge's own figures for an hour it recorded most of, else each flow from
    /// the imports where they have it (the sources added up), else whatever the bridge recorded.
    static func merged(_ hour: Hour) -> (flows: EnergyFlows, recorded: Bool) {
        let imported = (hour.imported ?? [:]).values.reduce(EnergyFlows()) { $0.adding($1) }
        guard let recorded = hour.recorded else { return (imported, false) }
        let whole = (hour.minutes ?? 0) >= wholeHour
        var flows = EnergyFlows()
        for field in EnergyFlows.fields {
            flows[keyPath: field] = whole ? (recorded[keyPath: field] ?? imported[keyPath: field]) : (imported[keyPath: field] ?? recorded[keyPath: field])
        }
        return (flows, whole || imported.isEmpty)
    }

    /// The hours from `from` to `to` that some source imported, oldest first: their flows, the sources added up.
    public func importedHours(from: Date, to: Date) -> [(start: Date, flows: EnergyFlows)] {
        let first = Self.hourStart(from), last = Int(to.timeIntervalSince1970)
        guard first <= last else { return [] }
        // The span's hours looked up one by one, in order: the archive holds years of them.
        return hours.withLockedValue { hours in
            stride(from: first, through: last, by: 3600).compactMap { key -> (start: Date, flows: EnergyFlows)? in
                guard let imported = hours[key]?.imported, !imported.isEmpty else { return nil }
                return (Date(timeIntervalSince1970: TimeInterval(key)), imported.values.reduce(EnergyFlows()) { $0.adding($1) })
            }
        }
    }

    /// The first hour with anything known.
    public var earliest: Date? { hours.withLockedValue { $0.keys.min() }.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    /// The days (`.day`) or months (`.month`) from the one `from` is in to the one `to` is in, in `timeZone`, oldest
    /// first; each with the hours whose start falls in it.
    public func periods(_ unit: Calendar.Component, from: Date, to: Date, timeZone: TimeZone) -> [EnergyPeriod] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components: Set<Calendar.Component> = unit == .month ? [.year, .month] : [.year, .month, .day]
        guard var start = calendar.date(from: calendar.dateComponents(components, from: from)) else { return [] }
        var periods: [EnergyPeriod] = []
        while start <= to {
            periods.append(EnergyPeriod(start: start))
            guard let next = calendar.date(byAdding: unit, value: 1, to: start) else { break }
            start = next
        }
        guard let first = periods.first?.start, let end = calendar.date(byAdding: unit, value: 1, to: periods.last!.start) else { return periods }
        let selected = hours.withLockedValue { $0.filter { $0.key >= Int(first.timeIntervalSince1970) && $0.key < Int(end.timeIntervalSince1970) } }
        for (key, hour) in selected {
            let date = Date(timeIntervalSince1970: TimeInterval(key))
            guard let index = periods.lastIndex(where: { $0.start <= date }) else { continue }
            let (flows, recorded) = Self.merged(hour)
            periods[index].add(flows, recorded: recorded)
        }
        return periods
    }

    // MARK: The file

    /// A save after `delay` (`saveDelay` by default), unless one is due sooner.
    private func scheduleSave(after delay: DispatchTimeInterval? = nil) {
        guard url != nil else { return }
        let deadline = DispatchTime.now() + (delay ?? saveDelay)
        let schedule = saveDue.withLockedValue { due -> Bool in
            if let due, due <= deadline { return false }
            due = deadline
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: deadline) { [weak self] in self?.write() }
    }

    /// Writes what changed now; the metrics store calls it when it stops.
    public func flush() {
        queue.sync { write() }
    }

    private func write() {
        guard let url, saveDue.withLockedValue({ due in defer { due = nil }; return due != nil }) else { return }
        let snapshot = hours.withLockedValue { $0 }
        try? OwnerOnlyFile.write(Self.encoded(snapshot), to: url)
    }

    /// The file's bytes: what `JSONEncoder` writes for `Stored` with sorted keys, written straight as bytes. Years of
    /// hours are hundreds of kilobytes: the encoder's generic path was the slow part of a save.
    static func encoded(_ hours: [Int: Hour]) -> Data {
        // Watt-hours to a hundredth: the file stays small, the sums exact enough. The coding keys in the encoder's
        // sorted order.
        func write(_ flows: EnergyFlows, to json: inout JSONBytesWriter) {
            func field(_ json: inout JSONBytesWriter, _ name: String, _ value: Double?) {
                if let value { json.field(name, .number((value * 100).rounded() / 100)) }
            }
            json.object { json in
                field(&json, "batteryCharge", flows.batteryCharge)
                field(&json, "batteryDischarge", flows.batteryDischarge)
                field(&json, "gridExport", flows.gridExport)
                field(&json, "gridImport", flows.gridImport)
                field(&json, "home", flows.home)
                field(&json, "homeFromSolar", flows.homeFromSolar)
                field(&json, "solar", flows.solar)
            }
        }
        // Sorted keys, as the encoder sorts them: by UTF-8 bytes. Hours as numbers of one length (every hour since 2001
        // has ten digits) sort the same as numbers, far cheaper than comparing their text.
        let starts = hours.keys.sorted()
        // Sorted and not negative: all have one length when the first and the last have.
        let sameLength = (starts.first ?? 0) >= 0 && String(starts.first ?? 0).utf8.count == String(starts.last ?? 0).utf8.count
        let hourKeys = sameLength
            ? starts.map { (String($0), $0) }
            : hours.keys.map { (String($0), $0) }.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
        var json = JSONBytesWriter(capacity: hours.count * 100)
        json.object { json in
            json.key("hours")
            json.object { json in
                for (key, start) in hourKeys {
                    let hour = hours[start].unsafelyUnwrapped
                    json.key(key)
                    json.object { json in
                        if let imported = hour.imported {
                            json.key("imported")
                            json.object { json in
                                for source in imported.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                                    json.key(source)
                                    write(imported[source].unsafelyUnwrapped, to: &json)
                                }
                            }
                        }
                        if let minutes = hour.minutes { json.field("minutes", .number(Double(minutes))) }
                        if let recorded = hour.recorded {
                            json.key("recorded")
                            write(recorded, to: &json)
                        }
                    }
                }
            }
            json.field("version", .number(1))
        }
        return Data(json.bytes)
    }
}
