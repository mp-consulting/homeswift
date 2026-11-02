import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import HomeswiftNetwork
import HomeswiftPlugin
import NIOHTTP1

/// The MCP server on the web UI's own address, for clients that sign in with OAuth (claude.ai, the Claude apps):
/// `/mcp`, the discovery documents (RFC 9728's protected resource metadata, RFC 8414's authorization server
/// metadata), registration, the token and revocation endpoints, and the sign-in page at `/oauth/authorize`, whose
/// script approves through `/api/oauth/…` with the browser's session. One HTTPS name to publish (a tunnel, a reverse
/// proxy) carries all of it. Everything here needs the HomeswiftAiKit block's MCP server to be on.
extension UIServer {
    static let scopesSupported: JSONValue = .array(Scope.allCases.map { .string($0.rawValue) })
    static let corsHeaders = [
        "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Authorization, Content-Type, MCP-Protocol-Version",
    ]
    static let oauthPaths: Set<[String]> = [
        [".well-known", "oauth-protected-resource"], [".well-known", "oauth-protected-resource", "mcp"], [".well-known", "oauth-authorization-server"],
        ["oauth", "register"], ["oauth", "token"], ["oauth", "revoke"], ["mcp"],
    ]

    /// The address clients reach this server by, as the request says: `https` with a certificate or behind a trusted
    /// proxy that was reached over HTTPS. The issuer and every endpoint in the metadata derive from it.
    /// On the MCP connector's shared host name (`publicURL`), that address, path included.
    func publicBase(_ request: Request) -> String {
        if let url = publicURL(for: request) { return url.address }
        return "\(isSecure(request) ? "https" : "http")://\(request.headers["host"] ?? "localhost")"
    }

    /// The MCP endpoint as clients name it: `<base>/mcp`, or the connector address itself on its shared host name.
    func mcpResource(_ request: Request) -> String {
        publicURL(for: request)?.address ?? publicBase(request) + "/mcp"
    }

    /// Where the protected resource metadata is (RFC 9728: the root's `.well-known`, the resource's path appended).
    func resourceMetadataAddress(_ request: Request) -> String {
        if let url = publicURL(for: request) { return url.origin + "/.well-known/oauth-protected-resource" + url.path }
        return publicBase(request) + "/.well-known/oauth-protected-resource/mcp"
    }

    /// The bridge's MCP server, when the HomeswiftAiKit block turns it on.
    var mcpTransport: MCPHTTPServer? { options.mcp?() }

    /// Answers the OAuth and MCP paths; nil for any other (and for `/oauth/authorize`, which is a page).
    func oauthEndpoint(_ parts: [String], _ request: Request) async -> Reply? {
        // Any other well-known document (openid-configuration…) is not here: a 404, never the UI's page.
        if parts.first == ".well-known", !Self.oauthPaths.contains(parts) { return .error(404, "not found") }
        guard Self.oauthPaths.contains(parts) else { return nil }
        guard let transport = mcpTransport else {
            return .error(404, "the MCP server is off: turn on mcp.http in the HomeswiftAiKit block")
        }
        if parts == ["mcp"] { return await mcpEndpoint(request, transport: transport) }
        if request.method == .OPTIONS { return .data(status: 204, contentType: "text/plain", body: Data(), headers: Self.corsHeaders) }
        let base = publicBase(request)
        let reply: Reply
        switch (request.method, parts) {
        case (.GET, [".well-known", "oauth-protected-resource"]), (.GET, [".well-known", "oauth-protected-resource", "mcp"]):
            reply = .json([
                "resource": .string(mcpResource(request)), "authorization_servers": [.string(base)], "scopes_supported": Self.scopesSupported,
                "bearer_methods_supported": ["header"], "resource_name": "Homeswift",
            ])
        case (.GET, [".well-known", "oauth-authorization-server"]):
            let methods: JSONValue = ["none", "client_secret_post", "client_secret_basic"]
            reply = .json([
                "issuer": .string(base), "authorization_endpoint": .string(base + "/oauth/authorize"), "token_endpoint": .string(base + "/oauth/token"),
                "registration_endpoint": .string(base + "/oauth/register"), "revocation_endpoint": .string(base + "/oauth/revoke"),
                "response_types_supported": ["code"], "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": methods,
                "revocation_endpoint_auth_methods_supported": methods, "scopes_supported": Self.scopesSupported,
                "authorization_response_iss_parameter_supported": true,
            ])
        case (.POST, ["oauth", "register"]):
            reply = register(request)
        case (.POST, ["oauth", "token"]):
            reply = await token(request)
        case (.POST, ["oauth", "revoke"]):
            // RFC 7009: a client that fails to authenticate is told so; an unknown token is not an error.
            let form = Self.form(request.body)
            do {
                let client = try tokenClient(request, form: form)
                if let token = form["token"] { oauth.revoke(token, client: client) }
                reply = .json([:])
            } catch {
                reply = Self.oauthError(error)
            }
        default:
            reply = .error(405, "method not allowed")
        }
        guard case .data(let status, let contentType, let body, var headers) = reply else { return reply }
        headers.merge(Self.corsHeaders) { own, _ in own }
        return .data(status: status, contentType: contentType, body: body, headers: headers)
    }

    // MARK: Registration and tokens

    private func register(_ request: Request) -> Reply {
        guard let metadata = try? JSONValue(data: request.body) else { return Self.oauthError(.invalidClientMetadata("send the client's metadata as JSON")) }
        do {
            let (client, secret) = try oauth.register(metadata)
            logger.info("OAuth client registered", metadata: ["client": "\(client.name)", "remote": "\(request.remote)"])
            var answer: [String: JSONValue] = [
                "client_id": .string(client.id), "client_id_issued_at": .number(client.created.timeIntervalSince1970.rounded(.down)),
                "client_name": .string(client.name), "redirect_uris": .array(client.redirectURIs.map(JSONValue.string)),
                "token_endpoint_auth_method": .string(client.authMethod), "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            ]
            if let secret {
                answer["client_secret"] = .string(secret)
                answer["client_secret_expires_at"] = 0
            }
            return .json(.object(answer), status: 201)
        } catch {
            return Self.oauthError(error)
        }
    }

    private func token(_ request: Request) async -> Reply {
        let form = Self.form(request.body)
        do {
            let client = try tokenClient(request, form: form)
            let tokens: OAuthStore.Tokens
            switch form["grant_type"] {
            case "authorization_code":
                guard let code = form["code"] else { throw OAuthError.invalidRequest("code is missing") }
                if let resource = form["resource"], !Self.isMCPResource(resource, publicPath: configuration.publicURL?.path) { throw OAuthError.invalidRequest("resource is not this server's /mcp") }
                tokens = try oauth.exchange(code: code, client: client, redirectURI: form["redirect_uri"], verifier: form["code_verifier"])
                logger.info("OAuth client signed in", metadata: ["client": "\(client.name)", "username": "\(tokens.grant.username)", "scope": "\(tokens.grant.scope.rawValue)"])
            case "refresh_token":
                guard let refresh = form["refresh_token"] else { throw OAuthError.invalidRequest("refresh_token is missing") }
                var scope: Scope?
                if let asked = form["scope"], !asked.isEmpty {
                    guard let parsed = OAuthStore.scope(from: asked) else { throw OAuthError.invalidScope("the scopes are read, control and admin") }
                    scope = parsed
                }
                tokens = try oauth.refresh(refresh, client: client, scope: scope)
            case nil:
                throw OAuthError.invalidRequest("grant_type is missing")
            default:
                throw OAuthError.unsupportedGrantType("the grants are authorization_code and refresh_token")
            }
            return .json([
                "access_token": .string(tokens.access), "token_type": "Bearer", "expires_in": .number(Double(tokens.expiresIn)),
                "refresh_token": .string(tokens.refresh), "scope": .string(OAuthStore.parameter(for: tokens.grant.scope)),
            ], headers: ["Pragma": "no-cache"])
        } catch let error as OAuthError {
            if case .invalidClient = error { logger.warning("OAuth token request from an unknown client", metadata: ["remote": "\(request.remote)"]) }
            return Self.oauthError(error)
        } catch {
            return Self.oauthError(.invalidRequest("\(error)"))
        }
    }

    /// The client of a token or revocation request: `client_id` (and `client_secret`) in the form, or HTTP Basic.
    private func tokenClient(_ request: Request, form: [String: String]) throws(OAuthError) -> OAuthStore.Client {
        var id = form["client_id"]
        var secret = form["client_secret"]
        if let header = request.headers["authorization"], header.lowercased().hasPrefix("basic ") {
            guard let decoded = Data(base64Encoded: String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)).map({ String(decoding: $0, as: UTF8.self) }),
                  let colon = decoded.firstIndex(of: ":") else { throw .invalidClient("the Basic credentials are malformed") }
            // RFC 6749 §2.3.1: both halves are form-encoded.
            id = URLEncoding.decode(String(decoded[..<colon]))
            secret = URLEncoding.decode(String(decoded[decoded.index(after: colon)...]))
        }
        guard let id, let client = oauth.authenticate(clientID: id, secret: secret) else { throw .invalidClient("unknown client or wrong secret") }
        return client
    }

    static func oauthError(_ error: OAuthError) -> Reply {
        .json(error.json, status: error.status, headers: error.status == 401 ? ["WWW-Authenticate": "Basic"] : [:])
    }

    /// An `application/x-www-form-urlencoded` body.
    static func form(_ body: Data) -> [String: String] { URLEncoding.fields(String(decoding: body, as: UTF8.self)) }

    /// RFC 8707's `resource`, when a client sends one: this server's `/mcp`, its origin, or the connector address
    /// on a shared host name (`publicURL`'s path).
    static func isMCPResource(_ resource: String, publicPath: String? = nil) -> Bool {
        guard let components = URLComponents(string: resource), components.scheme != nil, components.host != nil, components.fragment == nil else { return false }
        let own = publicPath.map { [$0, $0 + "/", $0 + "/mcp"] } ?? []
        return (["", "/", "/mcp", "/mcp/"] + own).contains(components.path)
    }

    // MARK: Approval

    /// An authorization request (RFC 6749 §4.1.1) that names a known client and one of its redirect URIs.
    struct AuthorizationRequest {
        var client: OAuthStore.Client
        var redirectURI: String
        /// The request named it, rather than leaving it to the client's only one.
        var redirectURIGiven: Bool
        var state: String?
        var challenge: String
        /// The most the client asks for; nil when it names no scope.
        var requested: Scope?
    }

    enum AuthorizationCheck {
        case valid(AuthorizationRequest)
        /// Shown on the page: without a known client and redirect URI, nothing may be sent anywhere.
        case refused(String)
        /// Sent back to the client, as its redirect URI's `error`: by the person's click, never on its own, since anyone
        /// may register a client and its redirect URI (RFC 9700 4.11.2). `destination` is the URI as the page shows it.
        case redirect(String, destination: String, reason: String)
    }

    func checkAuthorization(_ parameters: JSONValue, issuer: String) -> AuthorizationCheck {
        func text(_ name: String) -> String? { parameters[name]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        guard let clientID = text("client_id"), let client = oauth.client(id: clientID) else {
            return .refused("This app is not registered with Homeswift, or its registration expired. Connect again from the app.")
        }
        let redirectURI: String
        if let given = text("redirect_uri") {
            guard client.redirectURIs.contains(given) else { return .refused("The address this app asked to return to is not one it registered.") }
            redirectURI = given
        } else {
            guard client.redirectURIs.count == 1 else { return .refused("The app did not say where to return to.") }
            redirectURI = client.redirectURIs[0]
        }
        let state = text("state")
        func back(_ error: String, _ description: String) -> AuthorizationCheck {
            .redirect(Self.redirect(redirectURI, ["error": error, "error_description": description, "state": state, "iss": issuer]),
                      destination: Self.shownDestination(redirectURI), reason: description)
        }
        guard text("response_type") == "code" else { return back("unsupported_response_type", "response_type is code") }
        guard let challenge = text("code_challenge"), text("code_challenge_method") == "S256", OAuthStore.challengeIsValid(challenge) else {
            return back("invalid_request", "PKCE with S256 is required")
        }
        if let resource = text("resource"), !Self.isMCPResource(resource, publicPath: configuration.publicURL?.path) { return back("invalid_target", "resource is not this server's /mcp") }
        let requested = OAuthStore.scope(from: text("scope"))
        if text("scope") != nil, requested == nil { return back("invalid_scope", "the scopes are read, control and admin") }
        return .valid(AuthorizationRequest(
            client: client, redirectURI: redirectURI, redirectURIGiven: text("redirect_uri") != nil, state: state, challenge: challenge, requested: requested))
    }

    /// A redirect URI with parameters added to its query, every value encoded but the unreserved characters.
    static func redirect(_ uri: String, _ parameters: KeyValuePairs<String, String?>) -> String {
        let query = URLEncoding.query(parameters.compactMap { name, value in value.map { (name, $0) } })
        guard var components = URLComponents(string: uri) else { return uri }
        components.percentEncodedQuery = [components.percentEncodedQuery, query].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "&")
        return components.string ?? uri
    }

    /// The sign-in page's calls, with the browser's session: what an authorization request asks (`GET request`), the
    /// user's answer (`POST decision`), and the user's connected apps (`GET`, `DELETE /api/account/apps`).
    func oauthAPI(_ route: [String], _ request: Request, body: JSONValue, caller: Caller) -> Reply? {
        let isApps = route.count >= 2 && route[0] == "account" && route[1] == "apps"
        guard route.first == "oauth" || isApps else { return nil }
        guard caller.token == nil else { return .error(403, "an API token names no account: sign in to connect an app") }
        if isApps {
            switch (request.method, route.count) {
            case (.GET, 2):
                return .json([
                    "mcp": mcpTransport == nil ? .null : .string(publicBase(request) + "/mcp"),
                    "apps": .array(oauth.grants(of: caller.username).map(appJSON)),
                ])
            case (.DELETE, 3):
                guard oauth.revoke(grant: route[2], of: caller.username) else { return .error(404, "no such connected app") }
                logger.info("OAuth app disconnected", metadata: ["username": "\(caller.username)"])
                return .json([:])
            default:
                return .error(404, "unknown route")
            }
        }
        guard mcpTransport != nil else { return .error(404, "the MCP server is off: turn on mcp.http in the HomeswiftAiKit block") }
        let issuer = publicBase(request)
        let parameters: JSONValue = request.method == .GET ? .object(request.query.mapValues(JSONValue.string)) : body
        let checked: AuthorizationRequest
        switch checkAuthorization(parameters, issuer: issuer) {
        case .refused(let message): return .error(400, message)
        case .redirect(let location, let destination, let reason):
            return .json(["error": "the request is not one Homeswift can answer", "redirect": .string(location), "destination": .string(destination), "reason": .string(reason)])
        case .valid(let valid): checked = valid
        }
        let most = caller.scope
        // Offered up to the user's role; Administer is never the one picked in advance, whatever the client asks.
        let choices = Scope.allCases.filter { $0 <= most }
        switch (request.method, route) {
        case (.GET, ["oauth", "request"]):
            return .json([
                "client": .string(checked.client.name), "destination": .string(Self.shownDestination(checked.redirectURI)), "username": .string(caller.username),
                "choices": .array(choices.map { .string($0.rawValue) }), "suggested": .string(min(checked.requested ?? most, most, .control).rawValue),
                "readOnly": .bool(mcpTransport?.configuration.readOnly == true),
            ])
        case (.POST, ["oauth", "decision"]):
            guard body["approve"]?.boolValue == true else {
                return .json(["redirect": .string(Self.redirect(checked.redirectURI, ["error": "access_denied", "error_description": "the user said no", "state": checked.state, "iss": issuer]))])
            }
            guard let chosen = body["scope_granted"]?.stringValue.flatMap(Scope.init(rawValue:)), chosen <= most else {
                return .error(400, "choose read, control or admin, up to what your account may do")
            }
            let code = oauth.issueCode(
                clientID: checked.client.id, username: caller.username, scope: chosen, redirectURI: checked.redirectURI,
                redirectURIGiven: checked.redirectURIGiven, challenge: checked.challenge)
            logger.info("OAuth app approved", metadata: ["client": "\(checked.client.name)", "username": "\(caller.username)", "scope": "\(chosen.rawValue)"])
            return .json(["redirect": .string(Self.redirect(checked.redirectURI, ["code": code, "state": checked.state, "iss": issuer]))])
        default:
            return .error(404, "unknown route")
        }
    }

    /// Where approving sends the browser, as the page shows it: the host of a web address, else the app's scheme.
    static func shownDestination(_ uri: String) -> String {
        guard let components = URLComponents(string: uri) else { return uri }
        if let host = components.host, !host.isEmpty, ["https", "http"].contains(components.scheme?.lowercased() ?? "") { return host }
        return (components.scheme ?? uri) + ":"
    }

    private func appJSON(_ grant: OAuthStore.Grant) -> JSONValue {
        let client = oauth.client(id: grant.clientID)
        return [
            "id": .string(grant.id), "client": .string(client?.name ?? "An MCP client"),
            "redirect": client?.redirectURIs.first.map { .string(Self.shownDestination($0)) } ?? .null,
            "scope": .string(grant.scope.rawValue), "created": .string(Timestamp.iso8601(grant.created)),
            "lastUsed": grant.lastUsed.map { .string(Timestamp.iso8601($0)) } ?? .null,
        ]
    }

    // MARK: MCP

    /// Who a bearer token at `/mcp` is: an OAuth access token, whose user's role, read now, caps it, and `readOnly`
    /// at read. The HomeswiftAiKit block's client tokens are not taken here: they never expire and are often admin,
    /// and the UI may be published where the MCP server's own listener is not.
    enum MCPCaller {
        case principal(Principal, grant: String)
        case expired
        case unknown
    }

    func mcpCaller(_ request: Request, transport: MCPHTTPServer) -> MCPCaller {
        guard let token = MCPHTTPServer.bearerToken(request.headers["authorization"]) else { return .unknown }
        switch oauth.validate(token) {
        case .valid(let grant):
            guard let principal = principal(for: grant, readOnly: transport.configuration.readOnly) else { return .unknown }
            return .principal(principal, grant: grant.id)
        case .expired:
            return .expired
        case .unknown:
            return .unknown
        }
    }

    /// A grant's principal: named after its client and user, at most what the user's role allows now. A user who is
    /// not an administrator controls accessories but, as in the UI, does not see the log, config.json or the
    /// pairings (`HomeswiftCatalog.administratorOnly`). Nil once the user is gone.
    func principal(for grant: OAuthStore.Grant, readOnly: Bool) -> Principal? {
        let administrator: Bool
        if configuration.auth == .none {
            administrator = true
        } else {
            guard let user = users.user(named: grant.username) else { return nil }
            administrator = user.admin
        }
        let client = oauth.client(id: grant.clientID)?.name ?? "An MCP client"
        return Principal(
            name: "\(client) (\(grant.username))", scope: min(grant.scope, administrator ? .admin : .control, readOnly ? .read : .admin),
            hidden: administrator ? [] : HomeswiftCatalog.administratorOnly)
    }

    private func mcpEndpoint(_ request: Request, transport: MCPHTTPServer) async -> Reply {
        if let origin = request.headers["origin"], !transport.originAllowed(origin, host: request.headers["host"]) {
            logger.warning("MCP request from a forbidden origin", metadata: ["origin": "\(origin)", "remote": "\(request.remote)"])
            return .error(403, "origin not allowed")
        }
        let metadata = resourceMetadataAddress(request)
        let principal: Principal
        let grant: String
        switch mcpCaller(request, transport: transport) {
        case .principal(let found, let id):
            mcpThrottle.succeeded(request.remote)
            principal = found
            grant = id
        case let outcome:
            // An expired access token is the normal end of its hour, not a guess: only unknown tokens are slowed down.
            if case .unknown = outcome, request.headers["authorization"] != nil {
                logger.warning("MCP request with a bad token", metadata: ["remote": "\(request.remote)"])
                await mcpThrottle.failAndWait(request.remote)
            }
            let challenge = request.headers["authorization"] == nil
                ? #"Bearer resource_metadata="\#(metadata)""#
                : #"Bearer resource_metadata="\#(metadata)", error="invalid_token""#
            return .data(status: 401, contentType: "application/json", body: MCPHTTPServer.errorBody("a bearer token is required"), headers: ["WWW-Authenticate": challenge])
        }
        let forwarded = MCPHTTPServer.Request(
            method: request.method, path: transport.options.path, headers: request.headers, body: request.body, remote: request.remote)
        switch await transport.handle(forwarded, principal: principal) {
        case .json(let status, let body, var headers):
            let type = headers.removeValue(forKey: "Content-Type") ?? "application/json"
            return .data(status: status, contentType: type, body: body, headers: headers)
        case .empty(let status, let headers):
            return .data(status: status, contentType: "text/plain", body: Data(), headers: headers)
        case .events(_, var headers, let stream):
            headers.removeValue(forKey: "Content-Type")
            // A stream ends once its app is disconnected or its user removed (the token's own hour does not end it).
            let readOnly = transport.configuration.readOnly
            let allowed: @Sendable () -> Bool = { [self] in
                oauth.grant(id: grant).flatMap { self.principal(for: $0, readOnly: readOnly) } == principal
            }
            return .events(stream, allowed: allowed, headers: headers)
        }
    }
}
