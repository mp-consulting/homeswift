import Foundation
import Homeswift
import HomeswiftAI

/// What one gesture of a Remote's Button or Wheel does (GLOSSARY.md, "Control"), a Core Accessory Setting of the Remote
/// (`controls`, docs/adr/0009-remote-controls-are-not-automations.md):
///
/// ```json
/// { "part": "button:6", "gesture": "press", "action": "toggle", "targets": ["Govee:AA:BB"], "power": ["EWeLink:1000a"] }
/// { "part": "wheel:4", "gesture": "turn", "action": "step", "targets": ["Elgato:3C6A"], "step": 5 }
/// { "part": "button:7", "gesture": "double", "action": "on", "targets": ["Hue:lamp"], "scenes": ["evening"] }
/// ```
///
/// A press, a double or a long press also runs its `scenes`, whatever its action does to its targets. A Control that
/// only runs Scenes has the action `scene`. Before 0.31, `scene` named one Scene; it is still read.
public struct RemoteControl: Sendable, Equatable, Codable {
    public enum Gesture: String, Sendable, Codable, CaseIterable {
        case press, double, long, hold, turn

        /// The gestures an Automation's press Trigger can be: a hold or a Wheel's turn never starts one.
        public static let automationGestures: [Gesture] = [.press, .double, .long]
    }

    public enum Action: String, Sendable, Codable, CaseIterable {
        /// Its targets all the same way: off (closed) when any is on (open), else on; moving shutters stop first.
        case toggle
        case on, off
        /// Runs `scenes`, and drives nothing.
        case scene
        /// Moving shutters stop where they are.
        case stop
        /// Held: dims the lights and moves the shutters a step at a time until let go (`direction`).
        case dim
        /// A Wheel's turn: a step per notch.
        case step
    }

    /// Which way a held Button dims: each hold the other way, or always up or always down.
    public enum Direction: String, Sendable, Codable, CaseIterable {
        case alternate, up, down
    }

    /// The Button or Wheel (`RemotePart.id`).
    public var part: String
    public var gesture: Gesture
    public var action: Action
    /// The lights, shutters and Appliances it drives: accessory ids, or one Function of one (`<id>#<key>`, `ControlTarget`).
    public var targets: [String]
    /// The switches or outlets that power its lights (Power Switch, GLOSSARY.md), named as its targets are.
    public var power: [String]
    /// The Scenes a press, a double or a long press runs, by id, beside what it does to its targets.
    public var scenes: [String]
    /// `dim`'s way; alternate when nil.
    public var direction: Direction?
    /// Percent of brightness or position per step; `defaultStep` when nil.
    public var step: Int?
    /// A Wheel turned up dims (closes) rather than brightens (opens).
    public var reversed: Bool?
    /// Seconds the lights take to come back once their power is on; `defaultPowerDelay` when nil.
    public var powerDelay: Int?

    public static let defaultStep = 5
    /// Its step, or the default.
    public var stepOrDefault: Int { step ?? Self.defaultStep }
    public static let defaultPowerDelay = 5
    public static let steps = 1...25
    public static let powerDelays = 1...30

    public init(part: String, gesture: Gesture, action: Action, targets: [String] = [], power: [String] = [], scenes: [String] = [],
                direction: Direction? = nil, step: Int? = nil, reversed: Bool? = nil, powerDelay: Int? = nil) {
        self.part = part
        self.gesture = gesture
        self.action = action
        self.targets = targets
        self.power = power
        self.scenes = scenes
        self.direction = direction
        self.step = step
        self.reversed = reversed
        self.powerDelay = powerDelay
    }

    private enum CodingKeys: String, CodingKey {
        case part, gesture, action, targets, power, scenes, scene, direction, step, reversed, powerDelay
    }

    /// `targets`, `power` and `scenes` may be left out: none. A single `scene` (before 0.31) is one of `scenes`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        part = try container.decode(String.self, forKey: .part)
        gesture = try container.decode(Gesture.self, forKey: .gesture)
        action = try container.decode(Action.self, forKey: .action)
        targets = try container.decodeIfPresent([String].self, forKey: .targets) ?? []
        power = try container.decodeIfPresent([String].self, forKey: .power) ?? []
        scenes = try container.decodeIfPresent([String].self, forKey: .scenes)
            ?? (try container.decodeIfPresent(String.self, forKey: .scene)).map { [$0] } ?? []
        direction = try container.decodeIfPresent(Direction.self, forKey: .direction)
        step = try container.decodeIfPresent(Int.self, forKey: .step)
        reversed = try container.decodeIfPresent(Bool.self, forKey: .reversed)
        powerDelay = try container.decodeIfPresent(Int.self, forKey: .powerDelay)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(part, forKey: .part)
        try container.encode(gesture, forKey: .gesture)
        try container.encode(action, forKey: .action)
        if !targets.isEmpty { try container.encode(targets, forKey: .targets) }
        if !power.isEmpty { try container.encode(power, forKey: .power) }
        if !scenes.isEmpty { try container.encode(scenes, forKey: .scenes) }
        try container.encodeIfPresent(direction, forKey: .direction)
        try container.encodeIfPresent(step, forKey: .step)
        try container.encodeIfPresent(reversed, forKey: .reversed)
        try container.encodeIfPresent(powerDelay, forKey: .powerDelay)
    }

    /// What a Control may drive (GLOSSARY.md, "Control"): a light, a shutter (a window covering with a position), or an
    /// Appliance, which it only turns on and off.
    public enum TargetKind: String, Sendable { case light, shutter, appliance }

    /// The actions a gesture can have: a press, a double or a long press does one thing, a hold dims, a turn steps.
    public static func actions(for gesture: Gesture) -> [Action] {
        switch gesture {
        case .press, .double, .long: [.toggle, .on, .off, .scene, .stop]
        case .hold: [.dim]
        case .turn: [.step]
        }
    }

    /// Why a Remote's Controls cannot be saved, or nil: each gesture of a part once, an action its gesture has, what it
    /// needs (Scenes, targets), a Button's long press or hold but not both (they are the same press), steps and waits in range,
    /// nothing both a target and a Power Switch of one Control.
    public static func problem(in controls: [RemoteControl]) -> String? {
        var seen: Set<String> = []
        for control in controls {
            let at = "\(control.part) \(control.gesture.rawValue)"
            if control.part.isEmpty { return "a Control names no part" }
            if !seen.insert("\(control.part)|\(control.gesture.rawValue)").inserted { return "\(at) has two Controls" }
            if !actions(for: control.gesture).contains(control.action) { return "\(at) cannot \(control.action.rawValue)" }
            if control.action == .scene {
                if control.scenes.isEmpty { return "\(at) runs no Scene" }
                if !control.targets.isEmpty { return "\(at) only runs Scenes: give it another action to drive its targets" }
            } else if control.targets.isEmpty {
                return "\(at) drives nothing"
            }
            if !control.scenes.isEmpty, !Gesture.automationGestures.contains(control.gesture) {
                return "\(at): a press, a double or a long press runs Scenes, not a \(control.gesture.rawValue)"
            }
            if control.scenes.contains(where: \.isEmpty) { return "\(at) names an empty Scene" }
            if let step = control.step, !steps.contains(step) { return "\(at): a step is \(steps.lowerBound) to \(steps.upperBound) %" }
            if let delay = control.powerDelay, !powerDelays.contains(delay) {
                return "\(at): the power wait is \(powerDelays.lowerBound) to \(powerDelays.upperBound) seconds"
            }
            // Switching what powers it and switching it would fight each other.
            if let both = control.targets.first(where: control.power.contains) { return "\(at): \(both) is both what it drives and its power" }
        }
        for control in controls where control.gesture == .hold && seen.contains("\(control.part)|long") {
            return "\(control.part) has a long press and a hold: they are the same press, keep one"
        }
        return nil
    }

    /// Controls with a device's Functions renamed as Separate Functions is turned on or off
    /// (docs/adr/0011-a-control-names-a-function.md): `<device>#<key>` becomes the separated accessory `<device>:<key>`,
    /// and back; `keys` are the Functions other than the main one, which stays on the device's accessory.
    public static func rewritten(_ controls: [RemoteControl], device: String, keys: [String], separated: Bool) -> [RemoteControl] {
        let renamed = Dictionary(keys.map { separated ? ("\(device)#\($0)", "\(device):\($0)") : ("\(device):\($0)", "\(device)#\($0)") },
                                 uniquingKeysWith: { first, _ in first })
        return controls.map { control in
            var control = control
            control.targets = control.targets.map { renamed[$0] ?? $0 }
            control.power = control.power.map { renamed[$0] ?? $0 }
            return control
        }
    }

    /// Controls from `controls`' JSON; nil when it is not a list of them (what the settings writers refuse).
    public static func list(from json: JSONValue?) -> [RemoteControl]? {
        guard let json, !json.isNull else { return [] }
        return try? json.decode([RemoteControl].self)
    }

    /// The Controls of `controls`' JSON that read, the others left out: what the bridge runs, so that one it cannot read
    /// (a newer version's, an edit's typo) stops nothing else.
    public static func readable(from json: JSONValue?) -> [RemoteControl] {
        (json?.arrayValue ?? []).compactMap { try? $0.decode(RemoteControl.self) }
    }

    /// A list of Controls as config.json keeps it.
    public static func json(_ controls: [RemoteControl]) -> JSONValue {
        (try? JSONValue(encoding: controls)) ?? .array([])
    }
}
