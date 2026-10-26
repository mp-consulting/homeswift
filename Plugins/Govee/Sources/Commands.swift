import Foundation
import HomeswiftPlugin

/// A command for a device, before it is encoded for a transport (`DeviceCommand` of the Homebridge plugin).
enum DeviceCommand: Sendable, Equatable {
    /// Lights: on or off.
    case state(Bool)
    /// Percent.
    case brightness(Int)
    case color(RGB)
    /// Kelvin.
    case colorTem(Int)
    /// Plugs and everything shown as one: on or off.
    case stateOutlet(Bool)
    /// Humidifiers, dehumidifiers and diffusers.
    case stateHumi(Bool)
    /// A multi-outlet `stateDual` value: the channels addressed in the high nibble, which are on in the low.
    case stateDual(Int)
    /// Purifiers.
    case statePuri(Bool)
    /// Heaters of the H7131 family.
    case stateHeat(Bool)
    /// A frame for devices that take `multiSync` over AWS.
    case multiSync(String)
    /// A frame (base64).
    case ptReal(String)
    /// A scene: its comma-separated frames, and those to use over BLE when they differ.
    case rgbScene(code: String, bleCode: String?)
    case musicMode(SceneCodes.MusicMode)

    /// The command's name, as the Homebridge plugin calls it.
    var name: String {
        switch self {
        case .state: "state"
        case .brightness: "brightness"
        case .color: "color"
        case .colorTem: "colorTem"
        case .stateOutlet: "stateOutlet"
        case .stateHumi: "stateHumi"
        case .stateDual: "stateDual"
        case .statePuri: "statePuri"
        case .stateHeat: "stateHeat"
        case .multiSync: "multiSync"
        case .ptReal: "ptReal"
        case .rgbScene: "rgbScene"
        case .musicMode: "musicMode"
        }
    }

    /// A light's colour mode: a newer command of this kind makes a queued older one obsolete.
    var setsColourMode: Bool {
        switch self {
        case .color, .colorTem, .rgbScene, .musicMode: true
        default: false
        }
    }
}

/// An AWS IoT command: `{ cmd, data }` inside the message's `msg`.
struct AWSParams: Sendable, Equatable {
    var cmd: String
    var data: JSONValue
}

/// A LAN command, sent as `{ msg: { cmd, data } }` to port 4003.
struct LANParams: Sendable, Equatable {
    var cmd: String
    var data: JSONValue
}

/// A BLE write: one frame `0x33, cmd, data…` with its checksum, or frames given whole (base64).
enum BLEParams: Sendable, Equatable {
    case command(UInt8, [Int])
    case ptReal([String])

    /// The frames to write, in order, over one connection.
    var frames: [[UInt8]] {
        switch self {
        case .command(let command, let data): [Govee.codeBytes([0x33, Int(command)] + data)]
        case .ptReal(let frames): frames.map { Govee.bytes(base64: $0) }
        }
    }
}

/// A command encoded for each transport; nil where the command has no form for it.
struct TransportCommands: Sendable, Equatable {
    var aws: AWSParams?
    var ble: BLEParams?
    var lan: LANParams?

    /// Per-device settings that change the encoding.
    struct Options: Sendable, Equatable {
        var awsBrightnessNoScale = false
        var awsColourMode = "default"
        /// Scenes, DIY effects and music mode go over LAN too, as `ptReal` with the frames the cloud takes. Off by
        /// default: LAN commands are not acknowledged, so a model that ignores them would not fall back.
        var lanScenes = false
    }

    /// `buildTransportCommands`: the command for AWS, BLE and LAN. `model` in any case.
    init(_ command: DeviceCommand, model: String, options: Options = Options()) {
        let model = model.uppercased()
        switch command {
        case .state(let on):
            aws = AWSParams(cmd: "turn", data: ["val": .number(on ? 1 : 0)])
            ble = .command(0x01, [on ? 0x1 : 0x0])
            lan = LANParams(cmd: "turn", data: ["value": .number(on ? 1 : 0)])
        case .brightness(let value):
            aws = AWSParams(cmd: "brightness", data: ["val": .number(Double(options.awsBrightnessNoScale ? value : Govee.roundInt(Double(value) * 2.54)))])
            ble = .command(0x04, [GoveeConstants.bleBrightnessNoScale.contains(model) ? value : Int((Double(value) / 100 * 0xFF).rounded(.down))])
            lan = LANParams(cmd: "brightness", data: ["value": .number(Double(value))])
        case .color(let rgb):
            // Some older models take only the legacy `color` command, in one of two shapes.
            switch options.awsColourMode {
            case "rgb": aws = AWSParams(cmd: "color", data: Self.json(rgb))
            case "redgreenblue": aws = AWSParams(cmd: "color", data: ["red": .number(Double(rgb.r)), "green": .number(Double(rgb.g)), "blue": .number(Double(rgb.b))])
            default: aws = AWSParams(cmd: "colorwc", data: ["color": Self.json(rgb), "colorTemInKelvin": 0])
            }
            ble = .command(0x05, Self.bleColourData(model: model, rgb))
            lan = LANParams(cmd: "colorwc", data: ["color": Self.json(rgb), "colorTemInKelvin": 0])
        case .colorTem(let kelvin):
            let rgb = Colour.k2rgb(Double(kelvin))
            aws = AWSParams(cmd: "colorwc", data: ["color": Self.json(rgb), "colorTemInKelvin": .number(Double(kelvin))])
            ble = .command(0x05, [0x02, 0xFF, 0xFF, 0xFF, 0x01, rgb.r, rgb.g, rgb.b])
            lan = LANParams(cmd: "colorwc", data: ["color": Self.json(rgb), "colorTemInKelvin": .number(Double(kelvin))])
        case .stateOutlet(let on):
            let value = GoveeConstants.awsOutlet1617.contains(model) ? (on ? 17 : 16) : (on ? 1 : 0)
            aws = AWSParams(cmd: "turn", data: ["val": .number(Double(value))])
        case .stateHumi(let on):
            aws = AWSParams(cmd: "turn", data: ["val": .number(on ? 1 : 0)])
        case .stateDual(let value):
            aws = AWSParams(cmd: "turn", data: ["val": .number(Double(value))])
        case .statePuri(let on):
            // The Homebridge plugin had no encoding for these three (they failed with "Invalid command");
            // these are the encodings of the original homebridge-govee it was forked from.
            aws = AWSParams(cmd: "turn", data: ["val": .number(on ? 1 : 0)])
        case .stateHeat(let on):
            let code = Catalog.deviceStateCodes[on ? "on" : "off"]!
            aws = AWSParams(cmd: "multiSync", data: ["command": [.string(code)]])
            ble = .ptReal([code])
        case .multiSync(let code):
            aws = AWSParams(cmd: "multiSync", data: ["command": [.string(code)]])
        case .ptReal(let code):
            aws = AWSParams(cmd: "ptReal", data: ["command": [.string(code)]])
            ble = .ptReal([code])
        case .rgbScene(let code, let bleCode):
            // A scene is a sequence of 20-byte frames: AWS takes them in one message, BLE writes them in order.
            let awsFrames = SceneCodes.codeToFrames(code)
            let bleFrames = SceneCodes.codeToFrames(bleCode?.isEmpty == false ? bleCode! : code)
            if !awsFrames.isEmpty { aws = AWSParams(cmd: "ptReal", data: ["command": .array(awsFrames.map(JSONValue.string))]) }
            if !bleFrames.isEmpty { ble = .ptReal(bleFrames) }
        case .musicMode(let mode):
            let frames = SceneCodes.encodeMusicMode(mode)
            aws = AWSParams(cmd: "ptReal", data: ["command": .array(frames.map(JSONValue.string))])
            ble = .ptReal(frames)
        }
        // With LAN scenes, a scene, DIY effect or music mode also goes over LAN, as the same ptReal frames as the cloud's.
        if options.lanScenes, lan == nil, let aws, aws.cmd == "ptReal" { lan = LANParams(cmd: aws.cmd, data: aws.data) }
    }

    init(aws: AWSParams? = nil, ble: BLEParams? = nil, lan: LANParams? = nil) {
        self.aws = aws
        self.ble = ble
        self.lan = lan
    }

    /// The payload of a BLE colour command (opcode 0x05), in its three model-specific shapes.
    static func bleColourData(model: String, _ rgb: RGB) -> [Int] {
        if GoveeConstants.bleColourD.contains(model) { return [0x0D, rgb.r, rgb.g, rgb.b] }
        // Colour for all segments: 15 01, RGB, five unused bytes, then the segment mask.
        if GoveeConstants.bleColour1501.contains(model) { return [0x15, 0x01, rgb.r, rgb.g, rgb.b, 0, 0, 0, 0, 0, 0xFF, 0x7F] }
        return [0x02, rgb.r, rgb.g, rgb.b]
    }

    static func json(_ rgb: RGB) -> JSONValue {
        ["r": .number(Double(rgb.r)), "g": .number(Double(rgb.g)), "b": .number(Double(rgb.b))]
    }
}
