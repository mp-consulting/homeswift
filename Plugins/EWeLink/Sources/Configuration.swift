import Foundation
import HomeswiftPlugin

extension EWeLinkPlugin {
    /// The platform block of `@mp-consulting/homebridge-ewelink`, key for key. Decoding is lenient where
    /// Homebridge was: numbers may be strings, a value of the wrong type is ignored rather than failing the
    /// whole block, and every list may be missing.
    public struct Configuration: Decodable, Sendable, Equatable {
        public var name: String?
        /// The eWeLink account's email or phone number.
        public var username: String?
        /// The account's password, or its base64 encoding.
        public var password: String?
        /// `+1`, `+44`, `+86`...: picks the API region.
        public var countryCode: String?
        /// `auto` (LAN, then the cloud), `lan` or `wan` (cloud only).
        public var mode: String?
        public var language: String?
        public var disableNoResponse: Bool?
        public var hideDevFromHB: Bool?
        public var hideMasters: Bool?
        public var hideFromHB: Bool?
        public var outlineInLog: Bool?
        /// Accessories log their debug lines.
        public var debug: Bool?
        public var debugFakegato: Bool?
        /// No per-device state change lines at info level.
        public var disableDeviceLogging: Bool?
        /// Offline devices read as off instead of "No Response".
        public var offlineAsOff: Bool?
        /// Milliseconds between queued cloud commands (250 by default).
        public var commandQueueInterval: Double?
        /// Cloud commands in flight at once (3 by default).
        public var commandQueueConcurrency: Int?
        public var ignoredHomes: [String]?
        public var httpHost: String?
        public var apiPort: Int?
        public var appId: String?
        public var appSecret: String?
        public var singleDevices: [SingleDevice]?
        public var multiDevices: [MultiDevice]?
        public var thDevices: [ThermostatDevice]?
        public var fanDevices: [FanDevice]?
        public var lightDevices: [LightDevice]?
        public var sensorDevices: [SensorDevice]?
        public var rfDevices: [RFDevice]?
        public var bridgeSensors: [BridgeSensor]?
        public var groups: [Group]?
        public var ignoredDevices: [String]?

        public init() {}

        /// `mode`, `auto` when missing.
        var connectionMode: ConnectionMode { ConnectionMode(rawValue: mode ?? "") ?? .auto }

        enum ConnectionMode: String, Sendable { case auto, lan, wan }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            name = c.string("name")
            username = c.string("username")
            password = c.string("password")
            countryCode = c.string("countryCode")
            mode = c.string("mode")
            language = c.string("language")
            disableNoResponse = c.bool("disableNoResponse")
            hideDevFromHB = c.bool("hideDevFromHB")
            hideMasters = c.bool("hideMasters")
            hideFromHB = c.bool("hideFromHB")
            outlineInLog = c.bool("outlineInLog")
            debug = c.bool("debug")
            debugFakegato = c.bool("debugFakegato")
            disableDeviceLogging = c.bool("disableDeviceLogging")
            offlineAsOff = c.bool("offlineAsOff")
            commandQueueInterval = c.double("commandQueueInterval")
            commandQueueConcurrency = c.int("commandQueueConcurrency")
            ignoredHomes = c.strings("ignoredHomes")
            httpHost = c.string("httpHost")
            apiPort = c.int("apiPort")
            appId = c.string("appId")
            appSecret = c.string("appSecret")
            singleDevices = c.list("singleDevices")
            multiDevices = c.list("multiDevices")
            thDevices = c.list("thDevices")
            fanDevices = c.list("fanDevices")
            lightDevices = c.list("lightDevices")
            sensorDevices = c.list("sensorDevices")
            rfDevices = c.list("rfDevices")
            bridgeSensors = c.list("bridgeSensors")
            groups = c.list("groups")
            ignoredDevices = c.strings("ignoredDevices")
        }

        /// What every per-device entry has.
        public struct SingleDevice: Decodable, Sendable, Equatable {
            public var deviceId: String
            public var label: String?
            public var ipAddress: String?
            public var ignoreDevice: Bool?
            public var disableDeviceLogging: Bool?
            /// `default`, `outlet`, `switch`, `valve`, `sensor`, `heater`, `cooler`, `purifier`, `lock`, `tap`, and the
            /// other simulations (`garage`, `gate`, `blind`, `doorbell`, `p_button`, `tv`, `sensor_leak`...).
            public var showAs: String?
            public var deviceModel: String?
            /// The device whose temperature a heater or cooler simulation follows.
            public var tempSource: String?
            public var humiditySource: String?
            /// Inching: always send "on", toggle the state shown.
            public var isInched: Bool?
            public var showAsInching: Bool?
            /// `motion`, `leak`/`water`, `smoke`/`fire`, `co`, `co2`, `contact`, `occupancy`.
            public var sensorType: String?
            public var sensorInvert: Bool?
            public var operationTime: Double?
            public var operationTimeDown: Double?
            /// Degrees added to an air conditioner's or panel's temperature (multiplied by `offsetFactor` first).
            public var offset: Double?
            public var offsetFactor: Double?
            /// Watts above which an outlet is "in use".
            public var inUsePowerThreshold: Double?
            public var sensorId: String?
            public var showAsMotor: Bool?
            public var showAsEachen: Bool?
            /// No auto-off timer on valves and taps.
            public var disableTimer: Bool?
            public var hideSensor: Bool?
            public var obstructId: String?
            /// The lock simulation's type.
            public var type: String?
            public var lowBattThreshold: Double?
            public var scaleBattery: Bool?
            public var overrideLogging: String?
            public var garageType: String?

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                deviceId = c.string("deviceId") ?? ""
                label = c.string("label")
                ipAddress = c.string("ipAddress")
                ignoreDevice = c.bool("ignoreDevice")
                disableDeviceLogging = c.bool("disableDeviceLogging")
                showAs = c.string("showAs")
                deviceModel = c.string("deviceModel")
                tempSource = c.string("tempSource")
                humiditySource = c.string("humiditySource")
                isInched = c.bool("isInched")
                showAsInching = c.bool("showAsInching")
                sensorType = c.string("sensorType")
                sensorInvert = c.bool("sensorInvert")
                operationTime = c.double("operationTime")
                operationTimeDown = c.double("operationTimeDown")
                offset = c.double("offset")
                offsetFactor = c.double("offsetFactor")
                inUsePowerThreshold = c.double("inUsePowerThreshold")
                sensorId = c.string("sensorId")
                showAsMotor = c.bool("showAsMotor")
                showAsEachen = c.bool("showAsEachen")
                disableTimer = c.bool("disableTimer")
                hideSensor = c.bool("hideSensor")
                obstructId = c.string("obstructId")
                type = c.string("type")
                lowBattThreshold = c.double("lowBattThreshold")
                scaleBattery = c.bool("scaleBattery")
                overrideLogging = c.string("overrideLogging")
                garageType = c.string("garageType")
            }

            init(deviceId: String) {
                self.deviceId = deviceId
            }
        }

        public struct MultiDevice: Decodable, Sendable, Equatable {
            public var deviceId: String
            public var label: String?
            public var ipAddress: String?
            public var ignoreDevice: Bool?
            public var disableDeviceLogging: Bool?
            /// `default`, `outlet`, `switch`, `valve`, `blind`, `garage`, `door`, `window`, `lock`.
            public var showAs: String?
            public var deviceModel: String?
            public var tempSource: String?
            public var humiditySource: String?
            /// Channels to hide: numbers (`1,2`) or full ids (`1000abcdefSW1`), comma separated.
            public var hideChannels: String?
            public var operationTime: Double?
            public var operationTimeDown: Double?
            public var invert: Bool?
            public var sensorId: String?
            public var hideSensor: Bool?
            public var obstructId: String?
            public var type: String?
            public var sensorType: String?
            public var lowBattThreshold: Double?
            public var scaleBattery: Bool?
            public var disableTimer: Bool?
            public var overrideLogging: String?
            /// Inching channels: the master switch is hidden.
            public var inchChannels: Bool?

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                deviceId = c.string("deviceId") ?? ""
                label = c.string("label")
                ipAddress = c.string("ipAddress")
                ignoreDevice = c.bool("ignoreDevice")
                disableDeviceLogging = c.bool("disableDeviceLogging")
                showAs = c.string("showAs")
                deviceModel = c.string("deviceModel")
                tempSource = c.string("tempSource")
                humiditySource = c.string("humiditySource")
                // An array of channels is accepted too.
                hideChannels = c.string("hideChannels") ?? c.strings("hideChannels")?.joined(separator: ",")
                operationTime = c.double("operationTime")
                operationTimeDown = c.double("operationTimeDown")
                invert = c.bool("invert")
                sensorId = c.string("sensorId")
                hideSensor = c.bool("hideSensor")
                obstructId = c.string("obstructId")
                type = c.string("type")
                sensorType = c.string("sensorType")
                lowBattThreshold = c.double("lowBattThreshold")
                scaleBattery = c.bool("scaleBattery")
                disableTimer = c.bool("disableTimer")
                overrideLogging = c.string("overrideLogging")
                inchChannels = c.bool("inchChannels")
            }
        }

        public struct ThermostatDevice: Decodable, Sendable, Equatable {
            public var deviceId: String
            public var label: String?
            public var ipAddress: String?
            public var ignoreDevice: Bool?
            public var disableDeviceLogging: Bool?
            /// `default`, `thermostat`, `heater`, `cooler`, `humidifier`, `dehumidifier` (TH10/TH16).
            public var showAs: String?
            public var deviceModel: String?
            public var showHeatCool: Bool?
            public var hideSwitch: Bool?
            public var tempOffset: Double?
            public var offsetFactor: Double?
            public var humidityOffset: Double?
            public var humidityOffsetFactor: Double?
            public var minTarget: Double?
            public var maxTarget: Double?
            /// Hysteresis of the TH heater and cooler, °C.
            public var targetTempThreshold: Double?
            public var overrideLogging: String?

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                deviceId = c.string("deviceId") ?? ""
                label = c.string("label")
                ipAddress = c.string("ipAddress")
                ignoreDevice = c.bool("ignoreDevice")
                disableDeviceLogging = c.bool("disableDeviceLogging")
                showAs = c.string("showAs")
                deviceModel = c.string("deviceModel")
                showHeatCool = c.bool("showHeatCool")
                hideSwitch = c.bool("hideSwitch")
                tempOffset = c.double("tempOffset")
                offsetFactor = c.double("offsetFactor")
                humidityOffset = c.double("humidityOffset")
                humidityOffsetFactor = c.double("humidityOffsetFactor")
                minTarget = c.double("minTarget")
                maxTarget = c.double("maxTarget")
                targetTempThreshold = c.double("targetTempThreshold")
                overrideLogging = c.string("overrideLogging")
            }
        }

        public struct FanDevice: Decodable, Sendable, Equatable {
            public var deviceId: String
            public var label: String?
            public var ipAddress: String?
            public var ignoreDevice: Bool?
            public var disableDeviceLogging: Bool?
            public var showAs: String?
            public var deviceModel: String?
            /// No Lightbulb for the fan's light.
            public var hideLight: Bool?
            public var overrideLogging: String?

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                deviceId = c.string("deviceId") ?? ""
                label = c.string("label")
                ipAddress = c.string("ipAddress")
                ignoreDevice = c.bool("ignoreDevice")
                disableDeviceLogging = c.bool("disableDeviceLogging")
                showAs = c.string("showAs")
                deviceModel = c.string("deviceModel")
                hideLight = c.bool("hideLight")
                overrideLogging = c.string("overrideLogging")
            }
        }

        public struct LightDevice: Decodable, Sendable, Equatable {
            public var deviceId: String
            public var label: String?
            public var ipAddress: String?
            public var ignoreDevice: Bool?
            public var disableDeviceLogging: Bool?
            /// `fan` shows a dimmer (UIID 36, 44, 57) as a fan.
            public var showAs: String?
            /// `offlineAsOff` on a light shown as a fan shows it off while offline.
            public var deviceModel: String?
            public var brightnessStep: Double?
            public var adaptiveLightingShift: Double?
            public var overrideLogging: String?

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                deviceId = c.string("deviceId") ?? ""
                label = c.string("label")
                ipAddress = c.string("ipAddress")
                ignoreDevice = c.bool("ignoreDevice")
                disableDeviceLogging = c.bool("disableDeviceLogging")
                showAs = c.string("showAs")
                deviceModel = c.string("deviceModel")
                brightnessStep = c.double("brightnessStep")
                adaptiveLightingShift = c.double("adaptiveLightingShift")
                overrideLogging = c.string("overrideLogging")
            }
        }

        public struct SensorDevice: Decodable, Sendable, Equatable {
            public var deviceId: String
            public var label: String?
            public var ipAddress: String?
            public var ignoreDevice: Bool?
            public var disableDeviceLogging: Bool?
            public var showAs: String?
            public var hideTemp: Bool?
            public var hideHumidity: Bool?
            public var hideSwitch: Bool?
            public var tempOffset: Double?
            public var humidityOffset: Double?
            /// Percent under which the battery is low (20 by default).
            public var lowBattery: Double?
            public var hideLongDouble: Bool?
            public var scaleBattery: Bool?
            public var sensorTimeDifference: Double?
            public var deviceModel: String?
            public var overrideLogging: String?

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                deviceId = c.string("deviceId") ?? ""
                label = c.string("label")
                ipAddress = c.string("ipAddress")
                ignoreDevice = c.bool("ignoreDevice")
                disableDeviceLogging = c.bool("disableDeviceLogging")
                showAs = c.string("showAs")
                hideTemp = c.bool("hideTemp")
                hideHumidity = c.bool("hideHumidity")
                hideSwitch = c.bool("hideSwitch")
                tempOffset = c.double("tempOffset")
                humidityOffset = c.double("humidityOffset")
                lowBattery = c.double("lowBattery")
                hideLongDouble = c.bool("hideLongDouble")
                scaleBattery = c.bool("scaleBattery")
                sensorTimeDifference = c.double("sensorTimeDifference")
                deviceModel = c.string("deviceModel")
                overrideLogging = c.string("overrideLogging")
            }
        }

        public struct RFDevice: Decodable, Sendable, Equatable {
            public var deviceId: String
            public var label: String?
            public var ipAddress: String?
            public var ignoreDevice: Bool?
            public var disableDeviceLogging: Bool?
            public var showAs: String?
            public var deviceModel: String?
            public var resetOnStartup: Bool?
            /// Per sub-device settings, by the bridge's button index.
            public var subdevices: [RFSubdevice]?
            public var overrideLogging: String?

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                deviceId = c.string("deviceId") ?? ""
                label = c.string("label")
                ipAddress = c.string("ipAddress")
                ignoreDevice = c.bool("ignoreDevice")
                disableDeviceLogging = c.bool("disableDeviceLogging")
                showAs = c.string("showAs")
                deviceModel = c.string("deviceModel")
                resetOnStartup = c.bool("resetOnStartup")
                subdevices = c.list("subdevices")
                overrideLogging = c.string("overrideLogging")
            }
        }

        public struct RFSubdevice: Decodable, Sendable, Equatable {
            public var index: Int?
            public var label: String?
            /// `motion`, `contact`, `smoke`, `water`, `co`, `co2`, `occupancy`, `button`, `doorbell`, `curtain`, `garage`.
            public var showAs: String?
            /// Seconds a sensor stays triggered (60 by default).
            public var resetTime: Double?
            public var operationTime: Double?
            public var operationTimeDown: Double?
            public var overrideLogging: String?

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                index = c.int("index")
                label = c.string("label")
                showAs = c.string("showAs")
                resetTime = c.double("resetTime")
                operationTime = c.double("operationTime")
                operationTimeDown = c.double("operationTimeDown")
                overrideLogging = c.string("overrideLogging")
            }
        }

        public struct BridgeSensor: Decodable, Sendable, Equatable {
            public var deviceId: String?
            public var fullButtonId: String?
            /// The sub-device's id, e.g. `1000ab23cdSW2`.
            public var fullDeviceId: String?
            public var sensorType: String?
            public var deviceType: String?
            public var type: String?
            public var label: String?
            public var resetTime: Double?
            public var sensorTimeLength: Double?
            public var sensorTimeDifference: Double?
            public var sensorWebHook: String?
            /// `oneButton`, `twoButtons`, `threeButtons`, or a cover simulation: `blind`, `door`, `window`.
            public var curtainType: String?
            public var operationTime: Double?
            public var operationTimeDown: Double?

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                deviceId = c.string("deviceId")
                fullButtonId = c.string("fullButtonId")
                fullDeviceId = c.string("fullDeviceId")
                sensorType = c.string("sensorType")
                deviceType = c.string("deviceType")
                type = c.string("type")
                label = c.string("label")
                resetTime = c.double("resetTime")
                sensorTimeLength = c.double("sensorTimeLength")
                sensorTimeDifference = c.double("sensorTimeDifference")
                sensorWebHook = c.string("sensorWebHook")
                curtainType = c.string("curtainType")
                operationTime = c.double("operationTime")
                operationTimeDown = c.double("operationTimeDown")
            }
        }

        public struct Group: Decodable, Sendable, Equatable {
            public var type: String?
            public var deviceIds: [String]?
            public var label: String?
            public var operationTime: Double?
            public var operationTimeDown: Double?
            public var invert: Bool?
            public var sensorId: String?

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                type = c.string("type")
                deviceIds = c.strings("deviceIds")
                label = c.string("label")
                operationTime = c.double("operationTime")
                operationTimeDown = c.double("operationTimeDown")
                invert = c.bool("invert")
                sensorId = c.string("sensorId")
            }
        }
    }
}

extension EWeLinkPlugin.Configuration {
    func single(_ deviceId: String) -> SingleDevice? { singleDevices?.first { $0.deviceId == deviceId } }
    func multi(_ deviceId: String) -> MultiDevice? { multiDevices?.first { $0.deviceId == deviceId } }
    func thermostat(_ deviceId: String) -> ThermostatDevice? { thDevices?.first { $0.deviceId == deviceId } }
    func fan(_ deviceId: String) -> FanDevice? { fanDevices?.first { $0.deviceId == deviceId } }
    func light(_ deviceId: String) -> LightDevice? { lightDevices?.first { $0.deviceId == deviceId } }
    func sensor(_ deviceId: String) -> SensorDevice? { sensorDevices?.first { $0.deviceId == deviceId } }
    func rf(_ deviceId: String) -> RFDevice? { rfDevices?.first { $0.deviceId == deviceId } }

    func isIgnored(_ deviceId: String) -> Bool { ignoredDevices?.contains(deviceId) ?? false }

    /// The `showAs` of a device's entry in the list of its category.
    func showAs(_ deviceId: String, category: DeviceCategory) -> String? {
        switch category {
        case .singleSwitch: single(deviceId)?.showAs
        case .multiSwitch: multi(deviceId)?.showAs
        case .thermostat: thermostat(deviceId)?.showAs
        case .fan: fan(deviceId)?.showAs
        case .light: light(deviceId)?.showAs
        case .sensor: sensor(deviceId)?.showAs
        case .rfBridge: rf(deviceId)?.showAs
        default: nil
        }
    }

    /// The device's entry in the list of its category, as JSON text: what a handler was built from.
    func entryIdentity(_ deviceId: String, category: DeviceCategory) -> String {
        func text(_ value: (some Encodable)?) -> String { value.flatMap { try? JSONValue(encoding: $0).text() } ?? "null" }
        return switch category {
        case .singleSwitch: text(single(deviceId))
        case .multiSwitch: text(multi(deviceId))
        case .thermostat: text(thermostat(deviceId))
        case .fan: text(fan(deviceId))
        case .light: text(light(deviceId))
        case .sensor: text(sensor(deviceId))
        case .rfBridge: text(rf(deviceId))
        default: "null"
        }
    }
}

// The entries encode back to JSON for handler identities.
extension EWeLinkPlugin.Configuration.SingleDevice: Encodable {}
extension EWeLinkPlugin.Configuration.MultiDevice: Encodable {}
extension EWeLinkPlugin.Configuration.ThermostatDevice: Encodable {}
extension EWeLinkPlugin.Configuration.FanDevice: Encodable {}
extension EWeLinkPlugin.Configuration.LightDevice: Encodable {}
extension EWeLinkPlugin.Configuration.SensorDevice: Encodable {}
extension EWeLinkPlugin.Configuration.RFDevice: Encodable {}
extension EWeLinkPlugin.Configuration.RFSubdevice: Encodable {}

/// Any key, so the decoders can read what they know and ignore the rest.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    private func value(_ key: String) -> JSONValue? {
        guard let value = try? decodeIfPresent(JSONValue.self, forKey: AnyKey(stringValue: key)), !value.isNull else { return nil }
        return value
    }

    /// A string, or a number written without quotes.
    func string(_ key: String) -> String? {
        switch value(key) {
        case .string(let text): text
        case .number(let number): number.jsDescription
        default: nil
        }
    }

    /// A number, or a numeric string.
    func double(_ key: String) -> Double? {
        switch value(key) {
        case .number(let number): number
        case .string(let text): Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    func int(_ key: String) -> Int? { double(key).flatMap { $0.isFinite ? Int($0) : nil } }

    /// A boolean, or `"true"`/`"false"`.
    func bool(_ key: String) -> Bool? {
        switch value(key) {
        case .bool(let flag): flag
        case .string(let text): text == "true" ? true : text == "false" ? false : nil
        case .number(let number): number != 0
        default: nil
        }
    }

    /// A list of strings (numbers allowed); a single string counts as a list of one.
    func strings(_ key: String) -> [String]? {
        switch value(key) {
        case .array(let items): items.compactMap { $0.jsString }
        case .string(let text): [text]
        default: nil
        }
    }

    /// A list of entries; entries that do not decode are skipped.
    func list<T: Decodable>(_ key: String) -> [T]? {
        guard case .array(let items) = value(key) else { return nil }
        return items.compactMap { try? $0.decode(T.self) }
    }
}
