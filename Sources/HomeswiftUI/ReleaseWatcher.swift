import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// Whether a newer Homeswift is out: GitHub's latest release, asked a while after the start and twice a day, and
/// how this install gets it (the NAS's .spk, the container's tag, Homebrew, a checkout). The Status page shows
/// it. A Homebrew install and a Synology package upgrade themselves when an administrator asks (`install`, with its
/// progress, then a restart into the new binary); a container is replaced from outside, and a checkout is built by
/// hand.
public final class ReleaseWatcher: Sendable {
    public static let repository = "mp-consulting/homeswift"

    /// How Homeswift was installed, which decides what upgrading it means.
    public enum Install: String, Sendable {
        case synology, docker, homebrew, source

        /// `HOMESWIFT_INSTALL` (the Synology package and the container image set it), else what the file
        /// system says.
        public static func detect(
            environment: [String: String] = ProcessInfo.processInfo.environment, executable: String = ReleaseWatcher.runningExecutable,
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
            if install == .synology { installer = SynologyInstaller(architecture: architecture) }
        }
    }

    /// This process's binary: the kernel's path where Foundation knows it, since a shell passes a bare `homeswift`
    /// as the first argument.
    public static var runningExecutable: String { Bundle.main.executablePath ?? CommandLine.arguments.first ?? "" }

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
        /// While a release installs, its version, and how far it has got.
        var installing: String?
        var progress: UpdateProgress?
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
            guard response.isSuccess else { throw UpdateError(message: "GitHub answered HTTP \(response.status)") }
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

    /// The version on disk, when the installer knows it and it is newer than the one running (`brew upgrade` run by
    /// hand, or by `install`): the Status page then offers a relaunch. An older one is no update to relaunch into.
    public func noteInstalledVersion() async {
        guard let installer = options.installer, state.withLockedValue({ $0.installing == nil }), let version = await installer.installedVersion() else { return }
        let current = options.current
        state.withLockedValue { $0.installed = Self.isNewer(version, than: current) ? version : nil }
    }

    /// Whether `install` would start: an installer, nothing installing, and a release newer than both this version
    /// and the one on disk.
    private func canInstall(_ state: State) -> Bool {
        guard options.installer != nil, state.installing == nil, let latest = state.latest, Self.isNewer(latest.version, than: options.current) else { return false }
        return state.installed.map { Self.isNewer(latest.version, than: $0) } ?? true
    }

    /// Starts installing the latest release in the background (GET /api/updates says how it goes). Once it is on disk,
    /// `relaunch` asks for the restart into it and says whether one is coming. False when `canInstall` is.
    @discardableResult
    public func install(relaunch: @escaping @Sendable () -> Bool = { false }) -> Bool {
        guard let installer = options.installer else { return false }
        let current = options.current
        guard let release = state.withLockedValue({ state -> Release? in
            guard canInstall(state), let latest = state.latest else { return nil }
            state.installing = latest.version
            state.progress = UpdateProgress(phase: .downloading)
            state.installError = nil
            return latest
        }) else { return false }
        let version = release.version
        options.logger.warning("Installing Homeswift \(version) (this is \(current))")
        Task { [self] in
            do {
                try await installer.install(release: release) { [state] progress in state.withLockedValue { $0.progress = progress } }
                let found = await installer.installedVersion()
                guard let found, Self.isNewer(found, than: current) else {
                    throw UpdateError(message: "the installer finished, but Homeswift \(found ?? current) is still the one installed; Homebrew's tap may not have \(version) yet (it catches up within 6 hours)")
                }
                options.logger.info("Homeswift \(found) is installed; a restart starts it")
                // Asked before the state says installed, so a page that sees the install done also sees the relaunch.
                let relaunching = relaunch()
                state.withLockedValue { $0.installing = nil; $0.progress = nil; $0.installed = found; $0.relaunching = relaunching }
            } catch {
                state.withLockedValue { $0.installing = nil; $0.progress = nil; $0.installError = "\(error)" }
                options.logger.error("Could not install Homeswift \(version): \(error)")
            }
        }
        return true
    }

    static func release(from json: JSONValue) throws -> Release {
        guard let tag = json["tag_name"]?.stringValue, let url = json["html_url"]?.stringValue, isWeb(url) else {
            throw UpdateError(message: "GitHub's answer has no release")
        }
        let assets = (json["assets"]?.arrayValue ?? []).compactMap { asset -> Asset? in
            guard let name = asset["name"]?.stringValue, let url = asset["browser_download_url"]?.stringValue, isWeb(url) else { return nil }
            return Asset(name: name, url: url)
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        // The version goes into a command the Status page offers to copy: digits, letters, dots and dashes only.
        guard !version.isEmpty, version.count <= 40, version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-+".contains($0)) }) else {
            throw UpdateError(message: "GitHub's latest release has an unexpected tag")
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
        if let progress = state.progress {
            object["progress"] = ["phase": .string(progress.phase.rawValue), "fraction": progress.fraction.map { .number($0) } ?? .null]
        }
        if let installed = state.installed { object["installed"] = .string(installed) }
        if let installError = state.installError { object["installError"] = .string(installError) }
        if state.relaunching { object["relaunching"] = true }
        guard let latest = state.latest else {
            object["available"] = false
            return .object(object)
        }
        let available = Self.isNewer(latest.version, than: options.current)
        object["available"] = .bool(available)
        object["canInstall"] = .bool(canInstall(state))
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
                object["how"] = options.installer == nil ? "Download the package, then Package Center > Manual Install. Your settings and pairings stay."
                    : "Install it here (the bridge downloads the package, puts its files in place and restarts; Package Center shows the version it installed until its next install), or download it for Package Center > Manual Install. Your settings and pairings stay."
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

/// How far an install has got, for the Status page: downloading (with the share done when the size is known), then
/// installing.
public struct UpdateProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case downloading, installing }
    public var phase: Phase
    /// 0...1 when the installer can tell; nil while it cannot.
    public var fraction: Double?

    public init(phase: Phase, fraction: Double? = nil) {
        self.phase = phase
        self.fraction = fraction.map { min(max($0, 0), 1) }
    }
}

/// Puts a release on this machine, saying how far it has got. The bridge restarts into `executable` afterwards.
public protocol UpdateInstalling: Sendable {
    func install(release: ReleaseWatcher.Release, progress: @escaping @Sendable (UpdateProgress) -> Void) async throws
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

    public init?(executable: String = ReleaseWatcher.runningExecutable) {
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        guard let range = path.range(of: "/Cellar/") else { return nil }
        prefix = String(path[..<range.lowerBound])
    }

    public var executable: String? { "\(prefix)/opt/homeswift/bin/homeswift" }

    public func install(release: ReleaseWatcher.Release, progress: @escaping @Sendable (UpdateProgress) -> Void) async throws {
        // A service starts with a short PATH; brew needs its own bin and the system's tools. Its auto-update fetches
        // the tap, which has the new formula once its workflow ran.
        let environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "\(prefix)/bin:\(prefix)/sbin:/usr/bin:/bin:/usr/sbin:/sbin", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1",
        ]) { $1 }
        let reader = NIOLockedValueBox(BrewProgress())
        let result = try await SubprocessRunner.run("\(prefix)/bin/brew", ["upgrade", "homeswift"], environment: environment, timeout: timeout) { line in
            if let now = reader.withLockedValue({ $0.read(line) }) { progress(now) }
        }
        guard result.status == 0 else {
            throw UpdateError(message: "brew upgrade failed (exit \(result.status)): \(result.tail)")
        }
    }

    /// The Cellar version the `opt` link leads to (`Cellar/homeswift/0.4.0_1/bin/homeswift`, without the formula's
    /// revision): no process to start on each look.
    public func installedVersion() async -> String? {
        guard let executable else { return nil }
        let parts = URL(fileURLWithPath: executable).resolvingSymlinksInPath().pathComponents
        guard let index = parts.lastIndex(of: "Cellar"), index + 2 < parts.count, parts[index + 1] == "homeswift" else { return nil }
        let version = parts[index + 2].split(separator: "_").first.map(String.init) ?? ""
        return version.isEmpty || version.count > 40 ? nil : version
    }
}

/// What `brew upgrade`'s output says of how far it has got: fetching and downloading, then pouring or building and
/// linking; a percentage on a download's line when brew prints one.
struct BrewProgress {
    private(set) var current = UpdateProgress(phase: .downloading)

    /// The progress after `line`, when it changed.
    mutating func read(_ line: String) -> UpdateProgress? {
        let before = current
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("==> ") {
            let step = text.dropFirst(4).lowercased()
            if step.hasPrefix("fetching") || step.hasPrefix("downloading") {
                current = UpdateProgress(phase: .downloading)
            } else if ["pouring", "installing", "upgrading", "building", "linking", "caveats", "summary", "running"].contains(where: { step.hasPrefix($0) }) {
                current = UpdateProgress(phase: .installing)
            }
        } else if current.phase == .downloading, let range = text.range(of: #"(\d{1,3}(?:\.\d+)?)%"#, options: .regularExpression) {
            let number = text[range].dropLast()
            if let value = Double(number), value <= 100 { current = UpdateProgress(phase: .downloading, fraction: value / 100) }
        }
        return current == before ? nil : current
    }
}

/// A Synology package's own upgrade, as Package Center would do it but without it (the package runs as its own user,
/// who owns its files in `target` but not Package Center's records): the release's .spk for this architecture is
/// downloaded beside the package, unpacked, its binary asked its version, then `bin`, `lib`, `app` and `share` are
/// swapped in by renames (each one atomic, all of them undone when one fails); the running binary keeps its inode
/// until the restart. Package Center goes on showing the version it installed. Nil where the package's folder is not
/// this user's to write.
public struct SynologyInstaller: UpdateInstalling {
    public let target: URL
    public let architecture: String
    let transport: any HTTPStreaming
    /// The download, unpacking and swap; the download alone has its own deadline per read.
    public var timeout: Duration = .seconds(30 * 60)
    static let folders = ["bin", "lib", "app", "share"]

    public init?(target: String = "/var/packages/homeswift/target", architecture: String = ReleaseWatcher.architecture,
                 transport: any HTTPStreaming = HTTPClient(), requireWritable: Bool = true) {
        let url = URL(fileURLWithPath: target).resolvingSymlinksInPath()
        guard !requireWritable || FileManager.default.isWritableFile(atPath: url.path) else { return nil }
        self.target = url
        self.architecture = architecture
        self.transport = transport
    }

    public var executable: String? { target.appendingPathComponent("bin/homeswift").path }

    public func install(release: ReleaseWatcher.Release, progress: @escaping @Sendable (UpdateProgress) -> Void) async throws {
        guard let asset = release.assets.first(where: { $0.name.hasPrefix("homeswift-\(architecture)-") && $0.name.hasSuffix(".spk") }) else {
            throw UpdateError(message: "the release has no package for \(architecture)")
        }
        let files = FileManager.default
        // Beside the package, on its volume: the swap is a rename, not a copy.
        let work = target.appendingPathComponent(".update")
        try? files.removeItem(at: work)
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: work) }

        let package = work.appendingPathComponent("homeswift.spk")
        try await download(asset.url, to: package) { progress(UpdateProgress(phase: .downloading, fraction: $0)) }
        progress(UpdateProgress(phase: .installing))
        // An .spk is a tar of INFO, the scripts and package.tgz, which is what lands in target.
        let staged = work.appendingPathComponent("package")
        try files.createDirectory(at: staged, withIntermediateDirectories: true)
        try await tar(["-xf", package.path, "-C", work.path, "package.tgz"])
        try await tar(["-xzf", work.appendingPathComponent("package.tgz").path, "-C", staged.path])
        // The new binary must run here and be the release: its libraries come with it (RPATH $ORIGIN/../lib).
        let binary = staged.appendingPathComponent("bin/homeswift")
        let answer = try await SubprocessRunner.run(binary.path, ["--version"], timeout: .seconds(60))
        let reported = answer.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard answer.status == 0, reported == release.version else {
            throw UpdateError(message: "the package's binary does not run here (it said \"\(reported.prefix(120))\"); nothing was changed")
        }
        try Self.swap(staged: staged, into: target, keeping: work.appendingPathComponent("previous"))
    }

    /// Puts each of `folders` from `staged` in place in `target`, the old one moved to `keeping`; on a failure, the
    /// folders already swapped go back.
    static func swap(staged: URL, into target: URL, keeping: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: keeping, withIntermediateDirectories: true)
        var done: [String] = []
        do {
            for name in folders where files.fileExists(atPath: staged.appendingPathComponent(name).path) {
                let current = target.appendingPathComponent(name), previous = keeping.appendingPathComponent(name)
                let had = files.fileExists(atPath: current.path)
                if had { try files.moveItem(at: current, to: previous) }
                do {
                    try files.moveItem(at: staged.appendingPathComponent(name), to: current)
                } catch {
                    if had { try? files.moveItem(at: previous, to: current) }
                    throw error
                }
                done.append(name)
            }
        } catch {
            for name in done.reversed() {
                let current = target.appendingPathComponent(name), previous = keeping.appendingPathComponent(name)
                try? files.removeItem(at: current)
                if files.fileExists(atPath: previous.path) { try? files.moveItem(at: previous, to: current) }
            }
            throw UpdateError(message: "could not put the new files in place (\(error)); the package is as it was")
        }
    }

    /// The release's file, through GitHub's redirects to its storage, written as it comes, with the share done.
    func download(_ address: String, to file: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        guard var url = URL(string: address) else { throw UpdateError(message: "the package's address is not one") }
        for _ in 0..<6 {
            var request = HomeswiftNetwork.HTTPRequest(url: url, timeout: .seconds(60))
            request.headers = [("User-Agent", "Homeswift"), ("Accept", "application/octet-stream")]
            let response = try await transport.stream(request)
            let header = { (name: String) in response.headers.first { $0.name.lowercased() == name }?.value }
            if [301, 302, 303, 307, 308].contains(response.status), let location = header("location"), let next = URL(string: location, relativeTo: url)?.absoluteURL {
                guard next.scheme?.lowercased() == "https" else { throw UpdateError(message: "the download was sent to an address that is not https") }
                url = next
                continue
            }
            guard (200..<300).contains(response.status) else { throw UpdateError(message: "the download answered HTTP \(response.status)") }
            let total = header("content-length").flatMap(Double.init)
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw UpdateError(message: "cannot write \(file.path)") }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var received = 0.0, reported = -1.0
            progress(total == nil ? nil : 0)
            for try await chunk in response.body {
                try handle.write(contentsOf: chunk)
                received += Double(chunk.count)
                // A report per percent, not per chunk.
                if let total, total > 0, received / total - reported >= 0.01 {
                    reported = received / total
                    progress(reported)
                }
            }
            if let total, received < total { throw UpdateError(message: "the download stopped at \(Int(received)) of \(Int(total)) bytes") }
            // The last chunk can be under a percent: the bar still ends full.
            if total != nil, reported < 1 { progress(1) }
            return
        }
        throw UpdateError(message: "the download was redirected too many times")
    }

    private func tar(_ arguments: [String]) async throws {
        let tool = ["/bin/tar", "/usr/bin/tar"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "tar"
        let result = try await SubprocessRunner.run(tool, arguments, timeout: timeout)
        guard result.status == 0 else { throw UpdateError(message: "the package could not be unpacked: \(result.tail)") }
    }

    /// The version of the binary in place, which an install changes before the restart starts it.
    public func installedVersion() async -> String? {
        guard let executable, let result = try? await SubprocessRunner.run(executable, ["--version"], timeout: .seconds(30)), result.status == 0 else { return nil }
        let version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty || version.count > 40 || version.contains("\n") ? nil : version
    }
}

struct UpdateError: Error, CustomStringConvertible {
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

    /// `onLine` gets the output's lines as they are written (a look at the file every half second), for progress.
    static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil, timeout: Duration,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw UpdateError(message: "cannot write \(log.path)") }
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
        // Past the timeout, SIGTERM, then SIGKILL for a tool that ignores it: an install must end for another to start.
        // Cancelled as the process ends; DispatchWorkItem is thread-safe, though not marked Sendable.
        nonisolated(unsafe) let deadline = DispatchWorkItem { [process] in
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(10)) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        // Following the file while the tool runs: whole lines only, the last partial one waits for its end.
        let follower = onLine.map { onLine in
            Task {
                var offset: UInt64 = 0, pending = ""
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let reader = try? FileHandle(forReadingFrom: log) else { continue }
                    try? reader.seek(toOffset: offset)
                    let data = (try? reader.readToEnd()) ?? Data()
                    try? reader.close()
                    offset += UInt64(data.count)
                    pending += String(decoding: data, as: UTF8.self)
                    // brew's download bars end in carriage returns: each is a line too.
                    var lines = pending.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
                    pending = lines.popLast() ?? ""
                    for line in lines where !line.isEmpty { onLine(line) }
                }
            }
        }
        defer { follower?.cancel() }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { deadline.cancel(); continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                deadline.cancel()
                continuation.resume(throwing: UpdateError(message: "cannot run \(path): \(error)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(timeout.components.seconds)), execute: deadline)
        }
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return Result(status: status, output: output)
    }
}
