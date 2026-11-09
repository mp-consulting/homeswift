import Foundation
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftShelly

@Suite(.timeLimit(.minutes(1)))
struct RPCTests {
    /// 11.4: HA1, HA2 and the response for the original's numeric cnonce and aioshelly's base64 one.
    @Test func digestMatchesTheVectors() throws {
        let challenge = #"{"auth_type":"digest","nonce":1700000000,"nc":1,"realm":"shellyplus1pm-aabbccddeeff","algorithm":"SHA-256"}"#
        let digest = try #require(try RPCDigest(challenge: challenge))
        #expect(RPCDigest.sha256("admin:shellyplus1pm-aabbccddeeff:secret") == "abf4a881bbc6e16f0c68bbf0fcabc24109b577fe615ca02a4f78be7bbdafa619")
        #expect(RPCDigest.ha2 == "6370ec69915103833b5222b368555393393f098bfbfbb59f47e0590af135f062")
        #expect(digest.response(password: "secret", cnonce: "313773") == "a9fdaa21db8597c0311326b58dd16eb0d24e799ca76bf9230b4887c62359c45d")
        #expect(digest.response(password: "secret", cnonce: "AAECAwQFBgcICQoLDA0ODw==") == "ed9b9f40cd94a6814033c7c87f0b4900fdebfe240b8221aa5ccb3f3fb3162f25")
        let auth = digest.auth(password: "secret", cnonce: .number(313773))
        #expect(auth["nonce"] == .number(1_700_000_000))
        #expect(auth["username"] == "admin")
        #expect(auth["response"]?.stringValue == "a9fdaa21db8597c0311326b58dd16eb0d24e799ca76bf9230b4887c62359c45d")
        #expect(throws: RPCError.unsupportedAuthentication("MD5")) { try RPCDigest(challenge: #"{"nonce":1,"realm":"r","algorithm":"MD5"}"#) }
    }

    @Test func reconnectScheduleReadsEveryShape() {
        #expect(RPCSettings.reconnectSchedule("5,10") == [5, 10])
        #expect(RPCSettings.reconnectSchedule([5, 10]) == [5, 10])
        #expect(RPCSettings.reconnectSchedule(5) == [5])
        #expect(RPCSettings.reconnectSchedule(0) == [0])
        var settings = RPCSettings()
        #expect((0..<8).map { settings.reconnectDelay(attempt: $0) } == [5, 10, 30, 60, 300, 600, 600, 600])
        settings.reconnectInterval = [0]
        #expect(settings.reconnectDelay(attempt: 0) == nil)
        settings.reconnectInterval = [5, 0]
        #expect(settings.reconnectDelay(attempt: 1) == nil)
        #expect(ShellyRPC.describe(seconds: 5) == "5 seconds")
        #expect(ShellyRPC.describe(seconds: 60) == "1 minute")
        #expect(ShellyRPC.describe(seconds: 7200) == "2 hours")
    }

    @Test func accessoryIDsNameTheirDevice() {
        #expect(ShellyNGPlugin.deviceID(ofAccessory: "shellypro4pm-aabbccddeeff-switch-3") == "shellypro4pm-aabbccddeeff")
        #expect(ShellyNGPlugin.deviceID(ofAccessory: "shellyplusi4-aabbccddeeff-buttons") == "shellyplusi4-aabbccddeeff")
        #expect(ShellyPlugin.deviceID(ofAccessory: "Shelly 2.5 A4CF12 #1") == "A4CF12")
        #expect(ShellyPlugin.deviceID(ofAccessory: "Shelly 1PM A4CF12F45678") == "A4CF12F45678")
    }

    @Test func layoutsFollowTheHomebridgePlugin() {
        func items(_ keys: [String], profile: String? = nil, inputs: [Int: String] = [:]) -> [String] {
            Gen2Layout(components: Set(keys.compactMap(ComponentKey.init)), profile: profile, inputTypes: inputs).items.map(\.accessoryID)
        }
        #expect(items(["switch:0", "input:0"]) == ["switch"])
        #expect(items(["switch:0", "switch:1", "switch:2", "switch:3"]) == ["switch-0", "switch-1", "switch-2", "switch-3"])
        #expect(items(["switch:0", "switch:1", "cover:0"], profile: "switch") == ["switch-0", "switch-1"])
        #expect(items(["cover:0", "input:0", "input:1"], profile: "cover") == ["cover"])
        #expect(items(["input:0", "input:1", "input:2", "input:3"], inputs: [0: "button", 1: "switch", 2: "button", 3: "switch"]) == ["buttons", "switch1", "switch3"])
        #expect(items(["em:0", "emdata:0"]) == ["em-0"])
        #expect(items(["rgbw:0"]) == ["rgbw"])
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ShellyNGTests {
    let environment = ShellyEnvironment()
    let switchID = "ShellyNG:shellyplus1pm-aabbccddeeff-switch"

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(ShellyNGPlugin.Configuration.self, from: Data(#"{"platform":"ShellyNG","name":"Shelly NG"}"#.utf8))
        #expect(configuration.devices == nil)
        let full = try JSONDecoder().decode(ShellyNGPlugin.Configuration.self, from: Data(#"""
            {"platform":"ShellyNG","devices":[{"id":"shellyplus1-abc","switch:0":{"type":"outlet"}}],"mdns":{"enable":false},
             "websocket":{"requestTimeout":5,"pingInterval":0,"reconnectInterval":"5,10"}}
            """#.utf8))
        #expect(full.devices?.count == 1)
    }

    /// 11.1 to 11.3: the Plus 1PM's accessory, its values, a notification merged into them, and a write.
    @Test func aPlus1PMBecomesASwitchWithAPowerMeter() async throws {
        let device = plus1PM()
        environment.add(device)
        let host = try await environment.start(settings: ["devices": [["id": "shellyplus1pm-aabbccddeeff", "hostname": "10.0.0.9"]]])
        defer { Task { await host.stop() } }
        await expectEventually { host.accessory(switchID) != nil }
        let accessory = try #require(host.accessory(switchID))
        #expect(accessory.information.characteristic(.name).value == "Kitchen")
        #expect(accessory.information.characteristic(.manufacturer).value == "Allterco")
        #expect(accessory.information.characteristic(.model).value == "Shelly Plus 1 PM")
        #expect(accessory.information.characteristic(.serialNumber).value == "AABBCCDDEEFF")
        #expect(accessory.information.characteristic(.firmwareRevision).value == "1.1.0")
        let switchService = try #require(accessory.services.first { $0.type == .switch })
        #expect(switchService.subtype == "switch-0")
        #expect(switchService.characteristic(.on).value == .bool(false))
        let meter = try #require(accessory.services.first { $0.type == PowerMeter.service })
        #expect(meter.characteristic(PowerMeter.consumption).value.doubleValue == 0)
        #expect(meter.characteristic(PowerMeter.voltage).value.doubleValue == 232.8)
        #expect(abs((meter.characteristic(PowerMeter.totalConsumption).value.doubleValue ?? 0) - 0.110046) <= 0.051)

        device.notify("NotifyStatus", #"{"ts":1707327000.12,"switch:0":{"id":0,"output":true,"source":"button","apower":41.7,"aenergy":{"total":110.051}}}"#)
        await expectEventually { switchService.characteristic(.on).value == .bool(true) }
        await expectEventually { meter.characteristic(PowerMeter.consumption).value.doubleValue == 41.7 }
        #expect(meter.characteristic(PowerMeter.voltage).value.doubleValue == 232.8)
        let found = await environment.ng?.devices["shellyplus1pm-aabbccddeeff"]?.status["switch:0"]
        let status = try #require(found)
        #expect(status["aenergy"]?["minute_ts"] == .number(1_707_326_934))

        // Equal to the device's value: no request.
        try await switchService.characteristic(.on).write(.bool(true))
        #expect(device.calls("Switch.Set").isEmpty)
        try await switchService.characteristic(.on).write(.bool(false))
        let set = try #require(device.calls("Switch.Set").last)
        #expect(set["params"] == ["id": 0, "on": false])
        #expect(set["jsonrpc"] == "2.0")
    }

    @Test func anOutletFromTheDeviceOptions() async throws {
        environment.add(plus1PM())
        let host = try await environment.start(settings: ["devices": [["id": "shellyplus1pm-aabbccddeeff", "hostname": "10.0.0.9", "switch:0": ["type": "Outlet"]]]])
        defer { Task { await host.stop() } }
        await expectEventually { host.accessory(switchID) != nil }
        let outlet = try #require(host.accessory(switchID)?.services.first { $0.type == .outlet })
        #expect(outlet.subtype == "outlet-0")
        #expect(outlet.characteristic(.name).value == "Outlet 1")
        #expect(outlet.characteristic(.outletInUse).value == .bool(false))
    }

    /// 11.4: the first request is challenged, answered with the password, and the next ones carry a growing `nc`.
    @Test func aPasswordAnswersTheDigestChallenge() async throws {
        let device = plus1PM(password: "secret")
        environment.add(device)
        let host = try await environment.start(settings: ["devices": [["id": "shellyplus1pm-aabbccddeeff", "hostname": "10.0.0.9", "password": "secret"]]])
        defer { Task { await host.stop() } }
        await expectEventually { host.accessory(switchID) != nil }
        let statuses = device.calls("Shelly.GetStatus")
        #expect(statuses.count == 2)
        #expect(statuses[0]["auth"] == nil)
        #expect(statuses[1]["auth"]?["username"] == "admin")
        let config = try #require(device.calls("Shelly.GetConfig").first)
        #expect(config["auth"]?["nc"] == .number(2))
    }

    @Test func aWrongPasswordLeavesTheDeviceOut() async throws {
        environment.add(plus1PM(password: "secret"))
        let host = try await environment.start(settings: ["devices": [["id": "shellyplus1pm-aabbccddeeff", "hostname": "10.0.0.9", "password": "wrong"]]])
        defer { Task { await host.stop() } }
        await expectEventually { await environment.ng?.failures["shellyplus1pm-aabbccddeeff"] == "Invalid password" }
        #expect(host.accessory(switchID) == nil)
    }

    @Test func mDNSFindsADeviceAndFollowsItsAddress() async throws {
        let device = plus1PM()
        environment.add(device, host: "10.0.0.9")
        environment.add(device, host: "10.0.0.10")
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        environment.announce("shellyplus1pm-aabbccddeeff", host: "10.0.0.9")
        await expectEventually { host.accessory(switchID) != nil }
        environment.announce("shellyplus1pm-aabbccddeeff", host: "10.0.0.10")
        await expectEventually { await environment.ng?.devices["shellyplus1pm-aabbccddeeff"]?.host == "10.0.0.10" }
        await expectEventually { device.socket?.url?.host == "10.0.0.10" }
        // Values missed while away are read again.
        await expectEventually { device.calls("Shelly.GetStatus").count >= 2 }
    }

    @Test func aDroppedConnectionReconnectsAndAnIntentionalCloseDoesNot() async throws {
        let device = plus1PM()
        environment.add(device)
        let host = try await environment.start(settings: ["devices": [["id": "shellyplus1pm-aabbccddeeff", "hostname": "10.0.0.9"]]])
        defer { Task { await host.stop() } }
        await expectEventually { host.accessory(switchID) != nil }
        let before = device.connections, statuses = device.calls("Shelly.GetStatus").count
        device.socket?.drop()
        await expectEventually { device.connections == before + 1 }
        await expectEventually { device.calls("Shelly.GetStatus").count == statuses + 1 }
        let reconnected = device.connections
        device.socket?.finish(code: 1000)
        try await Task.sleep(for: .milliseconds(100))
        #expect(device.connections == reconnected)
    }

    @Test func anExcludedDeviceIsNotReached() async throws {
        let device = plus1PM()
        environment.add(device)
        let host = try await environment.start(settings: ["devices": [["id": "shellyplus1pm-aabbccddeeff", "hostname": "10.0.0.9", "exclude": true]]])
        defer { Task { await host.stop() } }
        environment.announce("shellyplus1pm-aabbccddeeff", host: "10.0.0.9")
        try await Task.sleep(for: .milliseconds(100))
        #expect(device.connections == 0)
        #expect(host.accessory(switchID) == nil)
    }

    @Test func aPlus2PMInCoverProfileIsAWindow() async throws {
        let device = FakeShellyNG(
            info: #"{"id":"shellyplus2pm-aabbccddeeff","mac":"AABBCCDDEEFF","model":"SNSW-102P16EU","gen":2,"ver":"1.0.0","app":"Plus2PM","profile":"cover"}"#,
            status: #"{"cover:0":{"id":0,"source":"WS_in","state":"closing","apower":123.1,"voltage":219.7,"current":0.557,"pf":0.99,"aenergy":{"total":314.801},"pos_control":true,"current_pos":51},"input:0":{"id":0,"state":false}}"#)
        environment.add(device)
        let host = try await environment.start(settings: ["devices": [["id": "shellyplus2pm-aabbccddeeff", "hostname": "10.0.0.9"]]])
        defer { Task { await host.stop() } }
        let id = "ShellyNG:shellyplus2pm-aabbccddeeff-cover"
        await expectEventually { host.accessory(id) != nil }
        let accessory = try #require(host.accessory(id))
        #expect(accessory.information.characteristic(.name).value == "Shelly Plus 2 PM Cover")
        let window = try #require(accessory.services.first { $0.type == .window })
        #expect(window.subtype == "window-0")
        #expect(window.characteristic(.currentPosition).value == .int(51))
        #expect(window.characteristic(.positionState).value == .int(0))
        #expect(window.characteristic(.targetPosition).value == .int(51))
        try await window.characteristic(.targetPosition).write(.int(80))
        await expectEventually { device.calls("Cover.GoToPosition").last?["params"] == ["id": 0, "pos": 80] }
        device.notify("NotifyStatus", #"{"cover:0":{"state":"stopped","current_pos":80}}"#)
        await expectEventually { window.characteristic(.positionState).value == .int(2) }
    }

    /// 11.3: the I4's buttons and its input configured as a switch.
    @Test func anI4ReportsButtonPresses() async throws {
        let device = FakeShellyNG(
            info: #"{"id":"shellyplusi4-aabbccddeeff","mac":"AABBCCDDEEFF","model":"SNSN-0024X","gen":2,"ver":"1.0.0","app":"PlusI4"}"#,
            status: #"{"input:0":{"id":0,"state":null},"input:1":{"id":1,"state":true},"input:2":{"id":2,"state":null},"input:3":{"id":3,"state":null}}"#,
            config: #"{"input:0":{"type":"button"},"input:1":{"type":"switch"},"input:2":{"type":"button"},"input:3":{"type":"button"}}"#)
        environment.add(device)
        let host = try await environment.start(settings: ["devices": [["id": "shellyplusi4-aabbccddeeff", "hostname": "10.0.0.9"]]])
        defer { Task { await host.stop() } }
        let buttonsID = "ShellyNG:shellyplusi4-aabbccddeeff-buttons"
        // The device's accessories are added one after the other: wait for the last one, not the first.
        await expectEventually { host.accessory(buttonsID) != nil && host.accessory("ShellyNG:shellyplusi4-aabbccddeeff-switch1") != nil }
        let readOnly = try #require(host.accessory("ShellyNG:shellyplusi4-aabbccddeeff-switch1")?.services.first { $0.type == .switch })
        #expect(readOnly.subtype == "readonly-switch-1")
        #expect(readOnly.characteristic(.on).value == .bool(true))
        #expect(!readOnly.characteristic(.on).type.permissions.contains(.pairedWrite))
        let button = try #require(host.accessory(buttonsID)?.services.first { $0.subtype == "stateless-programmable-switch-2" })
        #expect(button.characteristic(.serviceLabelIndex).value == .int(3))
        let presses = PressLog()
        _ = button.characteristic(.programmableSwitchEvent).observe { presses.add($0.newValue) }
        device.notify("NotifyEvent", #"{"ts":1707327010.50,"events":[{"component":"input:2","id":2,"event":"double_push","ts":1707327010.50}]}"#)
        await expectEventually { presses.values == [.int(1)] }
    }

    @Test func anRGBWLightSetsItsColour() async throws {
        let device = FakeShellyNG(
            info: #"{"id":"shellyplusrgbwpm-aabbccddeeff","mac":"AABBCCDDEEFF","model":"SNDC-0D4P10WW","gen":2,"ver":"1.4.0","app":"PlusRGBWPM"}"#,
            status: #"{"rgbw:0":{"id":0,"output":true,"brightness":50,"rgb":[255,0,0],"white":0}}"#)
        environment.add(device)
        let host = try await environment.start(settings: ["devices": [["id": "shellyplusrgbwpm-aabbccddeeff", "hostname": "10.0.0.9"]]])
        defer { Task { await host.stop() } }
        let id = "ShellyNG:shellyplusrgbwpm-aabbccddeeff-rgbw"
        await expectEventually { host.accessory(id) != nil }
        let light = try #require(host.accessory(id)?.services.first { $0.type == .lightbulb })
        #expect(light.characteristic(.hue).value.doubleValue == 0)
        #expect(light.characteristic(.saturation).value.doubleValue == 100)
        async let hue: Void = light.characteristic(.hue).write(.double(120))
        async let brightness: Void = light.characteristic(.brightness).write(.int(80))
        _ = try await (hue, brightness)
        await expectEventually { device.calls("RGBW.Set").count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(device.calls("RGBW.Set").count == 1)
        #expect(device.calls("RGBW.Set").first?["params"] == ["id": 0, "on": true, "brightness": 80, "rgb": [0, 255, 0], "white": 0])
    }

    @Test func aCCTLightHasAdaptiveLighting() async throws {
        let device = FakeShellyNG(
            info: #"{"id":"shellyprorgbwwpm-aabbccddeeff","mac":"AABBCCDDEEFF","model":"SPDC-0D5PE16EU","gen":2,"ver":"1.4.0","app":"ProRGBWWPM"}"#,
            status: #"{"cct:0":{"id":0,"output":true,"brightness":50,"ct":4000}}"#, config: #"{"cct:0":{"ct_range":[2700,6500]}}"#)
        environment.add(device)
        let host = try await environment.start(settings: ["devices": [["id": "shellyprorgbwwpm-aabbccddeeff", "hostname": "10.0.0.9"]]])
        defer { Task { await host.stop() } }
        let id = "ShellyNG:shellyprorgbwwpm-aabbccddeeff-cct"
        await expectEventually { host.accessory(id) != nil }
        let light = try #require(host.accessory(id)?.services.first { $0.type == .lightbulb })
        #expect(light.characteristic(.colorTemperature).value.intValue == 250)
        let controller = try #require(light.adaptiveLighting)
        try controller.activateForTesting()
        device.notify("NotifyStatus", #"{"cct:0":{"ct":6500}}"#)
        await expectEventually { !controller.isAdaptiveLightingActive }
    }

    /// A device named nowhere but in the Shelly app takes the names the app keeps in Shelly Cloud, by channel; one named on
    /// the device keeps that name.
    @Test func anUnnamedDeviceTakesItsNameFromShellyCloud() async throws {
        environment.add(FakeShellyNG(
            info: #"{"id":"shellypro3em-aabbccddeeff","mac":"AABBCCDDEEFF","model":"SPEM-003CEBEU","gen":2,"ver":"1.4.0","app":"Pro3EM","name":null}"#,
            status: #"{"em:0":{"id":0,"total_act_power":735.5}}"#, config: #"{"sys":{"device":{"name":null}}}"#))
        let host = try await environment.start(settings: ["devices": [["id": "shellypro3em-aabbccddeeff", "hostname": "10.0.0.9"]]])
        defer { Task { await host.stop() } }
        await expectEventually { host.accessory("ShellyNG:shellypro3em-aabbccddeeff-em-0") != nil }
        let meter = try #require(await environment.ng?.devices["shellypro3em-aabbccddeeff"])
        let unnamed = await meter.makeAccessories(platform: ShellyNGPlugin.platform).map(\.name)
        #expect(unnamed.count == 1 && unnamed[0].hasSuffix(" Meter 1"))
        await meter.setCloudNames(["aabbccddeeff": "Smart Meter", "aabbccddeeff_1": "Garage"])
        #expect(await meter.makeAccessories(platform: ShellyNGPlugin.platform).map(\.name) == ["Smart Meter"])
    }

    @Test func aDeviceNamedOnItselfKeepsItsName() async throws {
        environment.add(plus1PM())
        let host = try await environment.start(settings: ["devices": [["id": "shellyplus1pm-aabbccddeeff", "hostname": "10.0.0.9"]]])
        defer { Task { await host.stop() } }
        await expectEventually { host.accessory(switchID) != nil }
        let device = try #require(await environment.ng?.devices["shellyplus1pm-aabbccddeeff"])
        await device.setCloudNames(["aabbccddeeff": "Smart Plug"])
        #expect(await device.makeAccessories(platform: ShellyNGPlugin.platform).map(\.name) == ["Kitchen"])
    }

    /// A first import from Shelly Cloud that a restart stopped goes on from where it reached, after the days since, and
    /// forgets where it stopped once it ends. Its former file (`shelly-cloud-history.json`) is taken by the runtime's import.
    @Test func aStoppedCloudImportGoesOnFromWhereItReached() async throws {
        environment.add(plus1PM())
        let host = try await environment.start(settings: ["devices": [["id": "shellyplus1pm-aabbccddeeff", "hostname": "10.0.0.9"]]])
        defer { Task { await host.stop() } }
        await expectEventually { host.accessory(switchID) != nil }
        let device = try #require(await environment.ng?.devices["shellyplus1pm-aabbccddeeff"])
        let context = try #require(host.context(platform: ShellyNGPlugin.platform, name: "Shelly"))
        let file = context.jsonFile("shelly-cloud-history.json", as: [String: Int].self)
        let now = Date(), day = 86_400.0
        let key = "shellyplus1pm-aabbccddeeff/switch:0"
        try file.save([key: Int(now.timeIntervalSince1970 - 2 * day), "\(key)#resume": Int(now.timeIntervalSince1970 - 100 * day)])

        let http = environment.http
        http.answer("/v2/users/auth/login", #"{"accessToken":"\#(cloudToken())"}"#)
        http.answer("/v2/statistics/power-consumption", #"{"history":[]}"#)
        let cloud = ShellyCloud(credentials: ShellyCloudCredentials(email: "me@example.com", password: "pw"), http: http, logger: Logger(label: "test"))
        await device.importCloudHistory(cloud, id: "aabbccddeeff", delay: .zero, now: now)

        let format = ShellyCloud.formatter(.current)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let asked = http.requests.filter { $0.url.path == "/v2/statistics/power-consumption" }.compactMap { request in
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "date_to" }?.value.flatMap { format.date(from: $0.replacingOccurrences(of: "+", with: " ")) }
        }
        // The days since the last import first, then on from a day before where the first import stopped.
        #expect(asked.first.map { calendar.isDate($0, inSameDayAs: now) } == true)
        let resumed = now.addingTimeInterval(-101 * day)
        #expect(asked.contains { calendar.isDate($0, inSameDayAs: resumed) })
        #expect(!asked.contains { $0 > now.addingTimeInterval(-90 * day) && $0 < now.addingTimeInterval(-5 * day) })
        // The runtime's import keeps it now, as notes by meter; the former file's entries were taken.
        let notes = await device.cloudHistory().state.notes
        #expect(notes["switch:0#resume"] == nil && notes["switch:0"] != nil)
        #expect(file.load() == nil)
    }

    @Test func aWholeHomeMeterCountsAsTheGrid() async throws {
        let device = FakeShellyNG(
            info: #"{"id":"shellypro3em-aabbccddeeff","mac":"AABBCCDDEEFF","model":"SPEM-003CEBEU","gen":2,"ver":"1.4.0","app":"Pro3EM"}"#,
            status: #"{"em:0":{"id":0,"a_voltage":230.1,"total_current":3.2,"total_act_power":735.5},"emdata:0":{"id":0,"total_act":123456.0}}"#)
        environment.add(device)
        let host = try await environment.start(settings: ["devices": [["id": "shellypro3em-aabbccddeeff", "hostname": "10.0.0.9"]]])
        defer { Task { await host.stop() } }
        let id = "ShellyNG:shellypro3em-aabbccddeeff-em-0"
        await expectEventually { host.accessory(id) != nil }
        let meter = try #require(host.accessory(id)?.services.first { $0.type == PowerMeter.service })
        #expect(meter.characteristic(PowerMeter.consumption).value.doubleValue == 735.5)
        #expect(abs((meter.characteristic(PowerMeter.totalConsumption).value.doubleValue ?? 0) - 123.456) <= 0.051)

        // Its Meter is the plugin's, suggested as the grid: exporting, the grid's power goes below zero, which the
        // characteristic (a consumption, zero or above) cannot show.
        let metrics = Metrics(directory: nil, interval: .seconds(60))
        metrics.start(following: host)
        defer { metrics.stop() }
        let meterID = MeterID(accessory: id, meter: "\(PowerMeter.service.uuid)/power-meter-0")
        await expectEventually { metrics.meterDescription(of: meterID)?.suggestedRole == .grid }
        let series = "plugin:ShellyNG:shellypro3em-aabbccddeeff:em:0:power"
        device.notify("NotifyStatus", #"{"em:0":{"total_act_power":-480.0}}"#)
        await expectEventually {
            metrics.valueHistories(from: Date().addingTimeInterval(-120), to: Date().addingTimeInterval(60), series: [series]).points[series]?.last?.values.low == -480
        }
        #expect(metrics.energyTags[series]?.role == .grid)
        #expect(metrics.meters.meters == [meterID])
    }

    /// A 3EM's records (its CSV: a row of Wh a minute per phase) come into its Meter added up by hour, what it drew and
    /// sent back, and as the grid into the Home Energy's long-term history, from the oldest record the device keeps.
    @Test func anEnergyMetersRecordsAreImported() async throws {
        let device = FakeShellyNG(
            info: #"{"id":"shellypro3em-aabbccddeeff","mac":"AABBCCDDEEFF","model":"SPEM-003CEBEU","gen":2,"ver":"1.4.0","app":"Pro3EM"}"#,
            status: #"{"em:0":{"id":0,"a_voltage":230.1,"total_current":3.2,"total_act_power":735.5},"emdata:0":{"id":0,"total_act":123456.0,"total_act_ret":10.0}}"#)
        // Two minutes at the end of the hour three hours ago, two at the start of the next.
        let hour = (Int(Date().timeIntervalSince1970) / 3600 - 3) * 3600
        device.answer("EMData.GetRecords", #"{"data_blocks":[{"ts":\#(hour - 120),"period":60,"records":4}]}"#)
        let header = "timestamp,a_total_act_energy,b_total_act_energy,c_total_act_energy,a_total_act_ret_energy,b_total_act_ret_energy,c_total_act_ret_energy,a_max_voltage"
        let rows = ["\(hour - 120),1,2,3,0,0,0.5,231", "\(hour - 60),1,2,3,0,0,0.5,231", "\(hour),2,2,2,0,0,0,230", "\(hour + 60),2,2,2,0,0,0,230"]
        environment.http.answer("/emdata/0/data.csv", ([header] + rows).joined(separator: "\n"))
        environment.add(device)
        let host = try await environment.start(settings: ["devices": [["id": "shellypro3em-aabbccddeeff", "hostname": "10.0.0.9"]]])
        defer { Task { await host.stop() } }
        let metrics = Metrics(directory: nil, interval: .seconds(60))
        metrics.start(following: host)
        defer { metrics.stop() }
        let id = "ShellyNG:shellypro3em-aabbccddeeff-em-0"
        let meterID = MeterID(accessory: id, meter: "\(PowerMeter.service.uuid)/power-meter-0")
        let start = Date(timeIntervalSince1970: TimeInterval(hour - 3600))
        await expectEventually { metrics.meters.hours(of: meterID, from: start, to: start.addingTimeInterval(3600)).count == 2 }
        let hours = metrics.meters.hours(of: meterID, from: start, to: start.addingTimeInterval(3600))
        #expect(hours.map(\.consumption) == [12, 12])
        #expect(hours.map(\.returned) == [1, 0])
        #expect(hours.allSatisfy { !$0.recorded })
        // The grid's import and export in the Home Energy's history.
        let imported = metrics.archive.importedHours(from: start, to: start.addingTimeInterval(3600))
        #expect(imported.map(\.flows.gridImport) == [12, 12])
        #expect(imported.map(\.flows.gridExport) == [1, 0])
        #expect(environment.http.paths.contains { $0.hasPrefix("/emdata/0/data.csv?add_keys=true&ts=") })
        await expectEventually { host.energyImportProgress.first?.state == .done }
    }

    /// A device that sums its hours (`EMData.GetNetEnergies`) gives them in pages: each phase's net energy added up, an
    /// hour above zero drawn and one below sent back; no CSV is asked for.
    @Test func anEnergyMetersHoursComeSummedByTheDevice() async throws {
        let device = FakeShellyNG(
            info: #"{"id":"shellypro3em-aabbccddeeff","mac":"AABBCCDDEEFF","model":"SPEM-003CEBEU","gen":2,"ver":"1.4.0","app":"Pro3EM"}"#,
            status: #"{"em:0":{"id":0,"a_voltage":230.1,"total_current":3.2,"total_act_power":735.5},"emdata:0":{"id":0,"total_act":123456.0,"total_act_ret":10.0}}"#)
        let hour = (Int(Date().timeIntervalSince1970) / 3600 - 3) * 3600
        device.answer("EMData.GetRecords", #"{"data_blocks":[{"ts":\#(hour),"period":60,"records":120}]}"#)
        device.answer("EMData.GetNetEnergies", #"{"keys":["a_net_act_energy","b_net_act_energy","c_net_act_energy"],"data":[{"ts":\#(hour),"period":3600,"values":[[100,200,300],[0,0,-50]]}]}"#)
        environment.add(device)
        let host = try await environment.start(settings: ["devices": [["id": "shellypro3em-aabbccddeeff", "hostname": "10.0.0.9"]]])
        defer { Task { await host.stop() } }
        let metrics = Metrics(directory: nil, interval: .seconds(60))
        metrics.start(following: host)
        defer { metrics.stop() }
        let meterID = MeterID(accessory: "ShellyNG:shellypro3em-aabbccddeeff-em-0", meter: "\(PowerMeter.service.uuid)/power-meter-0")
        let start = Date(timeIntervalSince1970: TimeInterval(hour))
        await expectEventually { metrics.meters.hours(of: meterID, from: start, to: start.addingTimeInterval(3600)).count == 2 }
        let hours = metrics.meters.hours(of: meterID, from: start, to: start.addingTimeInterval(3600))
        #expect(hours.map(\.consumption) == [600, 0])
        #expect(hours.map(\.returned) == [0, 50])
        #expect(device.calls("EMData.GetNetEnergies").first?["params"]?["period"] == 3600)
        #expect(!environment.http.paths.contains { $0.hasPrefix("/emdata/") })
    }

    /// The CSV's rows added up by hour, a row with a missing value left out.
    @Test func recordsAddUpByHour() throws {
        let csv = Data("timestamp,total_act_energy,total_act_ret_energy\n3600,1.5,0\n3660,2.5,1\n7200,4,\n7260,x,1\n".utf8)
        let hours = try #require(Gen2Device.hours(csv: csv, drawn: ["total_act_energy"], back: ["total_act_ret_energy"]))
        #expect(hours[3600]?.drawn == 4 && hours[3600]?.back == 1)
        #expect(hours[7200]?.drawn == 4 && hours[7200]?.back == 0)
        #expect(Gen2Device.hours(csv: Data("nothing".utf8), drawn: ["a"], back: []) == nil)
    }

    @Test func canonicalSettingsMoveDevicesIntoAccessorySettings() throws {
        let block: JSONValue = [
            "platform": "ShellyNG",
            "devices": [
                ["id": "ShellyPlus1PM-AABBCCDDEEFF", "name": "Kitchen", "hostname": "10.0.0.9", "password": "secret", "switch:0": ["type": "outlet"]],
                ["id": "shellypro4pm-aabbccddeeff", "exclude": true],
                ["id": "shellyplus1-aabbccddeeff", "protocol": "outboundWebsocket"],
            ],
        ]
        let (canonical, vaulted) = ShellyNGPlugin.canonical(block, passwords: ["shellyplus1pm-aabbccddeeff": "secret"])
        #expect(vaulted == ["shellyplus1pm-aabbccddeeff": "secret"])
        let entry = try #require(canonical["_accessories"]?["shellyplus1pm-aabbccddeeff"])
        #expect(entry["name"] == "Kitchen")
        #expect(entry["hostname"] == "10.0.0.9")
        #expect(entry["switch:0"] == ["type": "outlet"])
        #expect(entry["password"] == nil)
        #expect(canonical["_accessories"]?["shellypro4pm-aabbccddeeff"]?["excluded"] == true)
        #expect(canonical["devices"]?.arrayValue?.count == 1)
    }

    @Test func theSchemaIsCurrent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(ShellyNGPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines), "run: swift Scripts/embed-assets.swift plugin Plugins/Shelly ShellyNGPlugin")
        #expect(try JSONValue(string: ShellyNGPlugin.configurationSchemaJSON!)["pluginAlias"] == "ShellyNG")
        let gen1 = try String(contentsOf: root.appendingPathComponent("config.gen1.schema.json"), encoding: .utf8)
        #expect(ShellyPlugin.configurationSchemaJSON == gen1.trimmingCharacters(in: .whitespacesAndNewlines),
                "run: swift Scripts/embed-assets.swift plugin Plugins/Shelly ShellyPlugin config.gen1.schema.json")
        #expect(try JSONValue(string: ShellyPlugin.configurationSchemaJSON!)["pluginAlias"] == "Shelly")
    }
}

final class PressLog: Sendable {
    private let box = NIOLockedValueBox<[HAPValue]>([])
    func add(_ value: HAPValue) { box.withLockedValue { $0.append(value) } }
    var values: [HAPValue] { box.withLockedValue { $0 } }
}

/// A Shelly Cloud token (a JWT without a signature) naming the account's server, valid for an hour.
func cloudToken() -> String {
    let claims = #"{"user_api_url":"https://shelly-1-eu.shelly.cloud","exp":\#(Int(Date().timeIntervalSince1970) + 3600)}"#
    return "e30." + Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
}
