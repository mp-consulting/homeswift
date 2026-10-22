import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftElgatoKeyLights
import HomeswiftMCP
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import HomeswiftUI

let testLogger: Logger = {
    var logger = Logger(label: "homeswift.ui")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// A plugin with a lamp and a lock.
actor LampPlugin: HomeswiftPlugin {
    struct Configuration: Decodable, Sendable { var name: String? }
    static let platform = "Lamps"
    static let name = "Lamps Plugin"
    let context: PluginContext
    let writes: NIOLockedValueBox<[(String, HAPValue)]>

    init(configuration: Configuration, context: PluginContext) { self.init(context: context, writes: NIOLockedValueBox([])) }
    init(context: PluginContext, writes: NIOLockedValueBox<[(String, HAPValue)]>) {
        self.context = context
        self.writes = writes
    }

    func start() async throws {
        let writes = self.writes
        let lightbulb = Service(.lightbulb, name: "Desk Lamp", optional: [.brightness], isPrimary: true)
        lightbulb.characteristic(.brightness).value = .int(40)
        lightbulb.characteristic(.brightness).onWrite { value in writes.withLockedValue { $0.append(("brightness", value)) } }
        try context.add(Accessory(id: "Lamps:lamp", name: "Desk Lamp", manufacturer: "Acme", model: "L1", category: .lightbulb, services: [lightbulb], onIdentify: {
            writes.withLockedValue { $0.append(("identify", .bool(true))) }
        }))
        let lock = Service(.lockMechanism, name: "Front Door", isPrimary: true)
        lock.characteristic(.lockTargetState).onWrite { value in writes.withLockedValue { $0.append(("lock", value)) } }
        try context.add(Accessory(id: "Lamps:lock", name: "Front Door", category: .doorLock, services: [lock]))
    }

    static let webFiles: [String: WebFile] = [
        "index.html": WebFile(contentType: "text/html; charset=utf-8", body: "<!doctype html><title>Lamps</title><script src=\"/plugin.js\"></script>"),
    ]

    func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "hello"): return PluginWebResponse(["hello": .string(request.user), "name": .string(context.name), "q": .string(request.query["q"] ?? "")])
        case ("POST", "echo"): return PluginWebResponse(request.body, status: 201)
        default: return .error(404, "nothing at \(request.path)")
        }
    }
}

final class UITestEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-ui-tests-\(UUID().uuidString)")
    let writes = NIOLockedValueBox<[(String, HAPValue)]>([])
    let restarts = NIOLockedValueBox(0)
    let logs = LogBuffer()
    let host: PluginHost
    let server: UIServer
    var configURL: URL { directory.appendingPathComponent("config.json") }

    init(auth: UIConfiguration.AuthMode = .form, webRoot: URL? = nil, https: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = """
            {
              "bridge": { "name": "UI Bridge", "username": "0E:11:22:33:44:66", "pin": "031-45-154", "port": 0 },
              "platforms": [
                { "platform": "Lamps", "name": "Lamps" },
                { "platform": "HomeswiftUI", "port": 0 }
              ]
            }
            """
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        var registry = PluginRegistry()
        let writes = self.writes
        registry.register(platform: LampPlugin.platform, name: LampPlugin.name, webFiles: LampPlugin.webFiles) { _, context in LampPlugin(context: context, writes: writes) }
        registry.register(ElgatoKeyLightsPlugin.self)
        var options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        options.systemPlatforms.insert(UIConfiguration.platform)
        host = try PluginHost(configuration: try HomeswiftConfiguration.decode(Data(config.utf8)), registry: registry, storageDirectory: directory, options: options)
        let restarts = self.restarts
        let catalog = HomeswiftCatalog(host: host, logs: logs, configURL: directory.appendingPathComponent("config.json"), restart: { restarts.withLockedValue { $0 += 1 } }, logger: testLogger)
        var configuration = UIConfiguration()
        configuration.host = "127.0.0.1"
        configuration.port = 0
        configuration.auth = auth
        configuration.https = https
        var serverOptions = UIServer.Options()
        serverOptions.hashIterations = 1000
        serverOptions.logger = testLogger
        serverOptions.webRoot = webRoot
        server = UIServer(configuration: configuration, catalog: catalog, usersURL: directory.appendingPathComponent("ui-users.json"), options: serverOptions)
    }

    func start() async throws -> URL {
        try await host.start()
        try await server.start()
        return URL(string: "\(server.configuration.scheme)://127.0.0.1:\(server.port!)")!
    }

    func stop() async {
        await server.stop()
        await host.stop()
    }
}

/// An HTTP client for the tests that keeps the session cookie itself: its URLSession stores none, so a
/// second client is anonymous on Linux too, where the shared session keeps cookies whatever the request says.
final class Browser: @unchecked Sendable {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    let base: URL
    var cookie: String?
    var origin: String?
    var contentType = "application/json"

    init(base: URL) { self.base = base }

    struct Response {
        var status: Int
        var headers: [String: String]
        var body: String
        var json: JSONValue? { try? JSONValue(string: body) }
    }

    func send(_ method: String, _ path: String, body: String? = nil) async throws -> Response {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL, timeoutInterval: 30)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        request.httpShouldHandleCookies = false
        let (data, response) = try await Self.session.data(for: request)
        let http = response as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields { headers[String(describing: name).lowercased()] = String(describing: value) }
        if let set = headers["set-cookie"] {
            let pair = set.split(separator: ";")[0]
            cookie = pair.hasSuffix("=") ? nil : String(pair)
        }
        return Response(status: http.statusCode, headers: headers, body: String(decoding: data, as: UTF8.self))
    }

    func get(_ path: String) async throws -> Response { try await send("GET", path) }
    func post(_ path: String, _ json: JSONValue) async throws -> Response { try await send("POST", path, body: json.text()) }
    func put(_ path: String, _ json: JSONValue) async throws -> Response { try await send("PUT", path, body: json.text()) }
}

@Suite struct AuthTests {
    @Test func storesUsersAndVerifiesPasswords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-ui-users-\(UUID().uuidString).json")
        let store = UserStore(url: url, iterations: 1000)
        #expect(store.isEmpty)
        try store.createFirst(username: "rosaly", password: "correct horse battery")
        #expect(throws: AuthError.setupDone) { try store.createFirst(username: "other", password: "a different strong pass") }
        #expect { try store.create(username: "xyz", password: "short") } throws: { ($0 as? AuthError)?.description.contains("at least 12 characters") == true }
        #expect(throws: AuthError.userExists) { try store.create(username: "Rosaly", password: "another strong one") }
        #expect(throws: AuthError.invalidUsername) { try store.create(username: "a b", password: "another strong one") }
        #expect(store.verify(username: "rosaly", password: "correct horse battery"))
        #expect(store.verify(username: "ROSALY", password: "correct horse battery"))
        #expect(!store.verify(username: "rosaly", password: "wrong horse"))
        #expect(!store.verify(username: "nobody", password: "correct horse battery"))
        let reloaded = UserStore(url: url, iterations: 1000)
        #expect(reloaded.usernames == ["rosaly"])
        #expect(reloaded.verify(username: "rosaly", password: "correct horse battery"))
        #expect(UserStore.pbkdf2(password: "password", salt: Data("salt".utf8), iterations: 1).map { String(format: "%02x", $0) }.joined().hasPrefix("120fb6cffcf8b32c"))
        // The usual PBKDF2-HMAC-SHA256 vector (password, salt, 4096 rounds), through the platform's code and the portable loop.
        let expected = "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"
        #expect(UserStore.pbkdf2(password: "password", salt: Data("salt".utf8), iterations: 4096).map { String(format: "%02x", $0) }.joined() == expected)
        #expect(UserStore.portablePBKDF2(password: "password", salt: Data("salt".utf8), iterations: 4096).map { String(format: "%02x", $0) }.joined() == expected)

        let sessionsURL = url.deletingLastPathComponent().appendingPathComponent("homeswift-ui-sessions-\(UUID().uuidString).json")
        let sessions = SessionStore(lifetime: 60, url: sessionsURL)
        let token = sessions.create(username: "rosaly")
        #expect(sessions.username(for: token) == "rosaly")
        #expect(sessions.username(for: "nope") == nil)
        #expect(SessionStore(lifetime: 60, url: sessionsURL).username(for: token) == "rosaly")   // survives a restart
        #expect(try !String(contentsOf: sessionsURL, encoding: .utf8).contains(token))   // as a hash, not the cookie
        sessions.revoke(token)
        #expect(sessions.username(for: token) == nil)
        #expect(SessionStore(lifetime: 60, url: sessionsURL).username(for: token) == nil)
        // A session whose user is gone ends at use, and is not loaded; a loaded expiry is capped at the lifetime.
        let only = SessionStore(lifetime: 60, url: sessionsURL, isKnownUser: { $0 == "rosaly" })
        let kept = only.create(username: "rosaly")
        let gone = only.create(username: "gone")
        #expect(only.username(for: gone) == nil)
        #expect(only.username(for: kept) == "rosaly")
        #expect(only.count == 1)
        #expect(SessionStore(lifetime: 60, url: sessionsURL, isKnownUser: { _ in false }).count == 0)
        #expect(SessionStore(lifetime: 0, url: sessionsURL).count == 0)
    }

    @Test func readsTheBlock() throws {
        let configuration = try UIConfiguration(block: ["platform": "HomeswiftUI", "port": 9001, "host": "127.0.0.1", "auth": "none", "sessionDays": 2])
        #expect(configuration.port == 9001)
        #expect(configuration.host == "127.0.0.1")
        #expect(configuration.auth == .none)
        #expect(configuration.sessionDays == 2)
        #expect(UIConfiguration().port == 8581)
        #expect(UIConfiguration().auth == .form)
        #expect(throws: UIConfigurationError.self) { try UIConfiguration(block: ["auth": "magic"]) }
        #expect(throws: UIConfigurationError.self) { try UIConfiguration(block: ["port": 0]) }
        #expect(throws: UIConfigurationError.self) { try UIConfiguration(block: ["allowedHosts": "bridge.example.com"]) }
    }

    @Test func answersOnlyToItsOwnNames() throws {
        let named = try UIConfiguration(block: ["allowedHosts": ["Bridge.Example.com", " proxy.lan "]])
        #expect(named.allowedHosts == ["bridge.example.com", "proxy.lan"])
        #expect(UIServer.allowedHosts(for: named).isSuperset(of: ["localhost", "bridge.example.com", "proxy.lan"]))
        var bound = UIConfiguration()
        bound.host = "bridge.home"
        #expect(UIServer.allowedHosts(for: bound).contains("bridge.home"))
        #expect(HostName.of("[::1]:8581") == "::1")
        #expect(HostName.of("Mac-Mini.local.:8581") == "mac-mini.local")
        #expect(HostName.of("192.168.1.10") == "192.168.1.10")
        #expect(HostName.port(of: "[::1]:8581") == 8581)
        #expect(HostName.port(of: "mac-mini.local:8581") == 8581)
        #expect(HostName.port(of: "::1") == nil)
        #expect(HostName.port(of: "mac-mini.local") == nil)
        #expect(HostName.isIPAddress("192.168.1.10"))
        #expect(HostName.isIPAddress("fe80::1%en0"))
        #expect(!HostName.isIPAddress("evil.example"))
        #expect(!HostName.isIPAddress("300.1.1.1"))
        #expect(UIServer.makeSetupCode().count == 9)
        #expect(UIServer.setupCodeMatches("ab cd-efgh", "ABCD-EFGH"))
        #expect(!UIServer.setupCodeMatches("ABCD-EFGJ", "ABCD-EFGH"))
    }
}

@Suite struct PasswordPolicyTests {
    @Test func followsTheANSSIBands() {
        // 12 lower-case letters and spaces: 12 × log2(59) ≈ 70.6 bits, the "low to medium" band, under the bar.
        let medium = PasswordPolicy.evaluate("orange plane")
        #expect(medium.level == .lowToMedium && !medium.isAcceptable)
        #expect((medium.bits - 12 * log2(59)).magnitude < 0.01)
        // A passphrase of random words passes, a long one is strong.
        #expect(PasswordPolicy.evaluate("battery staple lamp").isAcceptable)
        // 14 such characters, ≈ 82 bits: above the CNIL's 80, under the guide's 85.
        #expect(!PasswordPolicy.evaluate("battery staple").isAcceptable)
        #expect(PasswordPolicy.evaluate("correct horse battery staple").level == .strongToVeryStrong)
        #expect(PasswordPolicy.evaluate("k7#Qm2!vXp9&Lw").level == .mediumToStrong)
        #expect(PasswordPolicy.evaluate("Tr0ub4dor&3").problems.first == "use at least 12 characters")
    }

    @Test func givesNothingForWhatPeopleType() {
        // Repeats and runs count once, common words and the username as one character.
        #expect(PasswordPolicy.evaluate("aaaaaaaaaaaaaaaaaaaaaaaa").level == .veryWeak)
        #expect(PasswordPolicy.evaluate("abcdefghijklmnopqrstuvwx").level == .veryWeak)
        #expect(!PasswordPolicy.evaluate("Password123456!").isAcceptable)
        #expect(!PasswordPolicy.evaluate("rosalyrosaly42!", username: "rosaly").isAcceptable)
        #expect(PasswordPolicy.evaluate("rosalyrosaly42!").bits > PasswordPolicy.evaluate("rosalyrosaly42!", username: "rosaly").bits)
        #expect(PasswordPolicy.evaluate("homeswift2026!").problems.contains { $0.contains("common words") })
        #expect(PasswordPolicy.evaluate(String(repeating: "x", count: 2000)).problems.contains("use at most 1024 bytes"))
    }
}

@Suite struct LiveWebFilesTests {
    /// A checkout with the UI's Web folder and one plugin's.
    func checkout() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-live-\(UUID().uuidString)")
        for (path, text) in [("Sources/HomeswiftUI/Web/style.css", "body { color: red; }"), ("Plugins/Lamps/Web/app.js", "// lamps"), ("secret.txt", "no")] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    @Test func readsFilesFromTheCheckoutAndStaysInIt() throws {
        let live = LiveWebFiles(root: try checkout())
        #expect(live.file("style.css", platform: nil) == WebFile(contentType: "text/css; charset=utf-8", body: "body { color: red; }"))
        #expect(live.file("app.js", platform: "Lamps")?.body == "// lamps")
        #expect(live.file("../../../secret.txt", platform: nil) == nil)
        #expect(live.file("app.js", platform: "../Lamps") == nil)
        #expect(live.file(".hidden", platform: nil) == nil)
        #expect(Set(live.snapshot().keys) == ["Sources/HomeswiftUI/Web/style.css", "Plugins/Lamps/Web/app.js"])
    }

    @Test func servesTheCheckoutWithoutTrippingOnBarePaths() async throws {
        let root = try checkout()
        let environment = try UITestEnvironment(auth: .none, webRoot: root)
        let base = try await environment.start()
        let browser = Browser(base: base)
        #expect(try await browser.get("/style.css").body == "body { color: red; }")
        // /plugins alone names no plugin: an answer, not a crash.
        #expect(try await browser.get("/plugins").status == 404)
        #expect(try await browser.get("/plugins/Lamps/app.js").body == "// lamps")
        await environment.server.stop()
    }

    @Test func reportsAChangedFile() async throws {
        let root = try checkout()
        let live = LiveWebFiles(root: root)
        let changes = NIOLockedValueBox<[String]>([])
        let watcher = live.watch(every: .milliseconds(50)) { path in changes.withLockedValue { $0.append(path) } }
        defer { watcher.cancel() }
        try await Task.sleep(for: .milliseconds(120))
        let url = root.appendingPathComponent("Plugins/Lamps/Web/app.js")
        try Data("// changed".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        let deadline = ContinuousClock.now + .seconds(3)
        while changes.withLockedValue({ $0.isEmpty }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(changes.withLockedValue { $0 } == ["Plugins/Lamps/Web/app.js"])
    }
}

@Suite struct EmbeddingTests {
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    @Test func pluginSchemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("Plugins/ElgatoKeyLights/config.schema.json"), encoding: .utf8)
        #expect(ElgatoKeyLightsPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(try JSONValue(string: ElgatoKeyLightsPlugin.configurationSchemaJSON!)["pluginAlias"] == "ElgatoKeyLights")
    }

    @Test func webFilesAreCurrent() throws {
        try Self.expectCurrent(WebAssets.files, from: "Sources/HomeswiftUI/Web", command: "web Sources/HomeswiftUI/Web Sources/HomeswiftUI/WebAssets.swift")
        try Self.expectCurrent(ElgatoKeyLightsPlugin.webFiles, from: "Plugins/ElgatoKeyLights/Web", command: "web Plugins/ElgatoKeyLights/Web Plugins/ElgatoKeyLights/Sources/WebFiles.swift ElgatoKeyLightsPlugin")
    }

    /// Every file of the directory is embedded as written, with its media type.
    static func expectCurrent(_ files: [String: WebFile], from directory: String, command: String) throws {
        let web = root.appendingPathComponent(directory)
        for name in try FileManager.default.contentsOfDirectory(atPath: web.path) where !name.hasPrefix(".") {
            let file = try String(contentsOf: web.appendingPathComponent(name), encoding: .utf8)
            #expect(files[name]?.body == file, "run: swift Scripts/embed-assets.swift \(command) (\(name))")
        }
        #expect(files["index.html"]?.contentType == "text/html; charset=utf-8")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct LogFilterTests {
    /// One accessory's lines, picked on the server, for the latest lines and for a time range.
    @Test func picksAnAccessorysLines() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        environment.logs.append(LogBuffer.Line(level: .info, label: "Lamps", text: "Desk Lamp turned on"))
        environment.logs.append(LogBuffer.Line(level: .info, label: "Lamps", text: "Front Door locked"))
        let browser = Browser(base: base)
        let latest = try await browser.get("/api/logs?accessory=Lamps:lamp").json?.arrayValue ?? []
        #expect(latest.map { $0["text"]?.stringValue ?? "" } == ["Desk Lamp turned on"])
        let from = Date().addingTimeInterval(-60).ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeSeparator(.colon).dateSeparator(.dash))
        let range = try await browser.get("/api/logs?from=\(from)Z&accessory=Lamps:lock").json?.arrayValue ?? []
        #expect(range.map { $0["text"]?.stringValue ?? "" } == ["Front Door locked"])
        #expect(try await browser.get("/api/logs").json?.arrayValue?.count ?? 0 >= 2)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct UIServerTests {
    @Test func servesPagesAndTheAPIBehindALogin() async throws {
        let environment = try UITestEnvironment()
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)

        let page = try await browser.get("/")
        #expect(page.status == 200)
        #expect(page.body.contains("<title>Homeswift</title>"))
        #expect(page.headers["content-security-policy"]?.contains("default-src 'self'") == true)
        #expect(page.headers["x-frame-options"] == "DENY")
        #expect(try await browser.get("/app.js").headers["content-type"]?.hasPrefix("text/javascript") == true)
        #expect(try await browser.get("/nope.html").status == 404)
        #expect(try await browser.get("/api/status").status == 401)

        // First visit: setup. Cross-site and non-JSON attempts are refused.
        let state = try await browser.get("/api/auth/state").json
        #expect(state?["setupNeeded"] == true)
        #expect(state?["authenticated"] == false)
        let code = try #require(environment.server.setupCode)
        #expect(code.count == 9)
        browser.origin = "http://evil.example"
        #expect(try await browser.post("/api/auth/setup", ["username": "rosaly", "password": "correct horse battery", "setupCode": .string(code)]).status == 403)
        browser.origin = "http://127.0.0.1:\(environment.server.port!)"
        browser.contentType = "text/plain"
        #expect(try await browser.post("/api/auth/setup", ["username": "rosaly", "password": "correct horse battery", "setupCode": .string(code)]).status == 415)
        browser.contentType = "application/json"
        // The set-up code from the bridge's output is required; its case and dashes are not.
        #expect(try await browser.post("/api/auth/setup", ["username": "rosaly", "password": "correct horse battery"]).status == 403)
        #expect(try await browser.post("/api/auth/setup", ["username": "rosaly", "password": "correct horse battery", "setupCode": "NOPE-NOPE"]).status == 403)
        #expect(try await browser.post("/api/auth/setup", ["username": "rosaly", "password": "short", "setupCode": .string(code)]).status == 400)
        #expect(environment.server.users.isEmpty)
        let typed = code.lowercased().replacingOccurrences(of: "-", with: " ")
        let created = try await browser.post("/api/auth/setup", ["username": "rosaly", "password": "correct horse battery", "setupCode": .string(typed)])
        #expect(created.status == 200)
        #expect(browser.cookie?.hasPrefix("homeswift_session=") == true)
        #expect(created.headers["set-cookie"]?.contains("HttpOnly") == true)
        #expect(created.headers["set-cookie"]?.contains("SameSite=Strict") == true)
        #expect(try await browser.post("/api/auth/setup", ["username": "again", "password": "correct horse battery", "setupCode": .string(code)]).status == 409)

        // Only the server's own names are answered: a page whose name is rebound to this address gets nothing.
        let port = environment.server.port!
        #expect(environment.server.isAllowedHost("127.0.0.1:\(port)"))
        #expect(environment.server.isAllowedHost("[::1]:\(port)"))
        #expect(environment.server.isAllowedHost("localhost:\(port)"))
        if !HomeswiftCatalog.machineName().isEmpty { #expect(environment.server.isAllowedHost(HomeswiftCatalog.machineName())) }
        #expect(!environment.server.isAllowedHost("evil.example:\(port)"))
        #expect(!environment.server.isAllowedHost(nil))

        // Changing the password: the current one first; the user's other browsers are signed out, this one stays.
        // A password past the size limit is refused without hashing it.
        #expect(!environment.server.users.verify(username: "rosaly", password: String(repeating: "x", count: 100_000)))
        let other = Browser(base: base)
        #expect(try await other.post("/api/auth/login", ["username": "rosaly", "password": "correct horse battery"]).status == 200)
        #expect(try await browser.post("/api/account/password", ["current": "wrong horse", "new": "battery staple lamp"]).status == 403)
        #expect(try await browser.post("/api/account/password", ["current": "correct horse battery", "new": "short"]).status == 400)
        #expect(try await browser.post("/api/account/password", ["current": "correct horse battery", "new": "battery staple lamp"]).status == 200)
        #expect(try await other.get("/api/status").status == 401)
        #expect(try await browser.get("/api/status").status == 200)
        #expect(environment.server.users.verify(username: "rosaly", password: "battery staple lamp"))
        #expect(try await Browser(base: base).post("/api/auth/login", ["username": "rosaly", "password": "correct horse battery"]).status == 401)

        // Status, accessories, control.
        // Without a HomeswiftAiKit block the pages offer no Explain, and asking for one says why.
        #expect(try await browser.get("/api/assistant").json?["enabled"] == false)
        #expect(try await browser.post("/api/assistant/explain", ["error": "boom"]).status == 404)
        let status = try await browser.get("/api/status").json
        #expect(status?["bridges"]?[0]?["deviceId"] == "0E:11:22:33:44:66")
        #expect(status?["bridges"]?[0]?["setupCode"] == "0314-5154")
        #expect(status?["restartNeeded"] == false)
        #expect(status?["username"] == "rosaly")
        let accessories = try await browser.get("/api/accessories").json?.arrayValue ?? []
        #expect(accessories.map { $0["id"] } == ["Lamps:lamp", "Lamps:lock"])
        #expect(accessories[0]["services"]?[0]?["characteristics"]?.arrayValue?.contains { $0["type"] == "Brightness" && $0["value"] == 40 } == true)
        let written = try await browser.put("/api/accessories/Lamps:lamp", ["characteristic": "Brightness", "value": 60])
        #expect(written.status == 200)
        #expect(written.json?["value"] == 60)
        #expect(environment.writes.withLockedValue { $0 }.last?.1 == .int(60))
        #expect(try await browser.put("/api/accessories/Lamps:lock", ["characteristic": "Lock Target State", "value": 1]).status == 200)
        #expect(try await browser.put("/api/accessories/Lamps:lamp", ["characteristic": "Brightness", "value": 500]).status == 400)
        #expect(try await browser.put("/api/accessories/nope", ["characteristic": "On", "value": true]).status == 404)
        #expect(try await browser.post("/api/accessories/Lamps:lamp/identify", [:]).status == 200)
        #expect(environment.writes.withLockedValue { $0 }.contains { $0.0 == "identify" })

        // Plugins, schemas, config.
        let plugins = try await browser.get("/api/plugins").json
        #expect(plugins?["blocks"]?[0]?["platform"] == "Lamps")
        #expect(plugins?["blocks"]?[1]?["system"] == true)
        #expect(plugins?["plugins"]?.arrayValue?.contains { $0["platform"] == "ElgatoKeyLights" && $0["hasSchema"] == true } == true)
        let schema = try await browser.get("/api/plugins/ElgatoKeyLights/schema")
        #expect(schema.status == 200)

        // A plugin's own page and its API, for the signed-in user only.
        #expect(plugins?["plugins"]?.arrayValue?.contains { $0["platform"] == "Lamps" && $0["hasPages"] == true } == true)
        let pluginPage = try await browser.get("/plugins/Lamps/index.html")
        #expect(pluginPage.status == 200)
        #expect(pluginPage.body.contains("<title>Lamps</title>"))
        #expect(try await browser.get("/plugins/Lamps/missing.js").status == 404)
        #expect(try await browser.get("/plugins/Nope/index.html").status == 404)
        #expect(try await browser.get("/plugin.js").status == 200)
        let anonymous = Browser(base: base)
        let landed = try await anonymous.get("/plugins/Lamps/index.html")   // sent to the login page
        #expect(landed.status == 302 || landed.body.contains("<title>Homeswift</title>"))
        #expect(try await anonymous.get("/api/plugins/Lamps/Lamps/hello").status == 401)
        let hello = try await browser.get("/api/plugins/Lamps/Lamps/hello?q=1").json
        #expect(hello?["hello"] == "rosaly")
        #expect(hello?["name"] == "Lamps")
        #expect(hello?["q"] == "1")
        let echoed = try await browser.post("/api/plugins/Lamps/Lamps/echo", ["a": 1])
        #expect(echoed.status == 201)
        #expect(echoed.json?["a"] == 1)
        #expect(try await browser.get("/api/plugins/Lamps/Lamps/nothing").status == 404)
        #expect(try await browser.get("/api/plugins/Lamps/Other/hello").status == 404)

        // The pairing QR code, and a restart through the hook.
        let qr = try await browser.get("/api/qr/0.svg")
        #expect(qr.status == 200)
        #expect(qr.headers["content-type"]?.hasPrefix("image/svg+xml") == true)
        #expect(qr.body.hasPrefix("<svg "))
        #expect(try await browser.get("/api/qr/9.svg").status == 404)
        #expect(try await browser.post("/api/restart", [:]).status == 200)
        try await Task.sleep(for: .milliseconds(800))
        #expect(environment.restarts.withLockedValue { $0 } == 1)

        // A kept session of a user that no longer exists is worthless.
        let ghost = Browser(base: base)
        ghost.cookie = "homeswift_session=\(environment.server.sessions.create(username: "ghost"))"
        #expect(try await ghost.get("/api/status").status == 401)
        #expect(environment.server.sessions.count == 1)
        #expect(schema.json?["pluginAlias"] == "ElgatoKeyLights")
        #expect(try await browser.get("/api/plugins/Lamps/schema").status == 404)
        let config = try await browser.get("/api/config")
        #expect(config.json?["bridge"]?["pin"] == "031-45-154")

        let patched = try await browser.put("/api/config/platforms/0", ["platform": "Lamps", "name": "Lamps", "pollingRate": 5])
        #expect(patched.status == 200)
        #expect(patched.json?["changes"] == ["platforms[0].pollingRate"])
        #expect(try JSONValue(data: Data(contentsOf: environment.configURL))["platforms"]?[0]?["pollingRate"] == 5)
        // A plugin block applies in place: no restart.
        #expect(patched.json?["restartNeeded"] == [] && patched.json?["restarting"] == false)
        #expect(try await browser.get("/api/status").json?["restartNeeded"] == false)
        #expect(try await browser.put("/api/config/platforms/2", ["platform": "ElgatoKeyLights", "name": "Lights"]).status == 200)
        #expect(try await browser.put("/api/config/platforms/9", ["platform": "X"]).status == 404)
        #expect(try await browser.put("/api/config/platforms/0", ["name": "no platform"]).status == 400)
        #expect(try await browser.send("DELETE", "/api/config/platforms/2").status == 200)
        #expect(try JSONValue(data: Data(contentsOf: environment.configURL))["platforms"]?.arrayValue?.count == 2)
        #expect(try await browser.put("/api/config", ["bridge": ["pin": "111-11-111"]]).status == 400)
        #expect(try await browser.put("/api/config", (try JSONValue(data: Data(contentsOf: environment.configURL)))).status == 200)

        // Logs and events.
        environment.logs.append(.init(level: .warning, label: "Lamps", text: "Lamp not responding"))
        let logs = try await browser.get("/api/logs").json?.arrayValue ?? []
        #expect(logs.last?["text"] == "Lamp not responding")
        let streamTask = Task { () -> String in
            let http = try await URLSessionTransport(timeout: 10).stream(HTTPRequest(method: "GET", url: base.appendingPathComponent("/api/events"), headers: ["Cookie": browser.cookie ?? "", "Accept": "text/event-stream"]))
            #expect(http.status == 200)
            var text = ""
            for try await event in SSE.events(http.body) {
                text += "\(event.event ?? ""):\(event.data)\n"
                if event.event == "accessory" { break }
            }
            return text
        }
        try await Task.sleep(for: .milliseconds(300))
        environment.host.mainBridge.server.accessories[1].service(.lightbulb)?.characteristic(.on).value = .bool(true)
        let streamed = try await streamTask.value
        #expect(streamed.contains("accessory:"))
        #expect(streamed.contains("\"characteristic\":\"On\""))
        #expect(streamed.contains("\"id\":\"Lamps:lamp\""))

        // Login, wrong password, logout.
        let fresh = Browser(base: base)
        #expect(try await fresh.post("/api/auth/login", ["username": "rosaly", "password": "wrong horse"]).status == 401)
        #expect(try await fresh.post("/api/auth/login", ["username": "rosaly", "password": "battery staple lamp"]).status == 200)
        #expect(try await fresh.get("/api/status").status == 200)
        #expect(try await fresh.post("/api/auth/logout", [:]).status == 200)
        #expect(try await fresh.get("/api/status").status == 401)
    }

    @Test func needsNoLoginWhenConfigured() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        #expect(try await browser.get("/api/auth/state").json?["mode"] == "none")
        #expect(try await browser.get("/api/status").status == 200)
        #expect(try await browser.post("/api/auth/login", ["username": "x", "password": "y"]).status == 400)
    }
}
