import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftUniFiProtect

/// The plugin on a bridge, against a fake controller: the accessories of each device type, their handlers,
/// the events, MQTT (devices.test.ts, sensor-logic.test.ts, night-vision-dimmer.test.ts, camera-properties
/// .test.ts, event-timers.test.ts and doorbell tests of the Homebridge plugin).
@Suite(.timeLimit(.minutes(1)), .serialized) struct DeviceTests {
    static let sensorID = ProtectPlatform.accessoryID(Fixtures.sensorMAC)
    static let cameraID = ProtectPlatform.accessoryID(Fixtures.cameraMAC)
    static let doorbellID = ProtectPlatform.accessoryID(Fixtures.doorbellMAC)
    static let lightID = ProtectPlatform.accessoryID(Fixtures.lightMAC)
    static let viewerID = ProtectPlatform.accessoryID(Fixtures.viewerMAC)
    static let chimeID = ProtectPlatform.accessoryID(Fixtures.chimeMAC)
    static let packageID = ProtectPlatform.accessoryID(Fixtures.doorbellMAC + ".PackageCamera")

    func topic(_ mac: String, _ topic: String) -> String { "unifi/protect/\(mac)/\(topic)" }

    @ProtectActor func detects(_ device: ProtectDevice) -> Bool? { device.context.detectMotion }

    @Test func sensorServicesAndValues() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let sensor = try #require(environment.accessory(host, Self.sensorID))
        #expect(sensor.summary == [
            "\(ServiceType.battery.name)||Front Door",
            "\(ServiceType.contactSensor.name)|ContactAlarmSound|Front Door Alarm Sound",
            "\(ServiceType.contactSensor.name)|ContactSensor|Front Door",
            "\(ServiceType.humiditySensor.name)||Front Door",
            "\(ServiceType.leakSensor.name)|External|Front Door External Leak Sensor",
            "\(ServiceType.leakSensor.name)|Internal|Front Door",
            "\(ServiceType.lightSensor.name)||Front Door",
            "\(ServiceType.motionSensor.name)||Front Door",
            "\(ServiceType.temperatureSensor.name)||Front Door",
        ].sorted())
        #expect(sensor.service(.lightSensor)?[.currentAmbientLightLevel]?.value == .double(0.0001))
        #expect(sensor.service(.humiditySensor)?[.currentRelativeHumidity]?.value == .double(45))
        #expect(sensor.service(.temperatureSensor)?[.currentTemperature]?.value == .double(21.5))
        #expect(sensor.service(.leakSensor, "Internal")?[.leakDetected]?.value == .int(1))
        #expect(sensor.service(.leakSensor, "External")?[.leakDetected]?.value == .int(0))
        #expect(sensor.service(.battery)?[.batteryLevel]?.value == .int(90))
        #expect(sensor.service(.motionSensor)?[.statusActive]?.value == .bool(true))
        #expect(sensor.information[.manufacturer]?.value == "Ubiquiti Inc." && sensor.information[.model]?.value == "UP Sense")
        #expect(sensor.information[.serialNumber]?.value == .string(Fixtures.sensorMAC))
        // Protect reports no hardware revision for this sensor: the characteristic stays off, as upstream leaves it.
        #expect(sensor.information[.hardwareRevision] == nil)
        #expect(await eventually { environment.mqtt.published.filter { $0.topic.hasPrefix("unifi/protect/\(Fixtures.sensorMAC)/") }.count >= 7 })
        let published = environment.mqtt.published.filter { $0.topic.hasPrefix("unifi/protect/\(Fixtures.sensorMAC)/") }.map { ($0.topic.split(separator: "/").last.map(String.init) ?? "", $0.string ?? "") }
        #expect(published.map(\.0) == ["alarm", "ambientlight", "contact", "humidity", "leak-external", "leak", "temperature"])
        #expect(published.map(\.1) == ["false", "0", "false", "45", "false", "true", "21.5"])
        // A reading changes.
        environment.update("sensor", id: "sensor-id", ["stats": ["temperature": ["value": 23]], "isOpened": true])
        #expect(await eventually { sensor.service(.temperatureSensor)?[.currentTemperature]?.value == .double(23) })
        #expect(sensor.service(.contactSensor, "ContactSensor")?[.contactSensorState]?.value == .int(1))
    }

    @Test func moistureSensorsAndOfflineSensors() async throws {
        let sensor = Fixtures.sensor().setting("isConnected", false).setting("mountType", "leak")
        let controller = FakeController(bootstrap: Fixtures.bootstrap { $0["sensors"] = [sensor] })
        let environment = ProtectTestEnvironment(controller: controller)
        let host = try await environment.start(options: ["Enable.Sensor.MoistureSensor"])
        defer { Task { await host.stop() } }
        let accessory = try #require(environment.accessory(host, Self.sensorID))
        #expect(accessory.service(.leakSensor, "Internal") == nil)
        #expect(accessory.service(.contactSensor, "External")?[.name]?.value == "Front Door External Moisture Sensor")
        #expect(accessory.service(.contactSensor, "ContactSensor") == nil)
        #expect(!environment.mqtt.published.contains { $0.topic == topic(Fixtures.sensorMAC, "leak") })
        #expect(accessory.service(.motionSensor)?[.statusActive]?.value == .bool(false))
    }

    @Test func motionEventsAndTheirReset() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start(options: ["Enable.Motion.Trigger", "Enable.Motion.Switch", "Enable.Log.Motion", "Enable.Motion.OccupancySensor"])
        defer { Task { await host.stop() } }
        let sensor = try #require(environment.accessory(host, Self.sensorID))
        let motion = try #require(sensor.service(.motionSensor)?[.motionDetected])
        let trigger = try #require(sensor.service(.switch, ProtectReservedNames.switchMotionTrigger))
        #expect(sensor.service(.switch, ProtectReservedNames.switchMotionSensor)?[.on]?.value == .bool(true))
        environment.update("sensor", id: "sensor-id", ["motionDetectedAt": 1_700_000_000_000])
        #expect(await eventually { motion.value == .bool(true) })
        // The trigger and the occupancy sensor go in the same pass as the motion sensor: wait for them too.
        #expect(await eventually { trigger[.on]?.value == .bool(true) && sensor.service(.occupancySensor)?[.occupancyDetected]?.value == .int(1) })
        #expect(await eventually { environment.mqtt.published(topic(Fixtures.sensorMAC, "motion")) == ["true"] })
        // Two seconds at least (scaled), then the reset.
        #expect(await eventually { motion.value == .bool(false) })
        #expect(await eventually { trigger[.on]?.value == .bool(false) })
        #expect(await eventually { environment.mqtt.published(topic(Fixtures.sensorMAC, "motion")) == ["true", "false"] })
        #expect(environment.logs.contains("Motion detected."))
        // Motion detection off: events are ignored.
        try await sensor.service(.switch, ProtectReservedNames.switchMotionSensor)?[.on]?.write(.bool(false))
        environment.update("sensor", id: "sensor-id", ["motionDetectedAt": 1_700_000_000_001])
        try await Task.sleep(for: .milliseconds(100))
        #expect(motion.value == .bool(false))
        // The trigger switch with motion detection off goes back off.
        try await trigger[.on]?.write(.bool(true))
        #expect(await eventually { trigger[.on]?.value == .bool(false) })
        // Occupancy lasts longer (60 s at least, scaled).
        #expect(await eventually { sensor.service(.occupancySensor)?[.occupancyDetected]?.value == .int(0) })
    }

    @Test func lightControls() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start(options: ["Enable.Device.StatusLed.Switch"], waitFor: Self.lightID)
        defer { Task { await host.stop() } }
        let light = try #require(environment.accessory(host, Self.lightID))
        let bulb = try #require(light.service(.lightbulb))
        #expect(bulb[.brightness]?.value == .int(40) && bulb[.on]?.value == .bool(false))
        try await bulb[.brightness]?.write(.int(50))
        let patch = try #require(environment.controller.requests("/proxy/protect/api/lights/light-id").last)
        #expect(FakeController.body(patch) == ["lightDeviceSettings": ["ledLevel": 4]])
        #expect(await eventually { bulb[.brightness]?.value == .int(60) })
        try await bulb[.on]?.write(.bool(true))
        #expect(FakeController.body(environment.controller.requests("/proxy/protect/api/lights/light-id").last!) == ["lightOnSettings": ["isLedForceOn": true]])
        #expect(await eventually { environment.mqtt.published(topic(Fixtures.lightMAC, "light")) == ["true"] })
        let led = try #require(light.service(.switch, ProtectReservedNames.switchStatusLed))
        #expect(led[.on]?.value == .bool(true))
        try await led[.on]?.write(.bool(false))
        #expect(FakeController.body(environment.controller.requests("/proxy/protect/api/lights/light-id").last!) == ["lightDeviceSettings": ["isIndicatorEnabled": false]])
        environment.update("light", id: "light-id", ["isLightOn": false, "lightDeviceSettings": ["ledLevel": 6]])
        #expect(await eventually { bulb[.brightness]?.value == .int(100) && bulb[.on]?.value == .bool(false) })
        // MQTT sets go through the same handlers.
        environment.mqtt.receive(topic(Fixtures.lightMAC, "light/brightness/set"), "20")
        #expect(await eventually { FakeController.body(environment.controller.requests("/proxy/protect/api/lights/light-id").last!) == ["lightDeviceSettings": ["ledLevel": 2]] })
        // A failed write reverts in HomeKit.
        environment.controller.update { $0.patchStatus = 500 }
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await bulb[.on]?.write(.bool(true)) }
        #expect(bulb[.on]?.value == .bool(false))
    }

    @Test func cameraControls() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start(options: [
            "Enable.Device.NightVision.Dimmer", "Enable.Nvr.Recording.Switch", "Enable.Motion.SmartDetect", "Enable.Motion.SmartDetect.ObjectSensors",
            "Enable.Motion.SmartDetect.ObjectSensors.LicensePlate.abc123-XYZ9",
        ], waitFor: Self.cameraID)
        defer { Task { await host.stop() } }
        let camera = try #require(environment.accessory(host, Self.cameraID))
        #expect(camera.information[.hardwareRevision]?.value == "11")
        let types = camera.services.compactMap(\.subtype).filter { $0.hasPrefix(ProtectReservedNames.contactMotionSmartDetect) }.sorted()
        #expect(types == [
            "ContactMotionSmartDetect.alrmSmoke", "ContactMotionSmartDetect.licensePlate", "ContactMotionSmartDetect.person", "ContactMotionSmartDetect.vehicle",
            "ContactMotionSmartDetectLicense.ABC123", "ContactMotionSmartDetectLicense.XYZ9",
        ])
        #expect(camera.service(.contactSensor, "ContactMotionSmartDetect.person")?[.name]?.value == "Driveway Person")
        // Night vision: auto is 10%; 50% is custom sensitivity 4, which settles at 48%.
        let dimmer = try #require(camera.service(.lightbulb, ProtectReservedNames.lightbulbNightVision))
        #expect(dimmer[.brightness]?.value == .int(10) && dimmer[.on]?.value == .bool(true))
        try await dimmer[.brightness]?.write(.int(50))
        let cameraPath = "/proxy/protect/api/cameras/camera-id"
        #expect(FakeController.body(environment.controller.requests(cameraPath).last!) == ["ispSettings": ["icrCustomValue": 4, "irLedMode": "custom"]])
        #expect(await eventually { dimmer[.brightness]?.value == .int(48) })
        try await dimmer[.brightness]?.write(.int(7))
        #expect(FakeController.body(environment.controller.requests(cameraPath).last!) == ["ispSettings": ["irLedMode": "autoFilterOnly"]])
        try await dimmer[.on]?.write(.bool(false))
        #expect(FakeController.body(environment.controller.requests(cameraPath).last!) == ["ispSettings": ["irLedMode": "off"]])
        // Recording mode switches.
        let always = try #require(camera.service(.switch, ProtectReservedNames.switchUFPRecordingAlways))
        let detections = try #require(camera.service(.switch, ProtectReservedNames.switchUFPRecordingDetections))
        #expect(always[.on]?.value == .bool(true) && detections[.on]?.value == .bool(false))
        #expect(detections[.name]?.value == "Driveway UFP Recording Detections")
        try await detections[.on]?.write(.bool(true))
        #expect(FakeController.body(environment.controller.requests(cameraPath).last!) == ["recordingSettings": ["mode": "detections", "prePaddingSecs": 2]])
        #expect(always[.on]?.value == .bool(false))
    }

    @Test func smartDetectionAndPlates() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start(options: [
            "Enable.Motion.SmartDetect", "Enable.Motion.SmartDetect.ObjectSensors", "Enable.Motion.SmartDetect.ObjectSensors.LicensePlate.ABC123",
            "Enable.Motion.OccupancySensor",
        ], waitFor: Self.cameraID)
        defer { Task { await host.stop() } }
        let camera = try #require(environment.accessory(host, Self.cameraID))
        let person = try #require(camera.service(.contactSensor, "ContactMotionSmartDetect.person"))
        let plate = try #require(camera.service(.contactSensor, "ContactMotionSmartDetectLicense.ABC123"))
        // Plain motion does not count when smart detection is on.
        environment.update("camera", id: "camera-id", ["lastMotion": 1])
        try await Task.sleep(for: .milliseconds(50))
        #expect(camera.service(.motionSensor)?[.motionDetected]?.value == .bool(false))
        environment.add("event", id: "event-1", ["type": "smartDetectZone", "camera": "camera-id", "smartDetectTypes": ["person"]])
        #expect(await eventually { person[.contactSensorState]?.value == .int(1) })
        #expect(await eventually {
            camera.service(.motionSensor)?[.motionDetected]?.value == .bool(true) && camera.service(.occupancySensor)?[.occupancyDetected]?.value == .int(1)
        })
        #expect(await eventually { environment.mqtt.published(topic(Fixtures.cameraMAC, "motion/smart/person")) == ["true"] })
        environment.update("camera", id: "camera-id", ["smartDetectTypes": ["vehicle"], "metadata": ["detectedThumbnails": [
            ["type": "vehicle", "name": "abc123", "confidence": 90, "attributes": ["color": ["val": "red", "confidence": 80]]], ["type": "motion"],
        ]]])
        #expect(await eventually { plate[.contactSensorState]?.value == .int(1) })
        #expect(await eventually { person[.contactSensorState]?.value == .int(0) && plate[.contactSensorState]?.value == .int(0) })
    }

    @Test func doorbell() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start(options: [
            "Enable.Doorbell.Messages", "Enable.Doorbell.PhysicalChime", "Enable.Doorbell.Trigger", "Enable.Doorbell.Mute", "Enable.Doorbell.Volume.Dimmer",
            "Enable.Doorbell.AuthSensor",
        ], extra: ["doorbellMessages": [["message": "I'll be there soon.", "duration": 30]]], waitFor: Self.doorbellID)
        defer { Task { await host.stop() } }
        let doorbell = try #require(environment.accessory(host, Self.doorbellID))
        #expect(doorbell.category == .videoDoorbell)
        let bell = try #require(doorbell.service(.doorbell))
        #expect(bell.isPrimary)
        // Message switches: the controller's and the configured ones.
        #expect(doorbell.service(.switch, "LEAVE_PACKAGE_AT_DOOR.LEAVE PACKAGE AT DOOR") != nil)
        #expect(doorbell.service(.switch, "CUSTOM_MESSAGE.Back soon") != nil)
        let custom = try #require(doorbell.service(.switch, "CUSTOM_MESSAGE.I'll be there soon."))
        try await custom[.on]?.write(.bool(true))
        let patch = try #require(FakeController.body(environment.controller.requests("/proxy/protect/api/cameras/doorbell-id").last!))
        #expect(patch.string("lcdMessage.text") == "I'll be there soon." && patch.string("lcdMessage.type") == "CUSTOM_MESSAGE" && patch.double("lcdMessage.resetAt") != nil)
        environment.update("camera", id: "doorbell-id", ["lcdMessage": ["type": "CUSTOM_MESSAGE", "text": "Back soon", "resetAt": .null]])
        // One pass sets the new message's switch and clears the others: wait for both.
        #expect(await eventually { doorbell.service(.switch, "CUSTOM_MESSAGE.Back soon")?[.on]?.value == .bool(true) && custom[.on]?.value == .bool(false) })
        environment.update("camera", id: "doorbell-id", ["lcdMessage": [:]])
        #expect(await eventually { doorbell.service(.switch, "CUSTOM_MESSAGE.Back soon")?[.on]?.value == .bool(false) })
        // Physical chimes: mechanical is on (300 ms); a refused change reverts.
        let mechanical = try #require(doorbell.service(.switch, ProtectReservedNames.switchDoorbellChimeMechanical))
        let digital = try #require(doorbell.service(.switch, ProtectReservedNames.switchDoorbellChimeDigital))
        #expect(mechanical[.on]?.value == .bool(true) && digital[.on]?.value == .bool(false))
        environment.controller.update { $0.patchStatus = 500 }
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await digital[.on]?.write(.bool(true)) }
        #expect(FakeController.body(environment.controller.requests("/proxy/protect/api/cameras/doorbell-id").last!) == ["chimeDuration": 1000])
        #expect(digital[.on]?.value == .bool(false))
        environment.controller.update { $0.patchStatus = 200 }
        // The chime volume dimmer averages the chimes this doorbell rings.
        let volume = try #require(doorbell.service(.lightbulb, ProtectReservedNames.lightbulbDoorbellVolume))
        #expect(await eventually { volume[.brightness]?.value == .int(80) })
        try await volume[.brightness]?.write(.int(30))
        let chimePatch = try #require(environment.controller.requests("/proxy/protect/api/chimes/chime-id").last)
        #expect(FakeController.body(chimePatch)?.array("ringSettings").first?.int("volume") == 30)
        // A ring: the doorbell event, the trigger switch, MQTT.
        let trigger = try #require(doorbell.service(.switch, ProtectReservedNames.switchDoorbellTrigger))
        environment.update("camera", id: "doorbell-id", ["lastRing": 1_700_000_000_000])
        #expect(await eventually { trigger[.on]?.value == .bool(true) })
        #expect(await eventually { environment.mqtt.published(topic(Fixtures.doorbellMAC, "doorbell")).first == "true" })
        #expect(await eventually { trigger[.on]?.value == .bool(false) })
        #expect(environment.logs.contains("Doorbell ring detected."))
        // The authentication sensor.
        let auth = try #require(doorbell.service(.contactSensor, ProtectReservedNames.contactAuthSensor))
        environment.add("event", id: "event-2", ["type": "nfcCardScanned", "camera": "doorbell-id", "metadata": ["nfc": ["ulpId": "user", "nfcId": "card-1"]]])
        #expect(await eventually { auth[.contactSensorState]?.value == .int(1) })
        #expect(await eventually { environment.mqtt.published(topic(Fixtures.doorbellMAC, "authenticate")) == [#"{"id":"card-1","type":"nfc"}"#] })
        #expect(await eventually { auth[.contactSensorState]?.value == .int(0) })
        // The package camera, with its flashlight.
        let package = try #require(environment.accessory(host, Self.packageID))
        #expect(package.name == "Front Door Package Camera")
        #expect(package.service(.lightbulb, ProtectReservedNames.lightbulbPackageFlashlight) != nil)
        #expect(package.service(.motionSensor) != nil)
        try await package.service(.lightbulb, ProtectReservedNames.lightbulbPackageFlashlight)?[.on]?.write(.bool(true))
        #expect(environment.controller.requests("/proxy/protect/api/cameras/doorbell-id/turnon-flashlight").count == 1)
    }

    @Test func ringDelayDebouncesRings() async throws {
        let environment = ProtectTestEnvironment()
        // A ring delay far longer than the test can take, however loaded the machine: 1000 s, 10 s scaled.
        let settings = ProtectTestEnvironment.block(options: ["Enable.Doorbell.Trigger"]).merging(["ringDelay": 1000]) { $1 }
        let host = try environment.host(settings: settings)
        try await host.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.accessory(host, Self.doorbellID) != nil })
        // Each ring publishes `true`, and `false` once the trigger resets.
        let rings: @Sendable () -> Int = { environment.mqtt.published(topic(Fixtures.doorbellMAC, "doorbell")).filter { $0 == "true" }.count }
        environment.update("camera", id: "doorbell-id", ["lastRing": 1])
        #expect(await eventually { rings() == 1 })
        environment.update("camera", id: "doorbell-id", ["lastRing": 2])
        // Events are handled one after the other: once this motion is out, the second ring has been handled.
        environment.update("camera", id: "doorbell-id", ["lastMotion": 3])
        #expect(await eventually { environment.mqtt.published(topic(Fixtures.doorbellMAC, "motion")).contains("true") })
        #expect(rings() == 1)
    }

    @Test func liveviewScenes() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start(options: ["Enable.Motion.Switch", "Enable.SecuritySystem.Alarm"], waitFor: ProtectPlatform.accessoryID(Fixtures.nvrMAC + ".Security"))
        defer { Task { await host.stop() } }
        let security = try #require(environment.accessory(host, ProtectPlatform.accessoryID(Fixtures.nvrMAC + ".Security")))
        let system = try #require(security.service(.securitySystem))
        #expect(security.information[.model]?.value == "UniFi Protect Liveview Security System")
        #expect(security.information[.hardwareRevision]?.value == "3")
        #expect(security.service(.switch) != nil)
        let garage = try #require(await eventually { environment.accessory(host, ProtectPlatform.accessoryID(Fixtures.nvrMAC + ".Liveview.GARAGE")) != nil }
            ? environment.accessory(host, ProtectPlatform.accessoryID(Fixtures.nvrMAC + ".Liveview.GARAGE")) : nil)
        #expect(garage.name == "Home NVR Garage")
        // Away: both cameras watch; Home: only the doorbell.
        try await system[.securitySystemTargetState]?.write(.int(HAPConstants.SecuritySystemTargetState.awayArm))
        #expect(system[.securitySystemCurrentState]?.value == .int(HAPConstants.SecuritySystemCurrentState.awayArm))
        let camera = try #require(await environment.device("camera-id"))
        let doorbell = try #require(await environment.device("doorbell-id"))
        #expect(await detects(camera) == true)
        #expect(await detects(doorbell) == true)
        try await system[.securitySystemTargetState]?.write(.int(HAPConstants.SecuritySystemTargetState.stayArm))
        #expect(await detects(camera) == false)
        #expect(await detects(doorbell) == true)
        let cameraAccessory = try #require(environment.accessory(host, Self.cameraID))
        #expect(cameraAccessory.service(.switch, ProtectReservedNames.switchMotionSensor)?[.on]?.value == .bool(false))
        #expect(await eventually { environment.mqtt.published(topic(Fixtures.nvrMAC, "securitysystem")).last == "Home" })
        // The Garage switch turns its camera's motion detection back on.
        try await garage.service(.switch)?[.on]?.write(.bool(true))
        #expect(await detects(camera) == true)
        // The alarm.
        try await security.service(.switch)?[.on]?.write(.bool(true))
        #expect(system[.securitySystemCurrentState]?.value == .int(HAPConstants.SecuritySystemCurrentState.alarmTriggered))
        environment.mqtt.receive(topic(Fixtures.nvrMAC, "securitysystem/set"), "off")
        #expect(await eventually { system[.securitySystemCurrentState]?.value == .int(HAPConstants.SecuritySystemCurrentState.disarmed) })
        #expect(await detects(camera) == false)
        #expect(await detects(doorbell) == false)
    }

    @Test func viewerAndChime() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start(waitFor: Self.viewerID)
        defer { Task { await host.stop() } }
        let viewer = try #require(environment.accessory(host, Self.viewerID))
        #expect(viewer.services.filter { $0.type.uuid == ServiceType.switch.uuid }.count == 3)
        #expect(viewer.service(.switch, "liveview-garage")?[.on]?.value == .bool(true))
        try await viewer.service(.switch, "liveview-home")?[.on]?.write(.bool(true))
        #expect(FakeController.body(environment.controller.requests("/proxy/protect/api/viewers/viewer-id").last!) == ["liveview": "liveview-home"])
        #expect(viewer.service(.switch, "liveview-garage")?[.on]?.value == .bool(false))
        #expect(await eventually { environment.mqtt.published(topic(Fixtures.viewerMAC, "liveview")) == ["Protect-Home"] })
        let chime = try #require(await eventually { environment.accessory(host, Self.chimeID)?.service(.switch, "DoorbellChime.speaker.tone-1") != nil }
            ? environment.accessory(host, Self.chimeID) : nil)
        #expect(chime.service(.switch, ProtectReservedNames.switchDoorbellChimeBuzzer)?[.name]?.value == "Hall Chime Buzzer")
        let tone = try #require(chime.service(.switch, "DoorbellChime.speaker.tone-1"))
        try await tone[.on]?.write(.bool(true))
        let play = try #require(environment.controller.requests("/proxy/protect/api/chimes/chime-id/play-speaker").last)
        #expect(FakeController.body(play) == ["repeatTimes": 1, "ringtoneId": "tone-1", "volume": 80])
        #expect(tone[.on]?.value == .bool(true))
        #expect(await eventually { tone[.on]?.value == .bool(false) })
        #expect(await eventually { environment.mqtt.published(topic(Fixtures.chimeMAC, "tone")) == ["Traditional"] })
    }

    @Test func systemInformationAndDisabledDevices() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start(options: ["Enable.Nvr.SystemInfo", "Disable.Device.\(Fixtures.lightMAC)"],
                                               waitFor: ProtectPlatform.accessoryID(Fixtures.nvrMAC + ".NVRSystemInfo"))
        defer { Task { await host.stop() } }
        let info = try #require(environment.accessory(host, ProtectPlatform.accessoryID(Fixtures.nvrMAC + ".NVRSystemInfo")))
        #expect(info.service(.temperatureSensor)?[.currentTemperature]?.value == .double(48.5))
        environment.update("nvr", id: "nvr-id", ["systemInfo": ["cpu": ["temperature": 51]]])
        #expect(await eventually { info.service(.temperatureSensor)?[.currentTemperature]?.value == .double(51) })
        #expect(environment.accessory(host, Self.lightID) == nil)
        #expect(environment.accessory(host, Self.sensorID) != nil)
    }

    @Test func unadoptedDevicesLeave() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start(options: ["Disable.Nvr.DelayDeviceRemoval"])
        defer { Task { await host.stop() } }
        #expect(environment.accessory(host, Self.sensorID) != nil)
        environment.add("event", id: "event-3", ["type": "deviceUnadopted", "metadata": ["deviceId": ["text": "sensor-id"]]])
        #expect(await eventually { environment.accessory(host, Self.sensorID) == nil })
    }

    @Test func webAPI() async throws {
        let environment = ProtectTestEnvironment()
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        let options = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "options", user: "admin"))
        #expect(options.json.array("categories").count == 11)
        let devices = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "devices",
            body: ["address": "192.168.1.1", "username": "homeswift", "password": "secret"], user: "admin"))
        let list = devices.json.array("devices")
        #expect(list.first?.string("modelKey") == "nvr")
        #expect(list.map { $0.string("modelKey") ?? "" } == ["nvr", "camera", "camera", "chime", "light", "sensor", "viewer"])
        #expect(list.dropFirst().first?.string("name") == "Driveway")
        // The configured controller's own password, over the certificate the running plugin pinned.
        let configured = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "devices",
            body: ["address": "192.168.1.1", "username": "homeswift"], user: "admin"))
        #expect(configured.json.array("devices").count == list.count)
        let refused = try await plugin.handleWebRequest(PluginWebRequest(method: "POST", path: "devices",
            body: ["address": "192.168.1.1", "username": "homeswift", "password": "wrong"], user: "admin"))
        #expect(refused.json.array("devices").isEmpty)
        #expect(refused.json.string("error") == "Invalid login credentials given. Please check your login and password." || refused.json.string("error")?.contains("Invalid login") == true)
        let status = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "controllers", user: "admin"))
        #expect(status.json.array("controllers").first?.bool("connected") == true)
        let missing = try await plugin.handleWebRequest(PluginWebRequest(method: "GET", path: "nope", user: "admin"))
        #expect(missing.status == 404)
    }

    @Test func noControllers() async throws {
        let environment = ProtectTestEnvironment()
        let host = try environment.host(settings: ["name": "UniFi Protect"])
        try await host.start()
        defer { Task { await host.stop() } }
        #expect(await eventually { environment.logs.contains("No UniFi Protect controllers have been configured.") })
    }
}
