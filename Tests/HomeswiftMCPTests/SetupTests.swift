import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Testing

@testable import HomeswiftMCP

/// A plugin with one device of each kind of Authorization it tests: a lamp that needs none, a TV that shows a PIN, a hub
/// whose button is pressed, and an account behind a login.
actor PairablePlugin: HomeswiftPlugin {
    struct Configuration: Decodable, Sendable {}
    static let platform = "Pairable"
    static let accountAuthorization = AuthorizationMethod.accountLogin

    let context: PluginContext
    init(configuration: Configuration, context: PluginContext) { self.context = context }

    func start() async throws {
        for device in try await discover() where device.authorization == .none || context.credentials(for: device.deviceID) != nil {
            let service = Service(.switch, name: device.name, isPrimary: true)
            try context.add(Accessory(id: context.accessoryID(of: device.deviceID), name: device.name, category: .switch, services: [service]))
        }
    }

    func discover() async throws -> [DiscoveredDevice] {
        [
            DiscoveredDevice(deviceID: "lamp", name: "Lamp"),
            DiscoveredDevice(deviceID: "tv", name: "TV", address: "10.0.0.2", authorization: .deviceCode),
            DiscoveredDevice(deviceID: "hub", name: "Hub", authorization: .buttonPress),
        ]
    }

    func authorize(_ request: SetupRequest) async throws -> SetupStep {
        switch request.target {
        case .account:
            guard !request.isFirst else {
                return .ask(SetupPrompt(message: "Sign in", fields: [SetupField("email", label: "Email"), SetupField("password", label: "Password", kind: .secret)]))
            }
            guard request.answer("password") == "account-pass" else { throw SetupError("Wrong password") }
            return .done(SetupOutcome(credentials: ["token": "account-token"], settings: ["email": .string(request.answer("email") ?? "")]))
        case .device(let device) where device.deviceID == "tv":
            guard !request.isFirst else { return .ask(SetupPrompt(message: "Enter the PIN", fields: [SetupField("pin", label: "PIN", kind: .code)])) }
            guard request.answer("pin") == "1234" else { throw SetupError("Wrong PIN") }
            return .done(SetupOutcome(credentials: ["password": "tv-pass"], settings: ["ip": "10.0.0.2"]))
        case .device:
            // The button counts as pressed on the second try; what counts it is in the state, not the plugin.
            let tries = request.state["tries"]?.intValue ?? 0
            guard tries >= 1 else { return .ask(SetupPrompt(message: "Press the button", waitSeconds: 30, retryAfter: 1), state: ["tries": .number(Double(tries + 1))]) }
            return .done(SetupOutcome(credentials: ["token": "hub-token"]))
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SetupTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-setup-tests-\(UUID().uuidString)")
    let host: PluginHost
    let catalog: HomeswiftCatalog

    init(config: String = #"{ "bridge": { "name": "Test", "port": 0 }, "platforms": [ { "platform": "Pairable", "name": "Pairable" } ] }"#) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        try Data(config.utf8).write(to: configURL)
        let registry = PluginRegistry([PairablePlugin.self])
        host = try PluginHost(
            configuration: try HomeswiftConfiguration.decode(Data(config.utf8)), registry: registry, storageDirectory: directory,
            options: PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() })
        catalog = HomeswiftCatalog(host: host, logs: LogBuffer(), configURL: configURL, logger: testLogger)
    }

    func accessoryIDs() -> Set<String> { Set(host.platforms.flatMap(\.accessoryIDs)) }

    func block() throws -> JSONValue? { try catalog.readConfig()["platforms"]?.arrayValue?.first { $0["platform"] == "Pairable" } }

    func status(_ deviceID: String) async throws -> String? {
        try await catalog.discoverDevices(platform: "Pairable", name: nil)["devices"]?.arrayValue?.first { $0["deviceID"]?.stringValue == deviceID }?["status"]?.stringValue
    }

    @Test func aDeviceCodeIsAskedAgainUntilItWorksThenTheDeviceIsPublished() async throws {
        try await host.start()
        #expect(accessoryIDs() == ["Pairable:lamp"])
        #expect(try await status("lamp") == "setUp")
        #expect(try await status("tv") == "needsAuthorization")

        let first = try await catalog.startSetup(platform: "Pairable", name: nil, deviceID: "tv")
        #expect(first["status"] == "asking")
        #expect(first["prompt"]?["fields"]?[0]?["key"] == "pin")
        let session = try #require(first["session"]?.stringValue)
        let wrong = try await catalog.continueSetup(session, answers: ["pin": "0000"])
        #expect(wrong["error"] == "Wrong PIN")
        #expect(wrong["session"]?.stringValue == session)
        let done = try await catalog.continueSetup(session, answers: ["pin": "1234"])
        #expect(done["status"] == "done")
        #expect(done["accessoryID"] == "Pairable:tv")

        // The password went to the vault, the address to the device's Accessory Settings, and the plugin publishes it.
        #expect(try block()?["_accessories"]?["tv"]?["ip"] == "10.0.0.2")
        #expect(try block()?.text().contains("tv-pass") == false)
        #expect(host.context(platform: "Pairable", name: nil)?.credentials(for: "tv")?["password"] == "tv-pass")
        #expect(await eventually { accessoryIDs().contains("Pairable:tv") })
        #expect(try await status("tv") == "setUp")
        #expect(catalog.setupSessions.session(session) == nil)
        await host.stop()
    }

    @Test func aButtonPressIsRetriedAndOutlivesAReloadOfThePlugin() async throws {
        try await host.start()
        let first = try await catalog.startSetup(platform: "Pairable", name: nil, deviceID: "hub")
        #expect(first["prompt"]?["retryAfter"] == 1)
        let session = try #require(first["session"]?.stringValue)
        await host.relaunch(platform: "Pairable", name: nil)
        let done = try await catalog.continueSetup(session, answers: [:])
        #expect(done["status"] == "done")
        #expect(await eventually { accessoryIDs().contains("Pairable:hub") })
        await host.stop()
    }

    @Test func anExcludedDeviceLeavesTheBridgeAndIsNeverAdded() async throws {
        try await host.start()
        #expect(accessoryIDs().contains("Pairable:lamp"))
        _ = try await catalog.editBlock(platform: "Pairable", name: nil, dryRun: false) { $0["_accessories"] = ["lamp": ["excluded": true]] }
        #expect(await eventually { !accessoryIDs().contains("Pairable:lamp") })
        #expect(try await status("lamp") == "excluded")
        _ = try await catalog.editBlock(platform: "Pairable", name: nil, dryRun: false) { $0["_accessories"] = nil }
        #expect(await eventually { accessoryIDs().contains("Pairable:lamp") })
        await host.stop()
    }

    @Test func aClientAnswersASecretWithAVaultReferenceOnly() async throws {
        try await host.start()
        try catalog.vault.set("pairable-login", VaultEntry(kind: .login, fields: ["password": "account-pass"]))
        let first = try await catalog.startSetup(platform: "Pairable", name: nil, deviceID: nil, by: .client)
        #expect(first["method"] == "accountLogin")
        let session = try #require(first["session"]?.stringValue)
        let plain = try await catalog.continueSetup(session, answers: ["email": "a@b.c", "password": "account-pass"], by: .client)
        #expect(plain["error"]?.stringValue?.contains("vault:") == true)
        let environment = try await catalog.continueSetup(session, answers: ["email": "a@b.c", "password": "env:HOME"], by: .client)
        #expect(environment["error"]?.stringValue?.contains("only a vault: reference") == true)
        let done = try await catalog.continueSetup(session, answers: ["email": "a@b.c", "password": "vault:pairable-login"], by: .client)
        #expect(done["status"] == "done")
        #expect(try block()?["email"] == "a@b.c")
        #expect(host.context(platform: "Pairable", name: nil)?.credentials()?["token"] == "account-token")
        await host.stop()
    }

    @Test func anAccountSetUpForABlockNotSavedYetAddsTheBlock() async throws {
        let setup = try SetupTests(config: #"{ "bridge": { "name": "Test", "port": 0 }, "platforms": [] }"#)
        try await setup.host.start()
        let draft: JSONValue = ["platform": "Pairable", "name": "Pairable"]
        let first = try await setup.catalog.startSetup(platform: "Pairable", name: nil, deviceID: nil, block: draft)
        let session = try #require(first["session"]?.stringValue)
        #expect(try setup.block() == nil)
        let done = try await setup.catalog.continueSetup(session, answers: ["email": "me@example.com", "password": "account-pass"])
        #expect(done["status"] == "done")
        #expect(try setup.block()?["email"] == "me@example.com")
        #expect(setup.host.context(platform: "Pairable", name: nil)?.credentials()?["token"] == "account-token")
        #expect(await eventually { setup.accessoryIDs().contains("Pairable:lamp") })
        await setup.host.stop()
    }
}
