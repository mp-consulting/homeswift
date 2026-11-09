import Foundation
import Homeswift
import Logging
import NIOConcurrencyHelpers

/// Where a plugin's energy history import stands, kept by the runtime (`energy-history-<name>.json` in the plugin's
/// storage): what was imported, from where the next pass goes on, and onto which Meters, so a new version or another
/// device's Meters drop the old hours (docs/adr/0009-one-energy-history-import.md).
public struct EnergyHistoryState: Codable, Sendable, Equatable {
    /// The plugin's version of its history: another one reads it again from the start, its old hours dropped.
    public var version: Int
    /// What the history is read from, when the plugin says (`EnergyHistoryPass.identify`): a STREAM's serial number. Another
    /// one drops what went onto the old one's Meters, and reads it again from the start.
    public var identity: String?
    /// The first hour imported.
    public var from: Date?
    /// When the last whole pass ended: the next one goes on `overlap` before it. Nil until a first whole pass is done.
    public var through: Date?
    /// A first pass under way: where it goes on from (`EnergyHistoryPass.checkpoint`).
    public var resume: Date?
    /// The Meters the hours went onto, which a new version or identity forgets.
    public var meters: [MeterID]
    /// The plugin's own notes about its history (`EnergyHistoryPass.note`): kept with the rest, dropped with it.
    public var notes: [String: JSONValue]

    public init(version: Int, identity: String? = nil, from: Date? = nil, through: Date? = nil, resume: Date? = nil,
                meters: [MeterID] = [], notes: [String: JSONValue] = [:]) {
        self.version = version
        self.identity = identity
        self.from = from
        self.through = through
        self.resume = resume
        self.meters = meters
        self.notes = notes
    }
}

/// A pass failed: its message is the Status page's, and the next pass is in `retry`. Any other error says the same.
public struct EnergyHistoryFailure: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// One pass of an import (`EnergyHistoryImport.pass`): where it starts, and what the plugin's reading hands it.
public final class EnergyHistoryPass: Sendable {
    /// Where to read from: `overlap` before the last whole pass ended, where an unfinished first pass stopped, or nil for
    /// the history's start (the plugin's oldest record, its cloud's first day).
    public let since: Date?
    /// The pass's time.
    public let now: Date
    /// The first pass, or one made again from the start (`since` is where it goes on from, if anything).
    public let isFirst: Bool
    let box: NIOLockedValueBox<EnergyHistoryState>
    let restarted = NIOLockedValueBox(false)
    let added = NIOLockedValueBox(0)
    let progressSink: @Sendable (EnergyImportProgress) -> Void
    let forget: @Sendable ([MeterID]) -> Void
    let save: @Sendable (EnergyHistoryState) -> Void

    init(state: EnergyHistoryState, since: Date?, now: Date, progress: @escaping @Sendable (EnergyImportProgress) -> Void,
         forget: @escaping @Sendable ([MeterID]) -> Void, save: @escaping @Sendable (EnergyHistoryState) -> Void) {
        box = NIOLockedValueBox(state)
        self.since = since
        self.now = now
        isFirst = state.through == nil
        progressSink = progress
        self.forget = forget
        self.save = save
    }

    /// The state as it stands in the pass.
    public var state: EnergyHistoryState { box.withLockedValue { $0 } }

    /// Says what the history is read from (a device's serial number): the first time it is kept; another than the one
    /// kept drops the old one's hours and throws, and the import starts again from the start at once.
    public func identify(_ identity: String) throws {
        let previous = box.withLockedValue { $0 }
        if previous.identity == identity { return }
        if previous.identity != nil {
            forget(previous.meters)
            box.withLockedValue { $0 = EnergyHistoryState(version: $0.version, identity: identity) }
            save(state)
            restarted.withLockedValue { $0 = true }
            throw Restart()
        }
        box.withLockedValue { $0.identity = identity }
        save(state)
    }

    struct Restart: Error {}

    /// Hours of a Meter's past (`PluginMeter.importHours`): imported at once, the Meter remembered, the history's first
    /// hour kept.
    public func add(_ meter: PluginMeter, _ hours: [MeterHourImport]) {
        guard !hours.isEmpty else { return }
        meter.importHours(hours)
        added.withLockedValue { $0 += hours.count }
        let first = hours.map(\.start).min()
        let changed = box.withLockedValue { state -> Bool in
            var changed = false
            if !state.meters.contains(meter.id) { state.meters.append(meter.id); changed = true }
            if let first, state.from.map({ first < $0 }) ?? true { state.from = first; changed = true }
            return changed
        }
        if changed { save(state) }
    }

    /// A first pass's progress kept: one that stops (a failure, a restart) goes on from `resume` next time.
    public func checkpoint(_ resume: Date) {
        guard isFirst else { return }
        box.withLockedValue { $0.resume = resume }
        save(state)
    }

    /// How far the pass is, for the Status page: `done` of `total` (months, days, pages: the plugin's).
    public func progress(done: Int, total: Int) {
        let state = state
        progressSink(EnergyImportProgress(state: .running, done: done, total: total, from: state.from, through: state.through))
    }

    /// A note of the plugin's own about its history, kept until a new version or identity (nil drops it).
    public func note(_ key: String, _ value: JSONValue?) {
        box.withLockedValue { $0.notes[key] = value }
        save(state)
    }
}

/// A plugin's energy history import, run by the runtime the same way for every plugin (docs/adr/0009-one-energy-history-import.md):
/// the plugin says how to read its past (`read`, a pass at a time, handing each Meter's hours to `EnergyHistoryPass.add`),
/// and the runtime keeps where it stands, reads it again from the start for a new `version` (its old hours dropped),
/// goes on after a restart from the last checkpoint, reads the last days again every `interval` (`overlap` of them, a
/// cloud fills hours in late), tries again in `retry` after a failure, and says on the Status page how far it is.
/// Hours the bridge measured keep their own figures (`PluginMeter.importHours`).
///
/// Made by `PluginContext.energyHistory`; a plugin adds `run` to its tasks, or calls `pass` itself when its hours come
/// with its own poll (a cloud that sends the last days with each device list).
public final class EnergyHistoryImport: Sendable {
    public let name: String
    public let version: Int
    public let overlap: TimeInterval
    public let interval: Duration
    public let retry: Duration
    let file: JSONFile<EnergyHistoryState>
    let logger: Logger
    let progressSink: @Sendable (EnergyImportProgress) -> Void
    let forgetSink: @Sendable ([MeterID]) -> Void
    let migrate: @Sendable () -> EnergyHistoryState?
    /// One pass at a time.
    let running = NIOLockedValueBox(false)
    /// The state as last loaded or saved: the import is its file's only writer.
    let cached = NIOLockedValueBox<EnergyHistoryState?>(nil)

    init(name: String, version: Int, overlap: TimeInterval, interval: Duration, retry: Duration, file: JSONFile<EnergyHistoryState>, logger: Logger,
         progress: @escaping @Sendable (EnergyImportProgress) -> Void, forget: @escaping @Sendable ([MeterID]) -> Void,
         migrate: @escaping @Sendable () -> EnergyHistoryState? = { nil }) {
        self.name = name
        self.version = version
        self.overlap = overlap
        self.interval = interval
        self.retry = retry
        self.file = file
        self.logger = logger
        progressSink = progress
        forgetSink = forget
        self.migrate = migrate
    }

    /// Where it stands now.
    public var state: EnergyHistoryState {
        current()
    }

    /// The kept state, else what the plugin's own file said (`migrate`), else none; one of another version dropped (its
    /// Meters' imported hours forgotten), so the history is read again from the start.
    func current() -> EnergyHistoryState {
        if let kept = cached.withLockedValue({ $0 }) { return kept }
        // A plugin's former file is gone once taken: what it gave is saved at once, so it is never asked for again.
        let loaded = file.load()
        guard let kept = loaded ?? migrate() else { return EnergyHistoryState(version: version) }
        guard kept.version == version else {
            forgetSink(kept.meters)
            logger.info("The energy history (\(name)) is read again from the start: its way of reading changed")
            let fresh = EnergyHistoryState(version: version, identity: kept.identity)
            save(fresh)
            return fresh
        }
        if loaded == nil { save(kept) } else { cached.withLockedValue { $0 = kept } }
        return kept
    }

    /// Saves the state, and keeps it for `current`.
    func save(_ state: EnergyHistoryState) {
        cached.withLockedValue { $0 = state }
        try? file.save(state)
    }

    /// One pass: `read` from `since` on, its hours handed to the pass. True when it went through (nothing to import is
    /// fine); false when it failed, said on the Status page, or when another pass is under way.
    @discardableResult
    public func pass(now: Date = Date(), _ read: @Sendable (EnergyHistoryPass) async throws -> Void) async -> Bool {
        guard running.withLockedValue({ busy in
            if busy { return false }
            busy = true
            return true
        }) else { return false }
        defer { running.withLockedValue { $0 = false } }
        // An identity that changed starts again at once, from the start: twice at most.
        for _ in 0..<2 {
            let state = current()
            let since = state.through.map { $0.addingTimeInterval(-overlap) } ?? state.resume
            let pass = EnergyHistoryPass(state: state, since: since, now: now, progress: progressSink, forget: forgetSink, save: { [self] in save($0) })
            do {
                try await read(pass)
            } catch is EnergyHistoryPass.Restart {
                logger.info("The energy history (\(name)) is read from another device now: reading it again from the start")
                continue
            } catch {
                guard !Task.isCancelled else { return false }
                let kept = pass.state
                save(kept)
                progressSink(EnergyImportProgress(state: .failed, from: kept.from, through: kept.through, message: "\(error)"))
                logger.warning("Could not import the energy history (\(name)), trying again later: \(error)")
                return false
            }
            guard !Task.isCancelled else { return false }
            let hours = pass.added.withLockedValue { $0 }
            // Nothing there, ever (an account without the device the history is read from): nothing to say, and the
            // next pass is a first one still; the state is kept, so a plugin's former file is not taken again.
            if hours == 0, pass.state.from == nil {
                save(pass.state)
                return true
            }
            var done = pass.state
            done.through = now
            done.resume = nil
            save(done)
            progressSink(EnergyImportProgress(state: .done, from: done.from, through: now))
            if pass.isFirst, hours > 0, let from = done.from {
                logger.info("Imported \(hours) hours of energy history (\(name)) since \(Timestamp.iso8601(from).prefix(10))")
            }
            return true
        }
        return false
    }

    /// Passes for as long as the task runs: one now, then every `interval` (`retry` after a failure).
    public func run(_ read: @escaping @Sendable (EnergyHistoryPass) async throws -> Void) async {
        while !Task.isCancelled {
            let succeeded = await pass(read)
            try? await Task.sleep(for: succeeded ? interval : retry)
        }
    }

    /// What earlier runs imported, on the Status page from the start, before the first pass says more.
    public func reportKept() {
        let kept = current()
        guard let through = kept.through else { return }
        progressSink(EnergyImportProgress(state: .done, from: kept.from, through: through))
    }
}

extension PluginContext {
    /// The plugin's energy history import `name` (one per history the plugin reads: a cloud's, a device's records), run
    /// by the runtime (`EnergyHistoryImport`). `version`: the plugin's way of reading it, raised when it changes, so the
    /// history is read again from the start and the old hours dropped. `overlap`: the last days each pass reads again;
    /// `interval` between passes, `retry` after a failure. `migrate` gives the state from the plugin's former file, the
    /// first time, so a plugin moving onto it does not read everything again.
    public func energyHistory(_ name: String, version: Int = 1, overlap: TimeInterval = 2 * 86_400, interval: Duration = .seconds(6 * 3600),
                              retry: Duration = .seconds(600), migrate: @escaping @Sendable () -> EnergyHistoryState? = { nil }) -> EnergyHistoryImport {
        let sink = meterSink
        return EnergyHistoryImport(
            name: name, version: version, overlap: overlap, interval: interval, retry: retry,
            file: jsonFile("energy-history-\(name).json"), logger: logger,
            progress: { [self] progress in reportEnergyImport(progress) },
            forget: { meters in for id in meters { sink(.forgetHistory(id)) } },
            migrate: migrate)
    }
}
