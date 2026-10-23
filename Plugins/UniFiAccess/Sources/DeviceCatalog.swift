import Foundation

/// The terminal inputs of Access hubs: door position, remote release, request to enter, request to exit.
enum SensorInput: String, Sendable, CaseIterable {
    case dps = "Dps", rel = "Rel", ren = "Ren", rex = "Rex"

    /// The feature option suffix: `Hub.DPS`, `Log.REX`.
    var optionName: String { rawValue.uppercased() }
    /// The contact sensor's subtype.
    var reservedName: AccessReservedName {
        switch self {
        case .dps: .contactDPS
        case .rel: .contactREL
        case .ren: .contactREN
        case .rex: .contactREX
        }
    }

    var label: String {
        switch self {
        case .dps: "Door Position Sensor"
        case .rel: "Remote Release"
        case .ren: "Request to Enter Sensor"
        case .rex: "Request to Exit Sensor"
        }
    }

    /// The MQTT topic.
    var topic: String { rawValue.lowercased() }
}

/// Service subtypes and accessory groups, as the Homebridge plugin named them (`AccessReservedNames`).
enum AccessReservedName: String, Sendable, CaseIterable {
    case contactDPS = "ContactSensor.DPS"
    case contactDPSSide = "ContactSensor.DPS.Side"
    case contactREL = "ContactSensor.REL"
    case contactREN = "ContactSensor.REN"
    case contactREX = "ContactSensor.REX"
    case lockDoorSide = "Lock.Door.Side"
    case accessMethodFace = "AccessMethod.Face"
    case accessMethodHand = "AccessMethod.Hand"
    case accessMethodMobile = "AccessMethod.Mobile"
    case accessMethodNFC = "AccessMethod.NFC"
    case accessMethodPIN = "AccessMethod.PIN"
    case accessMethodQR = "AccessMethod.QR"
    case accessMethodTouchPass = "AccessMethod.TouchPass"
    case doorbellTrigger = "DoorbellTrigger"
    case lockDoorSideTrigger = "Switch.Lock.Door.Side.Trigger"
    case lockTrigger = "LockTrigger"

    static let contactSensors: [AccessReservedName] = [.contactDPS, .contactDPSSide, .contactREL, .contactREN, .contactREX]
}

/// The UniFi Access event types the plugin follows.
enum AccessEventType {
    static let deviceDelete = "access.data.device.delete"
    static let deviceRemoteUnlock = "access.data.device.remote_unlock"
    static let deviceUpdate = "access.data.device.update"
    static let deviceUpdateV2 = "access.data.v2.device.update"
    static let doorbellCancel = "access.remote_view.change"
    static let doorbellRing = "access.remote_view"
    static let locationUpdate = "access.data.v2.location.update"
}

/// What the plugin knows about each model (`access-device-catalog.ts`), keyed by `device_type`.
struct DeviceCatalogEntry: Sendable, Equatable {
    struct Sensor: Sendable, Equatable {
        /// Where the input's state is in `configs`.
        var configKey: String?
        /// For models with one input that is either DPS or REX (UA Ultra): the `rex_button_mode` value that selects it.
        var proxyMode: String?
        /// Configs that must all be `on` for the input to count as wired.
        var wiringKeys: [String]?
    }

    struct SideDoor: Sendable, Equatable {
        var dps: Sensor
        var lockRelayConfigKey: String
    }

    enum DoorService: String, Sendable { case lock = "Lock", garageDoorOpener = "GarageDoorOpener" }

    /// Multi-door devices (UA Hub Enterprise): one HomeKit identity per door, the port appended to the MAC.
    var appendsSourceId: Bool
    var defaultDoorService: DoorService
    var displayModel: String
    var lockRelayConfigKey: String
    /// The terminal inputs the model has.
    var sensors: [SensorInput: Sensor]
    var sideDoor: SideDoor?
    /// The controller sends no v1 lock or DPS events for it (UA Gate).
    var skipsV1LockEvents: Bool
    /// Access methods change through `/configs?is_camera=true` rather than `/settings`.
    var usesConfigsApi: Bool
    /// Doors unlock through the location endpoint rather than the device's.
    var usesLocationApi: Bool

    func has(_ input: SensorInput) -> Bool { sensors[input] != nil }
    var supportsSideDoor: Bool { sideDoor != nil }
    /// One input that is either DPS or REX, as `rex_button_mode` says (UA Ultra).
    var usesProxyMode: Bool { sensors.values.contains { $0.proxyMode != nil } }
}

enum DeviceCatalog {
    /// UA Gate's relays and ports, for telling its two doors apart.
    static let gateMainPortSourceId = "port1"
    static let gateSidePortSourceId = "port2"
    static let gateMainDoorTargetName = "oper1"
    static let gateSideDoorTargetName = "oper2"

    /// Every model the plugin knows, in the order the Homebridge plugin listed them.
    static let order = ["UA-Hub-Door-Mini", "UA-ULTRA", "UAH", "UAH-Ent", "UGT", "UVC G6 Entry"]

    private static let hubSensors: [SensorInput: DeviceCatalogEntry.Sensor] = [
        .dps: .init(configKey: "input_state_dps", wiringKeys: ["wiring_state_dps-neg", "wiring_state_dps-pos"]),
        .rel: .init(configKey: "input_state_rel", wiringKeys: ["wiring_state_rel-neg", "wiring_state_rel-pos"]),
        .ren: .init(configKey: "input_state_ren", wiringKeys: ["wiring_state_ren-neg", "wiring_state_ren-pos"]),
        .rex: .init(configKey: "input_state_rex", wiringKeys: ["wiring_state_rex-neg", "wiring_state_rex-pos"]),
    ]

    static let entries: [String: DeviceCatalogEntry] = [
        "UA-Hub-Door-Mini": DeviceCatalogEntry(
            appendsSourceId: false, defaultDoorService: .lock, displayModel: "UA Hub Door Mini",
            lockRelayConfigKey: "output_d1_lock_relay",
            sensors: [
                .dps: .init(configKey: "input_d1_dps", wiringKeys: ["wiring_state_d1-dps-neg", "wiring_state_d1-dps-pos"]),
                .rex: .init(configKey: "input_d1_button", wiringKeys: ["wiring_state_d1-button-neg", "wiring_state_d1-button-pos"]),
            ],
            sideDoor: nil, skipsV1LockEvents: false, usesConfigsApi: false, usesLocationApi: false),
        "UA-ULTRA": DeviceCatalogEntry(
            appendsSourceId: false, defaultDoorService: .lock, displayModel: "UA Ultra",
            lockRelayConfigKey: "output_d1_lock_relay",
            sensors: [.dps: .init(configKey: "input_d1_dps", proxyMode: "dps"), .rex: .init(configKey: "input_d1_button", proxyMode: "rex")],
            sideDoor: nil, skipsV1LockEvents: false, usesConfigsApi: false, usesLocationApi: false),
        "UAH": DeviceCatalogEntry(
            appendsSourceId: false, defaultDoorService: .lock, displayModel: "UA Hub",
            lockRelayConfigKey: "input_state_rly-lock_dry", sensors: hubSensors,
            sideDoor: nil, skipsV1LockEvents: false, usesConfigsApi: false, usesLocationApi: false),
        "UAH-Ent": DeviceCatalogEntry(
            appendsSourceId: true, defaultDoorService: .lock, displayModel: "UA Hub Enterprise",
            lockRelayConfigKey: "input_state_rly-lock_dry", sensors: hubSensors,
            sideDoor: nil, skipsV1LockEvents: false, usesConfigsApi: false, usesLocationApi: false),
        "UGT": DeviceCatalogEntry(
            appendsSourceId: false, defaultDoorService: .garageDoorOpener, displayModel: "UA Gate",
            lockRelayConfigKey: "output_oper1_relay",
            sensors: [.dps: .init(configKey: "input_gate_dps", wiringKeys: ["wiring_state_gate-dps-neg", "wiring_state_gate-dps-pos"])],
            sideDoor: .init(
                dps: .init(configKey: "input_door_dps", wiringKeys: ["wiring_state_door-dps-neg", "wiring_state_door-dps-pos"]), lockRelayConfigKey: "output_oper2_relay"),
            skipsV1LockEvents: true, usesConfigsApi: false, usesLocationApi: true),
        "UVC G6 Entry": DeviceCatalogEntry(
            appendsSourceId: false, defaultDoorService: .lock, displayModel: "UVC G6 Entry",
            lockRelayConfigKey: "input_state_rly-lock_dry", sensors: [:],
            sideDoor: nil, skipsV1LockEvents: false, usesConfigsApi: true, usesLocationApi: false),
    ]

    static func entry(_ deviceType: String) -> DeviceCatalogEntry? { entries[deviceType] }

    /// The id a device has in feature options and MQTT topics: its MAC without separators, and for devices with
    /// several doors (UA Hub Enterprise) the port it is bound to.
    static func deviceIdentifier(deviceType: String, mac: String, sourceId: String?) -> String {
        let base = mac.replacingOccurrences(of: ":", with: "")
        if entry(deviceType)?.appendsSourceId == true, let sourceId, !sourceId.isEmpty { return "\(base)-\(sourceId.uppercased())" }
        return base
    }

    private static func models(_ predicate: (DeviceCatalogEntry) -> Bool) -> [String] {
        order.compactMap { entries[$0] }.filter(predicate).map(\.displayModel)
    }

    // The models each feature option applies to, for the settings page.
    static let modelsDps = models { $0.has(.dps) }
    static let modelsRel = models { $0.has(.rel) }
    static let modelsRen = models { $0.has(.ren) }
    static let modelsRex = models { $0.has(.rex) }
    static let modelsSideDoor = models(\.supportsSideDoor)
    static let modelsSensors = models { !$0.sensors.isEmpty || $0.supportsSideDoor }
    static let modelsDefaultGarageDoor = models { $0.defaultDoorService == .garageDoorOpener }
    static let modelsDefaultLock = models { $0.defaultDoorService == .lock && !$0.appendsSourceId && !$0.usesConfigsApi }
}
