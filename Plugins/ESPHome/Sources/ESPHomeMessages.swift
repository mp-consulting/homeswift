import Foundation
import HomeswiftNetwork

/// The native API's message type ids this plugin reads or writes (ESPHome's `api.proto`); others are ignored.
enum MessageType {
    static let helloRequest = 1
    static let helloResponse = 2
    static let authenticationRequest = 3
    static let authenticationResponse = 4
    static let disconnectRequest = 5
    static let disconnectResponse = 6
    static let pingRequest = 7
    static let pingResponse = 8
    static let deviceInfoRequest = 9
    static let deviceInfoResponse = 10
    static let listEntitiesRequest = 11
    static let listEntitiesDone = 19
    static let subscribeStates = 20
    static let coverCommand = 30
    static let fanCommand = 31
    static let lightCommand = 32
    static let switchCommand = 33
    static let getTimeRequest = 36
    static let getTimeResponse = 37
    static let climateCommand = 48
    static let lockCommand = 60
    static let buttonCommand = 62
}

/// The entity types the plugin maps, with their list and state message ids.
enum EntityKind: String, Sendable, CaseIterable {
    case binarySensor = "binary_sensor"
    case cover
    case fan
    case light
    case sensor
    case `switch`
    case climate
    case lock
    case button

    init?(listType: Int) {
        guard let kind = Self.allCases.first(where: { $0.listType == listType }) else { return nil }
        self = kind
    }

    init?(stateType: Int) {
        guard let kind = Self.allCases.first(where: { $0.stateType == stateType }) else { return nil }
        self = kind
    }

    var listType: Int {
        switch self {
        case .binarySensor: 12
        case .cover: 13
        case .fan: 14
        case .light: 15
        case .sensor: 16
        case .switch: 17
        case .climate: 46
        case .lock: 58
        case .button: 61
        }
    }

    static func entityID(deviceID: UInt32, key: UInt32) -> UInt64 { UInt64(deviceID) << 32 | UInt64(key) }

    /// A state's entity: its key and its sub-device.
    func entityID(ofState state: ProtobufMessage) -> UInt64 {
        let field = switch self {
        case .binarySensor, .sensor: 4
        case .switch, .lock, .button: 3
        case .cover: 6
        case .fan: 8
        case .light: 14
        case .climate: 16
        }
        return Self.entityID(deviceID: state.uint32(field), key: state.fixed32(1))
    }

    /// The `device_id` field of a command, by its type.
    static func deviceIDField(ofCommand type: Int) -> Int? {
        switch type {
        case MessageType.switchCommand: 3
        case MessageType.coverCommand: 9
        case MessageType.fanCommand: 14
        case MessageType.lightCommand: 28
        case MessageType.climateCommand: 24
        case MessageType.lockCommand: 5
        case MessageType.buttonCommand: 2
        default: nil
        }
    }

    /// nil for a button, which has no state.
    var stateType: Int? {
        switch self {
        case .binarySensor: 21
        case .cover: 22
        case .fan: 23
        case .light: 24
        case .sensor: 25
        case .switch: 26
        case .climate: 47
        case .lock: 59
        case .button: nil
        }
    }
}

/// The list types of entities the plugin does not map: they are logged as not supported. Text sensors (18), cameras
/// (43), numbers (49), selects (52), sirens (55), media players (63), alarm panels (94), texts (97), dates and times
/// (100, 103, 112), events (107), valves (109), updates (116), water heaters (132).
let unsupportedListTypes: Set<Int> = [18, 43, 49, 52, 55, 63, 94, 97, 100, 103, 107, 109, 112, 116, 132]

/// HelloResponse, DeviceInfoResponse: what the plugin reads of them.
struct DeviceInfo: Equatable, Sendable {
    var name: String
    var friendlyName: String
    var mac: String
    var model: String
    var manufacturer: String
    var esphomeVersion: String
    /// `uses_password`: older firmware asks for the API password.
    var usesPassword: Bool
    /// `bluetooth_proxy_feature_flags` (`BluetoothProxy`), from `legacy_bluetooth_proxy_version` on older firmware.
    var bluetoothProxyFeatures: UInt32

    /// A Bluetooth proxy: it passes on the advertisements it hears.
    var isBluetoothProxy: Bool { bluetoothProxyFeatures & BluetoothProxy.passiveScanFeature != 0 }
    var sendsRawAdvertisements: Bool { bluetoothProxyFeatures & BluetoothProxy.rawAdvertisementsFeature != 0 }

    init(_ message: ProtobufMessage) {
        usesPassword = message.bool(1)
        name = Sanitized.text(message.string(2), limit: 31)
        mac = Sanitized.text(message.string(3), limit: 17)
        esphomeVersion = Sanitized.text(message.string(4), limit: 32)
        model = Sanitized.text(message.string(6), limit: 64)
        manufacturer = Sanitized.text(message.string(12), limit: 64)
        friendlyName = Sanitized.text(message.string(13))
        // Version 1 of the legacy field scanned passively; later ones connected actively too.
        bluetoothProxyFeatures = message.has(15) ? message.uint32(15) : (message.uint32(11) > 0 ? BluetoothProxy.passiveScanFeature : 0)
    }
}

/// One entity of ListEntities, its message kept for the fields its kind reads.
struct EntityInfo: Equatable, Sendable {
    let kind: EntityKind
    let message: ProtobufMessage

    var objectID: String { message.string(1) }
    var key: UInt32 { message.fixed32(2) }

    /// The sub-device it belongs to (ESPHome's `devices:`); 0 for the main device.
    var deviceID: UInt32 {
        let field = switch kind {
        case .binarySensor, .switch: 10
        case .cover, .fan: 13
        case .light: 16
        case .sensor: 14
        case .climate: 26
        case .lock: 12
        case .button: 9
        }
        return message.uint32(field)
    }

    /// The entity among the device's: its key is unique within its sub-device only.
    var entityID: UInt64 { EntityKind.entityID(deviceID: deviceID, key: key) }
    var name: String { Sanitized.text(message.string(3)) }

    var icon: String {
        switch kind {
        case .binarySensor: message.string(8)
        case .sensor, .switch, .lock, .button: message.string(5)
        case .cover, .fan: message.string(10)
        case .light: message.string(14)
        case .climate: message.string(19)
        }
    }

    var deviceClass: String {
        switch kind {
        case .binarySensor: message.string(5)
        case .cover, .button: message.string(8)
        case .sensor, .switch: message.string(9)
        default: ""
        }
    }

    var unit: String { kind == .sensor ? message.string(6) : "" }

    // Lights.

    /// The color modes, from `supported_color_modes`, or from the legacy flags of older firmware.
    var colorModes: [Int] {
        let modes = message.enumerations(12)
        guard modes.isEmpty else { return modes }
        let brightness = message.bool(5), rgb = message.bool(6), white = message.bool(7), temperature = message.bool(8)
        var mode = ColorMode.onOff
        if brightness { mode |= ColorMode.brightness }
        if rgb { mode |= ColorMode.rgb }
        if white { mode |= ColorMode.white }
        if temperature { mode |= ColorMode.colorTemperature }
        return [mode]
    }

    private func hasColorBit(_ bit: Int) -> Bool { colorModes.contains { $0 & bit != 0 } }
    var supportsBrightness: Bool { hasColorBit(ColorMode.brightness) }
    var supportsRGB: Bool { hasColorBit(ColorMode.rgb) }
    var supportsColorTemperature: Bool { hasColorBit(ColorMode.colorTemperature) || hasColorBit(ColorMode.coldWarmWhite) }
    var minMireds: Float { message.float(9) }
    var maxMireds: Float { message.float(10) }
    var effects: [String] { message.strings(11).map { Sanitized.text($0) } }

    // Covers.

    var supportsPosition: Bool { message.bool(6) }
    var supportsTilt: Bool { message.bool(7) }
    var supportsStop: Bool { message.bool(12) }

    // Fans.

    var supportsOscillation: Bool { message.bool(5) }
    var supportsSpeed: Bool { message.bool(6) }
    var supportsDirection: Bool { message.bool(7) }
    var speedCount: Int { Int(message.int32(8)) }

    // Climates.

    /// The feature flags (bits: 1 current temperature, 2 two-point target, 4 requires two-point, 8 current humidity,
    /// 16 target humidity, 32 action), built from the older booleans when the firmware sends none.
    var climateFeatures: UInt32 {
        if message.has(27) { return message.uint32(27) }
        var flags: UInt32 = 0
        if message.bool(5) { flags |= ClimateFeature.currentTemperature }
        if message.bool(6) { flags |= ClimateFeature.twoPoint | ClimateFeature.requiresTwoPoint }
        if message.bool(22) { flags |= ClimateFeature.currentHumidity }
        if message.bool(23) { flags |= ClimateFeature.targetHumidity }
        if message.bool(12) { flags |= ClimateFeature.action }
        return flags
    }

    var climateModes: [Int] { message.enumerations(7) }
    var visualMinTemperature: Float { message.float(8) }
    var visualMaxTemperature: Float { message.float(9) }
    var visualTemperatureStep: Float { message.float(10) }
    var temperatureUnit: Int { message.enumeration(28) }

    // Locks.

    var supportsOpen: Bool { message.bool(9) }
}

enum ColorMode {
    static let onOff = 1
    static let brightness = 2
    static let white = 4
    static let colorTemperature = 8
    static let coldWarmWhite = 16
    static let rgb = 32
}

enum ClimateFeature {
    static let currentTemperature: UInt32 = 1
    static let twoPoint: UInt32 = 2
    static let requiresTwoPoint: UInt32 = 4
    static let currentHumidity: UInt32 = 8
    static let targetHumidity: UInt32 = 16
    static let action: UInt32 = 32
}

/// The requests the plugin sends, each a frame.
enum ESPHomeRequest {
    static let clientInfo = "homeswift"

    static func hello() -> ESPHomeFrame {
        var body = ProtobufWriter()
        body.string(1, clientInfo)
        body.uint32(2, 1)
        body.uint32(3, 10)
        return ESPHomeFrame(type: MessageType.helloRequest, body: body.bytes)
    }

    static func authentication(password: String) -> ESPHomeFrame {
        var body = ProtobufWriter()
        body.string(1, password)
        return ESPHomeFrame(type: MessageType.authenticationRequest, body: body.bytes)
    }

    static func empty(_ type: Int) -> ESPHomeFrame { ESPHomeFrame(type: type, body: []) }

    static func time(_ date: Date) -> ESPHomeFrame {
        var body = ProtobufWriter()
        body.fixed32(1, UInt32(clamping: Int64(date.timeIntervalSince1970)))
        return ESPHomeFrame(type: MessageType.getTimeResponse, body: body.bytes)
    }

    static func `switch`(key: UInt32, on: Bool) -> ESPHomeFrame {
        var body = ProtobufWriter()
        body.fixed32(1, key)
        body.bool(2, on)
        return ESPHomeFrame(type: MessageType.switchCommand, body: body.bytes)
    }

    static func button(key: UInt32) -> ESPHomeFrame {
        var body = ProtobufWriter()
        body.fixed32(1, key)
        return ESPHomeFrame(type: MessageType.buttonCommand, body: body.bytes)
    }

    static func lock(key: UInt32, lock: Bool) -> ESPHomeFrame {
        var body = ProtobufWriter()
        body.fixed32(1, key)
        body.enumeration(2, lock ? 1 : 0)
        return ESPHomeFrame(type: MessageType.lockCommand, body: body.bytes)
    }

    struct Light {
        var key: UInt32
        var state: Bool?
        var brightness: Float?
        var rgb: (red: Float, green: Float, blue: Float)?
        var colorTemperature: Float?
        var effect: String?
        /// Set with a colour or a temperature, so the light leaves its other mode.
        var colorMode: Int?

        var frame: ESPHomeFrame {
            var body = ProtobufWriter()
            body.fixed32(1, key)
            if let state {
                body.bool(2, true)
                body.bool(3, state)
            }
            if let brightness {
                body.bool(4, true)
                body.float(5, brightness)
            }
            if let rgb {
                body.bool(6, true)
                body.float(7, rgb.red)
                body.float(8, rgb.green)
                body.float(9, rgb.blue)
            }
            if let colorTemperature {
                body.bool(12, true)
                body.float(13, colorTemperature)
            }
            if let effect {
                body.bool(18, true)
                body.string(19, effect)
            }
            if let colorMode {
                body.bool(22, true)
                body.enumeration(23, colorMode)
            }
            return ESPHomeFrame(type: MessageType.lightCommand, body: body.bytes)
        }
    }

    struct Cover {
        var key: UInt32
        var position: Float?
        var tilt: Float?
        var stop = false

        var frame: ESPHomeFrame {
            var body = ProtobufWriter()
            body.fixed32(1, key)
            if let position {
                body.bool(4, true)
                body.float(5, position)
            }
            if let tilt {
                body.bool(6, true)
                body.float(7, tilt)
            }
            body.bool(8, stop)
            return ESPHomeFrame(type: MessageType.coverCommand, body: body.bytes)
        }
    }

    struct Fan {
        var key: UInt32
        var state: Bool?
        var oscillating: Bool?
        var direction: Int?
        var speedLevel: Int?

        var frame: ESPHomeFrame {
            var body = ProtobufWriter()
            body.fixed32(1, key)
            if let state {
                body.bool(2, true)
                body.bool(3, state)
            }
            if let oscillating {
                body.bool(6, true)
                body.bool(7, oscillating)
            }
            if let direction {
                body.bool(8, true)
                body.enumeration(9, direction)
            }
            if let speedLevel {
                body.bool(10, true)
                body.int32(11, Int32(clamping: speedLevel))
            }
            return ESPHomeFrame(type: MessageType.fanCommand, body: body.bytes)
        }
    }

    struct Climate {
        var key: UInt32
        var mode: Int?
        var targetTemperature: Float?
        var targetLow: Float?
        var targetHigh: Float?
        var targetHumidity: Float?

        var frame: ESPHomeFrame {
            var body = ProtobufWriter()
            body.fixed32(1, key)
            if let mode {
                body.bool(2, true)
                body.enumeration(3, mode)
            }
            if let targetTemperature {
                body.bool(4, true)
                body.float(5, targetTemperature)
            }
            if let targetLow {
                body.bool(6, true)
                body.float(7, targetLow)
            }
            if let targetHigh {
                body.bool(8, true)
                body.float(9, targetHigh)
            }
            if let targetHumidity {
                body.bool(22, true)
                body.float(23, targetHumidity)
            }
            return ESPHomeFrame(type: MessageType.climateCommand, body: body.bytes)
        }
    }
}
