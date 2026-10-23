import Foundation
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// Whether a newer Homeswift is out: GitHub's latest release, asked a while after the start and twice a day, and
/// how this install gets it (the NAS's .spk, the container's tag, Homebrew, a checkout). The Status page shows
/// it. The bridge never upgrades itself: a Synology package runs as its own user, and a container is replaced
/// from outside.
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
            if executable.contains("/Cellar/") { return .homebrew }
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
        public init() {}
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
        } catch {
            state.withLockedValue { $0.checkedAt = Date(); $0.error = "\(error)" }
            options.logger.debug("Could not check for a new Homeswift: \(error)")
        }
    }

    struct CheckError: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    static func release(from json: JSONValue) throws -> Release {
        guard let tag = json["tag_name"]?.stringValue, let url = json["html_url"]?.stringValue else {
            throw CheckError(message: "GitHub's answer has no release")
        }
        let assets = (json["assets"]?.arrayValue ?? []).compactMap { asset -> Asset? in
            guard let name = asset["name"]?.stringValue, let url = asset["browser_download_url"]?.stringValue else { return nil }
            return Asset(name: name, url: url)
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, url: url, notes: String((json["body"]?.stringValue ?? "").prefix(4000)), publishedAt: json["published_at"]?.stringValue, assets: assets)
    }

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
    /// check.
    public func json() -> JSONValue? {
        let state = state.withLockedValue { $0 }
        guard let checkedAt = state.checkedAt else { return nil }
        var object: [String: JSONValue] = [
            "current": .string(options.current), "install": .string(options.install.rawValue),
            "checkedAt": .string(ISO8601DateFormatter().string(from: checkedAt)),
        ]
        if let error = state.error { object["error"] = .string(error) }
        guard let latest = state.latest else {
            object["available"] = false
            return .object(object)
        }
        let available = Self.isNewer(latest.version, than: options.current)
        object["available"] = .bool(available)
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
                object["how"] = "Upgrade with Homebrew, then restart the bridge."
            case .source:
                object["command"] = .string("git fetch --tags && git checkout v\(latest.version)")
                object["how"] = "Check out the release, build it, then restart the bridge."
            }
        }
        return .object(object)
    }
}
