import Foundation
import Homeswift
import NIOConcurrencyHelpers

/// A Meter's address: the accessory it belongs to (its Accessory Id) and which of its Meters (a key its source picks,
/// stable for as long as the accessory is: a service's `uuid/subtype`, or a plugin's own name for the Meter).
public struct MeterID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var accessory: String
    public var meter: String

    public init(accessory: String, meter: String) {
        self.accessory = accessory
        self.meter = meter
    }

    public var description: String { "\(accessory)#\(meter)" }
}

/// Which way a Meter's energy flows: drawn (Consumption) or sent back, or produced (Returned).
public enum MeterDirection: String, Sendable, Codable, CaseIterable {
    case consumption, returned
}

/// An hour of one Meter, in watt-hours; nil where nothing is known. `recorded` says the figures are the bridge's own
/// measurement, not an import's or an estimate across a time the bridge was not running.
public struct MeterHour: Sendable, Equatable {
    public var start: Date
    public var consumption: Double?
    public var returned: Double?
    public var recorded: Bool
}

/// A day's or a month's energy of one Meter, in watt-hours, from its hours.
public struct MeterPeriod: Sendable, Equatable {
    public var start: Date
    public var consumption: Double?
    public var returned: Double?
    /// Hours with anything known, and those of them the bridge measured itself.
    public var hours = 0
    public var recordedHours = 0

    public init(start: Date) { self.start = start }

    mutating func add(_ hour: MeterHour) {
        hours += 1
        if hour.recorded { recordedHours += 1 }
        if let value = hour.consumption { consumption = (consumption ?? 0) + value }
        if let value = hour.returned { returned = (returned ?? 0) + value }
    }
}

/// An hour of a Meter's past (a device's or a cloud's record), in watt-hours, handed to `MeterArchive.importHours`.
public struct MeterHourImport: Sendable, Equatable {
    public var start: Date
    public var consumption: Double?
    public var returned: Double?

    public init(start: Date, consumption: Double? = nil, returned: Double? = nil) {
        self.start = start
        self.consumption = consumption
        self.returned = returned
    }
}

/// Each Meter's energy, an hour at a time, for years (docs/adr/0004-meters-and-consumption-history.md).
///
/// A Meter's energy comes from its counters when it has them: what a counter gained between two readings is spread
/// over the time between them, so a restart of the bridge loses nothing, and a counter that went back is a reset (what
/// it reads is what it gained since). The part of that time before the bridge started this time is an estimate,
/// which an import's figure stands over. A Meter without a counter for a direction has its power held from one
/// reading to the next (`advance(to:)` carries it to now), watts above zero drawn and below zero returned; power held
/// across a restart is never counted.
///
/// Files, under `directory`: a folder per Meter (its id in base64url), with `meter.json` (the id and the counters' last
/// readings) and a file per UTC year of hours (`2026.json`), written a while after they change and on `flush()`.
public final class MeterArchive: @unchecked Sendable {
    struct Hour: Codable, Equatable {
        /// The bridge's own figures (`c`, `r`), and whether some of them were an estimate (`e`).
        var c: Double?
        var r: Double?
        var e: Bool?
        /// An import's (`ic`, `ir`).
        var ic: Double?
        var ir: Double?

        var isEmpty: Bool { c == nil && r == nil && ic == nil && ir == nil }
    }

    struct Reading: Codable, Equatable {
        var value: Double
        var at: Date
    }

    struct Stored: Codable {
        var version: Int
        var accessory: String
        var meter: String
        /// The counters' last readings, by direction.
        var counters: [String: Reading]
    }

    private struct Meter {
        var counters: [MeterDirection: Reading] = [:]
        /// The power last read, held until the next reading; this run's only.
        var power: Reading?
        /// Loaded years: the hours by their offset from the year's first, in hours.
        var years: [Int: [Int: Hour]] = [:]
    }

    private struct State {
        var meters: [MeterID: Meter] = [:]
        /// Meters whose `meter.json` and which of their years are to be written.
        var dirty: [MeterID: Set<Int>] = [:]
        var dirtyMeters: Set<MeterID> = []
    }

    /// The longest time a counter's gain is spread over; a longer one sets the counter's reading again and is lost.
    public static let longestGap: TimeInterval = 31 * 86_400
    static let version = 1

    public let directory: URL?
    /// When the bridge started this time: time before it is an estimate.
    public let started: Date
    let now: @Sendable () -> Date
    private let state = NIOLockedValueBox(State())
    private let saveDue = NIOLockedValueBox<DispatchTime?>(nil)
    private let queue = DispatchQueue(label: "homeswift.meter-archive", qos: .utility)
    private let saveDelay: DispatchTimeInterval

    /// `directory` nil keeps the Meters in memory only. `now` is for tests.
    public init(directory: URL?, saveDelay: DispatchTimeInterval = .seconds(600), now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.saveDelay = saveDelay
        self.now = now
        started = now()
        guard let directory, let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        var meters: [MeterID: Meter] = [:]
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meter.json")),
                  let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == Self.version else { continue }
            var meter = Meter()
            for (key, reading) in stored.counters { if let direction = MeterDirection(rawValue: key) { meter.counters[direction] = reading } }
            meters[MeterID(accessory: stored.accessory, meter: stored.meter)] = meter
        }
        state.withLockedValue { $0.meters = meters }
    }

    /// Every Meter with a history, by Accessory Id and key.
    public var meters: [MeterID] {
        state.withLockedValue { Array($0.meters.keys) }.sorted { ($0.accessory, $0.meter) < ($1.accessory, $1.meter) }
    }

    // MARK: Readings

    /// A counter's reading, in watt-hours.
    public func recordCounter(_ wattHours: Double, direction: MeterDirection = .consumption, meter id: MeterID, at: Date? = nil) {
        guard wattHours.isFinite, wattHours >= 0 else { return }
        let at = at ?? now()
        let started = started
        changing(id) { meter, years in
            defer { if meter.counters[direction].map({ at >= $0.at }) ?? true { meter.counters[direction] = Reading(value: wattHours, at: at) } }
            guard let last = meter.counters[direction], at > last.at else { return true }
            let gained = wattHours >= last.value ? wattHours - last.value : wattHours
            guard gained > 0, at.timeIntervalSince(last.at) <= Self.longestGap else { return true }
            // The part before this run started is an estimate, the rest the bridge's own.
            let split = min(max(started, last.at), at)
            let whole = at.timeIntervalSince(last.at)
            if split > last.at {
                Self.spread(gained * split.timeIntervalSince(last.at) / whole, direction: direction, from: last.at, to: split, estimate: true, into: &meter, years: &years, id: id, directory: self.directory)
            }
            if at > split {
                Self.spread(gained * at.timeIntervalSince(split) / whole, direction: direction, from: split, to: at, estimate: false, into: &meter, years: &years, id: id, directory: self.directory)
            }
            return true
        }
    }

    /// A power reading, in watts: above zero drawn, below zero returned. Counted only for a direction the Meter has
    /// no counter for.
    public func recordPower(_ watts: Double, meter id: MeterID, at: Date? = nil) {
        guard watts.isFinite else { return }
        let at = at ?? now()
        changing(id) { meter, years in
            let changed = Self.hold(&meter, to: at, years: &years, id: id, directory: self.directory)
            if meter.power.map({ at >= $0.at }) ?? true { meter.power = Reading(value: watts, at: at) }
            return changed
        }
    }

    /// Counts every Meter's held power up to `date`; the metrics store calls it as it samples.
    public func advance(to date: Date? = nil) {
        let date = date ?? now()
        let changed = state.withLockedValue { state -> Bool in
            var changed = false
            for id in Array(state.meters.keys) {
                guard var meter = state.meters[id], meter.power.map({ date > $0.at }) == true else { continue }
                var years: Set<Int> = []
                if Self.hold(&meter, to: date, years: &years, id: id, directory: directory) {
                    state.dirty[id, default: []].formUnion(years)
                    changed = true
                }
                state.meters[id] = meter
            }
            return changed
        }
        if changed { scheduleSave() }
    }

    /// A Meter's hours from a device's or a cloud's record: each replaces what was imported for it before. An hour the
    /// bridge measured keeps its own figures.
    public func importHours(_ hours: [MeterHourImport], meter id: MeterID) {
        guard !hours.isEmpty else { return }
        changing(id) { meter, years in
            for hour in hours {
                let (year, offset) = Self.position(hour.start)
                Self.load(year, for: id, directory: self.directory, into: &meter)
                var known = meter.years[year]?[offset] ?? Hour()
                known.ic = hour.consumption
                known.ir = hour.returned
                meter.years[year, default: [:]][offset] = known.isEmpty ? nil : known
                years.insert(year)
            }
            return true
        }
    }

    /// Forgets every Meter of an accessory, its files included.
    public func forget(accessory: String) {
        let gone = state.withLockedValue { state -> [MeterID] in
            let gone = state.meters.keys.filter { $0.accessory == accessory }
            for id in gone {
                state.meters[id] = nil
                state.dirty[id] = nil
                state.dirtyMeters.remove(id)
            }
            return gone
        }
        guard let directory, !gone.isEmpty else { return }
        queue.sync {
            for id in gone { try? FileManager.default.removeItem(at: Self.folder(of: id, in: directory)) }
        }
    }

    // MARK: Reading back

    /// A Meter's hours from `from` to `to`, oldest first, those with nothing known left out.
    public func hours(of id: MeterID, from: Date, to: Date) -> [MeterHour] {
        let first = Int((from.timeIntervalSince1970 / 3600).rounded(.down)), last = Int((to.timeIntervalSince1970 / 3600).rounded(.down))
        guard first <= last else { return [] }
        return state.withLockedValue { state -> [MeterHour] in
            guard var meter = state.meters[id] else { return [] }
            let firstYear = Self.position(Date(timeIntervalSince1970: TimeInterval(first * 3600))).year
            let lastYear = Self.position(Date(timeIntervalSince1970: TimeInterval(last * 3600))).year
            var found: [MeterHour] = []
            for year in firstYear...lastYear {
                Self.load(year, for: id, directory: directory, into: &meter)
                let base = Self.yearStart(year) / 3600
                for offset in (meter.years[year] ?? [:]).keys.sorted() where (first...last).contains(base + offset) {
                    found.append(Self.merged(meter.years[year]![offset]!, start: Date(timeIntervalSince1970: TimeInterval((base + offset) * 3600))))
                }
            }
            state.meters[id] = meter
            return found
        }
    }

    /// A Meter's days (`.day`) or months (`.month`) from the one `from` is in to the one `to` is in, in `timeZone`,
    /// oldest first, each with the hours that start in it.
    public func periods(of id: MeterID, _ unit: Calendar.Component, from: Date, to: Date, timeZone: TimeZone) -> [MeterPeriod] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components: Set<Calendar.Component> = unit == .month ? [.year, .month] : [.year, .month, .day]
        guard var start = calendar.date(from: calendar.dateComponents(components, from: from)) else { return [] }
        var periods: [MeterPeriod] = []
        while start <= to {
            periods.append(MeterPeriod(start: start))
            guard let next = calendar.date(byAdding: unit, value: 1, to: start) else { break }
            start = next
        }
        guard let first = periods.first?.start, let end = calendar.date(byAdding: unit, value: 1, to: periods.last!.start) else { return periods }
        for hour in hours(of: id, from: first, to: end.addingTimeInterval(-1)) {
            guard let index = periods.lastIndex(where: { $0.start <= hour.start }) else { continue }
            periods[index].add(hour)
        }
        return periods
    }

    /// An hour as it reads: the bridge's measurement, each figure it lacks from the import; for an estimate, the
    /// import's figures where it has them.
    static func merged(_ hour: Hour, start: Date) -> MeterHour {
        let estimate = hour.e ?? false
        let imported = hour.ic != nil || hour.ir != nil
        if estimate && imported {
            return MeterHour(start: start, consumption: hour.ic ?? hour.c, returned: hour.ir ?? hour.r, recorded: false)
        }
        let recorded = (hour.c != nil || hour.r != nil) && !estimate
        return MeterHour(start: start, consumption: hour.c ?? hour.ic, returned: hour.r ?? hour.ir, recorded: recorded)
    }

    // MARK: Spreading energy over hours

    /// The held power from its reading to `date`, for the directions without a counter. Returns whether anything changed.
    private static func hold(_ meter: inout Meter, to date: Date, years: inout Set<Int>, id: MeterID, directory: URL?) -> Bool {
        guard let power = meter.power, date > power.at else { return false }
        meter.power = Reading(value: power.value, at: date)
        let direction: MeterDirection = power.value >= 0 ? .consumption : .returned
        guard power.value != 0, meter.counters[direction] == nil else { return false }
        let wattHours = abs(power.value) * date.timeIntervalSince(power.at) / 3600
        spread(wattHours, direction: direction, from: power.at, to: date, estimate: false, into: &meter, years: &years, id: id, directory: directory)
        return true
    }

    /// Adds `wattHours`, spent evenly from `from` to `to`, to the hours it covers.
    private static func spread(_ wattHours: Double, direction: MeterDirection, from: Date, to: Date, estimate: Bool,
                               into meter: inout Meter, years: inout Set<Int>, id: MeterID, directory: URL?) {
        let whole = to.timeIntervalSince(from)
        guard whole > 0, wattHours > 0 else { return }
        var cursor = from
        while cursor < to {
            let hourStart = (cursor.timeIntervalSince1970 / 3600).rounded(.down) * 3600
            let next = min(to, Date(timeIntervalSince1970: hourStart + 3600))
            let share = wattHours * next.timeIntervalSince(cursor) / whole
            let (year, offset) = position(cursor)
            load(year, for: id, directory: directory, into: &meter)
            var hour = meter.years[year]?[offset] ?? Hour()
            switch direction {
            case .consumption: hour.c = (hour.c ?? 0) + share
            case .returned: hour.r = (hour.r ?? 0) + share
            }
            if estimate { hour.e = true }
            meter.years[year, default: [:]][offset] = hour
            years.insert(year)
            cursor = next
        }
    }

    // MARK: Years

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The first second of a UTC year.
    static func yearStart(_ year: Int) -> Int {
        Int(utc.date(from: DateComponents(year: year, month: 1, day: 1))!.timeIntervalSince1970)
    }

    /// The UTC year an instant is in, and its hour's offset from the year's first.
    static func position(_ date: Date) -> (year: Int, offset: Int) {
        let year = utc.component(.year, from: date)
        return (year, (Int((date.timeIntervalSince1970 / 3600).rounded(.down)) * 3600 - yearStart(year)) / 3600)
    }

    static func folder(of id: MeterID, in directory: URL) -> URL {
        let name = Data("\(id.accessory)\u{0}\(id.meter)".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    private static func load(_ year: Int, for id: MeterID, directory: URL?, into meter: inout Meter) {
        guard meter.years[year] == nil else { return }
        guard let directory,
              let data = try? Data(contentsOf: folder(of: id, in: directory).appendingPathComponent("\(year).json")),
              let stored = try? JSONDecoder().decode([String: Hour].self, from: data) else {
            meter.years[year] = [:]
            return
        }
        meter.years[year] = Dictionary(uniqueKeysWithValues: stored.compactMap { key, hour in Int(key).map { ($0, hour) } })
    }

    /// Changes one Meter under the lock (each year loaded as it is touched) and schedules a save.
    private func changing(_ id: MeterID, _ change: (inout Meter, inout Set<Int>) -> Bool) {
        let changed = state.withLockedValue { state -> Bool in
            let isNew = state.meters[id] == nil
            var meter = state.meters[id] ?? Meter()
            var years: Set<Int> = []
            let before = meter.counters
            let changed = change(&meter, &years)
            state.meters[id] = meter
            // `meter.json` names the Meter: written for a new one, and when its counters move.
            if isNew || meter.counters != before { state.dirtyMeters.insert(id) }
            state.dirty[id, default: []].formUnion(years)
            return changed || isNew || meter.counters != before
        }
        if changed { scheduleSave() }
    }

    // MARK: Files

    private func scheduleSave() {
        guard directory != nil else { return }
        let deadline = DispatchTime.now() + saveDelay
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
        saveDue.withLockedValue { $0 = nil }
        guard let directory else { return }
        let pending = state.withLockedValue { state -> [(MeterID, Stored?, [(Int, [Int: Hour])])] in
            defer { state.dirty = [:]; state.dirtyMeters = [] }
            let ids = Set(state.dirty.keys).union(state.dirtyMeters)
            return ids.compactMap { id in
                guard let meter = state.meters[id] else { return nil }
                let stored = Stored(version: Self.version, accessory: id.accessory, meter: id.meter,
                                    counters: Dictionary(uniqueKeysWithValues: meter.counters.map { ($0.key.rawValue, $0.value) }))
                let years = (state.dirty[id] ?? []).compactMap { year in meter.years[year].map { (year, $0) } }
                return (id, stored, years)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (id, stored, years) in pending {
            let folder = Self.folder(of: id, in: directory)
            if let stored, let data = try? encoder.encode(stored) { try? OwnerOnlyFile.write(data, to: folder.appendingPathComponent("meter.json")) }
            for (year, hours) in years {
                let rounded = Dictionary(uniqueKeysWithValues: hours.map { offset, hour in
                    (String(offset), Hour(c: hour.c.map(Self.round), r: hour.r.map(Self.round), e: hour.e, ic: hour.ic.map(Self.round), ir: hour.ir.map(Self.round)))
                })
                if let data = try? encoder.encode(rounded) { try? OwnerOnlyFile.write(data, to: folder.appendingPathComponent("\(year).json")) }
            }
        }
    }

    /// Watt-hours to a thousandth: the files stay small, the sums exact enough.
    static func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
