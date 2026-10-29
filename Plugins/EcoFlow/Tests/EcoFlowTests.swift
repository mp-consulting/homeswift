import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftEcoFlow

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// The devices in memory.
actor FakeAPI: EcoFlowAPI {
    private(set) var list = [EcoFlowDevice(id: "dev-1", name: "Test Device", online: true)]

    func devices() -> [EcoFlowDevice] { list }

    func schemaChanges() -> [String] { [] }

    func add(_ device: EcoFlowDevice) { list.append(device) }

    /// A change made elsewhere, in the device's own app.
    func update(deviceID: String, _ change: @Sendable (inout EcoFlowState) -> Void) {
        for index in list.indices where list[index].id == deviceID { change(&list[index].state) }
    }
}

/// Answers each path with a canned JSON body (404 for a path it does not know) and records the requests.
final class FakeTransport: HTTPSending, Sendable {
    let answers: [String: String]
    let requests = NIOLockedValueBox<[HomeswiftNetwork.HTTPRequest]>([])

    init(answers: [String: String]) { self.answers = answers }

    /// The answers are keyed by the path, and by the path and query when there is one ("path?sn=1").
    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        requests.withLockedValue { $0.append(request) }
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let key = [components?.path ?? "", components?.percentEncodedQuery].compactMap { $0 }.joined(separator: "?")
        guard let body = answers[key] else { return HomeswiftNetwork.HTTPResponse(status: 404) }
        return HomeswiftNetwork.HTTPResponse(status: 200, body: Data(body.utf8))
    }
}

/// A host with one platform block whose plugin talks to `api`.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-EcoFlow-tests-\(UUID().uuidString)")
    let api = FakeAPI()
    private let plugins = NIOLockedValueBox<[EcoFlowPlugin]>([])

    var plugin: EcoFlowPlugin? { plugins.withLockedValue { $0.last } }

    func start(settings: [String: Any] = [:]) async throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: EcoFlowPlugin.platform, name: EcoFlowPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(EcoFlowPlugin.Configuration.self, from: json)
            let plugin = EcoFlowPlugin(configuration: configuration, context: context, dependencies: .init(api: self.api))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: EcoFlowPlugin.platform, name: EcoFlowPlugin.name, settings: settings)
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

/// The request signature, checked against a value computed independently (HMAC-SHA256 of
/// "sn=SN-STREAM-ULTRA&accessKey=ak&nonce=123456&timestamp=1700000000000" under the key "sk").
let knownSignature = "fdecf59b1c1eaa3ed129a1de9b69e19c16a6db4a72356535bc2c0b383c146fb3"

@Suite(.timeLimit(.minutes(1)))
struct EcoFlowTests {
    let environment = TestEnvironment()
    let accessoryID = EcoFlowPlugin.accessoryID(deviceID: "dev-1")

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(EcoFlowPlugin.Configuration.self, from: Data(#"{"platform":"EcoFlow"}"#.utf8))
        #expect(configuration.devices == nil)
        #expect(configuration.pollingInterval == nil)
        #expect(configuration.accessKey == nil)
    }

    /// A STREAM's four flows carry their roles and add up across units (an AC Pro beside an Ultra reports 0 for each,
    /// the Ultra the system's: averaging them would halve the home's use). A station's ports have no role.
    @Test func streamReadingsCarryEnergyRoles() {
        let stream = EcoFlowDevice(id: "BK11-TEST", name: "STREAM Ultra", online: true, model: EcoFlowModel.model(serial: "BK11-TEST"))
        #expect(stream.energyTag("solar") == EnergyTag(role: .solar, device: "STREAM Ultra"))
        #expect(stream.energyTag("battery") == EnergyTag(role: .battery, device: "STREAM Ultra"))
        #expect(stream.energyTag("home") == EnergyTag(role: .home, device: "STREAM Ultra"))
        #expect(stream.energyTag("grid")?.shared == nil)
        #expect(stream.energyTag("ac1") == nil)
        #expect(EcoFlowDevice(id: "R655-TEST", name: "RIVER 3", online: true, model: EcoFlowModel.model(serial: "R655-TEST")).energyTag("output") == nil)
        // A PowerStream has no grid reading: no grid role.
        let inverter = EcoFlowDevice(id: "HW51-TEST", name: "PowerStream", online: true, model: EcoFlowModel.model(serial: "HW51-TEST"))
        #expect(inverter.energyTag("solar") == EnergyTag(role: .solar, device: "PowerStream"))
        #expect(inverter.energyTag("grid") == nil)
    }

    /// The page's order is kept by the plugin and answers `power` in it; a device it has not placed comes after the
    /// others. Each device says whether the configuration lists it.
    @Test func thePagesOrderIsKept() async throws {
        await environment.api.add(EcoFlowDevice(id: "dev-2", name: "Second", online: true))
        await environment.api.add(EcoFlowDevice(id: "dev-3", name: "Third", online: true))
        let host = try await environment.start(settings: ["devices": [["id": "dev-1", "name": "Renamed"]]])
        let plugin = try #require(environment.plugin)
        let power = { @Sendable () async throws -> [JSONValue] in
            try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "power", user: "admin")).json["devices"]?.arrayValue ?? []
        }
        #expect(await eventually { (try? await power().count) == 3 })
        #expect(try await power().map { $0["id"]?.stringValue } == ["dev-1", "dev-2", "dev-3"])
        #expect(try await power().map { $0["configured"] } == [.bool(true), .bool(false), .bool(false)])

        let saved = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "order", body: ["ids": ["dev-3", "dev-1"]], user: "admin"))
        #expect(saved.status == 200)
        #expect(try await power().map { $0["id"]?.stringValue } == ["dev-3", "dev-1", "dev-2"])

        let refused = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "order", body: ["ids": "dev-1"], user: "admin"))
        #expect(refused.status == 400)
        await host.stop()
    }

    /// A device whose level is not known yet is on the plugin's page, not in HomeKit: a new accessory would show 0 %.
    /// Once its level arrives, it gets its accessory.
    @Test func aDeviceWaitsForItsLevelBeforeHomeKit() async throws {
        var quiet = EcoFlowDevice(id: "dev-quiet", name: "Quiet", online: false)
        quiet.state = EcoFlowState(soc: nil, power: EcoFlowState.Power())
        await environment.api.add(quiet)
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == accessoryID } })
        let listed = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "power", user: "admin")).json["devices"]?.arrayValue ?? []
        #expect(listed.contains { $0["id"]?.stringValue == "dev-quiet" }, "on the page")
        #expect(!host.mainBridge.server.accessories.contains { $0.id == EcoFlowPlugin.accessoryID(deviceID: "dev-quiet") }, "not in HomeKit yet")

        await environment.api.update(deviceID: "dev-quiet") { $0 = EcoFlowState(soc: 64, power: EcoFlowState.Power()) }
        await plugin.refresh()
        #expect(host.mainBridge.server.accessories.contains { $0.id == EcoFlowPlugin.accessoryID(deviceID: "dev-quiet") })
        await host.stop()
    }

    @Test func eachDeviceBecomesAnAccessory() async throws {
        let host = try await environment.start(settings: ["devices": [["id": "dev-1", "name": "Renamed"]]])
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == accessoryID } })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
        #expect(accessoryID == "EcoFlow:dev-1")
        #expect(accessory.information.characteristic(.name).value == .string("Renamed"))
        let batteryService = try #require(accessory.service(.battery))
        #expect(batteryService.isPrimary)
        #expect(batteryService[.statusLowBattery] != nil)
        #expect(batteryService[.batteryLevel] != nil)
        #expect(batteryService[.chargingState] != nil)
        await host.stop()
    }

    @Test func changesOnTheDeviceReachHomeKit() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.mainBridge.server.accessories.contains { $0.id == accessoryID } })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
        let characteristic = try #require(accessory.service(.battery)?[.statusLowBattery])

        await environment.api.update(deviceID: "dev-1") { $0.battery.statusLowBattery = 1 }
        await environment.plugin?.refresh()
        #expect(characteristic.value.intValue == 1)
        await host.stop()
    }

    @Test func theSignatureMatchesTheDocumentedScheme() {
        let signature = EcoFlowCloud.signature(query: [(name: "sn", value: "SN-STREAM-ULTRA")], accessKey: "ak",
                                               secretKey: "sk", nonce: "123456", timestamp: 1_700_000_000_000)
        #expect(signature == knownSignature)
    }

    @Test func parametersAreSortedBeforeSigning() {
        let sorted = EcoFlowCloud.signature(query: [(name: "a", value: "1"), (name: "sn", value: "X")], accessKey: "ak",
                                            secretKey: "sk", nonce: "1", timestamp: 2)
        let unsorted = EcoFlowCloud.signature(query: [(name: "sn", value: "X"), (name: "a", value: "1")], accessKey: "ak",
                                              secretKey: "sk", nonce: "1", timestamp: 2)
        #expect(sorted == unsorted)
    }

    /// A STREAM's level is its own `f32ShowSoc` (the MQTT pushes). The REST quota's `cmsBattSoc` is the system's, or 0
    /// on a unit that does not lead it: never a unit's level, so a quota without `f32ShowSoc` does not know the level.
    @Test func theStateReadsTheQuota() {
        func state(_ quota: [String: Double]) -> EcoFlowState { EcoFlowState(readings: quota, keys: EcoFlowModel.streamDeveloper) }
        let discharging = state(["f32ShowSoc": 58.4, "powGetBpCms": -636.0, "powGetPvSum": 508.0,
                                 "powGetSysLoad": 1380.0, "powGetSysGrid": 872.0])
        #expect(discharging.battery.batteryLevel == 58)
        #expect(discharging.battery.chargingState == 0)
        #expect(discharging.battery.statusLowBattery == 0)
        #expect(discharging.power == EcoFlowState.Power(solar: 508, home: 1380, grid: 872, battery: -636))

        let charging = state(["f32ShowSoc": 26, "powGetBpCms": 35.0])
        #expect(charging.battery.chargingState == 1)

        let low = state(["f32ShowSoc": 5])
        #expect(low.battery.statusLowBattery == 1)
        #expect(state(["f32ShowSoc": 140]).battery.batteryLevel == 100)
        #expect(state(["cmsBattSoc": 0, "f32ShowSoc": 86.79]).battery.batteryLevel == 87, "this unit's percentage")
        // The system's 62 beside units at 85 and 40 (an Ultra leading an AC Pro), and an AC Pro's 0: neither is a level.
        #expect(state(["cmsBattSoc": 62, "powGetBpCms": 35.0]).knowsBatteryLevel == false)
        #expect(state(["cmsBattSoc": 0, "powGetBpCms": 35.0]).knowsBatteryLevel == false)
        #expect(EcoFlowState().battery.batteryLevel == 0)
    }

    /// The time remaining: to full while charging, to empty otherwise; 0 and 5939 are no estimate.
    @Test func theTimeRemainingIsTheDevicesEstimate() {
        let keys = EcoFlowModel.powerBank
        let charging = EcoFlowState(readings: ["254_21.3": 25.5, "254_21.262": 13.4, "254_21.269": 233, "254_21.268": 0], keys: keys)
        #expect(charging.minutesRemaining == 233)
        #expect(charging.minutesToEmpty == nil)
        let draining = EcoFlowState(readings: ["254_21.4": 12, "254_21.262": 90, "254_21.269": 5939, "254_21.268": 410], keys: keys)
        #expect(draining.minutesRemaining == 410)
        #expect(draining.minutesToFull == nil)
        let stream = EcoFlowState(readings: ["254_21.518": -300, "254_21.254": 4979, "254_21.268": 2000], keys: EcoFlowModel.streamApp)
        #expect(stream.minutesRemaining == 4979, "this unit's own battery before the system's")
    }

    @Test func devicesAreReadWithSignedRequests() async throws {
        let transport = FakeTransport(answers: [
            "/iot-open/sign/device/list": #"{"code":"0","message":"Success","data":[{"sn":"BK11-TEST-ULTRA","deviceName":"STREAM Ultra","online":1}]}"#,
            "/iot-open/sign/device/quota/all?sn=BK11-TEST-ULTRA": #"{"code":"0","message":"Success","data":{"cmsBattSoc":58,"powGetBpCms":35,"powGetPvSum":184,"powGetSysLoad":1480,"powGetSysGrid":1330}}"#,
        ])
        var cloud = EcoFlowCloud(accessKey: "ak", secretKey: "sk", baseURL: URL(string: "https://api.example.test")!, transport: transport)
        cloud.nonce = { "123456" }
        cloud.timestamp = { 1_700_000_000_000 }

        let devices = try await cloud.devices()
        #expect(devices.count == 1)
        #expect(devices[0].id == "BK11-TEST-ULTRA")
        #expect(devices[0].model?.name == "STREAM Ultra")
        #expect(devices[0].tested)
        #expect(devices[0].name == "STREAM Ultra")
        #expect(devices[0].online)
        #expect(devices[0].state.knowsBatteryLevel == false, "the REST quota's cmsBattSoc is the system's, not this unit's")
        #expect(devices[0].state.battery.chargingState == 1)
        #expect(devices[0].state.power.solar == 184)

        let requests = transport.requests.withLockedValue { $0 }
        #expect(requests.count == 2)
        #expect(requests.last?.url.absoluteString.hasSuffix("?sn=BK11-TEST-ULTRA") == true)
        let quota = try #require(requests.last)
        #expect(quota.header("sign") == EcoFlowCloud.signature(query: [(name: "sn", value: "BK11-TEST-ULTRA")], accessKey: "ak",
                                                               secretKey: "sk", nonce: "123456", timestamp: 1_700_000_000_000))
        #expect(quota.header("accessKey") == "ak")
        #expect(quota.header("nonce") == "123456")
        #expect(quota.header("timestamp") == "1700000000000")
        #expect(!quota.url.absoluteString.contains("sk"), "the secret key never goes into a request")
    }

    /// A device the API refuses, a device whose quota has none of its model's state-of-charge keys, a device whose
    /// quota is all zeros and a device with no battery for HomeKit are left out, the last logged once; the STREAM
    /// device still loads.
    @Test func otherDevicesAreLeftOut() async throws {
        let transport = FakeTransport(answers: [
            "/iot-open/sign/device/list": #"{"code":"0","message":"Success","data":[{"sn":"P101-TEST","deviceName":"DELTA Pro Ultra X","online":0},{"sn":"R655-TEST","deviceName":"RIVER 3","online":1},{"sn":"BK31-ZEROS","deviceName":"STREAM AC Pro","online":1},{"sn":"HW52-TEST","deviceName":"Smart Plug","online":1},{"sn":"BK11-TEST-ULTRA","deviceName":"STREAM Ultra","online":1}]}"#,
            "/iot-open/sign/device/quota/all?sn=P101-TEST": #"{"code":"1006","message":"current device is not allowed to get device info"}"#,
            "/iot-open/sign/device/quota/all?sn=R655-TEST": #"{"code":"0","message":"Success","data":{"bms_bmsStatus.soc":40}}"#,
            "/iot-open/sign/device/quota/all?sn=BK31-ZEROS": #"{"code":"0","message":"Success","data":{"cmsBattSoc":0,"powGetBpCms":0,"powGetPvSum":0,"powGetSysLoad":0,"powGetSysGrid":0}}"#,
            "/iot-open/sign/device/quota/all?sn=BK11-TEST-ULTRA": #"{"code":"0","message":"Success","data":{"cmsBattSoc":58,"powGetBpCms":35}}"#,
        ])
        let cloud = EcoFlowCloud(accessKey: "ak", secretKey: "sk", baseURL: URL(string: "https://api.example.test")!, transport: transport)
        let devices = try await cloud.devices()
        #expect(devices.map(\.id) == ["BK11-TEST-ULTRA"])
        #expect(devices.first?.state.power.battery == 35)
        #expect(devices.first?.state.knowsBatteryLevel == false)
        #expect(!transport.requests.withLockedValue { $0 }.contains { $0.url.absoluteString.contains("HW52") }, "a plug is not asked")
        #expect(await cloud.schemaChanges() == ["Left out the device HW52… on the developer API: Smart Plug, which the plugin does not read"])
        _ = try await cloud.devices()
        #expect(await cloud.schemaChanges().isEmpty, "once")
    }

    /// The developer API reads an older station by its JSON quota keys (the same as the app's), and a PowerOcean by its
    /// own; both are untested.
    @Test func otherModelsAreReadByTheirKeys() async throws {
        let transport = FakeTransport(answers: [
            "/iot-open/sign/device/list": #"{"code":"0","message":"Success","data":[{"sn":"DCABZ-TEST","deviceName":"DELTA Pro","online":1},{"sn":"HJ31-TEST","deviceName":"PowerOcean","online":1}]}"#,
            "/iot-open/sign/device/quota/all?sn=DCABZ-TEST": #"{"code":"0","message":"Success","data":{"ems.lcdShowSoc":"64","pd.wattsInSum":1200,"pd.wattsOutSum":300,"inv.outputWatts":290,"mppt.inWatts":8000}}"#,
            "/iot-open/sign/device/quota/all?sn=HJ31-TEST": #"{"code":"0","message":"Success","data":{"bpSoc":81,"mpptPwr":2400.5,"sysLoadPwr":900,"sysGridPwr":-1000,"bpPwr":500.5}}"#,
        ])
        let cloud = EcoFlowCloud(accessKey: "ak", secretKey: "sk", baseURL: URL(string: "https://api.example.test")!, transport: transport)
        let devices = try await cloud.devices()
        #expect(devices.map(\.id) == ["DCABZ-TEST", "HJ31-TEST"])
        #expect(devices.allSatisfy { !$0.tested })
        let delta = devices[0]
        #expect(delta.kind == .portable)
        #expect(delta.state.battery.batteryLevel == 64, "a number sent as text")
        #expect(delta.state.power.solar == 800, "a DELTA Pro's solar is in tenths of a watt")
        #expect(delta.state.power.acOut == 290)
        #expect(delta.state.battery.chargingState == 1)
        let ocean = devices[1]
        #expect(ocean.kind == .home)
        #expect(ocean.state.battery.batteryLevel == 81)
        #expect(ocean.state.power == EcoFlowState.Power(solar: 2400.5, home: 900, grid: -1000, battery: 500.5))
        #expect(ocean.energyTag("grid") == EnergyTag(role: .grid, device: "PowerOcean"))
    }

    /// A RIVER 3 the app's route reads (checked there, not here) costs no quota request; one it does not report, or a
    /// model checked here, is asked for as before.
    @Test func aDeviceTheAppReadsIsNotAskedFor() async throws {
        let transport = FakeTransport(answers: [
            "/iot-open/sign/device/list": #"{"code":"0","message":"Success","data":[{"sn":"R655-TEST","deviceName":"RIVER 3","online":1},{"sn":"R631-TEST","deviceName":"RIVER 3 Plus","online":1}]}"#,
            "/iot-open/sign/device/quota/all?sn=R655-TEST": #"{"code":"0","message":"Success","data":{"cmsBattSoc":64,"powInSumW":10,"powOutSumW":5}}"#,
            "/iot-open/sign/device/quota/all?sn=R631-TEST": #"{"code":"0","message":"Success","data":{"cmsBattSoc":70,"powInSumW":10,"powOutSumW":5}}"#,
        ])
        let cloud = EcoFlowCloud(accessKey: "ak", secretKey: "sk", baseURL: URL(string: "https://api.example.test")!, transport: transport)
        var river = EcoFlowDevice(id: "R655-TEST", name: "RIVER 3", online: true, model: EcoFlowModel.model(serial: "R655-TEST"))
        river.source = .app
        let devices = try await cloud.devices(besides: [river])
        #expect(devices.map(\.id) == ["R631-TEST"])
        let asked = transport.requests.withLockedValue { $0 }.compactMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.query }
        #expect(asked.allSatisfy { !$0.contains("R655-TEST") })
        #expect(try await cloud.devices().map(\.id) == ["R655-TEST", "R631-TEST"], "without the app's copy, it is read here")
    }

    @Test func anAPIRefusalIsReported() async throws {
        let transport = FakeTransport(answers: [
            "/iot-open/sign/device/list": #"{"code":"1001","message":"Invalid accessKey"}"#,
        ])
        let cloud = EcoFlowCloud(accessKey: "ak", secretKey: "sk", baseURL: URL(string: "https://api.example.test")!, transport: transport)
        await #expect(throws: EcoFlowCloud.Failure.api(code: "1001", message: "Invalid accessKey")) {
            _ = try await cloud.devices()
        }
    }

    @Test func anUnknownPathIsAnHTTPError() async throws {
        let transport = FakeTransport(answers: [:])
        let cloud = EcoFlowCloud(accessKey: "ak", secretKey: "sk", baseURL: URL(string: "https://api.example.test")!, transport: transport)
        await #expect(throws: EcoFlowCloud.Failure.http(404)) {
            _ = try await cloud.devices()
        }
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(EcoFlowPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/EcoFlow EcoFlowPlugin")
        let schema = try JSONValue(string: try #require(EcoFlowPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "EcoFlow")
    }
}
