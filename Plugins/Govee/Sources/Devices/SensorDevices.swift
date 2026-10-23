import Foundation
import HomeswiftPlugin
import Homeswift

/// Thermo-hygrometers (`device/sensor-thermo.ts`), or with `showExtraSwitch` a read-only thermostat
/// (`device/sensor-thermo-switch.ts`): temperature, humidity and battery from the HTTP device list or BLE
/// advertisements (readings in hundredths), with Eve history. BLE readings win over HTTP ones for four BLE
/// refresh cycles, as the cloud may lag behind.
final class SensorThermoDevice: GoveeDevice {
    let asThermostat: Bool
    private var temperatureService: Service!
    private var humidityService: Service!
    private var batteryService: Service!
    private let lowBattThreshold: Int
    private let httpTimeout: Duration
    private var cacheTemp = 0.0
    private var cacheHumi = 0.0
    private var cacheBatt = 0.0
    private var cacheOnline = true
    private var bleKey: UUID?

    init(environment: DeviceEnvironment, asThermostat: Bool) {
        self.asThermostat = asThermostat
        lowBattThreshold = environment.settings.lowBattThreshold
        // The Homebridge plugin's `(bleRefreshTime ?? 15) * 4.5` seconds.
        httpTimeout = .milliseconds(environment.platform.bleRefreshTime * 4500)
        super.init(environment: environment)
    }

    override var category: AccessoryCategory { asThermostat ? .thermostat : .sensor }

    override func configure() {
        if asThermostat {
            // A thermostat that only shows the temperature: no heating or cooling, Celsius.
            temperatureService = addService(.thermostat, characteristics: [
                .currentHeatingCoolingState.with(validValues: [0]), .targetHeatingCoolingState.with(validValues: [0]),
            ], primary: true)
            cacheTemp = double(temperatureService[.currentTemperature])
            if cacheTemp == 0 { cacheTemp = 20 }
            update(temperatureService[.targetTemperature], cacheTemp)
            update(temperatureService[.currentHeatingCoolingState], 0)
            update(temperatureService[.targetHeatingCoolingState], 0)
            update(temperatureService[.temperatureDisplayUnits], 0)
            temperatureService.characteristic(.targetTemperature).onRead { @GoveeActor [weak self] in .double(self?.cacheTemp ?? 20) }
        } else {
            temperatureService = addService(.temperatureSensor, primary: true)
            cacheTemp = double(temperatureService[.currentTemperature])
        }
        batteryService = addService(.battery, characteristics: [.batteryLevel])
        cacheBatt = double(batteryService[.batteryLevel])
        humidityService = addService(.humiditySensor)
        cacheHumi = double(humidityService[.currentRelativeHumidity])
        saveTemperature()
        startCustomHistory()
        logInitOptions([("lowBattThreshold", String(lowBattThreshold)), ("showExtraSwitch", String(asThermostat))])
        initialised = true
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let online = update.online, online != cacheOnline {
            cacheOnline = online
            log("Device is \(online ? "online" : "offline")")
        }
        if update.source == .ble {
            let key = UUID()
            bleKey = key
            schedule(after: httpTimeout) { [weak self] in
                if self?.bleKey == key { self?.bleKey = nil }
            }
        }
        if update.source == .http, bleKey != nil { return }

        if let battery = update.battery, battery != cacheBatt {
            cacheBatt = battery
            self.update(batteryService[.batteryLevel], cacheBatt)
            self.update(batteryService[.statusLowBattery], cacheBatt < Double(lowBattThreshold) ? 1 : 0)
            log("\(Lang.curBatt) [\(DeviceUpdate.format(cacheBatt))%]")
        }
        if let temperature = update.temperature {
            // `parseInt` of the hundredths, then the degrees.
            let newTemp = (temperature).rounded(.towardZero) / 100
            if newTemp != cacheTemp {
                cacheTemp = newTemp
                self.update(temperatureService[.currentTemperature], cacheTemp)
                if asThermostat { self.update(temperatureService[.targetTemperature], cacheTemp) }
                addHistory(temp: cacheTemp)
                log("\(Lang.curTemp) [\(DeviceUpdate.format(cacheTemp))°C / \(DeviceUpdate.format(Govee.cenToFar(cacheTemp)))°F]")
                saveTemperature()
            }
        }
        if let humidity = update.humidity {
            let newHumi = min(max(humidity.rounded(.towardZero) / 100, 0), 100)
            if newHumi != cacheHumi {
                cacheHumi = newHumi
                self.update(humidityService[.currentRelativeHumidity], cacheHumi)
                addHistory(humidity: cacheHumi)
                log("\(Lang.curHumi) [\(DeviceUpdate.format(cacheHumi))%]")
            }
        }
    }

    /// Heaters and coolers shown for a plug read the temperature from here (`temperatureSource`).
    private func saveTemperature() {
        storeTemperature(cacheTemp)
    }
}

/// The H5198, whose readings are not decoded yet: it logs what it receives (`device/sensor-thermo4.ts`).
final class SensorThermo4Device: GoveeDevice {
    override var category: AccessoryCategory { .sensor }

    override func configure() {
        logInitOptions([])
        logWarn("H5198 sensor support is under development. Data is being logged for analysis")
        initialised = true
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        logWarn(update.json.text(pretty: true))
        for command in update.commands ?? [] {
            let hex = Govee.base64ToHex(command)
            newScene(command, hex)
            if Govee.item(Govee.hexToTwoItems(hex), 1) == "aa" { newScene(command, hex) }
        }
    }
}

/// Leak sensors (`device/sensor-leak.ts`): a leak while an unread leakage alert exists in the Govee app,
/// battery, and Eve's last activation.
final class SensorLeakDevice: GoveeDevice {
    private var service: Service!
    private var batteryService: Service!
    private let lowBattThreshold: Int
    private var cacheLeak = false
    private var cacheBatt = 0.0
    private var cacheOnline = true

    override init(environment: DeviceEnvironment) {
        lowBattThreshold = environment.settings.lowBattThreshold
        super.init(environment: environment)
    }

    override var category: AccessoryCategory { .sensor }

    override func configure() {
        service = addService(.leakSensor, characteristics: [EveCharacteristic.lastActivation], primary: true)
        cacheLeak = int(service[.leakDetected]) != 0
        batteryService = addService(.battery, characteristics: [.batteryLevel])
        cacheBatt = double(batteryService[.batteryLevel])
        startHistory(.motion)
        logInitOptions([])
        initialised = true
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let online = update.online, online != cacheOnline {
            cacheOnline = online
            log("Device is \(online ? "online" : "offline")")
        }
        if let battery = update.battery, battery != cacheBatt {
            cacheBatt = battery
            self.update(batteryService[.batteryLevel], cacheBatt)
            self.update(batteryService[.statusLowBattery], cacheBatt < Double(lowBattThreshold) ? 1 : 0)
            log("\(Lang.curBatt) [\(DeviceUpdate.format(cacheBatt))%]")
        }
        if let leak = update.leakDetected, leak != cacheLeak {
            cacheLeak = leak
            self.update(service[.leakDetected], cacheLeak ? 1 : 0)
            if cacheLeak, let initialTime = history?.initialTime {
                self.update(service[EveCharacteristic.lastActivation], Int(Date().timeIntervalSince1970) - initialTime)
            }
            log("\(Lang.curLeak) [\(cacheLeak ? Lang.labelYes : Lang.labelNo)]")
        }
    }
}

/// The H5106 air quality monitor (`device/sensor-monitor.ts`): temperature, humidity and PM2.5, from the HTTP
/// device list or from its status frames.
final class SensorMonitorDevice: GoveeDevice {
    private var temperatureService: Service!
    private var humidityService: Service!
    private var airService: Service!
    private let lowBattThreshold: Int
    private var cacheTemp = 20.0
    private var cacheHumi = 50.0
    private var cacheAir = 0.0
    private var cacheAirQuality = "unknown"
    private var cacheOnline = true

    override init(environment: DeviceEnvironment) {
        lowBattThreshold = environment.settings.lowBattThreshold
        super.init(environment: environment)
    }

    override var category: AccessoryCategory { .sensor }

    override func configure() {
        temperatureService = addService(.temperatureSensor, primary: true)
        cacheTemp = double(temperatureService[.currentTemperature])
        storeTemperature(cacheTemp)
        humidityService = addService(.humiditySensor)
        cacheHumi = double(humidityService[.currentRelativeHumidity])
        airService = addService(.airQualitySensor, characteristics: [.pm2_5Density])
        cacheAir = double(airService[.pm2_5Density])
        startCustomHistory()
        logInitOptions([("lowBattThreshold", String(lowBattThreshold))])
        initialised = true
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let online = update.online, online != cacheOnline {
            cacheOnline = online
            log("Device is \(online ? "online" : "offline")")
        }
        // Readings from the HTTP device list, in hundredths (PM2.5 as is).
        if let temperature = update.temperature {
            setTemperature(temperature / 100)
        }
        if let humidity = update.humidity {
            setHumidity(min(max(Govee.round(humidity / 100), 0), 100))
        }
        if let pm25 = update.pm25 { setAirQuality(pm25) }

        for command in update.commands ?? [] {
            let hex = Govee.base64ToHex(command)
            let parts = Govee.hexToTwoItems(hex)
            let function = Govee.item(parts, 1) + Govee.item(parts, 2)
            switch function {
            case "0000", "0003", "0100", "0101", "0102", "0103", "331a", "3315", "aa0d", "aa0e":
                // Known frames without readings.
                break
            default:
                guard parts.count >= 21 else {
                    logDebug("\(Lang.newScene): [\(function)] [insufficient data: \(parts.count) parts]")
                    break
                }
                let offTemp = 0.0
                let temperature = Govee.round((Double(Govee.hexToDecimal("0x\(function)")) + offTemp / 100) / 10) / 10
                setTemperature(temperature)
                let humidity = Govee.round(Double(Govee.hexToDecimal("0x" + Govee.item(parts, 10) + Govee.item(parts, 11))) / 100)
                setHumidity(humidity)
                setAirQuality(Double(Govee.hexToDecimal("0x" + Govee.item(parts, 19) + Govee.item(parts, 20))))
            }
        }
    }

    private func setTemperature(_ value: Double) {
        guard value != cacheTemp else { return }
        cacheTemp = value
        update(temperatureService[.currentTemperature], cacheTemp)
        addHistory(temp: cacheTemp)
        log("\(Lang.curTemp) [\(DeviceUpdate.format(cacheTemp))°C / \(DeviceUpdate.format(Govee.cenToFar(cacheTemp)))°F]")
        storeTemperature(cacheTemp)
    }

    private func setHumidity(_ value: Double) {
        guard value != cacheHumi else { return }
        cacheHumi = value
        update(humidityService[.currentRelativeHumidity], cacheHumi)
        addHistory(humidity: cacheHumi)
        log("\(Lang.curHumi) [\(DeviceUpdate.format(cacheHumi))%]")
    }

    private func setAirQuality(_ pm25: Double) {
        if pm25 != cacheAir {
            cacheAir = pm25
            update(airService[.pm2_5Density], cacheAir)
            log("\(Lang.curPM25) [\(DeviceUpdate.format(pm25))µg/m³]")
        }
        let value = Catalog.airQuality(pm25: cacheAir)
        let label = Catalog.airQualityLabels[value] ?? "unknown"
        if cacheAirQuality != label {
            cacheAirQuality = label
            update(airService[.airQuality], value)
            log("\(Lang.curAirQual) [\(label)]")
        }
    }
}

/// The H5122 button: a stateless switch; scene reports are logged (`device/sensor-button.ts`).
final class SensorButtonDevice: GoveeDevice {
    override var category: AccessoryCategory { .programmableSwitch }

    override func configure() {
        addService(.statelessProgrammableSwitch, primary: true)
        logInitOptions([])
        initialised = true
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let scene = update.scene, !scene.isEmpty, scene != "0" { logWarn("\(Lang.newScene): [\(scene)]") }
    }
}

/// The H5123 contact sensor: the service, and scene reports logged (`device/sensor-contact.ts`).
final class SensorContactDevice: GoveeDevice {
    override var category: AccessoryCategory { .sensor }

    override func configure() {
        addService(.contactSensor, primary: true)
        logInitOptions([])
        initialised = true
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let scene = update.scene, !scene.isEmpty, scene != "0" { logWarn("\(Lang.newScene): [\(scene)]") }
    }
}

/// The H5127 presence sensor, as an occupancy sensor (`device/sensor-presence.ts`).
final class SensorPresenceDevice: GoveeDevice {
    private var service: Service!
    private var cacheOccupancy = 0

    override var category: AccessoryCategory { .sensor }

    override func configure() {
        service = addService(.occupancySensor, primary: true)
        cacheOccupancy = int(service[.occupancyDetected])
        logInitOptions([])
        initialised = true
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        for command in update.commands ?? [] {
            let hex = Govee.base64ToHex(command)
            let parts = Govee.hexToTwoItems(hex)
            guard Govee.item(parts, 1) == "aa" else { continue }
            switch Govee.item(parts, 1) + Govee.item(parts, 2) {
            case "aa01":
                let state = Govee.item(parts, 3) == "01" ? 1 : 0
                if state != cacheOccupancy {
                    cacheOccupancy = state
                    self.update(service[.occupancyDetected], cacheOccupancy)
                    log("\(Lang.curOcc) [\(cacheOccupancy == 1 ? "yes" : "no")]")
                }
            default:
                newScene(command, hex)
            }
        }
    }
}

/// Models whose support is under construction: an accessory without services that logs what it receives
/// (`device/template.ts`).
final class TemplateDevice: GoveeDevice {
    override func configure() {
        logInitOptions([])
        logWarn("Support for this device is under construction. This may not be possible if this is a Bluetooth-only device")
        initialised = true
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        logWarn(update.json.text())
        for command in update.commands ?? [] {
            let hex = Govee.base64ToHex(command)
            if Govee.item(Govee.hexToTwoItems(hex), 1) == "aa" { newScene(command, hex) }
        }
    }
}
