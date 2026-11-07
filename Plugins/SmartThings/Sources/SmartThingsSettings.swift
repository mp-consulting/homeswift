import Foundation
import HomeswiftPlugin

/// The block, read leniently: the option names of homebridge-smartthings-oauth (aziz66) and of
/// homebridge-smartthings-ik both load (docs/clean-room/SmartThings.md, section 2). Every option is optional.
struct SmartThingsSettings: Sendable {
    static let defaultBaseURL = URL(string: "https://api.smartthings.com/v1/")!
    /// The API hosts `BaseURL` may name: SmartThings' own, and its China base (section 2.1).
    static let allowedHosts: Set<String> = ["api.smartthings.com", "api.samsungiotcloud.cn"]
    static let defaultCallbackPort = 8583
    static let pollKeys = [
        "PollLocksSeconds", "PollDoorsSeconds", "PollSensorsSeconds", "PollSecuritySystemsSeconds", "PollSwitchesAndLightsSeconds",
        "PollTelevisionsSeconds", "PollWindowShadesSeconds", "PollEnergySeconds",
    ]
    /// Options of the Homebridge plugins that load and do nothing here (sections 2.1, 2.2, 13.3).
    static let webhookKeys = ["server_url", "webhook_port", "verifyWebhookSignatures", "selectedCapabilities", "WebhookToken"]
    static let ignoredKeys = webhookKeys + [
        "ExposeContactSensorForWashers", "ExposeContactSensorForDryers", "ExposeContactSensorForDishwashers", "removeLegacySwitchForTV",
        "frameTvDevices", "UnregisterAll", "GarageDoorMaxPoll",
    ]
    static let optionalModes = ["None", "Sleep", "Speed", "WindFree", "WindFreeSleep", "Speed and Windfree"]

    var raw: [String: JSONValue]

    init(_ raw: JSONValue, credentials: JSONValue? = nil) {
        var fields = raw.objectValue ?? [:]
        // The client Setup kept in the vault wins over the block's (section 2.3).
        for key in ["client_id", "client_secret"] {
            if let value = Self.text(credentials?[key]) { fields[key] = .string(value) }
        }
        self.raw = fields
    }

    static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    func text(_ key: String) -> String? { Self.text(raw[key]) }

    func flag(_ key: String, default value: Bool = false) -> Bool {
        switch raw[key] {
        case .bool(let flag): flag
        case .string(let text): ["true", "1", "yes"].contains(text.lowercased())
        case .number(let number): number != 0
        default: value
        }
    }

    func integer(_ key: String) -> Int? {
        if let number = raw[key]?.saturatingIntValue { return number }
        return text(key).flatMap { Int($0) }
    }

    func strings(_ key: String) -> [String] {
        (raw[key]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: The account

    var clientID: String? { text("client_id") }
    var clientSecret: String? { text("client_secret") }

    /// `BaseURL`, with a trailing slash, when it is an `https` URL on SmartThings' API hosts; the default when unset.
    var baseURL: URL { (try? checkedBaseURL()) ?? Self.defaultBaseURL }

    struct SettingsError: Error, CustomStringConvertible { var description: String }

    func checkedBaseURL() throws -> URL {
        guard let text = text("BaseURL") else { return Self.defaultBaseURL }
        guard let url = URL(string: text.hasSuffix("/") ? text : text + "/"), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), Self.allowedHosts.contains(host) else {
            throw SettingsError(description: "BaseURL must be an https address on api.smartthings.com or api.samsungiotcloud.cn: \(text) is not used")
        }
        return url
    }

    var callbackServerExternalAddress: String? { text("callbackServerExternalAddress") }
    var callbackServerPort: Int {
        guard let port = integer("callbackServerPort"), (1...65535).contains(port) else { return Self.defaultCallbackPort }
        return port
    }

    var locationID: String? { text("locationId") }

    // MARK: Updates

    /// The poll period (section 5.3): the smallest non-zero `Poll*Seconds` the block has, at least `floor`; `fallback`
    /// when it has none; nil when every one there is 0 (no polling but the slow safety one).
    func pollSeconds(floor: Double = 60, fallback: Double = 300) -> Double? {
        let present = Self.pollKeys.compactMap { key in raw[key] == nil ? nil : integer(key) }
        guard !present.isEmpty else { return fallback }
        let positive = present.filter { $0 > 0 }
        guard let smallest = positive.min() else { return nil }
        return max(Double(smallest), floor)
    }

    var presentIgnoredKeys: [String] { Self.ignoredKeys.filter { raw[$0] != nil && raw[$0]?.isNull == false } }
    var hasWebhookOptions: Bool { Self.webhookKeys.contains { key in raw[key].map { !$0.isNull && $0 != "" } ?? false } }

    // MARK: Accessories

    var registerVolumeSlider: Bool { flag("registerVolumeSlider") }
    var exposeHumidityForAirConditioners: Bool { flag("ExposeHumiditySensorForAirConditioners") }
    var exposeACDisplayLight: Bool { flag("ExposeACDisplayLight") }
    var exposeMultiZoneRefrigerator: Bool { flag("ExposeMultiZoneRefrigerator") }
    var exposeZigbangSmartDoorlock: Bool { flag("ExposeZigbangSmartDoorlock") }
    var exposeEnergyMonitoring: Bool { flag("ExposeEnergyMonitoring") }
    var exposeEnergyAsOutlet: Bool { flag("ExposeEnergyAsOutlet") }
    /// Absent means true here (section 2.1).
    var exposeRobotVacuum: Bool { flag("ExposeRobotVacuum", default: true) }
    var removeLegacySwitchForLaundry: Bool { flag("removeLegacySwitchForLaundry") }
    var enableTelevisionService: Bool { flag("enableTelevisionService", default: true) }
    var publishTVsAsExternal: Bool { flag("publishTVsAsExternal", default: true) }
    var optionalModeForAirConditioners: String {
        let value = text("OptionalModeForAirConditioners") ?? "None"
        return Self.optionalModes.first { $0.caseInsensitiveCompare(value) == .orderedSame } ?? "None"
    }
    var tvApps: [String] { strings("tvApps") }
    var ignoreLocations: [String] { strings("IgnoreLocations") }
    var ignoreDevices: [String] { strings("IgnoreDevices") }
    var showOnlyDevices: [String] { strings("ShowOnlyDevices") }

    struct ModeOverride: Sendable, Equatable {
        var deviceName: String
        var heatMode: String?
        var coolMode: String?
    }

    var thermostatModeOverrides: [ModeOverride] {
        (raw["thermostatModeOverrides"]?.arrayValue ?? []).compactMap { entry in
            guard let name = Self.text(entry["deviceName"]) else { return nil }
            return ModeOverride(deviceName: name, heatMode: Self.text(entry["heatMode"]), coolMode: Self.text(entry["coolMode"]))
        }
    }

    /// Left out by the block's own lists (section 2.4): `ShowOnlyDevices` when it has names, else `IgnoreDevices`, and
    /// `IgnoreLocations` by the names of the locations.
    func excludedByLists(_ device: SmartThingsDevice, locationNames: [String: String]) -> Bool {
        let label = normalizedName(device.label ?? device.name ?? "")
        let shown = showOnlyDevices.map(normalizedName)
        if !shown.isEmpty, !shown.contains(label) { return true }
        if shown.isEmpty, ignoreDevices.map(normalizedName).contains(label) { return true }
        if let location = device.locationID, let name = locationNames[location], ignoreLocations.map(normalizedName).contains(normalizedName(name)) { return true }
        return false
    }

    /// The app ids of `tvApps` with their names (section 2.1).
    static let tvAppNames: [String: String] = [
        "3201907018807": "Netflix", "3201910019365": "Prime Video", "3201512006785": "Prime Video", "111299001912": "YouTube",
        "3201611010983": "YouTube Kids", "3201606009684": "Spotify", "3201901017640": "Disney+", "3201601007625": "Hulu",
        "3201710014981": "Paramount+", "3201807016597": "Apple TV", "3202006020991": "Peacock TV", "3201710015037": "Gallery",
        "3202301029760": "HBO Max", "111477000821": "Shahid", "3201608010191": "Deezer", "3201806016390": "DAZN", "3201708014618": "ESPN",
        "3202410037239": "BeIN Sports", "3201908019041": "Apple Music",
    ]
}

/// A device's Plugin Accessory Settings (`accessorySchema`), with the plugin-wide defaults under them (section 2.4).
struct DeviceOptions: Sendable, Equatable {
    var heatMode = "heat"
    var coolMode = "cool"
    var optionalMode = "None"
    var exposeHumidity = false
    var displayLight = false
    var outlet = false
    var hiddenInputs: [String] = []

    init() {}

    init(settings: SmartThingsSettings, plugin: [String: JSONValue], deviceName: String) {
        optionalMode = settings.optionalModeForAirConditioners
        exposeHumidity = settings.exposeHumidityForAirConditioners
        displayLight = settings.exposeACDisplayLight
        outlet = settings.exposeEnergyAsOutlet
        // The block's thermostatModeOverrides by name until the bridge moves them into `_accessories`.
        if let override = settings.thermostatModeOverrides.first(where: { normalizedName($0.deviceName) == normalizedName(deviceName) }) {
            if let heat = override.heatMode { heatMode = heat }
            if let cool = override.coolMode { coolMode = cool }
        }
        if let heat = SmartThingsSettings.text(plugin["heatMode"]) { heatMode = heat }
        if let cool = SmartThingsSettings.text(plugin["coolMode"]) { coolMode = cool }
        if let mode = SmartThingsSettings.text(plugin["optionalMode"]), SmartThingsSettings.optionalModes.contains(mode) { optionalMode = mode }
        if let flag = plugin["exposeHumidity"]?.boolValue { exposeHumidity = flag }
        if let flag = plugin["displayLight"]?.boolValue { displayLight = flag }
        if let flag = plugin["outlet"]?.boolValue { outlet = flag }
        hiddenInputs = (plugin["hiddenInputs"]?.arrayValue ?? []).compactMap(\.stringValue)
    }
}
