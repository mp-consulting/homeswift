import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import HomeswiftUI

/// What keeps the web UI's server from being worn down or outlived: body limits before sign-in, idle connections,
/// event streams that end with their session, one password check per address, and the files kept in order.
@Suite(.timeLimit(.minutes(1)))
struct HardeningTests {
    func signedIn(_ environment: UITestEnvironment) async throws -> (URL, Browser) {
        let base = try await environment.start()
        let browser = Browser(base: base)
        browser.origin = "http://127.0.0.1:\(environment.server.port!)"
        let code = try #require(environment.server.setupCode)
        #expect(try await browser.post("/api/auth/setup", ["username": "rosaly", "password": "correct horse battery", "setupCode": .string(code)]).status == 200)
        return (base, browser)
    }

    /// Waits for `condition`, ten seconds at most.
    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Reads an event stream until it ends; its event names. `opened` turns true at the first event.
    func events(_ base: URL, cookie: String?, opened: NIOLockedValueBox<Bool>? = nil) async throws -> [String] {
        let http = try await URLSessionTransport(timeout: 30).stream(HTTPRequest(method: "GET", url: base.appendingPathComponent("/api/events"), headers: ["Cookie": cookie ?? "", "Accept": "text/event-stream"]))
        #expect(http.status == 200)
        var names: [String] = []
        for try await event in SSE.events(http.body) {
            names.append(event.event ?? "")
            opened?.withLockedValue { $0 = true }
        }
        return names
    }

    @Test func keepsOnlySmallBodiesBeforeSignIn() async throws {
        let environment = try UITestEnvironment()
        let (base, admin) = try await signedIn(environment)
        defer { Task { await environment.stop() } }
        let padding = String(repeating: "a", count: 100_000)
        let anonymous = Browser(base: base)
        anonymous.origin = admin.origin
        let refused = try await anonymous.send("POST", "/api/auth/login", body: #"{"username":"rosaly","password":"\#(padding)"}"#)
        #expect(refused.status == 413)
        // Signed in, the same size reaches the route, which says what is wrong with it.
        #expect(try await admin.put("/api/preferences", ["theme": "dark", "padding": .string(padding)]).status == 400)
    }

    @Test func closesConnectionsThatStaySilent() async throws {
        let environment = try UITestEnvironment(auth: .none) { $0.idleTimeout = .milliseconds(300) }
        _ = try await environment.start()
        defer { Task { await environment.stop() } }
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connect(host: "127.0.0.1", port: environment.server.port!).get()
        let started = ContinuousClock.now
        // Half a request, then nothing. On a loaded runner the server may close the connection, silent until now, before
        // the write goes out: that is the closing under test too.
        do {
            try await channel.writeAndFlush(ByteBuffer(string: "GET /api/status HTTP/1.1\r\nHost: 127.0.0.1\r\n")).get()
        } catch where !channel.isActive {}
        try await channel.closeFuture.get()
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func endsEventStreamsWithTheirSession() async throws {
        let environment = try UITestEnvironment { $0.keepalive = .milliseconds(100) }
        let (base, admin) = try await signedIn(environment)
        defer { Task { await environment.stop() } }
        let opened = NIOLockedValueBox(false)
        let stream = Task { try await events(base, cookie: admin.cookie, opened: opened) }
        try await waitUntil { opened.withLockedValue { $0 } }
        #expect(try await admin.post("/api/auth/logout", [:]).status == 200)
        #expect(try await stream.value.first == "hello")

        // An administrator made a user ends their stream, which carries the log: the page asks again, without it.
        let again = Browser(base: base)
        again.origin = admin.origin
        #expect(try await again.post("/api/auth/login", ["username": "rosaly", "password": "correct horse battery"]).status == 200)
        #expect(try await again.post("/api/users", ["username": "milo", "password": "battery staple lamp", "admin": true]).status == 201)
        let milo = Browser(base: base)
        milo.origin = admin.origin
        #expect(try await milo.post("/api/auth/login", ["username": "milo", "password": "battery staple lamp"]).status == 200)
        let miloOpened = NIOLockedValueBox(false)
        let demoted = Task { try await events(base, cookie: milo.cookie, opened: miloOpened) }
        try await waitUntil { miloOpened.withLockedValue { $0 } }
        #expect(try await again.put("/api/users/milo", ["admin": false]).status == 200)
        _ = try await demoted.value
        // Still signed in, as a user: a new stream is theirs.
        #expect(try await milo.get("/api/status").status == 200)
    }

    @Test func forgetsWhatARemovedUserKept() async throws {
        let environment = try UITestEnvironment()
        let (base, admin) = try await signedIn(environment)
        defer { Task { await environment.stop() } }
        #expect(try await admin.post("/api/users", ["username": "milo", "password": "battery staple lamp"]).status == 201)
        let milo = Browser(base: base)
        milo.origin = admin.origin
        #expect(try await milo.post("/api/auth/login", ["username": "milo", "password": "battery staple lamp"]).status == 200)
        #expect(try await milo.put("/api/preferences", ["theme": "dark"]).status == 200)
        let record = ChatRecord(id: "c1", created: Date(), updated: Date(), messages: [], items: [["kind": "user", "text": "where is my lamp"]])
        environment.server.chat.store?.update("milo") { $0.file(record) }

        #expect(try await admin.send("DELETE", "/api/users/milo").status == 200)
        #expect(environment.server.chat.store?.chats(of: "milo").recent.isEmpty == true)
        #expect(!(try String(contentsOf: environment.directory.appendingPathComponent("ui-chats.json"), encoding: .utf8).contains("where is my lamp")))
        // A new account by the same name starts afresh.
        #expect(try await admin.post("/api/users", ["username": "milo", "password": "battery staple lamp"]).status == 201)
        #expect(try await milo.post("/api/auth/login", ["username": "milo", "password": "battery staple lamp"]).status == 200)
        #expect(try await milo.get("/api/preferences").json?["theme"] == "auto")
    }

    @Test func letsAnAdministratorsTokenEmptyTheLog() async throws {
        let environment = try UITestEnvironment()
        let (base, admin) = try await signedIn(environment)
        defer { Task { await environment.stop() } }
        let token = try #require(try await admin.post("/api/tokens", ["name": "Ops", "scope": "admin"]).json?["token"]?.stringValue)
        let script = Browser(base: base)
        #expect(try await script.send("POST", "/api/logs/truncate", body: "{}", headers: ["Authorization": "Bearer \(token)"]).status == 200)
    }

    @Test func checksOnePasswordAtATimePerAddress() {
        let checks = CredentialChecks()
        #expect(checks.begin("192.0.2.1"))
        #expect(!checks.begin("192.0.2.1"))
        #expect(checks.begin("192.0.2.2"))
        checks.end("192.0.2.1")
        #expect(checks.begin("192.0.2.1"))
    }

    @Test func writesOnlyTheNewestSnapshot() throws {
        let writer = SnapshotWriter()
        var written: [UInt64] = []
        writer.write(2) { written.append(2) }
        writer.write(1) { written.append(1) }
        writer.write(3) { written.append(3) }
        #expect(written == [2, 3])
    }

    @Test func keepsRevokedSessionsRevokedAcrossRestarts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-sessions-\(UUID().uuidString).json")
        let sessions = SessionStore(lifetime: 60, url: url)
        let token = sessions.create(username: "rosaly")
        // A lookup that is not the user's own activity does not move the expiry.
        #expect(sessions.username(for: token, refresh: false) == "rosaly")
        sessions.revoke(token)
        #expect(SessionStore(lifetime: 60, url: url).username(for: token) == nil)
    }

    @Test func takesOneSnapshotAtATimePerCamera() async throws {
        let snapshots = CameraSnapshots()
        let calls = NIOLockedValueBox(0)
        let make: @Sendable () async throws -> Data = {
            calls.withLockedValue { $0 += 1 }
            try await Task.sleep(for: .milliseconds(200))
            return Data([1, 2, 3])
        }
        async let first = snapshots.take("Cams:door", make)
        try await Task.sleep(for: .milliseconds(50))
        async let second = snapshots.take("Cams:door", make)
        let (a, b) = try await (first, second)
        #expect(a == b && calls.withLockedValue { $0 } == 1)
        // Once it is done, the next one is taken afresh.
        _ = try await snapshots.take("Cams:door", make)
        #expect(calls.withLockedValue { $0 } == 2)
    }

    @Test func refusesAReleaseWithAnOddTagOrAddress() throws {
        let good: JSONValue = ["tag_name": "v0.4.0", "html_url": "https://github.com/mp-consulting/homeswift/releases/tag/v0.4.0"]
        #expect(try ReleaseWatcher.release(from: good).version == "0.4.0")
        #expect(throws: (any Error).self) { try ReleaseWatcher.release(from: ["tag_name": "v1;curl x|sh", "html_url": "https://github.com/x"]) }
        #expect(throws: (any Error).self) { try ReleaseWatcher.release(from: ["tag_name": "v1.0.0", "html_url": "javascript:alert(1)"]) }
        let assets: JSONValue = ["tag_name": "v1.0.0", "html_url": "https://github.com/x", "assets": [["name": "a.spk", "browser_download_url": "http://evil/a.spk"]]]
        #expect(try ReleaseWatcher.release(from: assets).assets.isEmpty)
    }
}
