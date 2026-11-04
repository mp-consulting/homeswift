import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftRing

struct RingIdentityTests {
    @Test func homebridgeUUIDs() {
        let vectors = [
            "1001camera": "0c3b0c68-90ba-4c1e-ac80-efd358d2c1b6", "1002camera": "5322f216-72ab-4eb6-9bed-1bca0da88ec1",
            "2001": "9195f873-d171-45b7-975f-88118db6dc42", "5001": "7b61dec0-7e02-4c18-8790-670af43e717f",
            "zid-security-panel": "80dd424c-99c8-44fc-98d2-15e50c1a00ca", "zid-contact": "08c163b6-1a37-4394-b1e5-a55c9caa85bd",
            "zid-security-panelpanic": "12db32f8-286d-4548-9f7f-b9a2fc2075cd", "loc-alarm-001mode": "cb47393a-1236-4e4b-8364-ffdaf0279083",
        ]
        for (seed, uuid) in vectors { #expect(RingIdentity.homebridgeUUID(seed) == uuid, "\(seed)") }
    }

    @Test func hardwareID() {
        #expect(RingIdentity.hardwareID(systemID: String(repeating: "0123456789abcdef", count: 4)) == "c3b5b8ad-76e2-5873-a024-9491721d2150")
    }

    @Test func tokenWrapper() {
        let wrapper = RingTokenWrapper(parsing: Fixtures.wrapper)
        #expect(wrapper.refreshToken == "EXAMPLE-RT")
        #expect(wrapper.hardwareID == Fixtures.hardwareID)
        #expect(RingTokenWrapper(refreshToken: "EXAMPLE-RT", hardwareID: Fixtures.hardwareID).encoded == Fixtures.wrapper)
        let bare = RingTokenWrapper(parsing: "abc.def")
        #expect(bare.refreshToken == "abc.def")
        #expect(bare.hardwareID == nil)
        // A member it does not use (the push library's credentials) is kept.
        let withPush = RingTokenWrapper(parsing: Data(#"{"rt":"x","hid":"h","pnc":{"config":{}}}"#.utf8).base64EncodedString())
        #expect(withPush.others["pnc"]?["config"] != nil)
        #expect(RingTokenWrapper(parsing: withPush.encoded) == withPush)
    }
}

struct RingPushRoutingTests {
    @Test func dingKeepsItsLargeID() {
        let route = RingPush.route([
            "version": "2.0.0",
            "android_config": #"{"category":"com.ring.pn.live-event.ding","body":"There's someone at your Front Door"}"#,
            "data": #"{"device":{"id":1001,"kind":"lpd_v1","name":"Front Door"},"event":{"ding":{"id":7300000000000000001,"subtype":"ding"}},"location":{"id":"loc-alarm-001"}}"#,
            "img": #"{"snapshot_uuid":"abcd-1234:extra"}"#,
        ])
        #expect(route == .notification(RingNotification(deviceID: "1001", category: RingNotification.ding, dingID: "7300000000000000001", snapshotUUID: "abcd-1234")))
    }

    @Test func intercomUnlock() {
        let route = RingPush.route(["data": #"{"gcmData":{"action":"com.ring.push.INTERCOM_UNLOCK_FROM_APP","aps":{"alert":"…"},"alarm_meta":{"device_zid":5001,"location_id":"loc-alarm-001"}}}"#])
        #expect(route == .intercomUnlocked(deviceID: "5001"))
        #expect(RingPush.route(["other": "x"]) == .ignored)
    }

    @Test func largeIntegersAreQuoted() {
        #expect(RingPush.quotingLargeIntegers(#"{"a":7300000000000000002,"b":12,"c":"7300000000000000003","d":1.5e300,"e":true}"#)
            == #"{"a":"7300000000000000002","b":12,"c":"7300000000000000003","d":1.5e300,"e":true}"#)
    }
}

struct RingTamperTests {
    @Test func onlyAReportedTamperStatusShows() throws {
        let sensor = RingCommon.sensor(.motionSensor, data: [:])
        let parts = RingCommon.Parts(sensors: [sensor])
        RingCommon.show([:], on: parts)
        #expect(sensor[.statusTampered]?.value == .int(0))
        RingCommon.show(["tamperStatus": "tamper"], on: parts)
        #expect(sensor[.statusTampered]?.value == .int(1))
        RingCommon.show(["tamperStatus": "ok"], on: parts)
        #expect(sensor[.statusTampered]?.value == .int(0))
    }
}

struct RingClientTests {
    @Test func twoFactorPrompts() async throws {
        let cloud = FakeRingCloud()
        cloud.state.withLockedValue { $0.oauth = { _ in NetworkResponse(status: 412, body: Data(#"{"next_time_in_secs":60,"phone":"+1xxxxxx1234","tsv_state":"sms"}"#.utf8)) } }
        await #expect(throws: RingError.needsCode("Enter the code sent to +1xxxxxx1234 via sms")) {
            try await RingClient.requestToken(http: cloud, grant: .password(email: "a@example.com", password: "p"), hardwareID: "h", code: nil, timeout: .seconds(5))
        }
        cloud.state.withLockedValue { $0.oauth = { _ in NetworkResponse(status: 400, body: Data(#"{"error":"Verification Code is invalid or expired"}"#.utf8)) } }
        await #expect(throws: RingError.wrongCode) {
            try await RingClient.requestToken(http: cloud, grant: .password(email: "a@example.com", password: "p"), hardwareID: "h", code: "1", timeout: .seconds(5))
        }
        cloud.state.withLockedValue { $0.oauth = { _ in NetworkResponse(status: 429, body: Data(#"{"error":"x","error_description":"too many requests from dependency service"}"#.utf8)) } }
        await #expect(throws: RingError.rateLimited) {
            try await RingClient.requestToken(http: cloud, grant: .refresh("rt"), hardwareID: "h", code: nil, timeout: .seconds(5))
        }
        let request = try #require(cloud.requests.first)
        #expect(request.body?["client_id"] == "ring_official_android")
        #expect(request.body?["grant_type"] == "password")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct RingPluginTests {
    let environment = TestEnvironment()

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(RingPlugin.Configuration.self, from: Data(#"{"platform":"Ring"}"#.utf8))
        #expect(configuration.cameraPolling == 20)
        #expect(configuration.locationModePolling == 20)
        #expect(configuration.displayName == "homebridge-ring")
    }

    @Test func theFixturesBecomeAccessories() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.accessory("1003camera") != nil && host.accessory("5001") != nil })
        // The rotated token is in the vault at once; the session was made when Ring asked for one.
        let plugin = try #require(environment.plugin)
        let stored = try #require(await plugin.context.credentials(as: RingAccount.self))
        #expect(stored.refreshToken == "EXAMPLE-RT-2")
        #expect(stored.hardwareId == Fixtures.hardwareID)
        #expect(environment.cloud.state.withLockedValue { $0.sessions } == 1)
        #expect(environment.socketURLs.withLockedValue { $0 }.first?.absoluteString == "wss://hub.example.invalid/ws?authcode=TICKET&ack=false")
        let firstSent = try JSONValue(string: try #require(environment.socket.sentText.first))
        #expect(firstSent == (try JSONValue(string: #"{"channel":"message","msg":{"msg":"DeviceInfoDocGetList","dst":"asset-base-uuid-0001","seq":1}}"#)))

        let panel = try #require(host.accessory("zid-security-panel")?.service(.securitySystem))
        #expect(panel[.securitySystemCurrentState]?.value == .int(3))
        #expect(panel[.securitySystemTargetState]?.value == .int(3))
        #expect(host.accessory("zid-security-panel")?.service(.switch)?[.on]?.value == .bool(false))

        let base = try #require(host.accessory("zid-base-station"))
        #expect(base.service(.speaker)?[.volume]?.value == .int(50))
        #expect(base.service(.battery) == nil)
        #expect(base.service(.lightbulb) == nil)

        let contact = try #require(host.accessory("zid-contact"))
        #expect(contact.service(.contactSensor)?[.contactSensorState]?.value == .int(0))
        #expect(contact.service(.battery)?[.batteryLevel]?.value == .int(50))
        #expect(contact.service(.battery)?[.statusLowBattery]?.value == .int(0))

        let thermostat = try #require(host.accessory("zid-thermostat")?.service(.thermostat))
        #expect(thermostat[.currentTemperature]?.value == .double(19.9))
        #expect(thermostat[.currentHeatingCoolingState]?.value == .int(1))
        #expect(thermostat[.targetTemperature]?.type.minValue == 10)
        #expect(thermostat[.targetTemperature]?.type.maxValue == 30)
        #expect(host.accessory("zid-thermo-temp")?.service(.temperatureSensor)?[.currentTemperature]?.value.doubleValue.map { abs($0 - 19.94) < 0.05 } == true)

        let doorbell = try #require(host.accessory("1001camera"))
        #expect(doorbell.service(.doorbell) != nil)
        #expect(doorbell.service(.statelessProgrammableSwitch) != nil)
        #expect(doorbell.service(.switch, subtype: "In-Home Doorbell")?[.on]?.value == .bool(true))
        #expect(doorbell.service(.battery) == nil)
        #expect(doorbell.service(.lightbulb) == nil)
        #expect(doorbell.information[.model]?.value == .string("Doorbell Pro (lpd_v1)"))

        let indoor = try #require(host.accessory("1002camera"))
        #expect(indoor.service(.lightbulb) != nil)
        #expect(indoor.service(.switch, subtype: "Siren") != nil)
        #expect(indoor.service(.battery)?[.batteryLevel]?.value == .int(87))
        #expect(indoor.service(.doorbell) == nil)

        let onvif = try #require(host.accessory("1003camera"))
        #expect(onvif.information[.manufacturer]?.value == .string("Acme"))
        #expect(onvif.information[.model]?.value == .string("X1"))

        let chime = try #require(host.accessory("2001"))
        #expect(chime.service(.lightbulb, subtype: "nightlight") != nil)
        #expect(chime.service(.speaker)?[.volume]?.value == .int(6))
        #expect(host.accessory("5001")?.service(.battery)?[.batteryLevel]?.value == .int(100))
        // A location with an alarm has no Location Mode.
        #expect(host.accessory("loc-alarm-001mode") == nil)
        // Cameras are on servers of their own.
        #expect(host.bridges.filter(\.isExternal).count == 3)
        // Subscribing follows the accessories.
        #expect(await eventually { environment.cloud.count("doorbots/1001/subscribe") >= 1 })
        #expect(await eventually { environment.cloud.count("doorbots/1001/motions_subscribe") >= 1 })
        await host.stop()
    }

    @Test func hubUpdatesReachHomeKit() async throws {
        let host = try await environment.start(settings: ["refreshToken": Fixtures.wrapper, "alarmOnEntryDelay": false])
        #expect(await eventually { host.accessory("zid-contact") != nil })
        let contact = try #require(host.accessory("zid-contact")?.service(.contactSensor)?[.contactSensorState])
        environment.socket.receive(text: Fixtures.update("zid-contact", #"{"faulted":true}"#))
        #expect(await eventually { contact.value == .int(1) })

        let panel = try #require(host.accessory("zid-security-panel")?.service(.securitySystem))
        environment.socket.receive(text: Fixtures.update("zid-security-panel", #"{"mode":"all","alarmInfo":{"state":"burglar-alarm","faultedDevices":["zid-contact"]}}"#))
        #expect(await eventually { panel[.securitySystemCurrentState]?.value == .int(4) })
        #expect(panel[.securitySystemTargetState]?.value == .int(1))
        environment.socket.receive(text: Fixtures.update("zid-security-panel", #"{"alarmInfo":{"state":"entry-delay"}}"#))
        #expect(await eventually { panel[.securitySystemCurrentState]?.value == .int(1) })
        await host.stop()
    }

    @Test func nightArmsAwayBypassingOpenSensors() async throws {
        let host = try await environment.start(settings: ["refreshToken": Fixtures.wrapper, "nightModeBypassFor": "all"])
        #expect(await eventually { host.accessory("zid-contact") != nil })
        environment.socket.receive(text: Fixtures.update("zid-contact", #"{"faulted":true}"#))
        #expect(await eventually { host.accessory("zid-contact")?.service(.contactSensor)?[.contactSensorState]?.value == .int(1) })
        let target = try #require(host.accessory("zid-security-panel")?.service(.securitySystem)?[.securitySystemTargetState])
        #expect(target.type.validValues == [0, 1, 2, 3])
        try await write(target, .int(2))
        #expect(await eventually { environment.socket.sentText.contains { $0.contains("security-panel.switch-mode") } })
        let sent = try JSONValue(string: try #require(environment.socket.sentText.first { $0.contains("switch-mode") }))
        #expect(sent["msg"]?["dst"] == "asset-base-uuid-0001")
        #expect(sent["msg"]?["datatype"] == "DeviceInfoSetType")
        #expect(sent["msg"]?["body"]?[0]?["zid"] == "zid-security-panel")
        #expect(sent["msg"]?["body"]?[0]?["command"]?["v1"]?[0] == (try JSONValue(string: #"{"commandType":"security-panel.switch-mode","data":{"mode":"all","bypass":["zid-contact"]}}"#)))
        // The panel answers in the mode asked for: Night is the target.
        environment.socket.receive(text: Fixtures.update("zid-security-panel", #"{"mode":"all"}"#))
        #expect(await eventually { target.value == .int(2) })
        await host.stop()
    }

    @Test func aModeChangeThePanelNeverAnswersIsUndone() async throws {
        var timing = TestEnvironment.timing
        timing.alarmModeTimeout = .milliseconds(200)
        let host = try await environment.start(timing: timing)
        #expect(await eventually { host.accessory("zid-security-panel") != nil })
        let target = try #require(host.accessory("zid-security-panel")?.service(.securitySystem)?[.securitySystemTargetState])
        let before = target.value
        #expect(before != .int(1))
        // As HomeKit does with a write it accepted.
        target.value = .int(1)
        try await write(target, .int(1))
        #expect(await eventually { environment.socket.sentText.contains { $0.contains("security-panel.switch-mode") } })
        // No update comes back: the wait ends and HomeKit shows the mode the panel is in.
        #expect(await eventually { target.value == before })
        await host.stop()
    }

    @Test func dimmerWritesTheLastLevel() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.accessory("zid-beam-dimmer") != nil })
        let light = try #require(host.accessory("zid-beam-dimmer")?.service(.lightbulb))
        #expect(light[.brightness]?.value == .int(20))
        let brightness = try #require(light[.brightness])
        try await write(brightness, .int(10))
        try await write(brightness, .int(42))
        #expect(await eventually { environment.socket.sentText.contains { $0.contains("\"level\":0.42") } })
        #expect(!environment.socket.sentText.contains { $0.contains("\"level\":0.1") })
        #expect(host.accessory("zid-beam-dimmer")?.service(.motionSensor) != nil)
        await host.stop()
    }

    @Test func pushesDriveMotionAndTheDoorbell() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.accessory("1002camera") != nil && host.accessory("1001camera") != nil })
        let motion = try #require(host.accessory("1002camera")?.service(.motionSensor)?[.motionDetected])
        try environment.push.push([
            "android_config": #"{"category":"com.ring.pn.live-event.motion"}"#,
            "data": #"{"device":{"id":1002},"event":{"ding":{"id":7300000000000000002,"subtype":"human"}}}"#,
            "img": #"{"snapshot_uuid":"5e1f-aaaa:1700000000"}"#,
        ])
        #expect(await eventually { motion.value == .bool(true) })
        #expect(environment.cloud.count("snapshots/next/1002?uuid=5e1f-aaaa") == 1)
        // The notification expires: no more motion.
        #expect(await eventually { motion.value == .bool(false) })

        try environment.push.push([
            "android_config": #"{"category":"com.ring.pn.live-event.ding"}"#,
            "data": #"{"device":{"id":1001},"event":{"ding":{"id":"7300000000000000001","subtype":"ding"}}}"#,
            "img": #"{"snapshot_uuid":"abcd-1234:extra"}"#,
        ])
        #expect(await eventually { environment.cloud.count("snapshots/next/1001?uuid=abcd-1234") == 1 })
        // The push token went to Ring.
        #expect(await eventually { environment.cloud.requests.contains { $0.method == "PATCH" && $0.url.hasSuffix("clients_api/device") } })
        await host.stop()
    }

    @Test func anEventSnapshotDoesNotTakeTheCurrentOne() async throws {
        let host = try await environment.start()
        #expect(await eventually { await environment.plugin?.cameraList.count == 3 })
        let camera = try #require(await environment.plugin?.cameraList.first { $0.id == "1001" })
        environment.cloud.state.withLockedValue { $0.holdSnapshots = true }
        let current = Task { try await camera.refreshSnapshot(uuid: nil) }
        #expect(await eventually { environment.cloud.count("snapshots/next/1001?after-ms=0&extras=force") == 1 })
        // A ding's frame while the current image is on its way: a request of its own.
        let event = Task { try await camera.refreshSnapshot(uuid: "abcd-1234") }
        #expect(await eventually { environment.cloud.count("snapshots/next/1001?uuid=abcd-1234") == 1 })
        environment.cloud.state.withLockedValue { $0.holdSnapshots = false }
        let images = (try await current.value, try await event.value)
        #expect(images.0 == Fixtures.jpeg)
        #expect(images.1 == Fixtures.jpeg)
        await host.stop()
    }

    @Test func snapshotsAreCachedAndRefreshed() async throws {
        let host = try await environment.start()
        #expect(await eventually { await environment.plugin?.cameraList.count == 3 })
        let camera = try #require(await environment.plugin?.cameraList.first { $0.id == "1001" })
        // Nothing cached yet: an error, and a refresh in the background.
        await #expect(throws: (any Error).self) { try await camera.handleSnapshotRequest(SnapshotRequest(height: 720, width: 1280)) }
        #expect(await eventually { (try? await camera.handleSnapshotRequest(SnapshotRequest(height: 720, width: 1280))) == Fixtures.jpeg })
        #expect(environment.cloud.count("snapshots/next/1001?after-ms=0&extras=force") == 1)
        await host.stop()
    }

    @Test func intercomUnlocksForAWhile() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.accessory("5001") != nil })
        let lock = try #require(host.accessory("5001")?.service(.lockMechanism))
        try await write(lock[.lockTargetState], .int(0))
        #expect(await eventually { lock[.lockCurrentState]?.value == .int(0) })
        #expect(environment.cloud.requests.contains { $0.url.hasSuffix("commands/v1/devices/5001/device_rpc") && $0.body?["request"]?["method"] == "unlock_door" })
        #expect(await eventually { lock[.lockCurrentState]?.value == .int(1) })
        await host.stop()
    }

    @Test func hiddenDevicesAndDeviceTypes() async throws {
        let host = try await environment.start(settings: [
            "refreshToken": Fixtures.wrapper, "hideDeviceIds": ["08c163b6-1a37-4394-b1e5-a55c9caa85bd"], "showPanicButtons": true,
        ])
        #expect(await eventually { host.accessory("5001") != nil })
        #expect(host.accessory("zid-contact") == nil)
        let panic = try #require(host.accessory("zid-security-panelpanic"))
        let burglar = try #require(panic.service(.switch, subtype: "Burglar")?[.on])
        #expect(burglar.isSecurityControl)
        #expect(panic.service(.switch, subtype: "Fire") != nil)
        // The panel's updates reach its panic buttons.
        environment.socket.receive(text: Fixtures.update("zid-security-panel", #"{"alarmInfo":{"state":"burglar-alarm"}}"#))
        #expect(await eventually { burglar.value == .bool(true) })
        environment.socket.receive(text: Fixtures.update("zid-security-panel", #"{"alarmInfo":{"state":"none"}}"#))
        #expect(await eventually { burglar.value == .bool(false) })
        await host.stop()
    }

    @Test func sirensAreSecurityControls() async throws {
        let host = try await environment.start()
        #expect(await eventually { host.accessory("1002camera") != nil && host.accessory("zid-security-panel") != nil })
        #expect(host.accessory("zid-security-panel")?.service(.switch)?[.on]?.isSecurityControl == true)
        #expect(host.accessory("1002camera")?.service(.switch, subtype: "Siren")?[.on]?.isSecurityControl == true)
        await host.stop()
    }

    @Test func aRefusedTokenNeedsSigningInAgain() async throws {
        environment.cloud.state.withLockedValue { $0.oauth = { _ in NetworkResponse(status: 401, body: Data(#"{"error":"invalid_grant"}"#.utf8)) } }
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.context.credentials(as: RingAccount.self)?.refused == true })
        #expect(await plugin.context.credentials(as: RingAccount.self)?.refreshToken == "EXAMPLE-RT")
        #expect(await plugin.accountAuthorized() == false)
        await host.stop()
    }

    @Test func anOfflineCameraShowsThePlaceholder() async throws {
        environment.cloud.state.withLockedValue { $0.devices = $0.devices.replacingOccurrences(of: #""alerts":{"connection":"online"},"battery_life":null"#, with: #""alerts":{"connection":"offline"},"battery_life":null"#) }
        let host = try await environment.start()
        #expect(await eventually { await environment.plugin?.cameraList.count == 3 })
        let camera = try #require(await environment.plugin?.cameraList.first { $0.id == "1001" })
        let image = try await camera.handleSnapshotRequest(SnapshotRequest(height: 720, width: 1280))
        #expect(image == RingPlaceholder.jpeg)
        #expect(image.starts(with: [0xFF, 0xD8]))
        #expect(environment.cloud.count("snapshots/next/1001") == 0)
        await host.stop()
    }

    @Test func setupSignsInWithACode() async throws {
        let host = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        #expect(await plugin.accountAuthorized() == false)
        environment.cloud.state.withLockedValue { state in
            state.oauth = { request in
                let code = request.header("2fa-code") ?? ""
                if code.isEmpty { return NetworkResponse(status: 412, body: Data(#"{"tsv_state":"totp"}"#.utf8)) }
                return NetworkResponse(status: 200, body: Data(#"{"access_token":"AT","expires_in":3600,"refresh_token":"NEW-RT"}"#.utf8))
            }
        }
        let first = try await plugin.authorize(SetupRequest(target: .account))
        guard case .ask(let prompt, _) = first else { Issue.record("no prompt"); return }
        #expect(prompt.fields.map(\.key) == ["email", "password"])
        let second = try await plugin.authorize(SetupRequest(target: .account, answers: ["email": "a@example.com", "password": "secret"]))
        guard case .ask(let codePrompt, let state) = second else { Issue.record("no code prompt"); return }
        #expect(codePrompt.message == "Enter the code from your authenticator app.")
        let done = try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "123456"], state: state))
        guard case .done(let outcome) = done else { Issue.record("not done"); return }
        #expect(outcome.credentials?["refreshToken"] == "NEW-RT")
        #expect(outcome.settings["refreshToken"] == .null)
        await host.stop()
    }

    @Test func canonicalSettingsMovesTheTokenAndTheHiddenIDs() async throws {
        let host = try await environment.start(settings: ["refreshToken": Fixtures.wrapper, "hideDeviceIds": ["7b61dec0-7e02-4c18-8790-670af43e717f", "unknown"]])
        #expect(await eventually { await environment.plugin?.built.isEmpty == false })
        let plugin = try #require(environment.plugin)
        let block = try JSONValue(string: #"{"platform":"Ring","refreshToken":"\#(Fixtures.wrapper)","hideDeviceIds":["7b61dec0-7e02-4c18-8790-670af43e717f","unknown"]}"#)
        let canonical = await plugin.canonicalSettings(block)
        #expect(canonical["refreshToken"] == nil)
        #expect(canonical["hideDeviceIds"] == ["unknown"])
        #expect(await plugin.canonicalSettings(canonical) == canonical)
        await host.stop()
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(RingPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Ring RingPlugin")
        let schema = try JSONValue(string: try #require(RingPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "Ring")
        #expect(schema["schema"]?["properties"]?["refreshToken"] == nil)
    }
}
