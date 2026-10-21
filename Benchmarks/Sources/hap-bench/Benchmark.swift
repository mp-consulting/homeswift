import Foundation
import NIOCore
import NIOPosix

#if canImport(Glibc)
import Glibc
#endif

// MARK: Results

/// Timings in milliseconds.
struct Stats: Codable {
    var count: Int
    var mean: Double
    var p50: Double
    var p90: Double
    var p99: Double
    var min: Double
    var max: Double
    /// Every sample, in order.
    var samples: [Double]

    init(seconds: [Double]) {
        samples = seconds.map { $0 * 1000 }
        let sorted = samples.sorted()
        count = sorted.count
        guard let first = sorted.first, let last = sorted.last else {
            (mean, p50, p90, p99, min, max) = (0, 0, 0, 0, 0, 0)
            return
        }
        mean = sorted.reduce(0, +) / Double(sorted.count)
        func percentile(_ p: Double) -> Double {
            let rank = Int((Double(sorted.count) * p).rounded(.up)) - 1
            return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank))]
        }
        p50 = percentile(0.5)
        p90 = percentile(0.9)
        p99 = percentile(0.99)
        min = first
        max = last
    }
}

struct ProcessSample: Codable {
    var rssKB: Int
    /// macOS only: top's physical footprint, the number Activity Monitor shows.
    var footprintKB: Int?
    var cpuSeconds: Double
    var threads: Int
}

struct PairSetupStats: Codable {
    var m1m2: Stats
    var m3m4: Stats
    var m5m6: Stats
    var roundTrips: Stats
    var wall: Stats
}

struct PairVerifyStats: Codable {
    var m1m2: Stats
    var m3m4: Stats
    var roundTrips: Stats
    var wall: Stats
}

struct LatencyResult: Codable {
    var name: String
    var bytes: Int
    var latency: Stats
}

struct ThroughputResult: Codable {
    var name: String
    var concurrency: Int
    var requests: Int
    var seconds: Double
    var requestsPerSecond: Double
    var cpuSeconds: Double
    var cpuMicrosPerRequest: Double
    var latency: Stats
}

struct Options: Codable {
    var pin = "031-45-154"
    var accessories = 30
    var pairings = 20
    var verifies = 100
    var requests = 300
    var events = 50
    var duration = 5.0
    var advertise = true
}

struct RunResults: Codable {
    var name: String
    var command: [String]
    var date: String
    var machine: String
    var options: Options
    var startupSeconds: Double
    var accessoriesBytes: Int
    var pairSetup: PairSetupStats
    var pairVerify: PairVerifyStats
    var latency: [LatencyResult]
    var events: Stats?
    var eventsError: String?
    var throughput: [ThroughputResult]
    var samples: [String: ProcessSample]
}

enum BenchError: Error, CustomStringConvertible {
    case serverExited
    case startupTimeout
    case badDatabase(String)

    var description: String {
        switch self {
        case .serverExited: "the server exited before listening (see its log)"
        case .startupTimeout: "the server did not listen within 30 s"
        case .badDatabase(let why): "unexpected /accessories: \(why)"
        }
    }
}

// MARK: The server process

final class ServerProcess: @unchecked Sendable {
    private let process = Process()

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    init(command: [String], environment: [String: String], log: URL) throws {
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
    }

    func start() throws {
        try process.run()
    }

    /// Resident size and CPU time from ps; the thread count; on macOS the physical footprint from top when asked.
    func sample(footprint: Bool = true) -> ProcessSample {
        let fields = shell("/bin/ps", ["-o", "rss=,cputime=", "-p", "\(pid)"]).split(whereSeparator: \.isWhitespace)
        let rss = fields.first.flatMap { Int($0) } ?? 0
        let cpu = fields.count > 1 ? Self.seconds(fromCPUTime: String(fields[1])) : 0
        #if os(macOS)
        let threads = Swift.max(0, shell("/bin/ps", ["-M", "-p", "\(pid)"]).split(separator: "\n").count - 1)
        let footprintKB = footprint
            ? Self.kilobytes(shell("/usr/bin/top", ["-l", "1", "-pid", "\(pid)", "-stats", "mem"]).split(separator: "\n").last.map(String.init) ?? "")
            : nil
        #else
        let threads = Int(shell("/bin/ps", ["-o", "nlwp=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let footprintKB: Int? = nil
        #endif
        return ProcessSample(rssKB: rss, footprintKB: footprintKB, cpuSeconds: cpu, threads: threads)
    }

    /// ps cputime: "0:01.23", "1:02:03.45" or "1-02:03:04".
    static func seconds(fromCPUTime text: String) -> Double {
        var days = 0.0
        var rest = Substring(text)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        var seconds = 0.0
        for part in rest.split(separator: ":") { seconds = seconds * 60 + (Double(part) ?? 0) }
        return days * 86400 + seconds
    }

    /// top's MEM column: "1616K", "123M", "1.2G", with a delta sign in some modes.
    static func kilobytes(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "+-")))
        guard let unit = trimmed.last, let value = Double(trimmed.dropLast()) else { return nil }
        switch unit {
        case "B": return Int(value / 1024)
        case "K": return Int(value)
        case "M": return Int(value * 1024)
        case "G": return Int(value * 1024 * 1024)
        default: return nil
        }
    }

    func terminate() async {
        guard process.isRunning else { return }
        process.terminate()
        let start = ContinuousClock.now
        while process.isRunning && start.elapsed < 5 { try? await Task.sleep(for: .milliseconds(50)) }
        if process.isRunning { kill(pid, SIGKILL) }
        process.waitUntilExit()
    }
}

func shell(_ path: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func progress(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func ms(_ seconds: Double) -> String {
    String(format: "%.2f ms", seconds * 1000)
}

// MARK: The accessory database

struct Lamp {
    var aid: Int
    var on: Int
    var brightness: Int
}

struct Database {
    var lamps: [Lamp] = []

    init(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessories = root["accessories"] as? [[String: Any]]
        else { throw BenchError.badDatabase("no accessories array") }
        for accessory in accessories {
            guard let aid = accessory["aid"] as? Int, let services = accessory["services"] as? [[String: Any]] else { continue }
            for service in services where Self.shortType(service["type"]) == "43" {
                var on: Int?
                var brightness: Int?
                for characteristic in service["characteristics"] as? [[String: Any]] ?? [] {
                    switch Self.shortType(characteristic["type"]) {
                    case "25": on = characteristic["iid"] as? Int
                    case "8": brightness = characteristic["iid"] as? Int
                    default: break
                    }
                }
                if let on, let brightness { lamps.append(Lamp(aid: aid, on: on, brightness: brightness)) }
            }
        }
    }

    /// "00000043-0000-1000-8000-0026BB765291" and "43" both become "43".
    static func shortType(_ type: Any?) -> String {
        guard let type = type as? String else { return "" }
        let head = type.split(separator: "-").first.map(String.init) ?? type
        let trimmed = head.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed).uppercased()
    }
}

// MARK: The benchmark

typealias Operation = @Sendable (Controller, Int) async throws -> (HTTPMessage, Double)

struct Benchmark {
    let name: String
    let port: Int
    let command: [String]
    let options: Options
    let outputDirectory: URL

    func run() async throws -> RunResults {
        // The client's event loops exist before the clock starts.
        _ = MultiThreadedEventLoopGroup.singleton
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("hap-bench-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let server = try ServerProcess(
            command: command,
            environment: [
                "PORT": "\(port)", "PIN": options.pin, "ACCESSORIES": "\(options.accessories)",
                "STORAGE": storage.path, "ADVERTISE": options.advertise ? "1" : "0",
            ],
            log: outputDirectory.appendingPathComponent("\(name).log"))
        progress("\(name): \(command.joined(separator: " "))")
        let launch = ContinuousClock.now
        try server.start()
        do {
            let results = try await measure(server: server, launch: launch)
            await server.terminate()
            return results
        } catch {
            await server.terminate()
            throw error
        }
    }

    private func measure(server: ServerProcess, launch: ContinuousClock.Instant) async throws -> RunResults {
        let startup = try await waitForPort(server: server, since: launch)
        progress("  listening after \(ms(startup))")
        var samples: [String: ProcessSample] = [:]
        try await Task.sleep(for: .seconds(1.5))
        samples["idle"] = server.sample()

        // Pair setup and verify, as a new controller each time; the pairing is removed in between.
        var setups: [Controller.PairSetupTiming] = []
        var verifies: [Controller.PairVerifyTiming] = []
        for _ in 0..<options.pairings {
            let controller = Controller()
            try await controller.connect(port: port)
            setups.append(try await controller.pairSetup(code: options.pin))
            verifies.append(try await controller.pairVerify())
            try await controller.removePairing(controller.identifier)
            await controller.close()
        }
        let admin = Controller()
        try await admin.connect(port: port)
        setups.append(try await admin.pairSetup(code: options.pin))
        verifies.append(try await admin.pairVerify())
        progress("  pair setup ×\(setups.count): round trips p50 \(ms(median(setups.map(\.roundTrips)))), wall p50 \(ms(median(setups.map(\.wall))))")
        samples["afterPairing"] = server.sample()

        let (accessories, _) = try await admin.timed("GET", "/accessories")
        guard accessories.status == 200 else { throw ControllerError.status(accessories.status, String(decoding: accessories.body, as: UTF8.self)) }
        let lamps = try Database(accessories.body).lamps
        guard lamps.count >= 10 else { throw BenchError.badDatabase("\(lamps.count) lightbulbs, need 10") }
        progress("  /accessories: \(accessories.body.count) bytes, \(lamps.count) lightbulbs")

        // Pair verify alone, on new connections of the paired controller.
        var verifyOnly: [Controller.PairVerifyTiming] = []
        for _ in 0..<options.verifies {
            let connection = admin.sibling()
            try await connection.connect(port: port)
            verifyOnly.append(try await connection.pairVerify())
            await connection.close()
        }
        progress("  pair verify ×\(verifyOnly.count): round trips p50 \(ms(median(verifyOnly.map(\.roundTrips))))")
        samples["afterVerify"] = server.sample()

        // Request latency on one verified connection.
        let readTarget = "/characteristics?id=" + lamps.prefix(10).map { "\($0.aid).\($0.brightness)" }.joined(separator: ",")
        let first = lamps[0]
        let ten = Array(lamps.prefix(10))
        let operations: [(String, Operation)] = [
            ("GET /accessories", { controller, _ in try await controller.timed("GET", "/accessories") }),
            ("GET /characteristics ×10", { controller, _ in try await controller.timed("GET", readTarget) }),
            ("PUT /characteristics ×1", { controller, i in
                try await controller.json("PUT", "/characteristics", ["characteristics": [["aid": first.aid, "iid": first.brightness, "value": 10 + (i % 2) * 10]]])
            }),
            ("PUT /characteristics ×10", { controller, i in
                try await controller.json("PUT", "/characteristics", ["characteristics": ten.map { ["aid": $0.aid, "iid": $0.brightness, "value": 10 + (i % 2) * 10] }])
            }),
        ]
        var latency: [LatencyResult] = []
        for (operationName, operation) in operations {
            for i in 0..<20 { _ = try await operation(admin, i) }
            var times: [Double] = []
            var bytes = 0
            for i in 0..<options.requests {
                let (message, seconds) = try await operation(admin, i)
                guard message.status == 200 || message.status == 204 else {
                    throw ControllerError.status(message.status, String(decoding: message.body, as: UTF8.self))
                }
                times.append(seconds)
                bytes = message.body.count
            }
            let stats = Stats(seconds: times)
            latency.append(LatencyResult(name: operationName, bytes: bytes, latency: stats))
            progress("  \(operationName): p50 \(String(format: "%.3f", stats.p50)) ms, p99 \(String(format: "%.3f", stats.p99)) ms, \(bytes) bytes")
        }
        samples["afterLatency"] = server.sample()

        // Event latency: a second connection subscribes, the admin writes, the time to the event is measured.
        var eventTimes: [Double] = []
        var eventsError: String?
        let subscriber = admin.sibling()
        try await subscriber.connect(port: port)
        _ = try await subscriber.pairVerify()
        do {
            try await subscriber.subscribe(aid: first.aid, iid: first.brightness)
            for i in 0..<options.events {
                let value = 1 + i % 100
                let body = try JSONSerialization.data(withJSONObject: ["characteristics": [["aid": first.aid, "iid": first.brightness, "value": value]]])
                let start = ContinuousClock.now
                try await admin.send("PUT", "/characteristics", body: body)
                async let reply = admin.response()
                var elapsed: Double?
                while elapsed == nil {
                    let message = try await subscriber.receive(timeout: .seconds(5))
                    guard message.isEvent,
                        let changed = (message.json as? [String: Any])?["characteristics"] as? [[String: Any]]
                    else { continue }
                    if changed.contains(where: { ($0["aid"] as? Int) == first.aid && ($0["iid"] as? Int) == first.brightness && ($0["value"] as? Int) == value }) {
                        elapsed = start.elapsed
                    }
                }
                let response = try await reply
                guard response.status == 204 else { throw ControllerError.status(response.status, String(decoding: response.body, as: UTF8.self)) }
                eventTimes.append(elapsed!)
            }
            progress("  events ×\(eventTimes.count): p50 \(ms(median(eventTimes)))")
        } catch {
            eventsError = "\(error)"
            progress("  events failed after \(eventTimes.count): \(error)")
        }
        await subscriber.close()
        await admin.close()
        samples["afterEvents"] = server.sample()

        // Throughput under concurrent connections.
        var throughput: [ThroughputResult] = []
        let load: [(String, Int, Operation)] = [
            (operations[1].0, 1, operations[1].1),
            (operations[1].0, 4, operations[1].1),
            (operations[1].0, 16, operations[1].1),
            (operations[0].0, 4, operations[0].1),
            (operations[2].0, 4, operations[2].1),
        ]
        for (loadName, concurrency, operation) in load {
            let result = try await measureThroughput(name: loadName, concurrency: concurrency, admin: admin, server: server, operation: operation)
            throughput.append(result)
            progress("  \(loadName) ×\(concurrency): \(Int(result.requestsPerSecond)) req/s, \(String(format: "%.0f", result.cpuMicrosPerRequest)) µs CPU/req, p99 \(String(format: "%.3f", result.latency.p99)) ms")
        }
        samples["afterThroughput"] = server.sample()

        return RunResults(
            name: name, command: command, date: ISO8601DateFormatter().string(from: Date()), machine: machineDescription(),
            options: options, startupSeconds: startup, accessoriesBytes: accessories.body.count,
            pairSetup: PairSetupStats(
                m1m2: Stats(seconds: setups.map(\.m1m2)), m3m4: Stats(seconds: setups.map(\.m3m4)), m5m6: Stats(seconds: setups.map(\.m5m6)),
                roundTrips: Stats(seconds: setups.map(\.roundTrips)), wall: Stats(seconds: setups.map(\.wall))),
            pairVerify: PairVerifyStats(
                m1m2: Stats(seconds: verifyOnly.map(\.m1m2)), m3m4: Stats(seconds: verifyOnly.map(\.m3m4)),
                roundTrips: Stats(seconds: verifyOnly.map(\.roundTrips)), wall: Stats(seconds: verifyOnly.map(\.wall))),
            latency: latency, events: eventTimes.isEmpty ? nil : Stats(seconds: eventTimes), eventsError: eventsError,
            throughput: throughput, samples: samples)
    }

    private func waitForPort(server: ServerProcess, since launch: ContinuousClock.Instant) async throws -> Double {
        while launch.elapsed < 30 {
            guard server.isRunning else { throw BenchError.serverExited }
            let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connectTimeout(.milliseconds(250))
            if let channel = try? await bootstrap.connect(host: "127.0.0.1", port: port).get() {
                let elapsed = launch.elapsed
                try? await channel.close()
                return elapsed
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw BenchError.startupTimeout
    }

    private func measureThroughput(name: String, concurrency: Int, admin: Controller, server: ServerProcess, operation: @escaping Operation) async throws -> ThroughputResult {
        var controllers: [Controller] = []
        for _ in 0..<concurrency {
            let connection = admin.sibling()
            try await connection.connect(port: port)
            _ = try await connection.pairVerify()
            for i in 0..<5 { _ = try await operation(connection, i) }
            controllers.append(connection)
        }
        let before = server.sample(footprint: false)
        let start = ContinuousClock.now
        let deadline = start + .seconds(options.duration)
        let times: [Double] = try await withThrowingTaskGroup(of: [Double].self) { group in
            for controller in controllers {
                group.addTask {
                    var times: [Double] = []
                    var i = 0
                    while ContinuousClock.now < deadline {
                        let (message, seconds) = try await operation(controller, i)
                        guard message.status == 200 || message.status == 204 else {
                            throw ControllerError.status(message.status, String(decoding: message.body, as: UTF8.self))
                        }
                        times.append(seconds)
                        i += 1
                    }
                    return times
                }
            }
            var all: [Double] = []
            for try await times in group { all += times }
            return all
        }
        let elapsed = start.elapsed
        let after = server.sample(footprint: false)
        for controller in controllers { await controller.close() }
        let cpu = after.cpuSeconds - before.cpuSeconds
        // Tens of thousands of samples per run would dominate the results file; the percentiles are enough here.
        var latency = Stats(seconds: times)
        latency.samples = []
        return ThroughputResult(
            name: name, concurrency: concurrency, requests: times.count, seconds: elapsed,
            requestsPerSecond: Double(times.count) / elapsed, cpuSeconds: cpu,
            cpuMicrosPerRequest: times.isEmpty ? 0 : cpu * 1e6 / Double(times.count), latency: latency)
    }
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[sorted.count / 2]
}

func machineDescription() -> String {
    #if os(macOS)
    let cpu = shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let version = shell("/usr/bin/sw_vers", ["-productVersion"]).trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(cpu), macOS \(version)"
    #else
    return shell("/bin/uname", ["-srm"]).trimmingCharacters(in: .whitespacesAndNewlines)
    #endif
}
