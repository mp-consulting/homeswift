import Foundation
import Homeswift
import Logging
import NIOConcurrencyHelpers

/// The HomeKit side of a device, as the Homebridge plugin's `DysonLinkAccessory` and its services: an air
/// purifier (power, speed, swing, auto/manual), temperature and humidity sensors, an air quality sensor, the
/// filter, night mode, continuous monitoring and jet focus switches, a thermostat and/or heater-cooler on
/// Hot+Cool models, and a humidifier on Humidify+Cool models, each when the model has it and the options
/// keep it.
///
/// Reads answer the last value while the device is connected and "No Response" otherwise; the device's
/// state messages set the values.
final class DysonAccessory: @unchecked Sendable {
    static let speedDebounce: Duration = .milliseconds(300)
    static let filterChangeThreshold = 10
    static let heatingTolerance = 0.5

    let accessory: Accessory
    let device: DysonDevice
    let options: DeviceOptions
    let features: DeviceFeatures
    private let logger: Logger
    private let name: String

    let purifier: Service
    let temperature: Service?
    let humidity: Service?
    let airQuality: Service?
    let filter: Service?
    let nightMode: Service?
    let continuousMonitoring: Service?
    let jetFocus: Service?
    let thermostat: Service?
    let heaterCooler: Service?
    let humidifier: Service?

    /// The last manual speed (1-10): the slider shows it in auto mode, where the device reports none.
    private let lastManualSpeed = NIOLockedValueBox(MessageCodec.FanSpeed.default)
    private let speedDebouncer: SpeedDebouncer

    /// Builds the accessory. `cached` is the accessory restored from the cache: its values (and names the
    /// user gave the services in the Home app) carry over until the device reports.
    init(device: DysonDevice, id: String, name: String, options: DeviceOptions, firmwareVersion: String?, cached: Accessory?, logger: Logger) async {
        self.device = device
        self.options = options
        self.logger = logger
        self.name = name
        let features = await device.features
        let serial = await device.serial
        let productType = await device.productType
        self.features = features
        speedDebouncer = SpeedDebouncer(delay: Self.speedDebounce)

        func named(_ type: ServiceType, _ label: String, _ subtype: String, optional: [CharacteristicType] = [], extra: [Characteristic] = []) -> Service {
            Service(type, name: label, subtype: subtype, optional: optional, extra: extra + [Characteristic(.configuredName, value: .string(label))])
        }

        temperature = features.temperatureSensor && !options.isTemperatureIgnored
            ? named(.temperatureSensor, "Temperature", "temperature-sensor", optional: [.statusActive], extra: [Characteristic(Self.currentTemperature)]) : nil
        humidity = features.humiditySensor && !options.isHumidityIgnored
            ? named(.humiditySensor, "Humidity", "humidity-sensor", optional: [.statusActive]) : nil
        nightMode = features.nightMode && options.isNightModeEnabled ? named(.switch, "Night Mode", "night-mode") : nil
        continuousMonitoring = features.continuousMonitoring && options.isContinuousMonitoringEnabled
            ? named(.switch, "Continuous Monitoring", "continuous-monitoring") : nil
        if features.airQualitySensor && !options.isAirQualityIgnored {
            // Link models report a 0-9 index, not densities: no PM2.5 or PM10 there.
            var densities: [CharacteristicType] = features.basicAirQualitySensor ? [] : [.pm2_5Density, .pm10Density]
            densities.append(.vocDensity)
            if features.no2Sensor { densities.append(.nitrogenDioxideDensity) }
            airQuality = named(.airQualitySensor, "Air Quality", "air-quality-sensor", optional: densities)
        } else {
            airQuality = nil
        }
        filter = (features.hepaFilter || features.carbonFilter) && !options.isFilterStatusDisabled
            ? named(.filterMaintenance, "Filter", "filter-maintenance", optional: [.filterLifeLevel]) : nil

        var heaterCooler: Service?
        var thermostat: Service?
        if features.heating && !options.isHeatingDisabled {
            if options.heatingServiceType != .thermostat {
                heaterCooler = named(
                    .heaterCooler, "Heater", "heater-cooler",
                    extra: [
                        Characteristic(.targetHeaterCoolerState.with(minValue: 1, maxValue: 1, validValues: [1])), Characteristic(Self.currentTemperature),
                        Characteristic(.heatingThresholdTemperature.with(minValue: 10, maxValue: 38, minStep: 1), value: .double(20)),
                    ])
            }
            if options.heatingServiceType != .heaterCooler {
                thermostat = named(
                    .thermostat, "Thermostat", "thermostat",
                    extra: [
                        Characteristic(.targetHeatingCoolingState.with(validValues: [0, 1])), Characteristic(Self.currentTemperature),
                        Characteristic(.targetTemperature.with(minValue: MessageCodec.HeatingTemperature.minCelsius, maxValue: MessageCodec.HeatingTemperature.maxCelsius, minStep: 1)),
                    ])
            }
        }
        self.heaterCooler = heaterCooler
        self.thermostat = thermostat
        if features.humidifier && !options.isHumidifierDisabled {
            let range = options.fullRangeHumidity
                ? (MessageCodec.Humidity.minPercent, MessageCodec.Humidity.maxPercent) : (MessageCodec.Humidity.defaultMin, MessageCodec.Humidity.defaultMax)
            humidifier = named(
                .humidifierDehumidifier, "Humidifier", "humidifier", optional: [.waterLevel],
                extra: [
                    Characteristic(.targetHumidifierDehumidifierState.with(validValues: [0, 1])),
                    Characteristic(.relativeHumidityHumidifierThreshold.with(minValue: Double(range.0), maxValue: Double(range.1), minStep: 1), value: .double(Double(range.0))),
                ])
        } else {
            humidifier = nil
        }
        jetFocus = features.frontAirflow && options.isJetFocusEnabled ? named(.switch, "Jet Focus", "jet-focus") : nil

        let secondary = [temperature, humidity, nightMode, continuousMonitoring, airQuality, filter, heaterCooler, thermostat, humidifier, jetFocus].compactMap { $0 }
        // A plain fan has no auto mode: the target state is pinned to manual so HomeKit offers no Auto toggle.
        purifier = Service(
            .airPurifier, name: name, subtype: "air-purifier",
            extra: (features.autoMode ? [] : [Characteristic(.targetAirPurifierState.with(validValues: [0]))]) + [
                Characteristic(.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: 10)), Characteristic(.swingMode),
                Characteristic(.configuredName, value: .string(name)),
            ],
            linked: secondary, isPrimary: true)

        accessory = Accessory(
            id: id, name: name, manufacturer: "Dyson", model: DeviceCatalog.modelName(productType), serialNumber: serial,
            firmwareRevision: firmwareVersion?.nonEmpty ?? "1.0.0", category: .airPurifier, services: [purifier] + secondary)
        if let cached { accessory.takeValues(from: cached) }
        thermostat?.characteristic(.temperatureDisplayUnits).value = .int(0)
        heaterCooler?.characteristic(.targetHeaterCoolerState).value = .int(1)

        bind()
        let state = await device.state
        await device.setActivationDefaults(options.activation)
        if state.connected { apply(state) }
    }

    /// `CurrentTemperature` from -40 °C, as the Homebridge plugin sets it.
    static let currentTemperature = CharacteristicType.currentTemperature.with(minValue: -40, maxValue: 100, minStep: 0.1)

    // MARK: State to HomeKit

    /// Sets every characteristic from the device's state; unchanged values send no event.
    func apply(_ state: DeviceState) {
        purifier.characteristic(.active).value = .int(state.isOn ? 1 : 0)
        purifier.characteristic(.currentAirPurifierState).value = .int(Self.purifierState(state))
        purifier.characteristic(.targetAirPurifierState).value = .int(state.autoMode && features.autoMode ? 1 : 0)
        purifier.characteristic(.rotationSpeed).value = .double(Double(speedPercent(state)))
        purifier.characteristic(.swingMode).value = .int(state.oscillation ? 1 : 0)

        // A sensor that reports OFF keeps its last reading; Status Active tells the Home app it is not current.
        temperature?.characteristic(.statusActive).value = .bool(!state.temperatureOff)
        humidity?.characteristic(.statusActive).value = .bool(!state.humidityOff)
        if let temperature, let celsius = temperatureReading(state.temperature) {
            temperature.characteristic(.currentTemperature).value = .double(celsius)
            logger.debug("Temperature state changed -> \(options.useFahrenheit ? "\(MessageCodec.roundTenth(celsius * 9 / 5 + 32)) °F" : "\(celsius) °C")")
        }
        if let humidity, let percent = humidityReading(state.humidity) {
            humidity.characteristic(.currentRelativeHumidity).value = .double(percent)
        }
        if let airQuality {
            airQuality.characteristic(.airQuality).value = .int(Self.airQuality(state, basic: features.basicAirQualitySensor, no2: features.no2Sensor))
            if !features.basicAirQualitySensor {
                if let pm25 = Self.valid(state.pm25) { airQuality.characteristic(.pm2_5Density).value = .double(Double(pm25)) }
                if let pm10 = Self.valid(state.pm10) { airQuality.characteristic(.pm10Density).value = .double(Double(pm10)) }
            }
            if let voc = Self.valid(state.vocIndex) { airQuality.characteristic(.vocDensity).value = .double(Double(voc)) }
            if features.no2Sensor, let no2 = Self.valid(state.no2Index) { airQuality.characteristic(.nitrogenDioxideDensity).value = .double(Double(no2)) }
        }
        if let filter, let life = Self.filterLife(state) {
            filter.characteristic(.filterLifeLevel).value = .double(Double(life))
            filter.characteristic(.filterChangeIndication).value = .int(life <= Self.filterChangeThreshold ? 1 : 0)
        }
        nightMode?.characteristic(.on).value = .bool(state.nightMode)
        continuousMonitoring?.characteristic(.on).value = .bool(state.continuousMonitoring ?? true)
        jetFocus?.characteristic(.on).value = .bool(state.frontAirflow ?? false)

        let current = MessageCodec.decodeCelsius(state.temperature)
        if let thermostat {
            let heating = state.heatingEnabled == true ? 1 : 0
            thermostat.characteristic(.currentHeatingCoolingState).value = .int(heating)
            thermostat.characteristic(.targetHeatingCoolingState).value = .int(heating)
            if let current { thermostat.characteristic(.currentTemperature).value = .double(current) }
            if let target = Self.target(state.targetTemperature, in: MessageCodec.HeatingTemperature.minCelsius...MessageCodec.HeatingTemperature.maxCelsius) {
                thermostat.characteristic(.targetTemperature).value = .double(target)
            }
        }
        if let heaterCooler {
            heaterCooler.characteristic(.active).value = .int(state.isOn && state.heatingEnabled == true ? 1 : 0)
            heaterCooler.characteristic(.currentHeaterCoolerState).value = .int(Self.heaterCoolerState(state))
            if let current { heaterCooler.characteristic(.currentTemperature).value = .double(current) }
            if let target = Self.target(state.targetTemperature, in: 10...38) {
                heaterCooler.characteristic(.heatingThresholdTemperature).value = .double(target)
            }
        }
        if let humidifier {
            humidifier.characteristic(.active).value = .int(state.humidifierEnabled == true ? 1 : 0)
            humidifier.characteristic(.currentHumidifierDehumidifierState).value = .int(Self.humidifierState(state))
            humidifier.characteristic(.targetHumidifierDehumidifierState).value = .int(state.humidifierAuto == true ? 0 : 1)
            if let percent = state.humidity { humidifier.characteristic(.currentRelativeHumidity).value = .double(Double(percent)) }
            if let target = state.targetHumidity {
                let threshold = humidifier.characteristic(.relativeHumidityHumidifierThreshold).type
                let clamped = min(max(Double(target), threshold.minValue ?? 0), threshold.maxValue ?? 100)
                humidifier.characteristic(.relativeHumidityHumidifierThreshold).value = .double(clamped)
            }
            // No model reports its tank: it shows full.
            humidifier.characteristic(.waterLevel).value = .double(100)
        }
    }

    static func purifierState(_ state: DeviceState) -> Int {
        guard state.isOn else { return 0 }
        return state.fanSpeed == 0 ? 1 : 2
    }

    /// The speed as a percentage; in auto mode, the last manual speed instead of 0%.
    func speedPercent(_ state: DeviceState) -> Int {
        if state.fanSpeed > 0 {
            lastManualSpeed.withLockedValue { $0 = state.fanSpeed }
            return MessageCodec.speedToPercent(state.fanSpeed)
        }
        if state.fanSpeed == MessageCodec.FanSpeed.auto || state.autoMode {
            return MessageCodec.speedToPercent(lastManualSpeed.withLockedValue { $0 })
        }
        return MessageCodec.speedToPercent(state.fanSpeed)
    }

    /// Celsius with the offset, -40 to 100, or nil without a reading.
    func temperatureReading(_ kelvinTimes10: Int?) -> Double? {
        guard let celsius = MessageCodec.decodeCelsius(kelvinTimes10) else { return nil }
        return min(max(MessageCodec.roundTenth(celsius + options.temperatureOffset), -40), 100)
    }

    /// Percent with the offset, 0 to 100, or nil without a valid reading.
    func humidityReading(_ percent: Int?) -> Double? {
        guard let percent, (0...100).contains(percent) else { return nil }
        return min(max(Double(percent) + options.humidityOffset, 0), 100)
    }

    static func valid(_ reading: Int?) -> Int? {
        guard let reading, reading >= 0 else { return nil }
        return reading
    }

    /// Upper bounds of Excellent, Good, Fair and Inferior; above is Poor.
    typealias Thresholds = (Double, Double, Double, Double)
    /// PM2.5 µg/m³, EPA AQI breakpoints.
    static let pm25Thresholds: Thresholds = (12, 35, 55, 150)
    /// PM10 µg/m³, EPA AQI breakpoints.
    static let pm10Thresholds: Thresholds = (54, 154, 254, 354)
    /// The Link models' 0-9 particulate index.
    static let pactThresholds: Thresholds = (2, 4, 7, 9)
    /// The Link models' VOC index × 0.125.
    static let vactThresholds: Thresholds = (3, 6, 8, 9)
    /// VOC and NO2 indices after dividing `va10`/`noxl` by 10: 0-3 good, 4-6 fair, 7-8 poor, 9+ very poor.
    static let indexThresholds: Thresholds = (1, 3, 6, 8)

    static func rate(_ value: Double, _ thresholds: Thresholds) -> Int {
        if value <= thresholds.0 { return 1 }
        if value <= thresholds.1 { return 2 }
        if value <= thresholds.2 { return 3 }
        if value <= thresholds.3 { return 4 }
        return 5
    }

    /// HomeKit's air quality (0 unknown, 1 excellent … 5 poor): the worst of the readings there are.
    static func airQuality(_ state: DeviceState, basic: Bool, no2: Bool) -> Int {
        if basic {
            // On Link models `pm25` holds the `pact` index.
            guard let pact = valid(state.pm25) else { return 0 }
            let vact = valid(state.vocIndex).map { rate(Double($0) * 0.125, vactThresholds) } ?? 1
            return max(rate(Double(pact), pactThresholds), vact)
        }
        var ratings: [Int] = []
        if let pm25 = valid(state.pm25) { ratings.append(rate(Double(pm25), pm25Thresholds)) }
        if let pm10 = valid(state.pm10) { ratings.append(rate(Double(pm10), pm10Thresholds)) }
        if let voc = valid(state.vocIndex) { ratings.append(rate(Double(voc) / 10, indexThresholds)) }
        if no2, let index = valid(state.no2Index) { ratings.append(rate(Double(index) / 10, indexThresholds)) }
        return ratings.max() ?? 0
    }

    /// The most worn of the HEPA and carbon filters, in percent.
    static func filterLife(_ state: DeviceState) -> Int? {
        let lives = [state.hepaFilterLife, state.carbonFilterLife].compactMap { $0 }.filter { $0 >= 0 }
        guard let worst = lives.min() else { return nil }
        return min(100, worst)
    }

    /// A target temperature in whole degrees within the characteristic's range.
    static func target(_ kelvinTimes10: Int?, in range: ClosedRange<Double>) -> Double? {
        guard let celsius = MessageCodec.decodeCelsius(kelvinTimes10) else { return nil }
        return min(max((celsius + 0.5).rounded(.down), range.lowerBound), range.upperBound)
    }

    /// Heating while the room is below the target by more than half a degree, idle otherwise; heating
    /// without readings.
    static func heaterCoolerState(_ state: DeviceState) -> Int {
        guard state.isOn, state.heatingEnabled == true else { return 0 }
        guard let current = MessageCodec.decodeCelsius(state.temperature), let target = target(state.targetTemperature, in: 10...38) else { return 2 }
        return current < target - heatingTolerance ? 2 : 1
    }

    static func humidifierState(_ state: DeviceState) -> Int {
        guard state.humidifierEnabled == true else { return 0 }
        if let humidity = state.humidity, let target = state.targetHumidity, humidity < target { return 2 }
        return 1
    }

    // MARK: HomeKit to the device

    private func bind() {
        let device = device
        let logger = logger
        let name = name

        // Every readable characteristic answers "No Response" while the device is disconnected.
        for service in accessory.services where service.type.uuid != ServiceType.accessoryInformation.uuid {
            for characteristic in service.characteristics where characteristic.type.permissions.contains(.pairedRead) {
                if characteristic.type.uuid == CharacteristicType.configuredName.uuid || characteristic.type.uuid == CharacteristicType.name.uuid { continue }
                if characteristic.type.uuid == CharacteristicType.targetHeaterCoolerState.uuid { continue }
                characteristic.onRead { [weak characteristic] in
                    guard await device.isConnected else { throw HAPStatusError(.serviceCommunicationFailure) }
                    return characteristic?.value ?? .null
                }
            }
        }

        /// Runs a command; a failure is logged and reaches HomeKit as a communication failure.
        @Sendable func run(_ description: String, _ command: @Sendable () async throws -> Void) async throws {
            do {
                try await command()
            } catch {
                logger.error("Failed to \(description): \(error)", metadata: ["device": "\(name)"])
                throw HAPStatusError(.serviceCommunicationFailure)
            }
        }

        purifier.characteristic(.active).onWrite { value in
            let on = value.intValue == 1
            logger.debug("Set Active -> \(on)")
            try await run("set fan power") { try await device.setFanPower(on) }
        }
        purifier.characteristic(.targetAirPurifierState).onWrite { value in
            let auto = value.intValue == 1
            logger.debug("Set TargetAirPurifierState -> \(auto ? "AUTO" : "MANUAL")")
            try await run("set auto mode") { try await device.setAutoMode(auto) }
        }
        let debouncer = speedDebouncer
        purifier.characteristic(.rotationSpeed).onWrite { value in
            let percent = value.doubleValue ?? 0
            // A dragged slider sends a burst of values: the last one, after a pause, goes to the device.
            try await debouncer.submit(percent) { percent in
                logger.debug("Set RotationSpeed -> \(percent)")
                try await run("set fan speed") {
                    if percent == 0 {
                        try await device.setFanPower(false)
                    } else {
                        try await device.powerOnAndSetSpeed(MessageCodec.percentToSpeed(percent))
                    }
                }
            }
        }
        purifier.characteristic(.swingMode).onWrite { value in
            let on = value.intValue == 1
            logger.debug("Set SwingMode -> \(on)")
            try await run("set oscillation") { try await device.setOscillation(on) }
        }

        nightMode?.characteristic(.on).onWrite { value in
            let on = value.boolValue == true
            try await run("set night mode") { try await device.setNightMode(on) }
        }
        continuousMonitoring?.characteristic(.on).onWrite { value in
            let on = value.boolValue == true
            try await run("set continuous monitoring") { try await device.setContinuousMonitoring(on) }
        }
        jetFocus?.characteristic(.on).onWrite { value in
            let on = value.boolValue == true
            try await run("set jet focus") { try await device.setJetFocus(on) }
        }

        if let thermostat {
            thermostat.characteristic(.targetHeatingCoolingState).onWrite { value in
                let heat = value.intValue == 1
                logger.debug("Set TargetHeatingCoolingState -> \(heat ? "HEAT" : "OFF")")
                try await run("set heating mode") { try await device.setHeating(heat) }
            }
            thermostat.characteristic(.targetTemperature).onWrite { value in
                let celsius = value.doubleValue ?? MessageCodec.HeatingTemperature.minCelsius
                try await run("set target temperature") { try await device.setTargetTemperature(celsius) }
            }
        }
        if let heaterCooler {
            heaterCooler.characteristic(.active).onWrite { value in
                let active = value.intValue == 1
                logger.debug("Set Heater Active -> \(active)")
                try await run("set heater active") {
                    if active { try await device.startHeating() } else { try await device.setHeating(false) }
                }
            }
            heaterCooler.characteristic(.heatingThresholdTemperature).onWrite { value in
                let celsius = value.doubleValue ?? 20
                try await run("set target temperature") { try await device.setTargetTemperature(celsius) }
            }
        }
        if let humidifier {
            humidifier.characteristic(.active).onWrite { value in
                let active = value.intValue == 1
                try await run("set humidifier") { try await device.setHumidifier(active) }
            }
            humidifier.characteristic(.targetHumidifierDehumidifierState).onWrite { value in
                switch value.intValue {
                case 0: try await run("set humidifier auto") { try await device.setHumidifierAuto() }
                case 1: try await run("set humidifier manual") { try await device.setHumidifier(true) }
                default: break
                }
            }
            humidifier.characteristic(.relativeHumidityHumidifierThreshold).onWrite { value in
                let percent = value.doubleValue ?? 50
                try await run("set target humidity") { try await device.setTargetHumidity(percent) }
            }
        }
    }

    /// Follows the device: state changes set the values; a (re)connection pushes the whole state.
    func handle(_ event: DeviceEvent) {
        switch event {
        case .stateChanged(let state):
            apply(state)
        case .connected:
            // The `stateChanged` just before it (the state's `connected` changed) carried the whole state. Reading
            // the state again from a task here could apply it after a newer one.
            logger.info("Device connected: \(name)")
        case .disconnected:
            logger.warning("Device disconnected: \(name)")
        case .reconnectFailed, .error:
            break
        }
    }
}

/// Holds HomeKit's speed writes until the slider rests: each write waits for the command that carries the
/// last value, and gets its outcome.
actor SpeedDebouncer {
    private let delay: Duration
    private var pending: (value: Double, apply: @Sendable (Double) async throws -> Void)?
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var timer: Task<Void, Never>?

    init(delay: Duration) {
        self.delay = delay
    }

    func submit(_ value: Double, apply: @escaping @Sendable (Double) async throws -> Void) async throws {
        pending = (value, apply)
        timer?.cancel()
        let delay = delay
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            waiters.append(continuation)
        }
    }

    private func fire() async {
        guard let pending else { return }
        self.pending = nil
        let waiting = waiters
        waiters = []
        do {
            try await pending.apply(pending.value)
            for waiter in waiting { waiter.resume() }
        } catch {
            for waiter in waiting { waiter.resume(throwing: error) }
        }
    }
}
