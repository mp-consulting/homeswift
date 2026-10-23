import Foundation
import Logging
import NIOConcurrencyHelpers
#if canImport(Darwin)
import Darwin
#endif

/// Why a probe command failed: the counterpart of the `execFile` errors codecs.ts inspects.
public enum FfmpegCommandError: Error, Sendable, Equatable {
    /// The command is not in the `PATH` (Node's `ENOENT`).
    case notFound
    /// The command ran and failed, or could not be started; the message is what Node puts in `error.message`.
    case failed(String)
}

/// What `FfmpegCodecs` learns about the host: the platform, the CPU, the Raspberry Pi model, and how it runs a command.
/// `current` is the real host; tests substitute their own (codecs.ts's tests mock `node:os`, `node:fs` and `execFile`).
public struct FfmpegHostEnvironment: Sendable {
    /// Node's `process.platform`: `darwin`, `linux`, or something else.
    public var platform: String
    /// Node's `os.cpus()[0].model`, nil when unknown.
    public var cpuModel: String?
    /// The content of `/sys/firmware/devicetree/base/model`, nil when it cannot be read.
    public var deviceModel: @Sendable () -> String?
    /// Runs a command and returns its standard output, like `execFile`: throws `notFound`, or `failed` when it exits non-zero.
    public var run: @Sendable (_ command: String, _ arguments: [String]) async throws(FfmpegCommandError) -> String
    /// The `PATH`, for the error message when a command is missing.
    public var path: String

    public init(
        platform: String, cpuModel: String?, deviceModel: @escaping @Sendable () -> String?,
        run: @escaping @Sendable (_ command: String, _ arguments: [String]) async throws(FfmpegCommandError) -> String,
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        self.platform = platform
        self.cpuModel = cpuModel
        self.deviceModel = deviceModel
        self.run = run
        self.path = path
    }

    /// This machine.
    public static var current: FfmpegHostEnvironment {
        #if os(macOS)
        let platform = "darwin"
        #elseif os(Linux)
        let platform = "linux"
        #else
        let platform = "unknown"
        #endif
        return FfmpegHostEnvironment(
            platform: platform, cpuModel: hostCPUModel(),
            deviceModel: { try? String(contentsOfFile: "/sys/firmware/devicetree/base/model", encoding: .utf8) },
            run: { command, arguments throws(FfmpegCommandError) in try await runCommand(command, arguments) }
        )
    }

    /// The CPU model as Node's `os.cpus()` reports it: `machdep.cpu.brand_string` on macOS, the first `model name` of
    /// /proc/cpuinfo on Linux.
    static func hostCPUModel() -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        guard let cpuinfo = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) else { return nil }
        for line in cpuinfo.split(separator: "\n") where line.hasPrefix("model name") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
        #endif
    }
}

/// Runs a command to completion and returns its standard output, as Node's promisified `execFile` does.
func runCommand(_ command: String, _ arguments: [String]) async throws(FfmpegCommandError) -> String {
    let child: Subprocess
    do throws(FfmpegProcessError) {
        child = try Subprocess.launch(command, arguments: arguments)
    } catch {
        if case .notFound = error { throw .notFound }
        throw .failed(error.description)
    }
    let output = NIOLockedValueBox((stdout: Data(), stderr: Data()))
    child.addStdoutHandler { data in output.withLockedValue { $0.stdout.append(data) } }
    child.addStderrHandler { data in output.withLockedValue { $0.stderr.append(data) } }
    let status: FfmpegExitStatus = await withCheckedContinuation { continuation in
        if !child.addExitHandler({ continuation.resume(returning: $0) }) {
            continuation.resume(returning: FfmpegExitStatus(exitCode: nil, signal: nil))
        }
        child.beginReading()
        child.end()
    }
    let (stdout, stderr) = output.withLockedValue { ($0.stdout, $0.stderr) }
    guard status.exitCode == 0 else {
        // Node: "Command failed: <command line>\n<stderr>".
        var message = "Command failed: " + ([command] + arguments).joined(separator: " ")
        let errorOutput = String(decoding: stderr, as: UTF8.self)
        if !errorOutput.isEmpty { message += "\n" + errorOutput }
        throw .failed(message)
    }
    return String(decoding: stdout, as: UTF8.self)
}

/// Probes FFmpeg and the host: the FFmpeg version, its decoders, encoders and hardware accelerators (each accelerator checked
/// with a one-second test encode), the host family (`generic`, `macOS.Apple`, `macOS.Intel`, `raspbian`), the CPU generation
/// and a Raspberry Pi's GPU memory.
///
/// ```swift
/// let codecs = FfmpegCodecs(ffmpegExec: "ffmpeg", log: logger, verbose: false)
/// if await codecs.probe(), codecs.hasEncoder("h264", "h264_videotoolbox") { ... }
/// ```
public final class FfmpegCodecs: Sendable {
    /// The path or command name that runs FFmpeg.
    public let ffmpegExec: String
    /// Whether probing (and the FFmpeg processes using these options) log verbosely.
    public let verbose: Bool

    private struct State {
        var ffmpegVersion: String?
        var gpuMem: Int?
        var hostSystem: String?
        var cpuGeneration: Int?
        var codecs: [String: (decoders: Set<String>, encoders: Set<String>)] = [:]
        var hwAccels: [String] = []
    }

    private let log: Logger
    private let environment: FfmpegHostEnvironment
    private let state = NIOLockedValueBox(State())

    /// Detects the host system now; FFmpeg itself is probed by `probe()`.
    public init(ffmpegExec: String? = nil, log: Logger, verbose: Bool = false, environment: FfmpegHostEnvironment = .current) {
        self.ffmpegExec = ffmpegExec ?? "ffmpeg"
        self.log = log
        self.verbose = verbose
        self.environment = environment
        probeHwOs()
    }

    /// Capabilities known in advance (a cache, or tests): nothing is probed and `probe()` is not needed.
    public init(
        ffmpegExec: String = "ffmpeg", log: Logger, verbose: Bool = false, ffmpegVersion: String, hostSystem: String = "generic",
        cpuGeneration: Int = 0, gpuMem: Int = 0, decoders: [String: Set<String>] = [:], encoders: [String: Set<String>] = [:],
        hwAccels: Set<String> = []
    ) {
        self.ffmpegExec = ffmpegExec
        self.log = log
        self.verbose = verbose
        self.environment = .current
        state.withLockedValue { state in
            state.ffmpegVersion = ffmpegVersion
            state.hostSystem = hostSystem
            state.cpuGeneration = cpuGeneration
            state.gpuMem = gpuMem
            for (codec, list) in decoders {
                state.codecs[codec.lowercased(), default: ([], [])].decoders.formUnion(list.map { $0.lowercased() })
            }
            for (codec, list) in encoders {
                state.codecs[codec.lowercased(), default: ([], [])].encoders.formUnion(list.map { $0.lowercased() })
            }
            state.hwAccels = hwAccels.map { $0.lowercased() }.sorted()
        }
    }

    /// Probes the host and FFmpeg: the version, codecs and hardware accelerators. False when FFmpeg is missing or fails.
    public func probe() async -> Bool {
        // On a Raspberry Pi, check that there is enough GPU memory for hardware decoding and encoding.
        if hostSystem == "raspbian" {
            _ = await probeRpiGpuMem()
        }
        // Capture the version of FFmpeg, then make sure we have a working video processor before anything else.
        guard await probeFfmpegVersion() else { return false }
        guard await probeFfmpegCodecs(), await probeFfmpegHwAccel() else { return false }
        return true
    }

    /// Whether `codec` (e.g. `h264`) has the decoder `decoder` (e.g. `h264_qsv`). Case-insensitive.
    public func hasDecoder(_ codec: String, _ decoder: String) -> Bool {
        state.withLockedValue { $0.codecs[codec.lowercased()]?.decoders.contains(decoder.lowercased()) ?? false }
    }

    /// Whether `codec` (e.g. `h264`) has the encoder `encoder` (e.g. `h264_videotoolbox`). Case-insensitive.
    public func hasEncoder(_ codec: String, _ encoder: String) -> Bool {
        state.withLockedValue { $0.codecs[codec.lowercased()]?.encoders.contains(encoder.lowercased()) ?? false }
    }

    /// Whether a hardware accelerator from `ffmpeg -hwaccels` is available and passed its test encode.
    public func hasHwAccel(_ accel: String) -> Bool {
        state.withLockedValue { $0.hwAccels.contains(accel.lowercased()) }
    }

    /// The GPU memory of a Raspberry Pi in MB; 0 elsewhere.
    public var gpuMem: Int { state.withLockedValue { $0.gpuMem ?? 0 } }

    /// The FFmpeg version, `unknown` when it could not be parsed, empty before probing.
    public var ffmpegVersion: String { state.withLockedValue { $0.ffmpegVersion ?? "" } }

    /// `generic`, `macOS.Apple`, `macOS.Intel` or `raspbian`: only what changes the FFmpeg options we use.
    public var hostSystem: String { state.withLockedValue { $0.hostSystem ?? "generic" } }

    /// The Intel CPU generation on Linux, or the Apple Silicon generation on macOS; 0 when unknown.
    public var cpuGeneration: Int { state.withLockedValue { $0.cpuGeneration ?? 0 } }

    // MARK: Probes

    private func probeFfmpegVersion() async -> Bool {
        await probeCmd(ffmpegExec, ["-hide_banner", "-version"]) { stdout in
            let version = Self.parseVersion(stdout) ?? "unknown"
            self.state.withLockedValue { $0.ffmpegVersion = version }
            self.log.info("Using FFmpeg version: \(version).")
        }
    }

    /// `^ffmpeg version (.*) Copyright.*$` on any line.
    static func parseVersion(_ output: String) -> String? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("ffmpeg version ") else { continue }
            let rest = line.dropFirst("ffmpeg version ".count)
            // Greedy: the last " Copyright" on the line.
            guard let range = rest.range(of: " Copyright", options: .backwards) else { continue }
            return String(rest[..<range.lowerBound])
        }
        return nil
    }

    private func probeFfmpegHwAccel() async -> Bool {
        guard await probeCmd(ffmpegExec, ["-hide_banner", "-hwaccels"], { stdout in
            self.state.withLockedValue { state in
                for accel in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
                    // Skip blank lines and the heading.
                    guard !accel.isEmpty, accel != "Hardware acceleration methods:" else { continue }
                    let name = accel.lowercased()
                    if !state.hwAccels.contains(name) { state.hwAccels.append(name) }
                }
            }
        }) else { return false }

        // A codec or accelerator FFmpeg knows about may still lack the hardware to run it, which would fail every session. A
        // one-second test encode through each accelerator keeps those out.
        for accel in state.withLockedValue({ $0.hwAccels }) {
            let ok = await probeCmd(ffmpegExec, [
                "-hide_banner", "-hwaccel", accel, "-v", "quiet", "-t", "1", "-f", "lavfi", "-i", "color=black:1920x1080", "-c:v", "libx264", "-f",
                "null", "-",
            ], quietRunErrors: true, { _ in })
            if !ok {
                state.withLockedValue { $0.hwAccels.removeAll { $0 == accel } }
                if verbose {
                    log.error("Hardware-accelerated decoding and encoding using \(accel) will be unavailable: unable to successfully validate capabilities.")
                }
            }
        }
        return true
    }

    private func probeFfmpegCodecs() async -> Bool {
        await probeCmd(ffmpegExec, ["-hide_banner", "-codecs"]) { stdout in
            self.state.withLockedValue { state in
                for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
                    if case let (codec, decoders)? = Self.parseCodecLine(String(line), kind: "decoders") {
                        for decoder in decoders { state.codecs[codec, default: ([], [])].decoders.insert(decoder.lowercased()) }
                    }
                    if case let (codec, encoders)? = Self.parseCodecLine(String(line), kind: "encoders") {
                        for encoder in encoders { state.codecs[codec, default: ([], [])].encoders.insert(encoder.lowercased()) }
                    }
                }
            }
        }
    }

    /// `\S+\s+(\S+).+\(decoders: (.*?)\s*\)` (or `encoders`): the codec name and its implementations.
    static func parseCodecLine(_ line: String, kind: String) -> (String, [String])? {
        let match = kind == "decoders"
            ? line.firstMatch(of: #/\S+\s+(\S+).+\(decoders: (.*?)\s*\)/#)
            : line.firstMatch(of: #/\S+\s+(\S+).+\(encoders: (.*?)\s*\)/#)
        guard let match else { return nil }
        return (String(match.output.1), match.output.2.split(separator: " ", omittingEmptySubsequences: false).map(String.init))
    }

    // Identify the hardware and operating system we run on.
    private func probeHwOs() {
        let cpuModelString = environment.cpuModel ?? ""
        var hostSystem: String?
        var cpuGeneration: Int?
        switch environment.platform {
        case "darwin":
            let apple = cpuModelString.contains("Apple")
            hostSystem = "macOS." + (apple ? "Apple" : "Intel")
            if apple {
                cpuGeneration = 0
                if let match = cpuModelString.firstMatch(of: #/Apple M(\d+) .*/#.ignoresCase()), let generation = Int(match.output.1) {
                    cpuGeneration = generation
                }
            }
        case "linux":
            // Raspberry Pi identifies itself in the device tree since the 4.9 kernel.
            if let model = environment.deviceModel(), model.contains(#/Raspberry Pi (Compute Module )?4/#) {
                hostSystem = "raspbian"
            }
            if cpuModelString.contains("Intel") {
                cpuGeneration = 0
                if let match = cpuModelString.firstMatch(of: #/Intel.*Core.*i\d+-(\d{3,5})/#.ignoresCase()) {
                    let sku = String(match.output.1)
                    let number = Int(sku) ?? 0
                    if number < 1000 {
                        // First generation CPUs have three-digit SKUs.
                        cpuGeneration = 1
                    } else if sku.count > 4 {
                        // Five-digit SKUs: the generation is the digits before the last three.
                        cpuGeneration = Int(sku.dropLast(3)) ?? 0
                    } else {
                        // Four-digit SKUs: the first digit.
                        cpuGeneration = Int(String(sku.prefix(1))) ?? 0
                    }
                }
            }
        default:
            break
        }
        state.withLockedValue { state in
            state.hostSystem = hostSystem
            state.cpuGeneration = cpuGeneration
        }
    }

    private func probeRpiGpuMem() async -> Bool {
        await probeCmd("vcgencmd", ["get_mem", "gpu"]) { stdout in
            // ^gpu=(.*)M\n$, then parseInt.
            var gpuMem = 0
            if stdout.hasPrefix("gpu="), stdout.hasSuffix("M\n") {
                let value = stdout.dropFirst(4).dropLast(2)
                if !value.contains("\n") { gpuMem = Self.parseInt(value) }
            }
            self.state.withLockedValue { $0.gpuMem = gpuMem }
        }
    }

    /// JavaScript's `Number.parseInt(value, 10) || 0`: leading whitespace, a sign, then the leading digits.
    static func parseInt(_ value: Substring) -> Int {
        var rest = value.drop { $0.isWhitespace }
        var sign = 1
        if let first = rest.first, first == "-" || first == "+" {
            sign = first == "-" ? -1 : 1
            rest = rest.dropFirst()
        }
        return (Int(String(rest.prefix { $0.isASCII && $0.isNumber })) ?? 0) * sign
    }

    // Runs a probe and hands its output to `processOutput`.
    private func probeCmd(_ command: String, _ arguments: [String], quietRunErrors: Bool = false, _ processOutput: @Sendable (String) -> Void) async -> Bool {
        do throws(FfmpegCommandError) {
            let stdout = try await environment.run(command, arguments)
            processOutput(stdout)
            return true
        } catch {
            switch error {
            case .notFound:
                log.error("Unable to find '\(command)' in path: '\(environment.path)'.")
                return false
            case .failed(let message):
                if quietRunErrors { return false }
                let trimmed = message.hasSuffix(".") ? String(message.dropLast()) : message
                log.error("Error running \(command): \(trimmed).")
                log.error(
                    "Unable to probe the capabilities of your Homebridge host without access to '\(command)'. Ensure that it is available in your path and correctly working."
                )
                return false
            }
        }
    }
}
