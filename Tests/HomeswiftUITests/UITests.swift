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

/// A plugin with a lamp, a lock, and a strip with Adaptive Lighting.
actor LampPlugin: HomeswiftPlugin {
    struct Configuration: Decodable, Sendable { var name: String? }
    static let platform = "Lamps"
    static let name = "Lamps Plugin"
    let context: PluginContext
    let writes: NIOLockedValueBox<[(String, HAPValue)]>
    var adaptiveLighting: AdaptiveLightingController?

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
        let strip = Service(.lightbulb, name: "Strip", optional: [.brightness, .colorTemperature], isPrimary: true)
        adaptiveLighting = AdaptiveLightingController(strip, mode: .automatic)
        try context.add(Accessory(id: "Lamps:strip", name: "Strip", category: .lightbulb, services: [strip]))
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
    /// With `mcp`, the MCP server the UI serves at `/mcp` (never started: the UI hands it its requests).
    let mcpServer: MCPServer?
    var configURL: URL { directory.appendingPathComponent("config.json") }

    /// `assistant`: a HomeswiftAiKit block whose provider nothing answers for (it is never reached in the tests);
    /// `model`: one whose provider answers through this transport.
    init(auth: UIConfiguration.AuthMode = .form, webRoot: URL? = nil, https: Bool = false, metrics: Metrics? = nil, assistant: Bool = false,
         model: (any HTTPTransport)? = nil, mcp: MCPConfiguration? = nil, trustProxy: String? = nil, publicURL: String? = nil, options configure: (inout UIServer.Options) -> Void = { _ in }) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ai = assistant || model != nil ? #",{ "platform": "HomeswiftAiKit", "provider": "openai-compatible", "model": "llama3.1", "baseUrl": "http://127.0.0.1:9/v1", "maxRetries": 0 }"# : ""
        let config = """
            {
              "bridge": { "name": "UI Bridge", "username": "0E:11:22:33:44:66", "pin": "031-45-154", "port": 0 },
              "platforms": [
                { "platform": "Lamps", "name": "Lamps" },
                { "platform": "HomeswiftUI", "port": 0 }\(ai)
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
        options.aiTransport = model
        host = try PluginHost(configuration: try HomeswiftConfiguration.decode(Data(config.utf8)), registry: registry, storageDirectory: directory, options: options)
        let restarts = self.restarts
        let catalog = HomeswiftCatalog(
            host: host, logs: logs, metrics: metrics, configURL: directory.appendingPathComponent("config.json"), restart: { restarts.withLockedValue { $0 += 1 } }, logger: testLogger)
        var configuration = UIConfiguration()
        configuration.host = "127.0.0.1"
        configuration.port = 0
        configuration.auth = auth
        configuration.https = https
        configuration.publicURL = publicURL.flatMap(PublicURL.init)
        if let trustProxy { configuration.trustProxy = try UIConfiguration(block: ["trustProxy": .string(trustProxy)]).trustProxy }
        var serverOptions = UIServer.Options()
        serverOptions.hashIterations = 1000
        serverOptions.logger = testLogger
        serverOptions.webRoot = webRoot
        if let mcp {
            var mcpOptions = MCPServer.Options(version: "test")
            mcpOptions.logger = testLogger
            let mcpServer = MCPServer(options: mcpOptions, tools: catalog.tools, resources: catalog.resources, templates: catalog.templates, prompts: catalog.prompts)
            let transport = MCPHTTPServer(server: mcpServer, configuration: mcp)
            serverOptions.mcp = { transport }
            self.mcpServer = mcpServer
        } else {
            mcpServer = nil
        }
        configure(&serverOptions)
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

    func send(_ method: String, _ path: String, body: String? = nil, headers extra: [String: String] = [:]) async throws -> Response {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL, timeoutInterval: 30)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in extra { request.setValue(value, forHTTPHeaderField: name) }
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
        // /plugins alone is the Plugins view: the UI's page, not a crash.
        #expect(try await browser.get("/plugins").status == 200)
        #expect(try await browser.get("/plugins/lamps/app.js").body == "// lamps")
        await environment.server.stop()
    }

    /// Names as path segments, the same as common.js's `slug`.
    @Test func makesSlugs() {
        #expect(Slug.make("Dyson Pure Cool") == "dyson-pure-cool")
        #expect(Slug.make("  Café — Salon #2 ") == "cafe-salon-2")
        #expect(Slug.make("灯") == "")
        #expect(Slug.unique(["Lamps", "lamps", "灯", "Lamps"], fallback: "plugin") == ["lamps", "lamps-2", "plugin", "lamps-3"])
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
        let deadline = ContinuousClock.now + .seconds(30)
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

    @Test func artworkThemesCoverTheGallery() throws {
        let data = try #require(WebAssets.files["scene-artwork-themes.json"]?.data)
        let themes = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(themes.count == 28)
        var covered: Set<String> = []
        var names: Set<String> = []
        for theme in themes {
            let name = try #require(theme["name"] as? String)
            #expect(names.insert(name).inserted)
            let ids = try #require(theme["artworkIds"] as? [String])
            #expect(!ids.isEmpty && Set(ids).count == ids.count)
            for id in ids {
                #expect(WebAssets.files["artwork-\(id).webp"]?.contentType == "image/webp")
                covered.insert(id)
            }
        }
        #expect(covered.count == 143)
    }

    @Test func webFilesAreCurrent() throws {
        try Self.expectCurrent(WebAssets.files, from: "Sources/HomeswiftUI/Web", command: "web Sources/HomeswiftUI/Web Sources/HomeswiftUI/WebAssets.swift")
        try Self.expectCurrent(ElgatoKeyLightsPlugin.webFiles, from: "Plugins/ElgatoKeyLights/Web", command: "web Plugins/ElgatoKeyLights/Web Plugins/ElgatoKeyLights/Sources/WebFiles.swift ElgatoKeyLightsPlugin")
    }

    /// Every file of the directory is embedded as written, with its media type.
    static func expectCurrent(_ files: [String: WebFile], from directory: String, command: String) throws {
        let web = root.appendingPathComponent(directory)
        for name in try FileManager.default.contentsOfDirectory(atPath: web.path) where !name.hasPrefix(".") {
            let file = try Data(contentsOf: web.appendingPathComponent(name))
            #expect(files[name]?.data == file, "run: swift Scripts/embed-assets.swift \(command) (\(name))")
        }
        #expect(files["index.html"]?.contentType == "text/html; charset=utf-8")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct LogFilterTests {
    /// The logs answer, written directly, is the bytes of the array of `logJSON` it replaced.
    @Test func writesLogsAsTheirJSON() {
        let start = Date(timeIntervalSince1970: 1_800_000_000.75)
        let lines = [
            LogBuffer.Line(date: start, level: .info, label: "Bench Home", text: "plain"),
            LogBuffer.Line(date: start.addingTimeInterval(61), level: .warning, label: "Dyson \"Pure\"", text: "a\nb\té / \u{1} 😀", details: #"{"k":[1,2]}"#),
            LogBuffer.Line(date: start.addingTimeInterval(3600), level: .error, label: "", text: ""),
        ]
        #expect(UIServer.logsJSON(lines) == JSONValue.array(lines.map(UIServer.logJSON)).encoded())
        #expect(UIServer.logsJSON([]) == JSONValue.array([]).encoded())
    }

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

    /// A line's payload goes to the page beside its text, and an accessory named only in the payload finds the line.
    /// Without a log on disk there is nothing to save payloads to.
    @Test func servesPayloads() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        environment.logs.append(LogBuffer.Line(level: .debug, label: "Cloud", text: "state {…} 180 B", details: #"{"id":"Lamps:lamp","on":true}"#))
        let browser = Browser(base: base)
        let lines = try await browser.get("/api/logs?accessory=Lamps:lamp").json?.arrayValue ?? []
        #expect(lines.map { $0["details"]?.stringValue } == [#"{"id":"Lamps:lamp","on":true}"#])
        #expect(try await browser.get("/api/logs/settings").json == ["saveDetails": false, "available": false])
        #expect(try await browser.put("/api/logs/settings", ["saveDetails": true]).status == 404)
        #expect(try await browser.put("/api/logs/settings", ["saveDetails": "yes"]).status == 400)
    }

    /// The Accessories page's wall is kept beside config.json, owner-only, trimmed to what a layout holds; a size
    /// or a grouping the page does not know is refused.
    @Test func keepsTheAccessoryLayout() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        #expect(try await browser.get("/api/layout").json == ["order": [], "sizes": [:], "defaults": [:], "grouping": "none"])
        let layout: JSONValue = ["order": ["Lamps:lamp", "Lamps:lock", "Lamps:lamp"], "sizes": ["Lamps:lamp": "xlarge", "Lamps:lock": "large"], "defaults": ["light": "small", "climate": "xlarge"], "grouping": "plugin", "extra": true]
        let kept: JSONValue = ["order": ["Lamps:lamp", "Lamps:lock"], "sizes": ["Lamps:lamp": "xlarge", "Lamps:lock": "large"], "defaults": ["light": "small", "climate": "xlarge"], "grouping": "plugin"]
        #expect(try await browser.put("/api/layout", layout).json == kept)
        #expect(try await browser.get("/api/layout").json == kept)
        let file = environment.directory.appendingPathComponent("ui-layout.json")
        #expect(try JSONValue(data: Data(contentsOf: file)) == kept)
        #if !os(Windows)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        #endif
        #expect(try await browser.put("/api/layout", ["sizes": ["Lamps:lamp": "huge"]]).status == 400)
        #expect(try await browser.put("/api/layout", ["grouping": "floor"]).status == 400)
        #expect(try await browser.put("/api/layout", ["defaults": ["Light!": "small"]]).status == 400)
        #expect(try await browser.put("/api/layout", ["order": [1, 2]]).status == 400)
        #expect(try await browser.get("/api/layout").json == kept)
    }

    /// A light with Adaptive Lighting says so; on needs a schedule the Home app sent (409, with what to do), off
    /// always works. A device that does not answer is refused in words, not as a Swift error.
    @Test func turnsAdaptiveLightingOnAndOffAndExplainsRefusals() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        let accessories = try await browser.get("/api/accessories").json?.arrayValue ?? []
        let strip = try #require(accessories.first { $0["id"]?.stringValue == "Lamps:strip" })
        let light = try #require(strip["services"]?.arrayValue?.first { $0["type"]?.stringValue == "Lightbulb" })
        #expect(light["adaptiveLighting"] == ["active": false, "resumable": false])
        let lamp = try #require(accessories.first { $0["id"]?.stringValue == "Lamps:lamp" })
        #expect(lamp["services"]?.arrayValue?.allSatisfy { $0["adaptiveLighting"] == nil } == true)

        let refused = try await browser.put("/api/accessories/Lamps:strip/adaptive-lighting", ["on": true])
        #expect(refused.status == 409)
        #expect(refused.json?["error"]?.stringValue?.contains("Home app") == true)
        #expect(try await browser.put("/api/accessories/Lamps:strip/adaptive-lighting", ["on": false]).json?["adaptiveLighting"] == ["active": false, "resumable": false])
        #expect(try await browser.put("/api/accessories/Lamps:lamp/adaptive-lighting", ["on": true]).status == 409)
        #expect(try await browser.put("/api/accessories/Lamps:strip/adaptive-lighting", [:]).status == 400)

        let unreachable = try #require(environment.server.catalog.find(id: "Lamps:lamp")?.accessory)
        unreachable.isUnavailable = true
        let failed = try await browser.put("/api/accessories/Lamps:lamp", ["characteristic": "Brightness", "value": 10])
        #expect(failed.json?["error"]?.stringValue == "Desk Lamp did not answer: the device may be off or out of reach")
    }

    /// A bridge's own lines (its server's), or every bridge's; with an accessory, both must hold.
    @Test func picksABridgesLines() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        environment.logs.append(LogBuffer.Line(level: .info, label: "UI Bridge", text: "Connection opened"))
        environment.logs.append(LogBuffer.Line(level: .info, label: "Lamps", text: "Desk Lamp turned on"))
        environment.logs.append(LogBuffer.Line(level: .info, label: "homeswift", text: "Web UI listening"))
        let browser = Browser(base: base)
        let bridge = try #require(environment.server.catalog.host.mainBridge.server.deviceID.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        environment.logs.append(LogBuffer.Line(level: .info, label: "UI Bridge", text: "Desk Lamp read by a controller"))
        let lines = try await browser.get("/api/logs?bridge=\(bridge)").json?.arrayValue ?? []
        #expect(lines.map { $0["text"]?.stringValue ?? "" } == ["Connection opened", "Desk Lamp read by a controller"])
        #expect(try await browser.get("/api/logs?bridge=all").json?.arrayValue?.count == 2)
        let both = try await browser.get("/api/logs?bridge=\(bridge)&accessory=Lamps:lamp").json?.arrayValue ?? []
        #expect(both.map { $0["text"]?.stringValue ?? "" } == ["Desk Lamp read by a controller"])
        // A plugin's own lines, by its block's name; a name no block has picks nothing out.
        let plugin = try await browser.get("/api/logs?plugin=Lamps").json?.arrayValue ?? []
        #expect(plugin.map { $0["text"]?.stringValue ?? "" } == ["Desk Lamp turned on"])
        #expect(try await browser.get("/api/logs?plugin=Nope").json?.arrayValue?.count == 4)
    }
}

/// The Status page's charts: the history of the whole process, or of one accessory's calls.
@Suite(.timeLimit(.minutes(1)))
struct MetricsAPITests {
    @Test func servesTheHistory() async throws {
        let metrics = Metrics(directory: nil, interval: .seconds(60))
        let environment = try UITestEnvironment(auth: .none, metrics: metrics)
        let base = try await environment.start()
        defer { Task { metrics.stop(); await environment.stop() } }
        metrics.start(following: environment.host)
        let lamp = try #require(environment.server.catalog.find(id: "Lamps:lamp")?.accessory)
        try await #require(lamp.service(.lightbulb)?[.brightness]).write(.int(30))

        let browser = Browser(base: base)
        let all = try #require(try await browser.get("/api/metrics").json)
        #expect(all["step"]?.doubleValue == 60)
        #expect(all["latest"]?["memory"]?.doubleValue ?? 0 > 0)
        #expect(all["points"]?.arrayValue?.last?["handlers"]?["count"]?.doubleValue == 1)
        let one = try #require(try await browser.get("/api/metrics?accessory=Lamps:lock").json)
        #expect(one["points"]?.arrayValue?.last?["handlers"] == .null)
        #expect(try await browser.get("/api/metrics?from=2030-01-01T00:00:00Z&to=2029-01-01T00:00:00Z").status == 400)
    }

    /// The Energy section: the roles some series has, the power added up, a line of levels per device and the days.
    @Test func servesTheEnergySection() async throws {
        let minute = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let clock = NIOLockedValueBox(minute.addingTimeInterval(-120))
        let metrics = Metrics(directory: nil, now: { clock.withLockedValue { $0 } })
        let environment = try UITestEnvironment(auth: .none, metrics: metrics)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        #expect(try await browser.get("/api/metrics/energy").json?["roles"]?.arrayValue == [])

        metrics.tag("plugin:Test:a:solar", EnergyTag(role: .solar, device: "A"))
        metrics.tag("plugin:Test:b:solar", EnergyTag(role: .solar, device: "B"))
        metrics.tag("plugin:Test:a:grid", EnergyTag(role: .grid, device: "A"))
        metrics.tag("plugin:Test:a:level", EnergyTag(role: .batteryLevel, device: "A"))
        metrics.record(600, series: "plugin:Test:a:solar")
        metrics.record(300, series: "plugin:Test:b:solar")
        metrics.record(-480, series: "plugin:Test:a:grid")
        metrics.record(64, series: "plugin:Test:a:level")
        clock.withLockedValue { $0 = minute }
        metrics.record(1, series: "plugin:Test:untagged")

        let energy = try #require(try await browser.get("/api/metrics/energy?timeZone=UTC").json)
        #expect(energy["roles"]?.arrayValue == [.string("solar"), .string("grid"), .string("batteryLevel")])
        #expect(energy["step"]?.doubleValue == 60)
        let point = try #require(energy["power"]?.arrayValue?.first)
        #expect(point["solar"]?.doubleValue == 900)
        #expect(point["grid"]?.doubleValue == -480)
        #expect(energy["levels"]?.arrayValue?.first?["device"]?.stringValue == "A")
        #expect(energy["levels"]?.arrayValue?.first?["points"]?.arrayValue?.first?.arrayValue?.last?.doubleValue == 64)
        let days = try #require(energy["days"]?.arrayValue)
        #expect(days.count == 8)
        // The minute just closed counts in today's energy, unless it was yesterday's last.
        let today = days.first { $0["minutes"]?.doubleValue == 1 }
        #expect(today?["solar"]?.doubleValue == 0.015)
        #expect(today?["gridExport"]?.doubleValue == 0.008)
        #expect(today?["solarShare"] == .null)
        #expect(try await browser.get("/api/metrics/energy?from=2030-01-01T00:00:00Z&to=2029-01-01T00:00:00Z").status == 400)
    }

    /// The long-term history: days or months of the archive, null where an import knows nothing.
    @Test func servesTheEnergyHistory() async throws {
        let metrics = Metrics(directory: nil)
        let environment = try UITestEnvironment(auth: .none, metrics: metrics)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        // 3 and 4 March 2026, 10:00 UTC: an imported hour each.
        let march3 = Date(timeIntervalSince1970: 1_772_532_000)
        metrics.archive.importHours([EnergyHourImport(start: march3, flows: EnergyFlows(solar: 1500, home: 1000)),
                                     EnergyHourImport(start: march3.addingTimeInterval(86_400), flows: EnergyFlows(solar: 0, home: 2000))], source: "Test")
        let browser = Browser(base: base)

        let month = try #require(try await browser.get("/api/metrics/energy/history?period=month&date=2026-03-15&timeZone=UTC").json)
        let bars = try #require(month["bars"]?.arrayValue)
        #expect(bars.count == 31)
        #expect(month["earliest"]?.stringValue == "2026-03-03")
        // No plugin has imported: no import to show.
        #expect(month["imports"]?.arrayValue == [])
        let third = bars[2]
        #expect(third["date"]?.stringValue == "2026-03-03")
        #expect(third["solar"]?.doubleValue == 1.5)
        #expect(third["homeFromSolar"]?.doubleValue == 1)
        #expect(third["solarShare"]?.doubleValue == 1)
        #expect(third["gridImport"] == .null)
        #expect(bars[3]["homeNotSplit"]?.doubleValue == 2)
        #expect(bars[3]["importedHours"]?.doubleValue == 1)
        #expect(bars[0]["home"] == .null)

        let year = try #require(try await browser.get("/api/metrics/energy/history?period=year&date=2026-03-15&timeZone=UTC").json)
        #expect(year["bars"]?.arrayValue?.count == 12)
        #expect(year["bars"]?.arrayValue?[2]["date"]?.stringValue == "2026-03")
        #expect(year["bars"]?.arrayValue?[2]["home"]?.doubleValue == 3)
        let week = try #require(try await browser.get("/api/metrics/energy/history?period=week&date=2026-03-04&timeZone=UTC").json)
        #expect(week["bars"]?.arrayValue?.map { $0["date"]?.stringValue ?? "" }.last == "2026-03-04")
        #expect(week["bars"]?.arrayValue?.count == 8)
        #expect(try await browser.get("/api/metrics/energy/history?period=decade").status == 400)
        #expect(try await browser.get("/api/metrics/energy/history?period=month&date=2026-13-01").status == 400)
    }

    @Test func answersNotFoundWithoutARecorder() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        #expect(try await Browser(base: base).get("/api/metrics").status == 404)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct UIServerTests {
    /// HSTS only when a trusted proxy says the browser came over HTTPS: the proxy's certificate is a real one.
    @Test func sendsHSTSOnlyBehindATrustedHTTPSProxy() async throws {
        let environment = try UITestEnvironment(trustProxy: "loopback")
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        #expect(try await browser.get("/").headers["strict-transport-security"] == nil)
        let proxied = try await browser.send("GET", "/", headers: ["X-Forwarded-Proto": "https"])
        #expect(proxied.headers["strict-transport-security"] == "max-age=31536000")
        #expect(try await browser.send("GET", "/", headers: ["X-Forwarded-Proto": "http"]).headers["strict-transport-security"] == nil)
    }

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
        #expect(page.headers["permissions-policy"]?.contains("camera=()") == true && page.headers["permissions-policy"]?.contains("microphone=(self)") == true)
        #expect(page.headers["x-robots-tag"] == "noindex, nofollow")
        #expect(page.headers["strict-transport-security"] == nil)
        let robots = try await browser.get("/robots.txt")
        #expect(robots.status == 200 && robots.body == "User-agent: *\nDisallow: /\n")
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
        #expect(try await browser.post("/api/assistant/config", ["platform": "Recording", "request": "two lights"]).status == 404)
        let status = try await browser.get("/api/status").json
        #expect(status?["bridges"]?[0]?["deviceId"] == "0E:11:22:33:44:66")
        #expect(status?["bridges"]?[0]?["setupCode"] == "0314-5154")
        #expect(status?["restartNeeded"] == false)
        #expect(status?["username"] == "rosaly")
        let accessories = try await browser.get("/api/accessories").json?.arrayValue ?? []
        #expect(accessories.map { $0["id"] } == ["Lamps:lamp", "Lamps:lock", "Lamps:strip"])
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
        #expect(plugins?["blocks"]?[0]?["slug"] == "lamps")
        #expect(plugins?["blocks"]?[1]?["system"] == true)
        #expect(plugins?["plugins"]?.arrayValue?.contains { $0["platform"] == "ElgatoKeyLights" && $0["hasSchema"] == true } == true)
        let schema = try await browser.get("/api/plugins/ElgatoKeyLights/schema")
        #expect(schema.status == 200)

        // A plugin's own page and its API, for the signed-in user only.
        #expect(plugins?["plugins"]?.arrayValue?.contains { $0["platform"] == "Lamps" && $0["hasPages"] == true } == true)
        // At /plugins/<slug>, its files beside it, the page told which instance it is.
        let pluginPage = try await browser.get("/plugins/lamps")
        #expect(pluginPage.status == 200)
        #expect(pluginPage.body.contains("<title>Lamps</title>"))
        #expect(pluginPage.body.contains(#"<base href="/plugins/lamps/">"#))
        #expect(pluginPage.body.contains(#"data-platform="Lamps" data-name="Lamps""#))
        #expect(try await browser.get("/plugins/lamps/missing.js").status == 404)
        #expect(try await browser.get("/plugins/nope/app.js").status == 404)
        #expect(try await browser.get("/plugin.js").status == 200)
        // The UI's views are the UI's page, whatever their path.
        for path in ["/plugins/lamps/expert/json", "/plugins/nope", "/logs/desk-lamp?since=24h", "/accessories"] {
            let view = try await browser.get(path)
            #expect(view.status == 200 && view.body.contains("<title>Homeswift</title>"), "\(path)")
        }
        // Signed out: the UI's page, which signs in first.
        let anonymous = Browser(base: base)
        #expect(try await anonymous.get("/plugins/lamps").body.contains("<title>Homeswift</title>"))
        #expect(try await anonymous.get("/plugins/lamps/app.js").status == 404)
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
        // The page's config shows the PIN as the placeholder, never the value.
        #expect(config.json?["bridge"]?["pin"] == .string(Redaction.placeholder))
        // The Assistant is offered in the plugin list, so a removed one can be added again.
        let pluginList = try await browser.get("/api/plugins")
        #expect(pluginList.json?["plugins"]?.arrayValue?.contains { $0["platform"] == "HomeswiftAiKit" } == true)

        let patched = try await browser.put("/api/config/platforms/0", ["platform": "Lamps", "name": "Lamps", "pollingRate": 5])
        #expect(patched.status == 200)
        #expect(patched.json?["changes"] == ["platforms[0].pollingRate"])
        #expect(try JSONValue(data: Data(contentsOf: environment.configURL))["platforms"]?[0]?["pollingRate"] == 5)
        // A plugin block applies in place: no restart.
        #expect(patched.json?["restartNeeded"] == [] && patched.json?["restarting"] == false)
        #expect(try await browser.get("/api/status").json?["restartNeeded"] == false)
        #expect(try await browser.put("/api/config/platforms/2", ["platform": "ElgatoKeyLights", "name": "Lights"]).status == 200)
        // What a save changes in a plugin's block must match its config.schema.json, each problem with its path; the
        // page can save anyway.
        let tooFast: JSONValue = ["platform": "ElgatoKeyLights", "name": "Lights", "pollingRate": 100]
        let refused = try await browser.put("/api/config/platforms/2", tooFast)
        #expect(refused.status == 422)
        #expect(refused.json?["problems"]?[0]?["path"] == ["platforms", 2, "pollingRate"])
        #expect(refused.json?["problems"]?[0]?["text"] == "pollingRate must be >= 250")
        #expect(refused.json?["error"]?.stringValue?.contains("ElgatoKeyLights: pollingRate must be >= 250") == true)
        #expect(try await browser.put("/api/config/platforms/2?force=true", tooFast).status == 200)
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
            // Neither compressed nor buffered by a proxy on the way (Cloudflare, nginx).
            #expect(http.headers["cache-control"] == "no-store, no-transform" && http.headers["x-accel-buffering"] == "no")
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

    @Test func revalidatesScriptsAndStylesButNotPages() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        let script = try await browser.get("/app.js")
        #expect(script.status == 200)
        #expect(script.headers["cache-control"] == "no-cache")
        let tag = try #require(script.headers["etag"])
        let again = try await browser.send("GET", "/app.js", headers: ["If-None-Match": tag])
        #expect(again.status == 304)
        #expect(again.body.isEmpty)
        #expect(try await browser.send("GET", "/app.js", headers: ["If-None-Match": "\"other\""]).status == 200)
        #expect(try await browser.get("/style.css").headers["etag"] != tag)
        let page = try await browser.get("/")
        #expect(page.headers["cache-control"] == "no-store")
        #expect(page.headers["etag"] == nil)
    }
}
