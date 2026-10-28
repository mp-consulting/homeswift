import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import HomeswiftNetwork
import Testing

@testable import HomeswiftUI

@Suite struct OAuthStoreTests {
    func store() -> OAuthStore {
        OAuthStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-oauth-\(UUID().uuidString).json"))
    }

    let verifier = String(repeating: "abcdefgh", count: 6)

    @Test func checksRedirectURIs() {
        #expect(OAuthStore.acceptableRedirect("https://claude.ai/api/mcp/auth_callback"))
        #expect(OAuthStore.acceptableRedirect("http://localhost:6274/oauth/callback"))
        #expect(OAuthStore.acceptableRedirect("http://127.0.0.1:33418/callback"))
        #expect(OAuthStore.acceptableRedirect("cursor://anysphere.cursor-mcp/oauth/callback"))
        #expect(!OAuthStore.acceptableRedirect("http://evil.example/callback"))
        #expect(!OAuthStore.acceptableRedirect("https://claude.ai/callback#fragment"))
        #expect(!OAuthStore.acceptableRedirect("javascript:alert(1)"))
        #expect(!OAuthStore.acceptableRedirect("https:///nohost"))
        #expect(!OAuthStore.acceptableRedirect("not a uri"))
    }

    @Test func registersClients() throws {
        let store = store()
        #expect(throws: OAuthError.self) { try store.register(["redirect_uris": ["http://evil.example/cb"]]) }
        #expect(throws: OAuthError.self) { try store.register(["redirect_uris": []]) }
        #expect(throws: OAuthError.self) { try store.register(["redirect_uris": ["https://claude.ai/cb"], "token_endpoint_auth_method": "private_key_jwt"]) }
        #expect(throws: OAuthError.self) { try store.register(["redirect_uris": ["https://claude.ai/cb"], "grant_types": ["client_credentials"]]) }
        let (public_, none) = try store.register(["redirect_uris": ["https://claude.ai/cb"], "token_endpoint_auth_method": "none", "client_name": "Claude"])
        #expect(none == nil)
        #expect(public_.name == "Claude")
        #expect(store.authenticate(clientID: public_.id, secret: nil) != nil)
        // The default method is client_secret_basic: a secret, shown once, kept as its hash.
        let (confidential, secret) = try store.register(["redirect_uris": ["https://example.com/cb"]])
        let value = try #require(secret)
        #expect(store.authenticate(clientID: confidential.id, secret: value) != nil)
        #expect(store.authenticate(clientID: confidential.id, secret: "wrong") == nil)
        #expect(store.authenticate(clientID: confidential.id, secret: nil) == nil)
        let file = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!file.contains(value))
        // At most so many: a new one replaces the oldest without a grant; clients with one stay.
        let code = store.issueCode(clientID: public_.id, username: "rosaly", scope: .read, redirectURI: "https://claude.ai/cb", challenge: OAuthStore.challenge(for: verifier))
        _ = try store.exchange(code: code, client: public_, redirectURI: "https://claude.ai/cb", verifier: verifier)
        var last: OAuthStore.Client?
        for index in 0...OAuthStore.maximumClients {
            last = try store.register(["redirect_uris": ["https://claude.ai/cb"], "token_endpoint_auth_method": "none"], now: Date().addingTimeInterval(Double(index))).client
        }
        #expect(store.clients.count == OAuthStore.maximumClients)
        #expect(store.client(id: public_.id) != nil)
        #expect(store.client(id: confidential.id) == nil)
        #expect(store.client(id: last!.id) != nil)
    }

    @Test func tradesACodeOnceWithItsVerifier() throws {
        let store = store()
        let (client, _) = try store.register(["redirect_uris": ["https://claude.ai/cb"], "token_endpoint_auth_method": "none"])
        let (other, _) = try store.register(["redirect_uris": ["https://claude.ai/cb"], "token_endpoint_auth_method": "none"])
        let challenge = OAuthStore.challenge(for: verifier)
        #expect(OAuthStore.challengeIsValid(challenge))
        func code() -> String { store.issueCode(clientID: client.id, username: "rosaly", scope: .control, redirectURI: "https://claude.ai/cb", challenge: challenge) }

        #expect(throws: OAuthError.self) { try store.exchange(code: code(), client: client, redirectURI: "https://claude.ai/cb", verifier: String(repeating: "x", count: 43)) }
        #expect(throws: OAuthError.self) { try store.exchange(code: code(), client: client, redirectURI: "https://claude.ai/other", verifier: verifier) }
        #expect(throws: OAuthError.self) { try store.exchange(code: code(), client: other, redirectURI: "https://claude.ai/cb", verifier: verifier) }
        let expiring = code()
        #expect(throws: OAuthError.self) { try store.exchange(code: expiring, client: client, redirectURI: "https://claude.ai/cb", verifier: verifier, now: Date().addingTimeInterval(400)) }

        // A request that left redirect_uri to the client's only one may leave it out of the exchange too; one that
        // named it may not.
        let unnamed = store.issueCode(clientID: client.id, username: "rosaly", scope: .read, redirectURI: "https://claude.ai/cb", redirectURIGiven: false, challenge: challenge)
        #expect(try store.exchange(code: unnamed, client: client, redirectURI: nil, verifier: verifier).grant.scope == .read)
        #expect(throws: OAuthError.self) { try store.exchange(code: code(), client: client, redirectURI: nil, verifier: verifier) }

        let issued = code()
        let tokens = try store.exchange(code: issued, client: client, redirectURI: "https://claude.ai/cb", verifier: verifier)
        #expect(tokens.access.hasPrefix(OAuthStore.accessPrefix))
        #expect(tokens.grant.scope == .control)
        #expect(store.validate(tokens.access) == .valid(store.grant(id: tokens.grant.id)!))
        #expect(store.validate(tokens.access, now: Date().addingTimeInterval(OAuthStore.accessLifetime + 1)) == .expired)
        #expect(store.validate(OAuthStore.accessPrefix + "nope") == .unknown)
        // The same code again: refused, and what it got first ends.
        #expect(throws: OAuthError.self) { try store.exchange(code: issued, client: client, redirectURI: "https://claude.ai/cb", verifier: verifier) }
        #expect(store.validate(tokens.access) == .unknown)
    }

    @Test func rotatesRefreshTokens() throws {
        let store = store()
        let (client, _) = try store.register(["redirect_uris": ["https://claude.ai/cb"], "token_endpoint_auth_method": "none"])
        let (other, _) = try store.register(["redirect_uris": ["https://claude.ai/cb"], "token_endpoint_auth_method": "none"])
        let code = store.issueCode(clientID: client.id, username: "rosaly", scope: .admin, redirectURI: "https://claude.ai/cb", challenge: OAuthStore.challenge(for: verifier))
        let first = try store.exchange(code: code, client: client, redirectURI: "https://claude.ai/cb", verifier: verifier)
        #expect(throws: OAuthError.self) { try store.refresh(first.refresh, client: other) }

        let now = Date()
        let second = try store.refresh(first.refresh, client: client, now: now)
        #expect(store.validate(first.access) == .unknown)
        #expect(store.validate(second.access, now: now) != .unknown)
        // A narrower scope may be asked; a wider one may not.
        let third = try store.refresh(second.refresh, client: client, scope: .read, now: now)
        #expect(third.grant.scope == .read)
        #expect(throws: OAuthError.self) { try store.refresh(third.refresh, client: client, scope: .admin, now: now) }
        // The token just replaced is taken again for a minute (a lost answer, two refreshes at once): both answers'
        // tokens work. Later, it means a stolen copy: the grant ends.
        let retried = try store.refresh(second.refresh, client: client, now: now.addingTimeInterval(10))
        #expect(store.validate(third.access, now: now.addingTimeInterval(10)) != .unknown)
        #expect(store.validate(retried.access, now: now.addingTimeInterval(10)) != .unknown)
        #expect(throws: OAuthError.self) { try store.refresh(second.refresh, client: client, now: now.addingTimeInterval(120)) }
        #expect(store.validate(retried.access, now: now.addingTimeInterval(120)) == .unknown)
        #expect(store.grant(id: first.grant.id) == nil)
    }

    @Test func revokesAndForgets() throws {
        let store = store()
        let (client, _) = try store.register(["redirect_uris": ["https://claude.ai/cb"], "token_endpoint_auth_method": "none"])
        func grant() throws -> OAuthStore.Tokens {
            let code = store.issueCode(clientID: client.id, username: "Rosaly", scope: .read, redirectURI: "https://claude.ai/cb", challenge: OAuthStore.challenge(for: verifier))
            return try store.exchange(code: code, client: client, redirectURI: "https://claude.ai/cb", verifier: verifier)
        }
        let one = try grant()
        store.revoke(one.refresh, client: client)
        #expect(store.validate(one.access) == .unknown)
        let two = try grant()
        #expect(store.grants(of: "rosaly").map(\.id) == [two.grant.id])
        #expect(!store.revoke(grant: two.grant.id, of: "someone"))
        #expect(store.revoke(grant: two.grant.id, of: "rosaly"))
        #expect(store.grants(of: "rosaly").isEmpty)
        // Read back from the file.
        let three = try grant()
        #expect(OAuthStore(url: store.url).validate(three.access) != .unknown)
        // Grants unused past their refresh lifetime are dropped with their clients a day on.
        _ = try store.register(["redirect_uris": ["https://claude.ai/cb"], "token_endpoint_auth_method": "none"], now: Date().addingTimeInterval(OAuthStore.refreshLifetime + 2 * 86_400))
        #expect(store.grant(id: three.grant.id) == nil)
        #expect(store.client(id: client.id) == nil)
    }

    /// What a user who is not an administrator may not see names real tools, resources and prompts: a rename would
    /// otherwise show them again.
    @Test func administratorOnlyNamesExist() throws {
        let environment = try UITestEnvironment(mcp: OAuthServerTests.mcpConfiguration())
        let server = try #require(environment.mcpServer)
        let known = Set(server.tools.map(\.name) + server.resources.map(\.uri) + server.templates.map(\.uriTemplate) + server.prompts.map(\.name))
        #expect(HomeswiftCatalog.administratorOnly.subtracting(known) == [HomeswiftCatalog.digestRefresh])
    }

    @Test func readsScopes() {
        #expect(OAuthStore.scope(from: "read control") == .control)
        #expect(OAuthStore.scope(from: "admin openid") == .admin)
        #expect(OAuthStore.scope(from: "openid") == nil)
        #expect(OAuthStore.scope(from: nil) == nil)
        #expect(OAuthStore.parameter(for: .control) == "read control")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct OAuthServerTests {
    static let initialize: JSONValue = [
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "tests", "version": "1"]],
    ]

    static func mcpConfiguration() -> MCPConfiguration {
        var mcp = MCPConfiguration()
        mcp.enabled = true
        mcp.token = "the-configured-client-token"
        return mcp
    }

    static func form(_ fields: KeyValuePairs<String, String>) -> String {
        URLEncoding.query(fields.map { ($0.key, $0.value) })
    }

    static func query(_ location: String) -> [String: String] {
        Dictionary((URLComponents(string: location)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    @Test func signsAnMCPClientInWithAWebUIAccount() async throws {
        let environment = try UITestEnvironment(mcp: Self.mcpConfiguration())
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let origin = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        _ = try environment.server.users.createFirst(username: "rosaly", password: "correct horse battery")
        _ = try environment.server.users.create(username: "sam", password: "correct horse battery")

        // The client finds the sign-in from the 401.
        let app = Browser(base: base)
        let refused = try await app.send("POST", "/mcp", body: Self.initialize.text(), headers: ["Accept": "application/json"])
        #expect(refused.status == 401)
        #expect(refused.headers["www-authenticate"] == #"Bearer resource_metadata="\#(origin)/.well-known/oauth-protected-resource/mcp""#)
        let resource = try #require(try await app.get("/.well-known/oauth-protected-resource/mcp").json)
        #expect(resource["resource"] == .string(origin + "/mcp"))
        #expect(resource["authorization_servers"] == [.string(origin)])
        #expect(try await app.get("/.well-known/oauth-protected-resource").json == resource)
        let metadata = try #require(try await app.get("/.well-known/oauth-authorization-server").json)
        #expect(metadata["issuer"] == .string(origin))
        #expect(metadata["code_challenge_methods_supported"] == ["S256"])
        #expect(metadata["token_endpoint"] == .string(origin + "/oauth/token"))
        #expect(try await app.send("OPTIONS", "/oauth/token").headers["access-control-allow-origin"] == "*")
        #expect(try await app.get("/.well-known/openid-configuration").status == 404)

        let rejected = try await app.post("/oauth/register", ["redirect_uris": ["http://evil.example/cb"], "token_endpoint_auth_method": "none"])
        #expect(rejected.status == 400)
        #expect(rejected.json?["error"] == "invalid_redirect_uri")
        let registered = try await app.post("/oauth/register", ["redirect_uris": ["https://claude.ai/api/mcp/auth_callback"], "token_endpoint_auth_method": "none", "client_name": "Claude"])
        #expect(registered.status == 201)
        let clientID = try #require(registered.json?["client_id"]?.stringValue)
        #expect(registered.json?["client_secret"] == nil)

        // The user signs in on the page and approves.
        let verifier = Secrets.randomToken()
        let challenge = OAuthStore.challenge(for: verifier)
        let request: [String: String] = [
            "response_type": "code", "client_id": clientID, "redirect_uri": "https://claude.ai/api/mcp/auth_callback", "state": "state-1",
            "code_challenge": challenge, "code_challenge_method": "S256", "scope": "read control admin", "resource": origin + "/mcp",
        ]
        let queryString = URLEncoding.query(request.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        let browser = Browser(base: base)
        browser.origin = origin
        // Spaces as URLSearchParams writes them.
        let plusQuery = queryString.replacingOccurrences(of: "%20", with: "+")
        #expect(plusQuery.contains("scope=read+control+admin"))
        let page = try await browser.get("/oauth/authorize?\(plusQuery)")
        #expect(page.status == 200)
        // Its files are relative to a <base> of the UI's root (or of `publicURL`'s path, below).
        #expect(page.body.contains(#"<base href="/">"#))
        #expect(page.body.contains(#"src="authorize.js""#))
        #expect(page.headers["x-frame-options"] == "DENY")
        #expect(try await browser.get("/api/oauth/request?\(queryString)").status == 401)
        #expect(try await browser.post("/api/auth/login", ["username": "sam", "password": "correct horse battery"]).status == 200)
        let asked = try #require(try await browser.get("/api/oauth/request?\(plusQuery)").json)
        #expect(asked["client"] == "Claude")
        #expect(asked["destination"] == "claude.ai")
        // Sam is not an administrator: control at most.
        #expect(asked["choices"] == ["read", "control"])
        #expect(asked["suggested"] == "control")
        func decision(_ changes: [String: JSONValue]) -> JSONValue {
            .object(request.mapValues(JSONValue.string).merging(changes) { _, new in new })
        }
        #expect(try await browser.post("/api/oauth/decision", decision(["approve": true, "scope_granted": "admin"])).status == 400)
        // Unknown clients and redirect URIs are refused on the page; anything else goes back to the client.
        #expect(try await browser.post("/api/oauth/decision", decision(["approve": true, "scope_granted": "read", "redirect_uri": "https://evil.example/cb"])).status == 400)
        let sentBack = try #require(try await browser.post("/api/oauth/decision", decision(["approve": true, "scope_granted": "read", "code_challenge_method": "plain"])).json?["redirect"]?.stringValue)
        #expect(Self.query(sentBack)["error"] == "invalid_request")
        let denied = try #require(try await browser.post("/api/oauth/decision", decision(["approve": false])).json?["redirect"]?.stringValue)
        #expect(Self.query(denied)["error"] == "access_denied")
        #expect(Self.query(denied)["state"] == "state-1")
        let approved = try #require(try await browser.post("/api/oauth/decision", decision(["approve": true, "scope_granted": "control"])).json?["redirect"]?.stringValue)
        #expect(approved.hasPrefix("https://claude.ai/api/mcp/auth_callback?"))
        let answer = Self.query(approved)
        #expect(answer["state"] == "state-1")
        #expect(answer["iss"] == origin)
        let code = try #require(answer["code"])

        // The client trades the code, with its verifier.
        app.contentType = "application/x-www-form-urlencoded"
        let wrong = try await app.send("POST", "/oauth/token", body: Self.form(["grant_type": "authorization_code", "code": "nope", "client_id": clientID,
            "redirect_uri": "https://claude.ai/api/mcp/auth_callback", "code_verifier": verifier]))
        #expect(wrong.status == 400)
        #expect(wrong.json?["error"] == "invalid_grant")
        #expect(try await app.send("POST", "/oauth/token", body: Self.form(["grant_type": "authorization_code", "code": code, "client_id": "unknown"])).status == 401)
        let traded = try await app.send("POST", "/oauth/token", body: Self.form(["grant_type": "authorization_code", "code": code, "client_id": clientID,
            "redirect_uri": "https://claude.ai/api/mcp/auth_callback", "code_verifier": verifier, "resource": origin + "/mcp"]))
        #expect(traded.status == 200)
        let tokens = try #require(traded.json)
        #expect(tokens["token_type"] == "Bearer")
        #expect(tokens["scope"] == "read control")
        #expect(traded.headers["cache-control"] == "no-store")
        let access = try #require(tokens["access_token"]?.stringValue)
        let refresh = try #require(tokens["refresh_token"]?.stringValue)
        // The access token reaches /mcp and nothing else.
        #expect(try await app.send("GET", "/api/status", headers: ["Authorization": "Bearer \(access)"]).status == 401)

        app.contentType = "application/json"
        let session = try await app.send("POST", "/mcp", body: Self.initialize.text(), headers: ["Authorization": "Bearer \(access)", "Accept": "application/json"])
        #expect(session.status == 200)
        #expect(session.json?["result"]?["serverInfo"] != nil)
        let sessionID = try #require(session.headers["mcp-session-id"])
        let principal = try #require(environment.mcpServer?.activeSessions.first { $0.id == sessionID }?.principal)
        #expect(principal == Principal(name: "Claude (sam)", scope: .control, hidden: HomeswiftCatalog.administratorOnly))
        // Over server-sent events, the session's id comes in the stream's headers.
        let streamed = try await app.send("POST", "/mcp", body: Self.initialize.text(), headers: ["Authorization": "Bearer \(access)", "Accept": "application/json, text/event-stream"])
        #expect(streamed.status == 200)
        #expect(streamed.headers["content-type"] == "text/event-stream")
        #expect(streamed.headers["cache-control"] == "no-store, no-transform" && streamed.headers["x-accel-buffering"] == "no")
        #expect(streamed.headers["mcp-session-id"] != nil)
        #expect(streamed.body.contains("event: message"))
        // Sam is not an administrator: as in the UI, no log, config.json or pairings.
        func call(_ method: String, _ params: JSONValue) async throws -> JSONValue? {
            try await app.send("POST", "/mcp", body: (["jsonrpc": "2.0", "id": 2, "method": .string(method), "params": params] as JSONValue).text(),
                               headers: ["Authorization": "Bearer \(access)", "Accept": "application/json", "Mcp-Session-Id": sessionID]).json
        }
        _ = try await app.send("POST", "/mcp", body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                               headers: ["Authorization": "Bearer \(access)", "Mcp-Session-Id": sessionID])
        let tools = try #require(try await call("tools/list", [:])?["result"]?["tools"]?.arrayValue).compactMap { $0["name"]?.stringValue }
        #expect(tools.contains("set_accessory"))
        #expect(!tools.contains("get_recent_logs") && !tools.contains("get_config"))
        #expect(try await call("tools/call", ["name": "get_recent_logs", "arguments": [:]])?["error"] != nil)
        #expect(try await call("resources/read", ["uri": "homeswift://logs/recent"])?["error"] != nil)
        #expect(try await call("resources/read", ["uri": "homeswift://status"])?["result"] != nil)
        // A page from another site may not use it.
        #expect(try await app.send("POST", "/mcp", body: Self.initialize.text(), headers: ["Authorization": "Bearer \(access)", "Origin": "https://evil.example"]).status == 403)
        // The HomeswiftAiKit block's tokens stay on the MCP server's own listener.
        #expect(try await app.send("POST", "/mcp", body: Self.initialize.text(), headers: ["Authorization": "Bearer the-configured-client-token", "Accept": "application/json"]).status == 401)

        // A refresh replaces both tokens.
        app.contentType = "application/x-www-form-urlencoded"
        #expect(try await app.send("POST", "/oauth/revoke", body: Self.form(["token": refresh, "client_id": "unknown"])).status == 401)
        let refreshed = try await app.send("POST", "/oauth/token", body: Self.form(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]))
        #expect(refreshed.status == 200)
        let newAccess = try #require(refreshed.json?["access_token"]?.stringValue)
        app.contentType = "application/json"
        #expect(try await app.send("POST", "/mcp", body: Self.initialize.text(), headers: ["Authorization": "Bearer \(access)", "Accept": "application/json"]).status == 401)
        #expect(try await app.send("POST", "/mcp", body: Self.initialize.text(), headers: ["Authorization": "Bearer \(newAccess)", "Accept": "application/json"]).status == 200)

        // The account page lists it and disconnects it.
        let apps = try #require(try await browser.get("/api/account/apps").json)
        #expect(apps["mcp"] == .string(origin + "/mcp"))
        let listed = try #require(apps["apps"]?.arrayValue?.first)
        #expect(listed["client"] == "Claude")
        #expect(listed["scope"] == "control")
        #expect(try await browser.send("DELETE", "/api/account/apps/\(listed["id"]!.stringValue!)").status == 200)
        #expect(try await app.send("POST", "/mcp", body: Self.initialize.text(), headers: ["Authorization": "Bearer \(newAccess)", "Accept": "application/json"]).status == 401)
    }

    /// `publicURL`: the connector on a path of a host name other servers share (`mcp.example.com/homeswift`). The
    /// test's own address stands for that host: the port does not count, so every request here comes "for it".
    @Test func servesTheConnectorOnAPathOfASharedHostName() async throws {
        let environment = try UITestEnvironment(mcp: Self.mcpConfiguration(), publicURL: "https://127.0.0.1/homeswift")
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let own = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        let address = "https://127.0.0.1/homeswift"
        _ = try environment.server.users.createFirst(username: "rosaly", password: "correct horse battery")

        let app = Browser(base: base)
        let refused = try await app.send("POST", "/homeswift", body: Self.initialize.text(), headers: ["Accept": "application/json"])
        #expect(refused.status == 401)
        #expect(refused.headers["www-authenticate"] == #"Bearer resource_metadata="https://127.0.0.1/.well-known/oauth-protected-resource/homeswift""#)
        let resource = try #require(try await app.get("/.well-known/oauth-protected-resource/homeswift").json)
        #expect(resource["resource"] == .string(address))
        #expect(resource["authorization_servers"] == [.string(address)])
        let metadata = try #require(try await app.get("/.well-known/oauth-authorization-server/homeswift").json)
        #expect(metadata["issuer"] == .string(address))
        #expect(metadata["token_endpoint"] == .string(address + "/oauth/token"))
        #expect(metadata["authorization_endpoint"] == .string(address + "/oauth/authorize"))
        // Another server's path on the shared name is not this one's.
        #expect(try await app.get("/.well-known/oauth-authorization-server/mail").status == 404)

        let registered = try await app.post("/homeswift/oauth/register", ["redirect_uris": ["https://claude.ai/api/mcp/auth_callback"], "token_endpoint_auth_method": "none", "client_name": "Claude"])
        let clientID = try #require(registered.json?["client_id"]?.stringValue)

        // The sign-in page and everything it loads stay under the path.
        let verifier = Secrets.randomToken()
        let request: [String: String] = [
            "response_type": "code", "client_id": clientID, "redirect_uri": "https://claude.ai/api/mcp/auth_callback", "state": "s",
            "code_challenge": OAuthStore.challenge(for: verifier), "code_challenge_method": "S256", "resource": address,
        ]
        let queryString = URLEncoding.query(request.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        let browser = Browser(base: base)
        browser.origin = own
        let page = try await browser.get("/homeswift/oauth/authorize?\(queryString)")
        #expect(page.status == 200)
        #expect(page.body.contains(#"<base href="/homeswift/">"#))
        #expect(page.body.contains(#"src="authorize.js""#))
        #expect(try await browser.get("/homeswift/authorize.js").status == 200)
        #expect(try await browser.post("/homeswift/api/auth/login", ["username": "rosaly", "password": "correct horse battery"]).status == 200)
        let decision: JSONValue = .object(request.mapValues(JSONValue.string).merging(["approve": true, "scope_granted": "control"]) { _, new in new })
        let approved = try #require(try await browser.post("/homeswift/api/oauth/decision", decision).json?["redirect"]?.stringValue)
        #expect(Self.query(approved)["iss"] == address)
        let code = try #require(Self.query(approved)["code"])

        app.contentType = "application/x-www-form-urlencoded"
        let traded = try await app.send("POST", "/homeswift/oauth/token", body: Self.form(["grant_type": "authorization_code", "code": code, "client_id": clientID,
            "redirect_uri": "https://claude.ai/api/mcp/auth_callback", "code_verifier": verifier, "resource": address]))
        #expect(traded.status == 200)
        let access = try #require(traded.json?["access_token"]?.stringValue)
        app.contentType = "application/json"
        let session = try await app.send("POST", "/homeswift", body: Self.initialize.text(), headers: ["Authorization": "Bearer \(access)", "Accept": "application/json"])
        #expect(session.status == 200)
        #expect(session.json?["result"]?["serverInfo"] != nil)
    }

    @Test func mapsAPublicURLsPathsToTheUIsRoutes() throws {
        let url = try #require(PublicURL("https://MCP.example.com/homeswift/"))
        #expect(url.address == "https://mcp.example.com/homeswift")
        #expect(url.route("/homeswift") == "/mcp")
        #expect(url.route("/homeswift/mcp") == "/mcp")
        #expect(url.route("/homeswift/oauth/token") == "/oauth/token")
        #expect(url.route("/.well-known/oauth-protected-resource/homeswift") == "/.well-known/oauth-protected-resource/mcp")
        #expect(url.route("/.well-known/oauth-authorization-server/homeswift") == "/.well-known/oauth-authorization-server")
        #expect(url.route("/homeswiftx") == nil)
        #expect(url.route("/.well-known/oauth-authorization-server/mail") == nil)
        #expect(PublicURL("https://mcp.example.com") == nil)
        #expect(PublicURL("https://mcp.example.com/x?y=1") == nil)
        #expect(throws: UIConfigurationError.self) { try UIConfiguration(block: ["publicURL": "mcp.example.com/homeswift"]) }
        #expect(try UIConfiguration(block: ["publicURL": "https://mcp.example.com/homeswift"]).publicURL == url)
        #expect(UIServer.isMCPResource("https://mcp.example.com/homeswift", publicPath: "/homeswift"))
        #expect(!UIServer.isMCPResource("https://mcp.example.com/homeswift"))
    }

    @Test func capsAGrantByTheUsersRoleNow() async throws {
        let environment = try UITestEnvironment(mcp: Self.mcpConfiguration())
        _ = try await environment.start()
        defer { Task { await environment.stop() } }
        let server = environment.server
        _ = try server.users.createFirst(username: "rosaly", password: "correct horse battery")
        let (client, _) = try server.oauth.register(["redirect_uris": ["https://claude.ai/cb"], "token_endpoint_auth_method": "none", "client_name": "Claude"])
        let verifier = Secrets.randomToken()
        let code = server.oauth.issueCode(clientID: client.id, username: "rosaly", scope: .admin, redirectURI: "https://claude.ai/cb", challenge: OAuthStore.challenge(for: verifier))
        let tokens = try server.oauth.exchange(code: code, client: client, redirectURI: "https://claude.ai/cb", verifier: verifier)
        #expect(server.principal(for: tokens.grant, readOnly: false)?.scope == .admin)
        #expect(server.principal(for: tokens.grant, readOnly: true)?.scope == .read)
        _ = try server.users.create(username: "other", password: "correct horse battery", admin: true)
        _ = try server.users.update(username: "rosaly", admin: false)
        #expect(server.principal(for: tokens.grant, readOnly: false)?.scope == .control)
        try server.users.delete(username: "rosaly")
        #expect(server.principal(for: tokens.grant, readOnly: false) == nil)
    }

    @Test func endsAppsWithTheAccountOrItsPassword() async throws {
        let environment = try UITestEnvironment(mcp: Self.mcpConfiguration())
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let server = environment.server
        _ = try server.users.createFirst(username: "rosaly", password: "correct horse battery")
        _ = try server.users.create(username: "sam", password: "correct horse battery")
        let (client, _) = try server.oauth.register(["redirect_uris": ["https://claude.ai/cb"], "token_endpoint_auth_method": "none"])
        let verifier = Secrets.randomToken()
        func connect(_ username: String) throws {
            let code = server.oauth.issueCode(clientID: client.id, username: username, scope: .control, redirectURI: "https://claude.ai/cb", challenge: OAuthStore.challenge(for: verifier))
            _ = try server.oauth.exchange(code: code, client: client, redirectURI: "https://claude.ai/cb", verifier: verifier)
        }
        let admin = Browser(base: base)
        admin.origin = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        #expect(try await admin.post("/api/auth/login", ["username": "rosaly", "password": "correct horse battery"]).status == 200)
        // A new password, set by an administrator, ends the apps as it ends the sessions.
        try connect("sam")
        #expect(try await admin.put("/api/users/sam", ["password": "another horse battery staple"]).status == 200)
        #expect(server.oauth.grants(of: "sam").isEmpty)
        // A removed user's apps go: a later account of the same name does not get them.
        try connect("sam")
        #expect(try await admin.send("DELETE", "/api/users/sam").status == 200)
        #expect(server.oauth.grants(of: "sam").isEmpty)
        // Turning two-factor authentication on or off, or a new password of one's own, too.
        try connect("rosaly")
        #expect(try await admin.post("/api/account/password", ["current": "correct horse battery", "new": "a brand new horse battery"]).status == 200)
        #expect(server.oauth.grants(of: "rosaly").isEmpty)
    }

    @Test func answersNotFoundWithoutAnMCPServer() async throws {
        let environment = try UITestEnvironment()
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let app = Browser(base: base)
        #expect(try await app.get("/.well-known/oauth-authorization-server").status == 404)
        #expect(try await app.send("POST", "/mcp", body: Self.initialize.text()).status == 404)
    }

    @Test func addsParametersToARedirect() {
        #expect(UIServer.redirect("https://claude.ai/cb", ["code": "a b+c", "state": nil]) == "https://claude.ai/cb?code=a%20b%2Bc")
        #expect(UIServer.redirect("https://claude.ai/cb?x=1", ["code": "z"]) == "https://claude.ai/cb?x=1&code=z")
        #expect(UIServer.form(Data("a=1+2&b=%2F&c".utf8)) == ["a": "1 2", "b": "/", "c": ""])
        #expect(UIServer.isMCPResource("https://home.example.com/mcp"))
        #expect(!UIServer.isMCPResource("https://home.example.com/other"))
        #expect(UIServer.shownDestination("cursor://anysphere/cb") == "cursor:")
    }
}
