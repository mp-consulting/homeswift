import Foundation
import Homeswift
import HomeswiftAI
import NIOConcurrencyHelpers
#if canImport(Darwin)
import Darwin
#endif

/// The Status page's history: the process's memory and CPU, and how long the Home app's requests and the
/// plugins' handlers take, a record per minute, a week back and across restarts.
///
/// Memory and CPU are sampled every `interval`: a minute keeps its highest memory and its average CPU (100 is
/// one core busy). Durations come from the host's timing feed (`PluginHost.observeTimings`): a minute keeps,
/// for each series, how many calls there were, their total and the longest. A series is `all` (every
/// server), `bridge:<device ID>` (one server) or `accessory:<id>` (one accessory). Closed minutes go to a file
/// per day under `directory` (`metrics-20261023.jsonl`, the day in UTC, a JSON object per line, owner-only),
/// which is read back at start; minutes and files older than `days` go.
public final class Metrics: @unchecked Sendable {
    /// The calls of one series in a span: how many, their total and the longest, in milliseconds.
    public struct Durations: Sendable, Equatable {
        public var count = 0
        public var total = 0.0
        public var longest = 0.0

        public init(count: Int = 0, total: Double = 0, longest: Double = 0) {
            self.count = count
            self.total = total
            self.longest = longest
        }

        public var average: Double? { count > 0 ? total / Double(count) : nil }

        mutating func add(_ milliseconds: Double) {
            count += 1
            total += milliseconds
            longest = max(longest, milliseconds)
        }

        mutating func merge(_ other: Durations) {
            count += other.count
            total += other.total
            longest = max(longest, other.longest)
        }
    }

    /// One minute, or a span of several when a history is merged into fewer points.
    public struct Minute: Sendable, Equatable {
        public var start: Date
        /// Bytes: the physical footprint on macOS (what Activity Monitor shows), the resident set on Linux.
        public var memory: UInt64?
        /// Percent of one core.
        public var cpu: Double?
        /// The Home app's reads and writes, by series.
        public var requests: [String: Durations] = [:]
        /// The plugins' read and write handlers, by series.
        public var handlers: [String: Durations] = [:]

        public init(start: Date, memory: UInt64? = nil, cpu: Double? = nil, requests: [String: Durations] = [:], handlers: [String: Durations] = [:]) {
            self.start = start
            self.memory = memory
            self.cpu = cpu
            self.requests = requests
            self.handlers = handlers
        }
    }

    /// A series' history: `points` from `from` on, each `step` long, those with nothing recorded left out.
    public struct History: Sendable {
        public var step: TimeInterval
        public var points: [Point]
    }

    public struct Point: Sendable, Equatable {
        public var start: Date
        public var memory: UInt64?
        public var cpu: Double?
        public var requests: Durations
        public var handlers: Durations
    }

    public static let allSeries = "all"
    static let prefix = "metrics-"

    public let directory: URL?
    public let days: Int
    public let interval: Duration

    private struct State {
        var minutes: [Minute] = []
        var current: Minute?
        // The current minute's CPU samples, averaged when it closes.
        var cpuTotal = 0.0
        var cpuSamples = 0
        var lastCPU: (at: ContinuousClock.Instant, seconds: Double)?
        var latest: (memory: UInt64?, cpu: Double?) = (nil, nil)
        var observation: Observation?
        var sampler: Task<Void, Never>?
    }

    private let state = NIOLockedValueBox(State())
    private let queue = DispatchQueue(label: "homeswift.metrics")
    private let now: @Sendable () -> Date

    /// `directory` nil keeps the history in memory only. `now` is for tests.
    public init(directory: URL?, days: Int = 8, interval: Duration = .seconds(10), now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.days = days
        self.interval = interval
        self.now = now
        let loaded = directory.map { Self.load(from: $0, since: now().addingTimeInterval(-Double(days) * 86_400)) } ?? []
        state.withLockedValue { $0.minutes = loaded }
    }

    /// Follows the host's servers and samples the process until `stop()`.
    public func start(following host: PluginHost) {
        let observation = host.observeTimings { [weak self] bridge, timing in self?.record(timing, server: bridge.server.deviceID) }
        let interval = interval
        // The first sample before returning: the Status page (and a test) asking at once has a value, however long
        // the task takes to run on a loaded machine.
        sample()
        let sampler = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                self?.sample()
            }
        }
        state.withLockedValue {
            $0.observation = observation
            $0.sampler = sampler
        }
    }

    /// Stops following and sampling, and keeps the minute under way.
    public func stop() {
        let (observation, sampler) = state.withLockedValue { state in
            defer { state.observation = nil; state.sampler = nil }
            return (state.observation, state.sampler)
        }
        observation?.cancel()
        sampler?.cancel()
        let closed = state.withLockedValue { Self.close(&$0) }
        if let closed { persist(closed) }
        queue.sync {}
    }

    /// The latest sample: memory in bytes, CPU in percent of one core.
    public var latest: (memory: UInt64?, cpu: Double?) { state.withLockedValue { $0.latest } }

    /// Counts a call against `all`, its server and each accessory it was about.
    func record(_ timing: HAPServer.Timing, server: String) {
        let milliseconds = Double(timing.duration.components.seconds) * 1000 + Double(timing.duration.components.attoseconds) / 1e15
        let series = [Self.allSeries, "bridge:\(server)"] + timing.accessories.map { "accessory:\($0.id)" }
        let closed = state.withLockedValue { state -> Minute? in
            let closed = roll(&state)
            for name in series {
                switch timing.kind {
                case .request: state.current?.requests[name, default: Durations()].add(milliseconds)
                case .handler: state.current?.handlers[name, default: Durations()].add(milliseconds)
                }
            }
            return closed
        }
        if let closed { persist(closed) }
    }

    /// Takes a sample of the process's memory and CPU.
    func sample() {
        let memory = Self.memoryFootprint()
        let seconds = Self.cpuSeconds()
        let at = ContinuousClock.now
        let closed = state.withLockedValue { state -> Minute? in
            let closed = roll(&state)
            var cpu: Double?
            if let seconds, let last = state.lastCPU {
                let elapsed = at - last.at
                let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                if wall > 0 { cpu = max(0, (seconds - last.seconds) / wall * 100) }
            }
            if let seconds { state.lastCPU = (at, seconds) }
            if let memory, let current = state.current { state.current?.memory = max(current.memory ?? 0, memory) }
            if let cpu {
                state.cpuTotal += cpu
                state.cpuSamples += 1
            }
            state.latest = (memory, cpu ?? state.latest.cpu)
            return closed
        }
        if let closed { persist(closed) }
    }

    /// Adds a closed minute, as if recorded; for tests.
    func add(_ minute: Minute) {
        state.withLockedValue { $0.minutes.append(minute) }
        persist(minute)
    }

    /// Starts the minute `now` is in, closing the one before. Returns the closed minute, to persist.
    private func roll(_ state: inout State) -> Minute? {
        let start = Date(timeIntervalSince1970: (now().timeIntervalSince1970 / 60).rounded(.down) * 60)
        if state.current?.start == start { return nil }
        let closed = Self.close(&state)
        state.current = Minute(start: start)
        let oldest = start.addingTimeInterval(-Double(days) * 86_400)
        if let first = state.minutes.first, first.start < oldest { state.minutes.removeAll { $0.start < oldest } }
        return closed
    }

    private static func close(_ state: inout State) -> Minute? {
        guard var minute = state.current else { return nil }
        if state.cpuSamples > 0 { minute.cpu = state.cpuTotal / Double(state.cpuSamples) }
        state.current = nil
        state.cpuTotal = 0
        state.cpuSamples = 0
        guard minute.memory != nil || minute.cpu != nil || !minute.requests.isEmpty || !minute.handlers.isEmpty else { return nil }
        state.minutes.append(minute)
        return minute
    }

    // MARK: History

    /// The history of `series` (`all`, `bridge:<device ID>` or `accessory:<id>`; memory and CPU are the
    /// process's whatever it is) from `from` to `to`, merged into at most about `points` points of whole minutes:
    /// the highest memory, the average CPU, the durations added up. The minute under way counts.
    public func history(from: Date, to: Date, series: String = allSeries, points: Int = 240) -> History {
        let span = max(to.timeIntervalSince(from), 60)
        let step = max(60, (span / Double(max(points, 1)) / 60).rounded(.up) * 60)
        // Points start on whole steps (whole minutes, whole five minutes…), not at the second `from` was asked.
        let base = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / step).rounded(.down) * step)
        let minutes = state.withLockedValue { state -> [Minute] in
            var minutes = state.minutes.filter { $0.start >= base && $0.start <= to }
            if var current = state.current, current.start <= to {
                if state.cpuSamples > 0 { current.cpu = state.cpuTotal / Double(state.cpuSamples) }
                minutes.append(current)
            }
            return minutes
        }
        var buckets: [Int: (point: Point, cpuMinutes: Int)] = [:]
        for minute in minutes {
            let index = max(0, Int(minute.start.timeIntervalSince(base) / step))
            var bucket = buckets[index] ?? (Point(start: base.addingTimeInterval(Double(index) * step), memory: nil, cpu: nil, requests: Durations(), handlers: Durations()), 0)
            if let memory = minute.memory { bucket.point.memory = max(bucket.point.memory ?? 0, memory) }
            if let cpu = minute.cpu {
                bucket.point.cpu = ((bucket.point.cpu ?? 0) * Double(bucket.cpuMinutes) + cpu) / Double(bucket.cpuMinutes + 1)
                bucket.cpuMinutes += 1
            }
            if let requests = minute.requests[series] { bucket.point.requests.merge(requests) }
            if let handlers = minute.handlers[series] { bucket.point.handlers.merge(handlers) }
            buckets[index] = bucket
        }
        return History(step: step, points: buckets.keys.sorted().compactMap { buckets[$0]?.point })
    }

    // MARK: Files

    private func persist(_ minute: Minute) {
        guard let directory else { return }
        let line = Self.entry(minute) + [0x0A]
        let name = "\(Self.prefix)\(Self.days().string(from: minute.start)).jsonl"
        let days = days
        queue.async { [line] in
            let manager = FileManager.default
            let url = directory.appendingPathComponent(name)
            if !manager.fileExists(atPath: url.path) {
                try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                Self.prune(directory, keeping: days)
                guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    /// `{"t": start, "m": bytes, "c": percent, "r": {series: [count, total, longest]}, "h": {…}}`, durations in
    /// milliseconds.
    static func entry(_ minute: Minute) -> Data {
        func durations(_ all: [String: Durations]) -> JSONValue {
            .object(all.mapValues { .array([.number(Double($0.count)), .number(rounded($0.total)), .number(rounded($0.longest))]) })
        }
        var object: [String: JSONValue] = ["t": .number(minute.start.timeIntervalSince1970)]
        if let memory = minute.memory { object["m"] = .number(Double(memory)) }
        if let cpu = minute.cpu { object["c"] = .number(rounded(cpu)) }
        if !minute.requests.isEmpty { object["r"] = durations(minute.requests) }
        if !minute.handlers.isEmpty { object["h"] = durations(minute.handlers) }
        return JSONValue.object(object).encoded()
    }

    static func minute(_ row: Data) -> Minute? {
        guard let entry = try? JSONValue(data: row), let time = entry["t"]?.doubleValue else { return nil }
        func durations(_ value: JSONValue?) -> [String: Durations] {
            (value?.objectValue ?? [:]).compactMapValues { item in
                guard let parts = item.arrayValue, parts.count == 3, let count = parts[0].doubleValue, let total = parts[1].doubleValue,
                      let longest = parts[2].doubleValue else { return nil }
                return Durations(count: Int(count), total: total, longest: longest)
            }
        }
        return Minute(
            start: Date(timeIntervalSince1970: time), memory: entry["m"]?.doubleValue.map { UInt64(max(0, $0)) }, cpu: entry["c"]?.doubleValue,
            requests: durations(entry["r"]), handlers: durations(entry["h"]))
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// The minutes in the files of `directory` from `since` on, oldest first.
    static func load(from directory: URL, since: Date) -> [Minute] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jsonl") }.sorted()
        var minutes: [Minute] = []
        for name in names {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { continue }
            minutes += data.split(separator: 0x0A).compactMap { minute(Data($0)) }.filter { $0.start >= since }
        }
        return minutes.sorted { $0.start < $1.start }
    }

    /// Removes the files of days older than `days`.
    private static func prune(_ directory: URL, keeping days: Int) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let oldest = Self.days().string(from: Date().addingTimeInterval(-Double(days) * 86_400))
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".jsonl") && String(name.dropFirst(prefix.count).prefix(8)) < oldest {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// `20261023`, in UTC: names sort by day whatever the time zone.
    static func days() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }

    // MARK: The process

    /// The process's memory in bytes: its physical footprint on macOS, its resident set on Linux.
    static func memoryFootprint() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
        #else
        // /proc/self/statm: sizes in pages, the resident set second.
        guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return nil }
        let fields = text.split(separator: " ")
        guard fields.count > 1, let pages = UInt64(fields[1]) else { return nil }
        return pages * UInt64(sysconf(Int32(_SC_PAGESIZE)))
        #endif
    }

    /// The CPU time the process has used, user and system, in seconds.
    static func cpuSeconds() -> Double? {
        #if canImport(Darwin)
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let seconds = { (time: timeval) in Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
        #else
        // /proc/self/stat: utime and stime, in clock ticks, are the 14th and 15th fields; the 2nd, the command,
        // may hold spaces, so fields are counted after its closing parenthesis.
        guard let text = try? String(contentsOfFile: "/proc/self/stat", encoding: .utf8), let close = text.lastIndex(of: ")") else { return nil }
        let fields = text[text.index(after: close)...].split(separator: " ")
        guard fields.count > 12, let user = Double(fields[11]), let system = Double(fields[12]) else { return nil }
        return (user + system) / Double(sysconf(Int32(_SC_CLK_TCK)))
        #endif
    }
}
