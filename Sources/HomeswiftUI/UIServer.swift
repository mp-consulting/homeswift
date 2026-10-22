import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

/// The web UI: a NIO HTTP server inside the bridge serving the embedded pages and a JSON API over the
/// same control surface the MCP server uses (`HomeswiftCatalog`).
///
/// With `auth: form` the first visit creates the admin account, with the set-up code the bridge printed;
/// every API request then needs the session cookie. Requests are answered only for the server's own names
/// (`isAllowedHost`). Mutations must come from the page itself: JSON bodies only, and an `Origin` that
/// matches the `Host`. Pages and API answers carry no-store and content-security headers.
public final class UIServer: Sendable {
    public struct Options: Sendable {
        public var logger = Logger(label: "homeswift.ui")
        /// PBKDF2 iterations for new users (tests lower it).
        public var hashIterations = UserStore.defaultIterations
        /// A checkout to serve the web files from, live, instead of the copies compiled in (`HOMESWIFT_WEB_ROOT`).
        public var webRoot: URL?
        public init() {}
    }

    public let configuration: UIConfiguration
    public let catalog: HomeswiftCatalog
    public let users: UserStore
    public let sessions: SessionStore
    /// With `auth: form` and no account yet: what the first visitor must type to create one. The bridge's banner
    /// prints it; it is never logged, so a client of the MCP log tools cannot claim the UI.
    public let setupCode: String?
    let allowedHosts: Set<String>
    /// The pairing QR codes, by bridge index: the setup URI does not change while the process runs.
    private let qrCodes = NIOLockedValueBox<[Int: String]>([:])
    let options: Options
    let throttle = FailureThrottle()
    let events = EventHub()
    private let channel = NIOLockedValueBox<(any Channel)?>(nil)
    let live: LiveWebFiles?
    private let watcher = NIOLockedValueBox<Task<Void, Never>?>(nil)
    var logger: Logger { options.logger }

    static let cookieName = "homeswift_session"

    public init(configuration: UIConfiguration, catalog: HomeswiftCatalog, usersURL: URL, options: Options = Options()) {
        self.configuration = configuration
        self.catalog = catalog
        self.options = options
        let users = UserStore(url: usersURL, iterations: options.hashIterations)
        self.users = users
        sessions = SessionStore(
            lifetime: TimeInterval(configuration.sessionDays) * 86_400, url: usersURL.deletingLastPathComponent().appendingPathComponent("ui-sessions.json"),
            isKnownUser: { users.contains($0) })
        setupCode = configuration.auth == .form && users.isEmpty ? Self.makeSetupCode() : nil
        allowedHosts = Self.allowedHosts(for: configuration)
        live = options.webRoot.map(LiveWebFiles.init(root:))
    }

    /// The bound port, once started.
    public var port: Int? { channel.withLockedValue { $0?.localAddress?.port } }

    public func start() async throws {
        events.attach(to: catalog)
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 32)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(UIRequestHandler(server: self))
                }
            }
        let bound = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        channel.withLockedValue { $0 = bound }
        logger.info("Web UI listening", metadata: ["url": "http://\(configuration.host):\(bound.localAddress?.port ?? configuration.port)/", "auth": "\(configuration.auth.rawValue)"])
        if let live {
            // Open pages swap a stylesheet in place and reload for a script or a page.
            let events = events
            watcher.withLockedValue { $0 = live.watch { path in
                events.broadcast(event: "asset", payload: ["file": .string(path), "kind": .string(path.hasSuffix(".css") ? "css" : "page")])
            } }
            logger.info("Web files served live from the checkout; pages reload when one changes", metadata: ["root": "\(live.root.path)"])
        }
    }

    public func stop() async {
        watcher.withLockedValue { $0 }?.cancel()
        events.close()
        let bound = channel.withLockedValue { channel -> (any Channel)? in
            defer { channel = nil }
            return channel
        }
        try? await bound?.close()
    }

    // MARK: Requests

    struct Request: Sendable {
        var method: HTTPMethod
        var path: String
        var query: [String: String] = [:]
        var headers: [String: String]
        var body: Data
        var remote: String

        var cookies: [String: String] {
            (headers["cookie"] ?? "").split(separator: ";").reduce(into: [:]) { result, pair in
                let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { result[parts[0]] = parts[1] }
            }
        }
    }

    enum Reply: Sendable {
        case data(status: Int, contentType: String, body: Data, headers: [String: String] = [:])
        case events(AsyncStream<Data>)

        static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            .data(status: status, contentType: "application/json", body: value.encoded(), headers: headers)
        }

        /// An error for the page, secrets masked whatever the text came from.
        static func error(_ status: Int, _ message: String) -> Reply {
            .json(["error": .string(Redaction.redactText(message))], status: status)
        }

        static func text(_ text: String, status: Int = 200, contentType: String) -> Reply {
            .data(status: status, contentType: contentType, body: Data(text.utf8))
        }

        static func redirect(to location: String) -> Reply {
            .data(status: 302, contentType: "text/plain", body: Data(), headers: ["Location": location])
        }
    }

    func reply(to request: Request) async -> Reply {
        guard isAllowedHost(request.headers["host"]) else {
            return .error(421, "this is not a name the web UI answers to; add it to allowedHosts in the HomeswiftUI block")
        }
        let parts = request.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.first == "api" else { return page(for: parts, request) }
        let route = Array(parts.dropFirst())
        if route.first == "auth" { return await auth(route.dropFirst().first ?? "", request) }
        guard let username = authenticatedUser(request) else { return .error(401, "sign in first") }
        if request.method != .GET, let refused = refuseCrossSite(request) { return refused }
        do {
            return try await api(route, request, username: username)
        } catch let error as JSONRPCError {
            return .error(400, error.message)
        } catch {
            return .error(400, "\(error)")
        }
    }

    // MARK: Pages

    private func page(for parts: [String], _ request: Request) -> Reply {
        let files: [String: WebFile]
        let name: String
        var platform: String?
        if parts.first == "plugins", parts.count >= 2 {
            // A plugin's own pages, for a signed-in user; anyone else lands on the login page.
            guard authenticatedUser(request) != nil else { return .redirect(to: "/") }
            platform = parts[1]
            files = catalog.host.registry.entry(for: parts[1])?.webFiles ?? [:]
            name = parts.count == 2 ? "index.html" : parts.dropFirst(2).joined(separator: "/")
        } else {
            files = WebAssets.files
            name = parts.isEmpty ? "index.html" : parts.joined(separator: "/")
        }
        if let live, let file = live.file(name, platform: platform, unreadable: { url, error in
            logger.warning("Live web file unreadable; serving the compiled-in copy", metadata: ["file": "\(url.path)", "error": "\(error)"])
        }) {
            return .data(status: 200, contentType: file.contentType, body: Data(file.body.utf8))
        }
        guard let file = files[name] else { return .text("Not found", status: 404, contentType: "text/plain") }
        return .data(status: 200, contentType: file.contentType, body: Data(file.body.utf8))
    }

    // MARK: Authentication

    func authenticatedUser(_ request: Request) -> String? {
        if configuration.auth == .none { return "local" }
        guard let token = request.cookies[Self.cookieName] else { return nil }
        return sessions.username(for: token)
    }

    private func cookie(_ token: String?) -> String {
        let value = token ?? ""
        let age = token == nil ? 0 : Int(sessions.lifetime)
        return "\(Self.cookieName)=\(value); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(age)"
    }

    /// A browser sends `Origin` on cross-site and on same-site mutations; it must name this server.
    func refuseCrossSite(_ request: Request) -> Reply? {
        if let site = request.headers["sec-fetch-site"], site != "same-origin", site != "none" {
            return .error(403, "cross-site request refused")
        }
        if let origin = request.headers["origin"], let host = request.headers["host"] {
            let url = URL(string: origin)
            let same = url?.host.map(HostName.of) == HostName.of(host) && url?.port == HostName.port(of: host)
            if !same { return .error(403, "origin \(origin) does not match the host") }
        }
        if !request.body.isEmpty, !(request.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") {
            return .error(415, "send JSON")
        }
        return nil
    }

    private func credentials(_ request: Request) -> (String, String)? {
        guard let body = try? JSONValue(data: request.body), let username = body["username"]?.stringValue, let password = body["password"]?.stringValue else { return nil }
        return (username, password)
    }

    private func auth(_ action: String, _ request: Request) async -> Reply {
        switch (request.method, action) {
        case (.GET, "state"):
            let user = authenticatedUser(request)
            let state: JSONValue = [
                "mode": .string(configuration.auth.rawValue), "setupNeeded": .bool(configuration.auth == .form && users.isEmpty),
                "authenticated": .bool(user != nil), "username": user.map(JSONValue.string) ?? .null, "version": .string(PluginHost.version),
                "liveWebFiles": .bool(live != nil), "sessionDays": .number(Double(configuration.sessionDays)),
            ]
            return .json(state)
        case (.POST, "setup"):
            if let refused = refuseCrossSite(request) { return refused }
            guard configuration.auth == .form else { return .error(400, "no login is needed") }
            guard let setupCode, users.isEmpty else { return .error(409, AuthError.setupDone.description) }
            guard let (username, password) = credentials(request) else { return .error(400, "username and password are required") }
            let presented = (try? JSONValue(data: request.body))?["setupCode"]?.stringValue ?? ""
            let delay = throttle.delay(for: request.remote)
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard Self.setupCodeMatches(presented, setupCode) else {
                throttle.failed(request.remote)
                logger.warning("Web UI setup refused: wrong set-up code", metadata: ["remote": "\(request.remote)"])
                return .error(403, AuthError.wrongSetupCode.description)
            }
            do {
                try users.createFirst(username: username, password: password)
            } catch AuthError.setupDone {
                return .error(409, AuthError.setupDone.description)
            } catch {
                return .error(400, "\(error)")
            }
            throttle.succeeded(request.remote)
            logger.info("Web UI account created", metadata: ["username": "\(username)"])
            return .json(["username": .string(username)], headers: ["Set-Cookie": cookie(sessions.create(username: username))])
        case (.POST, "login"):
            if let refused = refuseCrossSite(request) { return refused }
            guard configuration.auth == .form else { return .error(400, "no login is needed") }
            guard let (username, password) = credentials(request) else { return .error(400, "username and password are required") }
            let delay = throttle.delay(for: request.remote)
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard users.verify(username: username, password: password) else {
                throttle.failed(request.remote)
                logger.warning("Web UI login failed", metadata: ["remote": "\(request.remote)"])
                return .error(401, AuthError.badCredentials.description)
            }
            throttle.succeeded(request.remote)
            return .json(["username": .string(username)], headers: ["Set-Cookie": cookie(sessions.create(username: username))])
        case (.POST, "password-strength"):
            // The gauge under a new password: the server's PasswordPolicy, the one that decides, while typing.
            // No session needed: the first account is created before there is one. evaluate caps the size.
            let body = (try? JSONValue(data: request.body)) ?? .null
            let strength = PasswordPolicy.evaluate(body["password"]?.stringValue ?? "", username: body["username"]?.stringValue)
            return .json([
                "bits": .number(strength.bits.rounded()), "level": .string(strength.level.rawValue), "problems": .array(strength.problems.map(JSONValue.string)),
                "reason": strength.reason.map(JSONValue.string) ?? .null,
                "lengthMet": .bool(strength.length >= PasswordPolicy.minimumLength), "bitsMet": .bool(strength.bits >= PasswordPolicy.minimumBits),
                "acceptable": .bool(strength.isAcceptable), "minimumLength": .number(Double(PasswordPolicy.minimumLength)),
                "minimumBits": .number(PasswordPolicy.minimumBits),
            ])
        case (.POST, "logout"):
            if let token = request.cookies[Self.cookieName] { sessions.revoke(token) }
            return .json(JSONValue.object([:]), headers: ["Set-Cookie": cookie(nil)])
        default:
            return .error(404, "unknown auth action")
        }
    }

    // MARK: API

    private func api(_ route: [String], _ request: Request, username: String) async throws -> Reply {
        let body = request.body.isEmpty ? JSONValue.null : try JSONValue(data: request.body)
        if route.count >= 4, route[0] == "plugins" {
            // A plugin page talking to its instance: /api/plugins/<platform>/<name>/<path>.
            let pluginRequest = PluginWebRequest(method: request.method.rawValue, path: route.dropFirst(3).joined(separator: "/"), query: request.query, body: body, user: username)
            guard let response = try await catalog.host.handleWebRequest(platform: route[1], name: route[2], pluginRequest) else {
                return .error(404, "no running instance \"\(route[2])\" of \(route[1])")
            }
            return .json(response.json, status: response.status)
        }
        switch request.method {
        case .GET:
            switch route {
            case ["status"]:
                return .json(status(username: username))
            case ["assistant"]:
                // Whether pages may offer "Explain": the HomeswiftAiKit block's Assistant, when one works.
                guard let assistant = catalog.host.assistant else { return .json(["enabled": false]) }
                return .json(["enabled": true, "provider": .string(assistant.providerName), "model": .string(assistant.model)])
            case ["accessories"]:
                return .json(.array(catalog.located().map { HomeswiftCatalog.accessoryJSON($0, detailed: true) }))
            case ["plugins"]:
                let blocks = catalog.host.configuration.platforms.enumerated().map { index, block -> JSONValue in
                    ["index": .number(Double(index)), "platform": .string(block.platform), "name": .string(block.name), "childBridge": .bool(block.childBridge != nil),
                     "system": .bool(HomeswiftCatalog.systemPlatforms.contains(block.platform))]
                }
                var plugins = catalog.pluginsJSON().objectValue ?? [:]
                plugins["blocks"] = .array(blocks)
                return .json(.object(plugins))
            case ["config"]:
                return .text(try String(contentsOf: catalog.configURL, encoding: .utf8), contentType: "application/json")
            case let path where path.count == 4 && path[0] == "config" && path[1] == "block":
                let block = try catalog.readConfig()["platforms"]?.arrayValue?.first { $0["platform"]?.stringValue == path[2] && ($0["name"]?.stringValue ?? path[2]) == path[3] }
                guard let block else { return .error(404, "no block \(path[3]) of \(path[2])") }
                return .json(block)
            case ["logs"]:
                return .json(.array(catalog.logs.recent(500).map(Self.logJSON)))
            case ["events"]:
                return .events(events.stream())
            default:
                if route.count == 2, route[0] == "qr", route[1].hasSuffix(".svg") {
                    // The pairing QR code of a bridge, for the Home app's camera: the setup URI, which the status page shows anyway.
                    guard let index = Int(route[1].dropLast(4)), catalog.host.bridges.indices.contains(index) else { return .error(404, "no such bridge") }
                    let svg = try qrCodes.withLockedValue { codes -> String in
                        if let cached = codes[index] { return cached }
                        let svg = try QRCode(catalog.host.bridges[index].server.setupURI).svg()
                        codes[index] = svg
                        return svg
                    }
                    return .text(svg, contentType: "image/svg+xml")
                }
                if route.count == 3, route[0] == "plugins", route[2] == "schema" {
                    // The runtime's own web UI block has a form too.
                    let schema = route[1] == UIConfiguration.platform ? UIConfiguration.schemaJSON : catalog.host.registry.entry(for: route[1])?.configurationSchemaJSON
                    guard let text = schema else { return .error(404, "no schema for \(route[1])") }
                    return .text(text, contentType: "application/json")
                }
            }
        case .PUT:
            if route == ["config"] {
                guard body.objectValue != nil else { return .error(400, "the config must be a JSON object") }
                let result = try await catalog.applyConfig(body, dryRun: false)
                noteConfigChange(by: username)
                return .json(result)
            }
            if route.count == 2, route[0] == "accessories" {
                guard let found = catalog.find(id: route[1]) else { return .error(404, "no accessory \(route[1])") }
                guard let characteristic = body["characteristic"]?.stringValue, let value = body["value"] else { return .error(400, "characteristic and value are required") }
                let result = try await catalog.write(found, service: body["service"]?.stringValue, characteristic: characteristic, value: value, allowSecurity: true)
                logger.info("Web UI wrote a characteristic", metadata: ["user": "\(username)", "accessory": "\(found.accessory.name)", "characteristic": "\(characteristic)"])
                return .json(result)
            }
            if route.count == 3, route[0] == "config", route[1] == "platforms" {
                return try await replacePlatformBlock(at: route[2], with: body, username: username)
            }
            if route.count == 4, route[0] == "config", route[1] == "block" {
                // A block by platform and name, for a plugin's own page: its read-modify-write never needs
                // the whole file, nor an index that may have moved.
                guard body.objectValue != nil, body["platform"]?.stringValue == route[2] else { return .error(400, "the block must keep its platform") }
                var found = false
                let result = try await catalog.editPlatforms(dryRun: false) { platforms in
                    guard let index = platforms.firstIndex(where: { $0["platform"]?.stringValue == route[2] && ($0["name"]?.stringValue ?? route[2]) == route[3] }) else { return }
                    platforms[index] = body
                    found = true
                }
                guard found else { return .error(404, "no block \(route[3]) of \(route[2])") }
                noteConfigChange(by: username)
                return .json(result)
            }
        case .POST:
            if route == ["account", "password"] {
                // The signed-in user's own password: the current one first, slowed down after mistakes like a login.
                guard configuration.auth == .form else { return .error(400, "this web UI has no passwords: auth is none") }
                guard let current = body["current"]?.stringValue, let new = body["new"]?.stringValue else { return .error(400, "the current and the new password are required") }
                let delay = throttle.delay(for: request.remote)
                if delay > .zero { try? await Task.sleep(for: delay) }
                do {
                    try users.changePassword(username: username, current: current, new: new)
                } catch AuthError.wrongPassword {
                    throttle.failed(request.remote)
                    logger.warning("Web UI password change refused: wrong current password", metadata: ["user": "\(username)", "remote": "\(request.remote)"])
                    return .error(403, AuthError.wrongPassword.description)
                } catch let error as AuthError {
                    return .error(400, error.description)
                }
                throttle.succeeded(request.remote)
                sessions.revokeAll(of: username, keeping: request.cookies[Self.cookieName])
                logger.info("Web UI password changed; the user's other sessions are signed out", metadata: ["user": "\(username)"])
                return .json(["changed": true])
            }
            if route == ["assistant", "explain"] {
                guard let assistant = catalog.host.assistant else { return .error(404, "the Assistant is off: add a HomeswiftAiKit block") }
                guard let error = body["error"]?.stringValue, !error.isEmpty else { return .error(400, "an error to explain is required") }
                do {
                    let reply = try await assistant.explain(error: error, context: body["context"]?.stringValue, device: body["device"], pluginName: body["plugin"]?.stringValue)
                    return .json(["text": .string(reply.text), "model": .string(reply.model)])
                } catch {
                    return .error(502, "the Assistant did not answer: \(error)")
                }
            }
            if route == ["restart"] {
                guard catalog.scheduleRestart(requestedBy: "web UI user \(username)") else { return .error(501, "this process cannot restart itself; restart homeswift by hand") }
                return .json(["restarting": true])
            }
            if route.count == 3, route[0] == "accessories", route[2] == "identify" {
                guard let found = catalog.find(id: route[1]) else { return .error(404, "no accessory \(route[1])") }
                try await catalog.identify(found)
                return .json(JSONValue.object([:]))
            }
        case .DELETE:
            if route.count == 3, route[0] == "config", route[1] == "platforms" {
                return try await replacePlatformBlock(at: route[2], with: nil, username: username)
            }
        default:
            break
        }
        return .error(404, "unknown API route")
    }

    private func status(username: String) -> JSONValue {
        var status = catalog.statusJSON(includePairing: true).objectValue ?? [:]
        status["username"] = .string(username)
        status["system"] = HomeswiftCatalog.systemJSON()
        return .object(status)
    }

    /// Replaces (or appends, at the next index) a platform block; nil removes it.
    private struct NoSuchBlock: Error { let index: Int }

    private func replacePlatformBlock(at indexText: String, with block: JSONValue?, username: String) async throws -> Reply {
        guard let index = Int(indexText) else { return .error(400, "bad index") }
        do {
            let result = try await catalog.editPlatforms(dryRun: false) { platforms in
                if let block {
                    guard let object = block.objectValue, object["platform"]?.stringValue?.isEmpty == false else { throw JSONRPCError.invalidParams("a platform block needs a platform") }
                    if platforms.indices.contains(index) {
                        platforms[index] = .object(object)
                    } else if index == platforms.count {
                        platforms.append(.object(object))
                    } else {
                        throw NoSuchBlock(index: index)
                    }
                } else {
                    guard platforms.indices.contains(index) else { throw NoSuchBlock(index: index) }
                    platforms.remove(at: index)
                }
            }
            noteConfigChange(by: username)
            return .json(result)
        } catch let missing as NoSuchBlock {
            return .error(404, "no block \(missing.index)")
        }
    }

    static func logJSON(_ line: LogBuffer.Line) -> JSONValue {
        ["time": .string(line.date.formatted(.iso8601)), "level": .string(line.level.rawValue), "label": .string(line.label), "text": .string(line.text)]
    }

    /// Who changed config.json; the host's own line says what applied.
    private func noteConfigChange(by username: String) {
        logger.info("config.json changed from the web UI", metadata: ["user": "\(username)"])
    }
}

/// Broadcasts accessory changes and log lines to every open `/api/events` stream. Its subscriptions end with
/// `close()`, so a web UI restarted in the process leaves nothing behind; the host's feed brings the servers
/// it adds later.
final class EventHub: Sendable {
    private let listeners = NIOLockedValueBox<[UUID: AsyncStream<Data>.Continuation]>([:])
    private let observations = NIOLockedValueBox<[Observation]?>(nil)

    func attach(to catalog: HomeswiftCatalog) {
        guard observations.withLockedValue({ $0 == nil }) else { return }
        // The host's feed covers the servers it adds later too (a new TV, a child bridge from a live reload).
        let changes = catalog.host.observeChanges { [self] accessory, characteristic, value in
            // Nothing is looked up while no page listens: `payload` is only built for a listener.
            broadcast(event: "accessory", payload: {
                let service = accessory.services.first { $0.characteristics.contains { $0 === characteristic } }
                var payload: [String: JSONValue] = ["id": .string(accessory.id), "characteristic": .string(characteristic.type.name), "value": HomeswiftCatalog.json(value)]
                if let service {
                    payload["service"] = .string(service.type.name)
                    if let subtype = service.subtype { payload["subtype"] = .string(subtype) }
                }
                return .object(payload)
            }())
        }
        let log = catalog.logs.observe { [self] line in
            broadcast(event: "log", payload: UIServer.logJSON(line))
        }
        observations.withLockedValue { $0 = [changes, log] }
    }

    func stream() -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(500)) { continuation in
            listeners.withLockedValue { $0[id] = continuation }
            continuation.yield(SSE.frame(event: "hello", data: "{}"))
            continuation.onTermination = { _ in _ = self.listeners.withLockedValue { $0.removeValue(forKey: id) } }
        }
    }

    /// Nothing is encoded while no page listens: this runs inside every log call.
    func broadcast(event: String, payload: @autoclosure () -> JSONValue) {
        let targets = listeners.withLockedValue { Array($0.values) }
        guard !targets.isEmpty else { return }
        let data = SSE.frame(event: event, data: payload().text())
        for continuation in targets { continuation.yield(data) }
    }

    func close() {
        observations.withLockedValue { $0 ?? [] }.forEach { $0.cancel() }
        for continuation in listeners.withLockedValue({ Array($0.values) }) { continuation.finish() }
    }
}

/// Collects one HTTP request, hands it to the server, writes the reply.
final class UIRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    let server: UIServer
    private var head: HTTPRequestHead?
    private var body = Data()

    init(server: UIServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
        case .body(var buffer):
            if body.count < 4 * 1024 * 1024, let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head else { return }
            var headers: [String: String] = [:]
            for (name, value) in head.headers { headers[name.lowercased()] = value }
            let components = URLComponents(string: head.uri)
            let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            let request = UIServer.Request(
                method: head.method, path: components?.percentEncodedPath ?? String(head.uri.prefix { $0 != "?" }), query: query, headers: headers, body: body,
                remote: context.remoteAddress?.ipAddress ?? "?")
            self.head = nil
            Self.respond(to: request, keepAlive: head.isKeepAlive, channel: context.channel, server: server)
        }
    }

    private static func respond(to request: UIServer.Request, keepAlive: Bool, channel: any Channel, server: UIServer) {
        Task {
            let reply = await server.reply(to: request)
            await write(reply, to: channel, keepAlive: keepAlive)
        }
    }

    static let securityHeaders: [(String, String)] = [
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "no-referrer"),
        ("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'"),
        ("Cache-Control", "no-store"),
    ]

    private static func write(_ reply: UIServer.Reply, to channel: any Channel, keepAlive: Bool) async {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        for (name, value) in securityHeaders { head.headers.add(name: name, value: value) }
        switch reply {
        case .data(let status, let contentType, let body, let headers):
            head.status = .init(statusCode: status)
            head.headers.add(name: "Content-Type", value: contentType)
            head.headers.add(name: "Content-Length", value: "\(body.count)")
            for (name, value) in headers { head.headers.add(name: name, value: value) }
            channel.write(HTTPServerResponsePart.head(head), promise: nil)
            if !body.isEmpty { channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil) }
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            if !keepAlive { channel.close(promise: nil) }
        case .events(let stream):
            head.headers.add(name: "Content-Type", value: "text/event-stream")
            head.headers.add(name: "Connection", value: "close")
            channel.writeAndFlush(HTTPServerResponsePart.head(head), promise: nil)
            let keepalive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { break }
                    channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: ": keepalive\n\n"))), promise: nil)
                }
            }
            for await chunk in stream {
                channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: chunk))), promise: nil)
            }
            keepalive.cancel()
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            channel.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

// MARK: The server's names and the set-up code

extension UIServer {
    /// Whether a `Host` header names this server: an IP address, localhost, this machine's name, the configured
    /// host or an `allowedHosts` entry. A page from another site whose name is rebound to this address fails here.
    func isAllowedHost(_ header: String?) -> Bool {
        guard let header else { return false }
        let host = HostName.of(header)
        if allowedHosts.contains("*") || allowedHosts.contains(host) { return true }
        return HostName.isLoopback(host) || HostName.isIPAddress(host)
    }

    static func allowedHosts(for configuration: UIConfiguration) -> Set<String> {
        var hosts: Set<String> = ["localhost"]
        let machine = HomeswiftCatalog.machineName()
        if !machine.isEmpty {
            hosts.insert(machine)
            let first = machine.split(separator: ".").first.map(String.init) ?? machine
            hosts.insert(first)
            hosts.insert(first + ".local")
        }
        let bound = configuration.host.lowercased()
        if !["", "0.0.0.0", "::", "[::]"].contains(bound) { hosts.insert(HostName.of(bound)) }
        for entry in configuration.allowedHosts { hosts.insert(HostName.of(entry)) }
        return hosts
    }

    /// Eight characters from an alphabet without look-alikes, as `XXXX-XXXX`.
    static func makeSetupCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let characters = (0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
        return String(characters[0..<4]) + "-" + String(characters[4..<8])
    }

    /// Case, spaces and dashes do not matter; compared in constant time.
    static func setupCodeMatches(_ presented: String, _ expected: String) -> Bool {
        func bare(_ code: String) -> Data { Data(code.uppercased().filter { $0.isLetter || $0.isNumber }.utf8) }
        return Secrets.constantTimeEqual(bare(presented), bare(expected))
    }
}
