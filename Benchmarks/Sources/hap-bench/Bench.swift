import Foundation
import NIOPosix

@main
struct Bench {
    static let usage = """
        usage: hap-bench run --name NAME --port PORT [options] -- <server command...>
               hap-bench idle --name NAME --port PORT [--seconds S] [--output DIR] -- <bridge command...>
               hap-bench compare RESULTS.json...

        Runs a HomeKit controller against the server command, which gets PORT, PIN, ACCESSORIES, STORAGE
        (a fresh directory) and ADVERTISE in its environment, and writes <output>/NAME.json and NAME.log.

        Options:
          --pin CODE          setup code (default 031-45-154)
          --accessories N     lightbulbs behind the bridge (default 30)
          --pairings N        pair setup + verify + unpair cycles (default 20)
          --verifies N        pair verify only (default 100)
          --requests N        timed requests per operation (default 300)
          --events N          write → event measurements (default 50)
          --duration S        seconds per throughput run (default 5)
          --output DIR        where results go (default results)
          --no-advertise      ask the server not to advertise over mDNS
        """

    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { fail(usage) }
        arguments.removeFirst()
        switch command {
        case "run": try await run(arguments)
        case "idle": try await idle(arguments)
        case "compare": try compare(arguments)
        default: fail(usage)
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func run(_ arguments: [String]) async throws {
        var name: String?
        var port: Int?
        var options = Options()
        var output = "results"
        var serverCommand: [String] = []
        var index = 0
        func value() -> String {
            index += 1
            guard index < arguments.count else { fail(usage) }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--name": name = value()
            case "--port": port = Int(value())
            case "--pin": options.pin = value()
            case "--accessories": options.accessories = Int(value()) ?? options.accessories
            case "--pairings": options.pairings = Int(value()) ?? options.pairings
            case "--verifies": options.verifies = Int(value()) ?? options.verifies
            case "--requests": options.requests = Int(value()) ?? options.requests
            case "--events": options.events = Int(value()) ?? options.events
            case "--duration": options.duration = Double(value()) ?? options.duration
            case "--output": output = value()
            case "--no-advertise": options.advertise = false
            case "--":
                serverCommand = Array(arguments[(index + 1)...])
                index = arguments.count
            default: fail("unknown option \(arguments[index])\n\n" + usage)
            }
            index += 1
        }
        guard let name, let port, !serverCommand.isEmpty else { fail(usage) }

        let directory = URL(fileURLWithPath: output)
        let benchmark = Benchmark(name: name, port: port, command: serverCommand, options: options, outputDirectory: directory)
        let results = try await benchmark.run()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = directory.appendingPathComponent("\(name).json")
        try encoder.encode(results).write(to: file)
        progress("  wrote \(file.path)")
        print(table([results]))
    }

    /// `hap-bench idle --name NAME --port PORT [--seconds S] [--output DIR] -- <command...>`: starts a bridge, times
    /// its startup and samples the process at rest, for whole-bridge comparisons (Homebridge vs homeswift).
    static func idle(_ arguments: [String]) async throws {
        var name: String?
        var port: Int?
        var seconds = 10.0
        var output = "results"
        var serverCommand: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--name": index += 1; name = arguments[index]
            case "--port": index += 1; port = Int(arguments[index])
            case "--seconds": index += 1; seconds = Double(arguments[index]) ?? seconds
            case "--output": index += 1; output = arguments[index]
            case "--":
                serverCommand = Array(arguments[(index + 1)...])
                index = arguments.count
            default: fail("unknown option \(arguments[index])\n\n" + usage)
            }
            index += 1
        }
        guard let name, let port, !serverCommand.isEmpty else { fail(usage) }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = MultiThreadedEventLoopGroup.singleton
        let server = try ServerProcess(command: serverCommand, environment: [:], log: directory.appendingPathComponent("\(name)-idle.log"))
        progress("\(name): \(serverCommand.joined(separator: " "))")
        let launch = ContinuousClock.now
        try server.start()
        var startup: Double?
        while launch.elapsed < 60, startup == nil {
            guard server.isRunning else { await server.terminate(); throw BenchError.serverExited }
            let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connectTimeout(.milliseconds(250))
            if let channel = try? await bootstrap.connect(host: "127.0.0.1", port: port).get() {
                startup = launch.elapsed
                try? await channel.close()
            } else {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        guard let startup else { await server.terminate(); throw BenchError.startupTimeout }
        try await Task.sleep(for: .seconds(3))
        let early = server.sample()
        try await Task.sleep(for: .seconds(max(0, seconds - 3)))
        let late = server.sample()
        await server.terminate()
        let result: [String: Any] = [
            "name": name, "command": serverCommand, "startupSeconds": startup, "seconds": seconds,
            "afterThreeSeconds": ["rssKB": early.rssKB, "footprintKB": early.footprintKB ?? 0, "cpuSeconds": early.cpuSeconds, "threads": early.threads],
            "atEnd": ["rssKB": late.rssKB, "footprintKB": late.footprintKB ?? 0, "cpuSeconds": late.cpuSeconds, "threads": late.threads],
        ]
        let file = directory.appendingPathComponent("\(name)-idle.json")
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        print(String(format: "| %@ | %.0f ms | %.1f MB | %.1f MB | %.1f MB | %.1f MB | %.2f s | %d |",
            name, startup * 1000, Double(early.rssKB) / 1024, Double(early.footprintKB ?? 0) / 1024,
            Double(late.rssKB) / 1024, Double(late.footprintKB ?? 0) / 1024, late.cpuSeconds, late.threads))
    }

    static func compare(_ arguments: [String]) throws {
        guard !arguments.isEmpty else { fail(usage) }
        let runs = try arguments.map { try JSONDecoder().decode(RunResults.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) }
        print(table(runs))
    }

    // MARK: The table

    /// A markdown table; with two runs the last column is second ÷ first (first ÷ second for throughput).
    static func table(_ runs: [RunResults]) -> String {
        var lines: [String] = []
        let ratio = runs.count == 2
        lines.append("| Metric | " + runs.map(\.name).joined(separator: " | ") + (ratio ? " | ratio |" : " |"))
        lines.append("|---|" + runs.map { _ in "---:|" }.joined() + (ratio ? "---:|" : ""))

        func row(_ label: String, _ values: [Double], unit: String, higherIsBetter: Bool = false, decimals: Int = 2) {
            let cells = values.map { String(format: "%.\(decimals)f %@", $0, unit) }
            var line = "| \(label) | " + cells.joined(separator: " | ")
            if ratio {
                let (a, b) = (values[0], values[1])
                let r = higherIsBetter ? a / b : b / a
                line += " | " + (a > 0 && b > 0 ? String(format: "%.1f×", r) : "–")
            }
            lines.append(line + " |")
        }
        func textRow(_ label: String, _ values: [String]) {
            lines.append("| \(label) | " + values.joined(separator: " | ") + (ratio ? " | |" : " |"))
        }
        func mb(_ kb: Int?) -> Double { Double(kb ?? 0) / 1024 }

        textRow("Server", runs.map { $0.command.joined(separator: " ") })
        textRow("Accessories", runs.map { "\($0.options.accessories)" })
        row("Startup to listening", runs.map { $0.startupSeconds * 1000 }, unit: "ms", decimals: 0)
        row("Memory idle, RSS", runs.map { mb($0.samples["idle"]?.rssKB) }, unit: "MB", decimals: 1)
        if runs.allSatisfy({ $0.samples["idle"]?.footprintKB != nil }) {
            row("Memory idle, footprint", runs.map { mb($0.samples["idle"]?.footprintKB) }, unit: "MB", decimals: 1)
        }
        row("Memory after run, RSS", runs.map { mb($0.samples["afterThroughput"]?.rssKB) }, unit: "MB", decimals: 1)
        if runs.allSatisfy({ $0.samples["afterThroughput"]?.footprintKB != nil }) {
            row("Memory after run, footprint", runs.map { mb($0.samples["afterThroughput"]?.footprintKB) }, unit: "MB", decimals: 1)
        }
        textRow("Threads (idle / after run)", runs.map { "\($0.samples["idle"]?.threads ?? 0) / \($0.samples["afterThroughput"]?.threads ?? 0)" })
        func phaseCPU(_ label: String, from: String, to: String) {
            row("CPU time, \(label)", runs.map { ($0.samples[to]?.cpuSeconds ?? 0) - ($0.samples[from]?.cpuSeconds ?? 0) }, unit: "s", decimals: 2)
        }
        phaseCPU("pairing phase", from: "idle", to: "afterPairing")
        phaseCPU("pair verify phase", from: "afterPairing", to: "afterVerify")
        phaseCPU("latency phase", from: "afterVerify", to: "afterLatency")
        phaseCPU("events phase", from: "afterLatency", to: "afterEvents")

        row("Pair setup, M1→M2 p50", runs.map(\.pairSetup.m1m2.p50), unit: "ms")
        row("Pair setup, M3→M4 (SRP) p50", runs.map(\.pairSetup.m3m4.p50), unit: "ms")
        row("Pair setup, M5→M6 p50", runs.map(\.pairSetup.m5m6.p50), unit: "ms")
        row("Pair setup, server round trips p50", runs.map(\.pairSetup.roundTrips.p50), unit: "ms")
        row("Pair setup, server round trips max", runs.map(\.pairSetup.roundTrips.max), unit: "ms")
        row("Pair setup, wall p50", runs.map(\.pairSetup.wall.p50), unit: "ms")
        row("Pair verify, round trips p50", runs.map(\.pairVerify.roundTrips.p50), unit: "ms")
        row("Pair verify, round trips p99", runs.map(\.pairVerify.roundTrips.p99), unit: "ms")

        let operations = runs.first?.latency.map(\.name) ?? []
        for operation in operations {
            let results = runs.map { run in run.latency.first { $0.name == operation } }
            guard results.allSatisfy({ $0 != nil }) else { continue }
            row("\(operation) p50", results.map { $0!.latency.p50 }, unit: "ms", decimals: 3)
            row("\(operation) p99", results.map { $0!.latency.p99 }, unit: "ms", decimals: 3)
            if operation.hasPrefix("GET") { textRow("\(operation) body", results.map { "\($0!.bytes) bytes" }) }
        }
        if runs.allSatisfy({ $0.events != nil }) {
            row("Event latency p50", runs.map { $0.events!.p50 }, unit: "ms")
            row("Event latency p99", runs.map { $0.events!.p99 }, unit: "ms")
        } else {
            textRow("Event latency", runs.map { $0.events.map { String(format: "p50 %.2f ms", $0.p50) } ?? "failed: \($0.eventsError ?? "?")" })
        }
        let loads = runs.first?.throughput.map { ($0.name, $0.concurrency) } ?? []
        for (loadName, concurrency) in loads {
            let results = runs.map { run in run.throughput.first { $0.name == loadName && $0.concurrency == concurrency } }
            guard results.allSatisfy({ $0 != nil }) else { continue }
            row("\(loadName) ×\(concurrency) throughput", results.map { $0!.requestsPerSecond }, unit: "req/s", higherIsBetter: true, decimals: 0)
            row("\(loadName) ×\(concurrency) CPU per request", results.map { $0!.cpuMicrosPerRequest }, unit: "µs", decimals: 0)
            row("\(loadName) ×\(concurrency) latency p99", results.map { $0!.latency.p99 }, unit: "ms", decimals: 3)
        }
        return lines.joined(separator: "\n")
    }
}
