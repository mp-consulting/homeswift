import Foundation

extension DysonPureCoolPlugin {
    /// The platform block of `@mp-consulting/homebridge-dyson-pure-cool`, key for key. Decoding is lenient as
    /// JavaScript was: numbers and booleans may come as strings, a malformed device entry is kept (and skipped
    /// with a message at start) rather than failing the whole block.
    public struct Configuration: Decodable, Sendable {
        public struct Device: Decodable, Sendable {
            public var serial: String?
            public var name: String?
            /// The Dyson product type code (`438`, `527K`).
            public var productType: String?
            /// The local MQTT password from the Dyson cloud.
            public var localCredentials: String?
            /// The older name of `localCredentials`; either works.
            public var credentials: String?
            public var ipAddress: String?
            public var firmwareVersion: String?
            /// Celsius added to the temperature reading.
            public var temperatureOffset: Double?
            /// Percent added to the humidity reading.
            public var humidityOffset: Double?
            public var useFahrenheit: Bool?
            public var isTemperatureIgnored: Bool?
            public var isHumidityIgnored: Bool?
            public var isAirQualityIgnored: Bool?
            public var isHeatingDisabled: Bool?
            /// `thermostat`, `heater-cooler` or `both`.
            public var heatingServiceType: String?
            /// Accepted for compatibility; the Homebridge plugin never read it.
            public var isHeatingSafetyIgnored: Bool?
            public var fullRangeHumidity: Bool?
            public var enableAutoModeWhenActivating: Bool?
            public var enableOscillationWhenActivating: Bool?
            public var enableNightModeWhenActivating: Bool?
            public var isContinuousMonitoringEnabled: Bool?
            public var isNightModeEnabled: Bool?
            public var isJetFocusEnabled: Bool?
            public var isFilterStatusDisabled: Bool?
            public var isHumidifierDisabled: Bool?

            enum CodingKeys: String, CodingKey {
                case serial, name, productType, localCredentials, credentials, ipAddress, firmwareVersion, temperatureOffset, humidityOffset
                case useFahrenheit, isTemperatureIgnored, isHumidityIgnored, isAirQualityIgnored, isHeatingDisabled, heatingServiceType
                case isHeatingSafetyIgnored, fullRangeHumidity, enableAutoModeWhenActivating, enableOscillationWhenActivating
                case enableNightModeWhenActivating, isContinuousMonitoringEnabled, isNightModeEnabled, isJetFocusEnabled
                case isFilterStatusDisabled, isHumidifierDisabled
            }

            public init(serial: String? = nil, name: String? = nil, productType: String? = nil, localCredentials: String? = nil, ipAddress: String? = nil) {
                self.serial = serial
                self.name = name
                self.productType = productType
                self.localCredentials = localCredentials
                self.ipAddress = ipAddress
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                serial = c.lenientString(.serial)
                name = c.lenientString(.name)
                productType = c.lenientString(.productType)
                localCredentials = c.lenientString(.localCredentials)
                credentials = c.lenientString(.credentials)
                ipAddress = c.lenientString(.ipAddress)
                firmwareVersion = c.lenientString(.firmwareVersion)
                temperatureOffset = c.lenientDouble(.temperatureOffset)
                humidityOffset = c.lenientDouble(.humidityOffset)
                useFahrenheit = c.lenientBool(.useFahrenheit)
                isTemperatureIgnored = c.lenientBool(.isTemperatureIgnored)
                isHumidityIgnored = c.lenientBool(.isHumidityIgnored)
                isAirQualityIgnored = c.lenientBool(.isAirQualityIgnored)
                isHeatingDisabled = c.lenientBool(.isHeatingDisabled)
                heatingServiceType = c.lenientString(.heatingServiceType)
                isHeatingSafetyIgnored = c.lenientBool(.isHeatingSafetyIgnored)
                fullRangeHumidity = c.lenientBool(.fullRangeHumidity)
                enableAutoModeWhenActivating = c.lenientBool(.enableAutoModeWhenActivating)
                enableOscillationWhenActivating = c.lenientBool(.enableOscillationWhenActivating)
                enableNightModeWhenActivating = c.lenientBool(.enableNightModeWhenActivating)
                isContinuousMonitoringEnabled = c.lenientBool(.isContinuousMonitoringEnabled)
                isNightModeEnabled = c.lenientBool(.isNightModeEnabled)
                isJetFocusEnabled = c.lenientBool(.isJetFocusEnabled)
                isFilterStatusDisabled = c.lenientBool(.isFilterStatusDisabled)
                isHumidifierDisabled = c.lenientBool(.isHumidifierDisabled)
            }
        }

        public var name: String?
        /// The Dyson account's country; the settings page signs in with it.
        public var countryCode: String?
        public var devices: [Device]?
        /// Seconds to look for devices over mDNS (the Homebridge plugin took milliseconds; both are understood).
        public var discoveryTimeout: Double?
        /// Seconds between state requests, 10 to 300.
        public var pollingInterval: Double?
        /// In the schema, never implemented by the Homebridge plugin; accepted and ignored.
        public var isSingleAccessoryModeEnabled: Bool?
        public var isSingleSensorAccessoryModeEnabled: Bool?
        public var enableTemperature: Bool?
        public var enableHumidity: Bool?
        public var enableAirQuality: Bool?
        public var enableNightMode: Bool?
        /// The settings page writes it; the air purifier's Auto/Manual control is always there.
        public var enableAutoMode: Bool?
        public var enableContinuousMonitoring: Bool?
        public var enableJetFocus: Bool?
        public var enableHeater: Bool?
        public var enableHumidifier: Bool?
        public var enableFilterStatus: Bool?

        enum CodingKeys: String, CodingKey {
            case name, countryCode, devices, discoveryTimeout, pollingInterval, isSingleAccessoryModeEnabled, isSingleSensorAccessoryModeEnabled
            case enableTemperature, enableHumidity, enableAirQuality, enableNightMode, enableAutoMode, enableContinuousMonitoring
            case enableJetFocus, enableHeater, enableHumidifier, enableFilterStatus
        }

        public init(devices: [Device]? = nil) {
            self.devices = devices
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lenientString(.name)
            countryCode = c.lenientString(.countryCode)
            // A device entry that is not an object (null, a string) becomes an empty entry, skipped at start.
            if let list = try? c.decodeIfPresent([Lenient<Device>].self, forKey: .devices) {
                devices = list.map { $0.value ?? Device() }
            } else {
                devices = nil
            }
            discoveryTimeout = c.lenientDouble(.discoveryTimeout)
            pollingInterval = c.lenientDouble(.pollingInterval)
            isSingleAccessoryModeEnabled = c.lenientBool(.isSingleAccessoryModeEnabled)
            isSingleSensorAccessoryModeEnabled = c.lenientBool(.isSingleSensorAccessoryModeEnabled)
            enableTemperature = c.lenientBool(.enableTemperature)
            enableHumidity = c.lenientBool(.enableHumidity)
            enableAirQuality = c.lenientBool(.enableAirQuality)
            enableNightMode = c.lenientBool(.enableNightMode)
            enableAutoMode = c.lenientBool(.enableAutoMode)
            enableContinuousMonitoring = c.lenientBool(.enableContinuousMonitoring)
            enableJetFocus = c.lenientBool(.enableJetFocus)
            enableHeater = c.lenientBool(.enableHeater)
            enableHumidifier = c.lenientBool(.enableHumidifier)
            enableFilterStatus = c.lenientBool(.enableFilterStatus)
        }

        /// The platform's toggles under a device's own settings: a device's key wins, as in the Homebridge
        /// plugin's `mergeDeviceConfig`.
        func merged(_ device: Device) -> Device {
            var merged = device
            if merged.isNightModeEnabled == nil { merged.isNightModeEnabled = enableNightMode }
            if merged.isJetFocusEnabled == nil { merged.isJetFocusEnabled = enableJetFocus }
            if merged.isContinuousMonitoringEnabled == nil { merged.isContinuousMonitoringEnabled = enableContinuousMonitoring }
            if merged.isTemperatureIgnored == nil { merged.isTemperatureIgnored = enableTemperature.map { !$0 } }
            if merged.isHumidityIgnored == nil { merged.isHumidityIgnored = enableHumidity.map { !$0 } }
            if merged.isAirQualityIgnored == nil { merged.isAirQualityIgnored = enableAirQuality.map { !$0 } }
            if merged.isHeatingDisabled == nil { merged.isHeatingDisabled = enableHeater.map { !$0 } }
            if merged.isFilterStatusDisabled == nil { merged.isFilterStatusDisabled = enableFilterStatus.map { !$0 } }
            if merged.isHumidifierDisabled == nil { merged.isHumidifierDisabled = enableHumidifier.map { !$0 } }
            return merged
        }

        /// The mDNS scan's length: seconds, or milliseconds for values over 60 (the Homebridge plugin's unit),
        /// between 1 and 60 seconds; 10 by default.
        var discoveryDuration: Duration {
            guard let value = discoveryTimeout, value > 0 else { return .seconds(10) }
            let seconds = value > 60 ? value / 1000 : value
            return .milliseconds(Int(min(max(seconds, 1), 60) * 1000))
        }
    }
}

/// A device's settings once merged and checked: what the accessory is built from.
struct DeviceOptions: Sendable, Equatable {
    var temperatureOffset = 0.0
    var humidityOffset = 0.0
    var isTemperatureIgnored = false
    var isHumidityIgnored = false
    var isAirQualityIgnored = false
    var useFahrenheit = false
    var isHeatingDisabled = false
    var heatingServiceType = HeatingServiceType.thermostat
    var fullRangeHumidity = false
    var activation = ActivationDefaults()
    var isNightModeEnabled = true
    var isJetFocusEnabled = true
    var isContinuousMonitoringEnabled = false
    /// The filter service is off unless `enableFilterStatus` (or the device's own key) turns it on, as the
    /// settings page writes it; a block without either key keeps the Homebridge plugin's default (shown).
    var isFilterStatusDisabled = false
    var isHumidifierDisabled = false

    enum HeatingServiceType: String, Sendable {
        case thermostat, heaterCooler = "heater-cooler", both
    }

    init() {}

    init(_ device: DysonPureCoolPlugin.Configuration.Device) {
        temperatureOffset = device.temperatureOffset ?? 0
        humidityOffset = device.humidityOffset ?? 0
        isTemperatureIgnored = device.isTemperatureIgnored ?? false
        isHumidityIgnored = device.isHumidityIgnored ?? false
        isAirQualityIgnored = device.isAirQualityIgnored ?? false
        useFahrenheit = device.useFahrenheit ?? false
        isHeatingDisabled = device.isHeatingDisabled ?? false
        heatingServiceType = device.heatingServiceType.flatMap(HeatingServiceType.init(rawValue:)) ?? .thermostat
        fullRangeHumidity = device.fullRangeHumidity ?? false
        activation = ActivationDefaults(
            autoMode: device.enableAutoModeWhenActivating ?? false, oscillation: device.enableOscillationWhenActivating ?? false,
            nightMode: device.enableNightModeWhenActivating ?? false)
        isNightModeEnabled = device.isNightModeEnabled ?? true
        isJetFocusEnabled = device.isJetFocusEnabled ?? true
        isContinuousMonitoringEnabled = device.isContinuousMonitoringEnabled ?? false
        isFilterStatusDisabled = device.isFilterStatusDisabled ?? false
        isHumidifierDisabled = device.isHumidifierDisabled ?? false
    }
}

/// Decodes a value, or nil when it does not fit, so one bad entry does not fail the list.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) { return string }
        if let number = try? decodeIfPresent(Double.self, forKey: key) {
            return number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        }
        return nil
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return number.isFinite ? number : nil }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return Double(string.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let bool = try? decodeIfPresent(Bool.self, forKey: key) { return bool }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            switch string.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0", "": return false
            default: return nil
            }
        }
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return number != 0 }
        return nil
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
