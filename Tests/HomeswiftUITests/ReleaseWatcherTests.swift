import Foundation
import HomeswiftAI
import HomeswiftNetwork
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftUI

/// GitHub's answer, canned; the requests it was sent.
final class CannedGitHub: HTTPSending, Sendable {
    let reply: NIOLockedValueBox<HomeswiftNetwork.HTTPResponse>
    let requests = NIOLockedValueBox<[HomeswiftNetwork.HTTPRequest]>([])

    init(status: Int = 200, json: String) {
        reply = NIOLockedValueBox(HomeswiftNetwork.HTTPResponse(status: status, body: Data(json.utf8)))
    }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        requests.withLockedValue { $0.append(request) }
        return reply.withLockedValue { $0 }
    }
}

/// An installer that puts `installs` on disk, or nothing (as Homebrew does when its tap is behind).
final class FakeInstaller: UpdateInstalling, Sendable {
    let onDisk: NIOLockedValueBox<String>
    let installs: String?
    init(onDisk: String, installs: String?) {
        self.onDisk = NIOLockedValueBox(onDisk)
        self.installs = installs
    }
    func install(release: ReleaseWatcher.Release, progress: @escaping @Sendable (UpdateProgress) -> Void) async throws {
        progress(UpdateProgress(phase: .downloading, fraction: 0.5))
        progress(UpdateProgress(phase: .installing))
        if let installs { onDisk.withLockedValue { $0 = installs } }
    }
    func installedVersion() async -> String? { onDisk.withLockedValue { $0 } }
    var executable: String? { "/opt/homebrew/opt/homeswift/bin/homeswift" }
}

/// GitHub's asset link, which redirects to its storage, then the file in pieces with its length.
final class CannedDownload: HTTPStreaming, Sendable {
    let file: Data
    let requests = NIOLockedValueBox<[URL]>([])
    init(_ file: Data) { self.file = file }

    func stream(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HTTPStreamingResponse {
        requests.withLockedValue { $0.append(request.url) }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self, throwing: (any Error).self)
        if request.url.host == "github.com" {
            continuation.finish()
            return HTTPStreamingResponse(status: 302, headers: [("Location", "https://objects.example.com/homeswift.spk")], body: .init(stream))
        }
        let bytes = [UInt8](file)
        for start in stride(from: 0, to: bytes.count, by: max(1, bytes.count / 10)) { continuation.yield(Array(bytes[start..<min(bytes.count, start + max(1, bytes.count / 10))])) }
        continuation.finish()
        return HTTPStreamingResponse(status: 200, headers: [("Content-Length", "\(bytes.count)")], body: .init(stream))
    }
}

@Suite struct ReleaseWatcherTests {
    /// brew's output says where the upgrade is: downloading (with the percent of a bar when it prints one), then
    /// pouring and linking.
    @Test func readsBrewsProgress() {
        var reader = BrewProgress()
        #expect(reader.read("==> Fetching homeswift") == nil)
        #expect(reader.read("##########                  42.5%") == UpdateProgress(phase: .downloading, fraction: 0.425))
        #expect(reader.read("==> Upgrading homeswift 0.3.0 -> 0.4.0") == UpdateProgress(phase: .installing))
        #expect(reader.read("90% of something after") == nil)
        #expect(reader.read("==> Pouring homeswift--0.4.0.arm64_sonoma.bottle.tar.gz") == nil)
    }

    /// A Synology package upgrades itself: the .spk through GitHub's redirect, its progress, the new binary asked its
    /// version, then bin, lib and app swapped in; a binary that is not the release leaves everything as it was.
    @Test func aSynologyPackageSwapsInTheRelease() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("homeswift-spk-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        func write(_ text: String, _ path: String, in folder: URL, executable: Bool = false) throws {
            let url = folder.appendingPathComponent(path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if executable { try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        func tar(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: files.isExecutableFile(atPath: "/usr/bin/tar") ? "/usr/bin/tar" : "/bin/tar")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        /// An .spk whose binary says `says`.
        func package(says: String) throws -> Data {
            let build = root.appendingPathComponent("build-\(says)")
            let contents = build.appendingPathComponent("package")
            try write("#!/bin/sh\necho \(says)\n", "bin/homeswift", in: contents, executable: true)
            try write("new lib", "lib/libavahi-client.so.3", in: contents)
            try write("new start", "app/start.sh", in: contents)
            let spk = build.appendingPathComponent("spk")
            try files.createDirectory(at: spk, withIntermediateDirectories: true)
            try tar(["-czf", spk.appendingPathComponent("package.tgz").path, "-C", contents.path, "."])
            try write("package=\"homeswift\"", "INFO", in: spk)
            let file = build.appendingPathComponent("homeswift.spk")
            try tar(["-cf", file.path, "-C", spk.path, "INFO", "package.tgz"])
            return try Data(contentsOf: file)
        }
        let target = root.appendingPathComponent("target")
        try write("#!/bin/sh\necho 0.3.0\n", "bin/homeswift", in: target, executable: true)
        try write("old lib", "lib/libavahi-client.so.3", in: target)
        try write("old start", "app/start.sh", in: target)
        try write("menu", "ui/config", in: target)
        let release = ReleaseWatcher.Release(version: "0.4.0", url: "https://github.com/x", notes: "", publishedAt: nil,
                                             assets: [.init(name: "homeswift-x86_64-0.4.0.spk", url: "https://github.com/mp-consulting/homeswift/releases/download/v0.4.0/homeswift-x86_64-0.4.0.spk")])

        // A package whose binary is another version: refused, nothing moved.
        let wrong = try #require(SynologyInstaller(target: target.path, architecture: "x86_64", transport: CannedDownload(try package(says: "0.3.9"))))
        await #expect(throws: UpdateError.self) { try await wrong.install(release: release) { _ in } }
        #expect(try String(contentsOf: target.appendingPathComponent("lib/libavahi-client.so.3"), encoding: .utf8) == "old lib")
        #expect(await wrong.installedVersion() == "0.3.0")

        let download = CannedDownload(try package(says: "0.4.0"))
        let installer = try #require(SynologyInstaller(target: target.path, architecture: "x86_64", transport: download))
        let seen = NIOLockedValueBox<[UpdateProgress]>([])
        try await installer.install(release: release) { progress in seen.withLockedValue { $0.append(progress) } }
        #expect(download.requests.withLockedValue { $0.map(\.host) } == ["github.com", "objects.example.com"])
        let fractions = seen.withLockedValue { $0 }.filter { $0.phase == .downloading }.compactMap(\.fraction)
        #expect(fractions.first == 0 && fractions.last == 1 && fractions == fractions.sorted())
        #expect(seen.withLockedValue { $0 }.last == UpdateProgress(phase: .installing))
        #expect(await installer.installedVersion() == "0.4.0")
        #expect(try String(contentsOf: target.appendingPathComponent("lib/libavahi-client.so.3"), encoding: .utf8) == "new lib")
        #expect(try String(contentsOf: target.appendingPathComponent("app/start.sh"), encoding: .utf8) == "new start")
        // What the package does not bring stays (DSM's menu entry), and the work folder goes.
        #expect(try String(contentsOf: target.appendingPathComponent("ui/config"), encoding: .utf8) == "menu")
        #expect(!files.fileExists(atPath: target.appendingPathComponent(".update").path))
    }

    @Test func installsAndSaysARelaunchStartsIt() async throws {
        let releases = watcher(CannedGitHub(json: Self.release), install: .homebrew, installer: FakeInstaller(onDisk: "0.3.0", installs: "0.4.0"))
        let environment = try UITestEnvironment(auth: .none, options: { $0.releases = releases })
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        browser.origin = base.absoluteString
        // Nothing to install before a check has found the release.
        #expect(try await browser.send("POST", "/api/updates/install", body: "{}").status == 409)
        let checked = try await browser.send("POST", "/api/updates/check", body: "{}")
        #expect(checked.json?["canInstall"] == true)
        let started = try await browser.send("POST", "/api/updates/install", body: #"{"relaunch": false}"#)
        #expect(started.status == 200)
        #expect(await eventually { (try? await browser.send("GET", "/api/updates").json?["installed"]?.stringValue) == "0.4.0" })
        let after = try await browser.send("GET", "/api/updates")
        #expect(after.json?["canInstall"] == false)
        #expect(after.json?["installing"] == nil)
        #expect(after.json?["relaunching"] == nil)
        #expect(releases.options.installer?.executable == "/opt/homebrew/opt/homeswift/bin/homeswift")
    }

    @Test func theSwitchWritesCheckForUpdates() async throws {
        let releases = watcher(CannedGitHub(json: Self.release), install: .source)
        let environment = try UITestEnvironment(auth: .none, options: { $0.releases = releases })
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        browser.origin = base.absoluteString
        let block = { try JSONValue(data: Data(contentsOf: environment.configURL))["platforms"]?[1] }
        let off = try await browser.put("/api/updates/automatic", ["on": false])
        #expect(off.status == 200)
        #expect(off.json?["automatic"] == false)
        #expect(try block()?["checkForUpdates"] == false)
        let on = try await browser.put("/api/updates/automatic", ["on": true])
        #expect(on.json?["automatic"] == true)
        // On is the default: the key goes.
        #expect(try block()?["checkForUpdates"] == nil)
        #expect(try block()?["platform"] == "HomeswiftUI")
        releases.stop()
        #expect(try await browser.put("/api/updates/automatic", [:]).status == 400)
    }

    @Test func anInstallThatChangesNothingIsAFailure() async throws {
        let releases = watcher(CannedGitHub(json: Self.release), install: .homebrew, installer: FakeInstaller(onDisk: "0.3.0", installs: nil))
        await releases.check()
        #expect(releases.install())
        #expect(await eventually { releases.json()?["installError"] != nil })
        #expect(releases.json()?["installed"] == nil)
        #expect(releases.json()?["canInstall"] == true)
    }

    @Test func notesAnUpgradeMadeByHand() async throws {
        let releases = watcher(CannedGitHub(json: Self.release), install: .homebrew, installer: FakeInstaller(onDisk: "0.4.0", installs: nil))
        await releases.check()
        #expect(releases.json()?["installed"] == "0.4.0")
        #expect(releases.json()?["canInstall"] == false)
        // Where the bridge cannot upgrade itself, no install is offered.
        let docker = watcher(CannedGitHub(json: Self.release), install: .docker)
        await docker.check()
        #expect(docker.json()?["canInstall"] == false)
        #expect(!docker.install())
    }

    @Test func anOlderVersionOnDiskIsNoRelaunch() async throws {
        let releases = watcher(CannedGitHub(json: Self.release), install: .homebrew, installer: FakeInstaller(onDisk: "0.2.0", installs: nil))
        await releases.check()
        #expect(releases.json()?["installed"] == nil)
        #expect(releases.json()?["canInstall"] == true)
    }

    @Test func readsTheInstalledVersionFromTheCellar() async throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("brew-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        let bin = prefix.appendingPathComponent("Cellar/homeswift/0.4.0_1/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // A link resolves only to a file that exists.
        FileManager.default.createFile(atPath: bin.appendingPathComponent("homeswift").path, contents: Data())
        let opt = prefix.appendingPathComponent("opt")
        try FileManager.default.createDirectory(at: opt, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: opt.appendingPathComponent("homeswift").path, withDestinationPath: "../Cellar/homeswift/0.4.0_1")
        let installer = try #require(HomebrewInstaller(executable: bin.appendingPathComponent("homeswift").path))
        #expect(await installer.installedVersion() == "0.4.0")
    }

    @Test func findsHomebrewFromTheCellar() {
        #expect(HomebrewInstaller(executable: "/opt/homebrew/Cellar/homeswift/0.3.0/bin/homeswift")?.prefix == "/opt/homebrew")
        #expect(HomebrewInstaller(executable: "/home/linuxbrew/.linuxbrew/Cellar/homeswift/0.3.0/bin/homeswift")?.executable == "/home/linuxbrew/.linuxbrew/opt/homeswift/bin/homeswift")
        #expect(HomebrewInstaller(executable: "/usr/local/bin/homeswift-nowhere") == nil)
    }

    @Test func manualCheckFetchesFreshReleaseWithoutStartingWatcher() async throws {
        let github = CannedGitHub(json: Self.release)
        let releases = watcher(github, install: .source)
        let environment = try UITestEnvironment(auth: .none, options: { $0.releases = releases })
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        browser.origin = base.absoluteString
        let result = try await browser.send("POST", "/api/updates/check", body: "{}")
        #expect(result.status == 200)
        #expect(result.json?["latest"]?.stringValue == "0.4.0")
        #expect(result.json?["available"]?.boolValue == true)
        #expect(github.requests.withLockedValue { $0.count } == 1)
        github.reply.withLockedValue { $0 = HomeswiftNetwork.HTTPResponse(status: 503, body: Data()) }
        let failed = try await browser.send("POST", "/api/updates/check", body: "{}")
        #expect(failed.json?["error"]?.stringValue != nil)
        #expect(github.requests.withLockedValue { $0.count } == 2)
    }

    static let release = """
        {
          "tag_name": "v0.4.0", "html_url": "https://github.com/mp-consulting/homeswift/releases/tag/v0.4.0",
          "published_at": "2026-11-02T10:00:00Z", "body": "### Added\\n- Update notices",
          "assets": [
            { "name": "homeswift-aarch64-0.4.0-1.spk", "browser_download_url": "https://example.com/aarch64.spk" },
            { "name": "homeswift-x86_64-0.4.0-1.spk", "browser_download_url": "https://example.com/x86_64.spk" }
          ]
        }
        """

    func watcher(_ github: CannedGitHub, current: String = "0.3.0", install: ReleaseWatcher.Install, architecture: String = "x86_64", installer: (any UpdateInstalling)? = nil) -> ReleaseWatcher {
        var options = ReleaseWatcher.Options()
        options.current = current
        options.install = install
        options.architecture = architecture
        options.installer = installer
        return ReleaseWatcher(transport: github, options: options)
    }

    @Test func comparesVersionsPartByPart() {
        #expect(ReleaseWatcher.isNewer("0.10.0", than: "0.9.2"))
        #expect(ReleaseWatcher.isNewer("1.0", than: "0.9.9"))
        #expect(ReleaseWatcher.isNewer("0.3.1", than: "0.3.0-2"))
        #expect(!ReleaseWatcher.isNewer("0.3.0", than: "0.3.0"))
        #expect(!ReleaseWatcher.isNewer("0.3.0-2", than: "0.3.0"))
        #expect(!ReleaseWatcher.isNewer("0.2.9", than: "0.3.0"))
    }

    @Test func offersTheNASItsPackage() async throws {
        let github = CannedGitHub(json: Self.release)
        let releases = watcher(github, install: .synology)
        #expect(releases.json() == nil)
        await releases.check()
        let update = try #require(releases.json())
        #expect(update["available"] == true)
        #expect(update["latest"] == "0.4.0")
        #expect(update["current"] == "0.3.0")
        #expect(update["download"]?["name"] == "homeswift-x86_64-0.4.0-1.spk")
        #expect(update["download"]?["url"] == "https://example.com/x86_64.spk")
        #expect(update["notes"]?.stringValue?.contains("Update notices") == true)
        let request = try #require(github.requests.withLockedValue { $0.first })
        #expect(request.url.absoluteString == "https://api.github.com/repos/mp-consulting/homeswift/releases/latest")
        #expect(request.header("User-Agent") == "Homeswift/0.3.0")
    }

    @Test func givesEachInstallItsWay() async throws {
        let docker = watcher(CannedGitHub(json: Self.release), install: .docker)
        await docker.check()
        #expect(docker.json()?["command"] == "docker pull ghcr.io/mp-consulting/homeswift:0.4.0")
        #expect(docker.json()?["download"] == nil)

        let brew = watcher(CannedGitHub(json: Self.release), install: .homebrew)
        await brew.check()
        #expect(brew.json()?["command"] == "brew upgrade homeswift")
    }

    @Test func saysNothingWhenUpToDate() async throws {
        let releases = watcher(CannedGitHub(json: Self.release), current: "0.4.0", install: .synology)
        await releases.check()
        let update = try #require(releases.json())
        #expect(update["available"] == false)
        #expect(update["download"] == nil)
        #expect(update["how"] == nil)
    }

    @Test func keepsTheLastAnswerWhenGitHubFails() async throws {
        let github = CannedGitHub(json: Self.release)
        let releases = watcher(github, install: .source)
        await releases.check()
        github.reply.withLockedValue { $0 = HomeswiftNetwork.HTTPResponse(status: 503) }
        await releases.check()
        let update = try #require(releases.json())
        #expect(update["available"] == true)
        #expect(update["error"] == "GitHub answered HTTP 503")
    }

    @Test func noReleaseYetIsNotAnError() async throws {
        let releases = watcher(CannedGitHub(status: 404, json: #"{"message": "Not Found"}"#), install: .source)
        await releases.check()
        let update = try #require(releases.json())
        #expect(update["available"] == false)
        #expect(update["error"] == nil)
    }

    @Test func detectsTheInstall() {
        #expect(ReleaseWatcher.Install.detect(environment: ["HOMESWIFT_INSTALL": "docker"], executable: "", fileExists: { _ in false }) == .docker)
        #expect(ReleaseWatcher.Install.detect(environment: [:], executable: "", fileExists: { $0 == "/var/packages/homeswift/INFO" }) == .synology)
        #expect(ReleaseWatcher.Install.detect(environment: [:], executable: "/opt/homebrew/Cellar/homeswift/0.3.0/bin/homeswift", fileExists: { _ in false }) == .homebrew)
        #expect(ReleaseWatcher.Install.detect(environment: [:], executable: "/usr/local/bin/homeswift", fileExists: { _ in false }) == .source)
    }

    @Test func turnsOffInConfig() throws {
        #expect(try UIConfiguration(block: ["platform": "HomeswiftUI"]).checkForUpdates)
        #expect(try !UIConfiguration(block: ["platform": "HomeswiftUI", "checkForUpdates": false]).checkForUpdates)
        #expect(throws: UIConfigurationError.invalid(key: "checkForUpdates", expected: "true or false")) {
            try UIConfiguration(block: ["platform": "HomeswiftUI", "checkForUpdates": "yes"])
        }
    }
}
