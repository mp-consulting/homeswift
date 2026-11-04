import Foundation
import HomeswiftPlugin

/// The accessories a block makes (docs/clean-room/HueSyncBox.md, section 1). The raw value is the Homebridge plugin's
/// name for it, which with the block's `uuidSeed` after it is the accessory's seed: its Device Id here, and its id
/// after `PhilipsHueSyncBoxPlatform:`.
enum SyncBoxKind: String, CaseIterable, Sendable {
    case lightbulb = "LightBulbAccessory"
    case `switch` = "SwitchAccessory"
    case power = "PowerSwitchAccessory"
    case hdmiTV = "TVAccessory"
    case modeTV = "ModeTVAccessory"
    case intensityTV = "IntensityTVAccessory"
    case entertainmentTV = "EntertainmentTVAccessory"

    static let televisions: [SyncBoxKind] = [.hdmiTV, .modeTV, .intensityTV, .entertainmentTV]

    var isTelevision: Bool { Self.televisions.contains(self) }

    /// The Device Kind (GLOSSARY.md): `light`, `switch` or `tv`, which picks the settings a device shows.
    var deviceKind: String {
        switch self {
        case .lightbulb: "light"
        case .switch, .power: "switch"
        default: "tv"
        }
    }

    /// The prefix of a television's options in the block: `tvAccessory`, `tvAccessoryType`, `tvAccessoryLightbulb`.
    var optionPrefix: String? {
        switch self {
        case .hdmiTV: "tvAccessory"
        case .modeTV: "modeTvAccessory"
        case .intensityTV: "intensityTvAccessory"
        case .entertainmentTV: "entertainmentTvAccessory"
        default: nil
        }
    }

    /// The Television service's subtype and name, and its inputs' subtype prefix (section 5.4): HomeKit's scenes name them.
    var television: (subtype: String, name: String, inputPrefix: String)? {
        switch self {
        case .hdmiTV: ("TV", "TV", "HDMI ")
        case .modeTV: ("ModeAccessory", "Mode", "MODE ")
        case .intensityTV: ("IntensityTVAccessory", "Intensity", "INTENSITY ")
        case .entertainmentTV: ("EntertainmentTVAccessory", "Entertainment Area", "AREA ")
        default: nil
        }
    }

    /// After the box's `uniqueId` in the Serial Number.
    var serialSuffix: String {
        switch self {
        case .lightbulb, .switch: ""
        case .power: "-power"
        case .hdmiTV: "-T"
        case .modeTV: "-M"
        case .intensityTV: "-I"
        case .entertainmentTV: "-E"
        }
    }

    func deviceID(seed: String) -> String { rawValue + seed }
}

/// What a HomeKit write asks of the box: one request (section 4.2).
enum SyncBoxWrite: Sendable, Equatable {
    /// `PUT /api/v1/execution` with a partial execution object.
    case execution(JSONValue)
    /// `PUT /api/v1/hue` with `{"groupId": …}`.
    case area(id: String, name: String)

    static func mode(_ mode: String) -> SyncBoxWrite { .execution(["mode": .string(mode)]) }
    static func brightness(_ level: Int) -> SyncBoxWrite { .execution(["brightness": .number(Double(min(200, max(0, level))))]) }
    static func hdmiSource(_ number: Int) -> SyncBoxWrite { .execution(["hdmiSource": .string("input\(number)")]) }
    static func intensity(_ intensity: String, mode: String) -> SyncBoxWrite { .execution([mode: ["intensity": .string(intensity)]]) }
}

/// The HomeKit side of the box's values, as pure functions of the state and the options (section 5).
struct SyncBoxMapping: Sendable, Equatable {
    /// `defaultOnMode`: `video`, `music`, `game` or `lastSyncMode`.
    var onMode = "video"
    /// `defaultOffMode`: `passthrough` or `powersave`.
    var offMode = "passthrough"
    var treatPassthroughAsOffForTV = false

    init(onMode: String? = nil, offMode: String? = nil, treatPassthroughAsOffForTV: Bool = false) {
        let on = onMode?.trimmingCharacters(in: .whitespaces) ?? ""
        self.onMode = SyncBoxState.syncModes.contains(on) || on == "lastSyncMode" ? on : "video"
        let off = offMode?.trimmingCharacters(in: .whitespaces) ?? ""
        self.offMode = off == "powersave" ? "powersave" : "passthrough"
        self.treatPassthroughAsOffForTV = treatPassthroughAsOffForTV
    }

    /// The mode an "on" writes: `lastSyncMode` resolved to the box's, video when it has none.
    func onMode(in state: SyncBoxState?) -> String {
        guard onMode == "lastSyncMode" else { return onMode }
        let last = state?.lastSyncMode ?? ""
        return SyncBoxState.syncModes.contains(last) ? last : "video"
    }

    /// A Lightbulb's or Switch's On, a TV's Lightbulb: on while syncing (section 5.2).
    func write(on: Bool, state: SyncBoxState?) -> SyncBoxWrite { .mode(on ? onMode(in: state) : offMode) }

    /// A Television's Active (section 5.4): off in powersave, and in passthrough when it counts as off.
    func isActive(_ state: SyncBoxState) -> Bool {
        switch state.mode {
        case "powersave": false
        case "passthrough": !treatPassthroughAsOffForTV
        default: true
        }
    }

    /// HomeKit's 0-100 to the box's 0-200.
    static func boxBrightness(_ value: Int) -> Int { min(200, max(0, value * 2)) }

    /// The box's 0-200 to HomeKit's 0-100, halves up (as JavaScript's Math.round).
    static func homeKitBrightness(_ level: Int) -> Int { min(100, max(0, Int((Double(level) / 2).rounded(.toNearestOrAwayFromZero)))) }

    /// The request a remote key makes (section 5.4's table); nil for a key that does nothing.
    func remoteKey(_ key: Int, state: SyncBoxState) -> SyncBoxWrite? {
        switch key {
        case 4: return .brightness(min(200, state.brightness + 50))
        case 5: return .brightness(max(0, state.brightness - 50))
        case 6, 7:
            let mode = state.intensityMode
            guard let current = state.intensities[mode] else { return nil }
            let levels = SyncBoxState.intensityLevels
            if key == 6 {
                let index = levels.firstIndex(of: current) ?? (levels.count - 1)
                return index > 0 ? .intensity(levels[index - 1], mode: mode) : nil
            }
            let index = levels.firstIndex(of: current) ?? 0
            return index < levels.count - 1 ? .intensity(levels[index + 1], mode: mode) : nil
        case 8:
            // video 1, music 2, game 3, passthrough 4, powersave 5: next is (n mod 4) + 1; an unknown mode goes to video.
            let number = (SyncBoxState.modes.firstIndex(of: state.mode) ?? -1) + 1
            return .mode(SyncBoxState.modes[number % 4])
        case 11: return .mode(state.isSyncing ? offMode : onMode(in: state))
        case 15: return .hdmiSource(state.hdmiSource % 4 + 1)
        default: return nil
        }
    }
}

/// The input names of a television, from the state at start (section 5.5-5.8): renames and new areas show after a restart.
extension SyncBoxKind {
    func inputs(of state: SyncBoxState) -> [String] {
        switch self {
        case .hdmiTV: state.inputNames
        case .modeTV: SyncBoxState.modes
        case .intensityTV: SyncBoxState.intensityLevels
        case .entertainmentTV: state.areas.map(\.name)
        default: []
        }
    }

    /// The input shown now, 1-based; for the Entertainment TV n + 1 when the area is not among them. nil to leave the value.
    func activeIdentifier(in state: SyncBoxState) -> Int? {
        switch self {
        case .hdmiTV: state.hdmiSource
        case .modeTV: SyncBoxState.modes.firstIndex(of: state.mode).map { $0 + 1 }
        case .intensityTV: state.intensities[state.intensityMode].flatMap { SyncBoxState.intensityLevels.firstIndex(of: $0) }.map { $0 + 1 }
        case .entertainmentTV: (state.areas.firstIndex { $0.id == state.groupID } ?? state.areas.count) + 1
        default: nil
        }
    }

    /// The request an input choice makes; nil for an identifier no input has.
    func write(identifier: Int, state: SyncBoxState?) -> SyncBoxWrite? {
        switch self {
        case .hdmiTV: return (1...4).contains(identifier) ? .hdmiSource(identifier) : nil
        case .modeTV: return SyncBoxState.modes.indices.contains(identifier - 1) ? .mode(SyncBoxState.modes[identifier - 1]) : nil
        case .intensityTV:
            guard let state, SyncBoxState.intensityLevels.indices.contains(identifier - 1) else { return nil }
            return .intensity(SyncBoxState.intensityLevels[identifier - 1], mode: state.intensityMode)
        case .entertainmentTV:
            guard let state, state.areas.indices.contains(identifier - 1) else { return nil }
            let area = state.areas[identifier - 1]
            return .area(id: area.id, name: area.name)
        default: return nil
        }
    }
}

extension String {
    /// The first letter upper-cased, the rest as it is: an input's Configured Name.
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
