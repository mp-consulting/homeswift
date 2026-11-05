import Foundation
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftImou

/// The addendum's signatures, PTZ, switches, privacy kept in step with HomeKit Camera Active, the SD card, restart and the
/// quota governor (docs/clean-room/Imou.md, "Addendum").
@Suite(.timeLimit(.minutes(1)))
struct ImouParityTests {
    let environment = TestEnvironment()
    let gardenID = "Imou:TEST000CAM1:0"

    func cloud(_ fake: FakeImouCloud, now: @escaping @Sendable () -> Date = { Date() }) -> ImouCloud {
        ImouCloud(appID: FakeImouCloud.appID, appSecret: FakeImouCloud.appSecret, region: .sg, apiURL: nil,
                  environment: ImouCloud.Environment(transport: fake, now: now), logger: testLogger)
    }

    /// A block with one camera of the account and these Accessory Settings (and its address, for HomeKit Secure Video).
    func block(_ options: [String: Any], local: Bool = false, polling: Int? = nil) -> [String: Any] {
        var block = TestEnvironment.account
        var entry: [String: Any] = ["deviceId": "TEST000CAM1"].merging(options) { $1 }
        if local { entry.merge(["host": "192.0.2.20", "password": "L2A3B4C5"]) { $1 } }
        block["devices"] = [entry]
        if let polling { block["pollingInterval"] = polling }
        return block
    }

    static var allSwitches: [String: Any] { [
        "personDetectSwitch": true, "statusLightSwitch": true, "linkageSirenSwitch": true, "linkageLightSwitch": true, "nightVisionSwitch": true,
    ] }
    static let allAbilities = "WLAN,AlarmMD,CloseCamera,Siren,WhiteLight,BreathingLight,LinkageSiren,NVM,PTZ,CollectionPoint,Reboot,LocalStorage"

    /// The garden's accessory once the plugin runs its camera (it is published a moment before).
    func garden(_ host: PluginHost) async throws -> Accessory {
        let environment = environment, id = gardenID
        #expect(await eventually { await environment.plugin?.camera(id)?.accessory != nil && environment.accessory(host, id) != nil })
        return try #require(environment.accessory(host, id))
    }

    func service(_ accessory: Accessory, _ subtype: String) -> Service? { accessory.services.first { $0.subtype == subtype } }

    func request(_ method: String, _ path: String, _ body: JSONValue = .null, query: [String: String] = [:]) async throws -> PluginWebResponse {
        try await #require(environment.plugin).handleWebRequest(PluginWebRequest(method: method, path: path, query: query, body: body, user: "admin"))
    }

    // MARK: Signatures

    @Test func bothSignaturesMatchTheAddendumsVectors() {
        let secret = FakeImouCloud.appSecret
        #expect(ImouCloud.password(appSecret: secret) == "ff25d2389ab7917a77cc0c3546331401054d53cb7b2edeedb7b4e7742bb5286d")
        #expect(ImouCloud.password(appSecret: "test123456789test123456789") == "1f2da89b2fab404859f02bcc80e8521bc7a63af3e5b1da5318f7cf7c56836b09")
        let rows: [(Int, String, String, String, String)] = [
            (1_700_000_000, "Xq3vP9-nonce-0001", secret, "55dfb1b302fa7e16b04c70224fa9f111", "/KGDnPf4k0KNIoUMRkEtRBoKUOkWjrLVE0o0BDIymdQ="),
            (1_762_300_000, "nonce-ptz-0002", secret, "7a6b5b38ad6ccd64362550b46107e15f", "a+nlbu3RzTvpjkaZszXXHDT2Oa/PlfD3pVpNGPVMBuk="),
            (1_762_300_060, "nonce-cam-0003", secret, "702096723e475730eab7927aac7470a4", "iLddnaTOjE9xcTr72RwfBRJifAscu4yd810ozYxTgjs="),
            // The documentation's own worked example.
            (1_706_511_734, "f5a1ae2d-c09c-4d39-a744-83a5c2c653c2", "test123456789test123456789", "fd37b62889e4757c58b8f3bf05fb9976",
             "xjhCQBoJ9hRDsCjyDcHjtDNzRZ3ZJezcawsfWeiaoxU="),
        ]
        for (time, nonce, secret, md5, hmac) in rows {
            #expect(ImouCloud.sign(.md5, time: time, nonce: nonce, appSecret: secret) == md5)
            #expect(ImouCloud.sign(.hmac, time: time, nonce: nonce, appSecret: secret) == hmac)
        }
    }

    @Test func theRequestBodiesAreTheAddendums() throws {
        let ptz = ImouCloud.body(appID: FakeImouCloud.appID, appSecret: FakeImouCloud.appSecret, params: [
            "deviceId": "TEST000CAM1", "channelId": "0", "operation": "2", "duration": 500,
        ], token: "At_test", time: 1_762_300_000, nonce: "nonce-ptz-0002", id: "ptz-1")
        #expect(ptz == (try JSONValue(string: """
            {"id":"ptz-1","system":{"ver":"1.0","appId":"lcaa11bb22cc33dd44","sign":"a+nlbu3RzTvpjkaZszXXHDT2Oa/PlfD3pVpNGPVMBuk=","time":1762300000,"nonce":"nonce-ptz-0002"},
             "params":{"token":"At_test","deviceId":"TEST000CAM1","channelId":"0","operation":"2","duration":500}}
            """)))
        let privacy = ImouCloud.body(appID: FakeImouCloud.appID, appSecret: FakeImouCloud.appSecret, signing: .md5, params: [
            "deviceId": "TEST000CAM1", "channelId": "0", "enableType": "closeCamera",
        ], token: "At_test", time: 1_762_300_060, nonce: "nonce-cam-0003", id: "cam-1")
        #expect(privacy == (try JSONValue(string: """
            {"id":"cam-1","system":{"ver":"1.0","appId":"lcaa11bb22cc33dd44","sign":"702096723e475730eab7927aac7470a4","time":1762300060,"nonce":"nonce-cam-0003"},
             "params":{"token":"At_test","deviceId":"TEST000CAM1","channelId":"0","enableType":"closeCamera"}}
            """)))
    }

    @Test func aCloudThatRefusesTheHMACIsSignedWithMD5FromThenOn() async throws {
        let fake = FakeImouCloud()
        fake.addCamera()
        fake.state.withLockedValue { $0.refusesHMAC = true }
        let cloud = cloud(fake)
        _ = try await cloud.online("TEST000CAM1")
        _ = try await cloud.online("TEST000CAM1")
        #expect(await cloud.signing == .md5)
        let signs = fake.calls.compactMap { $0.body["system"]?["sign"]?.stringValue }
        // The HMAC once (refused), then MD5 hex for the token and each call.
        #expect(signs.count == 4 && signs[0].hasSuffix("=") && signs.dropFirst().allSatisfy { $0.count == 32 && !$0.contains("=") })
        #expect(fake.calls("accessToken").count == 2)
        // An account that takes the documented form keeps it.
        let documented = FakeImouCloud()
        documented.addCamera()
        let other = self.cloud(documented)
        _ = try await other.online("TEST000CAM1")
        #expect(await other.signing == .hmac && documented.calls.count == 2)
    }

    // MARK: Cloud calls

    @Test func ptzSendsTheOperationAsAStringThenAsANumberIfRefused() async throws {
        let fake = FakeImouCloud()
        let cloud = cloud(fake)
        try await cloud.movePTZ("TEST000CAM1", channel: "0", .left, milliseconds: 500)
        let first = try #require(fake.calls("controlMovePTZ").last)
        #expect(first.params["operation"] == "2" && first.params["duration"] == 500 && first.params["channelId"] == "0")
        fake.state.withLockedValue { $0.ptzWantsNumbers = true }
        try await cloud.movePTZ("TEST000CAM1", channel: "0", .stop, milliseconds: 500)
        #expect(fake.calls("controlMovePTZ").count == 3 && fake.calls("controlMovePTZ").last?.params["operation"] == 10)
        // Remembered: one call from then on.
        try await cloud.movePTZ("TEST000CAM1", channel: "0", .zoomIn, milliseconds: 500)
        #expect(fake.calls("controlMovePTZ").count == 4 && fake.calls("controlMovePTZ").last?.params["operation"] == 8)
        try await cloud.locatePTZ("TEST000CAM1", channel: "0", h: 0.5, v: -0.25, z: 0)
        #expect(fake.calls("controlLocationPTZ").first?.params == ["token": "At_1", "deviceId": "TEST000CAM1", "channelId": "0", "h": 0.5, "v": -0.25, "z": 0])
    }

    @Test func aDeviceLevelSwitchGoesWithoutAChannelAndOnceWithZeroIfAsked() async throws {
        let fake = FakeImouCloud()
        let cloud = cloud(fake)
        try await cloud.setCameraStatus("TEST000CAM1", channel: nil, "breathingLight", false)
        #expect(fake.calls("setDeviceCameraStatus").last?.params == ["token": "At_1", "deviceId": "TEST000CAM1", "enableType": "breathingLight", "enable": false])
        fake.fail("setDeviceCameraStatus", with: "OP1003")
        try await cloud.setCameraStatus("TEST000CAM1", channel: nil, "breathingLight", true)
        #expect(fake.calls("setDeviceCameraStatus").count == 3 && fake.calls("setDeviceCameraStatus").last?.params["channelId"] == "0")
        try await cloud.setCameraStatus("TEST000CAM1", channel: "0", "linkageSiren", true)
        #expect(fake.calls("setDeviceCameraStatus").last?.params == ["token": "At_1", "deviceId": "TEST000CAM1", "channelId": "0", "enableType": "linkageSiren", "enable": true])
    }

    @Test func nightVisionStorageAndRestart() async throws {
        let fake = FakeImouCloud()
        let cloud = cloud(fake)
        let read = try await cloud.nightVision("TEST000CAM1", channel: "0")
        #expect(read.mode == "Intelligent" && read.modes == ["Intelligent", "FullColor", "Infrared", "Off"])
        try await cloud.setNightVision("TEST000CAM1", channel: "0", mode: "FullColor")
        #expect(fake.calls("setNightVisionMode").first?.params == ["token": "At_1", "deviceId": "TEST000CAM1", "channelId": "0", "mode": "FullColor"])
        #expect(try await cloud.storage("TEST000CAM1") == ImouStorage(status: "normal", usedPercent: 88))
        fake.state.withLockedValue { $0.sdStatus = "" }
        #expect(try await cloud.storage("TEST000CAM1") == ImouStorage(status: "none"))
        fake.state.withLockedValue { $0.sdStatus = "recovering" }
        #expect(try await cloud.storage("TEST000CAM1").status == "recovering")
        #expect(fake.calls("deviceStorage").count == 1 && fake.calls("deviceSdcardStatus").first?.params == ["token": "At_1", "deviceId": "TEST000CAM1"])
        try await cloud.restart("TEST000CAM1")
        #expect(fake.calls("restartDevice").first?.params == ["token": "At_1", "deviceId": "TEST000CAM1"])
    }

    @Test func aMethodSpentForTheDayIsNotCalledUntilTheNext() async throws {
        let fake = FakeImouCloud()
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_762_300_000))
        let cloud = cloud(fake) { clock.withLockedValue { $0 } }
        fake.fail("controlMovePTZ", with: "OP1014")
        await #expect(throws: ImouError.self) { try await cloud.movePTZ("TEST000CAM1", channel: "0", .up, milliseconds: 500) }
        await #expect(throws: ImouError.self) { try await cloud.movePTZ("TEST000CAM1", channel: "0", .up, milliseconds: 500) }
        #expect(fake.calls("controlMovePTZ").count == 1)
        clock.withLockedValue { $0 += 86_400 }
        try await cloud.movePTZ("TEST000CAM1", channel: "0", .up, milliseconds: 500)
        #expect(fake.calls("controlMovePTZ").count == 2)
    }

    // MARK: Switches

    @Test func theSwitchesFollowTheAbilitiesAndTheSettings() async throws {
        environment.cloud.addCamera(abilities: Self.allAbilities, channelAbilities: "AlarmMD,HeaderDetect,AiHuman")
        environment.cloud.addCamera("TEST000CAM2", name: "Drive", abilities: "WLAN,CloseCamera", channelAbilities: "")
        var settings = block(Self.allSwitches)
        settings["devices"] = [["deviceId": "TEST000CAM1"].merging(Self.allSwitches) { $1 }, ["deviceId": "TEST000CAM2"].merging(Self.allSwitches) { $1 }]
        let host = try await environment.start(settings)
        let accessory = try await garden(host)
        for subtype in ["personDetection", "statusLight", "alarmSiren", "alarmLight", "nightVision"] { #expect(service(accessory, subtype)?.type == .switch, "\(subtype)") }
        let drive = environment, driveID = "Imou:TEST000CAM2:0"
        #expect(await eventually { drive.accessory(host, driveID) != nil })
        let other = try #require(environment.accessory(host, driveID))
        #expect(other.services.filter { $0.type == .switch }.compactMap(\.subtype) == ["privacy"])
        await host.stop()
        // Off by default: the switches cost calls.
        let plain = TestEnvironment()
        plain.cloud.addCamera(abilities: Self.allAbilities, channelAbilities: "AlarmMD,HeaderDetect")
        let again = try await plain.start()
        let id = gardenID
        #expect(await eventually { plain.accessory(again, id) != nil })
        let services = try #require(plain.accessory(again, id)).services.filter { $0.type == .switch || $0.type == .lightbulb }
        #expect(Set(services.compactMap(\.subtype)) == ["privacy", "motionDetection", "siren", "spotlight"])
        await again.stop()
    }

    @Test func eachSwitchWritesTheAddendumsBody() async throws {
        environment.cloud.addCamera(abilities: Self.allAbilities, channelAbilities: "AlarmMD,HeaderDetect,AiHuman")
        let host = try await environment.start(block(Self.allSwitches))
        let accessory = try await garden(host)
        let cloud = environment.cloud
        try await service(accessory, "personDetection")?.characteristic(.on).write(true)
        let person = cloud.calls("setDeviceCameraStatus").filter { ["headerDetect", "aiHuman"].contains($0.params["enableType"]?.stringValue ?? "") }
        #expect(person.map(\.params) == [
            ["token": "At_1", "deviceId": "TEST000CAM1", "channelId": "0", "enableType": "headerDetect", "enable": true],
            ["token": "At_1", "deviceId": "TEST000CAM1", "channelId": "0", "enableType": "aiHuman", "enable": true],
        ])
        try await service(accessory, "statusLight")?.characteristic(.on).write(true)
        try await service(accessory, "statusLight")?.characteristic(.on).write(false)
        #expect(cloud.calls("setDeviceCameraStatus").last?.params == ["token": "At_1", "deviceId": "TEST000CAM1", "enableType": "breathingLight", "enable": false])
        try await service(accessory, "alarmSiren")?.characteristic(.on).write(true)
        #expect(cloud.calls("setDeviceCameraStatus").last?.params == ["token": "At_1", "deviceId": "TEST000CAM1", "channelId": "0", "enableType": "linkageSiren", "enable": true])
        try await service(accessory, "alarmLight")?.characteristic(.on).write(true)
        #expect(cloud.calls("setDeviceCameraStatus").last?.params["enableType"] == "linkageWhiteLight")
        let nightVision = try #require(service(accessory, "nightVision")).characteristic(.on)
        #expect(await eventually { nightVision.value == true })
        try await nightVision.write(false)
        #expect(cloud.calls("setNightVisionMode").last?.params == ["token": "At_1", "deviceId": "TEST000CAM1", "channelId": "0", "mode": "Off"])
        try await nightVision.write(true)
        #expect(cloud.calls("setNightVisionMode").last?.params["mode"] == "Intelligent")
        try await service(accessory, "motionDetection")?.characteristic(.on).write(true)
        #expect(cloud.calls("modifyDeviceAlarmStatus").last?.params == ["token": "At_1", "deviceId": "TEST000CAM1", "channelId": "0", "enable": true])
        await host.stop()
    }

    @Test func aSwitchIsOnWhenAnyReadsOnAndAFailedReadNeverTurnsItOff() async throws {
        environment.cloud.addCamera(abilities: Self.allAbilities, channelAbilities: "AlarmMD,HeaderDetect,AiHuman")
        environment.cloud.state.withLockedValue { $0.statuses["TEST000CAM1:0:aiHuman"] = true }
        let host = try await environment.start(block(["personDetectSwitch": true]))
        let person = try #require(service(try await garden(host), "personDetection")).characteristic(.on)
        #expect(await eventually { person.value == true })
        // aiHuman now fails on every read, headerDetect answers off: the switch stays on.
        let cloud = environment.cloud
        cloud.state.withLockedValue {
            $0.statuses["TEST000CAM1:0:aiHuman"] = nil
            $0.failing = ["aiHuman"]
        }
        let before = cloud.calls("deviceOnline").count
        #expect(await eventually { cloud.calls("deviceOnline").count > before + 3 })
        #expect(person.value == true)
        // Both answer off: off.
        cloud.state.withLockedValue { $0.failing = [] }
        #expect(await eventually { person.value == false })
        await host.stop()
    }

    @Test func aSwitchTheCameraLacksIsNoLongerReadAndGoesAtTheNextStart() async throws {
        environment.cloud.addCamera(abilities: Self.allAbilities)
        environment.cloud.state.withLockedValue { $0.unsupported = ["linkageSiren"] }
        let host = try await environment.start(block(["linkageSirenSwitch": true]))
        #expect(service(try await garden(host), "alarmSiren") != nil)
        let cloud = environment.cloud
        #expect(await eventually { cloud.calls("deviceOnline").count >= 4 })
        #expect(cloud.calls("getDeviceCameraStatus").filter { $0.params["enableType"] == "linkageSiren" }.count == 1)
        await host.stop()
        let again = try await environment.start(block(["linkageSirenSwitch": true]))
        let plugin = try #require(environment.plugin), id = gardenID
        // The camera the plugin publishes, not the one restored from the cache meanwhile.
        #expect(await eventually { await plugin.camera(id)?.accessory != nil })
        let accessory = try #require(await plugin.camera(id)?.accessory)
        #expect(service(accessory, "alarmSiren") == nil && service(accessory, "privacy") != nil)
        await again.stop()
    }

    @Test func theStatusLightFallsBackToItsLegacyRead() async throws {
        environment.cloud.addCamera(abilities: Self.allAbilities)
        environment.cloud.state.withLockedValue {
            $0.unsupported = ["breathingLight"]
            $0.statuses["TEST000CAM1:device:breathingLight"] = true
        }
        let host = try await environment.start(block(["statusLightSwitch": true]))
        let light = try #require(service(try await garden(host), "statusLight")).characteristic(.on)
        #expect(await eventually { light.value == true })
        #expect(environment.cloud.calls("breathingLightStatus").first?.params == ["token": "At_1", "deviceId": "TEST000CAM1"])
        await host.stop()
    }

    @Test func quickWritesToASwitchAreCoalesced() async throws {
        environment.cloud.addCamera(abilities: Self.allAbilities)
        let host = try await environment.start(block(["linkageSirenSwitch": true]))
        let on = try #require(service(try await garden(host), "alarmSiren")).characteristic(.on)
        environment.cloud.state.withLockedValue { $0.setStatusDelay = .milliseconds(500) }
        let first = Task { try await on.write(true) }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task { try await on.write(true) }
        try await Task.sleep(for: .milliseconds(50))
        let third = Task { try await on.write(true) }
        for task in [first, second, third] { try await task.value }
        // The second waited behind the first and was overtaken by the third: never sent.
        #expect(environment.cloud.calls("setDeviceCameraStatus").filter { $0.params["enableType"] == "linkageSiren" }.count < 3)
        await host.stop()
    }

    // MARK: Privacy and HomeKit Camera Active

    @Test func privacyAndHomeKitCameraActiveStayInStep() async throws {
        environment.cloud.addCamera(abilities: Self.allAbilities)
        environment.cloud.state.withLockedValue { $0.statuses["TEST000CAM1:0:closeCamera"] = true }
        let host = try await environment.start(block(["statusLightSwitch": true], local: true))
        let accessory = try await garden(host)
        let privacy = try #require(service(accessory, "privacy")).characteristic(.on)
        let operatingMode = try #require(accessory.services.first { $0.type == .cameraOperatingMode })
        let active = operatingMode.characteristic(.homeKitCameraActive)
        // A poll reads closeCamera on: closed, so not active.
        #expect(await eventually { privacy.value == true && active.value.intValue == 0 })
        let motion = try #require(accessory.services.first { $0.type == .motionSensor }).characteristic(.statusActive)
        #expect(motion.value == false)
        // HomeKit turns the camera on: the camera opens, and the switch follows.
        try await active.write(.int(1))
        let cloud = environment.cloud
        #expect(cloud.calls("setDeviceCameraStatus").last?.params == ["token": "At_1", "deviceId": "TEST000CAM1", "channelId": "0", "enableType": "closeCamera", "enable": false])
        #expect(privacy.value == false)
        // The switch closes it: Camera Active follows.
        try await privacy.write(true)
        #expect(active.value.intValue == 0)
        // The camera opens on its own (a privacy plan): the next poll says so to both.
        cloud.state.withLockedValue { $0.statuses["TEST000CAM1:0:closeCamera"] = false }
        #expect(await eventually { privacy.value == false && active.value.intValue == 1 })
        // A refused write changes neither.
        cloud.fail("setDeviceCameraStatus", with: "OP1009")
        await #expect(throws: HAPStatusError.self) { try await active.write(.int(0)) }
        #expect(privacy.value == false && active.value.intValue == 1)
        // With HomeKit Secure Video the status light is the operating mode's indicator, not a switch.
        #expect(service(accessory, "statusLight") == nil)
        let indicator = try #require(operatingMode[.cameraOperatingModeIndicator])
        try await indicator.write(true)
        #expect(cloud.calls("setDeviceCameraStatus").last?.params == ["token": "At_1", "deviceId": "TEST000CAM1", "enableType": "breathingLight", "enable": true])
        await host.stop()
    }

    // MARK: Quota

    @Test func everyPollReadsTheExposedSwitchesOnceAndNothingMore() async throws {
        environment.cloud.addCamera(abilities: Self.allAbilities, channelAbilities: "AlarmMD,HeaderDetect")
        let host = try await environment.start(block(Self.allSwitches))
        _ = try await garden(host)
        let cloud = environment.cloud
        #expect(await eventually { cloud.calls("deviceOnline").count >= 6 })
        #expect(await environment.plugin?.extrasEvery == 1)
        // Each poll: closeCamera, whiteLight, two motion reads, headerDetect, breathingLight, linkageSiren, linkageWhiteLight, and the night vision mode.
        let polls = cloud.calls("deviceOnline").count
        let reads = cloud.calls("getDeviceCameraStatus").count
        #expect(reads >= (polls - 1) * 8 && reads <= (polls + 1) * 8)
        let nightVision = cloud.calls("getNightVisionMode").count
        #expect(nightVision >= polls - 1 && nightVision <= polls + 1)
        // The SD card once an hour (3.6 s at this scale), not every poll.
        #expect(cloud.calls("deviceSdcardStatus").count <= 2 && cloud.calls("deviceStorage").count == cloud.calls("deviceSdcardStatus").count)
        await host.stop()
    }

    @Test func theGovernorSpreadsTheExtraSwitchesToStayUnderTheDailyBudget() async throws {
        environment.cloud.addCamera(abilities: Self.allAbilities.replacingOccurrences(of: ",LocalStorage", with: ""), channelAbilities: "AlarmMD,HeaderDetect,AiHuman")
        // Every 30 s, a day of the five first reads is 14,544 calls: 456 are left for the six extra ones' 17,280.
        let host = try await environment.start(block(Self.allSwitches, polling: 30))
        _ = try await garden(host)
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.extrasEvery == 38 })
        let cloud = environment.cloud
        #expect(await eventually(timeout: .seconds(30)) { cloud.calls("deviceOnline").count >= 40 })
        let polls = cloud.calls("deviceOnline").count
        let extras = cloud.calls("getNightVisionMode").count
        #expect(extras >= 1 && extras <= polls / 38 + 2)
        #expect(cloud.calls("getDeviceCameraStatus").filter { $0.params["enableType"] == "closeCamera" }.count >= polls - 1)
        await host.stop()
    }

    @Test func theSDCardIsOnTheCamerasList() async throws {
        environment.cloud.addCamera(abilities: Self.allAbilities)
        let host = try await environment.start()
        _ = try await garden(host)
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.storage["TEST000CAM1"] != nil })
        let list = try await request("GET", "cameras")
        let camera = try #require(list.json["cameras"]?[0])
        #expect(camera["sdCard"] == ["status": "normal", "usedPercent": 88])
        #expect(camera["ptz"] == "PTZ" && camera["restart"] == true && camera["accessoryId"] == .string(gardenID))
        await host.stop()
    }

    // MARK: Actions

    @Test func ptzMovesFollowTheAbilitiesAndStopBeforeTurning() async throws {
        environment.cloud.addCamera(abilities: Self.allAbilities)
        environment.cloud.addCamera("TEST000CAM2", name: "Drive", abilities: "WLAN,PT2", channelAbilities: "")
        let host = try await environment.start()
        _ = try await garden(host)
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.camera("Imou:TEST000CAM2:0") != nil })
        let cloud = environment.cloud
        #expect(try await request("POST", "ptz/move", ["accessoryId": .string(gardenID), "direction": "left", "duration": 10000]).status == 200)
        #expect(cloud.calls("controlMovePTZ").last?.params == ["token": "At_1", "deviceId": "TEST000CAM1", "channelId": "0", "operation": "2", "duration": 10000])
        // Another direction while the left move runs: a stop first.
        #expect(try await request("POST", "ptz/move", ["deviceId": "TEST000CAM1", "direction": "up", "duration": 500]).status == 200)
        #expect(cloud.calls("controlMovePTZ").suffix(2).map { $0.params["operation"] } == ["10", "0"])
        #expect(try await request("POST", "ptz/move", ["deviceId": "TEST000CAM1", "direction": "up", "duration": 50]).status == 409)
        // PT2: left and right only.
        #expect(try await request("POST", "ptz/move", ["deviceId": "TEST000CAM2", "direction": "zoomIn"]).status == 409)
        #expect(try await request("POST", "ptz/move", ["deviceId": "TEST000CAM2", "direction": "up"]).status == 409)
        #expect(try await request("POST", "ptz/move", ["deviceId": "TEST000CAM2", "direction": "right"]).status == 200)
        #expect(cloud.calls("controlMovePTZ").last?.params["duration"] == 1000)
        #expect(try await request("POST", "ptz/position", ["deviceId": "TEST000CAM1", "h": 0.5, "v": -0.25, "z": 0]).status == 200)
        #expect(try await request("POST", "ptz/position", ["deviceId": "TEST000CAM1", "h": 2, "v": 0]).status == 409)
        #expect(cloud.calls("controlLocationPTZ").count == 1)
        #expect(try await request("POST", "restart", ["deviceId": "TEST000CAM2"]).status == 409)
        #expect(try await request("POST", "restart", ["deviceId": "TEST000CAM1"]).status == 200)
        #expect(cloud.calls("restartDevice").map(\.params) == [["token": "At_1", "deviceId": "TEST000CAM1"]])
        #expect(try await request("POST", "ptz/move", ["deviceId": "NOPE", "direction": "up"]).status == 404)
        await host.stop()
    }

    @Test func theActionsDeclareTheirScope() {
        let actions = Dictionary(uniqueKeysWithValues: ImouPlugin.assistantActions.map { ($0.name, $0) })
        for name in ["move", "point", "list_presets", "go_to_preset", "set_night_vision", "restart"] { #expect(actions[name]?.access == .configure, "\(name)") }
        #expect(actions["restart"]?.confirm == true && actions["list_cameras"]?.access == .read)
    }

    @Test func presetsAreActionsAndOptionalSwitches() async throws {
        environment.cloud.addCamera(abilities: Self.allAbilities)
        environment.cloud.state.withLockedValue { $0.presets = ["Door", "Gate"] }
        let host = try await environment.start(block(["presetSwitches": true]))
        let accessory = try await garden(host)
        let presets = try await request("GET", "ptz/presets", query: ["accessoryId": gardenID])
        #expect(presets.json["presets"] == ["Door", "Gate"])
        #expect(try await request("POST", "ptz/preset", ["accessoryId": .string(gardenID), "name": "Gate"]).status == 200)
        let door = try #require(service(accessory, "preset:Door"))
        #expect(door.characteristic(.name).value == "Garden Go to Door")
        try await door.characteristic(.on).write(true)
        let cloud = environment.cloud
        #expect(cloud.calls("turnCollection").map { $0.params["name"] } == ["Gate", "Door"])
        #expect(await eventually { door.characteristic(.on).value == false })
        await host.stop()
    }
}
