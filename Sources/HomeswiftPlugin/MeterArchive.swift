import Foundation
import Homeswift
import HomeswiftAI
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

/// What a Meter measures (GLOSSARY.md, "Meter"): electricity, in kWh, or gas or water, in m³. HAP has no gas or water
/// characteristics, so only plugins declare those (`PluginContext.meter(_:deviceID:device:kind:)`). The archive keeps a
/// Meter's figures in thousandths of its unit: watt-hours for electricity, litres for gas and water. Gas stays in m³:
/// it is never converted to kWh, and never counts in the Home Energy.
public enum MeterKind: String, Sendable, Codable, CaseIterable {
    case electricity, gas, water

    /// The unit its figures are shown in.
    public var unit: String { self == .electricity ? "kWh" : "m³" }
}

/// Which way a Meter's energy flows: drawn (Consumption) or sent back, or produced (Returned).
public enum MeterDirection: String, Sendable, Codable, CodingKeyRepresentable {
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

    /// An hour of a gas or water Meter: the m³ it drew (kept in litres, as watt-hours are kept for kWh).
    public init(start: Date, cubicMetres: Double) {
        self.init(start: start, consumption: cubicMetres * 1000)
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
/// readings) and a file per UTC year of hours (`2026.json`), written a while after they change and on `flush()`. The
/// years readings reach stay in memory; a past year read for a chart is read from its file each time.
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
        var id: MeterID
        /// The counters' last readings.
        var counters: [MeterDirection: Reading]
        /// Gas or water; nil for electricity, as the files written before there were kinds have it.
        var kind: MeterKind?
    }

    private struct Meter {
        var counters: [MeterDirection: Reading] = [:]
        var kind: MeterKind = .electricity
        /// The power last read, held until the next reading, and counted up to `at`; this run's only.
        var power: Reading?
        /// When that power was read.
        var powerRead: Date?
        /// The years readings reached: the hours by their offset from the year's first, in hours.
        var years: [Int: [Int: Hour]] = [:]
    }

    private struct State {
        var meters: [MeterID: Meter] = [:]
        /// The Meters holding power, which `advance` carries forward.
        var holding: Set<MeterID> = []
        /// The Meters to write: their `meter.json` and the years given.
        var dirty: [MeterID: Set<Int>] = [:]
    }

    /// The longest time a counter's gain is spread over; a longer one sets the counter's reading again and is lost.
    public static let longestGap: TimeInterval = 31 * 86_400
    /// The most power a gain may stand for, in watts (Eve's Current Consumption's bound): a counter that gained more
    /// over its time (a plugin's 0 while the device was away, then its real reading) sets its reading again instead.
    public static let largestPower: Double = 100_000
    /// The longest power is held without a new reading: a device that stops reporting (gone from the network) stops
    /// being counted then.
    public static let longestHold: TimeInterval = 6 * 3600
    static let version = 1

    public let directory: URL?
    /// When the bridge started this time: time before it is an estimate.
    public let started: Date
    let now: @Sendable () -> Date
    private let state = NIOLockedValueBox(State())
    private let saving = DebouncedSave(label: "homeswift.meter-archive")
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
            meters[stored.id] = Meter(counters: stored.counters, kind: stored.kind ?? .electricity)
        }
        state.withLockedValue { $0.meters = meters }
    }

    /// Every Meter with a history, by Accessory Id and key.
    public var meters: [MeterID] {
        state.withLockedValue { Array($0.meters.keys) }.sorted { ($0.accessory, $0.meter) < ($1.accessory, $1.meter) }
    }

    /// What a Meter measures; electricity for one never declared otherwise.
    public func kind(of id: MeterID) -> MeterKind {
        state.withLockedValue { $0.meters[id]?.kind } ?? .electricity
    }

    /// Says what a Meter measures (its plugin declared it so), kept in its `meter.json`.
    public func setKind(_ kind: MeterKind, meter id: MeterID) {
        let changed = state.withLockedValue { state -> Bool in
            guard state.meters[id]?.kind != kind else { return false }
            state.meters[id, default: Meter()].kind = kind
            // Its meter.json, with no year.
            state.dirty[id, default: []].formUnion([])
            return true
        }
        if changed { scheduleSave() }
    }

    // MARK: Readings

    /// A counter's reading, in watt-hours, as the device reports it now.
    public func recordCounter(_ wattHours: Double, direction: MeterDirection = .consumption, meter id: MeterID, at: Date? = nil) {
        guard wattHours.isFinite, wattHours >= 0 else { return }
        let at = at ?? now()
        changing(id) { meter, years in
            defer { if Self.isNewer(at, than: meter.counters[direction]) { meter.counters[direction] = Reading(value: wattHours, at: at) } }
            guard let last = meter.counters[direction], at > last.at else { return }
            let gained = wattHours >= last.value ? wattHours - last.value : wattHours
            let whole = at.timeIntervalSince(last.at)
            guard gained > 0, whole <= Self.longestGap, gained <= Self.largestPower * whole / 3600 else { return }
            // The part before this run started is an estimate, the rest the bridge's own.
            let split = min(max(started, last.at), at)
            for (from, to, estimate) in [(last.at, split, true), (split, at, false)] {
                spread(gained * to.timeIntervalSince(from) / whole, direction, from: from, to: to, estimate: estimate, into: &meter, years: &years, id: id)
            }
        }
    }

    /// A counter's reading that may be old (an accessory's cached value, read at start): it counts only when the
    /// counter went up, never as a reset, and otherwise leaves the last reading as it is, so what the device counted
    /// while the bridge was away is spread over that time. A Meter's first reading is its start.
    public func seedCounter(_ wattHours: Double, direction: MeterDirection = .consumption, meter id: MeterID) {
        if let last = state.withLockedValue({ $0.meters[id]?.counters[direction] }), wattHours <= last.value { return }
        recordCounter(wattHours, direction: direction, meter: id)
    }

    /// A power reading, in watts: above zero drawn, below zero returned. Counted only for a direction the Meter has
    /// no counter for, and for at most `longestHold` after it.
    public func recordPower(_ watts: Double, meter id: MeterID, at: Date? = nil) {
        guard watts.isFinite else { return }
        let at = at ?? now()
        changing(id) { meter, years in
            hold(&meter, to: at, years: &years, id: id)
            if meter.powerRead.map({ at >= $0 }) ?? true {
                meter.power = Reading(value: watts, at: at)
                meter.powerRead = at
            }
        }
    }

    /// Counts every Meter's held power up to `date`; the metrics store calls it as it samples.
    public func advance(to date: Date? = nil) {
        let date = date ?? now()
        let changed = state.withLockedValue { state -> Bool in
            var changed = false
            for id in state.holding {
                changed = mutate(id, in: &state) { meter, years in hold(&meter, to: date, years: &years, id: id) } || changed
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
                load(year, of: id, into: &meter)
                var known = meter.years[year]?[offset] ?? Hour()
                known.ic = hour.consumption
                known.ir = hour.returned
                meter.years[year]?[offset] = known.isEmpty ? nil : known
                years.insert(year)
            }
        }
    }

    /// The Meters of one accessory, by key.
    public func meters(of accessory: String) -> [MeterID] {
        state.withLockedValue { $0.meters.keys.filter { $0.accessory == accessory } }.sorted { $0.meter < $1.meter }
    }

    /// Whether an accessory itself has a Meter (not the device's other accessories).
    public func hasMeters(accessory: String) -> Bool {
        state.withLockedValue { $0.meters.keys.contains { $0.accessory == accessory } }
    }

    /// Whether any Meter of an accessory or of the device's other accessories (`<accessory>:<more>`) has a history.
    public func hasHistory(accessory: String) -> Bool {
        state.withLockedValue { $0.meters.keys.contains { Self.belongs($0, to: accessory) } }
    }

    /// Forgets every Meter of an accessory and of the device's other accessories (`<accessory>:<more>`), files included.
    public func forget(accessory: String) {
        let gone = state.withLockedValue { state -> [MeterID] in
            let gone = state.meters.keys.filter { Self.belongs($0, to: accessory) }
            for id in gone {
                state.meters[id] = nil
                state.holding.remove(id)
                state.dirty[id] = nil
            }
            return gone
        }
        guard let directory, !gone.isEmpty else { return }
        // What is due for the other Meters, now: a save under way cannot write the folder back after it goes.
        flush()
        for id in gone { try? FileManager.default.removeItem(at: Self.folder(of: id, in: directory)) }
    }

    private static func belongs(_ id: MeterID, to accessory: String) -> Bool {
        id.accessory == accessory || id.accessory.hasPrefix("\(accessory):")
    }

    // MARK: Reading back

    /// A Meter's hours from `from` to `to`, oldest first, those with nothing known left out.
    public func hours(of id: MeterID, from: Date, to: Date) -> [MeterHour] {
        let first = Self.hourIndex(from), last = Self.hourIndex(to)
        guard first <= last else { return [] }
        let span = Self.position(from).year...Self.position(to).year
        // The years in memory, then those only on disk, read outside the lock.
        guard var years = state.withLockedValue({ state in state.meters[id].map { $0.years.filter { span.contains($0.key) } } }) else { return [] }
        for year in span where years[year] == nil { years[year] = readYear(year, of: id) }
        var found: [MeterHour] = []
        for year in span {
            let base = Self.yearStart(year) / 3600
            for (offset, hour) in (years[year] ?? [:]).filter({ (first...last).contains(base + $0.key) }).sorted(by: { $0.key < $1.key }) {
                found.append(Self.merged(hour, start: Date(timeIntervalSince1970: TimeInterval((base + offset) * 3600))))
            }
        }
        return found
    }

    /// A Meter's days (`.day`) or months (`.month`) from the one `from` is in to the one `to` is in, in `timeZone`,
    /// oldest first, each with the hours that start in it.
    public func periods(of id: MeterID, _ unit: Calendar.Component, from: Date, to: Date, timeZone: TimeZone) -> [MeterPeriod] {
        guard let span = EnergyCalendar.periods(unit, from: from, to: to, timeZone: timeZone) else { return [] }
        var periods = span.starts.map(MeterPeriod.init(start:))
        // Both oldest first: one pass.
        var index = 0
        for hour in hours(of: id, from: span.starts[0], to: span.end.addingTimeInterval(-1)) {
            while index + 1 < periods.count, periods[index + 1].start <= hour.start { index += 1 }
            periods[index].add(hour)
        }
        return periods
    }

    /// An hour as it reads: the bridge's measurement, each figure it lacks from the import; for an estimate, the
    /// import's figures where it has them.
    static func merged(_ hour: Hour, start: Date) -> MeterHour {
        let estimate = hour.e ?? false
        if estimate && (hour.ic != nil || hour.ir != nil) {
            return MeterHour(start: start, consumption: hour.ic ?? hour.c, returned: hour.ir ?? hour.r, recorded: false)
        }
        let recorded = (hour.c != nil || hour.r != nil) && !estimate
        return MeterHour(start: start, consumption: hour.c ?? hour.ic, returned: hour.r ?? hour.ir, recorded: recorded)
    }

    // MARK: Spreading energy over hours

    private static func isNewer(_ at: Date, than reading: Reading?) -> Bool {
        reading.map { at >= $0.at } ?? true
    }

    /// The held power from where it was counted to `date`, for the directions without a counter, and no further than
    /// `longestHold` after it was read.
    private func hold(_ meter: inout Meter, to date: Date, years: inout Set<Int>, id: MeterID) {
        guard let power = meter.power, let read = meter.powerRead else { return }
        let end = min(date, read.addingTimeInterval(Self.longestHold))
        guard end > power.at else { return }
        meter.power = Reading(value: power.value, at: end)
        let direction: MeterDirection = power.value >= 0 ? .consumption : .returned
        guard power.value != 0, meter.counters[direction] == nil else { return }
        spread(abs(power.value) * end.timeIntervalSince(power.at) / 3600, direction, from: power.at, to: end, estimate: false,
               into: &meter, years: &years, id: id)
    }

    /// Adds `wattHours`, spent evenly from `from` to `to`, to the hours it covers.
    private func spread(_ wattHours: Double, _ direction: MeterDirection, from: Date, to: Date, estimate: Bool,
                        into meter: inout Meter, years: inout Set<Int>, id: MeterID) {
        let whole = to.timeIntervalSince(from)
        guard whole > 0, wattHours > 0 else { return }
        var cursor = from
        while cursor < to {
            let next = min(to, Date(timeIntervalSince1970: TimeInterval((Self.hourIndex(cursor) + 1) * 3600)))
            let share = wattHours * next.timeIntervalSince(cursor) / whole
            let (year, offset) = Self.position(cursor)
            load(year, of: id, into: &meter)
            var hour = meter.years[year]?[offset] ?? Hour()
            switch direction {
            case .consumption: hour.c = (hour.c ?? 0) + share
            case .returned: hour.r = (hour.r ?? 0) + share
            }
            if estimate { hour.e = true }
            meter.years[year]?[offset] = hour
            years.insert(year)
            cursor = next
        }
    }

    // MARK: Hours and years

    /// Hours since 1970.
    public static func hourIndex(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 3600).rounded(.down)) }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The first second of each UTC year asked for, worked out once.
    private static let yearStarts = NIOLockedValueBox<[Int: Int]>([:])

    static func yearStart(_ year: Int) -> Int {
        if let known = yearStarts.withLockedValue({ $0[year] }) { return known }
        let start = Int(utc.date(from: DateComponents(year: year, month: 1, day: 1))!.timeIntervalSince1970)
        yearStarts.withLockedValue { $0[year] = start }
        return start
    }

    /// The UTC year an instant is in, and its hour's offset from the year's first.
    static func position(_ date: Date) -> (year: Int, offset: Int) {
        let hour = hourIndex(date)
        // A guess from the average year's 8 766 hours, then corrected.
        var year = 1970 + Int((Double(hour) / 8766).rounded(.down))
        while yearStart(year + 1) / 3600 <= hour { year += 1 }
        while yearStart(year) / 3600 > hour { year -= 1 }
        return (year, hour - yearStart(year) / 3600)
    }

    static func folder(of id: MeterID, in directory: URL) -> URL {
        directory.appendingPathComponent(Secrets.base64URL(Data("\(id.accessory)\u{0}\(id.meter)".utf8)), isDirectory: true)
    }

    /// A year's hours from its file; empty when it has none.
    private func readYear(_ year: Int, of id: MeterID) -> [Int: Hour] {
        guard let directory,
              let data = try? Data(contentsOf: Self.folder(of: id, in: directory).appendingPathComponent("\(year).json")),
              let stored = try? JSONDecoder().decode([String: Hour].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, hour in Int(key).map { ($0, hour) } })
    }

    /// Puts a year in memory before a reading reaches it.
    private func load(_ year: Int, of id: MeterID, into meter: inout Meter) {
        if meter.years[year] == nil { meter.years[year] = readYear(year, of: id) }
    }

    // MARK: Changes

    /// Changes one Meter under the lock and schedules a save.
    private func changing(_ id: MeterID, _ change: (inout Meter, inout Set<Int>) -> Void) {
        if state.withLockedValue({ mutate(id, in: &$0, change) }) { scheduleSave() }
    }

    /// Changes one Meter in place, and marks what is to be written: its `meter.json` when it is new or its counters
    /// moved, and the years changed. Returns whether anything is to be written.
    private func mutate(_ id: MeterID, in state: inout State, _ change: (inout Meter, inout Set<Int>) -> Void) -> Bool {
        let isNew = state.meters[id] == nil
        var years: Set<Int> = []
        // Changed through the dictionary's subscript, in place: a copy of the Meter would copy a year of hours.
        func apply(_ meter: inout Meter) -> (countersMoved: Bool, holding: Bool) {
            let before = meter.counters
            change(&meter, &years)
            return (meter.counters != before, meter.power != nil)
        }
        let (countersMoved, holding) = apply(&state.meters[id, default: Meter()])
        if holding { state.holding.insert(id) }
        guard isNew || countersMoved || !years.isEmpty else { return false }
        state.dirty[id, default: []].formUnion(years)
        return true
    }

    // MARK: Files

    private func scheduleSave() {
        guard directory != nil else { return }
        saving.schedule(after: saveDelay) { [weak self] in self?.write() }
    }

    /// Writes what changed now; the metrics store calls it when it stops.
    public func flush() {
        saving.flush { [weak self] in self?.write() }
    }

    private func write() {
        guard let directory else { return }
        let pending = state.withLockedValue { state -> [(Stored, [(Int, [Int: Hour])])] in
            defer { state.dirty = [:] }
            return state.dirty.compactMap { id, years in
                guard let meter = state.meters[id] else { return nil }
                return (Stored(version: Self.version, id: id, counters: meter.counters, kind: meter.kind == .electricity ? nil : meter.kind), years.compactMap { year in meter.years[year].map { (year, $0) } })
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (stored, years) in pending {
            let folder = Self.folder(of: stored.id, in: directory)
            if let data = try? encoder.encode(stored) { try? OwnerOnlyFile.write(data, to: folder.appendingPathComponent("meter.json")) }
            for (year, hours) in years {
                try? OwnerOnlyFile.write(Self.encoded(hours), to: folder.appendingPathComponent("\(year).json"))
            }
        }
    }

    /// A year file's bytes: what `JSONEncoder` writes for `[String: Hour]` with sorted keys, watt-hours to a thousandth,
    /// written straight as bytes (the encoder's generic path is slow for thousands of hours, as `EnergyArchive` found).
    static func encoded(_ hours: [Int: Hour]) -> Data {
        func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        var json = JSONBytesWriter(capacity: hours.count * 40)
        json.object { json in
            // Sorted as the encoder sorts keys: by their text.
            for (key, hour) in hours.map({ (String($0.key), $0.value) }).sorted(by: { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }) {
                json.key(key)
                json.object { json in
                    if let value = hour.c { json.field("c", .number(round(value))) }
                    if let value = hour.e { json.field("e", .bool(value)) }
                    if let value = hour.ic { json.field("ic", .number(round(value))) }
                    if let value = hour.ir { json.field("ir", .number(round(value))) }
                    if let value = hour.r { json.field("r", .number(round(value))) }
                }
            }
        }
        return Data(json.bytes)
    }
}
