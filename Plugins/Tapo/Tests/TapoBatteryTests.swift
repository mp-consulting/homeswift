import Foundation
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftTapo

/// docs/clean-room/TapoBattery.md, 7: a `basic_info` as Battery Level, Charging State and Status Low Battery.
struct TapoBatteryReadingTests {
    func values(_ info: [String: Any], previous: TapoBatteryReading? = nil) -> (level: Int?, charging: Int, low: Int)? {
        TapoBatteryReading.from(basicInfo: info, previous: previous).map { ($0.level, $0.charging ? 1 : 0, $0.isLow ? 1 : 0) }
    }

    @Test func theSpecsVectors() throws {
        #expect(try #require(values(["power": "BATTERY", "battery_percent": 100, "battery_charging": "NO", "low_battery": false])) == (100, 0, 0))
        #expect(try #require(values(["power": "BATTERY", "battery_percent": 7, "battery_charging": "NO", "low_battery": true])) == (7, 0, 1))
        #expect(try #require(values(["power": "BATTERY", "battery_percent": 90, "battery_charging": "NO", "low_battery": false, "battery_overheated": false])) == (90, 0, 0))
        #expect(try #require(values(["power": "SOLAR", "battery_percent": 64, "battery_charging": "YES", "low_battery": false])) == (64, 1, 0))
        #expect(try #require(values(["power": "SOLAR", "battery_percent": 64, "battery_charging": "NO", "low_battery": false])) == (64, 0, 0))
        #expect(try #require(values(["power": "ADAPTER", "battery_percent": 100, "battery_charging": "FINISHED"])) == (100, 0, 0))
        #expect(try #require(values(["power_mode": "BATTERY", "battery_percent": 15])) == (15, 0, 1))
        #expect(try #require(values(["power": "BATTERY", "battery_percent": 30, "battery_charging": true, "low_battery": false])) == (30, 1, 0))
        #expect(try #require(values(["power": "BATTERY", "battery_percent": 105, "battery_charging": "NO", "low_battery": false])) == (100, 0, 0))
        let stored = TapoBatteryReading(level: 55, charging: false, low: false, power: "BATTERY")
        #expect(try #require(values(["power": "BATTERY", "battery_charging": "NO"], previous: stored)) == (55, 0, 0))
        #expect(try #require(values(["power": "BATTERY", "battery_percent": 40, "battery_charging": "CHARGING", "battery_overheated": true, "low_battery": false])) == (40, 0, 0))
        #expect(values(["device_model": "C200", "sw_version": "1.0"]) == nil)
    }

    @Test func aLowNotificationLastsUntilTheCameraSaysOtherwise() throws {
        var reading = TapoBatteryReading(level: 22, charging: false, low: false, power: "BATTERY")
        reading.low = true
        #expect(reading.level == 22 && reading.isLow)
        let next = try #require(TapoBatteryReading.from(basicInfo: ["battery_percent": 60, "low_battery": false], previous: reading))
        #expect(next.level == 60 && !next.isLow)
    }
}

/// The battery through the plugin: asked only while a live view keeps the camera awake, kept across restarts, and
/// marked low by the cloud's notifications.
@Suite(.timeLimit(.minutes(1)))
struct TapoBatteryTests {
    let environment = TestEnvironment()
    let deviceID = "192.168.1.40Garden"
    let wideID = "TapoP100:192.168.1.40Garden"
    let teleID = "TapoP100:192.168.1.40Garden:tele"

    func battery(_ host: PluginHost, _ id: String) async throws -> Service {
        #expect(await eventually { host.bridges.flatMap(\.server.accessories).contains { $0.id == id } })
        let accessory = try #require(host.bridges.flatMap(\.server.accessories).first { $0.id == id })
        return try #require(accessory.service(.battery))
    }

    /// A camera whose live view and control API sign in with the account's password.
    func awakeCamera() -> (FakeTapoControlCamera, FakeStreamdCamera) {
        let camera = FakeStreamdCamera()
        camera.state.withLockedValue { $0.password = "password123" }
        return (FakeTapoControlCamera(), camera)
    }

    let devices: [[String: Any]] = [["name": "Garden", "host": "192.168.1.40", "type": "DualLensCamera", "motion": false]]

    /// Opens a live view, waits for `condition`, and closes it again.
    func watch(_ feed: TapoCameraFeed, until condition: @Sendable () async -> Bool) async -> Bool {
        let viewer = await feed.join()
        let met = await eventually(condition)
        await feed.leave(viewer.id)
        return await eventually { await feed.isConnected == false } && met
    }

    @Test func aLiveViewReadsTheBatteryForBothLensesAndKeepsIt() async throws {
        let (control, camera) = awakeCamera()
        // Every live view may ask: the interval is tested on its own.
        let host = try await environment.start(devices: devices, connect: camera.connect, control: control, batteryInterval: 0)
        let wide = try await battery(host, wideID)
        let tele = try await battery(host, teleID)
        #expect(wide[.statusLowBattery]?.value == .int(0))
        // Asleep: never asked.
        try await Task.sleep(for: .milliseconds(100))
        #expect(control.state.withLockedValue { $0.deviceInfoReads + $0.logins } == 0)
        let feed = try #require(await environment.plugin?.cameraRuntimes[deviceID]?.feed)
        #expect(await watch(feed) { wide[.batteryLevel]?.value == .int(64) && tele[.batteryLevel]?.value == .int(64) })
        #expect(wide[.chargingState]?.value == .int(0))
        // Charging at the next live view.
        control.state.withLockedValue { $0.basicInfo = ["power": "SOLAR", "battery_percent": 65, "battery_charging": "YES", "low_battery": false] }
        #expect(await watch(feed) { tele[.chargingState]?.value == .int(1) && tele[.batteryLevel]?.value == .int(65) })
        await host.stop()

        // A restart shows the kept level before any live view.
        let again = try await environment.start(devices: devices, connect: camera.connect, control: control)
        let kept = try await battery(again, teleID)
        #expect(kept[.batteryLevel]?.value == .int(65))
        #expect(kept[.chargingState]?.value == .int(1))
        await again.stop()
    }

    @Test func aLiveViewWithinTheIntervalDoesNotAskAgain() async throws {
        let (control, camera) = awakeCamera()
        // 200 seconds here: longer than the test.
        let host = try await environment.start(devices: devices, connect: camera.connect, control: control, batteryInterval: 100_000)
        let wide = try await battery(host, wideID)
        let feed = try #require(await environment.plugin?.cameraRuntimes[deviceID]?.feed)
        #expect(await watch(feed) { wide[.batteryLevel]?.value == .int(64) })
        control.state.withLockedValue { $0.basicInfo["battery_percent"] = 50 }
        let viewer = await feed.join()
        try await Task.sleep(for: .milliseconds(200))
        #expect(control.state.withLockedValue { $0.deviceInfoReads } == 1)
        #expect(wide[.batteryLevel]?.value == .int(64))
        await feed.leave(viewer.id)
        await host.stop()
    }

    @Test func theCloudsLowBatteryNoticeMarksItLow() async throws {
        let cloud = FakeTapoCloud()
        let host = try await environment.start(devices: [["name": "Garden", "host": "192.168.1.40", "type": "DualLensCamera"]], cloud: cloud)
        let wide = try await battery(host, wideID)
        let tele = try await battery(host, teleID)
        #expect(await eventually { cloud.paths.contains("/api/v2/common/getAppNotificationByPage") })
        cloud.notify(type: "CameraLowBattery")
        #expect(await eventually { wide[.statusLowBattery]?.value == .int(1) && tele[.statusLowBattery]?.value == .int(1) })
        #expect(wide.type.uuid == ServiceType.battery.uuid)
        await host.stop()
    }
}
