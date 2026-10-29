import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

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
        /// How many Assistant requests (an explanation, a block written, a chat message) each user may make.
        public var assistantRateLimiter = SlidingWindowRateLimiter.assistant()
        /// What the Status page says about a newer release; the CLI's, kept across restarts of the UI. Libraries
        /// and tests have none.
        public var releases: ReleaseWatcher?
        /// The bridge's MCP server, served at `/mcp` too for clients that sign in with OAuth (OAuthRoutes.swift); the
        /// CLI's, which may restart under the UI. Without one, `/mcp` and the OAuth endpoints answer 404.
        public var mcp: (@Sendable () -> MCPHTTPServer?)?
        /// How long a connection may stay silent while no answer is under way (a kept-alive connection between
        /// requests, a request that stopped half-way) before it is closed.
        var idleTimeout: TimeAmount = .seconds(60)
        /// How often an event stream sends a comment to stay open, and checks its caller still may read it.
        var keepalive: Duration = .seconds(20)
        public init() {}
    }

    public let configuration: UIConfiguration
    public let catalog: HomeswiftCatalog
    public let users: UserStore
    public let sessions: SessionStore
    /// API tokens for scripts (`Authorization: Bearer`), in `ui-api-tokens.json`.
    public let tokens: APITokenStore
    /// The OAuth clients and grants of `/mcp`, in `ui-oauth.json`.
    public let oauth: OAuthStore
    /// With `auth: form` and no account yet: what the first visitor must type to create one. The bridge's banner
    /// prints it; it is never logged, so a client of the MCP log tools cannot claim the UI.
    public let setupCode: String?
    let allowedHosts: Set<String>
    /// The pairing QR codes, by bridge index: the setup URI does not change while the process runs.
    private let qrCodes = NIOLockedValueBox<[Int: String]>([:])
    /// The compiled-in scripts, styles and images as served, by platform and name, with their ETags.
    private let assets = NIOLockedValueBox<[String: (file: WebFile, body: Data, tag: String)]>([:])
    let options: Options
    let throttle = FailureThrottle()
    /// Bad bearer tokens at `/mcp`, as the MCP server's own transport slows them down.
    let mcpThrottle = FailureThrottle(window: 600, threshold: 3, maxDelay: 5)
    /// The password and code checks under way, one per client address at a time.
    let credentialChecks = CredentialChecks()
    let events = EventHub()
    let chat: AssistantChat
    /// The pages' one-shot Assistant requests, streamed and cancellable (`AssistantRoutes.swift`).
    let runs = AssistantRuns()
    /// Each user's appearance and Status page layout.
    let preferences: PreferencesStore
    /// Who watches which camera's live feed, to cap them.
    let cameraViewers = CameraViewers()
    /// The snapshot each camera is taking, shared by the requests that come meanwhile.
    let cameraSnapshots = CameraSnapshots()
    private let channel = NIOLockedValueBox<(any Channel)?>(nil)
    let live: LiveWebFiles?
    private let watcher = NIOLockedValueBox<Task<Void, Never>?>(nil)
    /// The scheduled restart and the daily backup, while the server runs (Admin.swift).
    let schedules = NIOLockedValueBox(ScheduleState())
    /// Where the UI's own changes are recorded: the MCP audit log, as client "web UI".
    let auditLog: AuditLog?
    /// With `https`, the certificate it serves, once started.
    private let tls = NIOLockedValueBox<UICertificate?>(nil)
    /// Where the bridge keeps its own files: the generated certificate goes there.
    let directory: URL
    /// The Accessories page's wall: order and sizes (`ui-layout.json`).
    let layout: WallLayout
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
        tokens = APITokenStore(url: usersURL.deletingLastPathComponent().appendingPathComponent("ui-api-tokens.json"))
        oauth = OAuthStore(url: usersURL.deletingLastPathComponent().appendingPathComponent("ui-oauth.json"))
        live = options.webRoot.map(LiveWebFiles.init(root:))
        chat = AssistantChat(catalog: catalog, storeURL: usersURL.deletingLastPathComponent().appendingPathComponent("ui-chats.json"), logger: options.logger)
        directory = usersURL.deletingLastPathComponent()
        preferences = PreferencesStore(url: usersURL.deletingLastPathComponent().appendingPathComponent("ui-preferences.json"))
        auditLog = catalog.auditLog()
        layout = catalog.home.wall
    }

    /// The SHA-256 fingerprint of the HTTPS certificate, for the banner: what a browser's warning shows.
    public var certificateFingerprint: String? { tls.withLockedValue { $0?.fingerprint } }

    /// The bound port, once started.
    public var port: Int? { channel.withLockedValue { $0?.localAddress?.port } }

    public func start() async throws {
        events.attach(to: catalog)
        let sslContext = try configuration.https ? makeSSLContext() : nil
        let idleTimeout = options.idleTimeout
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 32)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: idleTimeout))
                    if let sslContext { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext)) }
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(UIRequestHandler(server: self))
                }
            }
        let bound = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        channel.withLockedValue { $0 = bound }
        startSchedules()
        logger.info("Web UI listening", metadata: ["url": "\(configuration.scheme)://\(configuration.host):\(bound.localAddress?.port ?? configuration.port)/", "auth": "\(configuration.auth.rawValue)"])
        if let live {
            // Open pages swap a stylesheet in place and reload for a script or a page.
            let events = events
            watcher.withLockedValue { $0 = live.watch { path in
                events.broadcast(event: "asset", payload: ["file": .string(path), "kind": .string(path.hasSuffix(".css") ? "css" : "page")])
            } }
            logger.info("Web files served live from the checkout; pages reload when one changes", metadata: ["root": "\(live.root.path)"])
        }
    }

    /// The HTTPS certificate (kept for the banner and for download) and its TLS context.
    private func makeSSLContext() throws -> NIOSSLContext {
        let names = allowedHosts.filter { $0 != "*" }.sorted { $0.count > $1.count }
        let certificate = try UICertificate.load(configuration: configuration, directory: directory, names: names, logger: logger)
        tls.withLockedValue { $0 = certificate }
        return try certificate.sslContext()
    }

    public func stop() async {
        watcher.withLockedValue { $0 }?.cancel()
        stopSchedules()
        events.close()
        runs.cancelAll()
        await chat.close()
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
        /// The browser reached a trusted reverse proxy over HTTPS (`trustProxy`): the cookie is Secure.
        var secure = false
        /// The body was larger than the route accepts and was cut.
        var truncated = false

        var cookies: [String: String] {
            (headers["cookie"] ?? "").split(separator: ";").reduce(into: [:]) { result, pair in
                let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { result[parts[0]] = parts[1] }
            }
        }
    }

    enum Reply: Sendable {
        case data(status: Int, contentType: String, body: Data, headers: [String: String] = [:])
        /// Server-sent events; `allowed`, asked at each keepalive, ends the stream once it answers false.
        case events(AsyncStream<Data>, allowed: (@Sendable () -> Bool)? = nil, headers: [String: String] = [:])
        /// A camera's live feed, chunked: the initialization segment, then each fragment until the browser leaves.
        case media(MediaStream)

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
        // The handler stopped keeping the body past what the request may send (UIRequestHandler's body limits).
        if request.truncated {
            return .error(413, Self.acceptsArchive(request) ? "the upload is larger than \(InstanceBackups.maxArchiveSize / 1_048_576) MB" : "the request is too large")
        }
        // On the MCP connector's shared host name (`publicURL`), its path stands for the UI's own routes.
        let path = publicURL(for: request).flatMap { $0.route(request.path) } ?? request.path
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        if parts == ["robots.txt"] { return .text("User-agent: *\nDisallow: /\n", contentType: "text/plain; charset=utf-8") }
        if let reply = await oauthEndpoint(parts, request) { return reply }
        guard parts.first == "api" else { return page(for: parts, request) }
        let route = Array(parts.dropFirst())
        if route.first == "auth" { return await auth(route.dropFirst().first ?? "", request) }
        guard let caller = self.caller(request, bearer: true) else { return .error(401, "sign in first") }
        // A cookie rides along with any request the browser makes, so a mutation must come from the page itself;
        // a bearer token is only sent by what holds it, which a page from another site cannot read.
        if request.method != .GET, let refused = refuseCrossSite(request, checkOrigin: caller.token == nil) { return refused }
        let needed = Self.requiredScope(request.method, route)
        guard caller.scope >= needed else {
            return .error(403, caller.token?.scope == .read ? "this API token can only read" : "only an administrator can do this")
        }
        do {
            var reply = try await api(route, request, caller: caller)
            if request.method != .GET { audit(route, request, caller: caller, reply: reply) }
            // A stream outlives the request: it ends once its caller could no longer open it (signed out, removed,
            // the token revoked, or no longer an administrator, whose stream carries the log).
            if case .events(let stream, .none, let headers) = reply {
                reply = .events(stream, allowed: { [self] in self.caller(request, bearer: true, refresh: false)?.scope == caller.scope }, headers: headers)
            }
            return reply
        } catch let error as ConfigSchemaError {
            // Each problem with its path, for the editors to mark the line.
            return .json(["error": .string(Redaction.redactText(error.description)), "problems": .array(error.problems.map(\.json))], status: 422)
        } catch let error as JSONRPCError {
            return .error(400, error.message)
        } catch {
            return .error(400, "\(error)")
        }
    }

    // MARK: Pages

    /// The pages. The UI's own are one page whose script draws the view its path names (`/accessories`,
    /// `/plugins/dyson-pure-cool/expert`, `/logs/desk-lamp?since=24h`), so any path without a file is that page.
    /// A plugin instance's own page is at `/plugins/<its slug>`, its files beside it.
    private func page(for parts: [String], _ request: Request) -> Reply {
        let files: [String: WebFile]
        var name: String
        var platform: String?
        var instance: (slug: String, name: String)?
        if parts.first == "plugins", parts.count >= 2, caller(request, bearer: false)?.scope == .admin, let target = pluginPage(slug: parts[1]),
                  parts.count > 2 ? parts.last?.contains(".") == true : target.hasPage {
            // An instance's page, or one of its files, by its slug, for a signed-in administrator; anyone else gets
            // the UI's page, which signs them in and then shows it (or, to a user who is not an administrator, Status).
            platform = target.platform
            files = catalog.host.registry.entry(for: target.platform)?.webFiles ?? [:]
            name = parts.count == 2 ? "index.html" : parts.dropFirst(2).joined(separator: "/")
            if parts.count == 2 { instance = (parts[1], target.name) }
        } else {
            // The HTTPS certificate, for a phone or a computer to trust: public, like any served certificate.
            if parts == ["homeswift-ui.crt"], let certificate = tls.withLockedValue({ $0 }) {
                return .data(status: 200, contentType: "application/x-x509-ca-cert", body: certificate.certificateDER,
                             headers: ["Content-Disposition": "attachment; filename=\"homeswift-ui.crt\""])
            }
            files = WebAssets.files
            // `/oauth/authorize`: the page that signs a user in for an OAuth client (claude.ai) and asks what it may do.
            name = parts.isEmpty ? "index.html" : parts == ["oauth", "authorize"] ? "authorize.html" : parts.joined(separator: "/")
            // A view's address, not a file: the page, which draws it.
            if files[name] == nil, parts.last?.contains(".") != true { name = "index.html" }
        }
        let file = live?.file(name, platform: platform, unreadable: { url, error in
            logger.warning("Live web file unreadable; serving the compiled-in copy", metadata: ["file": "\(url.path)", "error": "\(error)"])
        }) ?? files[name]
        guard let file else { return .text("Not found", status: 404, contentType: "text/plain") }
        if !file.contentType.hasPrefix("text/html") {
            // Scripts, styles and images are revalidated rather than downloaded again on every visit: an ETag of
            // their bytes, a 304 while it still matches. Pages keep no-store, like the API.
            let (body, tag) = asset(file, name: name, platform: platform, live: live != nil)
            if request.headers["if-none-match"] == tag {
                return .data(status: 304, contentType: file.contentType, body: Data(), headers: ["ETag": tag, "Cache-Control": "no-cache"])
            }
            return .data(status: 200, contentType: file.contentType, body: body, headers: ["ETag": tag, "Cache-Control": "no-cache"])
        }
        var body = file.body
        if platform == nil, name == "index.html", tls.withLockedValue({ $0 }) != nil {
            // iOS fetches a home screen icon on its own, without the exception the user accepted for a self-signed
            // certificate, and falls back to a letter: over HTTPS the page carries the icon itself.
            let link = #"<link rel="apple-touch-icon" href="/apple-touch-icon.png">"#
            if body.contains(link), let icon = live?.file("apple-touch-icon.png", platform: nil, unreadable: { _, _ in }) ?? files["apple-touch-icon.png"] {
                let base64 = icon.isBase64 ? icon.body : icon.data.base64EncodedString()
                body = body.replacingOccurrences(of: link, with: #"<link rel="apple-touch-icon" href="data:image/png;base64,\#(base64)">"#)
            }
        }
        if platform == nil, name == "authorize.html" {
            // The sign-in page's files and API are relative to its <base>: the UI's root, or the MCP connector's path
            // on a shared host name (`publicURL`), where the proxy routes nothing else.
            let head = #"<base href="\#(Self.attribute((publicURL(for: request)?.path ?? "") + "/"))">"#
            body = body.range(of: "<head>").map { body.replacingCharacters(in: $0, with: "<head>" + head) } ?? head + body
        }
        if let instance, let platform {
            // Its files are beside it (`app.js` is /plugins/<slug>/app.js), plugin.js reads which instance it is, and
            // i18n.js, first, gives it the UI's language (its own strings are in its i18n.js).
            let head = #"<base href="/plugins/\#(Self.attribute(instance.slug))/"><meta name="homeswift-plugin" data-platform="\#(Self.attribute(platform))" data-name="\#(Self.attribute(instance.name))"><script src="/i18n.js"></script>"#
            body = body.range(of: "<head>").map { body.replacingCharacters(in: $0, with: "<head>" + head) } ?? head + body
        }
        return .data(status: 200, contentType: file.contentType, body: Data(body.utf8))
    }

    /// A file's bytes and ETag; those of the compiled-in files, which never change, are kept.
    private func asset(_ file: WebFile, name: String, platform: String?, live: Bool) -> (Data, String) {
        let key = "\(platform ?? "")/\(name)"
        if !live, let kept = assets.withLockedValue({ $0[key] }), kept.file == file { return (kept.body, kept.tag) }
        let body = file.data
        // FNV-1a: stable across launches, so a restart does not make browsers fetch everything again.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in body { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let tag = "\"\(String(hash, radix: 16))\""
        if !live { assets.withLockedValue { $0[key] = (file, body, tag) } }
        return (body, tag)
    }

    /// The block whose slug this is: its platform, its name, and whether its plugin has a page to show for it (a
    /// running or paused instance of a plugin with pages); without one, its address is the settings view.
    private func pluginPage(slug: String) -> (platform: String, name: String, hasPage: Bool)? {
        let platforms = catalog.host.configuration.platforms
        guard let index = Slug.unique(platforms.map(\.name), fallback: "plugin").firstIndex(of: slug) else { return nil }
        let block = platforms[index]
        let hasPage = catalog.host.registry.entry(for: block.platform)?.hasPages == true
            && catalog.host.platforms.contains { $0.platform == block.platform && $0.name == block.name }
        return (block.platform, block.name, hasPage)
    }

    /// Text for an HTML attribute value in double quotes.
    private static func attribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }

    // MARK: Authentication

    /// Who makes a request, and what they may do: an administrator (`admin`), a user who is not one (`control`:
    /// they see the bridge and control accessories), or a read-only API token (`read`). The role is read from the
    /// users on every request, so a change applies at once.
    struct Caller: Sendable {
        var username: String
        var scope: Scope
        /// The API token the request came with; nil for a browser's session.
        var token: APITokenStore.Token?
        /// The session cookie, for a browser.
        var session: String?
        var isAdmin: Bool { scope == .admin }
    }

    /// The request's caller: by its session cookie, or, with `bearer`, by an `Authorization: Bearer` API token
    /// (which, when present, is the only thing looked at). With `auth: none`, everyone is the administrator.
    /// `refresh` false looks without counting it as activity: neither the session's expiry nor the token's last use.
    func caller(_ request: Request, bearer: Bool, refresh: Bool = true) -> Caller? {
        if configuration.auth == .none { return Caller(username: "local", scope: .admin) }
        if bearer, let header = request.headers["authorization"] {
            guard let token = MCPHTTPServer.bearerToken(header).flatMap({ tokens.validate($0, noteUse: refresh) }) else { return nil }
            return Caller(username: "api-token:\(token.name)", scope: token.scope == .admin ? .admin : .read, token: token)
        }
        guard let session = request.cookies[Self.cookieName], let username = sessions.username(for: session, refresh: refresh),
              let user = users.user(named: username) else { return nil }
        return Caller(username: user.username, scope: user.admin ? .admin : .control, session: session)
    }

    /// What a route needs, after Glass UI's guards: reading the bridge's state and accessories is for anyone signed
    /// in (and read tokens), controlling accessories and the Assistant's chat for any user, and everything else
    /// (config.json, plugins' settings and pages, the log, pairing codes, restarts, users and tokens) for an
    /// administrator. A route not listed needs an administrator.
    static func requiredScope(_ method: HTTPMethod, _ route: [String]) -> Scope {
        switch method {
        case .GET:
            if [["status"], ["accessories"], ["plugins"], ["metrics"], ["metrics", "energy"], ["metrics", "energy", "history"], ["events"], ["assistant"]].contains(route) { return .read }
            if route.count == 3, route[0] == "cameras" { return .read }
            if route.count == 3, route[0] == "accessories", route[2] == "history" { return .read }
            // The rooms, scenes and Quick Controls the Accessories and Status pages show; this browser's Web Push.
            if [["layout"], ["rooms"], ["scenes"], ["scenes", "templates"], ["notifications", "push"]].contains(route) { return .read }
            if route == ["assistant", "chat"] { return .control }
            // Today's digest, as the Status page's widget shows it (writing one is an administrator's); each user's
            // own conversations and appearance.
            if route == ["assistant", "digest"] { return .read }
            if route == ["assistant", "chats"] || route.first == "preferences" { return .control }
            // What an OAuth client asks, on the sign-in page; one's own connected apps.
            if route == ["oauth", "request"] || route == ["account", "apps"] { return .control }
        case .PUT:
            if route.count == 2, route[0] == "accessories" { return .control }
            if route.first == "preferences" { return .control }
        case .POST:
            if route.count == 3, route[0] == "accessories", route[2] == "identify" { return .control }
            if route.count >= 2, route[0] == "assistant", route[1] == "chat" { return .control }
            // Opening one's own earlier conversation; stopping one's own Assistant request.
            if route.count == 4, route[0] == "assistant", route[1] == "chats", route[3] == "open" { return .control }
            if route == ["assistant", "cancel"] { return .control }
            if route.first == "account" { return .control }
            // Running a scene is controlling its accessories (locks and the like still ask first); a browser turns
            // its own notifications on and off.
            if route.count == 3, route[0] == "scenes", route[2] == "run" { return .control }
            // Trying a template or a description, and putting the lights back after any run, is controlling lights;
            // saving a scene is an administrator's.
            if route == ["scenes", "try"] || (route.count == 3 && route[0] == "scenes" && route[2] == "stop") { return .control }
            if route == ["notifications", "push", "subscribe"] || route == ["notifications", "push", "unsubscribe"] { return .control }
            // Approving an OAuth client: the token it gets is capped by the user's role.
            if route == ["oauth", "decision"] { return .control }
        case .DELETE:
            if route == ["assistant", "chat"] { return .control }
            if route.count == 3, route[0] == "assistant", route[1] == "chats" { return .control }
            if route.first == "preferences" { return .control }
            if route.count == 3, route[0] == "account", route[1] == "apps" { return .control }
        default:
            break
        }
        return .admin
    }

    /// Signs a user out everywhere but `keeping` (this browser's session): their other sessions and the apps they
    /// connected (OAuth grants), after a new password, a two-factor change or their removal.
    func signOut(_ username: String, keeping session: String?) {
        sessions.revokeAll(of: username, keeping: session)
        oauth.revokeAll(of: username)
    }

    /// The browser reached this server over HTTPS: its own certificate, or a trusted proxy that says so.
    func isSecure(_ request: Request) -> Bool { configuration.https || request.secure }

    private func cookie(_ token: String?, secure: Bool = false) -> String {
        let value = token ?? ""
        let age = token == nil ? 0 : Int(saturating: sessions.lifetime) ?? 0
        return "\(Self.cookieName)=\(value); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(age)\(configuration.https || secure ? "; Secure" : "")"
    }

    /// A browser sends `Origin` on cross-site and on same-site mutations; it must name this server. Bodies are JSON
    /// (which a form on another site cannot send without asking first), API tokens' too.
    func refuseCrossSite(_ request: Request, checkOrigin: Bool = true) -> Reply? {
        if checkOrigin, let site = request.headers["sec-fetch-site"], site != "same-origin", site != "none" {
            return .error(403, "cross-site request refused")
        }
        if checkOrigin, let origin = request.headers["origin"], let host = request.headers["host"] {
            let url = URL(string: origin)
            let same = url?.host.map(HostName.of) == HostName.of(host) && url?.port == HostName.port(of: host)
            if !same { return .error(403, "origin \(origin) does not match the host") }
        }
        if !request.body.isEmpty, !(request.headers["content-type"] ?? "").lowercased().hasPrefix("application/json"), !Self.acceptsArchive(request) {
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
            let caller = self.caller(request, bearer: false)
            let account = caller.flatMap { users.user(named: $0.username) }
            let state: JSONValue = [
                "mode": .string(configuration.auth.rawValue), "setupNeeded": .bool(configuration.auth == .form && users.isEmpty),
                "authenticated": .bool(caller != nil), "username": caller.map { .string($0.username) } ?? .null, "version": .string(PluginHost.version),
                "liveWebFiles": .bool(live != nil), "sessionDays": .number(Double(configuration.sessionDays)),
                "admin": .bool(caller?.isAdmin == true), "name": account.map { .string($0.name) } ?? .null, "twoFactor": .bool(account?.otpActive == true),
            ]
            return .json(state)
        case (.POST, "setup"):
            if let refused = refuseCrossSite(request) { return refused }
            guard configuration.auth == .form else { return .error(400, "no login is needed") }
            guard let setupCode, users.isEmpty else { return .error(409, AuthError.setupDone.description) }
            guard let (username, password) = credentials(request) else { return .error(400, "username and password are required") }
            let presented = (try? JSONValue(data: request.body))?["setupCode"]?.stringValue ?? ""
            guard credentialChecks.begin(request.remote) else { return Self.checkUnderWay }
            defer { credentialChecks.end(request.remote) }
            let delay = throttle.delay(for: request.remote)
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard Self.setupCodeMatches(presented, setupCode) else {
                throttle.failed(request.remote)
                logger.warning("Web UI setup refused: wrong set-up code", metadata: ["remote": "\(request.remote)"])
                return .error(403, AuthError.wrongSetupCode.description)
            }
            do {
                let users = users
                _ = try await Self.hashing { Result { try users.createFirst(username: username, password: password) } }.get()
            } catch AuthError.setupDone {
                return .error(409, AuthError.setupDone.description)
            } catch {
                return .error(400, "\(error)")
            }
            throttle.succeeded(request.remote)
            logger.info("Web UI account created", metadata: ["username": "\(username)"])
            return .json(["username": .string(username)], headers: ["Set-Cookie": cookie(sessions.create(username: username), secure: request.secure)])
        case (.POST, "login"):
            if let refused = refuseCrossSite(request) { return refused }
            guard configuration.auth == .form else { return .error(400, "no login is needed") }
            guard let (username, password) = credentials(request) else { return .error(400, "username and password are required") }
            // One attempt at a time per address: parallel guesses would all get the delay due before any failed.
            guard credentialChecks.begin(request.remote) else { return Self.checkUnderWay }
            defer { credentialChecks.end(request.remote) }
            let delay = throttle.delay(for: request.remote)
            if delay > .zero { try? await Task.sleep(for: delay) }
            let users = users
            guard let user = await Self.hashing({ users.authenticate(username: username, password: password) }) else {
                throttle.failed(request.remote)
                logger.warning("Web UI login failed", metadata: ["remote": "\(request.remote)"])
                return .error(401, AuthError.badCredentials.description)
            }
            if user.otpActive {
                // Asking for the code is not a failed attempt; a wrong code is, like a wrong password.
                guard let code = (try? JSONValue(data: request.body))?["otp"]?.stringValue, !code.isEmpty else {
                    return .json(["error": "type the code from your authenticator app", "twoFactor": true], status: 412)
                }
                guard users.checkTwoFactor(username: user.username, code: code) else {
                    throttle.failed(request.remote)
                    logger.warning("Web UI login failed: wrong two-factor code", metadata: ["remote": "\(request.remote)"])
                    return .json(["error": .string(AuthError.wrongCode.description), "twoFactor": true], status: 401)
                }
            }
            throttle.succeeded(request.remote)
            return .json(["username": .string(user.username)], headers: ["Set-Cookie": cookie(sessions.create(username: user.username), secure: request.secure)])
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
            if let refused = refuseCrossSite(request) { return refused }
            if let token = request.cookies[Self.cookieName] { sessions.revoke(token) }
            return .json(JSONValue.object([:]), headers: ["Set-Cookie": cookie(nil, secure: request.secure)])
        default:
            return .error(404, "unknown auth action")
        }
    }

    // MARK: API

    private func api(_ route: [String], _ request: Request, caller: Caller) async throws -> Reply {
        let username = caller.username
        // Settings, child bridges, backups, the audit log: Admin.swift.
        if let reply = try await adminAPI(route, request, caller: caller) { return reply }
        let body = request.body.isEmpty ? JSONValue.null : try JSONValue(data: request.body)
        // Approving an OAuth client, and the account's connected apps (OAuthRoutes.swift).
        if let reply = oauthAPI(route, request, body: body, caller: caller) { return reply }
        if route.first == "account" || route.first == "users" || route.first == "tokens" {
            return try await accounts(route, request, body: body, caller: caller)
        }
        if route.count >= 4, route[0] == "plugins" {
            // A plugin page talking to its instance: /api/plugins/<platform>/<name>/<path>.
            let pluginRequest = PluginWebRequest(method: request.method.rawValue, path: route.dropFirst(3).joined(separator: "/"), query: request.query, body: body, user: username)
            guard let response = try await catalog.host.handleWebRequest(platform: route[1], name: route[2], pluginRequest) else {
                return .error(404, "no running instance \"\(route[2])\" of \(route[1])")
            }
            return .json(response.json, status: response.status)
        }
        if route.first == "preferences", let reply = preferencesRoute(Array(route.dropFirst()), request, body: body, username: username) { return reply }
        if route.first == "assistant", route.count >= 2, route[1] != "chat", route[1] != "chats",
           let reply = try await assistantRoute(Array(route.dropFirst()), request, body: body, username: username) { return reply }
        // Rooms, scenes and notifications (HomeRoutes.swift).
        if let reply = try await homeAPI(route, request.method, body: body, username: username, language: Self.language(request)) { return reply }
        switch request.method {
        case .GET:
            switch route {
            case ["status"]:
                return .json(status(username: username, admin: caller.isAdmin))
            case ["assistant"]:
                // Whether pages may offer "Explain": the HomeswiftAiKit block's Assistant, when one works.
                guard let assistant = catalog.host.assistant else { return .json(["enabled": false]) }
                return .json(["enabled": true, "provider": .string(assistant.providerName), "model": .string(assistant.model)])
            case ["assistant", "chat"]:
                guard catalog.host.assistant != nil else { return .error(404, "the Assistant is off: add a HomeswiftAiKit block") }
                // The conversation so far, then the run going on, if any, as it goes.
                return .events(await chat.conversation(for: username, admin: caller.isAdmin).subscribe())
            case ["assistant", "chats"]:
                // The user's own conversations, to open an earlier one.
                return .json(await chat.list(user: username))
            case ["accessories"]:
                // A doorbell's last ring since the bridge started, for its camera card. The list is written straight
                // to bytes: the same JSON as its value would encode to, without the tree.
                let rings = events.lastRings
                var json = JSONBytesWriter(capacity: 64 * 1024)
                json.array { json in
                    for located in catalog.located() {
                        HomeswiftCatalog.writeAccessory(located, detailed: true, lastRing: rings[located.accessory.id].map { $0.formatted(.iso8601) }, to: &json)
                    }
                }
                return .data(status: 200, contentType: "application/json", body: Data(json.bytes))
            case ["plugins"]:
                let platforms = catalog.host.configuration.platforms
                let slugs = Slug.unique(platforms.map(\.name), fallback: "plugin")
                let blocks = platforms.enumerated().map { index, block -> JSONValue in
                    ["index": .number(Double(index)), "platform": .string(block.platform), "name": .string(block.name), "childBridge": .bool(block.childBridge != nil),
                     "system": .bool(HomeswiftCatalog.systemPlatforms.contains(block.platform)), "slug": .string(slugs[index]),
                     "icon": catalog.pluginIcon(platform: block.platform).map(JSONValue.string) ?? .null]
                }
                var plugins = catalog.pluginsJSON().objectValue ?? [:]
                plugins["blocks"] = .array(blocks)
                // The key rule the server seals and redacts by; the settings page reads it from here.
                plugins["secretRule"] = ["keys": .string(Redaction.secretKeyPattern), "except": .string(Redaction.notSecretKeyPattern), "placeholder": .string(Redaction.placeholder)]
                return .json(.object(plugins))
            case ["config"]:
                // Secrets show as the placeholder, as the block views show them; a save that keeps it keeps the stored value.
                let shown = Redaction.redactSecrets(try catalog.readConfig()).encoded(pretty: true)
                return .text(String(decoding: shown, as: UTF8.self), contentType: "application/json")
            case let path where path.count == 4 && path[0] == "config" && path[1] == "block":
                let block = try catalog.readConfig()["platforms"]?.arrayValue?.first { $0["platform"]?.stringValue == path[2] && ($0["name"]?.stringValue ?? path[2]) == path[3] }
                guard let block else { return .error(404, "no block \(path[3]) of \(path[2])") }
                // The page shows secrets as the placeholder; a save that keeps it keeps the stored value.
                return .json(Redaction.redactSecrets(block))
            case ["logs"]:
                // `from` (and `to`, now when left out) as ISO 8601: that span, from the archive on disk; else the latest lines.
                // `accessory`, `bridge` (a device ID, or `all`), `plugin` (a block's name): only the lines about them,
                // picked before the limit.
                // A bridge's lines or a plugin's, not both: the page sends one of the two.
                if request.query["bridge"] != nil, request.query["plugin"] != nil {
                    return .error(400, "bridge and plugin cannot both filter the log")
                }
                let found = request.query["accessory"].flatMap { catalog.find(id: $0) }
                let bridges = catalog.host.bridges
                let chosen = request.query["bridge"].map { id in id == "all" ? bridges : bridges.filter { $0.server.deviceID == id } }
                // A plugin's lines carry its name as their label, as a bridge's own lines carry the bridge's.
                let plugin = request.query["plugin"].flatMap { name in catalog.host.configuration.platforms.contains { $0.name == name } ? [name] : nil }
                let labels = chosen.map { $0.map(\.name) } ?? plugin
                let matching = Self.all(found.map(Self.logMatcher(for:)), labels.map(Self.logMatcher(labels:)))
                // The same, on a row of the log on disk before it is parsed: what the row must hold to match.
                let mayMatch = Self.all(found.flatMap(Self.rowFilter(for:)), labels.flatMap(Self.rowFilter(labels:)))
                if let from = request.query["from"].flatMap(Self.date(iso:)) {
                    let to = request.query["to"].flatMap(Self.date(iso:)) ?? Date()
                    // The archive is read off the concurrency pool: up to a week of files.
                    let logs = catalog.logs
                    let lines = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: logs.lines(from: from, to: to, limit: Self.logLimit, matching: matching, mayMatch: mayMatch)) }
                    }
                    return .data(status: 200, contentType: "application/json", body: Self.logsJSON(lines))
                }
                return .data(status: 200, contentType: "application/json", body: Self.logsJSON(catalog.logs.recent(2000, matching: matching)))
            case ["logs", "download"]:
                // The log as a text file: everything kept (a week at most), or `from` to `to` (ISO 8601).
                let (from, to) = (request.query["from"].flatMap(Self.date(iso:)), request.query["to"].flatMap(Self.date(iso:)))
                let catalog = catalog
                let text = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: catalog.logText(from: from, to: to)) }
                }
                let stamp = Timestamp.iso8601(Date()).prefix(19).replacingOccurrences(of: ":", with: "-")
                return .data(status: 200, contentType: "text/plain; charset=utf-8", body: Data((text.isEmpty ? "" : text + "\n").utf8),
                             headers: ["Content-Disposition": "attachment; filename=\"homeswift-\(stamp).log\""])
            case ["metrics", "values"]:
                // A plugin's reading over time (`series` is `plugin:<platform>:<series>`) from `from` to `to` (the last hour
                // without them), in whole steps: each point with how many readings it averages, the average, the lowest and the highest.
                // Several series separated by commas answer at once, as `series`: each one's points, by its name.
                guard let metrics = catalog.metrics else { return .error(404, "this homeswift records no metrics") }
                guard let query = request.query["series"] else { return .error(400, "series must be a plugin's reading") }
                let names = query.split(separator: ",").map(String.init)
                guard !names.isEmpty, names.count <= 200, names.allSatisfy({ $0.hasPrefix("plugin:") }) else {
                    return .error(400, "series must be a plugin's reading")
                }
                let to = request.query["to"].flatMap(Self.date(iso:)) ?? Date()
                let from = request.query["from"].flatMap(Self.date(iso:)) ?? to.addingTimeInterval(-3600)
                guard from < to else { return .error(400, "from must be before to") }
                let history = metrics.valueHistories(from: from, to: to, series: names)
                func points(_ name: String) -> JSONValue {
                    .array((history.points[name] ?? []).map { point in
                        .object([
                            "t": .number(point.start.timeIntervalSince1970),
                            "count": .number(Double(point.values.count)),
                            "average": point.values.average.map { .number($0) } ?? .null,
                            "low": .number(point.values.low),
                            "high": .number(point.values.high),
                        ])
                    })
                }
                guard query.contains(",") else { return .json(.object(["step": .number(history.step), "points": points(query)])) }
                return .json(.object([
                    "step": .number(history.step),
                    "series": .object(Dictionary(names.map { ($0, points($0)) }, uniquingKeysWith: { first, _ in first })),
                ]))
            case ["metrics", "energy", "history"]:
                // The long-term energy history (the archive: the bridge's own hours and plugins' imports): `period` week
                // (the 8 days to `date`), month (the days of `date`'s month) or year (its months); `date` YYYY-MM-DD,
                // today without it; days and months in `timeZone`.
                guard let metrics = catalog.metrics else { return .error(404, "this homeswift records no metrics") }
                let timeZone = request.query["timeZone"].flatMap(TimeZone.init(identifier:)) ?? .current
                let period = request.query["period"] ?? "week"
                guard let span = Self.energySpan(period: period, date: request.query["date"], timeZone: timeZone) else {
                    return .error(400, "period is week, month or year, and date YYYY-MM-DD")
                }
                let periods = metrics.archive.periods(period == "year" ? .month : .day, from: span.from, to: span.to, timeZone: timeZone)
                return .json(Self.energyHistoryJSON(periods, period: period, earliest: metrics.archive.earliest, timeZone: timeZone,
                                                    imports: catalog.host.energyImportProgress))
            case ["metrics", "energy"]:
                // The Energy section: the readings plugins tag with a role (`EnergyTag`), from `from` to `to` (the last
                // hour without them), and the energy of today and the 7 days before, midnight to midnight in `timeZone`
                // (an IANA name, the server's without one).
                guard let metrics = catalog.metrics else { return .error(404, "this homeswift records no metrics") }
                let to = request.query["to"].flatMap(Self.date(iso:)) ?? Date()
                let from = request.query["from"].flatMap(Self.date(iso:)) ?? to.addingTimeInterval(-3600)
                guard from < to else { return .error(400, "from must be before to") }
                let timeZone = request.query["timeZone"].flatMap(TimeZone.init(identifier:)) ?? .current
                return .json(Self.energyJSON(metrics.energy(from: from, to: to, timeZone: timeZone), timeZone: timeZone))
            case ["metrics"]:
                // `from` and `to` (now when left out) as ISO 8601, the last hour without them; `bridge` (a device ID,
                // or `all`) or `accessory`: whose request and handler durations. Memory and CPU are the process's.
                guard let metrics = catalog.metrics else { return .error(404, "this homeswift records no metrics") }
                let to = request.query["to"].flatMap(Self.date(iso:)) ?? Date()
                let from = request.query["from"].flatMap(Self.date(iso:)) ?? to.addingTimeInterval(-3600)
                guard from < to else { return .error(400, "from must be before to") }
                let series = request.query["accessory"].flatMap { catalog.find(id: $0) }.map { "accessory:\($0.accessory.id)" }
                    ?? request.query["bridge"].flatMap { $0 == "all" ? nil : "bridge:\($0)" } ?? Metrics.allSeries
                return .json(Self.metricsJSON(metrics.history(from: from, to: to, series: series), latest: metrics.latest))
            case ["layout"]:
                return .json(layout.load())
            case ["logs", "settings"]:
                // Whether lines go to disk with their payloads; `available` false without a log on disk (tests, a library).
                let archive = catalog.logs.archive
                return .json(["saveDetails": .bool(archive?.savesDetails ?? false), "available": .bool(archive != nil)])
            case ["events"]:
                // The log is for administrators, as Glass UI's restrictLogsToAdmins.
                return .events(events.stream(logs: caller.isAdmin))
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
                if route.count == 3, route[0] == "cameras" {
                    // A camera card's snapshot or live video: /api/cameras/<accessory id>/snapshot or …/live.
                    return await camera(route[1], route[2], request, username: username)
                }
                if route.count == 3, route[0] == "plugins", route[2] == "schema" {
                    // The runtime's own blocks, the web UI's and the Assistant's, have forms too.
                    let schema = route[1] == UIConfiguration.platform ? UIConfiguration.schemaJSON
                        : route[1] == AIConfiguration.platform ? AIConfiguration.schemaJSON
                        : catalog.host.registry.entry(for: route[1])?.configurationSchemaJSON
                    guard let text = schema else { return .error(404, "no schema for \(route[1])") }
                    return .text(text, contentType: "application/json")
                }
            }
        case .PUT:
            if route == ["layout"] {
                // The Accessories page's order and sizes, the same for every user of the bridge.
                do { return .json(try layout.save(body)) } catch let error as WallLayout.Invalid { return .error(400, error.description) }
            }
            if route == ["logs", "settings"] {
                guard let save = body["saveDetails"]?.boolValue else { return .error(400, "saveDetails (true or false) is required") }
                guard let archive = catalog.logs.archive else { return .error(404, "this homeswift keeps no log on disk") }
                try archive.setSavesDetails(save)
                logger.info(save ? "Log payloads are saved on disk from now on, secrets masked" : "Log payloads are no longer saved on disk", metadata: ["user": "\(username)"])
                return .json(["saveDetails": .bool(save), "available": true])
            }
            if route == ["config"] {
                guard body.objectValue != nil else { return .error(400, "the config must be a JSON object") }
                let result = try await catalog.applyConfig(body, dryRun: false, checkSchemas: request.query["force"] != "true")
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
                return try await replacePlatformBlock(at: route[2], with: body, checkSchemas: request.query["force"] != "true", username: username)
            }
            if route.count == 3, route[0] == "accessories", route[2] == "adaptive-lighting" {
                // { "on": true } resumes the schedule the Home app last sent; false turns it off.
                guard let found = catalog.find(id: route[1]) else { return .error(404, "no accessory \(route[1])") }
                guard let on = body["on"]?.boolValue else { return .error(400, "on (true or false) is required") }
                do {
                    let result = try catalog.setAdaptiveLighting(found, service: body["service"]?.stringValue, on: on)
                    logger.info("Web UI turned Adaptive Lighting \(on ? "on" : "off")", metadata: ["user": "\(username)", "accessory": "\(found.accessory.name)"])
                    return .json(result)
                } catch let error as CatalogError {
                    return .error(409, error.description)
                }
            }
            if route.count == 4, route[0] == "config", route[1] == "block" {
                // A block by platform and name, for a plugin's own page: its read-modify-write never needs
                // the whole file, nor an index that may have moved.
                guard let replacement = body.objectValue, body["platform"]?.stringValue == route[2] else { return .error(400, "the block must keep its platform") }
                let result: JSONValue
                do {
                    // A plugin's own page, or pausing: the plugin's code knows its block, and its schema describes the form.
                    result = try await catalog.editBlock(platform: route[2], name: route[3], create: false, dryRun: false, checkSchemas: false) { $0 = replacement }
                } catch let error as CatalogError {
                    return .error(404, error.description)
                }
                noteConfigChange(by: username)
                return .json(result)
            }
        case .POST:
            if route == ["updates", "check"] {
                guard let releases = options.releases else { return .error(503, "update checking is unavailable") }
                await releases.check()
                return .json(releases.json() ?? .null)
            }
            if route == ["config", "check-port"] {
                guard let candidate = body["port"]?.intValue, (1...65535).contains(candidate) else {
                    return .error(400, "port must be an integer from 1 to 65535")
                }
                let host = body["host"]?.stringValue ?? "0.0.0.0"
                // The web UI's own port is held by this server, on whatever address: the restart that applies a new
                // address releases it first, so a probe here would only find this server.
                if body["service"]?.stringValue != "bridge", candidate == port {
                    return .json(["available": true, "current": .bool(host == configuration.host)])
                }
                do {
                    let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                        .childChannelInitializer { channel in channel.close() }
                        .bind(host: host, port: candidate).get()
                    try await probe.close().get()
                    return .json(["available": true, "current": false])
                } catch {
                    return .json(["available": false, "current": false])
                }
            }
            if route == ["assistant", "config"] {
                // Describe your setup: a block written from the plugin's config.schema.json and a request in plain
                // language, for the settings form to show as a change to review; nothing is saved here.
                guard let assistant = catalog.host.assistant else { return .error(404, "the Assistant is off: add a HomeswiftAiKit block") }
                guard let platform = body["platform"]?.stringValue, let entry = catalog.host.registry.entry(for: platform),
                      let schemaText = entry.configurationSchemaJSON else { return .error(404, "that plugin has no config.schema.json") }
                guard let wish = body["request"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !wish.isEmpty else {
                    return .error(400, "say what the block should do")
                }
                if let refused = limitAssistant(for: username) { return refused }
                let schema = try JSONValue(data: Data(schemaText.utf8))
                var current = body["current"]
                if case .object(var block)? = current { block["platform"] = nil; current = .object(block) }
                do {
                    let suggestion = try await assistant.forUser(username)
                        .withContext(PluginContext.assistantContext(name: entry.name, platform: platform, background: entry.assistantBackground))
                        .speaking(Self.language(request))
                        .generateConfiguration(request: wish, schema: schema, current: current == .null ? nil : current, pluginName: entry.name, onChunk: nil)
                    return .json(["config": suggestion.config, "explanation": .string(suggestion.explanation), "model": .string(assistant.model)])
                } catch {
                    return .error(502, "the Assistant did not answer: \(error)")
                }
            }
            if route == ["files"] {
                return try storeFile(body, username: username)
            }
            if route.count == 4, route[0] == "config", route[1] == "block" {
                // A new, empty block, for a plugin whose own page sets it up (pairing a TV, finding lights).
                guard (try catalog.readConfig()["platforms"]?.arrayValue ?? []).allSatisfy({ $0["platform"]?.stringValue != route[2] || ($0["name"]?.stringValue ?? route[2]) != route[3] }) else {
                    return .error(409, "there is already a block \(route[3]) of \(route[2])")
                }
                let result = try await catalog.editBlock(platform: route[2], name: route[3], dryRun: false, checkSchemas: false) { _ in }
                noteConfigChange(by: username)
                return .json(result, status: 201)
            }
            if route.count == 4, route[0] == "assistant", route[1] == "chats", route[3] == "open" {
                guard await chat.open(user: username, id: route[2]) else { return .error(404, "no such conversation") }
                return .json(JSONValue.object([:]))
            }
            if route.first == "assistant", route.count >= 2, route[1] == "chat" {
                return try await chatAction(Array(route.dropFirst(2)), body: body, caller: caller, language: Self.language(request))
            }
            if route == ["logs", "truncate"] {
                // For administrators, as the MCP tool is admin-scoped.
                guard caller.isAdmin else { return .error(403, "only an administrator can empty the log") }
                return .json(catalog.truncateLogs(by: "web UI user \(username)"))
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
            if route == ["assistant", "chat"] {
                await chat.reset(user: username)
                return .json(JSONValue.object([:]))
            }
            if route.count == 3, route[0] == "assistant", route[1] == "chats" {
                guard await chat.remove(user: username, id: route[2]) else { return .error(404, "no such conversation") }
                return .json(JSONValue.object([:]))
            }
            if route.count == 3, route[0] == "config", route[1] == "platforms" {
                return try await replacePlatformBlock(at: route[2], with: nil, username: username)
            }
        default:
            break
        }
        return .error(404, "unknown API route")
    }

    /// A certificate or a private key dropped on a settings form: checked, kept next to config.json under
    /// `files/`, owner-only, and answered with its path for the form's field. PEM text only.
    private func storeFile(_ body: JSONValue, username: String) throws -> Reply {
        guard let field = body["field"]?.stringValue, !field.isEmpty, field.count <= 64, field.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return .error(400, "a field name is required")
        }
        guard let content = body["content"]?.stringValue, content.utf8.count <= 256 * 1024 else { return .error(400, "the file is missing or too large") }
        guard content.contains("-----BEGIN ") else { return .error(400, "This is not a PEM file: a certificate or a key starts with -----BEGIN.") }
        let isKey = content.contains("PRIVATE KEY-----")
        // The field says which it wants: a key dropped on the certificate's field would keep HTTPS from starting.
        let wantsKey = field.lowercased().contains("key")
        guard isKey == wantsKey else {
            return .error(400, wantsKey ? "This is a certificate; drop the private key here." : "This is a private key; drop the certificate here.")
        }
        do {
            if isKey { _ = try NIOSSLPrivateKey(bytes: Array(content.utf8), format: .pem) } else { _ = try NIOSSLCertificate.fromPEMBytes(Array(content.utf8)) }
        } catch {
            return .error(400, isKey ? "This private key cannot be read (an encrypted key needs its passphrase removed)." : "This certificate cannot be read.")
        }
        let url = directory.appendingPathComponent("files").appendingPathComponent("\(field).pem")
        try OwnerOnlyFile.write(Data(content.utf8), to: url)
        logger.info("Web UI stored a file", metadata: ["user": "\(username)", "file": "\(url.lastPathComponent)", "kind": "\(isKey ? "private key" : "certificate")"])
        return .json(["path": .string(url.path), "kind": .string(isKey ? "key" : "certificate")])
    }

    /// Counts an Assistant request for the user: nil when there is room, else a 429 with when to try again.
    func limitAssistant(for username: String) -> Reply? {
        let result = options.assistantRateLimiter.consume(username)
        guard !result.allowed else { return nil }
        logger.warning("Web UI Assistant request refused: rate limit", metadata: ["user": "\(username)"])
        return .json(["error": .string(SlidingWindowRateLimiter.refusal)], status: 429, headers: ["Retry-After": "\(max(1, Int(result.retryAfter.rounded(.up))))"])
    }

    // MARK: Accounts, users and API tokens

    /// `account/…`: the signed-in user's own password and two-factor authentication. `users/…` and `tokens/…`:
    /// an administrator's, as Glass UI's Users page. A browser's session only: an API token names no account,
    /// and cannot mint or revoke tokens (Glass UI's UserSessionGuard).
    private func accounts(_ route: [String], _ request: Request, body: JSONValue, caller: Caller) async throws -> Reply {
        guard configuration.auth == .form else { return .error(400, "this web UI has no accounts: its auth is none") }
        guard caller.token == nil, let user = users.user(named: caller.username) else {
            return .error(403, "an API token cannot manage accounts or tokens; sign in to the web UI")
        }
        switch (request.method, route) {
        case (.POST, ["account", "password"]):
            // The signed-in user's own password: the current one first, slowed down after mistakes like a login.
            guard let current = body["current"]?.stringValue, let new = body["new"]?.stringValue else { return .error(400, "the current and the new password are required") }
            let users = users
            if let refused = await checkingPassword(request, user: user, { try users.changePassword(username: user.username, current: current, new: new) }) { return refused }
            signOut(user.username, keeping: caller.session)
            logger.info("Web UI password changed; the user's other sessions are signed out", metadata: ["user": "\(user.username)"])
            return .json(["changed": true])
        case (.POST, ["account", "otp", "setup"]):
            // A new secret, shown once as text, as an otpauth:// URI and as its QR code; it waits for a code.
            let secret: Data
            do { secret = try users.beginTwoFactor(username: user.username) } catch let error as AuthError { return .error(409, error.description) }
            // The app lists it under the bridge's name, when the QR code can carry it; else plain Homeswift. A QR code
            // too long for the encoder (a very long username) leaves the key and the link.
            let uris = [TOTP.uri(secret: secret, account: user.username, issuer: "Homeswift (\(catalog.host.configuration.bridge.name))"),
                        TOTP.uri(secret: secret, account: user.username, issuer: "Homeswift")]
            let shown = uris.lazy.compactMap { uri in (try? QRCode(uri)).map { (uri, $0.svg()) } }.first
            return .json(["secret": .string(Base32.encode(secret)), "uri": .string(shown?.0 ?? uris[0]), "qr": shown.map { .string($0.1) } ?? .null])
        case (.POST, ["account", "otp", "activate"]):
            guard let code = body["code"]?.stringValue else { return .error(400, "the code is required") }
            guard credentialChecks.begin(request.remote) else { return Self.checkUnderWay }
            defer { credentialChecks.end(request.remote) }
            let delay = throttle.delay(for: request.remote)
            if delay > .zero { try? await Task.sleep(for: delay) }
            do {
                try users.activateTwoFactor(username: user.username, code: code)
            } catch AuthError.wrongCode {
                throttle.failed(request.remote)
                return .error(400, AuthError.wrongCode.description)
            } catch let error as AuthError {
                return .error(409, error.description)
            }
            throttle.succeeded(request.remote)
            // Sessions opened without the code end, as Glass UI's; this one stays.
            signOut(user.username, keeping: caller.session)
            logger.info("Web UI two-factor authentication turned on; the user's other sessions are signed out", metadata: ["user": "\(user.username)"])
            return .json(["twoFactor": true])
        case (.POST, ["account", "otp", "disable"]):
            guard let password = body["password"]?.stringValue else { return .error(400, "the password is required") }
            let users = users
            if let refused = await checkingPassword(request, user: user, { try users.disableTwoFactor(username: user.username, password: password) }) { return refused }
            signOut(user.username, keeping: caller.session)
            logger.info("Web UI two-factor authentication turned off; the user's other sessions are signed out", metadata: ["user": "\(user.username)"])
            return .json(["twoFactor": false])
        default:
            break
        }
        // Users and tokens: an administrator's (requiredScope already said so; checked again here).
        guard user.admin else { return .error(403, "only an administrator can do this") }
        switch (request.method, route) {
        case (.GET, ["users"]):
            return .json(.array(users.users.map { Self.userJSON($0, you: $0.username == user.username) }))
        case (.POST, ["users"]):
            guard let username = body["username"]?.stringValue, let password = body["password"]?.stringValue else { return .error(400, "a username and a password are required") }
            let created: UserStore.User
            let (users, name, admin) = (users, body["name"]?.stringValue, body["admin"]?.boolValue ?? false)
            do {
                created = try await Self.hashing { Result { try users.create(username: username, password: password, name: name, admin: admin) } }.get()
            } catch AuthError.userExists {
                return .error(409, AuthError.userExists.description)
            } catch let error as AuthError {
                return .error(400, error.description)
            }
            logger.info("Web UI user added", metadata: ["user": "\(created.username)", "admin": "\(created.admin)", "by": "\(user.username)"])
            return .json(Self.userJSON(created, you: false), status: 201)
        case (.PUT, let path) where path.count == 2 && path[0] == "users":
            let password = body["password"]?.stringValue
            let updated: UserStore.User
            let (users, name, admin) = (users, body["name"]?.stringValue, body["admin"]?.boolValue)
            do {
                updated = try await Self.hashing { Result { try users.update(username: path[1], name: name, admin: admin, password: password) } }.get()
            } catch AuthError.noSuchUser {
                return .error(404, AuthError.noSuchUser.description)
            } catch let error as AuthError {
                return .error(400, error.description)
            }
            // A new password ends the user's sessions (this browser's stays when it is their own).
            if password != nil { signOut(updated.username, keeping: caller.session) }
            logger.info("Web UI user changed", metadata: ["user": "\(updated.username)", "admin": "\(updated.admin)", "password": "\(password != nil ? "reset" : "kept")", "by": "\(user.username)"])
            return .json(Self.userJSON(updated, you: updated.username == user.username))
        case (.DELETE, let path) where path.count == 2 && path[0] == "users":
            let target = users.user(named: path[1])?.username ?? path[1]
            do {
                try users.delete(username: target)
            } catch AuthError.noSuchUser {
                return .error(404, AuthError.noSuchUser.description)
            } catch let error as AuthError {
                return .error(400, error.description)
            }
            signOut(target, keeping: nil)
            // Their conversations and choices go with them: a later account of the same name starts afresh.
            await chat.forget(user: target)
            preferences.forget(user: target)
            logger.info("Web UI user removed", metadata: ["user": "\(target)", "by": "\(user.username)"])
            return .json(JSONValue.object([:]))
        case (.GET, ["tokens"]):
            return .json(.array(tokens.tokens.map(Self.tokenJSON)))
        case (.POST, ["tokens"]):
            guard let scope = body["scope"]?.stringValue.flatMap(APITokenStore.Scope.init(rawValue:)) else { return .error(400, "the scope is read or admin") }
            let days = body["expiresInDays"]?.nonNull
            guard days == nil || days?.intValue != nil else { return .error(400, AuthError.invalidExpiry.description) }
            do {
                let (token, value) = try tokens.create(name: body["name"]?.stringValue ?? "", scope: scope, expiresInDays: days?.intValue, createdBy: user.username)
                logger.info("Web UI API token created", metadata: ["token": "\(token.name)", "scope": "\(token.scope.rawValue)", "by": "\(user.username)"])
                var json = Self.tokenJSON(token).objectValue ?? [:]
                json["token"] = .string(value)
                return .json(.object(json), status: 201)
            } catch let error as AuthError {
                return .error(400, error.description)
            }
        case (.DELETE, let path) where path.count == 2 && path[0] == "tokens":
            do {
                let revoked = try tokens.revoke(id: path[1])
                logger.info("Web UI API token revoked", metadata: ["token": "\(revoked.name)", "by": "\(user.username)"])
                return .json(JSONValue.object([:]))
            } catch {
                return .error(404, AuthError.noSuchToken.description)
            }
        default:
            return .error(404, "unknown API route")
        }
    }

    /// Runs a change that checks the user's password, slowed down after mistakes like a login; a refusal's reply.
    private func checkingPassword(_ request: Request, user: UserStore.User, _ change: @escaping @Sendable () throws -> Void) async -> Reply? {
        guard credentialChecks.begin(request.remote) else { return Self.checkUnderWay }
        defer { credentialChecks.end(request.remote) }
        let delay = throttle.delay(for: request.remote)
        if delay > .zero { try? await Task.sleep(for: delay) }
        do {
            try await Self.hashing { Result { try change() } }.get()
        } catch AuthError.wrongPassword {
            throttle.failed(request.remote)
            logger.warning("Web UI change refused: wrong password", metadata: ["user": "\(user.username)", "remote": "\(request.remote)"])
            return .error(403, AuthError.wrongPassword.description)
        } catch {
            return .error(400, "\(error)")
        }
        throttle.succeeded(request.remote)
        return nil
    }

    static func userJSON(_ user: UserStore.User, you: Bool) -> JSONValue {
        ["username": .string(user.username), "name": .string(user.name), "admin": .bool(user.admin), "twoFactor": .bool(user.otpActive),
         "created": .string(Timestamp.iso8601(user.created)), "you": .bool(you)]
    }

    static func tokenJSON(_ token: APITokenStore.Token) -> JSONValue {
        ["id": .string(token.id), "name": .string(token.name), "scope": .string(token.scope.rawValue), "created": .string(Timestamp.iso8601(token.created)),
         "expires": token.expires.map { .string(Timestamp.iso8601($0)) } ?? .null, "lastUsed": token.lastUsed.map { .string(Timestamp.iso8601($0)) } ?? .null,
         "createdBy": token.createdBy.map(JSONValue.string) ?? .null]
    }

    /// `POST assistant/chat` sends a message and streams the run; `…/confirm` answers a confirmation card;
    /// `…/stop` stops the run.
    private func chatAction(_ action: [String], body: JSONValue, caller: Caller, language: String?) async throws -> Reply {
        let username = caller.username
        let conversation = await chat.conversation(for: username, admin: caller.isAdmin)
        switch action {
        case []:
            guard let assistant = catalog.host.assistant else { return .error(404, "the Assistant is off: add a HomeswiftAiKit block") }
            guard let text = body["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .error(400, "a message is required") }
            guard text.count <= 4000 else { return .error(400, "the message is too long: 4000 characters at most") }
            let page = body["page"]?.stringValue.map { String($0.prefix(100)) }
            if conversation.isRunning { return .error(409, "the Assistant is still answering; stop it first") }
            if let refused = limitAssistant(for: username) { return refused }
            guard conversation.send(text, page: page, user: username, assistant: assistant.forUser(username).speaking(language), logger: logger) else {
                return .error(409, "the Assistant is still answering; stop it first")
            }
            return .events(conversation.subscribe())
        case ["confirm"]:
            guard let id = body["id"]?.stringValue, let allow = body["allow"]?.boolValue else { return .error(400, "id and allow are required") }
            guard conversation.answer(id, allow: allow) else { return .error(404, "nothing waits for that answer") }
            return .json(JSONValue.object([:]))
        case ["stop"]:
            conversation.stop()
            return .json(JSONValue.object([:]))
        default:
            return .error(404, "unknown API route")
        }
    }

    /// The setup codes (the pairing QR codes) only for an administrator, as Glass UI's `/server/pairing`.
    private func status(username: String, admin: Bool) -> JSONValue {
        var status = catalog.statusJSON(includePairing: admin).objectValue ?? [:]
        status["username"] = .string(username)
        status["system"] = HomeswiftCatalog.systemJSON()
        if let update = options.releases?.json() { status["update"] = update }
        return .object(status)
    }

    /// Replaces (or appends, at the next index) a platform block; nil removes it.
    private struct NoSuchBlock: Error { let index: Int }

    private func replacePlatformBlock(at indexText: String, with block: JSONValue?, checkSchemas: Bool = true, username: String) async throws -> Reply {
        guard let index = Int(indexText) else { return .error(400, "bad index") }
        do {
            let result = try await catalog.editPlatforms(dryRun: false, checkSchemas: checkSchemas) { platforms in
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

    /// The most lines one time range answers with: the latest of them.
    static let logLimit = 10_000

    /// What names an accessory in a line, lower-cased: its name, id, address (`ElgatoKeyLights:3C:6A:…`) and serial.
    static func logTerms(for found: HomeswiftCatalog.Located) -> [String] {
        let accessory = found.accessory
        let id = accessory.id
        let address = id.firstIndex(of: ":").map { String(id[id.index(after: $0)...]) }.flatMap(MACAddress.canonical)
        let serial = accessory.information[.serialNumber]?.value.stringValue
        return [accessory.name, id, address, serial].compactMap { $0?.lowercased() }.filter { $0.count >= 3 }
    }

    /// Whether a row of the log on disk, its raw JSON text, could be about the accessory: it holds one of its terms.
    /// The row escapes only quotes, backslashes and control characters, so a term without them reads the same in
    /// it; nil (no shortcut) when a term has one.
    static func rowFilter(for found: HomeswiftCatalog.Located) -> (@Sendable (String) -> Bool)? {
        let terms = logTerms(for: found)
        guard !terms.contains(where: { $0.contains("\"") || $0.contains("\\") }) else { return nil }
        // ASCII terms (nearly always) are searched byte by byte, rows with an emoji or an accent too.
        let ascii = terms.filter(TextSearch.isASCII), other = terms.filter { !TextSearch.isASCII($0) }
        return { row in TextSearch.containsAny(row, asciiCaseless: ascii) || other.contains { TextSearch.contains(row, caseless: $0) } }
    }

    /// Whether a row could be a line with one of these labels (a bridge's own lines, a plugin's): it holds
    /// `"n":"<label>"` (nil for a label to escape).
    static func rowFilter(labels: [String]) -> (@Sendable (String) -> Bool)? {
        let keys = labels.map { #""n":"\#($0)""# }
        guard !labels.contains(where: { $0.contains("\"") || $0.contains("\\") || !TextSearch.isASCII($0) }) else { return nil }
        return { row in keys.contains { TextSearch.contains(row, ascii: $0) } }
    }

    /// Both filters when there are two, the one there is, or none.
    static func all<Value>(_ first: (@Sendable (Value) -> Bool)?, _ second: (@Sendable (Value) -> Bool)?) -> (@Sendable (Value) -> Bool)? {
        switch (first, second) {
        case let (first?, second?): { first($0) && second($0) }
        case let (first, second): first ?? second
        }
    }

    /// Whether a log line is about an accessory: the lines naming it, its id, the address its id carries or its
    /// serial number. The page filters live lines the same way.
    static func logMatcher(for found: HomeswiftCatalog.Located) -> @Sendable (LogBuffer.Line) -> Bool {
        let terms = logTerms(for: found)
        // A lower-cased term that is not ASCII never occurs in an ASCII line.
        let asciiTerms = terms.filter(TextSearch.isASCII)
        return { line in
            // Inside its payload too: a device often appears there only, by its id or address.
            let haystack = line.searchable
            // ASCII lines, nearly all of them, are searched in place, ignoring case; others are lowered first.
            if TextSearch.isASCII(haystack) { return asciiTerms.contains { TextSearch.contains(haystack, caseless: $0) } }
            let lowered = haystack.lowercased()
            return terms.contains { lowered.contains($0) }
        }
    }

    /// The lines with one of these labels: a bridge's own server's (connections, pairings, controllers), a plugin's.
    static func logMatcher(labels: [String]) -> @Sendable (LogBuffer.Line) -> Bool {
        let labels = Set(labels)
        return { labels.contains($0.label) }
    }

    /// An ISO 8601 date and time, with or without fractional seconds (`Date.toISOString()` sends them).
    static func date(iso text: String) -> Date? {
        isoParsers.date(text)
    }

    private static let isoParsers = ISOParsers()

    /// The two formatters `date(iso:)` tries, made once: making them cost more than the rest of a log range's request.
    /// Formatters are not Sendable, so one caller at a time uses them.
    private final class ISOParsers: @unchecked Sendable {
        private let lock = NSLock()
        private let fractional = ISO8601DateFormatter()
        private let plain = ISO8601DateFormatter()

        init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain.formatOptions = [.withInternetDateTime]
        }

        func date(_ text: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return fractional.date(from: text) ?? plain.date(from: text)
        }
    }

    /// A history for the Status page's charts: `step` in seconds, then a point per step with something recorded,
    /// its durations in milliseconds.
    static func metricsJSON(_ history: Metrics.History, latest: (memory: UInt64?, cpu: Double?)) -> JSONValue {
        func durations(_ durations: Metrics.Durations) -> JSONValue {
            guard let average = durations.average else { return .null }
            return ["count": .number(Double(durations.count)), "average": .number(average), "longest": .number(durations.longest)]
        }
        let points = history.points.map { point -> JSONValue in
            ["time": .string(Timestamp.iso8601(point.start)), "memory": point.memory.map { .number(Double($0)) } ?? .null,
             "cpu": point.cpu.map(JSONValue.number) ?? .null, "requests": durations(point.requests), "handlers": durations(point.handlers)]
        }
        return ["step": .number(history.step), "points": .array(points),
                "latest": ["memory": latest.memory.map { .number(Double($0)) } ?? .null, "cpu": latest.cpu.map(JSONValue.number) ?? .null]]
    }

    /// The Energy section: the roles some series has; the power chart's points (`t` in seconds, a role's watts, summed
    /// across devices); a line of battery levels per device; and each day's energy in kWh, newest first (`date` the
    /// day in `timeZone`, `solarShare` 0 to 1 or null).
    static func energyJSON(_ report: EnergyReport, timeZone: TimeZone) -> JSONValue {
        let roles = EnergyRole.allCases.filter(report.roles.contains)
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        let kWh = { (value: Double) in JSONValue.number((value * 1000).rounded() / 1000) }
        return [
            "roles": .array(roles.map { .string($0.rawValue) }),
            "step": .number(report.step),
            "power": .array(report.power.map { point in
                var object: [String: JSONValue] = ["t": .number(point.start.timeIntervalSince1970)]
                for (role, watts) in point.watts { object[role.rawValue] = .number((watts * 10).rounded() / 10) }
                if point.imported { object["imported"] = .bool(true) }
                return .object(object)
            }),
            "levels": .array(report.levels.map { level in
                ["series": .string(level.series), "device": .string(level.device),
                 "points": .array(level.points.map { .array([.number($0.start.timeIntervalSince1970), .number(($0.percent * 10).rounded() / 10)]) })]
            }),
            "days": .array(report.days.map { one in
                ["date": .string(day.string(from: one.start)), "minutes": .number(Double(one.minutes)),
                 "solar": kWh(one.solar), "home": kWh(one.home), "gridImport": kWh(one.gridImport), "gridExport": kWh(one.gridExport),
                 "batteryCharge": kWh(one.batteryCharge), "batteryDischarge": kWh(one.batteryDischarge), "homeFromSolar": kWh(one.homeFromSolar),
                 "solarShare": one.solarShare.map { .number(($0 * 1000).rounded() / 1000) } ?? .null]
            }),
        ]
    }

    /// The span of a history `period` around `date` (YYYY-MM-DD, today without it) in `timeZone`: the 8 days to it, its
    /// month, or its year; nil for anything else.
    static func energySpan(period: String, date: String?, timeZone: TimeZone, now: Date = Date()) -> (from: Date, to: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day: Date
        if let date {
            let parts = date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]),
                  let parsed = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
            day = parsed
        } else {
            day = calendar.startOfDay(for: now)
        }
        switch period {
        case "week": return (calendar.date(byAdding: .day, value: -7, to: day)!, day)
        case "month":
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: day))!
            return (start, calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!)
        case "year":
            let start = calendar.date(from: calendar.dateComponents([.year], from: day))!
            return (start, calendar.date(byAdding: DateComponents(year: 1, day: -1), to: start)!)
        default: return nil
        }
    }

    /// The history's bars: each day (`date` YYYY-MM-DD) or month (YYYY-MM) with its kWh, null where nothing is known (an
    /// import has no grid or battery), where the home's use came from, and how many hours were recorded or imported.
    /// `imports`: where each plugin's import stands (`state` running, done or failed; `done` of `total` steps; `from`
    /// and `through` the days it covers; `updated`, ISO 8601; `message` why it failed).
    static func energyHistoryJSON(_ periods: [EnergyPeriod], period: String, earliest: Date?, timeZone: TimeZone,
                                  imports: [EnergyImportProgress] = []) -> JSONValue {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        let kWh = { (wattHours: Double?) in wattHours.map { JSONValue.number(($0).rounded() / 1000) } ?? .null }
        let label = { (date: Date, monthly: Bool) -> JSONValue in
            format.dateFormat = monthly ? "yyyy-MM" : "yyyy-MM-dd"
            return .string(format.string(from: date))
        }
        return [
            "period": .string(period),
            "earliest": earliest.map { label($0, false) } ?? .null,
            "imports": .array(imports.map { one in
                [
                    "name": .string(one.name), "state": .string(one.state.rawValue),
                    "done": .number(Double(one.done)), "total": .number(Double(one.total)),
                    "from": one.from.map { label($0, false) } ?? .null, "through": one.through.map { label($0, false) } ?? .null,
                    "updated": .string(Timestamp.iso8601(one.updated)), "message": one.message.map(JSONValue.string) ?? .null,
                ]
            }),
            "bars": .array(periods.map { one in
                let flows = one.flows
                return [
                    "date": label(one.start, period == "year"),
                    "solar": kWh(flows.solar), "home": kWh(flows.home), "homeFromSolar": kWh(flows.homeFromSolar),
                    "homeFromBattery": kWh(one.homeFromBattery), "homeFromGrid": kWh(one.homeFromGrid), "homeNotSplit": kWh(one.homeNotSplit),
                    "gridImport": kWh(flows.gridImport), "gridExport": kWh(flows.gridExport),
                    "batteryCharge": kWh(flows.batteryCharge), "batteryDischarge": kWh(flows.batteryDischarge),
                    "solarShare": one.solarShare.map { .number(($0 * 1000).rounded() / 1000) } ?? .null,
                    "recordedHours": .number(Double(one.recordedHours)), "importedHours": .number(Double(one.importedHours)),
                ]
            }),
        ]
    }

    /// A line for the Logs page; `details`, the JSON taken out of it, as compact text for the page to expand.
    /// Lines as the JSON array of their `logJSON`, the same bytes, written directly: a dictionary per line and its
    /// sorted keys cost most of an answer of thousands of lines.
    static func logsJSON(_ lines: [LogBuffer.Line]) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(lines.count * 160 + 2)
        bytes.append(UInt8(ascii: "["))
        for (index, line) in lines.enumerated() {
            if index > 0 { bytes.append(UInt8(ascii: ",")) }
            // Keys in the order encoded() sorts them.
            bytes.append(UInt8(ascii: "{"))
            if let details = line.details {
                bytes.append(contentsOf: #""details":"#.utf8)
                JSONValue.appendQuoted(details, to: &bytes)
                bytes.append(UInt8(ascii: ","))
            }
            bytes.append(contentsOf: #""label":"#.utf8)
            JSONValue.appendQuoted(line.label, to: &bytes)
            bytes.append(contentsOf: #","level":"#.utf8)
            JSONValue.appendQuoted(line.level.rawValue, to: &bytes)
            bytes.append(contentsOf: #","text":"#.utf8)
            JSONValue.appendQuoted(line.text, to: &bytes)
            bytes.append(contentsOf: #","time":"#.utf8)
            JSONValue.appendQuoted(Timestamp.iso8601(line.date), to: &bytes)
            bytes.append(UInt8(ascii: "}"))
        }
        bytes.append(UInt8(ascii: "]"))
        return Data(bytes)
    }

    static func logJSON(_ line: LogBuffer.Line) -> JSONValue {
        var json: [String: JSONValue] = ["time": .string(Timestamp.iso8601(line.date)), "level": .string(line.level.rawValue), "label": .string(line.label), "text": .string(line.text)]
        if let details = line.details { json["details"] = .string(details) }
        return .object(json)
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
    /// Each open stream, and whether it gets log lines (an administrator's).
    private let listeners = NIOLockedValueBox<[UUID: (continuation: AsyncStream<Data>.Continuation, logs: Bool)]>([:])
    private let observations = NIOLockedValueBox<[Observation]?>(nil)
    private let rings = NIOLockedValueBox<[String: Date]>([:])

    /// When each doorbell last rang, by accessory id, since the bridge started.
    var lastRings: [String: Date] { rings.withLockedValue { $0 } }

    func attach(to catalog: HomeswiftCatalog) {
        guard observations.withLockedValue({ $0 == nil }) else { return }
        // The host's feed covers the servers it adds later too (a new TV, a child bridge from a live reload).
        let changes = catalog.host.observeChanges { [self] accessory, characteristic, value in
            if characteristic.type.uuid == CharacteristicType.programmableSwitchEvent.uuid, value != .null,
               accessory.services.contains(where: { $0.type.uuid == ServiceType.doorbell.uuid && $0.characteristics.contains { $0 === characteristic } }) {
                rings.withLockedValue { $0[accessory.id] = Date() }
            }
            // Nothing is looked up while no page listens: `payload` is only built for a listener.
            broadcast(event: "accessory", payload: {
                let service = accessory.services.first { $0.characteristics.contains { $0 === characteristic } }
                var payload: [String: JSONValue] = [
                    "id": .string(accessory.id), "characteristic": .string(characteristic.type.name), "value": characteristic.isConfidential ? .null : HomeswiftCatalog.json(value),
                    // Whether the device answers: No Response on its card follows it (`Accessory.isUnavailable`).
                    "unavailable": .bool(accessory.isUnavailable),
                ]
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
        // The rooms or the wall changed (a page, the chat, an MCP client): the Accessories page draws them again.
        let layout = catalog.home.observeLayout { [self] in broadcast(event: "layout", payload: [:]) }
        observations.withLockedValue { $0 = [changes, log, layout] }
    }

    func stream(logs: Bool = true) -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(500)) { continuation in
            listeners.withLockedValue { $0[id] = (continuation, logs) }
            continuation.yield(SSE.frame(event: "hello", data: "{}"))
            continuation.onTermination = { _ in _ = self.listeners.withLockedValue { $0.removeValue(forKey: id) } }
        }
    }

    /// Nothing is encoded while no page listens: this runs inside every log call.
    func broadcast(event: String, payload: @autoclosure () -> JSONValue) {
        let isLog = event == "log"
        let targets = listeners.withLockedValue { $0.values.filter { !isLog || $0.logs }.map(\.continuation) }
        guard !targets.isEmpty else { return }
        let data = SSE.frame(event: event, data: payload().text())
        for continuation in targets { continuation.yield(data) }
    }

    func close() {
        observations.withLockedValue { $0 ?? [] }.forEach { $0.cancel() }
        for listener in listeners.withLockedValue({ Array($0.values) }) { listener.continuation.finish() }
    }
}

/// Collects one HTTP request, hands it to the server, writes the reply.
final class UIRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    /// What a signed-in caller may send; a backup to restore, an administrator's, is the one larger body: an
    /// archive, up to InstanceBackups.maxArchiveSize.
    static let bodyLimit = 4 * 1024 * 1024
    /// What anyone else may send: a sign-in's JSON. Bodies are kept before the route checks anything, so a client
    /// with no session cannot make the bridge hold megabytes per connection.
    static let anonymousBodyLimit = 64 * 1024

    /// Sent through the pipeline once an answer is written, so the idle timeout applies again.
    struct ResponseDone: Sendable {}

    let server: UIServer
    private var head: HTTPRequestHead?
    private var headers: [String: String] = [:]
    private var body = Data()
    private var limit = UIRequestHandler.anonymousBodyLimit
    private var truncated = false
    /// Answers under way: while there is one, a silent connection is waiting for it (a stream, a slow Assistant).
    private var answering = 0

    init(server: UIServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            headers = [:]
            for (name, value) in head.headers { headers[name.lowercased()] = value }
            body = Data()
            truncated = false
            // Who sends it, looked up without counting as activity: the route checks again with the whole request.
            let probe = UIServer.Request(method: head.method, path: String(head.uri.prefix { $0 != "?" }), headers: headers, body: Data(), remote: "")
            let caller = server.caller(probe, bearer: true, refresh: false)
            // MCP clients send tool arguments (a config block) to /mcp with an OAuth token of their own.
            let mcpClient = probe.path == "/mcp" && MCPHTTPServer.bearerToken(headers["authorization"]).map { token in
                if case .valid = server.oauth.validate(token, noteUse: false) { true } else { false }
            } == true
            limit = mcpClient ? Self.bodyLimit : caller == nil ? Self.anonymousBodyLimit
                : caller?.isAdmin == true && probe.path == "/api/backups/restore" ? InstanceBackups.maxArchiveSize : Self.bodyLimit
        case .body(var buffer):
            if body.count + buffer.readableBytes > limit { truncated = true }
            if !truncated, let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head else { return }
            let components = URLComponents(string: head.uri)
            // Form-decoded, as URLSearchParams writes them (the pages', an OAuth client's): `+` is a space.
            let query = Dictionary((components?.percentEncodedQueryItems ?? []).map { (URLEncoding.decode($0.name), URLEncoding.decode($0.value ?? "")) },
                                   uniquingKeysWith: { _, last in last })
            var request = UIServer.Request(
                method: head.method, path: components?.percentEncodedPath ?? String(head.uri.prefix { $0 != "?" }), query: query, headers: headers, body: body,
                remote: context.remoteAddress?.ipAddress ?? "?")
            // Behind a trusted reverse proxy, the client it names and the scheme it was reached with.
            let proxies = server.configuration.trustProxy
            if !proxies.isEmpty {
                request.secure = proxies.forwardedHTTPS(remote: request.remote, proto: headers["x-forwarded-proto"])
                request.remote = proxies.client(remote: request.remote, forwardedFor: headers["x-forwarded-for"])
            }
            request.truncated = truncated
            self.head = nil
            body = Data()
            answering += 1
            Self.respond(to: request, keepAlive: head.isKeepAlive, channel: context.channel, server: server)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ResponseDone {
            answering = max(0, answering - 1)
        } else if let idle = event as? IdleStateHandler.IdleStateEvent, idle == .read {
            // Nothing read for a while and nothing to answer: a kept-alive connection nobody uses, or a request
            // that stopped coming. Closed, so idle or slow clients cannot hold the bridge's sockets.
            if answering == 0 { context.close(promise: nil) }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    private static func respond(to request: UIServer.Request, keepAlive: Bool, channel: any Channel, server: UIServer) {
        let keepalive = server.options.keepalive
        Task {
            let reply = await server.reply(to: request)
            await write(reply, to: channel, keepAlive: keepAlive, keepalive: keepalive, overProxiedHTTPS: request.secure)
            channel.pipeline.fireUserInboundEventTriggered(ResponseDone())
        }
    }

    static let securityHeaders: [(String, String)] = [
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "no-referrer"),
        // base-uri 'self': plugins' pages are served with a <base> of their own directory (/plugins/<slug>/).
        ("Content-Security-Policy", "default-src 'self'; manifest-src 'self'; img-src 'self' data: blob: https://tile.openstreetmap.org; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; connect-src 'self' https://photon.komoot.io; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"),
        // Location (sunrise/sunset map), microphone (dictation), and camera full screen for this UI only.
        ("Permissions-Policy", "camera=(), geolocation=(self), payment=(), usb=(), serial=(), hid=(), midi=(), bluetooth=(), magnetometer=(), gyroscope=(), accelerometer=(), display-capture=(), microphone=(self), fullscreen=(self)"),
        // A UI published through a tunnel or a proxy stays out of search engines (robots.txt says so too).
        ("X-Robots-Tag", "noindex, nofollow"),
        ("Cache-Control", "no-store"),
    ]
    /// HTTPS remembered by the browser for a year, sent only when a trusted proxy (`trustProxy`) says the browser came
    /// over HTTPS: that proxy holds a real certificate. Never for the UI's own HTTPS, whose certificate is usually its
    /// self-signed one: under HSTS a browser offers no way past a certificate warning.
    static let strictTransportSecurity = ("Strict-Transport-Security", "max-age=31536000")

    private static func write(_ reply: UIServer.Reply, to channel: any Channel, keepAlive: Bool, keepalive interval: Duration, overProxiedHTTPS: Bool = false) async {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        for (name, value) in securityHeaders { head.headers.add(name: name, value: value) }
        if overProxiedHTTPS { head.headers.add(name: strictTransportSecurity.0, value: strictTransportSecurity.1) }
        switch reply {
        case .data(let status, let contentType, let body, let headers):
            head.status = .init(statusCode: status)
            head.headers.add(name: "Content-Type", value: contentType)
            head.headers.add(name: "Content-Length", value: "\(body.count)")
            // A reply's own headers win over the defaults: an asset's Cache-Control.
            for (name, value) in headers { head.headers.replaceOrAdd(name: name, value: value) }
            channel.write(HTTPServerResponsePart.head(head), promise: nil)
            if !body.isEmpty { channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil) }
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            if !keepAlive { channel.close(promise: nil) }
        case .media(let media):
            await writeMedia(media, head: head, to: channel)
        case .events(let stream, let allowed, let headers):
            // Events as they happen, through a proxy too: one that compresses (Cloudflare) or buffers (nginx) would
            // hold them until it had enough (MCPHTTPServer.streamHeaders).
            for (name, value) in MCPHTTPServer.streamHeaders { head.headers.replaceOrAdd(name: name, value: value) }
            for (name, value) in headers { head.headers.replaceOrAdd(name: name, value: value) }
            head.headers.add(name: "Connection", value: "close")
            channel.writeAndFlush(HTTPServerResponsePart.head(head), promise: nil)
            // Each event once the previous one is out: a browser that stops reading leaves events in the stream's
            // own bounded buffer, not in the channel's, which nothing bounds. A closed connection stops reading the
            // stream, which ends what feeds it (a run, a subscription).
            let forward = Task {
                for await chunk in stream {
                    do { try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: chunk)))).get() } catch { break }
                }
            }
            let keepalive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { break }
                    // The caller signed out, was removed or changed role: the stream ends, and the page asks again.
                    if let allowed, !allowed() {
                        forward.cancel()
                        break
                    }
                    channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: ": keepalive\n\n"))), promise: nil)
                }
            }
            channel.closeFuture.whenComplete { _ in forward.cancel() }
            await forward.value
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

    /// `publicURL`, when the request came for its host name.
    func publicURL(for request: Request) -> PublicURL? {
        guard let url = configuration.publicURL, let host = request.headers["host"], HostName.of(host) == HostName.of(url.host) else { return nil }
        return url
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
        if let url = configuration.publicURL { hosts.insert(HostName.of(url.host)) }
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

// MARK: Password checks

extension UIServer {
    /// The answer while another check from the same address is under way.
    static var checkUnderWay: Reply {
        .json(["error": "another attempt from this address is under way; try again in a moment"], status: 429, headers: ["Retry-After": "1"])
    }

    /// PBKDF2 runs here, two hashes at a time and off the concurrency pool: a burst of sign-ins (210,000 rounds each,
    /// seconds on a NAS) slows sign-ins, not the accessories and plugins sharing the pool.
    private static let hashQueue = HashQueue()

    static func hashing<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            hashQueue.queue.addOperation { continuation.resume(returning: work()) }
        }
    }

    /// OperationQueue is thread-safe, but not marked Sendable on every platform.
    private final class HashQueue: @unchecked Sendable {
        let queue = OperationQueue()

        init() {
            queue.name = "homeswift.ui.passwords"
            queue.maxConcurrentOperationCount = 2
            queue.qualityOfService = .userInitiated
        }
    }
}

/// The client addresses with a password or code check under way. A second attempt from one of them is refused
/// rather than queued: parallel attempts would all be given the throttle's delay before any of them failed, and so
/// guess as many times at once as the client likes.
final class CredentialChecks: Sendable {
    private let active = NIOLockedValueBox<Set<String>>([])

    func begin(_ remote: String) -> Bool { active.withLockedValue { $0.insert(remote).inserted } }

    func end(_ remote: String) { _ = active.withLockedValue { $0.remove(remote) } }
}
