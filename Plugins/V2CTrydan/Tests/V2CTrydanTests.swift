import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftV2CTrydan

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// The test vectors of docs/clean-room/V2CTrydan.md, 7.
enum Vectors {
    /// 7.1: idle with a car connected, firmware 1.x, no ID, LEDs, voltage or wiring.
    static let idle = #"""
    {"ChargeState":1,"ReadyState":1,"ChargePower":0.00,"ChargeEnergy":7.60,"SlaveError":0,"ChargeTime":9979,
     "HousePower":0.00,"FVPower":0.00,"BatteryPower":0.00,"Paused":0,"Locked":0,"Timer":1,"Intensity":16,"Dynamic":0,
     "MinIntensity":6,"MaxIntensity":16,"PauseDynamic":0,"FirmwareVersion":"1.6.18","DynamicPowerMode":2,
     "ContractedPower":4600}
    """#

    /// 7.2: charging, firmware 2.x, every field.
    static let charging = #"""
    {"ID":"TRY4F2A","ChargeState":2,"ReadyState":0,"ChargePower":1500.27,"VoltageInstallation":230,
     "ChargeEnergy":1.80,"ChargeMode":1,"SlaveError":4,"ChargeTime":4355,"HousePower":0.0,"FVPower":0.0,
     "BatteryPower":0.0,"Paused":0,"Locked":0,"Timer":0,"Intensity":6,"Dynamic":0,"MinIntensity":6,"MaxIntensity":16,
     "PauseDynamic":0,"LightLED":25,"LogoLED":1,"FirmwareVersion":"2.1.7","DynamicPowerMode":2,"ContractedPower":4600,
     "SSID":"home-wifi","IP":"192.0.2.50","SignalStatus":3}
    """#

    /// The rest of a body around the members a malformed reply puts first.
    static let tail = #""ChargeEnergy":1.0,"ChargeTime":1,"HousePower":0,"FVPower":0,"SlaveError":0,"Paused":0,"Locked":0,"Timer":0,"Intensity":16,"MinIntensity":6,"MaxIntensity":16,"Dynamic":0,"PauseDynamic":0,"DynamicPowerMode":0,"ContractedPower":4600"#
}

/// A charger on the network, in memory: answers `/RealTimeData`, `/read/` and `/write/` as the firmware does, and counts
/// the requests.
final class FakeCharger: HTTPSending, Sendable {
    struct State {
        var body: String
        var reads: [String: String] = [:]
        var requests: [String] = []
        var failing = false
        var writeReply = (status: 200, body: "OK")
        /// Writes change the body's members as the charger would.
        var applyWrites = true
    }

    let state: NIOLockedValueBox<State>

    init(_ body: String, reads: [String: String] = [:]) {
        state = NIOLockedValueBox(State(body: body, reads: reads))
    }

    var requests: [String] { state.withLockedValue { $0.requests } }
    var writes: [String] { requests.filter { $0.hasPrefix("/write/") } }
    func count(_ path: String) -> Int { requests.filter { $0 == path }.count }

    func set(_ body: String) { state.withLockedValue { $0.body = body } }
    func fail(_ failing: Bool) { state.withLockedValue { $0.failing = failing } }

    func send(_ request: HomeswiftNetwork.HTTPRequest) async throws -> HomeswiftNetwork.HTTPResponse {
        let path = request.url.path
        let state = self.state.withLockedValue { state -> State in
            state.requests.append(path)
            return state
        }
        if state.failing { throw HTTPClientError.timeout }
        switch path {
        case "/RealTimeData":
            return HomeswiftNetwork.HTTPResponse(status: 200, headers: [("Content-Type", "text/html")], body: Data(state.body.utf8))
        case let path where path.hasPrefix("/read/"):
            let key = String(path.dropFirst(6))
            guard let value = state.reads[key] else { return HomeswiftNetwork.HTTPResponse(status: 404) }
            return HomeswiftNetwork.HTTPResponse(status: 200, body: Data(value.utf8))
        case let path where path.hasPrefix("/write/"):
            let assignment = path.dropFirst(7).split(separator: "=")
            if state.applyWrites, state.writeReply.status == 200, assignment.count == 2 {
                let key = String(assignment[0]), value = String(assignment[1])
                self.state.withLockedValue { state in
                    state.body = state.body.replacingOccurrences(of: #""\#(key)":[0-9.]+"#, with: "\"\(key)\":\(value)", options: .regularExpression)
                }
            }
            return HomeswiftNetwork.HTTPResponse(status: state.writeReply.status, body: Data(state.writeReply.body.utf8))
        default:
            return HomeswiftNetwork.HTTPResponse(status: 404)
        }
    }
}

/// Timings a test does not wait out.
let fastTiming = TrydanTiming(
    minimumPollingInterval: .milliseconds(20), second: .milliseconds(20), backoff: Backoff(initial: .milliseconds(30), maximum: .milliseconds(60)),
    settle: .milliseconds(40), coalescing: .milliseconds(80), fallbackInterval: .seconds(3600), fallbackRetry: .seconds(60))

/// A host with one platform block whose plugin talks to `charger`.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-V2CTrydan-tests-\(UUID().uuidString)")
    let charger: FakeCharger
    let timing: TrydanTiming
    private let plugins = NIOLockedValueBox<[V2CTrydanPlugin]>([])

    init(_ charger: FakeCharger = FakeCharger(Vectors.charging), timing: TrydanTiming = fastTiming) {
        self.charger = charger
        self.timing = timing
    }

    var plugin: V2CTrydanPlugin? { plugins.withLockedValue { $0.last } }

    func registry() -> PluginRegistry {
        var registry = PluginRegistry()
        registry.register(platform: V2CTrydanPlugin.platform, name: V2CTrydanPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(V2CTrydanPlugin.Configuration.self, from: json)
            let plugin = V2CTrydanPlugin(configuration: configuration, context: context, dependencies: .init(transport: self.charger, timing: self.timing))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        return registry
    }

    func start(settings: [String: Any] = ["devices": [["host": "192.0.2.50"]]]) async throws -> PluginHost {
        let block = try HomeswiftConfiguration.Platform(platform: V2CTrydanPlugin.platform, name: V2CTrydanPlugin.name, settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry(), storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func object(_ text: String) throws -> [String: JSONValue] {
    try #require(try JSONValue(string: text).objectValue)
}

@Suite struct V2CTrydanParsingTests {
    @Test func theIdleVectorDecodes() throws {
        let report = try TrydanReport(object(Vectors.idle))
        #expect(report.id == nil)
        #expect(report.chargeState == .connected)
        #expect(report.isConnected && !report.isCharging && !report.isFault)
        #expect(report.chargeEnergy == 7.6 && report.chargeTime == 9979)
        #expect(report.intensity == 16 && report.intensityRange == 6...16)
        #expect(report.timer == 1 && report.dynamic == 0)
        #expect(DynamicPowerMode(rawValue: report.dynamicPowerMode) == .solarMin)
        #expect(report.contractedPower == 4600)
        #expect(report.voltage == nil && report.current == nil)
        #expect(TrydanIdentity.firmwareRevision(report.firmwareVersion) == "1.6.18")
    }

    @Test func theChargingVectorDecodes() throws {
        let report = try TrydanReport(object(Vectors.charging))
        #expect(report.id.flatMap(TrydanIdentity.deviceID) == "TRY4F2A")
        #expect(report.isCharging && report.chargePower == 1500.27)
        #expect(report.chargeMode == 1 && report.lightLED == 25 && report.logoLED == 1)
        #expect(SlaveError.name(report.slaveError) == "Waiting for Wi-Fi")
        #expect(!report.isFault, "a meter code is a diagnostic only")
        #expect(report.voltage == 230)
        #expect(abs((report.current ?? 0) - 6.52) < 0.01)
    }

    @Test func faultsAndUnknownValues() throws {
        let fault = try TrydanReport(object(Vectors.idle.replacingOccurrences(of: #""ChargeState":1"#, with: #""ChargeState":4"#)))
        #expect(fault.isFault && fault.isConnected && !fault.isCharging)
        let unknown = try TrydanReport(object(Vectors.idle.replacingOccurrences(of: #""ChargeState":1"#, with: #""ChargeState":3"#)))
        #expect(unknown.chargeState == nil && unknown.isConnected && !unknown.isFault)
        #expect(SlaveError.name(224) == "Undefined error")
    }

    @Test func aMissingRequiredFieldFailsTheRead() throws {
        #expect(throws: TrydanError.missingField("Locked")) {
            try TrydanReport(object(Vectors.idle.replacingOccurrences(of: #""Locked":0,"#, with: "")))
        }
    }

    @Test func extrasFillWhatTheObjectLacks() throws {
        let report = try TrydanReport(object(Vectors.idle), extras: ["VoltageInstallation": 230, "ChargeMode": 2, "LightLED": 75, "LogoLED": 25])
        #expect(report.voltageInstallation == 230 && report.chargeMode == 2 && report.lightLED == 75 && report.logoLED == 25)
    }

    @Test func aDuplicatedFirmwareVersionKeepsTheLast() throws {
        let body = #"{"ChargeState":0,"FirmwareVersion":"1.0.0","ChargePower":0.00,"FirmwareVersion":"1.6.13",\#(Vectors.tail)}"#
        let parsed = try TrydanJSON.parse(Data(body.utf8))
        #expect(parsed.repaired)
        #expect(parsed.object["FirmwareVersion"] == "1.6.13")
        #expect(try TrydanReport(parsed.object).rawChargeState == 0)
    }

    @Test func aBareFirmwareVersionIsQuoted() throws {
        let body = #"{"ChargeState":0,"ChargePower":0.00,"FirmwareVersion":1.6.13,\#(Vectors.tail)}"#
        let parsed = try TrydanJSON.parse(Data(body.utf8))
        #expect(parsed.repaired && parsed.object["FirmwareVersion"] == "1.6.13")
    }

    @Test func aMissingCommaBeforeReadyStateIsPut() throws {
        let body = #"{"ChargeState":1,"ChargePower":0.00,"Intensity":16"ReadyState":1,\#(Vectors.tail.replacingOccurrences(of: #","Intensity":16"#, with: ""))}"#
        let parsed = try TrydanJSON.parse(Data(body.utf8))
        #expect(parsed.repaired && parsed.object["ReadyState"] == 1 && parsed.object["Intensity"] == 16)
        // A body that needs nothing is not touched.
        #expect(try TrydanJSON.parse(Data(Vectors.charging.utf8)).repaired == false)
    }

    @Test func anHTMLPageIsAnInvalidResponse() {
        #expect(throws: TrydanError.self) { try TrydanJSON.parse(Data("<html><body>Hello</body></html>".utf8)) }
    }

    @Test func identities() {
        #expect(TrydanIdentity.deviceID(" try4f2a ") == "TRY4F2A")
        #expect(TrydanIdentity.deviceID("a.b c/d") == "ABCD")
        #expect(TrydanIdentity.hostDeviceID("192.0.2.50") == "HOST-192-0-2-50")
        #expect(TrydanIdentity.hostDeviceID("192.168.1.23") != TrydanIdentity.hostDeviceID("192.168.12.3"))
        #expect(TrydanIdentity.firmwareRevision(nil) == "0.0.0")
        #expect(TrydanIdentity.firmwareRevision("2.1") == "2.1.0")
        #expect(TrydanIdentity.normalizedHost("192.0.2.50:80") == "192.0.2.50")
        #expect(TrydanIdentity.normalizedHost("charger.local:8080") == "charger.local:8080")
        #expect(TrydanIdentity.normalizedHost("[fe80::1]") == "[fe80::1]")
        #expect(TrydanIdentity.normalizedHost("http://x/y") == nil)
        #expect(TrydanIdentity.normalizedHost("a b") == nil)
    }

    @Test func energyIsTaggedAsTheSettingsSay() throws {
        let report = try TrydanReport(object(Vectors.charging))
        let plain = TrydanCharger.energyReadings(report, settings: ChargerSettings(), device: "Garage")
        #expect(plain.map(\.key) == ["charge", "house", "solar", "battery"])
        #expect(plain.allSatisfy { $0.tag == nil }, "nothing is counted twice by default")
        let tagged = TrydanCharger.energyReadings(report, settings: ChargerSettings(houseEnergyRole: .grid, solarEnergy: true), device: "Garage")
        #expect(tagged[0].tag == nil, "the car's draw is part of the home's use")
        #expect(tagged[1].tag == EnergyTag(role: .grid, device: "Garage", shared: "v2c-meter"))
        #expect(tagged[2].tag == EnergyTag(role: .solar, device: "Garage", shared: "v2c-meter"))
    }

    @Test func modesByName() {
        #expect(DynamicPowerMode(name: "solar-only") == .solarOnly)
        #expect(DynamicPowerMode(name: "3") == .solarOnly)
        #expect(DynamicPowerMode(name: "eco") == nil)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct V2CTrydanPluginTests {
    let accessoryID = V2CTrydanPlugin.accessoryID(deviceID: "TRY4F2A")

    func accessory(_ host: PluginHost, _ id: String) async -> Accessory? {
        _ = await eventually { host.mainBridge.server.accessories.contains { $0.id == id } }
        return host.mainBridge.server.accessories.first { $0.id == id }
    }

    @Test func aMinimalBlockDecodesAndCostsNothing() async throws {
        let configuration = try JSONDecoder().decode(V2CTrydanPlugin.Configuration.self, from: Data(#"{"platform":"V2CTrydan"}"#.utf8))
        #expect(configuration.devices == nil && configuration.pollingInterval == nil)
        let environment = TestEnvironment()
        let host = try await environment.start(settings: [:])
        try await Task.sleep(for: .milliseconds(100))
        #expect(environment.charger.requests.isEmpty)
        #expect(host.mainBridge.server.accessories.count == 1, "the bridge alone")
        await host.stop()
    }

    @Test func aChargerBecomesAnAccessory() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        let accessory = try #require(await accessory(host, accessoryID))
        #expect(accessory.category == .outlet)
        #expect(accessory.information.characteristic(.manufacturer).value == "V2C")
        #expect(accessory.information.characteristic(.model).value == "Trydan")
        #expect(accessory.information.characteristic(.serialNumber).value == "TRY4F2A")
        #expect(accessory.information.characteristic(.firmwareRevision).value == "2.1.7")
        let outlet = try #require(accessory.service(.outlet, subtype: "charger"))
        #expect(outlet.isPrimary)
        #expect(outlet[.on]?.value == .bool(true))
        #expect(outlet[.outletInUse]?.value == .bool(true))
        #expect(outlet[EveCharacteristic.currentConsumption]?.value == .int(1500))
        #expect(outlet[EveCharacteristic.totalConsumption]?.value == .double(1.8))
        #expect(outlet[EveCharacteristic.voltage]?.value == .double(230))
        #expect(outlet[EveCharacteristic.electricCurrent]?.value == .double(6.5))
        let fan = try #require(accessory.service(.fanv2, subtype: "current"))
        #expect(fan[.active]?.value == .int(1))
        #expect(fan[.rotationSpeed]?.value == .double(6))
        #expect(fan[.rotationSpeed]?.type.maxValue == 16)
        let lock = try #require(accessory.service(.lockMechanism, subtype: "lock"))
        #expect(lock[.lockTargetState]?.isSecurityControl == true)
        #expect(lock[.lockCurrentState]?.value == .int(0))
        let plug = try #require(accessory.service(.contactSensor, subtype: "plug"))
        #expect(plug[.contactSensorState]?.value == .int(0))
        #expect(plug[.statusFault]?.value == .int(0))
        #expect(accessory.service(.switch) == nil, "the dynamic switches are opt-in")
        #expect(accessory.service(.lightbulb) == nil, "the LEDs are opt-in")
        await host.stop()
    }

    @Test func theOptInServicesComeWithTheirSettings() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: [
            "devices": [["host": "192.0.2.50", "id": "TRY4F2A"]],
            "_accessories": ["TRY4F2A": ["exposeDynamic": true, "exposeLeds": true, "exposeLock": false]],
        ])
        _ = try #require(await accessory(host, accessoryID))
        // Rebuilt once the first read reports the LEDs.
        #expect(await eventually { host.mainBridge.server.accessories.first { $0.id == accessoryID }?.service(.lightbulb, subtype: "lightLED") != nil })
        let current = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
        #expect(current.service(.lockMechanism) == nil)
        #expect(current.service(.switch, subtype: "timer") != nil)
        #expect(current.service(.switch, subtype: "dynamic") != nil)
        #expect(current.service(.switch, subtype: "pauseDynamic") != nil)
        #expect(current.service(.lightbulb, subtype: "lightLED")?[.brightness]?.value == .int(25))
        #expect(current.service(.lightbulb, subtype: "logoLED")?[.on]?.value == .bool(true))
        await host.stop()
    }

    @Test func pollingAsksOnceACycleAndFallsBackOnce() async throws {
        let charger = FakeCharger(Vectors.idle, reads: ["VoltageInstallation": "230", "ChargeMode": "2"])
        let environment = TestEnvironment(charger)
        let host = try await environment.start()
        let id = V2CTrydanPlugin.accessoryID(deviceID: TrydanIdentity.hostDeviceID("192.0.2.50"))
        let accessory = try #require(await accessory(host, id))
        #expect(await eventually { charger.count("/RealTimeData") >= 6 })
        // Each optional keyword asked once: two answered, two not on this firmware (404) and never asked again.
        for key in TrydanReport.fallbackKeys { #expect(charger.count("/read/\(key)") == 1, "\(key)") }
        #expect(charger.requests.filter { $0.hasPrefix("/read/") }.count == 4)
        #expect(accessory.service(.outlet)?[EveCharacteristic.voltage]?.value == .double(230))
        #expect(accessory.service(.outlet)?[.outletInUse]?.value == .bool(false))
        await host.stop()
    }

    @Test func aChangeOnTheChargerReachesHomeKitOnce() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        let accessory = try #require(await accessory(host, accessoryID))
        let inUse = try #require(accessory.service(.outlet)?[.outletInUse])
        let changes = NIOLockedValueBox(0)
        inUse.observe { change in if change.oldValue != change.newValue { changes.withLockedValue { $0 += 1 } } }
        environment.charger.set(Vectors.charging.replacingOccurrences(of: #""ChargeState":2"#, with: #""ChargeState":1"#))
        #expect(await eventually { inUse.value == .bool(false) })
        let before = environment.charger.count("/RealTimeData")
        #expect(await eventually { environment.charger.count("/RealTimeData") >= before + 3 })
        #expect(changes.withLockedValue { $0 } == 1)
        await host.stop()
    }

    @Test func writesReachTheChargerAndReadItAgain() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        let accessory = try #require(await accessory(host, accessoryID))
        let on = try #require(accessory.service(.outlet)?[.on])
        let reads = environment.charger.count("/RealTimeData")
        let pause = try #require(on.writeHandler(for: .bool(false)))
        try await pause(.bool(false))
        #expect(environment.charger.writes == ["/write/Paused=1"])
        #expect(on.value == .bool(false), "shown at once")
        #expect(accessory.service(.fanv2)?[.active]?.value == .int(0))
        #expect(await eventually { environment.charger.count("/RealTimeData") >= reads + 2 })

        let lock = try #require(accessory.service(.lockMechanism)?[.lockTargetState])
        let secure = try #require(lock.writeHandler(for: .int(1)))
        try await secure(.int(1))
        #expect(environment.charger.writes.last == "/write/Locked=1")
        #expect(accessory.service(.lockMechanism)?[.lockCurrentState]?.value == .int(1))
        await host.stop()
    }

    @Test func sliderWritesAreCoalescedAndClamped() async throws {
        // Calls far enough apart to arrive in order on a loaded runner, within one window.
        var timing = fastTiming
        timing.coalescing = .milliseconds(600)
        let environment = TestEnvironment(timing: timing)
        let host = try await environment.start()
        let accessory = try #require(await accessory(host, accessoryID))
        let speed = try #require(accessory.service(.fanv2)?[.rotationSpeed])
        let handler = try #require(speed.writeHandler(for: .double(7)))
        await withTaskGroup(of: Void.self) { group in
            for (index, amperes) in [7.0, 8, 9, 10, 40].enumerated() {
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(40 * index))
                    try? await handler(.double(amperes))
                }
            }
        }
        #expect(environment.charger.writes == ["/write/Intensity=16"], "the last value, clamped to MaxIntensity")
        try await handler(.double(0))
        #expect(environment.charger.writes.last == "/write/Paused=1", "the bottom of the slider pauses")
        await host.stop()
    }

    @Test func aDragToTheBottomOnlyPauses() async throws {
        var timing = fastTiming
        timing.coalescing = .milliseconds(400)
        let environment = TestEnvironment(timing: timing)
        let host = try await environment.start()
        let accessory = try #require(await accessory(host, accessoryID))
        let speed = try #require(accessory.service(.fanv2)?[.rotationSpeed])
        let handler = try #require(speed.writeHandler(for: .double(10)))
        async let dragged: Void = { try? await handler(.double(10)) }()
        try await Task.sleep(for: .milliseconds(50))
        try await handler(.double(0))
        await dragged
        #expect(environment.charger.writes == ["/write/Paused=1"], "the 10 still waiting is dropped")
        await host.stop()
    }

    @Test func anOnWithABrightnessWritesTheBrightnessOnly() async throws {
        // A window a loaded runner starts both halves of the request in: the On is told apart from the brightness by time.
        var timing = fastTiming
        timing.coalescing = .milliseconds(600)
        let environment = TestEnvironment(timing: timing)
        let host = try await environment.start(settings: [
            "devices": [["host": "192.0.2.50", "id": "TRY4F2A"]], "_accessories": ["TRY4F2A": ["exposeLeds": true]],
        ])
        #expect(await eventually { host.mainBridge.server.accessories.first { $0.id == accessoryID }?.service(.lightbulb, subtype: "lightLED") != nil })
        let light = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID }?.service(.lightbulb, subtype: "lightLED"))
        let on = try #require(light[.on]?.writeHandler(for: .bool(true)))
        let brightness = try #require(light[.brightness]?.writeHandler(for: .int(40)))
        // One request of the Home app: both at once, in either order.
        async let turnedOn: Void = { try? await on(.bool(true)) }()
        try await brightness(.int(40))
        await turnedOn
        #expect(environment.charger.writes == ["/write/LightLED=40"])
        await host.stop()
    }

    @Test func anExcludedChargerIsNoLongerPolled() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: [
            "devices": [["host": "192.0.2.50"]], "_accessories": ["TRY4F2A": ["excluded": true]],
        ])
        #expect(await eventually { environment.charger.count("/RealTimeData") >= 1 })
        #expect(await eventually { await environment.plugin?.chargers.isEmpty == true })
        let reads = environment.charger.count("/RealTimeData")
        // As long as several polling intervals.
        try await Task.sleep(for: .milliseconds(200))
        #expect(environment.charger.count("/RealTimeData") <= reads + 1)
        #expect(host.mainBridge.server.accessories.first { $0.id == accessoryID } == nil)
        await host.stop()
    }

    @Test func refusedAndInvalidWrites() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        _ = try #require(await accessory(host, accessoryID))
        let charger = try #require(await environment.plugin?.charger(deviceID: "TRY4F2A"))
        await #expect(throws: HAPStatusError.self) { try await charger.set("Intensity", 5) }
        await #expect(throws: HAPStatusError.self) { try await charger.set("Intensity", 33) }
        #expect(environment.charger.writes.isEmpty, "refused locally")
        environment.charger.state.withLockedValue { $0.writeReply = (200, "ERROR") }
        do {
            try await charger.set("Timer", 1)
            Issue.record("a refused write succeeded")
        } catch let error as HAPStatusError {
            #expect(error.status == .serviceCommunicationFailure)
        }
        #expect(await charger.report?.timer == 0, "the value stays as last read")
        await host.stop()
    }

    @Test func threeFailedPollsAreNoResponseAndOneSuccessEndsIt() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        let accessory = try #require(await accessory(host, accessoryID))
        #expect(await eventually { accessory.service(.outlet)?[.outletInUse]?.value == .bool(true) })
        environment.charger.fail(true)
        #expect(await eventually { accessory.isUnavailable })
        environment.charger.fail(false)
        #expect(await eventually { !accessory.isUnavailable })
        await host.stop()
    }

    @Test func aRaisedMaximumChangesThePropsNotTheIids() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        let accessory = try #require(await accessory(host, accessoryID))
        let iid = try #require(accessory.service(.fanv2)?[.rotationSpeed]?.iid)
        environment.charger.set(Vectors.charging.replacingOccurrences(of: #""MaxIntensity":16"#, with: #""MaxIntensity":32"#))
        #expect(await eventually {
            host.mainBridge.server.accessories.first { $0.id == accessoryID }?.service(.fanv2)?[.rotationSpeed]?.type.maxValue == 32
        })
        let rebuilt = try #require(host.mainBridge.server.accessories.first { $0.id == accessoryID })
        #expect(rebuilt.service(.fanv2)?[.rotationSpeed]?.iid == iid)
        await host.stop()
    }

    @Test func aChargerWithoutIDIsKeyedByItsAddressAndNotReKeyed() async throws {
        let charger = FakeCharger(Vectors.idle)
        let environment = TestEnvironment(charger)
        let host = try await environment.start()
        let id = V2CTrydanPlugin.accessoryID(deviceID: "HOST-192-0-2-50")
        _ = try #require(await accessory(host, id))
        charger.set(Vectors.idle.replacingOccurrences(of: "{", with: #"{"ID":"NEW1","#))
        let before = charger.count("/RealTimeData")
        #expect(await eventually { charger.count("/RealTimeData") >= before + 2 })
        #expect(host.mainBridge.server.accessories.contains { $0.id == id })
        #expect(!host.mainBridge.server.accessories.contains { $0.id == "V2CTrydan:NEW1" })
        let learned = await environment.plugin?.learnedIDs
        #expect(learned?["192.0.2.50"] == "HOST-192-0-2-50")
        await host.stop()
    }

    @Test func setupAddsAChargerByAddress() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("no prompt"); return }
        #expect(prompt.fields.map(\.key) == ["host"])
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["host": "192.0.2.50"])) else {
            Issue.record("not done"); return
        }
        #expect(outcome.credentials == nil, "nothing to keep")
        #expect(outcome.settings["devices"] == [["host": "192.0.2.50", "id": "TRY4F2A"]])
        let canonical = V2CTrydanPlugin.canonical(["platform": "V2CTrydan", "devices": outcome.settings["devices"]!])
        #expect(canonical["_accessories"]?["TRY4F2A"]?["host"] == "192.0.2.50")
        #expect(canonical["devices"] == nil)

        environment.charger.set("<html>nope</html>")
        await #expect(throws: SetupError("No V2C Trydan answered at 192.0.2.60")) {
            try await plugin.authorize(SetupRequest(target: .account, answers: ["host": "192.0.2.60"]))
        }
        await host.stop()
    }

    @Test func discoverListsTheConfiguredChargers() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: ["_accessories": ["TRY4F2A": ["host": "192.0.2.50", "name": "Garage"]]])
        _ = try #require(await accessory(host, accessoryID))
        _ = await eventually { await environment.plugin?.chargers.isEmpty == false }
        let found = try await #require(environment.plugin).discover()
        #expect(found.map(\.deviceID) == ["TRY4F2A"])
        #expect(found.first?.address == "192.0.2.50" && found.first?.kind == "charger" && found.first?.isSetUp == true)
        await host.stop()
    }

    @Test func canonicalSettingsMovesTheDevicesList() throws {
        let block: JSONValue = [
            "platform": "V2CTrydan",
            "devices": [["host": "192.0.2.50", "name": "Garage"], ["host": "192.0.2.51", "id": "abc"], ["host": "192.0.2.52"]],
            "_accessories": ["ABC": ["host": "192.0.2.99", "exposeLock": false]],
        ]
        let canonical = V2CTrydanPlugin.canonical(block, learned: ["192.0.2.50": "TRY4F2A"])
        #expect(canonical["_accessories"]?["TRY4F2A"] == ["host": "192.0.2.50", "name": "Garage"])
        #expect(canonical["_accessories"]?["ABC"] == ["host": "192.0.2.51", "exposeLock": false], "the list's address is the newer one")
        #expect(canonical["devices"] == [["host": "192.0.2.52"]])
        #expect(V2CTrydanPlugin.canonical(canonical) == canonical, "written again, it changes nothing")
    }

    @Test func theModeActionWritesTheMode() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        _ = try #require(await accessory(host, accessoryID))
        let plugin = try #require(environment.plugin)
        let response = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "mode", query: [:], body: ["deviceID": "TRY4F2A", "mode": "solar-only"], user: "test"))
        #expect(response.status == 200)
        #expect(environment.charger.writes == ["/write/DynamicPowerMode=3"])
        let probe = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "probe", query: ["host": "192.0.2.50"], body: .null, user: "test"))
        #expect(probe.json["charger"]?["deviceID"] == "TRY4F2A")
        await host.stop()
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(V2CTrydanPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/V2CTrydan V2CTrydanPlugin")
        let schema = try JSONValue(string: try #require(V2CTrydanPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "V2CTrydan")
    }
}
