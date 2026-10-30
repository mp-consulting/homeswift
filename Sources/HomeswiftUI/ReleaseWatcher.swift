import Foundation
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// Whether a newer Homeswift is out: GitHub's latest release, asked a while after the start and twice a day, and
/// how this install gets it (the NAS's .spk, the container's tag, Homebrew, a checkout). The Status page shows
/// it. A Homebrew install upgrades itself when an administrator asks (`install`, then a restart into the new
/// binary); the others cannot: a Synology package runs as its own user, a container is replaced from outside, and a
/// checkout is built by hand.
public final class ReleaseWatcher: Sendable {
    public static let repository = "mp-consulting/homeswift"

    /// How Homeswift was installed, which decides what upgrading it means.
    public enum Install: String, Sendable {
        case synology, docker, homebrew, source

        /// `HOMESWIFT_INSTALL` (the Synology package and the container image set it), else what the file
        /// system says.
        public static func detect(
            environment: [String: String] = ProcessInfo.processInfo.environment, executable: String = CommandLine.arguments.first ?? "",
            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        ) -> Install {
            if let value = environment["HOMESWIFT_INSTALL"], let install = Install(rawValue: value) { return install }
            if fileExists("/var/packages/homeswift/INFO") { return .synology }
            if fileExists("/.dockerenv") { return .docker }
            // `brew services` starts the `opt/homeswift` link, which leads to the Cellar.
            let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
            if executable.contains("/Cellar/") || resolved.contains("/Cellar/") { return .homebrew }
            return .source
        }
    }

    public struct Asset: Sendable, Equatable {
        public var name: String
        public var url: String
    }

    public struct Release: Sendable, Equatable {
        /// Without the tag's `v`: `0.3.1`.
        public var version: String
        public var url: String
        public var notes: String
        public var publishedAt: String?
        public var assets: [Asset]
    }

    public struct Options: Sendable {
        public var current = PluginHost.version
        public var install = Install.detect()
        /// The architecture as the release's packages name it.
        public var architecture = ReleaseWatcher.architecture
        /// The first check, after the bridge has settled: a restart loop does not ask GitHub each time.
        public var delay: Duration = .seconds(60)
        public var interval: Duration = .seconds(12 * 3600)
        public var logger = Logger(label: "homeswift.ui")
        /// What installs a release on this machine: Homebrew's, for a Homebrew install; nil where the bridge cannot
        /// upgrade itself.
        public var installer: (any UpdateInstalling)?
        public init() {
            if install == .homebrew { installer = HomebrewInstaller() }
        }
    }

    #if arch(x86_64)
    public static let architecture = "x86_64"
    #elseif arch(arm64)
    public static let architecture = "aarch64"
    #else
    public static let architecture = "other"
    #endif

    private struct State {
        var latest: Release?
        var checkedAt: Date?
        var error: String?
        /// The version last logged as available, to log it once.
        var announced: String?
        /// While a release installs, its version.
        var installing: String?
        /// The version installed on disk when it is not the one running: a relaunch starts it.
        var installed: String?
        var installError: String?
        /// The restart into the installed version has been asked for.
        var relaunching = false
    }

    let transport: any HTTPSending
    public let options: Options
    private let state = NIOLockedValueBox(State())
    private let task = NIOLockedValueBox<Task<Void, Never>?>(nil)

    public init(transport: any HTTPSending = HTTPClient(), options: Options = Options()) {
        self.transport = transport
        self.options = options
    }

    /// Checks after `delay`, then every `interval`; once started, a second call does nothing.
    public func start() {
        task.withLockedValue { task in
            guard task == nil else { return }
            let options = options
            task = Task { [self] in
                try? await Task.sleep(for: options.delay)
                while !Task.isCancelled {
                    await check()
                    try? await Task.sleep(for: options.interval)
                }
            }
        }
    }

    public func stop() {
        task.withLockedValue { task in
            task?.cancel()
            task = nil
        }
    }

    /// Asks GitHub for the latest release. A failure is kept for the Status page and the last answer stays.
    public func check() async {
        var request = HomeswiftNetwork.HTTPRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!, timeout: .seconds(20))
        request.headers = [("Accept", "application/vnd.github+json"), ("User-Agent", "Homeswift/\(options.current)")]
        do {
            let response = try await transport.send(request)
            // No release yet.
            if response.status == 404 {
                state.withLockedValue { $0.checkedAt = Date(); $0.error = nil }
                return
            }
            guard response.isSuccess else { throw CheckError(message: "GitHub answered HTTP \(response.status)") }
            let release = try Self.release(from: JSONValue(data: response.body))
            let announce = state.withLockedValue { state -> Bool in
                state.latest = release
                state.checkedAt = Date()
                state.error = nil
                guard Self.isNewer(release.version, than: options.current), state.announced != release.version else { return false }
                state.announced = release.version
                return true
            }
            if announce {
                options.logger.info("Homeswift \(release.version) is available (this is \(options.current)): \(release.url)")
            }
            await noteInstalledVersion()
        } catch {
            state.withLockedValue { $0.checkedAt = Date(); $0.error = "\(error)" }
            options.logger.debug("Could not check for a new Homeswift: \(error)")
        }
    }

    /// The version on disk, when the installer knows it and it is not the one running (`brew upgrade` run by hand,
    /// or by `install`): the Status page then offers a relaunch.
    public func noteInstalledVersion() async {
        guard let installer = options.installer, state.withLockedValue({ $0.installing == nil }), let version = await installer.installedVersion() else { return }
        let current = options.current
        state.withLockedValue { $0.installed = version == current ? nil : version }
    }

    /// Starts installing the latest release in the background (GET /api/updates says how it goes); `installed` runs
    /// once it is on disk, to restart into it. False while one installs, or with nothing newer to install.
    @discardableResult
    public func install(then installed: @escaping @Sendable () -> Void = {}) -> Bool {
        guard let installer = options.installer else { return false }
        let current = options.current
        guard let version = state.withLockedValue({ state -> String? in
            guard state.installing == nil, let latest = state.latest, Self.isNewer(latest.version, than: current) else { return nil }
            state.installing = latest.version
            state.installError = nil
            return latest.version
        }) else { return false }
        options.logger.warning("Installing Homeswift \(version) (this is \(current))")
        Task { [self] in
            do {
                try await installer.install(version: version)
                let found = await installer.installedVersion()
                guard let found, found != current else {
                    throw InstallError(message: "the installer finished, but Homeswift \(found ?? current) is still the one installed; Homebrew's tap may not have \(version) yet (it catches up within 6 hours)")
                }
                state.withLockedValue { $0.installing = nil; $0.installed = found }
                options.logger.info("Homeswift \(found) is installed; a restart starts it")
                installed()
            } catch {
                state.withLockedValue { $0.installing = nil; $0.installError = "\(error)" }
                options.logger.error("Could not install Homeswift \(version): \(error)")
            }
        }
        return true
    }

    /// The restart into the installed version is on its way: the page waits for it rather than offering it again.
    public func noteRelaunch() {
        state.withLockedValue { $0.relaunching = true }
    }

    /// The binary a restart runs: the installer's (Homebrew's `opt` link, which follows an upgrade), else nil for
    /// this one.
    public var relaunchExecutable: String? { options.installer?.executable }

    struct CheckError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    static func release(from json: JSONValue) throws -> Release {
        guard let tag = json["tag_name"]?.stringValue, let url = json["html_url"]?.stringValue, isWeb(url) else {
            throw CheckError(message: "GitHub's answer has no release")
        }
        let assets = (json["assets"]?.arrayValue ?? []).compactMap { asset -> Asset? in
            guard let name = asset["name"]?.stringValue, let url = asset["browser_download_url"]?.stringValue, isWeb(url) else { return nil }
            return Asset(name: name, url: url)
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        // The version goes into a command the Status page offers to copy: digits, letters, dots and dashes only.
        guard !version.isEmpty, version.count <= 40, version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-+".contains($0)) }) else {
            throw CheckError(message: "GitHub's latest release has an unexpected tag")
        }
        return Release(version: version, url: url, notes: String((json["body"]?.stringValue ?? "").prefix(4000)), publishedAt: json["published_at"]?.stringValue, assets: assets)
    }

    /// An https address, the only kind the page links to.
    static func isWeb(_ url: String) -> Bool { URL(string: url)?.scheme?.lowercased() == "https" }

    /// Whether `version` comes after `current`, part by part as numbers: `0.10.0` after `0.9.2`. A suffix
    /// (`-beta`, a package's `-2`) is left out.
    static func isNewer(_ version: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            let core = text.split(separator: "-", maxSplits: 1).first.map(String.init) ?? text
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let new = parts(version), old = parts(current)
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0, b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// For the Status page: this version, the latest, and how to upgrade this install. Empty until the first
    /// check, unless `always` (the Settings page's, which says so).
    public func json(always: Bool = false) -> JSONValue? {
        let state = state.withLockedValue { $0 }
        guard state.checkedAt != nil || always else { return nil }
        var object: [String: JSONValue] = [
            "current": .string(options.current), "install": .string(options.install.rawValue),
            "automatic": .bool(task.withLockedValue { $0 != nil }),
        ]
        if let checkedAt = state.checkedAt { object["checkedAt"] = .string(Timestamp.iso8601(checkedAt)) }
        if let error = state.error { object["error"] = .string(error) }
        if let installing = state.installing { object["installing"] = .string(installing) }
        if let installed = state.installed { object["installed"] = .string(installed) }
        if let installError = state.installError { object["installError"] = .string(installError) }
        if state.relaunching { object["relaunching"] = true }
        guard let latest = state.latest else {
            object["available"] = false
            return .object(object)
        }
        let available = Self.isNewer(latest.version, than: options.current)
        object["available"] = .bool(available)
        // Installing is offered until the latest is the one on disk.
        object["canInstall"] = .bool(available && options.installer != nil && state.installed.map { Self.isNewer(latest.version, than: $0) } ?? true)
        object["latest"] = .string(latest.version)
        object["url"] = .string(latest.url)
        object["notes"] = .string(latest.notes)
        if let published = latest.publishedAt { object["publishedAt"] = .string(published) }
        if available {
            switch options.install {
            case .synology:
                if let package = latest.assets.first(where: { $0.name.hasPrefix("homeswift-\(options.architecture)-") && $0.name.hasSuffix(".spk") }) {
                    object["download"] = ["name": .string(package.name), "url": .string(package.url)]
                }
                object["how"] = "Download the package, then Package Center > Manual Install. Your settings and pairings stay."
            case .docker:
                object["command"] = .string("docker pull ghcr.io/\(Self.repository):\(latest.version)")
                object["how"] = "Pull the new image and recreate the container (docker compose pull, then docker compose up -d). The config directory stays."
            case .homebrew:
                object["command"] = "brew upgrade homeswift"
                object["how"] = options.installer == nil ? "Upgrade with Homebrew, then restart the bridge." : "Install it here (Homebrew upgrades it, then the bridge restarts), or run the command yourself and relaunch."
            case .source:
                object["command"] = .string("git fetch --tags && git checkout v\(latest.version)")
                object["how"] = "Check out the release, build it, then restart the bridge."
            }
        }
        return .object(object)
    }
}

/// Puts a release on this machine. The bridge restarts into `executable` afterwards.
public protocol UpdateInstalling: Sendable {
    func install(version: String) async throws
    /// The version on disk now, which may not be the one running.
    func installedVersion() async -> String?
    /// The binary to restart into, which an upgrade replaces; nil for this one.
    var executable: String? { get }
}

/// `brew upgrade homeswift` with the Homebrew that installed this binary (its prefix is the part of the path before
/// `/Cellar/`), then `opt/homeswift/bin/homeswift`, the link the upgrade moves to the new version.
public struct HomebrewInstaller: UpdateInstalling {
    public let prefix: String
    /// How long an upgrade may take: fetching the tap, the bottle or the source and building it.
    public var timeout: Duration = .seconds(30 * 60)

    public init?(executable: String = CommandLine.arguments.first ?? "") {
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        guard let range = path.range(of: "/Cellar/") else { return nil }
        prefix = String(path[..<range.lowerBound])
    }

    public var executable: String? { "\(prefix)/opt/homeswift/bin/homeswift" }

    public func install(version: String) async throws {
        // A service starts with a short PATH; brew needs its own bin and the system's tools. Its auto-update fetches
        // the tap, which has the new formula once its workflow ran.
        let environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "\(prefix)/bin:\(prefix)/sbin:/usr/bin:/bin:/usr/sbin:/sbin", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1",
        ]) { $1 }
        let result = try await SubprocessRunner.run("\(prefix)/bin/brew", ["upgrade", "homeswift"], environment: environment, timeout: timeout)
        guard result.status == 0 else {
            throw InstallError(message: "brew upgrade failed (exit \(result.status)): \(result.tail)")
        }
    }

    public func installedVersion() async -> String? {
        guard let executable, let result = try? await SubprocessRunner.run(executable, ["--version"], timeout: .seconds(20)), result.status == 0 else { return nil }
        let version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty || version.count > 40 ? nil : version
    }
}

struct InstallError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

/// Runs a tool to its end, its output (both streams) into a temporary file, so a chatty `brew` never fills a pipe.
enum SubprocessRunner {
    struct Result {
        var status: Int32
        var output: String
        /// The last lines, for an error.
        var tail: String {
            let lines = output.split(separator: "\n", omittingEmptySubsequences: true).suffix(6)
            return String(lines.joined(separator: " / ").suffix(600))
        }
    }

    static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil, timeout: Duration) async throws -> Result {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw InstallError(message: "cannot write \(log.path)") }
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: InstallError(message: "cannot run \(path): \(error)")) }
            let deadline = DispatchTime.now() + .seconds(Int(timeout.components.seconds))
            DispatchQueue.global().asyncAfter(deadline: deadline) { [process] in if process.isRunning { process.terminate() } }
        }
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return Result(status: status, output: output)
    }
}
