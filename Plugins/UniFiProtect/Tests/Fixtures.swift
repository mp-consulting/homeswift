import Foundation
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

@testable import Homeswift
@testable import HomeswiftUniFiProtect

/// A controller's bootstrap with one of each device, shaped like the controller's (protect-types.ts).
enum Fixtures {
    static let nvrMAC = "001122334455"
    static let cameraMAC = "F4E2C6000001"
    static let doorbellMAC = "F4E2C6000002"
    static let lightMAC = "F4E2C6000003"
    static let sensorMAC = "F4E2C6000004"
    static let viewerMAC = "F4E2C6000005"
    static let chimeMAC = "F4E2C6000006"

    static func channels(rtsp: Bool = true, package: Bool = false) -> JSONValue {
        var channels: [JSONValue] = [
            ["id": 0, "name": "High", "width": 2688, "height": 1512, "fps": 30, "bitrate": 8_000_000, "isRtspEnabled": .bool(rtsp), "rtspAlias": "highAlias"],
            ["id": 1, "name": "Medium", "width": 1280, "height": 720, "fps": 30, "bitrate": 2_000_000, "isRtspEnabled": .bool(rtsp), "rtspAlias": "mediumAlias"],
            ["id": 2, "name": "Low", "width": 640, "height": 360, "fps": 30, "bitrate": 500_000, "isRtspEnabled": .bool(rtsp), "rtspAlias": "lowAlias"],
        ]
        if package {
            channels.append(["id": 3, "name": "Package Camera", "width": 1600, "height": 1200, "fps": 2, "bitrate": 500_000, "isRtspEnabled": .bool(rtsp), "rtspAlias": "packageAlias"])
        }
        return .array(channels)
    }

    static func camera(id: String = "camera-id", mac: String = cameraMAC, name: String = "Driveway", flags: [String: JSONValue] = [:]) -> JSONValue {
        var featureFlags: [String: JSONValue] = [
            "hasLedStatus": true, "hasInfrared": true, "hasIcrSensitivity": true, "hasMic": true, "hasSpeaker": false, "hasSmartDetect": true,
            "hasLuxCheck": false, "hasTamperDetection": false, "hasPackageCamera": false, "isDoorbell": false, "hasChime": false, "hasLcdScreen": false,
            "hasFingerprintSensor": false, "smartDetectTypes": ["person", "vehicle", "licensePlate"], "smartDetectAudioTypes": ["alrmSmoke"],
        ]
        for (key, value) in flags { featureFlags[key] = value }
        return [
            "id": .string(id), "mac": .string(mac), "name": .string(name), "marketName": "G4 Bullet", "type": "UVC G4 Bullet", "modelKey": "camera",
            "host": "192.168.1.50", "connectionHost": "192.168.1.1", "firmwareVersion": "4.69.55", "hardwareRevision": "11", "isConnected": true, "isAdopted": true,
            "isAdoptedByOther": false, "isAdopting": false, "isThirdPartyCamera": false, "isAdoptedByAccessApp": false, "state": "CONNECTED", "videoCodec": "h264",
            "featureFlags": .object(featureFlags), "channels": channels(), "ledSettings": ["isEnabled": true], "ispSettings": ["irLedMode": "auto", "icrCustomValue": 5],
            "recordingSettings": ["mode": "always", "prePaddingSecs": 2], "smartDetectSettings": ["enableTamperDetection": false], "lastMotion": .null, "lastRing": .null,
        ]
    }

    static func doorbell() -> JSONValue {
        var doorbell = camera(id: "doorbell-id", mac: doorbellMAC, name: "Front Door", flags: [
            "isDoorbell": true, "hasChime": true, "hasLcdScreen": true, "hasSpeaker": true, "hasPackageCamera": true, "hasFingerprintSensor": true,
            "smartDetectTypes": [], "smartDetectAudioTypes": [],
        ])
        doorbell = doorbell.setting("marketName", "G4 Doorbell Pro").setting("type", "UVC G4 Doorbell Pro").setting("chimeDuration", 300)
            .setting("lcdMessage", .null).setting("channels", channels(package: true)).setting("enableNfc", true).setting("isDark", true)
        return doorbell
    }

    static func light() -> JSONValue {
        [
            "id": "light-id", "mac": .string(lightMAC), "name": "Porch Light", "marketName": "UP FloodLight", "type": "UP FloodLight", "modelKey": "light",
            "host": "192.168.1.51", "firmwareVersion": "1.9.3", "isConnected": true, "isAdopted": true, "isLightOn": false, "isPirMotionDetected": false,
            "lightDeviceSettings": ["ledLevel": 3, "isIndicatorEnabled": true], "lightOnSettings": ["isLedForceOn": false], "lastMotion": .null,
        ]
    }

    static func sensor() -> JSONValue {
        [
            "id": "sensor-id", "mac": .string(sensorMAC), "name": "Front Door", "marketName": "UP Sense", "type": "UFP-SENSE", "modelKey": "sensor",
            "firmwareVersion": "1.0.0", "isConnected": true, "isAdopted": true, "alarmSettings": ["isEnabled": true], "alarmTriggeredAt": .null,
            "batteryStatus": ["isLow": false, "percentage": 90], "externalLeakDetectedAt": .null, "humiditySettings": ["isEnabled": true], "isOpened": false,
            "leakDetectedAt": 1, "leakSettings": ["isExternalEnabled": true, "isInternalEnabled": true], "ledSettings": ["isEnabled": true],
            "lightSettings": ["isEnabled": true], "motionSettings": ["isEnabled": true], "mountType": "door", "tamperingDetectedAt": .null,
            "stats": ["humidity": ["value": 45], "light": ["value": 0], "temperature": ["value": 21.5]], "temperatureSettings": ["isEnabled": true],
            "isMotionDetected": false,
        ]
    }

    static func viewer() -> JSONValue {
        [
            "id": "viewer-id", "mac": .string(viewerMAC), "name": "Kitchen Viewport", "marketName": "UP Viewport", "type": "UFP-VIEWPORT", "modelKey": "viewer",
            "firmwareVersion": "1.2.3", "isConnected": true, "isAdopted": true, "liveview": "liveview-garage",
        ]
    }

    static func chime() -> JSONValue {
        [
            "id": "chime-id", "mac": .string(chimeMAC), "name": "Hall Chime", "marketName": "UP Chime", "type": "UP Chime", "modelKey": "chime",
            "firmwareVersion": "1.5.4", "isConnected": true, "isAdopted": true, "nvrMac": .string(nvrMAC), "cameraIds": ["doorbell-id"],
            "ringSettings": [["cameraId": "doorbell-id", "ringtoneId": "tone-1", "volume": 80, "repeatTimes": 1]],
        ]
    }

    static func bootstrap(cameras: [JSONValue]? = nil, options: (inout [String: JSONValue]) -> Void = { _ in }) -> JSONValue {
        var object: [String: JSONValue] = [
            "authUserId": "user-1",
            "lastUpdateId": "update-1",
            "users": [["id": "user-1", "allPermissions": ["camera:create,read,write,delete:*", "nvr:read:*"]]],
            "nvr": [
                "id": "nvr-id", "mac": .string(nvrMAC), "name": "Home NVR", "marketName": "UNVR", "type": "UNVR", "modelKey": "nvr", "host": "192.168.1.1",
                "version": "6.1.79", "firmwareVersion": "4.2.12", "hardwareRevision": "3", "ports": ["rtsp": 7447, "rtsps": 7441],
                "systemInfo": ["cpu": ["temperature": 48.5]],
                "doorbellSettings": ["defaultMessageResetTimeoutMs": 60000, "customMessages": ["Back soon"],
                                     "allMessages": [["type": "LEAVE_PACKAGE_AT_DOOR", "text": "LEAVE PACKAGE AT DOOR"], ["type": "CUSTOM_MESSAGE", "text": "Back soon"]]],
            ],
            "cameras": .array(cameras ?? [camera(), doorbell()]),
            "chimes": [chime()],
            "lights": [light()],
            "sensors": [sensor()],
            "viewers": [viewer()],
            "liveviews": [
                ["id": "liveview-away", "name": "Protect-Away", "slots": [["cameras": ["camera-id", "doorbell-id"]]]],
                ["id": "liveview-home", "name": "Protect-Home", "slots": [["cameras": ["doorbell-id"]]]],
                ["id": "liveview-garage", "name": "Protect-Garage", "slots": [["cameras": ["camera-id"]]]],
            ],
            "ringtones": [["id": "tone-1", "name": "Traditional", "nvrMac": .string(nvrMAC)]],
        ]
        options(&object)
        return .object(object)
    }
}

/// A host with one `UniFi Protect` block whose plugin talks to a fake controller.
final class ProtectTestEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-protect-tests-\(UUID().uuidString)")
    let controller: FakeController
    let webSockets = FakeWebSocketConnector()
    let mqtt = FakeMQTTConnection()
    let logs = LogCapture()
    private let plugins = NIOLockedValueBox<[UniFiProtectPlugin]>([])
    /// Shortens the plugin's timers: 0.01 makes a ten-second motion event last 100 ms.
    let timeScale: Double

    /// FFmpeg, when a test wants video.
    let ffmpeg: (any ProtectFfmpegKit)?
    /// The clock of snapshot budgets.
    let snapshotClock: any ProtectClock
    /// The consoles discovery finds.
    let discovered: [UbiquitiDiscovery.Console]

    init(controller: FakeController = FakeController(), timeScale: Double = 0.01, ffmpeg: (any ProtectFfmpegKit)? = nil,
         snapshotClock: any ProtectClock = SystemProtectClock(), discovered: [UbiquitiDiscovery.Console] = []) {
        self.controller = controller
        self.timeScale = timeScale
        self.ffmpeg = ffmpeg
        self.snapshotClock = snapshotClock
        self.discovered = discovered
    }

    var plugin: UniFiProtectPlugin? { plugins.withLockedValue { $0.last } }

    static func block(options: [String] = [], extra: [String: Any] = [:]) -> [String: Any] {
        var controller: [String: Any] = ["address": "192.168.1.1", "username": "homeswift", "password": "secret", "mqttUrl": "mqtt://broker.local"]
        for (key, value) in extra { controller[key] = value }
        return ["name": "UniFi Protect", "controllers": [controller], "options": options]
    }

    func host(settings: [String: Any]) throws -> PluginHost {
        var registry = PluginRegistry()
        let ffmpegFactory: (@Sendable (String?, Bool, Logger) -> any ProtectFfmpegKit)?
        if let ffmpeg { ffmpegFactory = { _, _, _ in ffmpeg } } else { ffmpegFactory = nil }
        let mqtt = self.mqtt
        let discovered = self.discovered
        registry.register(platform: UniFiProtectPlugin.platform, name: UniFiProtectPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(UniFiProtectPlugin.Configuration.self, from: json)
            var dependencies = ProtectDependencies(transport: self.controller, webSockets: self.webSockets.factory, mqtt: { _ in mqtt }, timeScale: self.timeScale,
                                                   discover: { _ in discovered }, resolve: { _ in ["192.168.1.1"] }, ffmpeg: ffmpegFactory, allowPlaylistServer: false, logger: self.logs.logger)
            dependencies.snapshotClock = self.snapshotClock
            let plugin = UniFiProtectPlugin(configuration: configuration, context: context, dependencies: dependencies)
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: UniFiProtectPlugin.platform, name: "UniFi Protect", settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        var logger = logs.logger
        logger.logLevel = .trace
        let options = PluginHost.Options(advertise: false, logger: logger) { _ in MemoryStorage() }
        return try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
    }

    /// Starts a host and waits for the controller's devices to be in HomeKit.
    func start(options: [String] = [], extra: [String: Any] = [:], waitFor id: String = ProtectPlatform.accessoryID(Fixtures.sensorMAC)) async throws -> PluginHost {
        let host = try host(settings: Self.block(options: options, extra: extra))
        try await host.start()
        _ = await eventually { self.accessory(host, id) != nil }
        return host
    }

    func accessory(_ host: PluginHost, _ id: String) -> Accessory? {
        host.bridges.flatMap(\.server.accessories).first { $0.id == id }
    }

    func device(_ id: String) async -> ProtectDevice? {
        guard let nvr = await plugin?.nvrs.first else { return nil }
        return await nvr.getDevice(id: id)
    }

    /// Sends an update event from the controller.
    func update(_ modelKey: String, id: String, _ payload: JSONValue) {
        webSockets.connections.first?.push(ProtectEventPacket.encode(header: ["action": "update", "id": .string(id), "modelKey": .string(modelKey), "newUpdateId": "u"], payload: payload))
    }

    func add(_ modelKey: String, id: String, _ payload: JSONValue) {
        webSockets.connections.first?.push(ProtectEventPacket.encode(header: ["action": "add", "id": .string(id), "modelKey": .string(modelKey), "newUpdateId": "u"], payload: payload))
    }
}

extension Accessory {
    func service(_ type: ServiceType, _ subtype: String) -> Service? {
        services.first { $0.type.uuid == type.uuid && $0.subtype == subtype }
    }

    /// `Type|subtype|name` of each service but the information and protocol ones, sorted.
    var summary: [String] {
        services.filter { ![ServiceType.accessoryInformation.uuid, ServiceType.protocolInformation.uuid].contains($0.type.uuid) }
            .map { "\($0.type.name)|\($0.subtype ?? "")|\($0[.name]?.value.stringValue ?? "")" }.sorted()
    }
}

/// A clock that stands still: budgets never run out and timeouts never strike, however loaded the machine.
struct FrozenClock: ProtectClock {
    let now = ContinuousClock.now

    func sleep(for duration: Duration) async {
        // Until cancelled.
        try? await Task.sleep(for: .seconds(3600))
    }
}
