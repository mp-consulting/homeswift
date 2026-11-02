import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftWingman

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// A host with one Wingman block whose plugin talks to a fake Wingman, Bonjour announcing it at 10.0.0.5.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-Wingman-tests-\(UUID().uuidString)")
    let wingman = FakeWingman()
    let rereadGap: Duration
    private let plugins = NIOLockedValueBox<[WingmanPlugin]>([])

    init(rereadGap: Duration = .zero) { self.rereadGap = rereadGap }

    var plugin: WingmanPlugin? { plugins.withLockedValue { $0.last } }

    nonisolated(unsafe) static let paired: [String: Any] = ["id": "wm-1", "name": "Mac mini", "host": "10.0.0.5", "token": FakeWingman.token, "fingerprint": FakeWingman.fingerprint]

    func start(settings: [String: Any] = ["devices": [TestEnvironment.paired]]) async throws -> PluginHost {
        var registry = PluginRegistry()
        let wingman = self.wingman
        registry.register(platform: WingmanPlugin.platform, name: WingmanPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(WingmanPlugin.Configuration.self, from: json)
            var dependencies = WingmanPlugin.Dependencies(transports: wingman)
            dependencies.browse = { _ in
                AsyncStream { continuation in
                    continuation.yield(.found(BonjourService(
                        name: "Mac mini", type: "_homeswift-wingman._tcp.", domain: "local.", hostName: "mac-mini.local.", port: 8619,
                        txt: ["v": "1", "id": "wm-1", "home": "abcd"], addresses: ["10.0.0.5"], interfaceIndex: 1)))
                }
            }
            dependencies.retry = Backoff(initial: .milliseconds(50), maximum: .milliseconds(200))
            dependencies.rereadGap = self.rereadGap
            dependencies.bridgeName = "Homeswift on test"
            dependencies.discoveryDuration = .milliseconds(200)
            let plugin = WingmanPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: WingmanPlugin.platform, name: WingmanPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

@Suite(.timeLimit(.minutes(1)))
struct WingmanTests {
    let environment = TestEnvironment()

    func accessory(_ host: PluginHost, _ id: String) async throws -> Accessory {
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == "Wingman:\(id)" } })
        return try #require(host.mainBridge.server.accessories.first { $0.id == "Wingman:\(id)" })
    }

    func web(_ plugin: WingmanPlugin?, _ method: String, _ path: String, query: [String: String] = [:], body: JSONValue = .null) async throws -> PluginWebResponse {
        try await #require(plugin).handleWebRequest(PluginWebRequest(method: method, path: path, query: query, body: body, user: "admin"))
    }

    @Test func identifyIsForwardedOnlyWhenAppleHomeExposesIt() async throws {
        let host = try await environment.start()
        let light = try await accessory(host, "light-1")
        #expect(light.supportsIdentify)
        try await light.information.characteristic(.identify).write(.bool(true))
        #expect(environment.wingman.writes.contains { $0.accessory == "light-1" && $0.characteristic == "light-identify" && $0.value == "1" })
        #expect(!Accessory(id: "unsupported", name: "Unsupported", services: []).supportsIdentify)
        await host.stop()
    }

    @Test func identifyRequiresWritableMetadataAndPropagatesFailure() async throws {
        let home = try JSONDecoder().decode(WingmanAPI.Home.self, from: JSONSerialization.data(withJSONObject: FakeWingman.home))
        var source = try #require(home.accessories.first { $0.id == "light-1" })
        let failingMirror = Mirror(source, write: { _, _, _ in throw HAPStatusError(.serviceCommunicationFailure) })
        let mirror = try #require(failingMirror)
        await #expect(throws: HAPStatusError.self) { try await mirror.accessory.information.characteristic(.identify).write(.bool(true)) }
        let before = Mirror.signature(of: source)
        let service = try #require(source.services.firstIndex { $0.id == "info-1" })
        let identify = try #require(source.services[service].characteristics.firstIndex { $0.id == "light-identify" })
        source.services[service].characteristics[identify].properties = ["read"]
        let unsupportedMirror = Mirror(source, write: { _, _, _ in Issue.record("Unexpected Identify write") })
        let unsupported = try #require(unsupportedMirror)
        #expect(!unsupported.accessory.supportsIdentify)
        #expect(Mirror.signature(of: source) != before)
    }

    @Test func aRefusedWriteCarriesWingmansWords() async throws {
        let home = try JSONDecoder().decode(WingmanAPI.Home.self, from: JSONSerialization.data(withJSONObject: FakeWingman.home))
        let source = try #require(home.accessories.first { $0.id == "light-1" })
        let refusal = WingmanError.refused(status: 500, message: "HMErrorDomain 80: Missing entitlement for API.")
        let refusingMirror = Mirror(source, write: { _, _, _ in throw refusal })
        let mirror = try #require(refusingMirror)
        let on = try #require(mirror.accessory.service(.lightbulb)?[.on])
        // Controllers still get No Response; people get why.
        let error = await #expect(throws: HAPStatusError.self) { try await on.write(.bool(true)) }
        #expect(error?.status == .serviceCommunicationFailure)
        #expect(error?.reason == "Wingman: HMErrorDomain 80: Missing entitlement for API.")
        let identify = await #expect(throws: HAPStatusError.self) { try await mirror.accessory.information.characteristic(.identify).write(.bool(true)) }
        #expect(identify?.reason == "Wingman: HMErrorDomain 80: Missing entitlement for API.")
    }

    @Test func nativeIdentifyDoesNotRequireACharacteristic() async throws {
        let home = try JSONDecoder().decode(WingmanAPI.Home.self, from: JSONSerialization.data(withJSONObject: FakeWingman.home))
        var source = try #require(home.accessories.first { $0.id == "light-1" })
        source.services.removeAll { $0.id == "info-1" }
        source.supportsIdentify = true
        let calls = NIOLockedValueBox<[String]>([])
        let supportedMirror = Mirror(source, write: { accessory, characteristic, value in
            #expect(accessory == "light-1" && value == .bool(true))
            calls.withLockedValue { $0.append(characteristic) }
        })
        let supported = try #require(supportedMirror)
        #expect(supported.accessory.supportsIdentify)
        try await supported.accessory.information.characteristic(.identify).write(.bool(true))
        #expect(calls.withLockedValue { $0 } == ["Identify"])
        source.supportsIdentify = false
        let disabled = Mirror(source, write: { _, _, _ in })
        #expect(disabled?.accessory.supportsIdentify == false)
    }

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(WingmanPlugin.Configuration.self, from: Data(#"{"platform":"Wingman"}"#.utf8))
        #expect(configuration.devices == nil)
        #expect(configuration.homes == nil)
    }

    @Test func appleHomeIsMirroredWithHomeswiftsTypesAndTheDevicesRanges() async throws {
        let host = try await environment.start()
        let light = try await accessory(host, "light-1")
        #expect(light.mirroredFrom == "Apple Home")
        #expect(light.suggestedRoom == "Salon")
        #expect(light.category == .lightbulb)
        #expect(light.information[.manufacturer]?.value == .string("Signify"))
        let bulb = try #require(light.service(.lightbulb))
        #expect(bulb.type.name == "Lightbulb")
        #expect(bulb.isPrimary)
        #expect(bulb[.on]?.value == .bool(true))
        #expect(bulb[.brightness]?.value == .int(40))
        #expect(bulb[.brightness]?.type.name == "Brightness")
        // HomeKit's range for this bulb, not HAP's default 140-500.
        #expect(bulb[.colorTemperature]?.type.minValue == 153)
        #expect(bulb[.colorTemperature]?.type.maxValue == 454)

        let sensor = try await accessory(host, "sensor-1")
        #expect(sensor.isUnreachable && sensor.showsNoResponse)
        #expect(sensor.service(.temperatureSensor)?[.currentTemperature]?.value == .double(12.5))
        // A lock target is a security control: the web UI and the MCP server ask first.
        let lock = try await accessory(host, "lock-1")
        #expect(lock.service(.lockMechanism)?[.lockTargetState]?.isSecurityControl == true)
        await host.stop()
    }

    @Test func homeswiftsOwnAccessoriesAreLeftOut() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, "light-1")
        #expect(!host.mainBridge.server.accessories.contains { $0.id == "Wingman:homeswift-switch" })
        let plugin = environment.plugin
        #expect(await eventually { (try? await web(plugin, "GET", "wingmen"))?.json["wingmen"]?.arrayValue?.first?["state"] == "connected" })
        let status = try await web(plugin, "GET", "wingmen")
        let wingman = try #require(status.json["wingmen"]?.arrayValue?.first)
        #expect(wingman["accessories"]?.doubleValue == 4)
        #expect(wingman["leftOut"]?.doubleValue == 1)
        #expect(wingman["notResponding"]?.doubleValue == 1)
        await host.stop()
    }

    /// An accessory Homeswift publishes on its own (a TV, a camera) is not bridged: its serial number tells it apart.
    @Test func homeswiftsOwnExternalAccessoriesAreLeftOutByTheirSerialNumber() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, "tv-1")
        try host.mainBridge.server.add(Accessory(
            id: "PhilipsAmbilightTV:tv", name: "Salon TV", serialNumber: "TV-SERIAL", category: .television, services: [Service(.switch, isPrimary: true)]))
        let link = try #require(await environment.plugin?.links["wm-1"])
        try await link.refresh()
        #expect(!host.mainBridge.server.accessories.contains { $0.id == "Wingman:tv-1" })
        await host.stop()
    }

    /// `since` is counted before the homes are read: a change made during the read comes as an event too.
    @Test func eventsAreCountedBeforeTheHomesAreRead() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, "light-1")
        let requests = environment.wingman.requests.filter { $0 == "events" || $0 == "homes" }
        #expect(Array(requests.prefix(2)) == ["events", "homes"])
        await host.stop()
    }

    /// Events Wingman no longer keeps were missed: the homes are read again.
    @Test func missedEventsMakeTheHomesReadAgain() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, "light-1")
        let reads = environment.wingman.requests.filter { $0 == "homes" }.count
        environment.wingman.dropKeptEvents()
        #expect(await eventually { environment.wingman.requests.filter { $0 == "homes" }.count > reads })
        await host.stop()
    }

    /// An accessory removed in the Home app leaves Homeswift at Wingman's "homes" event, not at the next refresh.
    @Test func anAccessoryRemovedInAppleHomeLeavesAtOnce() async throws {
        let host = try await environment.start()
        _ = try await accessory(host, "light-1")
        environment.wingman.remove(accessory: "light-1")
        #expect(await eventually { !host.mainBridge.server.accessories.contains { $0.id == "Wingman:light-1" } })
        await host.stop()
    }

    /// "homes" events coming without end read the homes once per gap, not once per event.
    @Test func aBurstOfHomesEventsReadsTheHomesOncePerGap() async throws {
        let environment = TestEnvironment(rereadGap: .milliseconds(400))
        let host = try await environment.start()
        _ = try await accessory(host, "light-1")
        let reads = environment.wingman.requests.filter { $0 == "homes" }.count
        let start = ContinuousClock.now
        for _ in 0..<40 {
            environment.wingman.changeHomes()
            try await Task.sleep(for: .milliseconds(25))
        }
        // A busy runner stretches the burst: allow a read per gap that actually went by, not per event.
        let elapsed = ContinuousClock.now - start
        let gaps = Int((elapsed / .milliseconds(400)).rounded(.up))
        let burst = environment.wingman.requests.filter { $0 == "homes" }.count - reads
        #expect(burst >= 1 && burst <= gaps + 2, "\(burst) reads for 40 events over \(elapsed)")
        await host.stop()
    }

    /// The token goes only to a pinned certificate: an entry without one (edited by hand) is not used.
    @Test func aWingmanWithoutAPinnedCertificateIsNotReached() async throws {
        var entry = TestEnvironment.paired
        entry["fingerprint"] = nil
        let host = try await environment.start(settings: ["devices": [entry]])
        let status = try await web(environment.plugin, "GET", "wingmen")
        #expect(status.json["wingmen"]?.arrayValue?.first?["state"] == "unpaired")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!environment.wingman.requests.contains("homes"))
        await host.stop()
    }

    /// Services without ids (an older Wingman): one primary, and two of a type kept apart.
    @Test func servicesWithoutIdsStayApart() throws {
        let on = WingmanAPI.Characteristic(id: nil, type: "00000025-0000-1000-8000-0026BB765291", properties: ["read", "write"], value: .bool(true), format: "bool")
        let first = WingmanAPI.Service(id: nil, name: "One", type: "00000049-0000-1000-8000-0026BB765291", characteristics: [on])
        let second = WingmanAPI.Service(id: nil, name: "Two", type: "00000049-0000-1000-8000-0026BB765291", characteristics: [on])
        let source = WingmanAPI.Accessory(id: "double", name: "Double Switch", services: [first, second])
        let mirror = try #require(Mirror(source) { _, _, _ in })
        let switches = mirror.accessory.services.filter { $0.type.uuid == ServiceType.switch.uuid }
        #expect(switches.count == 2)
        #expect(Set(switches.map(\.subtype)).count == 2)
        #expect(switches.filter(\.isPrimary).count == 1)
    }

    @Test func homeKitIsNotGivenTheMirroredAccessories() async throws {
        let host = try await environment.start()
        let light = try await accessory(host, "light-1")
        let database = host.mainBridge.server.database(includeValues: false).accessories.map(\.aid)
        #expect(!database.contains(light.aid))
        await host.stop()
    }

    @Test func writesReachWingmanByCharacteristicIDOverThePinnedCertificate() async throws {
        let host = try await environment.start()
        let light = try await accessory(host, "light-1")
        let brightness = try #require(light.service(.lightbulb)?[.brightness])
        let write = try #require(brightness.writeHandler(for: .int(75)))
        try await write(.int(75))
        #expect(environment.wingman.writes == [.init(accessory: "light-1", characteristic: "light-brightness", value: "75")])
        // Every connection after pairing holds Wingman to the certificate pinned then.
        #expect(environment.wingman.tlsModes.allSatisfy { $0 == .pinned(FakeWingman.fingerprint) })
        await host.stop()
    }

    /// Apple Home's No Response shows, but a write still goes to Wingman, as the Home app still tries; once HomeKit
    /// takes it the accessory answers.
    @Test func anAccessoryAppleHomeCallsUnreachableStillTakesWrites() async throws {
        environment.wingman.markUnreachable("light-1")
        let host = try await environment.start()
        let light = try await accessory(host, "light-1")
        #expect(light.showsNoResponse && !light.isUnavailable)
        let brightness = try #require(light.service(.lightbulb)?[.brightness])
        try await brightness.write(.int(75))
        #expect(environment.wingman.writes == [.init(accessory: "light-1", characteristic: "light-brightness", value: "75")])
        #expect(await eventually { !light.showsNoResponse })
        await host.stop()
    }

    @Test func aRefusedWriteIsNoResponse() async throws {
        let host = try await environment.start()
        let lock = try await accessory(host, "lock-1")
        let target = try #require(lock.service(.lockMechanism)?[.lockTargetState])
        let write = try #require(target.writeHandler(for: .int(0)))
        await #expect(throws: HAPStatusError.self) { try await write(.int(0)) }
        await host.stop()
    }

    @Test func aWriteRefusedWithoutAnyMessageIsNoResponseToo() async throws {
        let host = try await environment.start()
        let light = try await accessory(host, "light-1")
        let saturation = try #require(light.service(.lightbulb)?[.saturation])
        let write = try #require(saturation.writeHandler(for: .double(50)))
        await #expect(throws: HAPStatusError.self) { try await write(.double(50)) }
        await host.stop()
    }

    /// A new read of the homes keeps the objects of an accessory whose shape did not change, with its new values.
    @Test func aReadOfTheHomesKeepsUnchangedAccessories() async throws {
        let host = try await environment.start(settings: ["devices": [TestEnvironment.paired], "refreshMinutes": 1])
        let light = try await accessory(host, "light-1")
        let link = try #require(await environment.plugin?.links["wm-1"])
        try await link.refresh()
        #expect(host.mainBridge.server.accessories.first { $0.id == "Wingman:light-1" } === light)
        await host.stop()
    }

    @Test func valueChangesReachHomeswiftAtOnce() async throws {
        let host = try await environment.start()
        let light = try await accessory(host, "light-1")
        let brightness = try #require(light.service(.lightbulb)?[.brightness])
        environment.wingman.push(accessory: "light-1", characteristic: "light-brightness", type: "00000008-0000-1000-8000-0026BB765291", value: 90)
        #expect(await eventually { brightness.value == .int(90) })
        // A sensor that reports again answers again.
        let sensor = try await accessory(host, "sensor-1")
        environment.wingman.push(accessory: "sensor-1", characteristic: "temp", type: "00000011-0000-1000-8000-0026BB765291", value: 13)
        #expect(await eventually { !sensor.showsNoResponse })
        await host.stop()
    }

    @Test func aBridgeWingmanForgotIsShownAsUnpaired() async throws {
        environment.wingman.forgetBridge()
        let host = try await environment.start()
        #expect(await eventually {
            let status = try? await web(environment.plugin, "GET", "wingmen")
            return status?.json["wingmen"]?.arrayValue?.first?["state"] == "unpaired"
        })
        await host.stop()
    }

    // MARK: Setup

    /// Setup lists the Wingman Bonjour finds as needing its code, shows the certificate to check, refuses a wrong code,
    /// and hands the token and the certificate to the bridge's vault, the address to its Accessory Settings.
    @Test func setUpPairsAWingmanWithItsCode() async throws {
        let host = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await !plugin.announced.isEmpty })
        let devices = try await host.discover(platform: WingmanPlugin.platform, name: WingmanPlugin.name).devices
        let found = try #require(devices.first)
        #expect(devices.count == 1)
        #expect(found == DiscoveredDevice(deviceID: "wm-1", name: "Mac mini", model: "Homeswift Wingman", address: "10.0.0.5", authorization: .deviceCode))

        guard case .ask(let prompt, let state) = try await plugin.authorize(SetupRequest(target: .device(found))) else { Issue.record("expected the code"); return }
        #expect(prompt.fields == [SetupField("code", label: "Code", kind: .code)])
        #expect(prompt.text.contains("3F:9A:0C:71:3F:9A") && prompt.values["fingerprint"] == "3F:9A:0C:71:3F:9A")
        #expect(state["fingerprint"]?.stringValue == FakeWingman.fingerprint)
        await #expect(throws: SetupError("Wingman turned the code down: check it and try again")) {
            _ = try await plugin.authorize(SetupRequest(target: .device(found), answers: ["code": "111111"], state: state))
        }
        await #expect(throws: SetupError("The code has six digits")) {
            _ = try await plugin.authorize(SetupRequest(target: .device(found), answers: ["code": "4829"], state: state))
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(found), answers: ["code": "482 913"], state: state)) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.credentials == ["token": .string(FakeWingman.token), "fingerprint": .string(FakeWingman.fingerprint)])
        #expect(outcome.settings == ["host": "10.0.0.5", "name": "Mac mini"])
        #expect(outcome.deviceID == nil)
        #expect(environment.wingman.tlsModes.last == .pinned(FakeWingman.fingerprint))
        await host.stop()
    }

    /// A Wingman Bonjour does not reach, typed in the settings by its address (an entry of `devices` without an id): Setup
    /// lists it by that address and pairs it under the id Wingman gives; once set up there, the entry counts no more.
    @Test func setUpPairsAWingmanTypedByItsAddress() async throws {
        let typedEntry: [String: Any] = ["host": "10.0.0.9", "port": 9000, "name": "Office Mac"]
        let host = try await environment.start(settings: ["devices": [typedEntry]])
        let plugin = try #require(environment.plugin)
        #expect(plugin.configuredDevices().isEmpty)
        let devices = try await host.discover(platform: WingmanPlugin.platform, name: WingmanPlugin.name).devices
        let typed = try #require(devices.first { $0.deviceID == "address:10.0.0.9:9000" })
        #expect(typed == DiscoveredDevice(deviceID: "address:10.0.0.9:9000", name: "Office Mac", model: "Homeswift Wingman", address: "10.0.0.9:9000", authorization: .deviceCode))
        guard case .ask(_, let state) = try await plugin.authorize(SetupRequest(target: .device(typed))) else { Issue.record("expected the code"); return }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(typed), answers: ["code": "482913"], state: state)) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.deviceID == "wm-1")
        #expect(outcome.settings == ["host": "10.0.0.9", "port": 9000, "name": "Office Mac"])

        // What the bridge keeps of it: the Wingman runs from its Accessory Settings, and the typed entry is not listed again.
        let context = try #require(host.context(platform: WingmanPlugin.platform, name: WingmanPlugin.name))
        try context.saveCredentials(WingmanPlugin.Credentials(token: FakeWingman.token, fingerprint: FakeWingman.fingerprint), for: "wm-1")
        let block = try HomeswiftConfiguration.Platform(platform: WingmanPlugin.platform, name: WingmanPlugin.name, settings: [
            "devices": [typedEntry], "_accessories": ["wm-1": ["host": "10.0.0.9", "port": 9000, "name": "Office Mac"]],
        ])
        await host.apply(HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block]))
        _ = try await accessory(host, "light-1")
        let after = try await host.discover(platform: WingmanPlugin.platform, name: WingmanPlugin.name).devices
        #expect(after.map(\.deviceID) == ["wm-1"])
        #expect(after.first?.isSetUp == true)
        await host.stop()
    }

    /// A Wingman set up through Setup (its address in its Accessory Settings, its keys in the vault) is mirrored like one
    /// of `devices`, and shows as set up.
    @Test func aWingmanSetUpThroughSetupIsMirrored() async throws {
        let host = try await environment.start(settings: ["_accessories": ["wm-1": ["host": "10.0.0.5", "name": "Mac mini"]]])
        let context = try #require(host.context(platform: WingmanPlugin.platform, name: WingmanPlugin.name))
        try context.saveCredentials(WingmanPlugin.Credentials(token: FakeWingman.token, fingerprint: FakeWingman.fingerprint), for: "wm-1")
        await host.relaunch(platform: WingmanPlugin.platform, name: WingmanPlugin.name)
        _ = try await accessory(host, "light-1")
        let devices = try await host.discover(platform: WingmanPlugin.platform, name: WingmanPlugin.name).devices
        #expect(devices.map(\.deviceID) == ["wm-1"])
        #expect(devices.first?.isSetUp == true && devices.first?.name == "Mac mini")
        await host.stop()
    }

    /// A token and a certificate `devices` still has move into the vault; the vault's win over the entry's after that.
    @Test func aDevicesEntrysTokenMovesIntoTheVault() async throws {
        let host = try await environment.start()
        let context = try #require(host.context(platform: WingmanPlugin.platform, name: WingmanPlugin.name))
        #expect(context.credentials(for: "wm-1", as: WingmanPlugin.Credentials.self) == .init(token: FakeWingman.token, fingerprint: FakeWingman.fingerprint))
        try context.saveCredentials(WingmanPlugin.Credentials(token: "token-2", fingerprint: FakeWingman.fingerprint), for: "wm-1")
        let plugin = try #require(environment.plugin)
        #expect(plugin.configuredDevices().first?.token == "token-2")
        await host.stop()
    }

    /// A Wingman Excluded in its Accessory Settings is not reached.
    @Test func anExcludedWingmanIsNotReached() async throws {
        let host = try await environment.start(settings: ["devices": [TestEnvironment.paired], "_accessories": ["wm-1": ["excluded": true]]])
        #expect(await environment.plugin?.links.isEmpty == true)
        #expect(!environment.wingman.requests.contains("homes"))
        let devices = try await host.discover(platform: WingmanPlugin.platform, name: WingmanPlugin.name).devices
        #expect(devices.first { $0.deviceID == "wm-1" }?.isSetUp == false)
        await host.stop()
    }

    /// An instance made only for Setup, never started, looks on the network for a moment.
    @Test func setUpLooksForWingmenFromAnInstanceThatIsNotRunning() async throws {
        let host = try await environment.start(settings: [:])
        let block: JSONValue = ["platform": "Wingman", "name": "Another Wingman"]
        let devices = try await host.discover(platform: WingmanPlugin.platform, name: "Another Wingman", block: block).devices
        #expect(devices.map(\.deviceID) == ["wm-1"])
        await host.stop()
    }

    @Test func addressesKeepTheirPort() {
        #expect(WingmanPlugin.address(host: "10.0.0.5", port: 8619) == "10.0.0.5")
        #expect(WingmanPlugin.address(host: "10.0.0.5", port: 9000) == "10.0.0.5:9000")
        #expect(WingmanPlugin.address(host: "fe80::1", port: 9000) == "[fe80::1]:9000")
        #expect(WingmanPlugin.endpoint("10.0.0.5")! == ("10.0.0.5", 8619))
        #expect(WingmanPlugin.endpoint("10.0.0.5:9000")! == ("10.0.0.5", 9000))
        #expect(WingmanPlugin.endpoint("[fe80::1]:9000")! == ("fe80::1", 9000))
        #expect(WingmanPlugin.endpoint("fe80::1")! == ("fe80::1", 8619))
        #expect(WingmanPlugin.formatFingerprint(FakeWingman.fingerprint) == "3F:9A:0C:71:3F:9A")
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(WingmanPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Wingman WingmanPlugin")
        let schema = try JSONValue(string: try #require(WingmanPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "Wingman")
    }
}
