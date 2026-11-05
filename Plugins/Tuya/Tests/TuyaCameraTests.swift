import Crypto
import Foundation
import HomeswiftAI
import HomeswiftFFmpeg
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftTuya

/// A camera's video (docs/clean-room/TuyaCamera.md) on a host, against the fake cloud; FFmpeg's frames are faked.
@Suite(.timeLimit(.minutes(1)))
struct TuyaCameraTests {
    static let cameraDeviceID = "bf5c4a3b2d1e0f9a8b7c"
    static let offlineDeviceID = "bf00000000000offline"
    static let virtualDeviceID = "vdevo1234567890abcdef"
    /// The camera specification's example answer (section 13.3).
    static let url = "rtsps://cam-proxy.example.invalid:443/v1/proxy/bf5c4a3b2d1e0f9a8b7c?token=ZXhhbXBsZQ"
    let bridgedID = TuyaPlugin.accessoryID(deviceID: cameraDeviceID)
    let cameraID = TuyaPlugin.cameraID(deviceID: cameraDeviceID)

    static func allocatePath(_ deviceID: String) -> String { "/v1.0/devices/\(deviceID)/stream/actions/allocate" }

    static let deviceList = #"""
    [{"id":"bf5c4a3b2d1e0f9a8b7c","uuid":"c0ffee0123456789","name":"Front Door","online":true,"category":"sp","product_id":"campro1",
      "owner_id":"12345678","status":[{"code":"doorbell_ring_exist","value":"1"},{"code":"doorbell_pic","value":""},
      {"code":"movement_detect_pic","value":""},{"code":"motion_switch","value":true}]},
     {"id":"bf00000000000offline","name":"Garage","online":false,"category":"sp","product_id":"campro1","owner_id":"12345678","status":[]},
     {"id":"vdevo1234567890abcdef","name":"Virtual Camera","online":true,"category":"sp","product_id":"campro1","owner_id":"12345678","status":[]}]
    """#

    static let specification = #"""
    {"category":"sp",
     "functions":[{"code":"motion_switch","type":"Boolean","values":"{}"}],
     "status":[{"code":"doorbell_ring_exist","type":"Enum","values":"{\"range\":[\"0\",\"1\"]}"},
      {"code":"doorbell_pic","type":"Raw","values":"{}"},{"code":"movement_detect_pic","type":"Raw","values":"{}"},
      {"code":"motion_switch","type":"Boolean","values":"{}"}]}
    """#

    static func environment(timeScale: Double = 0.5, collectLogs: Bool = false) -> TestEnvironment {
        let environment = TestEnvironment(timeScale: timeScale, collectLogs: collectLogs)
        let cloud = environment.cloud
        cloud.set("GET /v1.0/homes/12345678/devices", try! JSONValue(string: deviceList))
        for id in [cameraDeviceID, offlineDeviceID, virtualDeviceID] {
            cloud.set("GET /v1.0/devices/\(id)/specifications", try! JSONValue(string: specification))
            cloud.set("POST \(allocatePath(id))", ["url": .string(url)])
        }
        return environment
    }

    func started(_ environment: TestEnvironment, settings: [String: Any] = TestEnvironment.smartHome) async throws -> (PluginHost, TuyaCamera) {
        let host = try await environment.start(settings: settings)
        let id = Self.cameraDeviceID, cameraID = cameraID
        #expect(await eventually { await environment.plugin?.cameras[id] != nil && host.externalAccessory(cameraID) != nil })
        let camera = try #require(await environment.plugin?.cameras[id])
        return (host, camera)
    }

    func allocations(_ environment: TestEnvironment, _ deviceID: String = cameraDeviceID) -> [FakeTuyaCloud.Sent] {
        environment.cloud.sent("POST", Self.allocatePath(deviceID))
    }

    @Test func aCameraIsPublishedOnItsOwnAndItsEventsStayInTheBridge() async throws {
        let environment = Self.environment()
        let (host, _) = try await started(environment)
        // The bridged accessory keeps its doorbell and motion sensor, under its id.
        let bridged = try #require(host.accessory(bridgedID))
        #expect(bridged.service(.doorbell) != nil && bridged.service(.motionSensor) != nil)
        #expect(!bridged.services.contains { $0.type.uuid == ServiceType.cameraRTPStreamManagement.uuid })
        let camera = try #require(host.externalAccessory(cameraID))
        #expect(camera.category == .videoDoorbell)
        #expect(camera.services.contains { $0.type.uuid == ServiceType.cameraRTPStreamManagement.uuid })
        #expect(!camera.services.contains { $0.type.uuid == ServiceType.cameraRecordingManagement.uuid })
        #expect(camera.information.characteristic(.manufacturer).value == "Tuya Inc.")
        // The offline camera has its video accessory too; the virtual one has none.
        #expect(await eventually { host.externalAccessory(TuyaPlugin.cameraID(deviceID: Self.offlineDeviceID)) != nil })
        #expect(await eventually { host.accessory(TuyaPlugin.accessoryID(deviceID: Self.virtualDeviceID)) != nil })
        #expect(host.externalAccessory(TuyaPlugin.cameraID(deviceID: Self.virtualDeviceID)) == nil)
        #expect(await environment.plugin?.cameras[Self.virtualDeviceID] == nil)
        // Publishing allocates nothing.
        #expect(environment.cloud.sent.filter { $0.path.hasSuffix("/stream/actions/allocate") }.isEmpty)
        await host.stop()
    }

    @Test func theCamerasSensorAndDoorbellFollowTheBridgedOnes() async throws {
        let environment = Self.environment()
        let (host, _) = try await started(environment)
        let bridged = try #require(host.accessory(bridgedID))
        let camera = try #require(host.externalAccessory(cameraID))
        let bridgedMotion = try #require(bridged.service(.motionSensor)?[.motionDetected])
        let motion = try #require(camera.service(.motionSensor)?[.motionDetected])
        bridgedMotion.value = .bool(true)
        #expect(motion.value == .bool(true))
        bridgedMotion.value = .bool(false)
        #expect(motion.value == .bool(false))
        let rings = NIOLockedValueBox(0)
        let press = try #require(camera.service(.doorbell)?[.programmableSwitchEvent])
        press.observe { change in if change.reason == .event { rings.withLockedValue { $0 += 1 } } }
        try #require(bridged.service(.doorbell)?[.programmableSwitchEvent]).sendEvent(.int(0))
        #expect(rings.withLockedValue { $0 } == 1)
        await host.stop()
    }

    @Test func eachStreamAllocatesOnceWithTheSignedRequest() async throws {
        let environment = Self.environment()
        let (host, camera) = try await started(environment)
        let source = try await camera.source()
        #expect(source.url == Self.url)
        let sent = try #require(allocations(environment).first)
        #expect(sent.body == #"{"type":"rtsp"}"#)
        #expect(sent.headers["access_token"] == "c8b1f0e2d3a4b5c6d7e8f9a0b1c2d3e4" && sent.headers["sign_method"] == "HMAC-SHA256")
        #expect(allocations(environment).count == 1)
        _ = try await camera.source()
        #expect(allocations(environment).count == 2)
        // FFmpeg reads it over TCP, with a socket timeout.
        let input = RTSPCameraArguments.input(url: source.url, options: TuyaCamera.options, timeoutFlag: "-timeout")
        #expect(input == ["-rtsp_transport", "tcp", "-timeout", "10000000", "-analyzeduration", "5000000", "-probesize", "5000000", "-i", Self.url])
        await host.stop()
    }

    @Test func snapshotsAreCoalesced() async throws {
        let environment = Self.environment()
        let (host, camera) = try await started(environment)
        async let first = camera.snapshotImage()
        async let second = camera.snapshotImage()
        let images = try await [first, second]
        #expect(images == [testJPEG, testJPEG])
        #expect(try await camera.snapshotImage() == testJPEG)
        #expect(allocations(environment).count == 1)
        #expect(environment.frames.withLockedValue { $0 } == [Self.url])
        await host.stop()
    }

    @Test func aFailedAllocationIsAnsweredAndARefusedSubscriptionBacksOff() async throws {
        let environment = Self.environment(collectLogs: true)
        let (host, camera) = try await started(environment)
        let route = "POST \(Self.allocatePath(Self.cameraDeviceID))"
        // Success without a URL: no stream.
        environment.cloud.set(route, .object([:]))
        await #expect(throws: TuyaAPIError.self) { _ = try await camera.source() }
        #expect(allocations(environment).count == 1)
        environment.cloud.refuse(route, code: 28841101, message: "No permissions. This API is not subscribed.")
        await #expect(throws: TuyaAPIError.self) { _ = try await camera.source() }
        #expect(allocations(environment).count == 2)
        #expect(environment.log.text.contains("IoT Video Live Stream"))
        // Neither streams nor snapshots ask again for a while.
        await #expect(throws: (any Error).self) { _ = try await camera.source() }
        await #expect(throws: (any Error).self) { _ = try await camera.snapshotImage() }
        #expect(allocations(environment).count == 2)
        await host.stop()
    }

    @Test func anOfflineCameraIsRefusedWithoutACall() async throws {
        let environment = Self.environment()
        let host = try await environment.start()
        let id = Self.offlineDeviceID
        #expect(await eventually { await environment.plugin?.cameras[id] != nil })
        let camera = try #require(await environment.plugin?.cameras[id])
        await #expect(throws: (any Error).self) { _ = try await camera.source() }
        await #expect(throws: (any Error).self) { _ = try await camera.snapshotImage() }
        #expect(allocations(environment, id).isEmpty)
        #expect(environment.frames.withLockedValue { $0 }.isEmpty)
        await host.stop()
    }

    @Test func theURLIsNeverLogged() async throws {
        let environment = Self.environment(collectLogs: true)
        var settings = TestEnvironment.smartHome
        var options = settings["options"] as! [String: Any]
        options["debug"] = true
        settings["options"] = options
        let (host, camera) = try await started(environment, settings: settings)
        _ = try await camera.source()
        _ = try await camera.snapshotImage()
        await host.stop()
        #expect(!environment.log.text.isEmpty)
        for secret in ["ZXhhbXBsZQ", "/v1/proxy/"] { #expect(!environment.log.text.contains(secret)) }
        // FFmpeg's command lines, as its process logs them.
        let input = RTSPCameraArguments.input(url: Self.url, options: TuyaCamera.options)
        for arguments in [RTSPCameraArguments.frame(input: input), input] {
            let logged = redactCommandLine(arguments)
            #expect(logged.contains("rtsps://cam-proxy.example.invalid:443/<redacted>?token=***"))
            for secret in ["ZXhhbXBsZQ", "/v1/proxy/", Self.cameraDeviceID] { #expect(!logged.contains(secret)) }
        }
    }

    @Test func videoCanBeTurnedOffAndRecordingOn() async throws {
        let environment = Self.environment()
        var settings = TestEnvironment.smartHome
        var options = settings["options"] as! [String: Any]
        options["deviceOverrides"] = [["id": Self.cameraDeviceID, "recording": true], ["id": Self.offlineDeviceID, "video": false]]
        settings["options"] = options
        let (host, _) = try await started(environment, settings: settings)
        let camera = try #require(host.externalAccessory(cameraID))
        #expect(camera.services.contains { $0.type.uuid == ServiceType.cameraRecordingManagement.uuid })
        #expect(await eventually { host.accessory(TuyaPlugin.accessoryID(deviceID: Self.offlineDeviceID)) != nil })
        #expect(host.externalAccessory(TuyaPlugin.cameraID(deviceID: Self.offlineDeviceID)) == nil)
        #expect(TuyaPlugin.canonical(.object(["options": .object(["deviceOverrides": [["id": .string(Self.cameraDeviceID), "video": false]]])]),
                                     vaultHasKey: false, vaultHasPassword: false, devices: [Self.cameraDeviceID: Self.cameraDeviceID])["_accessories"] != nil)
        await host.stop()
    }

    @Test func aCameraRemovedFromTheAccountTakesItsVideoAccessory() async throws {
        let environment = Self.environment()
        let (host, camera) = try await started(environment)
        _ = camera
        await environment.plugin?.handle(.lifecycle(code: "delete", deviceID: Self.cameraDeviceID, data: ["ownerId": "12345678"]))
        #expect(host.externalAccessory(cameraID) == nil && host.accessory(bridgedID) == nil)
        #expect(await environment.plugin?.cameras[Self.cameraDeviceID] == nil)
        await host.stop()
    }
}

/// The camera specification's vectors (section 13).
@Suite struct TuyaCameraProtocolTests {
    @Test func signsTheAllocation() async throws {
        let cloud = FakeTuyaCloud()
        cloud.set("POST /v1.0/devices/bf5c4a3b2d1e0f9a8b7c/stream/actions/allocate", ["url": .string(TuyaCameraTests.url)])
        let api = TuyaOpenAPI(accessID: "4h3dxjpwamt9gcrkqv8e", accessKey: "a1b2c3d4e5f60718293a4b5c6d7e8f90", host: "openapi.tuyaeu.com", transport: cloud,
                              logger: testLogger, now: { Date(timeIntervalSince1970: 1_700_000_000) }, nonce: { "6f1e2d3c-4b5a-4978-8a6b-5c4d3e2f1a0b" })
        try await api.loginSmartHome(countryCode: 33, username: "user@example.com", password: "e4dac8847254e28266642c1bfe2ea3d2", appSchema: "smartlife")
        #expect(try await api.streamURL("bf5c4a3b2d1e0f9a8b7c") == TuyaCameraTests.url)
        let sent = try #require(cloud.sent("POST", "/v1.0/devices/bf5c4a3b2d1e0f9a8b7c/stream/actions/allocate").first)
        #expect(sent.body == #"{"type":"rtsp"}"#)
        #expect(TuyaSignature.hex(SHA256.hash(data: Data(#"{"type":"rtsp"}"#.utf8))) == "4ca274a8eb0cfb8fd14c59b1c83570a1e93743355dfc174371290903cee74e0e")
        #expect(sent.headers["t"] == "1700000000000" && sent.headers["nonce"] == "6f1e2d3c-4b5a-4978-8a6b-5c4d3e2f1a0b")
        #expect(sent.headers["sign"] == "E81986164D7512568222E0D92D6493101137A539E0184B25DE188AFC30421D05")
        #expect(sent.query == nil)
    }

    @Test func choosesFFmpegsTimeoutOption() {
        #expect(RTSPCameraArguments.timeoutFlag(version: "7.1") == "-timeout")
        #expect(RTSPCameraArguments.timeoutFlag(version: "n4.4.2") == "-stimeout")
        #expect(RTSPCameraArguments.timeoutFlag(version: "4.3.1-0+deb11u1") == "-stimeout")
        #expect(RTSPCameraArguments.timeoutFlag(version: "unknown") == "-timeout")
        #expect(RTSPCameraArguments.input(url: "http://cam/x", options: TuyaCamera.options).first == "-analyzeduration")
    }

    @Test func theCameraKindsAreApart() {
        let camera = TuyaDevice(id: "c", name: "C", online: true, category: "sp", status: [:], schema: [:])
        #expect(TuyaPlugin.kind(of: camera) == "camera")
        #expect(TuyaPlugin.kind(of: TuyaDevice(id: "d", name: "D", online: true, category: "wxml", status: [:], schema: [:])) == "doorbell")
        #expect(TuyaPlugin.hasVideo(camera))
        #expect(!TuyaPlugin.hasVideo(TuyaDevice(id: "vdevo1", name: "V", online: true, category: "sp", status: [:], schema: [:])))
    }
}
