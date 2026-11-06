import Foundation
import Homeswift
import NIOConcurrencyHelpers

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// How long the History and the Logbook keep what they record: a Bridge Setting (`historyDays`, `historyYears` in the
/// bridge block).
public struct HistoryRetention: Sendable, Equatable {
    /// Each change, and the Logbook, for this many days.
    public var days: Int
    /// The hourly figures of numbers for this many years.
    public var years: Int

    public static let defaultDays = 14
    public static let defaultYears = 10
    public static let days: ClosedRange<Int> = 1...90
    public static let years: ClosedRange<Int> = 1...20

    public init(days: Int = defaultDays, years: Int = defaultYears) {
        self.days = min(max(days, Self.days.lowerBound), Self.days.upperBound)
        self.years = min(max(years, Self.years.lowerBound), Self.years.upperBound)
    }

    /// The bridge block's.
    public init(_ bridge: HomeswiftConfiguration.Bridge) {
        self.init(days: bridge.historyDays ?? Self.defaultDays, years: bridge.historyYears ?? Self.defaultYears)
    }
}

/// One characteristic of one accessory the History follows.
public struct HistorySeries: Sendable, Equatable, Codable {
    /// A number (temperature, brightness, power: kept at most every `HistoryStore.interval` and by the hour), or a
    /// state (on, open, locked, a mode, a string: every change).
    public enum Kind: String, Sendable, Codable { case number, state }

    public var id: Int
    /// The accessory's id, the service's type and subtype and the characteristic's type: what stays for as long as
    /// the accessory does.
    public var key: String
    public var accessory: String
    public var accessoryName: String
    /// The service's name; empty for a service without one.
    public var service: String
    public var characteristic: String
    public var unit: String?
    public var kind: Kind
    /// Its valid values, for a state that is a number (a mode, a door's state).
    public var validValues: [Int]?
    /// The last value recorded, and when.
    public var last: HAPValue?
    public var lastAt: Date?
}

/// A value a characteristic took, and when.
public struct HistoryPoint: Sendable, Equatable {
    public var time: Date
    public var value: HAPValue

    public init(time: Date, value: HAPValue) {
        self.time = time
        self.value = value
    }
}

/// An hour of a number: its lowest, its time-weighted mean and its highest.
public struct HistoryHour: Sendable, Equatable {
    public var start: Date
    public var min: Double
    public var mean: Double
    public var max: Double

    public init(start: Date, min: Double, mean: Double, max: Double) {
        self.start = start
        self.min = min
        self.mean = mean
        self.max = max
    }
}

/// One line of the Logbook: a state change or a write, with its Change Source.
public struct LogbookEntry: Sendable, Equatable, Codable {
    public var time: Date
    public var accessory: String
    public var accessoryName: String
    public var service: String?
    public var characteristic: String
    public var value: HAPValue
    public var source: ChangeSource
    /// A write (a person or a program asked for the value), rather than a change the accessory reported.
    public var write: Bool

    enum CodingKeys: String, CodingKey { case time = "t", accessory = "a", accessoryName = "n", service = "s", characteristic = "c", value = "v", source = "src", write = "w" }

    public init(time: Date, accessory: String, accessoryName: String, service: String?, characteristic: String, value: HAPValue, source: ChangeSource, write: Bool) {
        self.time = time
        self.accessory = accessory
        self.accessoryName = accessoryName
        self.service = service
        self.characteristic = characteristic
        self.value = value
        self.source = source
        self.write = write
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .time) / 1000)
        accessory = try container.decode(String.self, forKey: .accessory)
        accessoryName = try container.decode(String.self, forKey: .accessoryName)
        service = try container.decodeIfPresent(String.self, forKey: .service)
        characteristic = try container.decode(String.self, forKey: .characteristic)
        value = try container.decode(HAPValue.self, forKey: .value)
        source = try container.decode(ChangeSource.self, forKey: .source)
        write = try container.decodeIfPresent(Bool.self, forKey: .write) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode((time.timeIntervalSince1970 * 1000).rounded(), forKey: .time)
        try container.encode(accessory, forKey: .accessory)
        try container.encode(accessoryName, forKey: .accessoryName)
        try container.encodeIfPresent(service, forKey: .service)
        try container.encode(characteristic, forKey: .characteristic)
        try container.encode(value, forKey: .value)
        try container.encode(source, forKey: .source)
        if write { try container.encode(true, forKey: .write) }
    }
}

/// What to read from the Logbook. Entries come newest first.
public struct LogbookQuery: Sendable {
    public var from: Date?
    public var to: Date?
    /// Only these accessories (ids); nil for all.
    public var accessories: Set<String>?
    /// Only this kind of Change Source (`ChangeSource.kind`), and this name of it.
    public var sourceKind: String?
    public var sourceName: String?
    public var limit: Int

    public init(from: Date? = nil, to: Date? = nil, accessories: Set<String>? = nil, sourceKind: String? = nil, sourceName: String? = nil, limit: Int = 200) {
        self.from = from
        self.to = to
        self.accessories = accessories
        self.sourceKind = sourceKind
        self.sourceName = sourceName
        self.limit = limit
    }
}

/// The History and the Logbook (GLOSSARY.md): every characteristic change of every accessory, and what changed in the
/// home with its Change Source.
///
/// A state (a boolean, a mode, a string) is kept at each change. A number is kept at most every `interval` per
/// characteristic: at once when it moved by more than its step (its `minStep`, or half a percent of its range) since
/// the last kept, else once it settles, so the last value of a burst is always there. Each number also has its
/// hourly lowest, time-weighted mean and highest, kept for `retention.years`. The Logbook has the state changes, the
/// targets' and every write, each with its Change Source (`ChangeSource.resolved` where the change is made); numbers
/// that only report a reading are left out.
///
/// Files, under `directory`, as `MeterArchive`'s pattern has them: `series.json` (the characteristics followed, by
/// number, with their last value), `changes/<UTC day>.tsv` (`<ms>\t<series>\t<JSON value>` lines), `hours/<series>/<UTC
/// year>.tsv` (`<hour start, s>\t<min>\t<mean>\t<max>`) and `logbook/<UTC day>.jsonl`. Lines are buffered and appended
/// every `interval`; days past `retention.days` and years past `retention.years` are deleted.
public final class HistoryStore: @unchecked Sendable {
    /// The shortest time between two kept values of one number.
    public let interval: TimeInterval
    public let retention: HistoryRetention
    public let directory: URL?
    let now: @Sendable () -> Date

    private struct Number {
        var step: Double
        /// The last value kept, and one waiting for `interval` to pass or for the value to settle.
        var kept: HistoryPoint?
        var pending: HistoryPoint?
        /// The hour being summed: its start, its range, and the value held since `segment`.
        var hour: Date?
        var minimum = Double.infinity
        var maximum = -Double.infinity
        var weighted = 0.0
        var covered = 0.0
        var held: Double?
        var segment: Date?

        /// Nothing held: the next change starts a new hour.
        mutating func reset() {
            hour = nil
            held = nil
            segment = nil
            weighted = 0
            covered = 0
        }
    }

    private struct State {
        var series: [String: HistorySeries] = [:]
        var nextID = 1
        /// The series of each characteristic followed, by object; made again when accessories change.
        var known: [ObjectIdentifier: String] = [:]
        /// The characteristics followed that the History does not keep (data, confidential): not looked up again.
        var unkept: Set<ObjectIdentifier> = []
        var numbers: [String: Number] = [:]
        /// Lines waiting to be appended, by file (relative to `directory`).
        var lines: [String: [String]] = [:]
        /// In memory without a directory (tests, a library): every line, by file.
        var memory: [String: [String]] = [:]
        var indexDirty = false
        /// Only the series' last values changed: written at most every `indexInterval`, and at stop.
        var lastDirty = false
        var indexWritten: Date?
        /// The last Logbook entry of each series: a write that follows the change it made is not logged twice.
        var lastLogged: [String: LogbookEntry] = [:]
        /// Where each series' last Logbook line waits in `lines` (its file and place), for a write to mark it.
        var lastLine: [String: (file: String, index: Int)] = [:]
        /// A structure change waits to seed the accessories again.
        var seedPending = false
        var lastPrune: Date?
    }

    private let state = NIOLockedValueBox(State())
    /// Held while files are written or read.
    private let io = NIOLock()
    private let following = NIOLockedValueBox<(Observation, Task<Void, Never>)?>(nil)

    /// `directory` nil keeps everything in memory. `now` and `interval` are for tests.
    public init(directory: URL?, retention: HistoryRetention = HistoryRetention(), interval: TimeInterval = 10, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.retention = retention
        self.interval = interval
        self.now = now
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("series.json")),
              let stored = try? JSONDecoder().decode(StoredIndex.self, from: data), stored.version == Self.version else { return }
        state.withLockedValue { state in
            state.series = Dictionary(stored.series.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            state.nextID = (stored.series.map(\.id).max() ?? 0) + 1
        }
    }

    static let version = 1

    private struct StoredIndex: Codable {
        var version: Int
        var series: [HistorySeries]
    }

    // MARK: Following

    /// Follows every change and write on the host's servers, and records each accessory's values as they stand.
    public func start(following host: PluginHost) {
        let changes = host.observeChanges { [weak self] accessory, characteristic, value in
            self?.recordChange(of: characteristic, in: accessory, value: value, source: ChangeSource.resolved)
        }
        let writes = host.observeWrites { [weak self] accessory, characteristic, value in
            self?.recordWrite(of: characteristic, in: accessory, value: value, source: ChangeSource.resolved)
        }
        // A burst of structure changes (a plugin adding its devices one by one) makes one pass, off the plugin's path.
        let structure = host.observeStructure { [weak self, weak host] in
            guard let self, self.state.withLockedValue({ state in defer { state.seedPending = true }; return !state.seedPending }) else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self, weak host] in
                guard let self, let host else { return }
                self.state.withLockedValue { $0.seedPending = false }
                self.seed(host.bridges.flatMap(\.server.accessories))
            }
        }
        seed(host.bridges.flatMap(\.server.accessories))
        let interval = interval
        let ticker = Task { [weak self, weak host] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                ticks += 1
                // An accessory answering No Response holds no value: its hours stop until it reports again. Looked at
                // once a minute, for the accessories holding a number only.
                var silent: Set<String> = []
                if ticks % 6 == 0, let self, let host {
                    let holding = self.holdingAccessories
                    silent = Set(host.bridges.flatMap { bridge in holding.compactMap { bridge.server.accessory(id: $0) } }.filter(\.showsNoResponse).map(\.id))
                }
                self?.tick(silent: silent)
            }
        }
        following.withLockedValue { $0 = (Observation { changes.cancel(); writes.cancel(); structure.cancel() }, ticker) }
    }

    /// The accessories with a number held now.
    var holdingAccessories: Set<String> {
        state.withLockedValue { state in Set(state.numbers.compactMap { key, entry in entry.held == nil ? nil : state.series[key]?.accessory }) }
    }

    /// Stops following and writes what waits.
    public func stop() {
        let current = following.withLockedValue { value in defer { value = nil }; return value }
        current?.0.cancel()
        current?.1.cancel()
        tick()
        flush(all: true)
    }

    /// The values the accessories hold now, as their series' starting point: a value that differs from the last kept
    /// (it changed while the bridge was away) is recorded, as the Device's.
    func seed(_ accessories: [Accessory]) {
        let at = now()
        var fresh: [ObjectIdentifier: String] = [:]
        var unkept: Set<ObjectIdentifier> = []
        for accessory in accessories {
            for service in accessory.services {
                for characteristic in service.characteristics {
                    guard let key = series(for: characteristic, service: service, in: accessory) else { unkept.insert(ObjectIdentifier(characteristic)); continue }
                    fresh[ObjectIdentifier(characteristic)] = key
                    let value = characteristic.value
                    guard Self.isRecordable(value) else { continue }
                    let changed = state.withLockedValue { $0.series[key]?.last != value }
                    if changed {
                        record(value, key: key, at: at)
                    } else {
                        // Unchanged: the hour starts from it all the same.
                        state.withLockedValue { state in
                            guard let series = state.series[key], series.kind == .number, let number = value.doubleValue,
                                  var entry = state.numbers[key], entry.hour == nil else { return }
                            Self.hold(number, at: at, in: &entry, lines: &state.lines, series: series)
                            state.numbers[key] = entry
                        }
                    }
                }
            }
        }
        state.withLockedValue { state in
            state.known = fresh
            state.unkept = unkept
        }
    }

    /// The series of a characteristic, made the first time; nil for what the History does not keep.
    @discardableResult
    func series(for characteristic: Characteristic, service: Service, in accessory: Accessory) -> String? {
        let type = characteristic.type
        guard !characteristic.isConfidential, type.permissions.contains(.events), let kind = Self.kind(of: type) else { return nil }
        let key = "\(accessory.id)|\(service.type.uuid)|\(service.subtype ?? "")|\(type.uuid)"
        let serviceName = service[.configuredName]?.value.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? service[.name]?.value.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? ""
        let name = accessory.name
        state.withLockedValue { state in
            if var existing = state.series[key] {
                if existing.accessoryName != name || existing.service != serviceName {
                    existing.accessoryName = name
                    existing.service = serviceName
                    state.series[key] = existing
                    state.indexDirty = true
                }
            } else {
                state.series[key] = HistorySeries(
                    id: state.nextID, key: key, accessory: accessory.id, accessoryName: name, service: serviceName, characteristic: type.name,
                    unit: type.unit?.rawValue, kind: kind, validValues: type.validValues)
                state.nextID += 1
                state.indexDirty = true
            }
            if kind == .number, state.numbers[key] == nil {
                let range = (type.maxValue ?? 0) - (type.minValue ?? 0)
                state.numbers[key] = Number(step: max(type.minStep ?? 0, range > 0 ? range * 0.005 : 0))
            }
        }
        return key
    }

    /// A number when its format is one and it has no list of valid values; a state otherwise; nil for data.
    static func kind(of type: CharacteristicType) -> HistorySeries.Kind? {
        switch type.format {
        case .tlv8, .data: nil
        case .bool, .string: .state
        default: type.validValues == nil ? .number : .state
        }
    }

    static func isRecordable(_ value: HAPValue) -> Bool {
        switch value {
        case .null: false
        case .string(let text): text.utf8.count <= 256
        default: true
        }
    }

    private func key(of characteristic: Characteristic, in accessory: Accessory) -> String? {
        let id = ObjectIdentifier(characteristic)
        let (known, unkept) = state.withLockedValue { ($0.known[id], $0.unkept.contains(id)) }
        if let known { return known }
        if unkept { return nil }
        guard let service = accessory.services.first(where: { $0.characteristics.contains { $0 === characteristic } }),
              let key = series(for: characteristic, service: service, in: accessory) else {
            state.withLockedValue { _ = $0.unkept.insert(id) }
            return nil
        }
        state.withLockedValue { $0.known[id] = key }
        return key
    }

    // MARK: Recording

    /// A change of a characteristic's value, made by `source`.
    public func recordChange(of characteristic: Characteristic, in accessory: Accessory, value: HAPValue, source: ChangeSource) {
        guard Self.isRecordable(value), let key = key(of: characteristic, in: accessory) else { return }
        let at = now()
        record(value, key: key, at: at)
        guard let series = state.withLockedValue({ $0.series[key] }), Self.logs(series) else { return }
        log(LogbookEntry(time: at, accessory: series.accessory, accessoryName: series.accessoryName, service: series.service.isEmpty ? nil : series.service, characteristic: series.characteristic,
                         value: value, source: source, write: false), key: key)
    }

    /// A write of a characteristic, changed value or not, made by `source`: a Logbook entry, unless it is the one the
    /// change it made just logged.
    public func recordWrite(of characteristic: Characteristic, in accessory: Accessory, value: HAPValue, source: ChangeSource) {
        guard Self.isRecordable(value), !characteristic.isConfidential, Self.kind(of: characteristic.type) != nil else { return }
        let at = now()
        let key = key(of: characteristic, in: accessory) ?? "\(accessory.id)|write|\(characteristic.type.uuid)"
        let serviceName = state.withLockedValue { $0.series[key]?.service }.flatMap { $0.isEmpty ? nil : $0 }
        let entry = LogbookEntry(time: at, accessory: accessory.id, accessoryName: accessory.name, service: serviceName, characteristic: characteristic.type.name,
                                 value: value, source: source, write: true)
        // The change this write made was just logged: that line becomes the write's, rather than a second one.
        let marked = state.withLockedValue { state -> Bool in
            guard var last = state.lastLogged[key], last.value == value, last.source == source, at.timeIntervalSince(last.time) < 2 else { return false }
            if !last.write, let place = state.lastLine[key], let file = state.lines[place.file], file.indices.contains(place.index) {
                last.write = true
                guard let data = try? JSONEncoder().encode(last), let line = String(data: data, encoding: .utf8) else { return true }
                state.lines[place.file]?[place.index] = line
                state.lastLogged[key] = last
            }
            return true
        }
        if !marked { log(entry, key: key) }
    }

    /// Whether a series' changes go in the Logbook: states, and targets (what someone asked for).
    static func logs(_ series: HistorySeries) -> Bool {
        series.kind == .state || series.characteristic.hasPrefix("Target")
    }

    private func log(_ entry: LogbookEntry, key: String) {
        guard let data = try? JSONEncoder().encode(entry), let line = String(data: data, encoding: .utf8) else { return }
        let file = "logbook/\(Self.day(entry.time)).jsonl"
        state.withLockedValue { state in
            state.lastLogged[key] = entry
            state.lines[file, default: []].append(line)
            state.lastLine[key] = (file, state.lines[file]!.count - 1)
        }
    }

    private func record(_ value: HAPValue, key: String, at: Date) {
        state.withLockedValue { state in
            guard var series = state.series[key] else { return }
            series.last = value
            series.lastAt = at
            state.series[key] = series
            state.lastDirty = true
            guard series.kind == .number, let number = value.doubleValue, number.isFinite else {
                state.lines["changes/\(Self.day(at)).tsv", default: []].append(Self.line(at, series.id, value))
                return
            }
            var entry = state.numbers[key] ?? Number(step: 0)
            Self.hold(number, at: at, in: &entry, lines: &state.lines, series: series)
            let point = HistoryPoint(time: at, value: value)
            if let kept = entry.kept, let last = kept.value.doubleValue {
                if at.timeIntervalSince(kept.time) >= interval, abs(number - last) > entry.step {
                    state.lines["changes/\(Self.day(at)).tsv", default: []].append(Self.line(at, series.id, value))
                    entry.kept = point
                    entry.pending = nil
                } else {
                    entry.pending = number == last ? nil : point
                }
            } else {
                state.lines["changes/\(Self.day(at)).tsv", default: []].append(Self.line(at, series.id, value))
                entry.kept = point
            }
            state.numbers[key] = entry
        }
    }

    /// Moves a number's hour on to `at` (closing the hours it passes, each with the value held across it), then holds
    /// `value` from there.
    private static func hold(_ value: Double?, at: Date, in entry: inout Number, lines: inout [String: [String]], series: HistorySeries) {
        advance(&entry, to: at, lines: &lines, series: series)
        guard let value else { return }
        if entry.hour == nil {
            entry.hour = hourStart(at)
            entry.minimum = value
            entry.maximum = value
        }
        entry.minimum = min(entry.minimum, value)
        entry.maximum = max(entry.maximum, value)
        entry.held = value
        entry.segment = at
    }

    private static func advance(_ entry: inout Number, to at: Date, lines: inout [String: [String]], series: HistorySeries) {
        while let hour = entry.hour, let held = entry.held, let segment = entry.segment {
            let end = hour.addingTimeInterval(3600)
            let until = min(at, end)
            if until > segment {
                entry.weighted += held * until.timeIntervalSince(segment)
                entry.covered += until.timeIntervalSince(segment)
                entry.segment = until
            }
            guard at >= end else { return }
            close(entry, into: &lines, series: series)
            // A day past without a tick (the machine slept): the time between is not known, so nothing is held across it.
            if at.timeIntervalSince(end) > 86_400 {
                entry.reset()
                return
            }
            entry.hour = end
            entry.minimum = held
            entry.maximum = held
            entry.weighted = 0
            entry.covered = 0
            entry.segment = end
        }
    }

    /// Closes a number's hour at its last reading and holds nothing more, until its next change.
    private static func release(_ entry: inout Number, lines: inout [String: [String]], series: HistorySeries) {
        close(entry, into: &lines, series: series)
        entry.reset()
    }

    /// The hour's line: its lowest, time-weighted mean and highest, when any time was counted.
    private static func close(_ entry: Number, into lines: inout [String: [String]], series: HistorySeries) {
        guard let hour = entry.hour, entry.covered > 0 else { return }
        lines["hours/\(series.id)/\(year(hour)).tsv", default: []].append(
            "\(Int(hour.timeIntervalSince1970))\t\(format(entry.minimum))\t\(format(entry.weighted / entry.covered))\t\(format(entry.maximum))")
    }

    /// Keeps the numbers that waited, closes the hours that ended, and writes what waits; deletes what is past its
    /// retention once an hour.
    public func tick(silent: Set<String> = []) {
        let at = now()
        let interval = interval
        state.withLockedValue { state in
            for (key, var entry) in state.numbers {
                guard let series = state.series[key] else { continue }
                // No Response: the hour under way closes at its last reading, and nothing is held after it.
                if silent.contains(series.accessory), entry.held != nil {
                    // Held up to now (at most a tick past its silence), then closed.
                    Self.advance(&entry, to: at, lines: &state.lines, series: series)
                    Self.release(&entry, lines: &state.lines, series: series)
                    state.numbers[key] = entry
                    continue
                }
                if let pending = entry.pending, let kept = entry.kept, at.timeIntervalSince(kept.time) >= interval,
                   let value = pending.value.doubleValue, let last = kept.value.doubleValue,
                   abs(value - last) > entry.step || at.timeIntervalSince(pending.time) >= interval {
                    state.lines["changes/\(Self.day(pending.time)).tsv", default: []].append(Self.line(pending.time, series.id, pending.value))
                    entry.kept = pending
                    entry.pending = nil
                }
                Self.advance(&entry, to: at, lines: &state.lines, series: series)
                state.numbers[key] = entry
            }
        }
        flush()
        let prune = state.withLockedValue { state -> Bool in
            guard state.lastPrune.map({ at.timeIntervalSince($0) >= 3600 }) ?? true else { return false }
            state.lastPrune = at
            return true
        }
        if prune { self.prune(at: at) }
    }

    /// Writes the lines waiting and the index, when it changed.
    /// How often the series' last values alone are written to `series.json`.
    static let indexInterval: TimeInterval = 300

    /// Writes the lines waiting, and the index when a series came or was renamed, when its last values are
    /// `indexInterval` old, or with `all` (at stop).
    public func flush(all: Bool = false) {
        let at = now()
        let (lines, index) = state.withLockedValue { state -> ([String: [String]], [HistorySeries]?) in
            let due = state.indexDirty || (state.lastDirty && (all || state.indexWritten.map { at.timeIntervalSince($0) >= Self.indexInterval } ?? true))
            defer {
                state.lines = [:]
                state.lastLine = [:]
                if due { state.indexDirty = false; state.lastDirty = false; state.indexWritten = at }
            }
            return (state.lines, due ? Array(state.series.values) : nil)
        }
        guard !lines.isEmpty || index != nil else { return }
        io.withLock {
            guard let directory else {
                state.withLockedValue { state in for (file, more) in lines { state.memory[file, default: []].append(contentsOf: more) } }
                return
            }
            for (file, more) in lines {
                Self.append(more.joined(separator: "\n") + "\n", to: directory.appendingPathComponent(file))
            }
            if let index, let data = try? JSONEncoder().encode(StoredIndex(version: Self.version, series: index.sorted { $0.id < $1.id })) {
                try? OwnerOnlyFile.write(data, to: directory.appendingPathComponent("series.json"))
            }
        }
    }

    /// Deletes the days and years past their retention.
    func prune(at: Date) {
        let firstDay = Self.day(at.addingTimeInterval(-Double(retention.days) * 86_400))
        let firstYear = Self.year(at) - retention.years
        io.withLock {
            guard let directory else {
                state.withLockedValue { state in
                    state.memory = state.memory.filter { file, _ in Self.keeps(file, firstDay: firstDay, firstYear: firstYear) }
                }
                return
            }
            let manager = FileManager.default
            for folder in ["changes", "logbook"] {
                for file in (try? manager.contentsOfDirectory(atPath: directory.appendingPathComponent(folder).path)) ?? []
                where !Self.keeps("\(folder)/\(file)", firstDay: firstDay, firstYear: firstYear) {
                    try? manager.removeItem(at: directory.appendingPathComponent(folder).appendingPathComponent(file))
                }
            }
            let hours = directory.appendingPathComponent("hours")
            for series in (try? manager.contentsOfDirectory(atPath: hours.path)) ?? [] {
                for file in (try? manager.contentsOfDirectory(atPath: hours.appendingPathComponent(series).path)) ?? []
                where !Self.keeps("hours/\(series)/\(file)", firstDay: firstDay, firstYear: firstYear) {
                    try? manager.removeItem(at: hours.appendingPathComponent(series).appendingPathComponent(file))
                }
            }
        }
    }

    static func keeps(_ file: String, firstDay: String, firstYear: Int) -> Bool {
        let name = (file as NSString).lastPathComponent
        let stem = name.split(separator: ".").first.map(String.init) ?? name
        if file.hasPrefix("hours/") { return Int(stem).map { $0 >= firstYear } ?? true }
        return stem >= firstDay
    }

    // MARK: Reading

    /// Every series of an accessory, or of every accessory.
    public func series(accessory: String? = nil) -> [HistorySeries] {
        state.withLockedValue { Array($0.series.values) }.filter { accessory == nil || $0.accessory == accessory }.sorted { $0.id < $1.id }
    }

    /// The values a series took from `from` to `to`, oldest first, and the value it held at `from` (the last before it
    /// still kept), when known.
    public func changes(of series: HistorySeries, from: Date, to: Date) -> (before: HistoryPoint?, points: [HistoryPoint]) {
        changes(of: [series], from: from, to: to)[series.id] ?? (nil, [])
    }

    /// The same for several series at once (an accessory's), each day file read once.
    public func changes(of many: [HistorySeries], from: Date, to: Date) -> [Int: (before: HistoryPoint?, points: [HistoryPoint])] {
        flush()
        let first = max(from, now().addingTimeInterval(-Double(retention.days + 1) * 86_400))
        let wanted = Set(many.map(\.id))
        var found: [Int: (before: HistoryPoint?, points: [HistoryPoint])] = Dictionary(uniqueKeysWithValues: many.map { ($0.id, (nil, [])) })
        // Each day from the first kept to `to`: one before `from` too, for the value held at the start.
        var day = Self.dayStart(first.addingTimeInterval(-86_400))
        while day <= to {
            for line in lines(of: "changes/\(Self.day(day)).tsv") {
                let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3, let id = Int(fields[1]), wanted.contains(id), let point = Self.parse(line, series: id) else { continue }
                if point.time < from {
                    found[id]?.before = point
                } else if point.time <= to {
                    found[id]?.points.append(point)
                }
            }
            day = day.addingTimeInterval(86_400)
        }
        for series in many {
            if found[series.id]?.before == nil, let last = series.last, let lastAt = series.lastAt, lastAt < from {
                found[series.id]?.before = HistoryPoint(time: lastAt, value: last)
            }
            found[series.id]?.points.sort { $0.time < $1.time }
        }
        return found
    }

    /// A number's hours from `from` to `to`, oldest first, the hour under way included.
    public func hours(of series: HistorySeries, from: Date, to: Date) -> [HistoryHour] {
        flush()
        var hours: [HistoryHour] = []
        for year in Self.year(from)...Self.year(to) {
            for line in lines(of: "hours/\(series.id)/\(year).tsv") {
                let fields = line.split(separator: "\t")
                guard fields.count == 4, let start = Double(fields[0]), let low = Double(fields[1]), let mean = Double(fields[2]), let high = Double(fields[3]) else { continue }
                let date = Date(timeIntervalSince1970: start)
                if date >= Self.hourStart(from), date <= to { hours.append(HistoryHour(start: date, min: low, mean: mean, max: high)) }
            }
        }
        let current = state.withLockedValue { state -> HistoryHour? in
            guard let entry = state.numbers[series.key], let hour = entry.hour, let held = entry.held, let segment = entry.segment else { return nil }
            let until = now()
            let weighted = entry.weighted + held * max(0, until.timeIntervalSince(segment))
            let covered = entry.covered + max(0, until.timeIntervalSince(segment))
            return HistoryHour(start: hour, min: entry.minimum, mean: covered > 0 ? weighted / covered : held, max: entry.maximum)
        }
        if let current, current.start >= Self.hourStart(from), current.start <= to, !hours.contains(where: { $0.start == current.start }) { hours.append(current) }
        return hours.sorted { $0.start < $1.start }
    }

    /// The first time a series has anything kept: its first change, else its first hour.
    public func earliest(of series: HistorySeries) -> Date? {
        let horizon = now().addingTimeInterval(-Double(retention.days) * 86_400)
        let early = changes(of: series, from: horizon, to: now())
        let hour = series.kind == .number ? hours(of: series, from: now().addingTimeInterval(-Double(retention.years) * 366 * 86_400), to: now()).first?.start : nil
        return [early.before?.time, early.points.first?.time, hour].compactMap { $0 }.min()
    }

    /// The Logbook's entries that match, newest first.
    public func logbook(_ query: LogbookQuery) -> [LogbookEntry] {
        flush()
        let to = query.to ?? now()
        let from = max(query.from ?? .distantPast, now().addingTimeInterval(-Double(retention.days + 1) * 86_400))
        var found: [LogbookEntry] = []
        var day = Self.dayStart(to)
        let decoder = JSONDecoder()
        let needles = query.accessories.flatMap { ids in ids.count <= 20 ? ids.compactMap { id in (try? JSONEncoder().encode(id)).flatMap { String(data: $0, encoding: .utf8) }.map { "\"a\":\($0)" } } : nil }
        while day >= Self.dayStart(from), found.count < query.limit {
            var entries: [LogbookEntry] = []
            for line in lines(of: "logbook/\(Self.day(day)).jsonl") {
                // An accessory asked for: the lines that name it are the only ones decoded.
                if let needles, !needles.contains(where: { line.contains($0) }) { continue }
                guard let entry = try? decoder.decode(LogbookEntry.self, from: Data(line.utf8)), entry.time >= from, entry.time <= to else { continue }
                if let accessories = query.accessories, !accessories.contains(entry.accessory) { continue }
                if let kind = query.sourceKind, entry.source.kind != kind { continue }
                if let name = query.sourceName, entry.source.name != name { continue }
                entries.append(entry)
            }
            found.append(contentsOf: entries.reversed())
            day = day.addingTimeInterval(-86_400)
        }
        // Newest first already: the days from the last, each day's lines from its end.
        return Array(found.prefix(query.limit))
    }

    /// The lines of a file, from disk or memory.
    private func lines(of file: String) -> [Substring] {
        io.withLock {
            guard let directory else { return state.withLockedValue { ($0.memory[file] ?? []).map { Substring($0) } } }
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(file).path), let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n")
        }
    }

    // MARK: Lines

    static func line(_ at: Date, _ series: Int, _ value: HAPValue) -> String {
        "\(Int((at.timeIntervalSince1970 * 1000).rounded()))\t\(series)\t\(encode(value))"
    }

    static func parse(_ line: Substring, series: Int) -> HistoryPoint? {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, Int(fields[1]) == series, let ms = Double(fields[0]), let value = decode(fields[2]) else { return nil }
        return HistoryPoint(time: Date(timeIntervalSince1970: ms / 1000), value: value)
    }

    static func encode(_ value: HAPValue) -> String {
        switch value {
        case .bool(let flag): flag ? "true" : "false"
        case .int(let number): String(number)
        case .double(let number): format(number)
        case .string(let text):
            (try? String(data: JSONEncoder().encode(text), encoding: .utf8) ?? "\"\"") ?? "\"\""
        case .null: "null"
        }
    }

    static func decode(_ text: Substring) -> HAPValue? {
        switch text {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default:
            if text.first == "\"" { return (try? JSONDecoder().decode(String.self, from: Data(text.utf8))).map(HAPValue.string) }
            if let number = Int(text) { return .int(number) }
            return Double(text).map(HAPValue.double)
        }
    }

    static func format(_ number: Double) -> String {
        let rounded = (number * 10_000).rounded() / 10_000
        return rounded == rounded.rounded() && abs(rounded) < 1e15 ? String(Int(rounded)) : String(rounded)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func day(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    static func dayStart(_ date: Date) -> Date { utc.startOfDay(for: date) }
    static func year(_ date: Date) -> Int { utc.component(.year, from: date) }
    static func hourStart(_ date: Date) -> Date { Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600) }

    /// Appends to a file the owner alone reads, made with its folder when missing.
    static func append(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(Windows)
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close() } else { try? Data(text.utf8).write(to: url) }
        #else
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.close()
        #endif
    }
}
