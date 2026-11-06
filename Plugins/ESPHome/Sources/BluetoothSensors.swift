import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// A Bluetooth sensor set up through Setup: its format (its Accessory Settings' `format`), and its bindkey when it
/// encrypts (in the vault, as `ESPHomeCredentials.encryptionKey`).
struct BluetoothSensorSetup: Sendable, Equatable {
    var mac: String
    var format: BluetoothFormat
    var key: [UInt8]?
}

/// The Bluetooth LE devices the plugin's proxies hear. Every proxy passes on what it hears, so one advertisement
/// arrives once per proxy in range: the same frame from one sender within `duplicateWindow` is read once. Senders in a
/// known format are Discovered Devices; those set up are accessories, No Response once unheard for `timeout`.
actor BluetoothHub {
    /// A sender heard in a known format.
    struct Heard: Sendable {
        var mac: String
        var recognition: BluetoothRecognition
        var name: String?
        var rssi: Int
        /// The proxy that heard it loudest of late.
        var proxy: String
        var lastSeen: ContinuousClock.Instant
        /// Its last advertisement in its format, and its last encrypted one, for checking a bindkey in Setup.
        var advertisement: BluetoothAdvertisement
        var encryptedAdvertisement: BluetoothAdvertisement?
    }

    /// The most senders kept: a street's worth of phones and trackers never fills the memory.
    static let capacity = 256
    static let duplicateWindow: Duration = .seconds(5)

    private let context: PluginContext
    private let timeout: Duration
    private let clock = ContinuousClock()
    private var logger: Logger { context.logger }
    private(set) var heard: [String: Heard] = [:]
    /// Names from scan responses, by MAC: Govee's newer models are told by their name.
    private var names: [String: String] = [:]
    /// The last frame read from each sensor set up, and when.
    private var lastFrames: [String: (frame: [UInt8], at: ContinuousClock.Instant)] = [:]
    private var sensors: [String: BluetoothSensor] = [:]
    private var setups: [String: BluetoothSensorSetup] = [:]
    private var warnedKeys = Set<String>()
    /// The counter of the last encrypted frame read from each sensor, and when.
    private var counters: [String: (value: UInt32, at: ContinuousClock.Instant)] = [:]
    /// The frames of sensors set up that were read: one per frame, however many proxies heard it.
    private(set) var framesRead = 0

    init(context: PluginContext, timeout: Duration) {
        self.context = context
        self.timeout = timeout
    }

    /// The sensors set up, from the Accessory Settings; their accessories restored from the cache come back as they were,
    /// reachable for `timeout` unless heard. Not `listening` (the `bluetooth` option off), they show No Response: nothing
    /// will update them.
    func configure(_ list: [BluetoothSensorSetup], listening: Bool = true) {
        let now = clock.now
        for setup in list {
            setups[setup.mac] = setup
            let sensor = BluetoothSensor(setup: setup, context: context, heardAt: now)
            sensors[setup.mac] = sensor
            sensor.restore()
            if !listening { sensor.markUnavailable(true) }
        }
    }

    /// Advertisements from one proxy.
    func receive(_ advertisements: [BluetoothAdvertisement], from proxy: String) {
        let now = clock.now
        for advertisement in advertisements {
            let mac = advertisement.mac
            if let name = advertisement.name, Govee.isGovee(name) || heard[mac] != nil || setups[mac] != nil { remember(name, of: mac) }
            let name = names[mac] ?? advertisement.name
            let existing = heard[mac]
            // A scan response without the format's data says nothing more than the name.
            guard let recognition = BluetoothDecoders.recognize(advertisement, name: name) ?? existing?.recognition,
                  let frame = recognition.format.frame(of: advertisement, name: name) else { continue }
            if existing == nil {
                logger.debug("Heard \(recognition.model ?? recognition.format.rawValue) \(mac) through \(proxy)")
                evictIfFull()
            }
            var entry = existing ?? Heard(
                mac: mac, recognition: recognition, name: name, rssi: advertisement.rssi, proxy: proxy, lastSeen: now, advertisement: advertisement)
            // The loudest proxy of the last minute is the one it is nearest.
            if advertisement.rssi > entry.rssi || entry.proxy == proxy || now - entry.lastSeen > .seconds(60) {
                entry.rssi = advertisement.rssi
                entry.proxy = proxy
            }
            // A sender that encrypts some frames (a Xiaomi sensor's readings, not its beacons) needs its bindkey.
            if recognition.encrypted { entry.encryptedAdvertisement = advertisement }
            let sameFormat = entry.recognition.format == recognition.format
            entry.recognition = BluetoothRecognition(
                format: recognition.format, model: recognition.model ?? (sameFormat ? entry.recognition.model : nil),
                encrypted: recognition.encrypted || sameFormat && entry.recognition.encrypted)
            entry.name = name ?? entry.name
            entry.lastSeen = now
            entry.advertisement = advertisement
            heard[mac] = entry

            guard let setup = setups[mac], let sensor = sensors[mac], !context.isExcluded(mac) else { continue }
            if let last = lastFrames[mac], last.frame == frame, now - last.at < Self.duplicateWindow { continue }
            lastFrames[mac] = (frame, now)
            framesRead += 1
            do {
                guard let decoded = try BluetoothDecoders.decode(advertisement, as: setup.format, key: setup.key, name: name) else { continue }
                // Checked once the frame is authentic, so a forged one cannot move it. A sensor unheard for `timeout` may
                // have restarted its counter.
                if let counter = decoded.counter {
                    if let last = counters[mac], counter <= last.value, now - last.at < timeout {
                        logger.debug("Ignoring a replayed frame of \(mac)")
                        continue
                    }
                    counters[mac] = (counter, now)
                }
                sensor.show(decoded.readings, model: entry.recognition.model, at: now)
                warnedKeys.remove(mac)
            } catch BluetoothDecodeError.wrongKey {
                if warnedKeys.insert(mac).inserted { logger.warning("The bindkey of \(mac) does not open its advertisements: set it up again") }
            } catch BluetoothDecodeError.unencrypted {
                logger.debug("Ignoring an open frame of \(mac): it is set up with a bindkey")
            } catch BluetoothDecodeError.needsKey {
                if warnedKeys.insert(mac).inserted { logger.warning("\(mac) encrypts its advertisements: set it up again to give its bindkey") }
            } catch {
                logger.debug("Ignoring a frame of \(mac): \(error)")
            }
        }
    }

    /// A sender's name, the names of senders neither heard nor set up let go when there are `capacity` of them.
    private func remember(_ name: String, of mac: String) {
        if names[mac] == nil, names.count >= Self.capacity {
            names = names.filter { heard[$0.key] != nil || setups[$0.key] != nil }
            guard names.count < Self.capacity else { return }
        }
        names[mac] = name
    }

    private func evictIfFull() {
        guard heard.count >= Self.capacity,
              let oldest = heard.values.lazy.filter({ self.setups[$0.mac] == nil }).min(by: { $0.lastSeen < $1.lastSeen }) else { return }
        heard.removeValue(forKey: oldest.mac)
        names.removeValue(forKey: oldest.mac)
    }

    /// Marks No Response each sensor not heard for `timeout`.
    func checkReachability() {
        let now = clock.now
        for sensor in sensors.values { sensor.updateReachability(now: now, timeout: timeout) }
    }

    /// The senders heard, each with whether it was heard within `timeout`.
    func discovered() -> [(heard: Heard, reachable: Bool)] {
        let now = clock.now
        return heard.values.map { ($0, now - $0.lastSeen <= timeout) }
    }

    /// What the plugin knows of a sender's frames, when it has heard it.
    func recognition(of mac: String) -> BluetoothRecognition? { heard[mac]?.recognition }

    /// Checks a bindkey against the sender's last advertisement.
    func check(key: [UInt8]?, for mac: String) throws -> BluetoothRecognition {
        guard let entry = heard[mac] else { throw BluetoothDecodeError.unsupported }
        _ = try BluetoothDecoders.decode(entry.encryptedAdvertisement ?? entry.advertisement, as: entry.recognition.format, key: key, name: entry.name)
        return entry.recognition
    }
}

/// One Bluetooth sensor's accessory: a service for each value it has sent, added as they first come. Owned and called
/// by `BluetoothHub` alone, whose isolation keeps it.
final class BluetoothSensor {
    /// What the accessory shows, in the order of its services.
    enum Capability: Sendable, CaseIterable {
        case temperature, humidity, illuminance, carbonDioxide, motion, occupancy, contact, leak, smoke, carbonMonoxide, battery

        var optional: [CharacteristicType] {
            switch self {
            case .battery: [.batteryLevel, .chargingState]
            case .carbonDioxide: [.carbonDioxideLevel]
            default: []
            }
        }

        var serviceType: ServiceType {
            switch self {
            case .temperature: .temperatureSensor
            case .humidity: .humiditySensor
            case .illuminance: .lightSensor
            case .carbonDioxide: .carbonDioxideSensor
            case .motion: .motionSensor
            case .occupancy: .occupancySensor
            case .contact: .contactSensor
            case .leak: .leakSensor
            case .smoke: .smokeSensor
            case .carbonMonoxide: .carbonMonoxideSensor
            case .battery: .battery
            }
        }

        var name: String {
            switch self {
            case .temperature: "Temperature"
            case .humidity: "Humidity"
            case .illuminance: "Light"
            case .carbonDioxide: "Carbon Dioxide"
            case .motion: "Motion"
            case .occupancy: "Occupancy"
            case .contact: "Contact"
            case .leak: "Leak"
            case .smoke: "Smoke"
            case .carbonMonoxide: "Carbon Monoxide"
            case .battery: "Battery"
            }
        }

        static func of(_ readings: BluetoothReadings) -> Set<Capability> {
            var found = Set<Capability>()
            if readings.temperature != nil { found.insert(.temperature) }
            if readings.humidity != nil { found.insert(.humidity) }
            if readings.illuminance != nil { found.insert(.illuminance) }
            if readings.carbonDioxide != nil { found.insert(.carbonDioxide) }
            if readings.motion != nil { found.insert(.motion) }
            if readings.occupancy != nil { found.insert(.occupancy) }
            if readings.open != nil { found.insert(.contact) }
            if readings.leak != nil { found.insert(.leak) }
            if readings.smoke != nil { found.insert(.smoke) }
            if readings.carbonMonoxide != nil { found.insert(.carbonMonoxide) }
            if readings.battery != nil || readings.lowBattery != nil { found.insert(.battery) }
            return found
        }
    }

    let setup: BluetoothSensorSetup
    private let context: PluginContext
    private var accessory: Accessory?
    private var capabilities = Set<Capability>()
    private var buttonCount = 0
    private var model: String?
    private var lastHeard: ContinuousClock.Instant
    private var unavailable = false

    init(setup: BluetoothSensorSetup, context: PluginContext, heardAt: ContinuousClock.Instant) {
        self.setup = setup
        self.context = context
        lastHeard = heardAt
    }

    /// `esphome:ble@<MAC>`: the shape of an entity's `<name>@<MAC>`, whose MAC is its Device Id.
    var id: String { "\(ESPHomePlugin.platform):\(Self.idPrefix)\(setup.mac)" }
    static let idPrefix = "ble@"

    /// The Serial Number: the MAC, uppercase, without separators.
    static func serialNumber(_ mac: String) -> String { mac.replacingOccurrences(of: ":", with: "") }

    /// The cached accessory, rebuilt with the services it had.
    func restore() {
        guard let cached = context.accessory(id: id) else { return }
        for capability in Capability.allCases where cached.services.contains(where: { $0.type.uuid == capability.serviceType.uuid }) {
            capabilities.insert(capability)
        }
        buttonCount = cached.services.filter { $0.type.uuid == ServiceType.statelessProgrammableSwitch.uuid }.count
        model = cached.information.characteristic(.model).value.stringValue
        guard !capabilities.isEmpty || buttonCount > 0 else { return }
        publish(from: cached)
    }

    func show(_ readings: BluetoothReadings, model heardModel: String?, at now: ContinuousClock.Instant) {
        lastHeard = now
        let wanted = capabilities.union(Capability.of(readings))
        if wanted != capabilities || readings.buttons.count > buttonCount || accessory == nil || (heardModel != nil && heardModel != model) {
            guard !wanted.isEmpty || readings.buttons.count > buttonCount || buttonCount > 0 else { return }
            capabilities = wanted
            buttonCount = max(buttonCount, readings.buttons.count)
            model = heardModel ?? model
            publish(from: accessory ?? context.accessory(id: id))
        }
        guard let accessory else { return }
        if unavailable {
            unavailable = false
            accessory.isUnavailable = false
        }
        apply(readings, to: accessory)
    }

    func updateReachability(now: ContinuousClock.Instant, timeout: Duration) {
        markUnavailable(now - lastHeard > timeout, timeout: timeout)
    }

    /// No Response, or back; logged once when it goes.
    func markUnavailable(_ gone: Bool, timeout: Duration? = nil) {
        guard gone != unavailable, let accessory else { return }
        unavailable = gone
        accessory.isUnavailable = gone
        guard gone, let timeout else { return }
        let seconds = timeout.components.seconds
        let span = seconds >= 120 ? "\(seconds / 60) minutes" : "\(seconds) seconds"
        context.logger.info("\(accessory.name) has not been heard for \(span): No Response")
    }

    private func publish(from previous: Accessory?) {
        var services: [Service] = []
        for capability in Capability.allCases where capabilities.contains(capability) {
            let service = Service(
                capability.serviceType, name: capability.name, optional: capability.optional, isPrimary: services.isEmpty && capability != .battery)
            switch capability {
            case .battery:
                service[.chargingState]?.value = .int(HAPConstants.ChargingState.notChargeable)
            case .illuminance:
                service.characteristic(.currentAmbientLightLevel).value = .double(0.0001)
            default:
                break
            }
            services.append(service)
        }
        if buttonCount > 0 {
            for number in 1...buttonCount {
                let button = Service(.statelessProgrammableSwitch, name: buttonCount == 1 ? "Button" : "Button \(number)", subtype: "button\(number)",
                                     optional: [.serviceLabelIndex], isPrimary: services.isEmpty && number == 1)
                button[.serviceLabelIndex]?.value = .int(number)
                services.append(button)
            }
            let label = Service(.serviceLabel, subtype: "buttons")
            label.characteristic(.serviceLabelNamespace).value = .int(HAPConstants.ServiceLabelNamespace.arabicNumerals)
            services.append(label)
        }
        let serial = Self.serialNumber(setup.mac)
        let manufacturer = setup.format.manufacturer
        let model = model ?? manufacturer
        let category: AccessoryCategory = buttonCount > 0 && capabilities.isEmpty ? .programmableSwitch : .sensor
        let accessory = Accessory(
            id: id, name: "\(model) \(serial.suffix(4))", manufacturer: manufacturer, model: model,
            serialNumber: serial, firmwareRevision: "1.0.0", category: category, services: services)
        if let previous { accessory.takeValues(from: previous) }
        if unavailable { accessory.isUnavailable = true }
        do {
            try context.add(accessory)
            self.accessory = accessory
        } catch {
            context.logger.error("Could not add \(accessory.name): \(error)")
        }
    }

    private func apply(_ readings: BluetoothReadings, to accessory: Accessory) {
        func service(_ capability: Capability) -> Service? {
            accessory.services.first { $0.type.uuid == capability.serviceType.uuid }
        }
        if let value = readings.temperature, value.isFinite {
            service(.temperature)?.characteristic(.currentTemperature).value = .double((min(max(value, -270), 100) * 100).rounded() / 100)
        }
        if let value = readings.humidity, value.isFinite {
            service(.humidity)?.characteristic(.currentRelativeHumidity).value = .double(min(max(value, 0), 100))
        }
        if let value = readings.illuminance, value.isFinite {
            service(.illuminance)?.characteristic(.currentAmbientLightLevel).value = .double(min(max(value, 0.0001), 100_000))
        }
        if let value = readings.carbonDioxide, let co2 = service(.carbonDioxide) {
            co2[.carbonDioxideLevel]?.value = .double(min(max(value, 0), 100_000))
            co2.characteristic(.carbonDioxideDetected).value = .int(value >= 1200 ? 1 : 0)
        }
        if let value = readings.motion { service(.motion)?.characteristic(.motionDetected).value = .bool(value) }
        if let value = readings.occupancy { service(.occupancy)?.characteristic(.occupancyDetected).value = .int(value ? 1 : 0) }
        // Contact Sensor State: 0 when the contact is made (closed), 1 when open.
        if let value = readings.open { service(.contact)?.characteristic(.contactSensorState).value = .int(value ? 1 : 0) }
        if let value = readings.leak { service(.leak)?.characteristic(.leakDetected).value = .int(value ? 1 : 0) }
        if let value = readings.smoke { service(.smoke)?.characteristic(.smokeDetected).value = .int(value ? 1 : 0) }
        if let value = readings.carbonMonoxide { service(.carbonMonoxide)?.characteristic(.carbonMonoxideDetected).value = .int(value ? 1 : 0) }
        if let battery = service(.battery) {
            if let level = readings.battery { battery[.batteryLevel]?.value = .int(min(max(level, 0), 100)) }
            let low = readings.lowBattery ?? readings.battery.map { $0 < 20 }
            if let low { battery.characteristic(.statusLowBattery).value = .int(low ? 1 : 0) }
        }
        for (index, event) in readings.buttons.enumerated() {
            guard let event, let button = accessory.services.first(where: { $0.subtype == "button\(index + 1)" }) else { continue }
            button.characteristic(.programmableSwitchEvent).sendEvent(.int(event.rawValue))
        }
    }
}
