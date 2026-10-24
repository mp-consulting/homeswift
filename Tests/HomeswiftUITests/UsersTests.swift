import Foundation
import Homeswift
import HomeswiftAI
import Testing

@testable import HomeswiftUI

@Suite struct UserStoreTests {
    func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-\(name)-\(UUID().uuidString).json")
    }

    @Test func loadsAFileFromBeforeRolesWithItsUserAsAdministrator() throws {
        let url = temporaryURL("ui-users")
        try UserStore(url: url, iterations: 1000).createFirst(username: "rosaly", password: "correct horse battery")
        // The file as the single-account UI wrote it: no name, role nor two-factor.
        var users = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for key in ["name", "admin", "otpActive", "otpSecret"] { users[0].removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: users).write(to: url)
        let store = UserStore(url: url, iterations: 1000)
        let user = try #require(store.user(named: "Rosaly"))
        #expect(user.admin && user.name == "rosaly" && !user.otpActive)
        #expect(store.verify(username: "rosaly", password: "correct horse battery"))
        #expect(store.isAdmin("rosaly"))
    }

    /// `homeswift users add`, as the Synology installer runs it for the first account: that account is an
    /// administrator; a later one is one only when asked.
    @Test func makesTheFirstAccountAddedAnAdministrator() throws {
        let store = UserStore(url: temporaryURL("ui-users"), iterations: 1000)
        #expect(try store.create(username: "rosaly", password: "correct horse battery").admin)
        #expect(try !store.create(username: "milo", password: "battery staple lamp").admin)
        #expect(try store.create(username: "ada", password: "lamp battery horse", admin: true).admin)
    }

    /// An install made before that rule: users, no administrator. The first is promoted when the file loads.
    @Test func promotesTheFirstUserOfAFileWithoutAnAdministrator() throws {
        let url = temporaryURL("ui-users")
        let store = UserStore(url: url, iterations: 1000)
        try store.create(username: "rosaly", password: "correct horse battery")
        try store.create(username: "milo", password: "battery staple lamp")
        var users = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for index in users.indices { users[index]["admin"] = false }
        try JSONSerialization.data(withJSONObject: users).write(to: url)
        let reloaded = UserStore(url: url, iterations: 1000)
        #expect(reloaded.isAdmin("rosaly") && !reloaded.isAdmin("milo"))
        // Saved: the next load finds it so.
        #expect(UserStore(url: url, iterations: 1000).isAdmin("rosaly"))
    }

    @Test func keepsAnAdministrator() throws {
        let store = UserStore(url: temporaryURL("ui-users"), iterations: 1000)
        try store.createFirst(username: "rosaly", password: "correct horse battery")
        let milo = try store.create(username: "milo", password: "battery staple lamp", name: " Milo D. ")
        #expect(!milo.admin && milo.name == "Milo D.")
        #expect(throws: AuthError.lastAdmin) { try store.delete(username: "rosaly") }
        #expect(throws: AuthError.lastAdmin) { try store.update(username: "rosaly", admin: false) }
        // A refused change leaves the password as it was.
        #expect(throws: AuthError.lastAdmin) { try store.update(username: "rosaly", admin: false, password: "another strong phrase") }
        #expect(store.verify(username: "rosaly", password: "correct horse battery"))
        #expect(throws: AuthError.noSuchUser) { try store.update(username: "nobody", name: "x") }
        #expect(throws: AuthError.invalidName) { try store.update(username: "milo", name: String(repeating: "x", count: 65)) }
        try store.update(username: "MILO", admin: true)
        try store.update(username: "rosaly", admin: false, password: "another strong phrase")
        #expect(store.verify(username: "rosaly", password: "another strong phrase"))
        #expect(throws: AuthError.lastAdmin) { try store.delete(username: "milo") }
        try store.delete(username: "rosaly")
        #expect(store.usernames == ["milo"])
        #expect(throws: AuthError.noSuchUser) { try store.delete(username: "rosaly") }
    }

    @Test func asksForEachCodeOnce() throws {
        let url = temporaryURL("ui-users")
        let store = UserStore(url: url, iterations: 1000)
        try store.createFirst(username: "rosaly", password: "correct horse battery")
        #expect(throws: AuthError.twoFactorNotSetUp) { try store.activateTwoFactor(username: "rosaly", code: "123456") }
        let secret = try store.beginTwoFactor(username: "rosaly")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!store.checkTwoFactor(username: "rosaly", code: TOTP.code(secret: secret, at: now), at: now))   // not on yet
        #expect(throws: AuthError.wrongCode) { try store.activateTwoFactor(username: "rosaly", code: "000000x", at: now) }
        try store.activateTwoFactor(username: "rosaly", code: TOTP.code(secret: secret, at: now), at: now)
        #expect(throws: AuthError.twoFactorActive) { _ = try store.beginTwoFactor(username: "rosaly") }
        // The code that turned it on, and any of the same step, does not sign in; the next step's does, once.
        #expect(!store.checkTwoFactor(username: "rosaly", code: TOTP.code(secret: secret, at: now), at: now))
        let later = now.addingTimeInterval(30)
        #expect(store.checkTwoFactor(username: "rosaly", code: TOTP.code(secret: secret, at: later), at: later))
        #expect(!store.checkTwoFactor(username: "rosaly", code: TOTP.code(secret: secret, at: later), at: later))
        #expect(!store.checkTwoFactor(username: "rosaly", code: TOTP.code(secret: secret, at: now.addingTimeInterval(300)), at: later))
        // Kept with the user, owner-only, and on after a restart.
        #expect(UserStore(url: url, iterations: 1000).user(named: "rosaly")?.otpActive == true)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(throws: AuthError.wrongPassword) { try store.disableTwoFactor(username: "rosaly", password: "wrong horse") }
        try store.disableTwoFactor(username: "rosaly", password: "correct horse battery")
        #expect(store.user(named: "rosaly")?.otpActive == false)
        #expect(store.user(named: "rosaly")?.otpSecret == nil)
    }

    @Test func keepsOnlyTheTokensHash() throws {
        let url = temporaryURL("ui-api-tokens")
        let store = APITokenStore(url: url)
        let (token, value) = try store.create(name: " Backups ", scope: .read, createdBy: "rosaly")
        #expect(value.hasPrefix("hst_") && value.count > 40)
        #expect(token.name == "Backups" && token.lastUsed == nil && token.expires == nil)
        let file = try String(contentsOf: url, encoding: .utf8)
        #expect(!file.contains(value) && !file.contains(String(value.dropFirst(4))))
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(store.validate(value)?.id == token.id)
        #expect(APITokenStore(url: url).tokens.first?.lastUsed != nil)
        #expect(store.validate(value + "x") == nil)
        #expect(store.validate("nope") == nil)
        #expect(throws: AuthError.invalidTokenName) { try store.create(name: "  ", scope: .admin) }
        #expect(throws: AuthError.invalidExpiry) { try store.create(name: "x", scope: .admin, expiresInDays: 0) }
        // An expired token is refused.
        let old = try store.create(name: "old", scope: .admin, expiresInDays: 1, now: Date().addingTimeInterval(-2 * 86_400))
        #expect(store.validate(old.value) == nil)
        try store.revoke(id: token.id)
        #expect(store.validate(value) == nil)
        #expect(throws: AuthError.noSuchToken) { try store.revoke(id: token.id) }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct UsersServerTests {
    /// A started environment and a browser signed in as its first account, rosaly, an administrator.
    func signedIn(_ environment: UITestEnvironment) async throws -> (URL, Browser) {
        let base = try await environment.start()
        let browser = Browser(base: base)
        browser.origin = "http://127.0.0.1:\(environment.server.port!)"
        let code = try #require(environment.server.setupCode)
        #expect(try await browser.post("/api/auth/setup", ["username": "rosaly", "password": "correct horse battery", "setupCode": .string(code)]).status == 200)
        return (base, browser)
    }

    func login(_ base: URL, _ username: String, _ password: String, otp: String? = nil, origin: String) async throws -> (Browser, Browser.Response) {
        let browser = Browser(base: base)
        browser.origin = origin
        var body: [String: JSONValue] = ["username": .string(username), "password": .string(password)]
        if let otp { body["otp"] = .string(otp) }
        return (browser, try await browser.post("/api/auth/login", .object(body)))
    }

    @Test func givesEachUserTheirRole() async throws {
        let environment = try UITestEnvironment()
        let (base, admin) = try await signedIn(environment)
        defer { Task { await environment.stop() } }
        let origin = admin.origin!
        #expect(try await admin.get("/api/auth/state").json?["admin"] == true)

        // Adding users: a new name, a strong password.
        #expect(try await admin.post("/api/users", ["username": "milo", "name": "Milo", "password": "battery staple lamp"]).status == 201)
        #expect(try await admin.post("/api/users", ["username": "MILO", "password": "battery staple lamp"]).status == 409)
        #expect(try await admin.post("/api/users", ["username": "zoe", "password": "short"]).status == 400)
        let listed = try await admin.get("/api/users").json?.arrayValue ?? []
        #expect(listed.map { $0["username"] } == ["rosaly", "milo"])
        #expect(listed[0]["you"] == true && listed[1]["admin"] == false && listed[1]["name"] == "Milo")
        #expect(!(try await admin.get("/api/users").body.contains("hash")))

        // A user who is not an administrator sees the bridge and controls accessories; nothing else.
        let (milo, signedIn) = try await login(base, "Milo", "battery staple lamp", origin: origin)
        #expect(signedIn.status == 200 && signedIn.json?["username"] == "milo")
        let state = try await milo.get("/api/auth/state").json
        #expect(state?["admin"] == false && state?["name"] == "Milo" && state?["username"] == "milo")
        let status = try await milo.get("/api/status")
        #expect(status.status == 200 && status.json?["bridges"]?[0]?["setupCode"] == nil)
        #expect(try await admin.get("/api/status").json?["bridges"]?[0]?["setupCode"] == "0314-5154")
        #expect(try await milo.get("/api/accessories").status == 200)
        #expect(try await milo.get("/api/plugins").status == 200)
        #expect(try await milo.put("/api/accessories/Lamps:lamp", ["characteristic": "Brightness", "value": 70]).status == 200)
        #expect(try await milo.post("/api/accessories/Lamps:lamp/identify", [:]).status == 200)
        for (method, path) in [("GET", "/api/config"), ("GET", "/api/logs"), ("GET", "/api/qr/0.svg"), ("GET", "/api/users"), ("GET", "/api/tokens"),
                               ("GET", "/api/plugins/ElgatoKeyLights/schema"), ("GET", "/api/plugins/Lamps/Lamps/hello"), ("GET", "/api/config/block/Lamps/Lamps"),
                               ("GET", "/api/settings/bridge"), ("GET", "/api/backups"), ("GET", "/api/audit"), ("GET", "/api/pairings"), ("GET", "/api/child-bridges")] {
            #expect(try await milo.send(method, path).status == 403, "\(method) \(path)")
        }
        #expect(try await milo.put("/api/config", ["bridge": [:]]).status == 403)
        #expect(try await milo.put("/api/config/platforms/0", ["platform": "Lamps"]).status == 403)
        #expect(try await milo.post("/api/restart", [:]).status == 403)
        #expect(try await milo.post("/api/files", ["field": "certificate", "content": "x"]).status == 403)
        #expect(try await milo.post("/api/users", ["username": "eve", "password": "battery staple lamp", "admin": true]).status == 403)
        #expect(try await milo.send("DELETE", "/api/users/rosaly").status == 403)
        #expect(try await milo.post("/api/assistant/explain", ["error": "boom"]).status == 403)
        #expect(environment.restarts.withLockedValue { $0 } == 0)
        // A plugin's own page is an administrator's: anyone else gets the UI's page.
        #expect(try await milo.get("/plugins/lamps").body.contains("<title>Homeswift</title>"))
        #expect(try await admin.get("/plugins/lamps").body.contains("<title>Lamps</title>"))
        // Their own password stays theirs to change.
        #expect(try await milo.post("/api/account/password", ["current": "battery staple lamp", "new": "milo's own long phrase"]).status == 200)

        // The role is read at every request.
        #expect(try await admin.put("/api/users/milo", ["admin": true]).status == 200)
        #expect(try await milo.get("/api/config").status == 200)
        #expect(try await admin.put("/api/users/milo", ["admin": false, "name": "Milo D."]).status == 200)
        #expect(try await milo.get("/api/config").status == 403)

        // The last administrator stays one.
        #expect(try await admin.send("DELETE", "/api/users/rosaly").status == 400)
        #expect(try await admin.put("/api/users/rosaly", ["admin": false]).status == 400)
        #expect(try await admin.put("/api/users/nobody", ["name": "x"]).status == 404)

        // A new password from an administrator signs the user out everywhere.
        #expect(try await admin.put("/api/users/milo", ["password": "a fresh strong phrase"]).status == 200)
        #expect(try await milo.get("/api/status").status == 401)
        let (again, _) = try await login(base, "milo", "a fresh strong phrase", origin: origin)
        #expect(try await again.get("/api/status").status == 200)
        // Removed: signed out at once.
        #expect(try await admin.send("DELETE", "/api/users/milo").status == 200)
        #expect(try await again.get("/api/status").status == 401)
        #expect(try await admin.send("DELETE", "/api/users/milo").status == 404)
    }

    @Test func asksForTheCodeWithTwoFactorOn() async throws {
        let environment = try UITestEnvironment()
        let (base, admin) = try await signedIn(environment)
        defer { Task { await environment.stop() } }
        let origin = admin.origin!
        let (other, _) = try await login(base, "rosaly", "correct horse battery", origin: origin)

        let setup = try await admin.post("/api/account/otp/setup", [:])
        #expect(setup.status == 200)
        let encoded = try #require(setup.json?["secret"]?.stringValue)
        let secret = try #require(Base32.decode(encoded))
        #expect(setup.json?["uri"]?.stringValue?.hasPrefix("otpauth://totp/Homeswift%20%28UI%20Bridge%29:rosaly?secret=\(encoded)") == true)
        #expect(setup.json?["qr"]?.stringValue?.hasPrefix("<svg ") == true)
        #expect(try await admin.post("/api/account/otp/activate", ["code": "000000"]).status == 400)
        let now = Date()
        #expect(try await admin.post("/api/account/otp/activate", ["code": .string(TOTP.code(secret: secret, at: now))]).status == 200)
        #expect(try await admin.get("/api/auth/state").json?["twoFactor"] == true)
        #expect(try await admin.post("/api/account/otp/setup", [:]).status == 409)
        // Sessions opened without the code end; this one stays.
        #expect(try await other.get("/api/status").status == 401)
        #expect(try await admin.get("/api/status").status == 200)

        // The password, then the code: none asks for it (412, not a failure); a wrong one or one already used is refused.
        let (_, asked) = try await login(base, "rosaly", "correct horse battery", origin: origin)
        #expect(asked.status == 412 && asked.json?["twoFactor"] == true)
        #expect(try await login(base, "rosaly", "wrong horse", otp: "123456", origin: origin).1.status == 401)
        #expect(try await login(base, "rosaly", "correct horse battery", otp: TOTP.code(secret: secret, at: now), origin: origin).1.status == 401)
        let next = TOTP.code(secret: secret, at: now.addingTimeInterval(30))
        let (browser, accepted) = try await login(base, "rosaly", "correct horse battery", otp: next, origin: origin)
        #expect(accepted.status == 200)
        #expect(try await browser.get("/api/status").status == 200)
        #expect(try await login(base, "rosaly", "correct horse battery", otp: next, origin: origin).1.status == 401)
        #expect(try !String(contentsOf: environment.directory.appendingPathComponent("ui-users.json"), encoding: .utf8).contains(encoded))

        // Off with the password.
        #expect(try await admin.post("/api/account/otp/disable", ["password": "wrong horse"]).status == 403)
        #expect(try await admin.post("/api/account/otp/disable", ["password": "correct horse battery"]).status == 200)
        #expect(try await login(base, "rosaly", "correct horse battery", origin: origin).1.status == 200)
    }

    @Test func acceptsAPITokensWithTheirScope() async throws {
        let environment = try UITestEnvironment()
        let (base, admin) = try await signedIn(environment)
        defer { Task { await environment.stop() } }
        let read = try await admin.post("/api/tokens", ["name": "Dashboard", "scope": "read"])
        #expect(read.status == 201)
        let readToken = try #require(read.json?["token"]?.stringValue)
        let adminToken = try #require(try await admin.post("/api/tokens", ["name": "Backups", "scope": "admin", "expiresInDays": 30]).json?["token"]?.stringValue)
        #expect(try await admin.post("/api/tokens", ["name": "x", "scope": "root"]).status == 400)
        #expect(try await admin.post("/api/tokens", ["name": "x", "scope": "read", "expiresInDays": 0]).status == 400)
        let listed = try await admin.get("/api/tokens")
        #expect(listed.json?.arrayValue?.map { $0["name"] } == ["Backups", "Dashboard"])
        #expect(listed.json?[0]?["expires"]?.stringValue != nil && listed.json?[1]?["createdBy"] == "rosaly")
        #expect(!listed.body.contains(readToken) && !listed.body.contains(adminToken))

        // A script: no cookie, no Origin; a cross-site Origin does not matter to a bearer token.
        let script = Browser(base: base)
        func call(_ method: String, _ path: String, token: String, body: String? = nil, crossSite: Bool = false) async throws -> Int {
            var headers = ["Authorization": "Bearer \(token)"]
            if crossSite { headers["Origin"] = "http://evil.example"; headers["Sec-Fetch-Site"] = "cross-site" }
            return try await script.send(method, path, body: body, headers: headers).status
        }
        #expect(try await call("GET", "/api/status", token: readToken) == 200)
        #expect(try await call("GET", "/api/accessories", token: readToken) == 200)
        #expect(try await call("GET", "/api/config", token: readToken) == 403)
        #expect(try await call("GET", "/api/settings/bridge", token: readToken) == 403)
        #expect(try await call("GET", "/api/settings/bridge", token: adminToken) == 200)
        #expect(try await call("PUT", "/api/accessories/Lamps:lamp", token: readToken, body: #"{"characteristic":"Brightness","value":10}"#) == 403)
        #expect(try await call("GET", "/api/config", token: adminToken) == 200)
        #expect(try await call("PUT", "/api/accessories/Lamps:lamp", token: adminToken, body: #"{"characteristic":"Brightness","value":10}"#, crossSite: true) == 200)
        #expect(environment.writes.withLockedValue { $0 }.last?.1 == .int(10))
        // Tokens name no account: no users, tokens or passwords through them.
        #expect(try await call("GET", "/api/users", token: adminToken) == 403)
        #expect(try await call("POST", "/api/tokens", token: adminToken, body: #"{"name":"more","scope":"admin"}"#) == 403)
        #expect(try await call("POST", "/api/account/password", token: adminToken, body: #"{"current":"a","new":"b"}"#) == 403)
        #expect(try await call("GET", "/api/status", token: "hst_unknown") == 401)
        #expect(try await script.send("GET", "/api/status", headers: ["Authorization": "Basic cm9zYWx5"]).status == 401)
        // A cookie session still needs its own Origin for a mutation.
        let cookieOrigin = admin.origin
        admin.origin = "http://evil.example"
        #expect(try await admin.put("/api/accessories/Lamps:lamp", ["characteristic": "Brightness", "value": 20]).status == 403)
        admin.origin = cookieOrigin

        #expect(try await admin.get("/api/tokens").json?[1]?["lastUsed"]?.stringValue != nil)
        let id = try #require(try await admin.get("/api/tokens").json?[1]?["id"]?.stringValue)
        #expect(try await admin.send("DELETE", "/api/tokens/\(id)").status == 200)
        #expect(try await call("GET", "/api/status", token: readToken) == 401)
        #expect(try await admin.send("DELETE", "/api/tokens/\(id)").status == 404)
    }

    /// Never, as the page sends it: `"expiresInDays": null`.
    @Test func makesAPITokensThatNeverExpire() async throws {
        let environment = try UITestEnvironment()
        let (_, admin) = try await signedIn(environment)
        defer { Task { await environment.stop() } }
        let never = try await admin.post("/api/tokens", ["name": "Forever", "scope": "read", "expiresInDays": nil])
        #expect(never.status == 201, "\(never.body)")
        #expect(try await admin.post("/api/tokens", ["name": "Unset", "scope": "read"]).status == 201)
        #expect(try await admin.post("/api/tokens", ["name": "x", "scope": "read", "expiresInDays": "soon"]).status == 400)
        let listed = try await admin.get("/api/tokens").json?.arrayValue ?? []
        #expect(listed.map { $0["name"] } == ["Unset", "Forever"])
        #expect(listed.allSatisfy { $0["expires"]?.stringValue == nil })
    }

    @Test func limitsEachUsersAssistantRequests() async throws {
        let environment = try UITestEnvironment(assistant: true) { $0.assistantRateLimiter = SlidingWindowRateLimiter(limit: 2, window: 60) }
        let (_, admin) = try await signedIn(environment)
        defer { Task { await environment.stop() } }
        #expect(try await admin.get("/api/assistant").json?["enabled"] == true)
        let limiter = environment.server.options.assistantRateLimiter
        _ = limiter.consume("rosaly")
        _ = limiter.consume("rosaly")
        let refused = try await admin.post("/api/assistant/explain", ["error": "boom"])
        #expect(refused.status == 429)
        #expect(refused.json?["error"]?.stringValue == SlidingWindowRateLimiter.refusal)
        #expect(Int(refused.headers["retry-after"] ?? "") ?? 0 >= 1)
        #expect(try await admin.post("/api/assistant/chat", ["text": "hello"]).status == 429)
        #expect(try await admin.post("/api/assistant/config", ["platform": "ElgatoKeyLights", "request": "two lights"]).status == 429)
        // Per user: someone else still has their requests.
        #expect(limiter.peek("milo").allowed)
    }

    @Test func givesAUsersChatReadOnlyTools() async throws {
        let environment = try UITestEnvironment()
        _ = try await environment.start()
        defer { Task { await environment.stop() } }
        let administrator = await environment.server.chat.conversation(for: "rosaly", admin: true).toolNames
        #expect(administrator.contains("set_security_accessory") && administrator.contains("patch_config") && administrator.contains("get_config"))
        let user = await environment.server.chat.conversation(for: "milo", admin: false).toolNames
        #expect(user.contains("list_accessories") && user.contains("get_server_status"))
        for name in ["set_accessory", "set_security_accessory", "patch_config", "restart_bridge", "get_config", "search_logs", "reset_pairings"] {
            #expect(!user.contains(name), "\(name)")
        }
        // A role that changes starts the conversation afresh with the new tools.
        #expect(await environment.server.chat.conversation(for: "milo", admin: true).toolNames.contains("set_accessory"))
    }

    @Test func keepsTheLogFromOtherUsersEventStreams() async throws {
        let hub = EventHub()
        let stream = hub.stream(logs: false)
        hub.broadcast(event: "log", payload: ["text": "secret line"])
        hub.broadcast(event: "accessory", payload: ["id": "Lamps:lamp"])
        hub.close()
        var text = ""
        for await chunk in stream { text += String(decoding: chunk, as: UTF8.self) }
        #expect(text.contains("event: hello") && text.contains("event: accessory") && !text.contains("secret line"))
    }
}
