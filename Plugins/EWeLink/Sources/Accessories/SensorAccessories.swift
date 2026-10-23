import Foundation
import Homeswift
import HomeswiftPlugin

/// Sensors (contact, motion, temperature and humidity, Zigbee): the services the device's parameters and
/// UIID call for, a battery when it reports one (low under `lowBattery`, 20 % by default), and a switch for
/// sensors with a relay (SONOFF SC) unless `hideSwitch`.
final class SensorAccessory: BaseAccessory {
    let entry: EWeLinkPlugin.Configuration.SensorDevice?
    private var switchService: Service?
    private var temperatureService: Service?
    private var humidityService: Service?
    private var motionService: Service?
    private var contactService: Service?
    private var batteryService: Service?

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        entry = platform.configuration.sensor(record.deviceID)
        super.init(platform: platform, record: record, box: box)
        category = .sensor
        let params = deviceParams
        if params["switch"] != nil, entry?.hideSwitch != true {
            let service = addService(.switch, name: record.displayName, primary: true)
            switchService = service
            self.service = service
            onRead(service.characteristic(.on), "On") { [weak self] in .bool(self?.deviceParams["switch"] == "on") }
            onWrite(service.characteristic(.on)) { [weak self] value in
                guard let self else { return }
                try await self.handleSet("On", value) { await self.sendCommand(["switch": onOff(value.boolValue == true)]) }
            }
        }
        if DeviceValueParser.hasTemperature(params), entry?.hideTemp != true {
            let service = addService(.temperatureSensor, name: "\(record.displayName) Temperature", subtype: "temp")
            temperatureService = service
            onRead(service.characteristic(.currentTemperature), "CurrentTemperature") { [weak self] in
                guard let self else { return nil }
                return .double(self.applyTemperatureOffset(DeviceValueParser.temperature(self.deviceParams), offset: self.entry?.tempOffset ?? 0))
            }
        }
        if DeviceValueParser.hasHumidity(params), entry?.hideHumidity != true {
            let service = addService(.humiditySensor, name: "\(record.displayName) Humidity", subtype: "humidity")
            humidityService = service
            onRead(service.characteristic(.currentRelativeHumidity), "CurrentRelativeHumidity") { [weak self] in
                guard let self else { return nil }
                return .double(self.applyHumidityOffset(DeviceValueParser.humidity(self.deviceParams), offset: self.entry?.humidityOffset ?? 0))
            }
        }
        if DeviceCatalog.isMotionSensor(box.device.uiid) {
            let service = addService(.motionSensor)
            motionService = service
            self.service = service
            onRead(service.characteristic(.motionDetected), "MotionDetected") { [weak self] in
                self.map { .bool(DeviceValueParser.motionState($0.deviceParams)) }
            }
        }
        if DeviceCatalog.isContactSensor(box.device.uiid) {
            let service = addService(.contactSensor)
            contactService = service
            self.service = service
            onRead(service.characteristic(.contactSensorState), "ContactSensorState") { [weak self] in
                self.map { .int(DeviceValueParser.contactState($0.deviceParams) ? 1 : 0) }
            }
        }
        if DeviceValueParser.hasBattery(params) {
            let service = addService(.battery, optional: [.batteryLevel])
            batteryService = service
            onRead(service.characteristic(.batteryLevel), "BatteryLevel") { [weak self] in
                self.map { .double(clamp(DeviceValueParser.battery($0.deviceParams, default: DeviceLimits.defaultBattery), DeviceLimits.battery)) }
            }
            onRead(service.characteristic(.statusLowBattery), "StatusLowBattery") { [weak self] in
                guard let self else { return nil }
                let level = DeviceValueParser.battery(self.deviceParams, default: DeviceLimits.defaultBattery)
                return .int(level < self.lowBatteryThreshold ? 1 : 0)
            }
        }
        if service == nil { service = temperatureService }
        applyInitialState()
    }

    private var lowBatteryThreshold: Double {
        let threshold = entry?.lowBattery ?? 0
        return threshold == 0 ? 20 : threshold
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if let switchService, let state = params["switch"] { switchService.characteristic(.on).value = .bool(state == "on") }
        if let temperatureService {
            update(temperatureService.characteristic(.currentTemperature), applyTemperatureOffset(DeviceValueParser.temperature(deviceParams), offset: entry?.tempOffset ?? 0))
        }
        if let humidityService {
            update(humidityService.characteristic(.currentRelativeHumidity), applyHumidityOffset(DeviceValueParser.humidity(deviceParams), offset: entry?.humidityOffset ?? 0))
        }
        if let motionService { motionService.characteristic(.motionDetected).value = .bool(DeviceValueParser.motionState(params)) }
        if let contactService { update(contactService.characteristic(.contactSensorState), DeviceValueParser.contactState(params) ? 1 : 0) }
        if let batteryService, params["battery"] != nil {
            let level = clamp(DeviceValueParser.battery(deviceParams, default: DeviceLimits.defaultBattery), DeviceLimits.battery)
            update(batteryService.characteristic(.batteryLevel), level)
            update(batteryService.characteristic(.statusLowBattery), level < lowBatteryThreshold ? 1 : 0)
        }
        logDebug("Sensor state updated")
    }
}

// MARK: RF Bridge

/// An RF Bridge (UIID 28, 98) and the Zigbee bridges: not in HomeKit itself, it routes what its remotes
/// and sensors send (`cmd: transmit` with `rfChl`, `rfTrig0`-`rfTrig3` timestamps) to their accessories.
final class RFBridgeAccessory: BaseAccessory {
    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        super.init(platform: platform, record: record, box: box)
        logDebug("RF Bridge initialized - manages RF sub-devices")
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if params["cmd"] == "transmit", let channel = params["rfChl"]?.jsNumber {
            handleButton(Int(channel))
            return
        }
        if params["cmd"] == "trigger" || params["updateSource"] == "LAN" {
            for index in 0..<4 {
                if let trigger = params["rfTrig\(index)"] { handleSensor(index, timestamp: trigger.jsString ?? "") }
            }
        }
    }

    /// The handler whose buttons include `channel`.
    private func handler(channel: Int) -> BaseAccessory? {
        platform.rfHandlers(bridge: box.device.deviceid).first { $0.record.buttons?.contains { $0.channel == String(channel) } ?? false }
    }

    private func handleButton(_ channel: Int) {
        logDebug("RF button triggered on channel \(channel)")
        guard let handler = handler(channel: channel) else {
            logDebug("No RF button accessory found for channel \(channel)")
            return
        }
        (handler as? RFButtonAccessory)?.triggerButton(channel)
    }

    private func handleSensor(_ channel: Int, timestamp: String) {
        logDebug("RF sensor triggered on channel \(channel) at \(timestamp)")
        guard let handler = handler(channel: channel) else {
            logDebug("No RF sensor accessory found for channel \(channel)")
            return
        }
        (handler as? RFSensorAccessory)?.triggerSensor(timestamp)
    }
}

/// A remote an RF Bridge learned: one switch per button; switching one on transmits the code, and it turns
/// itself off a second later. A press on the physical remote shows as the switch on for three seconds.
final class RFButtonAccessory: BaseAccessory {
    private var buttons: [Int: Service] = [:]
    private var names: [Int: String] = [:]

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        super.init(platform: platform, record: record, box: box)
        category = .switch
        guard let configured = record.buttons else {
            logError("No button configuration found in accessory context")
            return
        }
        for (channelText, name) in configured {
            let channel = Int(channelText) ?? 0
            names[channel] = name
            let safeName = sanitizeHomeKitName(name)
            let service = addService(.switch, name: safeName, subtype: "switch\(channelText)", extra: [Characteristic(.configuredName, value: .string(safeName))], primary: buttons.isEmpty)
            onRead(service.characteristic(.on), "Button\(channel)") { .bool(false) }
            onWrite(service.characteristic(.on)) { [weak self] value in try await self?.press(channel, value) }
            service.characteristic(.on).value = false
            buttons[channel] = service
            if self.service == nil { self.service = service }
        }
        logDebug("RF Button initialized with \(buttons.count) button(s)")
    }

    private func press(_ channel: Int, _ value: HAPValue) async throws {
        guard value.boolValue == true else { return }
        logInfo("Pressing button \(names[channel] ?? String(channel))")
        guard await sendCommand(["cmd": "transmit", "rfChl": .number(Double(channel))]) else {
            if let service = buttons[channel] { revertCharacteristicLater(service.characteristic(.on), false, after: Double(Timing.rfButtonPress)) }
            throw communicationError
        }
        setTrackedTimeout(Double(Timing.buttonPress)) { [weak self] in self?.buttons[channel]?.characteristic(.on).value = false }
    }

    /// The physical remote was pressed.
    func triggerButton(_ channel: Int? = nil) {
        guard let channel = channel ?? record.buttons?.first.flatMap({ Int($0.channel) }) else { return }
        guard let service = buttons[channel] else {
            logDebug("No service found for channel \(channel)")
            return
        }
        logInfo("Button \(names[channel] ?? String(channel)) triggered")
        service.characteristic(.on).value = true
        setTrackedTimeout(Double(Timing.rfButtonTrigger)) { service.characteristic(.on).value = false }
    }
}

/// A sensor an RF Bridge learned: motion by default, or the type its `rfDevices` sub-device entry gives
/// (contact, water, smoke, co, co2, occupancy, button, doorbell). Triggered for `resetTime` seconds (60).
final class RFSensorAccessory: BaseAccessory {
    let sensorType: String
    let sensorTimeLength: Double
    let sensorTimeDifference = Timing.sensorMaxTimeDifferenceSeconds
    private var lastActivation: String?
    private var sensorCharacteristic: Characteristic!

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        let subdevice = platform.configuration.rf(box.device.deviceid)?.subdevices?.first { $0.index == record.rfButtonIndex }
        sensorType = subdevice?.showAs?.nonEmpty ?? "motion"
        let reset = subdevice?.resetTime ?? 0
        sensorTimeLength = reset == 0 ? 60 : reset
        super.init(platform: platform, record: record, box: box)
        category = .sensor
        let (type, characteristic) = Self.service(for: sensorType)
        if sensorType == "button" || sensorType == "doorbell" {
            category = sensorType == "doorbell" ? .videoDoorbell : .programmableSwitch
            service = addService(type, optional: [CharacteristicType.programmableSwitchEvent.with(minValue: 0, maxValue: 0, validValues: [0])], primary: true)
            sensorCharacteristic = service.characteristic(characteristic)
        } else {
            service = addService(type, primary: true)
            sensorCharacteristic = service.characteristic(characteristic)
            onRead(sensorCharacteristic, "SensorState") { [weak self] in self.map { .int($0.sensorState) } }
            update(sensorCharacteristic, 0)
        }
        logDebug("RF Sensor initialized as \(sensorType) type")
    }

    static func service(for type: String) -> (ServiceType, CharacteristicType) {
        switch type {
        case "water": (.leakSensor, .leakDetected)
        case "smoke": (.smokeSensor, .smokeDetected)
        case "co": (.carbonMonoxideSensor, .carbonMonoxideDetected)
        case "co2": (.carbonDioxideSensor, .carbonDioxideDetected)
        case "contact": (.contactSensor, .contactSensorState)
        case "occupancy": (.occupancySensor, .occupancyDetected)
        case "button": (.statelessProgrammableSwitch, .programmableSwitchEvent)
        case "doorbell": (.doorbell, .programmableSwitchEvent)
        default: (.motionSensor, .motionDetected)
        }
    }

    private var sensorState: Int {
        guard sensorType != "button", sensorType != "doorbell", let lastActivation, let date = parseISODate(lastActivation) else { return 0 }
        return (platform.clock.nowMilliseconds - date.timeIntervalSince1970 * 1000) / 1000 < sensorTimeLength ? 1 : 0
    }

    private func setSensor(_ value: Int) {
        if sensorType == "button" || sensorType == "doorbell" {
            sensorCharacteristic.sendEvent(.int(0))
        } else {
            update(sensorCharacteristic, value)
        }
    }

    /// The sensor fired at `timestamp`.
    func triggerSensor(_ timestamp: String) {
        if timestamp == lastActivation {
            logDebug("Ignoring duplicate sensor trigger")
            return
        }
        lastActivation = timestamp
        let triggered = parseISODate(timestamp).map { $0.timeIntervalSince1970 * 1000 } ?? .nan
        let difference = (platform.clock.nowMilliseconds - triggered) / 1000
        if difference > sensorTimeDifference {
            logDebug("Sensor trigger too old: \(difference)s > \(sensorTimeDifference.jsDescription)s")
            return
        }
        logInfo("Sensor triggered (type: \(sensorType))")
        setSensor(1)
        if sensorType != "button", sensorType != "doorbell" {
            setTrackedTimeout(sensorTimeLength * 1000) { [weak self] in
                guard let self else { return }
                self.setSensor(0)
                self.logDebug("Sensor reset after \(self.sensorTimeLength.jsDescription)s")
            }
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
