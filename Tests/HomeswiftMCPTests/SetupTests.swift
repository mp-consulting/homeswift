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
        // The lamp's night light: an accessory of the same device, as UniFi's `<MAC>.PackageCamera`.
        try context.add(Accessory(id: "Pairable:lamp.night", name: "Night light", category: .switch, services: [Service(.switch, name: "Night light", isPrimary: true)]))
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
            return .done(SetupOutcome(credentials: ["token": "account-token"], settings: ["email": .string(request.answer("email") ?? ""), "apiKey": .null]))
        case .device(let device) where device.deviceID == "tv":
            guard !request.isFirst else { return .ask(SetupPrompt(message: "Enter the PIN", fields: [SetupField("pin", label: "PIN", kind: .code)])) }
            guard request.answer("pin") == "1234" else { throw SetupError("Wrong PIN") }
            return .done(SetupOutcome(credentials: ["password": "tv-pass"], settings: ["ip": "10.0.0.2"]))
        case .device, .newDevice:
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

    init(config: String = #"{ "bridge": { "name": "Test", "port": 0 }, "platforms": [ { "platform": "Pairable", "name": "Pairable" } ] }"#,
         plugins: [any HomeswiftPlugin.Type] = [PairablePlugin.self]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        try Data(config.utf8).write(to: configURL)
        let registry = PluginRegistry(plugins)
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
        #expect(accessoryIDs() == ["Pairable:lamp", "Pairable:lamp.night"])
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

    /// A Setup the Assistant started reads where it stands, for the page to take over a step with a secret, a page to
    /// open or a button to press; a PIN, which the person reads out, stays in the conversation.
    @Test func aSetupInProgressIsTakenOverOnThePage() async throws {
        try await host.start()
        defer { Task { await host.stop() } }
        let tv = try await catalog.startSetup(platform: "Pairable", name: nil, deviceID: "tv")
        let session = try #require(tv["session"]?.stringValue)
        #expect(try catalog.setupState(session)["prompt"]?["fields"]?[0]?["key"] == "pin")
        #expect(!HomeswiftCatalog.needsThePage(tv))
        let hub = try await catalog.startSetup(platform: "Pairable", name: nil, deviceID: "hub")
        #expect(HomeswiftCatalog.needsThePage(hub))
        let account = try await catalog.startSetup(platform: "Pairable", name: nil, deviceID: nil)
        #expect(HomeswiftCatalog.needsThePage(account))
        #expect(!HomeswiftCatalog.needsThePage(["status": "done"]))
        #expect(throws: CatalogError.self) { try catalog.setupState("gone") }
    }

    /// A part left out goes in the device's Accessory Settings, beside its other settings, and reads back as written.
    @Test func aPartLeftOutIsKeptInTheDevicesAccessorySettings() async throws {
        try await host.start()
        defer { Task { await host.stop() } }
        _ = try await catalog.updateAccessorySettings([("Pairable:lamp", ["parts": ["Night": false]])])
        #expect(try block()?["_accessories"]?["lamp"]?["parts"] == ["Night": false])
        let settings = AccessorySettings(json: try #require(try block()?["_accessories"]?["lamp"]))
        #expect(settings.parts == ["Night": false] && settings.plugin.isEmpty)
        #expect(settings.json == ["parts": ["Night": false]])
        _ = try await catalog.updateAccessorySettings([("Pairable:lamp", ["parts": ["Night": true]])])
        #expect(try block()?["_accessories"]?["lamp"]?["parts"] == ["Night": true])
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
        #expect(await eventually { !accessoryIDs().contains("Pairable:lamp") && !accessoryIDs().contains("Pairable:lamp.night") })
        #expect(try await status("lamp") == "excluded")
        _ = try await catalog.editBlock(platform: "Pairable", name: nil, dryRun: false) { $0["_accessories"] = nil }
        #expect(await eventually { accessoryIDs().contains("Pairable:lamp") })
        await host.stop()
    }

    @Test func aClientAnswersASecretWithAVaultReferenceOnly() async throws {
        try await host.start()
        try catalog.vault.set("pairable-login", VaultEntry(kind: .login, fields: ["password": "account-pass"]))
        let first = try await catalog.startSetup(platform: "Pairable", name: nil, deviceID: nil)
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
        // A key the account's credentials now hold leaves the block.
        let draft: JSONValue = ["platform": "Pairable", "name": "Pairable", "apiKey": "old-key"]
        let first = try await setup.catalog.startSetup(platform: "Pairable", name: nil, deviceID: nil, block: draft)
        let session = try #require(first["session"]?.stringValue)
        #expect(try setup.block() == nil)
        let done = try await setup.catalog.continueSetup(session, answers: ["email": "me@example.com", "password": "account-pass"])
        #expect(done["status"] == "done")
        #expect(try setup.block()?["email"] == "me@example.com")
        #expect(try setup.block()?["apiKey"] == nil)
        #expect(setup.host.context(platform: "Pairable", name: nil)?.credentials()?["token"] == "account-token")
        #expect(await eventually { setup.accessoryIDs().contains("Pairable:lamp") })
        await setup.host.stop()
    }
}

/// A plugin whose account adds something its devices do without: a password on its webhooks.
actor OptionalAccountPlugin: HomeswiftPlugin {
    struct Configuration: Decodable, Sendable {}
    static let platform = "OptionalAccount"
    static let accountAuthorization = AuthorizationMethod.apiKey
    static let accountRequirement = AccountRequirement.optional(adds: "Protects the webhooks with a password.")

    let context: PluginContext
    init(configuration: Configuration, context: PluginContext) { self.context = context }
    func start() async throws {
        try context.add(Accessory(id: "OptionalAccount:hook", name: "Hook", category: .switch, services: [Service(.switch, name: "Hook", isPrimary: true)]))
    }
}

/// Where a plugin instance's account stands, as the Plugins page and its settings show it.
@Suite(.timeLimit(.minutes(1)))
struct AccountStateTests {
    let setup: SetupTests

    init() throws {
        setup = try SetupTests(config: #"{ "bridge": { "name": "Test", "port": 0 }, "platforms": [ { "platform": "Pairable", "name": "Pairable" }, { "platform": "OptionalAccount", "name": "Hooks" } ] }"#,
                               plugins: [PairablePlugin.self, OptionalAccountPlugin.self])
    }

    func instance(_ name: String) async -> JSONValue? {
        await setup.catalog.pluginsJSON()["platforms"]?.arrayValue?.first { $0["name"]?.stringValue == name }
    }

    /// Never set up, an account its devices come with Needs Authorization; set up, it does not; refused, it does again
    /// until new credentials are saved.
    @Test func aRequiredAccountNeedsAuthorizationUntilSetUpAndAgainOnceRefused() async throws {
        try await setup.host.start()
        #expect(await instance("Pairable")?["accountState"] == "notSetUp")
        #expect(await instance("Pairable")?["needsAuthorization"] == true)
        let found = try await setup.catalog.discoverDevices(platform: "Pairable", name: nil)
        #expect(found["accountState"] == "notSetUp" && found["needsAuthorization"] == true && found["accountRequired"] == true)

        let first = try await setup.catalog.startSetup(platform: "Pairable", name: nil, deviceID: nil)
        let session = try #require(first["session"]?.stringValue)
        #expect(try await setup.catalog.continueSetup(session, answers: ["email": "a@b.c", "password": "account-pass"])["status"] == "done")
        #expect(await eventually { await instance("Pairable")?["accountState"] == "setUp" })
        #expect(await instance("Pairable")?["needsAuthorization"] == false)

        // The plugin says the account refused its token: the card says so until new credentials are saved.
        let context = try #require(setup.host.context(platform: "Pairable", name: nil))
        context.accountRefused("token revoked")
        #expect(await instance("Pairable")?["accountState"] == "refused")
        #expect(await instance("Pairable")?["needsAuthorization"] == true)
        #expect(try await setup.catalog.discoverDevices(platform: "Pairable", name: nil)["accountState"] == "refused")
        try context.saveCredentials(["token": "new-token"])
        #expect(await instance("Pairable")?["accountState"] == "setUp")

        // Refused and then removed, it is not set up rather than refused.
        context.accountRefused()
        context.removeCredentials()
        #expect(context.accountRefusal == nil)
        let removed = await instance("Pairable")?["accountState"]
        #expect(removed == "notSetUp")
        await setup.host.stop()
    }

    /// An optional account left alone needs no one: the plugin runs as it should, and says what the account adds.
    @Test func anOptionalAccountNotSetUpNeedsNoOne() async throws {
        try await setup.host.start()
        #expect(await instance("Hooks")?["accountState"] == "notSetUp")
        #expect(await instance("Hooks")?["needsAuthorization"] == false)
        let plugin = await setup.catalog.pluginsJSON()["plugins"]?.arrayValue?.first { $0["platform"] == "OptionalAccount" }
        #expect(plugin?["accountRequired"] == false)
        #expect(plugin?["accountAdds"] == "Protects the webhooks with a password.")
        let found = try await setup.catalog.discoverDevices(platform: "OptionalAccount", name: "Hooks")
        #expect(found["needsAuthorization"] == false && found["accountRequired"] == false)
        // Refused, even an optional account needs someone: what it had no longer works.
        setup.host.context(platform: "OptionalAccount", name: "Hooks")?.accountRefused()
        #expect(await instance("Hooks")?["needsAuthorization"] == true)
        await setup.host.stop()
    }

    /// A paused instance is waiting for no one, whatever its account: it is resumed first.
    @Test func aPausedInstanceNeedsNoAuthorization() async throws {
        let paused = try SetupTests(config: #"{ "bridge": { "name": "Test", "port": 0 }, "platforms": [ { "platform": "Pairable", "name": "Pairable", "_paused": true } ] }"#,
                                    plugins: [PairablePlugin.self])
        try await paused.host.start()
        let json = await paused.catalog.pluginsJSON()["platforms"]?.arrayValue?.first
        #expect(json?["paused"] == true)
        #expect(json?["accountState"] == "notSetUp")
        #expect(json?["needsAuthorization"] == false)
        await paused.host.stop()
    }

    /// A plugin every accessory of which shows No Response says so; one answering again does not.
    @Test func aPluginNoneOfWhoseAccessoriesRespondsSaysSo() async throws {
        try await setup.host.start()
        #expect(await instance("Hooks")?["noneResponding"] == false)
        let accessories = try #require(setup.host.context(platform: "OptionalAccount", name: "Hooks")?.accessories)
        for accessory in accessories { accessory.isUnavailable = true }
        #expect(await instance("Hooks")?["noneResponding"] == true)
        accessories[0].isUnavailable = false
        #expect(await instance("Hooks")?["noneResponding"] == false)
        await setup.host.stop()
    }
}

/// A plugin whose devices cannot be found, added by their address (Add by address): a charger that answers at
/// `192.0.2.10`, behind a password, its port kept in its Accessory Settings unless it is the default. Its account is
/// optional, as IMOU's: both Setups are offered.
actor AddressablePlugin: HomeswiftPlugin {
    struct Configuration: Decodable, Sendable {}
    static let platform = "Addressable"
    static let accountAuthorization = AuthorizationMethod.accountLogin
    static let accountRequirement = AccountRequirement.optional(adds: "Protects the webhooks with a password.")
    static let addsDevicesByAddress = true

    let context: PluginContext
    init(configuration: Configuration, context: PluginContext) { self.context = context }

    func start() async throws {
        for (deviceID, settings) in context.allAccessorySettings where settings.plugin["host"] != nil && !context.isExcluded(deviceID) {
            try context.add(Accessory(id: context.accessoryID(of: deviceID), name: "Charger", category: .outlet, services: [Service(.outlet, name: "Charger", isPrimary: true)]))
        }
    }

    func discover() async throws -> [DiscoveredDevice] {
        context.allAccessorySettings.compactMap { deviceID, settings in
            settings.plugin["host"]?.stringValue.map { DiscoveredDevice(deviceID: deviceID, name: "Charger", address: $0, isSetUp: true) }
        }
    }

    func authorize(_ request: SetupRequest) async throws -> SetupStep {
        switch request.target {
        case .account, .device:
            return .done(SetupOutcome())
        case .newDevice:
            // Two steps: the address, then the charger's password, the host kept in the state between them.
            if let host = request.state["host"]?.stringValue {
                guard request.secret("password") == "charger-pass" else { throw SetupError("Wrong password") }
                return .done(SetupOutcome(credentials: ["password": "charger-pass"], settings: ["host": .string(host), "port": .null], deviceID: "EV-0001"))
            }
            guard let host = request.answer("host") else {
                return .ask(SetupPrompt(message: "Enter the charger's address", fields: [SetupField("host", label: "Host"), SetupField("port", label: "Port", optional: true)]))
            }
            guard host == "192.0.2.10" else { throw SetupError("Nothing answered at \(host)") }
            // A plugin that forgets to say which device it reached.
            if request.answer("port") == "1" { return .done(SetupOutcome()) }
            return .ask(SetupPrompt(message: "Enter the charger's password", fields: [SetupField("password", label: "Password", kind: .secret)]), state: ["host": .string(host)])
        }
    }
}

/// Add by address: a device the plugin cannot find, named by its address, probed, and added like a discovered one.
@Suite(.timeLimit(.minutes(1)))
struct AddByAddressTests {
    let setup: SetupTests

    init() throws {
        setup = try SetupTests(
            config: #"{ "bridge": { "name": "Test", "port": 0 }, "platforms": [ { "platform": "Addressable", "name": "Chargers", "_accessories": { "EV-0001": { "excluded": true, "port": 8080 } } }, { "platform": "Pairable", "name": "Pairable" } ] }"#,
            plugins: [AddressablePlugin.self, PairablePlugin.self])
    }

    func block() throws -> JSONValue? { try setup.catalog.readConfig()["platforms"]?.arrayValue?.first { $0["platform"] == "Addressable" } }

    @Test func aDeviceAddedByAddressIsProbedKeptAndPublished() async throws {
        try await setup.host.start()
        defer { Task { await setup.host.stop() } }
        let found = try await setup.catalog.discoverDevices(platform: "Addressable", name: "Chargers")
        #expect(found["addByAddress"] == true)
        let plugin = await setup.catalog.pluginsJSON()["plugins"]?.arrayValue?.first { $0["platform"] == "Addressable" }
        #expect(plugin?["addByAddress"] == true)

        let first = try await setup.catalog.startSetup(platform: "Addressable", name: "Chargers", deviceID: nil, addByAddress: true)
        #expect(first["status"] == "asking" && first["addByAddress"] == true && first["deviceID"] == nil)
        #expect(first["prompt"]?["fields"]?[0]?["key"] == "host")
        let session = try #require(first["session"]?.stringValue)
        let nothing = try await setup.catalog.continueSetup(session, answers: ["host": "192.0.2.50"])
        #expect(nothing["error"] == "Nothing answered at 192.0.2.50" && nothing["session"]?.stringValue == session)
        // Asked again, the field says what was answered, to correct it.
        #expect(nothing["prompt"]?["fields"]?[0]?["value"] == "192.0.2.50")
        let password = try await setup.catalog.continueSetup(session, answers: ["host": "192.0.2.10"])
        #expect(password["prompt"]?["fields"]?[0]?["kind"] == "secret" && HomeswiftCatalog.needsThePage(password))
        let done = try await setup.catalog.continueSetup(session, answers: ["password": "charger-pass"])
        #expect(done["status"] == "done" && done["deviceID"] == "EV-0001" && done["accessoryID"] == "Addressable:EV-0001")

        // Its host in its Accessory Settings, Excluded no more and its old port gone; its password in the vault only.
        #expect(try block()?["_accessories"]?["EV-0001"] == ["host": "192.0.2.10"])
        #expect(try block()?.text().contains("charger-pass") == false)
        #expect(setup.host.context(platform: "Addressable", name: "Chargers")?.credentials(for: "EV-0001")?["password"] == "charger-pass")
        #expect(await eventually { Set(setup.host.platforms.flatMap(\.accessoryIDs)).contains("Addressable:EV-0001") })
        let listed = try await setup.catalog.discoverDevices(platform: "Addressable", name: "Chargers")["devices"]?.arrayValue?.first
        #expect(listed?["deviceID"] == "EV-0001" && listed?["status"] == "setUp" && listed?["address"] == "192.0.2.10")
    }

    @Test func addByAddressIsRefusedWhereItDoesNotApply() async throws {
        try await setup.host.start()
        defer { Task { await setup.host.stop() } }
        // A plugin that finds its devices itself, and a device asked for twice over.
        await #expect(throws: CatalogError.self) { try await setup.catalog.startSetup(platform: "Pairable", name: nil, deviceID: nil, addByAddress: true) }
        #expect(try await setup.catalog.discoverDevices(platform: "Pairable", name: nil)["addByAddress"] == false)
        await #expect(throws: CatalogError.self) { try await setup.catalog.startSetup(platform: "Addressable", name: "Chargers", deviceID: "EV-0001", addByAddress: true) }
        // Done without saying which device it reached: nothing is written, and the person is asked again.
        let first = try await setup.catalog.startSetup(platform: "Addressable", name: "Chargers", deviceID: nil, addByAddress: true)
        let session = try #require(first["session"]?.stringValue)
        let unnamed = try await setup.catalog.continueSetup(session, answers: ["host": "192.0.2.10", "port": "1"])
        #expect(unnamed["status"] == "asking" && unnamed["error"]?.stringValue?.contains("did not say which device") == true)
        #expect(try block()?["_accessories"]?["EV-0001"] == ["excluded": true, "port": 8080])
    }

    /// The MCP tool takes `addByAddress`; a secret it asks for is a vault reference from a client, as in any Setup.
    @Test func startSetupTakesAddByAddressOverMCP() async throws {
        try await setup.host.start()
        defer { Task { await setup.host.stop() } }
        try setup.catalog.vault.set("charger", VaultEntry(kind: .login, fields: ["password": "charger-pass"]))
        let client = DirectClient(server: MCPServer(options: .init(version: "test"), tools: setup.catalog.tools))
        try await client.initialize()
        // Not a boolean: refused, never taken for the account's Setup.
        #expect(try await client.tool("start_setup", ["platform": "Addressable", "name": "Chargers", "addByAddress": "true"])["isError"] == true)
        let first = try await client.tool("start_setup", ["platform": "Addressable", "name": "Chargers", "addByAddress": true])["structuredContent"]
        let session = try #require(first?["session"]?.stringValue)
        _ = try await client.tool("continue_setup", ["session": .string(session), "answers": ["host": "192.0.2.10"]])
        let done = try await client.tool("continue_setup", ["session": .string(session), "answers": ["password": "vault:charger"]])["structuredContent"]
        #expect(done?["status"] == "done" && done?["accessoryID"] == "Addressable:EV-0001")
    }
}
