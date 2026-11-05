import Foundation
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import Testing

@testable import Homeswift
@testable import HomeswiftImou

/// The plugin on a bridge, against the cloud and a camera in memory.
@Suite(.timeLimit(.minutes(1)))
struct ImouTests {
    let environment = TestEnvironment()
    let gardenID = "Imou:TEST000CAM1:0"

    /// A camera of the account with its local address and safety code, as a hand-written block gives them.
    var localBlock: [String: Any] {
        var block = TestEnvironment.account
        block["devices"] = [["deviceId": "TEST000CAM1", "host": "192.0.2.20", "password": "L2A3B4C5", "motionTimeout": 1000]]
        return block
    }

    func garden(_ host: PluginHost, in other: TestEnvironment? = nil) async throws -> Accessory {
        let environment = other ?? environment, id = gardenID
        #expect(await eventually { environment.accessory(host, id) != nil })
        return try #require(environment.accessory(host, id))
    }

    func service(_ accessory: Accessory, _ subtype: String) -> Service? { accessory.services.first { $0.subtype == subtype } }

    /// The plugin's camera of the garden, once it is published.
    func runningCamera(in other: TestEnvironment? = nil) async throws -> ImouCamera {
        let environment = other ?? environment, id = gardenID
        #expect(await eventually { await environment.plugin?.camera(id) != nil })
        return try #require(await environment.plugin?.camera(id))
    }

    @Test func aBlockWithNothingCostsNothing() async throws {
        let host = try await environment.start(["platform": "Imou"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(environment.cloud.calls.isEmpty && environment.camera.targets.isEmpty)
        #expect(host.bridges.count == 1)
        await host.stop()
    }

    @Test func theAccountsCameraIsAnAccessoryOfItsOwnWithItsServices() async throws {
        environment.cloud.addCamera()
        let host = try await environment.start()
        let accessory = try await garden(host)
        #expect(accessory.category == .ipCamera)
        #expect(accessory.information.characteristic(.manufacturer).value == "Imou")
        #expect(accessory.information.characteristic(.model).value == "IPC-F42P")
        #expect(accessory.information.characteristic(.serialNumber).value == "TEST000CAM1")
        #expect(accessory.information.characteristic(.firmwareRevision).value == "2.840.0")
        #expect(accessory.services.contains { $0.type == .motionSensor })
        #expect(accessory.services.contains { $0.type == .cameraRTPStreamManagement })
        #expect(service(accessory, "privacy")?.type == .switch && service(accessory, "motionDetection")?.type == .switch)
        #expect(service(accessory, "spotlight")?.type == .lightbulb)
        let siren = try #require(service(accessory, "siren"))
        #expect(siren.characteristic(.on).isSecurityControl)
        // Cloud-only: no recording without a local stream.
        #expect(!accessory.services.contains { $0.type == .cameraRecordingManagement })
        await host.stop()
    }

    @Test func pollsReadTheSwitchesAndOnlyThem() async throws {
        environment.cloud.addCamera()
        environment.cloud.state.withLockedValue { $0.statuses["TEST000CAM1:0:closeCamera"] = true }
        let host = try await environment.start()
        let accessory = try await garden(host)
        let privacy = try #require(service(accessory, "privacy"))
        #expect(await eventually { privacy.characteristic(.on).value == true })
        let cloud = environment.cloud
        // Several poll cycles (300 ms each at this scale): each asks deviceOnline once, then the four switches.
        #expect(await eventually { cloud.calls("deviceOnline").count >= 4 })
        let polls = cloud.calls("deviceOnline").count
        let reads = cloud.calls("getDeviceCameraStatus").count
        #expect(reads >= (polls - 1) * 4 && reads <= (polls + 1) * 4)
        #expect(Set(cloud.calls("getDeviceCameraStatus").compactMap { $0.params["enableType"]?.stringValue }) == ["closeCamera", "whiteLight", "mobileDetect", "motionDetect"])
        // The listing only at rediscoveries, never once a poll (a loaded machine stretches the test over more of them), and
        // one token.
        #expect(cloud.calls("listDeviceDetailsByPage").count < cloud.calls("deviceOnline").count)
        #expect(cloud.tokenFetches == 1)
        await host.stop()
    }

    @Test func writesReachTheCloudOnceEach() async throws {
        environment.cloud.addCamera()
        let host = try await environment.start()
        let accessory = try await garden(host)
        let privacy = try #require(service(accessory, "privacy")).characteristic(.on)
        try await privacy.write(true)
        try await privacy.write(true)
        let sets = environment.cloud.calls("setDeviceCameraStatus").filter { $0.params["enableType"] == "closeCamera" }
        #expect(sets.count == 1 && sets.first?.params["enable"] == true && sets.first?.params["channelId"] == "0")
        try await service(accessory, "spotlight")?.characteristic(.on).write(true)
        #expect(environment.cloud.calls("setDeviceCameraStatus").contains { $0.params["enableType"] == "whiteLight" && $0.params["enable"] == true })
        try await service(accessory, "motionDetection")?.characteristic(.on).write(true)
        #expect(environment.cloud.calls("modifyDeviceAlarmStatus").first?.params["enable"] == true)
        // A camera closed refuses streams at once and answers snapshots with nothing new.
        let camera = try await runningCamera()
        await #expect(throws: (any Error).self) { _ = try await camera.source(for: .live) }
        await host.stop()
    }

    @Test func aRefusedWriteIsNoResponseAndKeepsTheState() async throws {
        environment.cloud.addCamera()
        let host = try await environment.start()
        let accessory = try await garden(host)
        environment.cloud.fail("setDeviceCameraStatus", with: "OP1009")
        let light = try #require(service(accessory, "spotlight")).characteristic(.on)
        await #expect(throws: HAPStatusError.self) { try await light.write(true) }
        #expect(light.value == false)
        await host.stop()
    }

    @Test func theSirenSoundsThenShowsOffAgain() async throws {
        environment.cloud.addCamera()
        let host = try await environment.start()
        let siren = try #require(service(try await garden(host), "siren")).characteristic(.on)
        try await siren.write(true)
        #expect(environment.cloud.calls("sirenStart").count == 1)
        #expect(environment.cloud.calls("sirenStart").first?.params["channels"] == nil)
        #expect(await eventually { siren.value == false })
        await host.stop()
    }

    @Test func localEventsDriveTheMotionSensor() async throws {
        environment.cloud.addCamera()
        let host = try await environment.start(localBlock)
        let accessory = try await garden(host)
        let camera = environment.camera
        #expect(await eventually { camera.streamOpens == 1 })
        // The codes in brackets, as written, answered with Digest.
        let target = try #require(camera.targets.last { $0.hasPrefix("/cgi-bin/eventManager.cgi") })
        #expect(target.hasPrefix("/cgi-bin/eventManager.cgi?action=attach&codes=[VideoMotion,SmartMotionHuman,"))
        #expect(target.hasSuffix("]&heartbeat=5"))
        let motion = try #require(accessory.services.first { $0.type == .motionSensor }).characteristic(.motionDetected)
        camera.push("Code=VideoMotion;action=Start;index=0")
        #expect(await eventually { motion.value == true })
        camera.push("Code=VideoMotion;action=Stop;index=0")
        #expect(await eventually { motion.value == false })
        // Another channel's event is not this camera's.
        camera.push("Code=VideoMotion;action=Start;index=3")
        try await Task.sleep(for: .milliseconds(50))
        #expect(motion.value == false)
        // HomeKit Secure Video from the local stream.
        #expect(accessory.services.contains { $0.type == .cameraRecordingManagement })
        // Snapshots from the camera's CGI, not the cloud.
        let image = try await runningCamera().snapshotImage()
        #expect(image == jpeg)
        #expect(environment.cloud.calls("setDeviceSnapEnhanced").isEmpty)
        #expect(camera.targets.contains("/cgi-bin/snapshot.cgi?channel=1"))
        // The stream reconnects when the camera drops it.
        camera.dropStreams()
        #expect(await eventually { camera.streamOpens == 2 })
        await host.stop()
    }

    @Test func aCameraThatRefusesTheCodesIsAskedForAll() async throws {
        environment.camera.state.withLockedValue { $0.refuseCodes = true }
        environment.cloud.addCamera()
        let host = try await environment.start(localBlock)
        let camera = environment.camera
        #expect(await eventually { camera.streamOpens == 1 })
        #expect(camera.targets.contains { $0.contains("codes=[All]") })
        await host.stop()
    }

    @Test func aWrongSafetyCodeStopsTheStreamAndTheCloudsAlarmsStandIn() async throws {
        var block = localBlock
        block["devices"] = [["deviceId": "TEST000CAM1", "host": "192.0.2.20", "password": "WRONG", "motionTimeout": 1000]]
        environment.cloud.addCamera()
        environment.cloud.state.withLockedValue { $0.alarms["TEST000CAM1"] = ["alarmId": "1001", "msgType": "human", "type": "120", "time": 1_700_000_100] }
        let host = try await environment.start(block)
        let accessory = try await garden(host)
        let cloud = environment.cloud
        // The alarms are polled once the stream is known to be down (every 60 ms at this scale).
        #expect(await eventually { cloud.calls("getAlarmMessage").count >= 2 })
        let motion = try #require(accessory.services.first { $0.type == .motionSensor }).characteristic(.motionDetected)
        // The first alarm is only noted.
        #expect(motion.value == false)
        cloud.state.withLockedValue { $0.alarms["TEST000CAM1"] = ["alarmId": "1002", "msgType": "e_videoMotion", "time": 1_700_000_200] }
        #expect(await eventually { motion.value == true })
        // No reconnect loop on a refused code.
        let attempts = environment.camera.targets.filter { $0.hasPrefix("/cgi-bin/eventManager.cgi") }.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(environment.camera.targets.filter { $0.hasPrefix("/cgi-bin/eventManager.cgi") }.count == attempts)
        await host.stop()
    }

    @Test func aCameraOnTheLANAloneRunsWithoutTheCloud() async throws {
        let host = try await environment.start(["devices": [["deviceId": "TEST000CAM1", "host": "192.0.2.20", "password": "L2A3B4C5", "name": "Porch"]]])
        let accessory = try await garden(host)
        #expect(accessory.services.allSatisfy { $0.subtype != "privacy" && $0.subtype != "siren" })
        let camera = environment.camera
        #expect(await eventually { camera.streamOpens == 1 })
        #expect(environment.cloud.calls.isEmpty)
        await host.stop()
    }

    @Test func aCloudSnapshotIsKeptAMinuteAndItsAddressNeverLogged() async throws {
        // At a twentieth the minute is 3 s: a loaded machine cannot make the second request miss it.
        let environment = TestEnvironment(timeScale: 0.05)
        environment.cloud.addCamera()
        let host = try await environment.start()
        _ = try await garden(host, in: environment)
        let camera = try await runningCamera(in: environment)
        #expect(try await camera.snapshotImage() == jpeg)
        #expect(try await camera.snapshotImage() == jpeg)
        #expect(environment.cloud.calls("setDeviceSnapEnhanced").count == 1)
        #expect(environment.download.urls.withLockedValue { $0 }.count == 1)
        await host.stop()
        let lines = environment.log.lines.withLockedValue { $0 }.joined(separator: "\n")
        // The plugin's own lines are there to check.
        #expect(lines.contains("Added Garden"))
        for secret in [FakeImouCloud.appSecret, "At_1", "SIGNATURE", "KEYID", "L2A3B4C5"] { #expect(!lines.contains(secret)) }
        for call in environment.cloud.calls { if let sign = call.body["system"]?["sign"]?.stringValue { #expect(!lines.contains(sign)) } }
    }

    @Test func aCloudStreamIsMadeForEachSessionWhenTheCameraIsNotLocal() async throws {
        environment.cloud.addCamera()
        let host = try await environment.start()
        _ = try await garden(host)
        let camera = try await runningCamera()
        let source = try await camera.source(for: .live)
        #expect(source.url == "rtsp://proxy.example.com:8554/live/secretpath")
        #expect(environment.cloud.calls("getStreamUrl").first?.params["streamId"] == 0)
        // Recordings are local only.
        await #expect(throws: (any Error).self) { _ = try await camera.source(for: .recording) }
        await host.stop()
    }

    @Test func refusedKeysMarkTheAccountAndKeepTheCameras() async throws {
        environment.cloud.addCamera()
        var block = TestEnvironment.account
        block["appSecret"] = "wrong"
        let host = try await environment.start(block)
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.context.accountRefusal != nil })
        // The documented signature, then once with MD5: both refused.
        #expect(environment.cloud.calls.count == 2)
        await host.stop()
    }

    @Test func anOfflineCameraIsNoResponseAndASleepingOneIsNeverWokenByAPoll() async throws {
        environment.cloud.addCamera()
        environment.cloud.state.withLockedValue { $0.online["TEST000CAM1"] = "4" }
        let host = try await environment.start()
        let accessory = try await garden(host)
        let cloud = environment.cloud
        #expect(await eventually { cloud.calls("deviceOnline").count >= 3 })
        #expect(cloud.calls("getDeviceCameraStatus").isEmpty && cloud.calls("wakeUpDevice").isEmpty)
        #expect(!accessory.isUnavailable)
        cloud.state.withLockedValue { $0.online["TEST000CAM1"] = "0" }
        #expect(await eventually { accessory.isUnavailable })
        let motion = try #require(accessory.services.first { $0.type == .motionSensor })
        #expect(motion.characteristic(.statusActive).value == false)
        cloud.state.withLockedValue { $0.online["TEST000CAM1"] = "1" }
        #expect(await eventually { !accessory.isUnavailable })
        await host.stop()
    }

    @Test func iotDevicesAreSkipped() async throws {
        environment.cloud.addCamera("PLUG1", name: "Plug", extra: ["productId": "p1"])
        environment.cloud.addCamera()
        let host = try await environment.start()
        _ = try await garden(host)
        #expect(environment.accessory(host, "Imou:PLUG1:0") == nil)
        await host.stop()
    }

    // MARK: Setup

    @Test func theAccountsSetupChecksTheKeysAndKeepsTheSecretInTheVault() async throws {
        let host = try await environment.start(["platform": "Imou"])
        let plugin = try #require(environment.plugin)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("expected a prompt"); return }
        #expect(prompt.fields.map(\.key) == ["appId", "appSecret", "region"])
        #expect(prompt.fields[1].kind == .secret)
        await #expect(throws: SetupError.self) {
            _ = try await plugin.authorize(SetupRequest(target: .account, answers: ["appId": FakeImouCloud.appID, "appSecret": "wrong", "region": "eu"]))
        }
        let step = try await plugin.authorize(SetupRequest(target: .account, answers: ["appId": FakeImouCloud.appID, "appSecret": FakeImouCloud.appSecret, "region": "eu"]))
        guard case .done(let outcome) = step else { Issue.record("expected done"); return }
        #expect(outcome.credentials?["appSecret"]?.stringValue == FakeImouCloud.appSecret)
        #expect(outcome.settings["appId"] == .string(FakeImouCloud.appID) && outcome.settings["region"] == "eu" && outcome.settings["appSecret"] == .null)
        await host.stop()
    }

    @Test func aCameraByAddressIsSetUpUnderItsSerial() async throws {
        let host = try await environment.start(["devices": [["host": "192.0.2.20", "name": "Porch"]]])
        let plugin = try #require(environment.plugin)
        let found = try await plugin.discover()
        let device = try #require(found.first)
        #expect(device.deviceID == "ip:192.0.2.20" && device.authorization == .deviceCode && !device.isSetUp)
        await #expect(throws: SetupError.self) {
            _ = try await plugin.authorize(SetupRequest(target: .device(device), answers: ["password": "WRONG"]))
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(device), answers: ["password": "L2A3B4C5"])) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.deviceID == "TEST000CAM1")
        #expect(outcome.credentials?["password"]?.stringValue == "L2A3B4C5")
        #expect(outcome.settings["host"] == "192.0.2.20")
        // Kept as the bridge keeps it, the camera runs on the LAN under its serial.
        try await plugin.context.saveCredentials(try #require(outcome.credentials), for: "TEST000CAM1")
        await host.stop()
        let again = try await environment.start(["_accessories": ["TEST000CAM1": ["host": "192.0.2.20", "name": "Porch"]]])
        _ = try await garden(again)
        let rediscovered = try await #require(environment.plugin).discover()
        #expect(rediscovered.map(\.deviceID) == ["TEST000CAM1"] && rediscovered.first?.isSetUp == true)
        await again.stop()
    }

    @Test func addByAddressChecksTheAddressThenTheCodeAndKeysTheCameraByItsSerial() async throws {
        #expect(ImouPlugin.addsDevicesByAddress)
        let host = try await environment.start([:])
        let plugin = try #require(environment.plugin)
        guard case .ask(let first, let none) = try await plugin.authorize(SetupRequest(target: .newDevice)) else { Issue.record("no prompt"); return }
        #expect(first.fields.map(\.key) == ["host"] && none.isNull)
        guard case .ask(let second, let state) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": " 192.0.2.20 "])) else {
            Issue.record("no code asked"); return
        }
        #expect(second.fields.map(\.key) == ["password", "username"] && second.fields[0].kind == .secret)
        #expect(state == ["host": "192.0.2.20"])
        await #expect(throws: SetupError("The camera at 192.0.2.20 refused this safety code.")) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["password": "WRONG"], state: state))
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["password": "L2A3B4C5"], state: state)) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.deviceID == "TEST000CAM1")
        #expect(outcome.credentials?["password"]?.stringValue == "L2A3B4C5")
        #expect(outcome.settings == ["host": "192.0.2.20", "username": "admin"])

        environment.camera.state.withLockedValue { $0.reachable = false }
        await #expect(throws: SetupError("No camera answered at 192.0.2.60")) {
            try await plugin.authorize(SetupRequest(target: .newDevice, answers: ["host": "192.0.2.60"]))
        }
        await host.stop()
    }

    @Test func aCloudCameraMustBeTheCameraAtItsAddress() async throws {
        environment.cloud.addCamera("OTHER0000001", name: "Drive")
        let host = try await environment.start()
        let plugin = try #require(environment.plugin)
        let device = try #require(try await plugin.discover().first)
        #expect(device.deviceID == "OTHER0000001" && !device.isSetUp)
        await #expect(throws: SetupError.self) {
            _ = try await plugin.authorize(SetupRequest(target: .device(device), answers: ["host": "192.0.2.20", "password": "L2A3B4C5"]))
        }
        // Without an address it runs on the cloud alone, and counts as set up.
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .device(device), answers: ["username": "admin"])) else {
            Issue.record("expected done"); return
        }
        #expect(outcome.credentials != nil && outcome.credentials?["password"] == nil)
        await host.stop()
    }

    @Test func theCanonicalShapeMovesTheCamerasAndDropsTheSecret() throws {
        let block: JSONValue = [
            "platform": "Imou", "appId": "x", "appSecret": "s",
            "devices": [
                ["deviceId": "CAM1", "name": "Garden", "host": "192.0.2.20", "password": "code", "motionTimeout": 30],
                ["host": "192.0.2.21"], ["host": "192.0.2.22"],
            ],
        ]
        let (canonical, moved) = ImouPlugin.canonical(block, setUpHosts: ["192.0.2.21"])
        #expect(moved == ["CAM1"])
        #expect(canonical["appSecret"] == nil)
        #expect(canonical["_accessories"]?["CAM1"] == ["name": "Garden", "host": "192.0.2.20", "motionTimeout": 30])
        #expect(canonical["devices"] == [["host": "192.0.2.22"]])
    }

    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(ImouPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
                "run: swift Scripts/embed-assets.swift plugin Plugins/Imou ImouPlugin")
        let schema = try JSONValue(string: try #require(ImouPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "Imou")
    }
}
