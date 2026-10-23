import Crypto
import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing
import _CryptoExtras

@testable import Homeswift
@testable import HomeswiftLGThinQ

@Suite struct ConfigurationTests {
    @Test func decodesARealisticBlock() throws {
        let block = """
            {
              "platform": "LGThinQ", "name": "LG ThinQ", "auth_mode": "token", "refresh_token": "abc", "username": "me@example.com",
              "password": "secret", "country": "US", "language": "en-US", "thinq1": true, "refresh_interval": "30",
              "devices": [
                { "id": "ac-1", "name": "Living Room AC", "type": "AC", "serial_number": "SN", "ac_mode": "COOLING", "ac_swing_mode": "VERTICAL",
                  "ac_air_quality": true, "ac_temperature_sensor": true, "ac_humidity_sensor": false, "ac_led_control": true, "ac_fan_control": true,
                  "ac_jet_control": true, "ac_energy_save": false, "ac_air_clean": true, "ac_temperature_unit": "F",
                  "ac_buttons": [{ "name": "Dry", "op_mode": 1 }, { "name": "", "op_mode": 2 }, { "name": "Fan", "op_mode": "2" }] },
                { "id": "washer-1", "washer_trigger": true, "washer_door_lock": "true", "washer_tub_clean": false },
                { "id": "fridge-1", "ref_express_freezer": true, "ref_express_fridge": true, "ref_eco_friendly": true },
                { "id": "dw-1", "dishwasher_trigger": true },
                { "id": "purifier-1", "air_fast_mode": true }
              ],
              "_bridge": { "username": "0E:00:00:00:00:01" }
            }
            """
        let configuration = try JSONDecoder().decode(LGThinQPlugin.Configuration.self, from: Data(block.utf8))
        #expect(configuration.auth_mode == "token" && configuration.refresh_token == "abc" && configuration.thinq1 == true && configuration.refresh_interval == 30)
        let devices = try #require(configuration.devices)
        #expect(devices.map(\.id) == ["ac-1", "washer-1", "fridge-1", "dw-1", "purifier-1"])
        let ac = DeviceSettings(type: "AC", block: devices[0].raw)
        #expect(ac.string("ac_mode") == "COOLING" && ac.string("ac_swing_mode") == "VERTICAL" && ac.string("ac_temperature_unit") == "F")
        #expect(ac.flag("ac_air_quality") && !ac.flag("ac_humidity_sensor") && !ac.flag("ac_energy_save") && ac.flag("ac_air_clean"))
        #expect(ac.acButtons.map(\.name) == ["Dry", "Fan"] && ac.acButtons.map(\.opMode) == [1, 2])
        #expect(ac.serialNumber == "SN" && ac.name == "Living Room AC")
        let washer = DeviceSettings(type: "WASHER", block: devices[1].raw)
        #expect(washer.flag("washer_trigger") && washer.flag("washer_door_lock") && !washer.flag("washer_tub_clean"))
        // Defaults of the type.
        let plain = DeviceSettings(type: "AC", block: nil)
        #expect(plain.string("ac_mode") == "BOTH" && plain.string("ac_swing_mode") == "BOTH" && plain.flag("ac_energy_save") && !plain.flag("ac_fan_control"))
        #expect(DeviceSettings(type: "DISHWASHER", block: nil).flag("dishwasher_trigger") == false)

        let sparse = try JSONDecoder().decode(LGThinQPlugin.Configuration.self, from: Data(#"{"platform":"LGThinQ","thinq1":1,"refresh_interval":5}"#.utf8))
        #expect(sparse.devices == nil && sparse.thinq1 == true && sparse.refresh_interval == 5)
    }

    @Test func schemaAndPagesAreEmbedded() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let schema = try String(contentsOf: root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(LGThinQPlugin.configurationSchemaJSON == schema.trimmingCharacters(in: .whitespacesAndNewlines), "run: swift Scripts/embed-assets.swift plugin Plugins/LGThinQ LGThinQPlugin")
        #expect(try JSONValue(string: LGThinQPlugin.configurationSchemaJSON!)["pluginAlias"] == "LGThinQ")
        let web = root.appendingPathComponent("Web")
        for name in try FileManager.default.contentsOfDirectory(atPath: web.path) where !name.hasPrefix(".") {
            let file = try String(contentsOf: web.appendingPathComponent(name), encoding: .utf8)
            #expect(LGThinQPlugin.webFiles[name]?.body == file, "run: swift Scripts/embed-assets.swift web Plugins/LGThinQ/Web Plugins/LGThinQ/Sources/WebFiles.swift LGThinQPlugin (\(name))")
        }
        #expect(LGThinQPlugin.webFiles["index.html"]?.contentType == "text/html; charset=utf-8")
    }

    /// Every type with options of its own has fields on the settings page: AERO_TOWER and WASH_TOWER_2 too.
    @Test func thePageHasFieldsForEveryTypeWithOptions() throws {
        let script = try #require(LGThinQPlugin.webFiles["app.js"]?.body)
        for (type, descriptor) in DeviceRegistry.descriptors where !descriptor.defaults.isEmpty {
            #expect(script.contains("\(type):") || script.contains("\"\(type)\"") || script.contains("DEVICE_TYPE_FIELDS.\(type) ="), "\(type) has no fields on the page")
            for key in descriptor.defaults.keys where key != "ac_buttons" {
                #expect(script.contains("key: \"\(key)\""), "\(key) has no field on the page")
            }
        }
        #expect(script.contains("DEVICE_TYPE_FIELDS.AERO_TOWER = DEVICE_TYPE_FIELDS.AIR_PURIFIER"))
        #expect(script.contains("\"WASH_TOWER_2\""))
    }

    /// The Assistant's background (homebridge-ui/assistant.js), with the port's files and messages.
    @Test func assistantBackground() throws {
        let background = try #require(LGThinQPlugin.assistantBackground)
        #expect(background.count > 1000 && background.contains("Homeswift") && !background.contains("Homebridge"))
        #expect(!background.contains("thinq auth") && background.contains("plugins/") && background.contains("persist"))
        #expect(background.contains("LG rejected the sign-in") && background.contains("LG ThinQ API rate limit hit"))
    }
}

@Suite struct ClientIdentityTests {
    @Test func makesACertificateRequestOpenSSLAccepts() throws {
        let keys = try ClientIdentity.generateKeys()
        #expect(keys.privateKey.contains("BEGIN RSA PRIVATE KEY") && keys.publicKey.contains("BEGIN PUBLIC KEY"))
        let csr = try ClientIdentity.certificationRequest(keys: keys)
        #expect(csr.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----\r\n") && csr.hasSuffix("-----END CERTIFICATE REQUEST-----\r\n"))
        let stripped = ClientIdentity.stripped(csr)
        #expect(!stripped.contains("-") && !stripped.contains("\n") && !stripped.contains("\r"))
        let der = try #require(Data(base64Encoded: stripped))
        #expect(der.first == 0x30)

        // The signature verifies with the public key over the request info.
        let bytes = Array(der)
        func element(at offset: Int) -> (contentStart: Int, end: Int) {
            var length = Int(bytes[offset + 1])
            var start = offset + 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                length = bytes[(offset + 2)..<(offset + 2 + count)].reduce(0) { $0 << 8 | Int($1) }
                start += count
            }
            return (start, start + length)
        }
        let outer = element(at: 0)
        let info = element(at: outer.contentStart)
        let infoBytes = Array(bytes[outer.contentStart..<info.end])
        let algorithm = element(at: info.end)
        let signature = element(at: algorithm.end)
        let signatureBytes = Array(bytes[(signature.contentStart + 1)..<signature.end])
        let publicKey = try _RSA.Signing.PublicKey(pemRepresentation: keys.publicKey)
        #expect(publicKey.isValidSignature(.init(rawRepresentation: signatureBytes), for: SHA256.hash(data: infoBytes), padding: .insecurePKCS1v1_5))

        // And OpenSSL agrees, when it is installed.
        let openssl = ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let openssl else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lg-csr-\(UUID().uuidString).pem")
        try Data(csr.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = ["req", "-verify", "-noout", "-subject", "-in", file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(text)")
        #expect(text.contains("AWS IoT Certificate") && text.contains("Amazon"))
    }

    @Test func picksTheRootOfTheBroker() {
        #expect(RootCAs.forMQTTHost("a1b2c3-ats.iot.eu-west-1.amazonaws.com") == .amazonRootCA1)
        #expect(RootCAs.forMQTTHost("abc.iot.ruic.lgthinq.com") == .roots(pem: RootCAs.comodoAAACertificateServices))
        #expect(RootCAs.forMQTTHost("mqtt.example.com") == .roots(pem: RootCAs.verisignClass3G5))
        // The bundled roots are the pinned ones (fingerprints of the Homebridge plugin's test).
        func fingerprint(_ pem: String) -> String {
            let base64 = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
            return SHA256.hash(data: Data(base64Encoded: base64)!).map { String(format: "%02x", $0) }.joined()
        }
        #expect(fingerprint(TLSOptions.Trust.amazonRootCA1PEM) == "8ecde6884f3d87b1125ba31ac3fcb13d7016de7f57cc904fe1cb97c6ae98196e")
    }

    @Test func persistsOwnerOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lg-persist-\(UUID().uuidString)")
        let persist = Persist(directory: directory)
        var made = 0
        _ = try await persist.cacheForever("keys") { made += 1; return ["a": 1] }
        let value = try await persist.cacheForever("keys") { made += 1; return ["a": 2] }
        #expect(made == 1 && value == ["a": 1])
        let attributes = try FileManager.default.attributesOfItem(atPath: persist.url("keys").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        persist.removeItem("keys")
        #expect(persist.item("keys") == nil)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct WebPageTests {
    @Test func signsInAndListsDevicesForThePage() async throws {
        let environment = LGTestEnvironment()
        environment.lg.override("lgemembers.com") { request in
            let url = request.url.absoluteString
            if url.contains("signInAct") {
                return request.bodyText.contains("userPw=\(Auth.sha512Hex("good"))")
                    ? FakeLG.json(["account": ["loginSessionID": "s", "userID": "u", "userIDType": "LGE"]])
                    : FakeLG.json(["error": ["code": "MS.001.02", "message": "Wrong password"]])
            }
            if url.contains("signInComplete") { return FakeLG.json(["code": "SUCCESS"]) }
            if url.contains("/oauth") { return FakeLG.json(["redirect_uri": "lgaccount.lgsmartthinq:/?code=c"]) }
            return FakeLG.json([:])
        }
        environment.lg.override("lgeapi.com/oauth") { _ in FakeLG.json(["access_token": "a", "refresh_token": "the-refresh-token", "expires_in": 3600]) }
        environment.lg.add(device: ["deviceId": .string(acID), "deviceType": 401, "alias": "AC", "online": true], model: [:])
        environment.lg.add(device: ["deviceId": .string(stylerID), "deviceType": 12345, "alias": "Thing", "online": false], model: [:])
        // A block without credentials still runs, so the page can sign in.
        let host = try await environment.start(settings: ["country": "FR", "language": "fr-FR"])
        defer { Task { await host.stop() } }
        func call(_ path: String, _ body: JSONValue) async throws -> PluginWebResponse? {
            try await host.handleWebRequest(platform: "LGThinQ", name: "LG ThinQ", PluginWebRequest(method: "POST", path: path, body: body, user: "admin"))
        }
        let missing = try #require(try await call("login-by-user-pass", ["username": "me"]))
        #expect(missing.status == 400 && missing.json["error"] == "Missing required fields: password, country, language")
        let wrong = try #require(try await call("login-by-user-pass", ["username": "me", "password": "bad", "country": "FR", "language": "fr-FR"]))
        #expect(wrong.json["success"] == false && wrong.json["error"] == "Wrong password")
        let login = try #require(try await call("login-by-user-pass", ["username": "me", "password": "good", "country": "FR", "language": "fr-FR"]))
        #expect(login.json["success"] == true && login.json["token"] == "the-refresh-token")

        let devices = try #require(try await call("get-all-devices", ["refresh_token": "the-refresh-token", "country": "FR", "language": "fr-FR"]))
        #expect(devices.json["success"] == true)
        #expect(devices.json["devices"] == [
            ["id": .string(acID), "name": "AC", "type": "AC", "online": true],
            ["id": .string(stylerID), "name": "Thing", "type": 12345, "online": false],
        ])
        // LG's own page, for accounts of Google, Apple and others.
        let page = try #require(try await host.handleWebRequest(platform: "LGThinQ", name: "LG ThinQ",
            PluginWebRequest(method: "GET", path: "login-url", query: ["country": "FR", "language": "fr-FR"], user: "admin")))
        let url = try #require(page.json["url"]?.stringValue.flatMap(URLComponents.init(string:)))
        #expect(url.host == "us.m.lgaccount.com" && url.path == "/spx/login/signIn")
        #expect(url.queryItems?.first { $0.name == "redirect_uri" }?.value == "https://fake-spx.lgaccount.test/login/iabClose")
        #expect(url.queryItems?.first { $0.name == "division" }?.value == "ha")
        let direct = try #require(try await call("login-by-redirect", ["url": "https://x.test/login/iabClose?refresh_token=direct", "country": "FR", "language": "fr-FR"]))
        #expect(direct.json["token"] == "direct")
        let invalid = try #require(try await call("login-by-redirect", ["url": "https://x.test/login/iabClose?user_id=a", "country": "FR", "language": "fr-FR"]))
        #expect(invalid.json["success"] == false)
        let unknown = try await host.handleWebRequest(platform: "LGThinQ", name: "LG ThinQ", PluginWebRequest(method: "GET", path: "nope", user: "admin"))
        #expect(unknown?.status == 404)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AssistantActionTests {
    func call(_ host: PluginHost, _ name: String, _ arguments: JSONValue = [:]) async throws -> PluginWebResponse {
        let action = try #require(LGThinQPlugin.assistantActions.first { $0.name == name })
        return try #require(try await host.handleWebRequest(platform: "LGThinQ", name: "LG ThinQ", action.request(arguments: arguments, user: "admin")))
    }

    @Test func describesOnlyReadingRoutes() {
        let actions = LGThinQPlugin.assistantActions
        #expect(actions.map(\.name) == ["list_devices", "list_account_devices", "login_url"])
        #expect(actions.allSatisfy { $0.access == .read && $0.method == "GET" && !$0.confirm })
        // The sign-ins that take a password or LG's redirected address stay on the page.
        #expect(!actions.contains { ["login-by-user-pass", "login-by-redirect", "get-all-devices"].contains($0.path) })
    }

    @Test func eachActionReachesItsRoute() async throws {
        let environment = LGTestEnvironment()
        environment.lg.add(device: ["deviceId": .string(stylerID), "deviceType": 203, "alias": "Styler", "online": true], model: [:])
        environment.lg.add(device: ["deviceId": .string(ovenID), "deviceType": 301, "alias": "Oven", "online": false], model: [:])
        environment.lg.add(device: ["deviceId": .string(hoodID), "deviceType": 304, "alias": "Old hood", "platformType": "thinq1"], model: [:])
        environment.lg.add(device: ["deviceId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "deviceType": 701, "alias": "TV"], model: [:])
        var block = LGTestEnvironment.defaultSettings
        block["devices"] = [["id": stylerID], ["id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"]]
        let host = try await environment.start(settings: block)
        defer { Task { await host.stop() } }
        #expect(await environment.accessory(host, id: stylerID) != nil)

        let running = try await call(host, "list_devices")
        #expect(running.status == 200)
        #expect(running.json["devices"] == [[
            "id": .string(stylerID), "name": "Styler", "type": "STYLER", "model": "", "platform": "thinq2", "online": true, "external": false,
            "accessory": .string("LGThinQ:\(stylerID)"),
        ]])

        let account = try await call(host, "list_account_devices")
        #expect(account.status == 200 && account.json["complete"] == true)
        let devices = try #require(account.json["devices"]?.arrayValue)
        #expect(devices.map { JS.string($0["name"]) } == ["Old hood", "Oven", "Styler", "TV"])
        let byName = Dictionary(uniqueKeysWithValues: devices.map { (JS.string($0["name"]), $0) })
        #expect(byName["Styler"]?["configured"] == true && byName["Styler"]?["running"] == true && byName["Styler"]?["supported"] == true)
        #expect(byName["Oven"]?["configured"] == false && byName["Oven"]?["running"] == false && byName["Oven"]?["online"] == false && byName["Oven"]?["type"] == "OVEN")
        #expect(byName["Old hood"]?["platform"] == "thinq1" && byName["Old hood"]?["supported"] == true)
        #expect(byName["TV"]?["supported"] == false && byName["TV"]?["configured"] == true && byName["TV"]?["running"] == false)
        // The refresh token is not in the answer.
        #expect(!account.json.text().contains("refresh-1"))

        let page = try await call(host, "login_url", ["country": "FR", "language": "fr-FR"])
        #expect(page.status == 200)
        #expect(page.json["url"]?.stringValue.flatMap(URLComponents.init(string:))?.host == "us.m.lgaccount.com")
    }

    @Test func theAccountNeedsASignIn() async throws {
        let environment = LGTestEnvironment()
        let host = try await environment.start(settings: ["country": "FR", "language": "fr-FR"])
        defer { Task { await host.stop() } }
        let answer = try await call(host, "list_account_devices")
        #expect(answer.status == 409)
        #expect(try await call(host, "list_devices").json["devices"] == [])
    }
}
