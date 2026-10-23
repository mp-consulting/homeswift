import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftGovee

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .critical
    return logger
}()

/// The plugin's directory in the checkout.
let pluginDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// Govee's cloud in memory: answers by URL path, records the requests.
final class FakeGovee: HTTPSending, @unchecked Sendable {
    struct Recorded { var method: String; var path: String; var query: [String: String]; var body: JSONValue?; var headers: [(String, String)] }
    private let lock = NIOLock()
    private var routes: [String: [(status: Int, body: JSONValue, headers: [(String, String)])]] = [:]
    private var failures: [String: Int] = [:]
    private(set) var requests: [Recorded] = []

    /// Answers `path` with this from now on.
    func answer(_ path: String, status: Int = 200, _ body: JSONValue, headers: [(String, String)] = []) {
        lock.withLock { routes[path] = [(status, body, headers)] }
    }

    func fail(_ path: String, times: Int = 1) { lock.withLock { failures[path, default: 0] += times } }

    func requests(to path: String) -> [Recorded] { lock.withLock { requests.filter { $0.path == path } } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let path = (request.url.host ?? "") + request.url.path
        let body = request.body.flatMap { try? JSONValue(data: $0) }
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let route: (Int, JSONValue, [(String, String)])? = try lock.withLock {
            requests.append(Recorded(method: request.method, path: path, query: query, body: body, headers: request.headers.map { ($0.name, $0.value) }))
            if let count = failures[path], count > 0 {
                failures[path] = count - 1
                throw HTTPClientError.timeout
            }
            guard var queued = routes[path], !queued.isEmpty else { return nil }
            let first = queued.count > 1 ? queued.removeFirst() : queued[0]
            routes[path] = queued
            return first
        }
        guard let (status, json, headers) = route else { return HTTPResponse(status: 404, body: Data("{}".utf8)) }
        if case .string(let raw) = json, raw.hasPrefix("raw:") {
            return HTTPResponse(status: status, headers: headers.map { (name: $0.0, value: $0.1) }, body: Data(raw.dropFirst(4).utf8))
        }
        return HTTPResponse(status: status, headers: headers.map { (name: $0.0, value: $0.1) }, body: json.encoded())
    }
}

/// A minimal but valid RGBIC payload: one sub-effect of three bytes.
let rgbicParam = Data([0x01, 0x03, 0x11, 0x22, 0x33]).base64EncodedString()

func categories(_ overrides: [String: JSONValue] = [:]) -> JSONValue {
    var effect: [String: JSONValue] = ["scenceParamId": 112, "scenceName": "Default", "scenceParam": .string(rgbicParam), "sceneCode": 212, "sceneType": 2]
    for (key, value) in overrides { effect[key] = value }
    return [[
        "categoryId": 5, "categoryName": "Natural",
        "scenes": [[
            "sceneId": 130, "sceneNameNew": ["en": "Forest", "fr": "Forêt"], "analyticName": "Forest",
            "iconUrls": ["https://cdn/light.png", "https://cdn/pressed.png", "https://cdn/dark.png"], "sceneCode": 212, "sceneType": 2,
            "lightEffects": [.object(effect)],
        ]],
    ]]
}

@Suite struct SceneLibraryTests {
    @Test func encodesScenesAndKeepsBothIcons() throws {
        let library = GoveeContent.normaliseSceneLibrary(categories(), sku: "H6173", device: "AA:BB")
        let category = try #require(library.categories.first)
        let scene = try #require(category.scenes.first)
        #expect(category.name == "Natural")
        #expect(scene.name == "Forest")
        #expect(scene.iconUrl == "https://cdn/light.png")
        #expect(scene.iconUrlDark == "https://cdn/dark.png")
        #expect(scene.code == scene.variants[0].code)
        #expect(scene.code.split(separator: ",").count > 1)
        #expect(library.source == .cloud)
        #expect(GoveeContent.normaliseSceneLibrary(categories(), sku: "H6173", device: "AA:BB", source: .offline).source == .offline)
    }

    @Test func perModelOverrides() throws {
        let overridden = categories(["specialEffect": [["scenceParamId": 3696, "scenceParam": .string(rgbicParam), "sceneCode": 999, "sceneType": 2, "supportSku": ["H6173"]]]])
        let mine = GoveeContent.normaliseSceneLibrary(overridden, sku: "H6173", device: "AA:BB").categories[0].scenes[0]
        let other = GoveeContent.normaliseSceneLibrary(overridden, sku: "H6001", device: "AA:BB").categories[0].scenes[0]
        #expect(mine.code != other.code)
        let activation = decoded(String(try #require(mine.code.split(separator: ",").last)))
        #expect(Array(activation[2..<5]) == [0x04, 0xE7, 0x03])
        let ignored = categories(["specialEffect": [["scenceParam": .string(rgbicParam), "sceneCode": 999, "supportSku": ["H9999"]]]])
        #expect(GoveeContent.normaliseSceneLibrary(ignored, sku: "H6173", device: "AA:BB").categories[0].scenes[0].code
            == GoveeContent.normaliseSceneLibrary(categories(), sku: "H6173", device: "AA:BB").categories[0].scenes[0].code)
    }

    @Test func variantsAndMetadata() throws {
        guard case .array(var list) = categories(), case .object(var category) = list[0], case .array(var scenes)? = category["scenes"],
            case .object(var scene) = scenes[0], case .array(var effects)? = scene["lightEffects"]
        else { Issue.record("fixture"); return }
        effects.append(["scenceParamId": 113, "scenceName": "Fast", "scenceParam": .string(rgbicParam), "sceneCode": 212, "sceneType": 2])
        scene["lightEffects"] = .array(effects)
        scenes[0] = .object(scene)
        category["scenes"] = .array(scenes)
        list[0] = .object(category)
        let multi = GoveeContent.normaliseSceneLibrary(.array(list), sku: "H6173", device: "AA:BB").categories[0].scenes[0]
        #expect(multi.variants.map(\.name) == ["Default", "Fast"])
        #expect(multi.variants.map(\.id) == [112, 113])
        let withSpeed = GoveeContent.normaliseSceneLibrary(categories(["speedInfo": ["supSpeed": true], "supportDirections": [1, 2]]), sku: "H6173", device: "AA:BB")
        #expect(withSpeed.categories[0].scenes[0].variants[0].supportsSpeed)
        #expect(withSpeed.categories[0].scenes[0].variants[0].supportedDirections == [1, 2])
    }

    @Test func dropsUnusableScenes() {
        let broken: JSONValue = [["categoryId": 1, "categoryName": "Broken", "scenes": [["sceneId": 1, "lightEffects": [[:]]]]]]
        #expect(GoveeContent.normaliseSceneLibrary(broken, sku: "H6173", device: "AA:BB").categories.isEmpty)
        #expect(GoveeContent.normaliseSceneLibrary(nil, sku: "H6173", device: "AA:BB").categories.isEmpty)
    }

    @Test func sceneCodeFallsBackToTheScene() throws {
        guard case .array(var list) = categories(), case .object(var category) = list[0], case .array(var scenes)? = category["scenes"],
            case .object(var scene) = scenes[0], case .array(var effects)? = scene["lightEffects"], case .object(var effect) = effects[0]
        else { Issue.record("fixture"); return }
        effect["sceneCode"] = nil
        effects[0] = .object(effect)
        scene["lightEffects"] = .array(effects)
        scenes[0] = .object(scene)
        category["scenes"] = .array(scenes)
        list[0] = .object(category)
        let code = GoveeContent.normaliseSceneLibrary(.array(list), sku: "H6173", device: "AA:BB").categories[0].scenes[0].code
        #expect(decoded(String(try #require(code.split(separator: ",").last)))[3] == 212)
    }

    @Test func modes() {
        #expect(GoveeContent.modes[10] == "scene")
        #expect(GoveeContent.modes[8] == "music")
        #expect(GoveeContent.modes[11] == "diy")
        #expect(GoveeContent.functionSupport(["modes": [10, ["componentId": 8], 99]]) == .init(modes: ["scene", "music"], modeIds: [10, 8, 99]))
        #expect(GoveeContent.functionSupport(["components": [["componentId": "11"]]]).modes == ["diy"])
        #expect(GoveeContent.functionSupport(nil).modeIds.isEmpty)
    }

    @Test func diyEntries() {
        let entries = GoveeContent.diyEntries([["groupName": "Mine", "diys": [["diyId": 7, "diyName": "Party", "effectStr": "", "coverUrl": "https://x/y.png"], ["name": "no code"]]]])
        #expect(entries.count == 1)
        #expect(entries[0].name == "Party" && entries[0].group == "Mine" && entries[0].iconUrl == "https://x/y.png")
        #expect(entries[0].code == SceneCodes.framesToCode(SceneCodes.encodeDIY(effect: "", code: 7)))
    }
}

@Suite struct OfflineCatalogueTests {
    @Test func rgbicModelsGetTheRicherSet() throws {
        #expect(SceneCatalogue.isRGBIC("H6173"))
        #expect(SceneCatalogue.isRGBIC("h6173"))
        #expect(!SceneCatalogue.isRGBIC("H6001"))
        let rgbic = try #require(SceneCatalogue.library(sku: "H6173", device: "AA:BB"))
        let rgb = try #require(SceneCatalogue.library(sku: "H6001", device: "AA:BB"))
        let count = { (library: GoveeContent.SceneLibrary) in library.categories.reduce(0) { $0 + $1.scenes.count } }
        // The Homebridge plugin's counts for the bundled catalogue.
        #expect(rgbic.categories.count == 9 && count(rgbic) == 124)
        #expect(rgb.categories.count == 4 && count(rgb) == 82)
        #expect(rgbic.categories.map(\.name).contains("Music"))
        #expect(rgbic.source == .offline)
        #expect(rgbic.categories[0].scenes[0].name == "Sunrise")
        #expect(rgbic.categories[0].scenes[0].code == "MwUEAAAAAAAAAAAAAAAAAAAAADI=")
        #expect(rgb.categories[2].scenes[1].name == "Dating")
        #expect(rgb.categories[2].scenes[1].code == "MwUEBQAAAAAAAAAAAAAAAAAAADc=")
    }

    @Test func everySceneHasAnIconAndUsableFrames() throws {
        let library = try #require(SceneCatalogue.library(sku: "H6173", device: "AA:BB"))
        for scene in library.categories.flatMap(\.scenes) {
            #expect(scene.iconUrl?.hasPrefix("https://") == true, "\(scene.name)")
            let frames = SceneCodes.codeToFrames(scene.code)
            #expect(frames.allSatisfy { decoded($0).count == 20 }, "\(scene.name)")
            #expect(Array(decoded(frames.last!)[0..<3]) == [0x33, 0x05, 0x04], "\(scene.name)")
        }
    }

    @Test func embeddedCatalogueIsCurrent() throws {
        let json = try String(contentsOf: pluginDirectory.appendingPathComponent("Resources/scene-library.json"), encoding: .utf8)
        #expect(SceneCatalogue.json == json.trimmingCharacters(in: .whitespacesAndNewlines), "run swift Plugins/Govee/Scripts/embed-scene-library.swift")
    }
}

@Suite struct EmbeddedFilesTests {
    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: pluginDirectory.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(GoveePlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(try JSONValue(string: GoveePlugin.configurationSchemaJSON!)["pluginAlias"] == "Govee")
    }

    @Test func webFilesAreCurrent() throws {
        let directory = pluginDirectory.appendingPathComponent("Web")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
        #expect(names == GoveePlugin.webFiles.keys.sorted())
        for name in names {
            let content = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(GoveePlugin.webFiles[name]?.body == content, "\(name) is stale: run swift Scripts/embed-assets.swift web Plugins/Govee/Web Plugins/Govee/Sources/WebFiles.swift GoveePlugin")
        }
    }

    /// The page's fields cover the schema's device options, as the Homebridge plugin's parity test checked.
    @Test func pageCoversTheSchema() throws {
        let schema = try JSONValue(string: GoveePlugin.configurationSchemaJSON!)
        let script = try #require(GoveePlugin.webFiles["app.js"]?.body)
        // Edited elsewhere on the page, or legacy slots kept for existing configurations (as the Homebridge page did).
        let allowed: Set<String> = [
            "scenes", "scene", "sceneTwo", "sceneThree", "sceneFour", "musicMode", "musicModeTwo", "videoMode", "videoModeTwo", "diyMode", "diyModeTwo",
            "diyModeThree", "diyModeFour", "segmented", "segmentedTwo", "segmentedThree", "segmentedFour",
        ]
        for key in DeviceConfigKey.allCases {
            let properties = try #require(schema["schema"]?["properties"]?[key.rawValue]?["items"]?["properties"]?.objectValue, "\(key)")
            for property in properties.keys where !allowed.contains(property) {
                if property == "musicModeLive" {
                    for sub in properties[property]?["properties"]?.objectValue?.keys ?? [:].keys { #expect(script.contains("\"musicModeLive.\(sub)\""), "musicModeLive.\(sub)") }
                    continue
                }
                #expect(script.contains("id: \"\(property)\""), "\(key).\(property) has no field on the page")
            }
        }
    }
}

@Suite struct APITests {
    static let login = "app2.govee.com/account/rest/account/v2/login"
    static let verification = "app2.govee.com/account/rest/account/v1/verification"

    @Test func clientIds() {
        // HAP-NodeJS's uuid.generate("user@example.com") is 63a71056-9261-4a24-b376-6275b7000ce8.
        #expect(GoveeAPI.hapUUID("user@example.com") == "63a71056-9261-4a24-b376-6275b7000ce8")
        #expect(GoveeAPI.hapUUID("hello") == "aaf4c61d-dcc5-4e8a-adab-ede0f3b482cd")
        #expect(GoveeAPI.clientId(username: "user@example.com") == "hb63a7105692614a24b3766275b7000c")
        #expect(GoveeAPI.clientId(username: "user@example.com").count == 32)
    }

    @Test func loginFailureMessages() {
        #expect(GoveeAPI.loginFailure(status: 401, body: ["message": "Incorrect password"]).description == "Govee login failed: Incorrect password (HTTP 401)")
        #expect(GoveeAPI.loginFailure(status: 400, body: ["msg": "Account locked"]).description == "Govee login failed: Account locked (HTTP 400)")
        let noToken = GoveeAPI.loginFailure(status: 200, body: ["status": 200, "foo": "bar"]).description
        #expect(noToken.contains("HTTP 200"))
        #expect(noToken.contains(#"Server response: {"foo":"bar","status":200}"#))
        #expect(noToken.contains("Bluetooth or LAN"))
        #expect(GoveeAPI.loginFailure(status: 200, body: nil).description.contains("Server response: (empty body)"))
        let long = GoveeAPI.loginFailure(status: 200, body: ["blob": .string(String(repeating: "x", count: 1000))]).description
        #expect(long.contains("…"))
        #expect(long.count < 900)
    }

    @Test func loginSendsTheStableClientIdAndTheAppHeaders() async throws {
        let govee = FakeGovee()
        govee.answer(Self.login, ["client": ["token": "tok-123", "accountId": 42, "topic": "GD/abc"]])
        let api = GoveeAPI(transport: govee, clientId: GoveeAPI.clientId(username: "user@example.com"))
        let login = try await api.login(username: "user@example.com", password: "pw", code: nil)
        #expect(login == GoveeAPI.Login(accountId: "42", token: "tok-123", topic: "GD/abc"))
        let request = try #require(govee.requests(to: Self.login).first)
        #expect(request.body?["client"] == .string(api.clientId))
        #expect(request.body?["code"] == nil)
        #expect(request.headers.contains { $0.0 == "appVersion" && $0.1 == GoveeAPI.appVersion })
        #expect(!request.headers.contains { $0.0 == "Authorization" })
    }

    @Test func newDeviceChallengeRequestsACode() async throws {
        let govee = FakeGovee()
        govee.answer(Self.login, ["status": 454])
        govee.answer(Self.verification, [:])
        let api = GoveeAPI(transport: govee, clientId: "hb1")
        await #expect(throws: GoveeAPIError.twoFactorRequired(Lang.twoFARequired)) { try await api.login(username: "user@example.com", password: "pw", code: nil) }
        #expect(govee.requests(to: Self.verification).first?.body?["email"] == "user@example.com")
        #expect(govee.requests(to: Self.verification).first?.body?["type"] == 8)
    }

    @Test func refusedCodeDoesNotAskForAnother() async throws {
        let govee = FakeGovee()
        govee.answer(Self.login, ["status": 454])
        let api = GoveeAPI(transport: govee, clientId: "hb1")
        await #expect(throws: GoveeAPIError.twoFactorInvalid(GoveeAPI.settingsCodeInvalid)) {
            try await api.login(username: "user@example.com", password: "pw", code: "0000", audience: .settingsPage)
        }
        #expect(govee.requests(to: Self.verification).isEmpty)
        #expect(govee.requests(to: Self.login).first?.body?["code"] == "0000")
    }

    @Test func refusedPasswordIsDiagnosed() async {
        let govee = FakeGovee()
        govee.answer(Self.login, ["status": 401, "message": "Incorrect password"])
        let api = GoveeAPI(transport: govee, clientId: "hb1")
        do {
            _ = try await api.login(username: "u", password: "p", code: nil)
            Issue.record("no error")
        } catch {
            #expect("\(error)".contains("Incorrect password"))
        }
    }

    @Test func accountRetriesWhenGoveeCannotBeReached() async throws {
        let govee = FakeGovee()
        govee.fail(Self.login, times: 2)
        govee.answer(Self.login, ["client": ["token": "tok", "accountId": "acc", "topic": "t"]])
        govee.answer("app2.govee.com/app/v1/account/iot/key", ["data": ["endpoint": "aws.example", "p12": "AAEC", "p12Pass": "secret"]])
        let account = GoveeAccount(api: GoveeAPI(transport: govee, clientId: "hb1"), username: "u", password: "p", code: nil, logger: testLogger, retryDelay: .milliseconds(1))
        let result = try await account.login()
        #expect(result.credentials == AccountCredentials(topic: "t", token: "tok", accountId: "acc", endpoint: "aws.example", iotPass: "secret"))
        #expect(result.iot == "AAEC")
        #expect(govee.requests(to: Self.login).count == 3)
        #expect(govee.requests(to: "app2.govee.com/app/v1/account/iot/key").first?.headers.contains { $0.0 == "Authorization" && $0.1 == "Bearer tok" } == true)
    }
}

@Suite struct CredentialStoreTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("govee-credentials-\(UUID().uuidString)")
    let credentials = AccountCredentials(topic: "t", token: "tok", accountId: "acc", endpoint: "e", iotPass: "p")

    @Test func roundTripsOwnerOnly() throws {
        let store = CredentialStore(directory: directory, username: "user@example.com", logger: testLogger)
        try store.save(credentials, iotCertificate: Data("certificate".utf8).base64EncodedString())
        #expect(store.load() == credentials)
        #expect(try store.certificate() == Data("certificate".utf8))
        for url in [store.iotFile, store.credentialsFile] {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func ignoresAnotherUserOrAMissingCertificate() throws {
        try CredentialStore(directory: directory, username: "old@example.com", logger: testLogger).save(credentials, iotCertificate: "")
        #expect(CredentialStore(directory: directory, username: "new@example.com", logger: testLogger).load() == nil)
        let store = CredentialStore(directory: directory, username: "old@example.com", logger: testLogger)
        #expect(store.load() == credentials)
        try FileManager.default.removeItem(at: store.iotFile)
        #expect(store.load() == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func forgetsClearedCredentials() throws {
        let store = CredentialStore(directory: directory, username: "user@example.com", logger: testLogger)
        try store.save(credentials, iotCertificate: "")
        store.clear()
        #expect(store.load() == nil)
        try? FileManager.default.removeItem(at: directory)
    }
}
