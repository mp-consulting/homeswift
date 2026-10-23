import Foundation
import Homeswift
import HomeswiftPlugin

/// A dehumidifier: target humidity, two speeds, the water tank as the water level, and a humidity sensor.
final class Dehumidifier: BaseDevice {
    nonisolated static let speeds = [2.0, 6.0]
    /// Operation modes that dehumidify.
    nonisolated static let dehumidifyingModes = [17.0, 18.0, 19.0, 21.0]

    var serviceDehumidifier: Service!
    var serviceHumiditySensor: Service!

    struct Status {
        let reader: StatusReader
        var isPowerOn: Bool { reader.bool("airState.operation") }
        var opMode: Double { reader.int("airState.opMode") }
        var windStrength: Double { reader.int("airState.windStrength") }
        var humidityCurrent: Double { reader.int("airState.humidity.current") }
        var humidityTarget: Double { reader.int("airState.humidity.desired") }
        var isDehumidifying: Bool { Dehumidifier.dehumidifyingModes.contains(opMode) && humidityCurrent >= humidityTarget }
        var isWaterTankFull: Bool { reader.bool("airState.notificationExt") }

        var rotationSpeed: Double {
            if let index = Dehumidifier.speeds.firstIndex(of: windStrength) { return Double(index + 1) }
            return (Double(Dehumidifier.speeds.count) / 2).rounded(.up)
        }
    }

    /// HomeKit's speed level as a wind strength (rounded, clamped; 0 is the lowest).
    nonisolated static func windStrength(speed: Double) -> Double {
        let level = speed.isFinite ? speed.rounded(.toNearestOrAwayFromZero) : 1
        return speeds[Int(max(1, min(Double(speeds.count), level))) - 1]
    }

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        super.init(device: device, environment: environment)
        let service = addService(.humidifierDehumidifier, name: device.name, optional: [
            CharacteristicType.currentHumidifierDehumidifierState.valid([0, 1, 3]),
            CharacteristicType.targetHumidifierDehumidifierState.valid([2]),
            CharacteristicType.relativeHumidityDehumidifierThreshold.props(min: 0, max: 100, step: 1),
            CharacteristicType.rotationSpeed.props(min: 1, max: Double(Self.speeds.count), step: 1),
            .waterLevel,
        ])
        service.characteristic(.active).onSet { [weak self] value in try await self?.setActive(value) }
        service.set(.active, 0)
        service.set(.currentHumidifierDehumidifierState, 0)
        service.set(.targetHumidifierDehumidifierState, 2)
        service.characteristic(.relativeHumidityDehumidifierThreshold).onSet { [weak self] value in try await self?.setHumidityThreshold(value) }
        service.characteristic(.rotationSpeed).onSet { [weak self] value in try await self?.setSpeed(value) }
        serviceDehumidifier = service

        serviceHumiditySensor = addService(.humiditySensor, name: "Humidity Sensor", optional: [.statusActive])
        serviceHumiditySensor.linked = [service]
    }

    var status: Status { Status(reader: StatusReader(data: statusData())) }

    func setActive(_ value: HAPValue) async throws {
        logger.debug("Set Dehumidifier Active State -> \(value)")
        let isOn = Normalize.boolean(value)
        if status.isPowerOn, isOn { return }
        guard try await setBooleanControl("airState.operation", isOn) else { throw Self.communicationFailure() }
    }

    func setHumidityThreshold(_ value: HAPValue) async throws {
        guard status.isPowerOn, let humidity = Normalize.number(value) else { return }
        guard try await setDeviceControl("airState.humidity.desired", .number(humidity)) else { throw Self.communicationFailure() }
    }

    func setSpeed(_ value: HAPValue) async throws {
        guard status.isPowerOn, let speed = Normalize.number(value) else { return }
        guard try await setDeviceControl("airState.windStrength", .number(Self.windStrength(speed: speed))) else { throw Self.communicationFailure() }
    }

    override func updateAccessoryCharacteristic(_ device: ThinQDevice) {
        super.updateAccessoryCharacteristic(device)
        let status = status
        serviceDehumidifier.set(.active, status.isPowerOn ? 1 : 0)
        serviceDehumidifier.set(.currentRelativeHumidity, status.humidityCurrent)
        serviceDehumidifier.set(.relativeHumidityDehumidifierThreshold, status.humidityTarget)
        serviceDehumidifier.set(.currentHumidifierDehumidifierState, status.isPowerOn ? (status.isDehumidifying ? 3 : 1) : 0)
        serviceDehumidifier.set(.rotationSpeed, status.rotationSpeed)
        serviceDehumidifier.set(.waterLevel, status.isWaterTankFull ? 100 : 0)
        serviceHumiditySensor.set(.currentRelativeHumidity, status.humidityCurrent)
        serviceHumiditySensor.set(.statusActive, status.isPowerOn)
    }
}
