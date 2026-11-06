import Foundation
import Homeswift
import HomeswiftPlugin

// The battery of a battery camera (docs/clean-room/TapoBattery.md): its level, whether it charges and whether it is low,
// from the control API's `getDeviceInfo` (2.1), which answers only while the camera is awake. So it is read once a live
// view has woken the camera (6), at most every `batteryInterval`, never on its own; the last reading is kept in
// `battery.json` so HomeKit shows a level between live views, and the TP-Link cloud's `CameraLowBattery` and
// `BatteryEmpty` notifications, which never reach the camera, mark it low as they come (5.3).

/// What a camera last said of its battery.
struct TapoBatteryReading: Codable, Sendable, Equatable {
    /// Percent, 0 to 100; nil before the camera ever said.
    var level: Int?
    var charging = false
    /// The camera's own low-battery flag (`low_battery`), or a low-battery notification; nil when it gave none.
    var low: Bool?
    /// Where its power comes from: `BATTERY`, `SOLAR` or `ADAPTER`.
    var power: String?

    /// Below this percentage the battery is low when the camera does not say (5.3).
    static let lowLevel = 20

    /// Status Low Battery: the camera's flag, else the level below `lowLevel`.
    var isLow: Bool { low ?? level.map { $0 < Self.lowLevel } ?? false }

    /// A `basic_info` as the battery reads it (2.1, 5): nil without any battery key (a camera on mains, 7 #12); a missing
    /// key keeps what `previous` had.
    static func from(basicInfo info: [String: Any], previous: TapoBatteryReading?) -> TapoBatteryReading? {
        let keys = ["battery_percent", "battery_charging", "low_battery", "power", "power_mode"]
        guard keys.contains(where: { info[$0] != nil }) else { return nil }
        var reading = previous ?? TapoBatteryReading()
        if let percent = number(info["battery_percent"]) { reading.level = min(100, max(0, Int(percent.rounded()))) }
        if let value = info["battery_charging"] {
            // Paused by heat is not charging (5.2).
            reading.charging = isCharging(value) && (info["battery_overheated"] as? Bool) != true
        } else if previous == nil {
            reading.charging = false
        }
        if let low = info["low_battery"] as? Bool {
            reading.low = low
        } else if info["battery_percent"] != nil {
            // A new level without the camera's flag: the level decides, not an older flag or notification.
            reading.low = nil
        }
        if let power = (info["power"] as? String) ?? (info["power_mode"] as? String) { reading.power = power }
        return reading
    }

    /// `battery_charging` (5.2): a JSON true, or a word other than the ones meaning not charging or full; only `NO` is
    /// known, so any other spelling of charging counts.
    static func isCharging(_ value: Any) -> Bool {
        if let text = value as? String {
            let word = text.trimmingCharacters(in: .whitespaces).lowercased()
            return !["", "no", "false", "0", "off", "none", "full", "finished", "charged", "complete"].contains(word)
        }
        return (value as? Bool) ?? false
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

extension TapoPlugin {
    /// The control API's request for the camera's basic information (2.1).
    static var deviceInfoParams: [String: Any] { ["device_info": ["name": ["basic_info"]]] }
    /// The notifications that say the battery is low or empty (4.4).
    static let batteryNotifications: Set<String> = ["CameraLowBattery", "BatteryEmpty"]
    /// How long after a live view opens the battery is asked: the camera has proved awake (6).
    static let batteryDelay = 3.0

    private var batteryFile: JSONFile<[String: TapoBatteryReading]> { context.jsonFile("battery.json", as: [String: TapoBatteryReading].self) }

    /// The kept reading of a camera, from `battery.json` the first time.
    func keptBattery(_ deviceID: String) -> TapoBatteryReading? {
        if batteryReadings == nil { batteryReadings = batteryFile.load() ?? [:] }
        return batteryReadings?[deviceID]
    }

    /// Reads a camera's battery now that a live view woke it, unless it was read less than `batteryInterval` ago; a
    /// camera that went back to sleep, or does not answer, keeps its last reading.
    func readBattery(deviceID: String) async {
        if let last = batteryReadAt[deviceID], ContinuousClock.now - last < scaled(dependencies.batteryInterval) { return }
        // Taken before any wait: sessions that open close together (a reconnection) read it once.
        batteryReadAt[deviceID] = .now
        try? await Task.sleep(for: scaled(Self.batteryDelay))
        guard let runtime = cameraRuntimes[deviceID], await runtime.feed.isConnected, let control = runtime.control else {
            // Asleep again before it was asked: the next live view asks.
            batteryReadAt[deviceID] = nil
            return
        }
        let found: TapoBatteryReading?
        do {
            found = try await control.batteryReading(previous: keptBattery(deviceID))
        } catch {
            logger.debug("\(runtime.cameras.first?.accessory.name ?? "The camera"): no battery reading: \(error)")
            return
        }
        guard let reading = found else {
            logger.debug("\(runtime.cameras.first?.accessory.name ?? "The camera"): its basic information says nothing of a battery.")
            return
        }
        keep(reading, for: deviceID)
    }

    /// The cloud said the battery is low or empty: low until the camera says otherwise, the level as it was (5.3).
    func batteryReportedLow(deviceID: String) {
        var reading = keptBattery(deviceID) ?? TapoBatteryReading()
        reading.low = true
        keep(reading, for: deviceID)
    }

    private func keep(_ reading: TapoBatteryReading, for deviceID: String) {
        for camera in cameraRuntimes[deviceID]?.cameras ?? [] { camera.apply(reading) }
        guard reading != keptBattery(deviceID) else { return }
        batteryReadings?[deviceID] = reading
        do { try batteryFile.save(batteryReadings ?? [:]) } catch { logger.warning("Could not keep the cameras' battery levels: \(error)") }
    }
}

extension TapoControl {
    /// The camera's battery from its basic information (2.1): nil when it says nothing of one.
    func batteryReading(previous: TapoBatteryReading?) async throws -> TapoBatteryReading? {
        // In turn with the motor's calls: two logins at once would each break the other's nonce (3.2).
        await acquire()
        defer { release() }
        let result = try await call("getDeviceInfo", TapoPlugin.deviceInfoParams)
        let info = ((result["device_info"] as? [String: Any])?["basic_info"] as? [String: Any]) ?? [:]
        return TapoBatteryReading.from(basicInfo: info, previous: previous)
    }
}

extension TapoCamera {
    /// The Battery service of a lens: both lenses of a C675D show the camera's one battery (5).
    static func batteryService(name: String) -> Service {
        let service = Service(.battery, name: "\(name) Battery", subtype: "battery", optional: [.batteryLevel, .chargingState])
        service.characteristic(.statusLowBattery).value = .int(0)
        service.characteristic(.chargingState).value = .int(0)
        return service
    }

    /// Shows a reading: a level the camera never gave stays as it was.
    func apply(_ reading: TapoBatteryReading) {
        guard let battery else { return }
        if let level = reading.level { battery.characteristic(.batteryLevel).value = .int(level) }
        battery.characteristic(.chargingState).value = .int(reading.charging ? 1 : 0)
        battery.characteristic(.statusLowBattery).value = .int(reading.isLow ? 1 : 0)
    }
}
