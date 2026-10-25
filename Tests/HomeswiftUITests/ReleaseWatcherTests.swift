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

@Suite struct ReleaseWatcherTests {
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

    func watcher(_ github: CannedGitHub, current: String = "0.3.0", install: ReleaseWatcher.Install, architecture: String = "x86_64") -> ReleaseWatcher {
        var options = ReleaseWatcher.Options()
        options.current = current
        options.install = install
        options.architecture = architecture
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
