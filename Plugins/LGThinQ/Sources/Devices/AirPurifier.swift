import Foundation
import Homeswift
import HomeswiftPlugin

/// Reads of a status the Homebridge plugin's `BaseStatus` helpers make.
struct StatusReader {
    let data: [String: JSONValue]

    func int(_ key: String, fallback: Double = 0) -> Double { JS.parseInt(data[key], fallback: fallback) }
    func string(_ key: String, fallback: String = "") -> String { data[key]?.stringValue ?? fallback }
    func bool(_ key: String) -> Bool { JS.truthy(data[key]) }
    func has(_ key: String) -> Bool { data[key] != nil }

    /// `getBoolean`: 1, true, "1" and "true" are on.
    func boolean(_ key: String, default defaultValue: Bool = false) -> Bool {
        switch data[key] {
        case nil, .null?: defaultValue
        case .bool(let bool)?: bool
        case .number(let number)?: number != 0
        case .string(let string)?: string == "1" || string.lowercased() == "true"
        default: true
        }
    }

    /// The remaining life of a filter in percent, 0 to 100 (0 when the maximum is unknown).
    func filterRemainingPercent(current: String, maximum: String) -> Double {
        let maxTime = int(maximum)
        guard maxTime > 0 else { return 0 }
        let used = max(0, int(current))
        return max(0, min(100, ((1 - used / maxTime) * 100).rounded(.toNearestOrAwayFromZero)))
    }
}

/// An air purifier's flat snapshot.
struct AirPurifierStatus {
    nonisolated static let normalMode = 14.0
    nonisolated static let autoMode = 16.0
    nonisolated static let speeds = [2.0, 4.0, 6.0, 7.0]
    nonisolated static let filterChangeThreshold = 95.0

    let reader: StatusReader

    init(_ data: [String: JSONValue]) { reader = StatusReader(data: data) }

    var isPowerOn: Bool { reader.boolean("airState.operation") }

    var isLightOn: Bool {
        if reader.has("airState.lightingState.signal") { return isPowerOn && reader.boolean("airState.lightingState.signal") }
        if reader.has("airState.lightingState.displayControl") { return isPowerOn && reader.boolean("airState.lightingState.displayControl") }
        return false
    }

    var isSwing: Bool { reader.boolean("airState.circulate.rotate") }

    var airQuality: ACStatus.AirQuality {
        guard reader.has("airState.quality.overall") || reader.has("airState.quality.PM2") || reader.has("airState.quality.PM10") else {
            return .init(isOn: false, overall: 0, pm2: 0, pm10: 0)
        }
        return .init(isOn: isPowerOn || reader.boolean("airState.quality.sensorMon"), overall: reader.int("airState.quality.overall"),
            pm2: reader.int("airState.quality.PM2"), pm10: reader.int("airState.quality.PM10"))
    }

    var rotationSpeed: Double { Self.rotationSpeed(windStrength: reader.int("airState.windStrength")) }
    var isNormalMode: Bool { reader.int("airState.opMode") == Self.normalMode }
    var filterRemainingPercent: Double { reader.filterRemainingPercent(current: "airState.filterMngStates.useTime", maximum: "airState.filterMngStates.maxTime") }
    var filterMaxTime: Double { reader.int("airState.filterMngStates.maxTime") }
    var isAirFastEnable: Bool { reader.boolean("airState.miscFuncState.airFast") }

    /// Change the filter once more than 95 % of its life is used.
    nonisolated static func needsFilterChange(_ remaining: Double) -> Bool { remaining < 100 - filterChangeThreshold }

    /// HomeKit's 0 to 4 speed (step 0.1) as a wind strength: rounded and clamped, 0 is the lowest.
    nonisolated static func windStrength(rotationSpeed: Double) -> Double {
        let level = rotationSpeed.isFinite ? rotationSpeed.rounded(.toNearestOrAwayFromZero) : 1
        return speeds[Int(max(1, min(Double(speeds.count), level))) - 1]
    }

    /// A wind strength as HomeKit's level 1 to 4; unknown strengths are the middle.
    nonisolated static func rotationSpeed(windStrength: Double) -> Double {
        if let index = speeds.firstIndex(of: windStrength) { return Double(index + 1) }
        return (Double(speeds.count) / 2).rounded(.up)
    }
}

/// An air purifier: speed (four levels), swing, auto mode, the air quality sensor, the light, the filter and
/// the Air Fast switch.
class AirPurifier: BaseDevice {
    var serviceAirPurifier: Service!
    var serviceAirQuality: Service!
    var serviceLight: Service?
    var serviceFilterMaintenance: Service?
    var serviceAirFastMode: Service?

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        super.init(device: device, environment: environment)
        let purifier = addService(.airPurifier, name: "Air Purifier", optional: [
            .swingMode, CharacteristicType.rotationSpeed.props(min: 0, max: Double(AirPurifierStatus.speeds.count), step: 0.1),
        ])
        purifier.characteristic(.active).onGet { [weak self] in .int(self?.status.isPowerOn == true ? 1 : 0) }
            .onSet { [weak self] value in try await self?.setActive(value) }
        purifier.characteristic(.targetAirPurifierState).onSet { [weak self] value in try await self?.setTargetAirPurifierState(value) }
        purifier.set(.name, device.name)
        purifier.characteristic(.swingMode).onSet { [weak self] value in try await self?.setSwingMode(value) }
        purifier.characteristic(.rotationSpeed).onSet { [weak self] value in try await self?.setRotationSpeed(value) }
        serviceAirPurifier = purifier

        serviceAirQuality = addService(.airQualitySensor, name: "Air Quality Sensor", optional: [.pm2_5Density, .pm10Density, .statusActive])

        let snapshot = device.snapshot
        if snapshot["airState.lightingState.displayControl"] != nil || snapshot["airState.lightingState.signal"] != nil {
            let light = addService(.lightbulb, name: "Light", optional: lightCharacteristics())
            light.characteristic(.on).onSet { [weak self] value in try await self?.setLight(value) }
            serviceLight = light
        }
        if status.filterMaxTime != 0, !status.filterMaxTime.isNaN {
            let filter = addService(.filterMaintenance, name: "Filter Maintenance", optional: [.filterLifeLevel])
            purifier.linked = [filter]
            serviceFilterMaintenance = filter
        }
        if config.flag("air_fast_mode") {
            let airFast = addService(.switch, name: "Air Fast")
            airFast.characteristic(.on).onSet { [weak self] value in try await self?.setAirFastActive(value) }
            serviceAirFastMode = airFast
        }
    }

    /// The light's characteristics beyond On.
    func lightCharacteristics() -> [CharacteristicType] { [] }

    var status: AirPurifierStatus { AirPurifierStatus(statusData()) }

    /// A control that must be accepted.
    func sendControl(_ dataKey: String, _ dataValue: Double) async throws {
        guard try await setDeviceControl(dataKey, .number(dataValue)) else {
            logger.warning("[\(device.name)] Device did not accept \(dataKey)")
            throw Self.communicationFailure()
        }
    }

    func setAirFastActive(_ value: HAPValue) async throws {
        guard status.isPowerOn else { return }
        try await sendControl("airState.miscFuncState.airFast", Normalize.boolean(value) ? 1 : 0)
    }

    func setActive(_ value: HAPValue) async throws {
        let isOn = Normalize.boolean(value)
        if status.isPowerOn, isOn { return }
        logger.debug("Set Active State -> \(value)")
        guard try await setBooleanControl("airState.operation", isOn) else { throw Self.communicationFailure() }
    }

    func setTargetAirPurifierState(_ value: HAPValue) async throws {
        let auto = value.boolValue ?? false
        guard status.isPowerOn, auto == status.isNormalMode else { return }
        logger.debug("Set Target State -> \(value)")
        try await sendControl("airState.opMode", auto ? AirPurifierStatus.autoMode : AirPurifierStatus.normalMode)
    }

    func setRotationSpeed(_ value: HAPValue) async throws {
        guard status.isPowerOn, status.isNormalMode, let speed = Normalize.number(value) else { return }
        logger.debug("Set Rotation Speed -> \(value)")
        try await sendControl("airState.windStrength", AirPurifierStatus.windStrength(rotationSpeed: speed))
    }

    func setSwingMode(_ value: HAPValue) async throws {
        guard status.isPowerOn, status.isNormalMode else { return }
        try await sendControl("airState.circulate.rotate", Normalize.boolean(value) ? 1 : 0)
    }

    func setLight(_ value: HAPValue) async throws {
        guard status.isPowerOn else { return }
        let snapshot = device.snapshot
        let dataKey = snapshot["airState.lightingState.signal"] != nil ? "airState.lightingState.signal"
            : snapshot["airState.lightingState.displayControl"] != nil ? "airState.lightingState.displayControl" : nil
        guard let dataKey else { return }
        try await sendControl(dataKey, Normalize.boolean(value) ? 1 : 0)
    }

    override func updateAccessoryCharacteristic(_ device: ThinQDevice) {
        super.updateAccessoryCharacteristic(device)
        let status = status
        serviceAirPurifier.set(.active, status.isPowerOn ? 1 : 0)
        serviceAirPurifier.set(.currentAirPurifierState, status.isPowerOn ? 2 : 0)
        serviceAirPurifier.set(.targetAirPurifierState, status.isNormalMode ? 0 : 1)
        serviceAirPurifier.set(.swingMode, status.isSwing ? 1 : 0)
        serviceAirPurifier.set(.rotationSpeed, status.rotationSpeed)
        if status.filterMaxTime != 0, !status.filterMaxTime.isNaN, let filter = serviceFilterMaintenance {
            let remaining = status.filterRemainingPercent
            filter.set(.filterLifeLevel, remaining)
            filter.set(.filterChangeIndication, AirPurifierStatus.needsFilterChange(remaining) ? 1 : 0)
        }
        // airState.quality.sensorMon = 1: the sensor runs while the purifier is off.
        let quality = status.airQuality
        serviceAirQuality.set(.airQuality, quality.overall)
        serviceAirQuality.set(.pm2_5Density, quality.pm2)
        serviceAirQuality.set(.pm10Density, quality.pm10)
        serviceAirQuality.set(.statusActive, quality.isOn)
        serviceLight?.set(.on, status.isLightOn)
        if config.flag("air_fast_mode") { serviceAirFastMode?.set(.on, status.isAirFastEnable) }
    }
}

/// The AeroTower: an air purifier with temperature and humidity sensors, a three-level light and UV purification.
final class AeroTower: AirPurifier {
    nonisolated static let lightLevels = [8.0, 9.0, 10.0]

    var serviceTemperatureSensor: Service!
    var serviceHumiditySensor: Service!
    var serviceUVNano: Service!

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        super.init(device: device, environment: environment)
        serviceTemperatureSensor = addService(.temperatureSensor, name: "Temperature Sensor")
        serviceHumiditySensor = addService(.humiditySensor, name: "Humidity Sensor")
        serviceLight?.characteristic(.brightness).onSet { [weak self] value in try await self?.setLightBrightness(value) }
        serviceUVNano = addService(.switch, name: "UV Purifier", subtype: "UV Purifier")
        serviceUVNano.characteristic(.on).onSet { [weak self] value in try await self?.setUVMode(value) }
    }

    override func lightCharacteristics() -> [CharacteristicType] { [CharacteristicType.brightness.props(max: 3)] }

    override func setLight(_ value: HAPValue) async throws {
        guard status.isPowerOn else { return }
        _ = try await setDeviceControl("airState.lightingState.displayControl", .number(value.boolValue == true ? 1 : 0))
    }

    func setUVMode(_ value: HAPValue) async throws {
        _ = try await setDeviceControl("airState.miscFuncState.Uvnano", .number(value.boolValue == true ? 1 : 0))
    }

    func setLightBrightness(_ value: HAPValue) async throws {
        guard let level = Normalize.number(value) else { return }
        let index = Int(level) - 1
        guard level == level.rounded(), Self.lightLevels.indices.contains(index) else { return }
        _ = try await setDeviceControl("airState.lightingState.displayControl", .number(Self.lightLevels[index]))
    }

    override func updateAccessoryCharacteristic(_ device: ThinQDevice) {
        super.updateAccessoryCharacteristic(device)
        let snapshot = device.snapshot
        let display = snapshot["airState.lightingState.displayControl"].flatMap { JS.truthy($0) ? $0.doubleValue : nil } ?? 0
        if let index = Self.lightLevels.firstIndex(of: display) { serviceLight?.set(.brightness, index + 1) }
        if let temperature = snapshot["airState.tempState.current"] { serviceTemperatureSensor.set(.currentTemperature, JS.number(temperature)) }
        if let humidity = snapshot["airState.humidity.current"] { serviceHumiditySensor.set(.currentRelativeHumidity, JS.number(humidity)) }
        serviceUVNano.set(.on, JS.truthy(snapshot["airState.miscFuncState.Uvnano"]))
    }
}
