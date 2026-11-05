import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import Testing

@testable import HomeswiftTapo

@Suite(.timeLimit(.minutes(1)))
struct TapoCloudTests {
    let cloud = FakeTapoCloud()

    func client(username: String = "user@example.com", password: String = "password123", kept: TapoCloud.Session? = nil) -> TapoCloud {
        TapoCloud(http: cloud, entry: URL(string: "https://n-wap-gw.example")!, credentials: { TapoCredentials(username: username, password: password) },
                  load: { kept }, save: { _ in }, logger: testLogger)
    }

    @Test func signsTheCallsAndListsTheCameras() async throws {
        let client = client()
        try await client.signIn()
        let cameras = try await client.cameras()
        #expect(cameras == [TapoCloud.Device(deviceID: "CLOUDID0001", alias: "Garden", model: "C675D", mac: "105A952FAD17")])
        #expect(cloud.state.withLockedValue { $0.badSignatures } == 0)
        #expect(cloud.paths.first == "/api/v2/account/getAccountStatusAndUrl")
    }

    @Test func aNewTerminalGivesTheEmailedCode() async throws {
        cloud.state.withLockedValue { $0.requiresCode = true }
        let client = client()
        await #expect(throws: TapoCloudError.self) { try await client.signIn() }
        try await client.requestCode()
        #expect(cloud.state.withLockedValue { $0.codesSent } == 1)
        try await client.finish(code: "123456", processID: "process-1")
        #expect(await client.isSignedIn)
        // The terminal is trusted now: the same one signs in without a code.
        let again = self.client(kept: await client.currentSession)
        try await again.signIn()
        #expect(await again.isSignedIn)
    }

    @Test func anExpiredTokenIsRefreshedOnce() async throws {
        let client = client()
        try await client.signIn()
        cloud.state.withLockedValue { $0.expireNext = 1 }
        _ = try await client.notifications(since: 0)
        #expect(cloud.paths.contains("/api/v2/account/refreshToken"))
        #expect(cloud.logins == 1)
    }

    @Test func aWrongPasswordIsARefusal() async throws {
        await #expect {
            try await client(password: "wrong").signIn()
        } throws: { error in
            (error as? TapoCloudError)?.isRefusedSignIn == true
        }
    }

    @Test func notificationsReadEitherTimeUnit() {
        let seconds = TapoCloud.notification(["msgId": 7, "msgType": "Motion", "deviceId": "D", "time": 1_762_340_000])
        let millis = TapoCloud.notification(["msgId": "8", "msgType": "PersonDetected", "deviceId": "D", "time": 1_762_340_000_000])
        #expect(seconds == TapoCloud.Notification(id: "7", type: "Motion", deviceID: "D", time: 1_762_340_000))
        #expect(millis?.time == 1_762_340_000)
        #expect(TapoCloud.notification(["msgType": "Motion"]) == nil)
        #expect(TapoCloud.alias("R2FyZGVu") == "Garden")
        #expect(TapoCloud.alias("Not base64!") == "Not base64!")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct TapoMotionTests {
    let environment = TestEnvironment()
    let wideID = "TapoP100:192.168.1.40Garden"
    let teleID = "TapoP100:192.168.1.40Garden:tele"

    func cameraAccessory(_ host: PluginHost, _ id: String) async throws -> Accessory {
        #expect(await eventually { host.bridges.flatMap(\.server.accessories).contains { $0.id == id } })
        return try #require(host.bridges.flatMap(\.server.accessories).first { $0.id == id })
    }

    func motion(_ accessory: Accessory) -> Bool? {
        accessory.services.first { $0.type.uuid == ServiceType.motionSensor.uuid }?[.motionDetected]?.value.boolValue
    }

    @Test func aDetectionInTheCloudReachesBothLensesWithoutTheCamera() async throws {
        let cloud = FakeTapoCloud()
        let camera = FakeStreamdCamera()
        let host = try await environment.start(devices: [["name": "Garden", "host": "192.168.1.40", "type": "DualLensCamera"]], connect: camera.connect, cloud: cloud)
        let wide = try await cameraAccessory(host, wideID)
        let tele = try await cameraAccessory(host, teleID)
        #expect(motion(wide) == false)
        // Polling has begun: an old message is not news, a new one is.
        #expect(await eventually { cloud.paths.contains("/api/v2/common/getAppNotificationByPage") })
        cloud.notify(time: Date().addingTimeInterval(-600))
        try await Task.sleep(for: .milliseconds(100))
        #expect(motion(wide) == false)
        cloud.notify()
        #expect(await eventually { motion(wide) == true && motion(tele) == true })
        // And it clears after the hold.
        #expect(await eventually { motion(wide) == false })
        #expect(camera.connections == 0)
        await host.stop()
    }

    @Test func otherCamerasAndOtherTypesAreIgnored() async throws {
        let cloud = FakeTapoCloud()
        let host = try await environment.start(devices: [["name": "Garden", "host": "192.168.1.40", "type": "DualLensCamera"]], cloud: cloud)
        let wide = try await cameraAccessory(host, wideID)
        #expect(await eventually { cloud.paths.contains("/api/v2/common/getAppNotificationByPage") })
        cloud.notify(deviceID: "ANOTHER")
        cloud.notify(type: "CameraLowBattery")
        try await Task.sleep(for: .milliseconds(150))
        #expect(motion(wide) == false)
        await host.stop()
    }

    @Test func theCameraIsFoundByItsMACWhenTheNamesDiffer() async throws {
        let cloud = FakeTapoCloud()
        cloud.state.withLockedValue { state in
            state.cameras = [
                ["deviceId": "OTHER", "alias": Data("Porch".utf8).base64EncodedString(), "deviceModel": "C675D", "deviceMac": "AA:BB:CC:DD:EE:FF"],
                ["deviceId": "CLOUDID0001", "alias": Data("Back".utf8).base64EncodedString(), "deviceModel": "C675D", "deviceMac": "10:5A:95:2F:AD:17"],
            ]
        }
        let host = try await environment.start(devices: [["name": "Garden", "host": "192.168.1.40", "type": "DualLensCamera"]], cloud: cloud,
                                               macAddress: "10:5a:95:2f:ad:17")
        let wide = try await cameraAccessory(host, wideID)
        #expect(await eventually { cloud.paths.contains("/api/v2/common/getAppNotificationByPage") })
        cloud.notify(deviceID: "OTHER")
        try await Task.sleep(for: .milliseconds(100))
        #expect(motion(wide) == false)
        cloud.notify(deviceID: "CLOUDID0001")
        #expect(await eventually { motion(wide) == true })
        await host.stop()
    }

    @Test func aRefusedSignInStopsTheWatch() async throws {
        let cloud = FakeTapoCloud()
        cloud.state.withLockedValue { $0.password = "changed" }
        let host = try await environment.start(devices: [["name": "Garden", "host": "192.168.1.40", "type": "Camera"]], cloud: cloud)
        _ = try await cameraAccessory(host, wideID)
        #expect(await eventually { cloud.logins == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(cloud.logins == 1)
        await host.stop()
    }

    @Test func noMotionMeansNoSensorAndNoCloud() async throws {
        let cloud = FakeTapoCloud()
        let host = try await environment.start(devices: [["name": "Garden", "host": "192.168.1.40", "type": "Camera", "motion": false]], cloud: cloud)
        let wide = try await cameraAccessory(host, wideID)
        #expect(motion(wide) == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(cloud.paths.isEmpty)
        await host.stop()
    }

    @Test func setupAsksForTheEmailedCode() async throws {
        let cloud = FakeTapoCloud()
        cloud.state.withLockedValue { $0.requiresCode = true }
        let host = try await environment.start(devices: [["name": "Garden", "host": "192.168.1.40", "type": "Camera"]], settings: [:], cloud: cloud)
        let plugin = try #require(environment.plugin)
        let answers = ["username": "user@example.com", "password": "password123"]
        guard case .ask(let prompt, let state) = try await plugin.authorize(SetupRequest(target: .account, answers: answers)) else {
            Issue.record("No code asked")
            return
        }
        #expect(prompt.fields.map(\.key) == ["code"])
        #expect(cloud.state.withLockedValue { $0.codesSent } == 1)
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "000000"], state: state))
        }
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "123456"], state: state)) else {
            Issue.record("Not signed in")
            return
        }
        #expect(outcome.credentials?["username"]?.stringValue == "user@example.com")
        #expect(cloud.state.withLockedValue { $0.trustedTerminals.count } == 1)
        await host.stop()
    }
}
