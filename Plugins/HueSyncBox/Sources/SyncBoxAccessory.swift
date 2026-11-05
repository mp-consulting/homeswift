import Foundation
import Homeswift
import HomeswiftPlugin

/// One of the box's accessories and the services its state shows on (docs/clean-room/HueSyncBox.md, section 5).
struct SyncBoxAccessory: Sendable {
    /// A television's options: its icon (`tv`, `settopbox`, `tvstick`, `audioreceiver`) and whether it has a Lightbulb.
    struct Options: Sendable, Equatable {
        var type = "tv"
        var lightbulb = false
        /// A Homebridge block's `tvAccessoryConfiguredName`, until a settings write moves it to the Core name.
        var name: String?
    }

    let kind: SyncBoxKind
    let accessory: Accessory
    /// The base Lightbulb, the TV's Lightbulb.
    let lightbulb: Service?
    /// The base Switch or the power switch.
    let onSwitch: Service?
    let television: Service?

    init(kind: SyncBoxKind, id: String, state: SyncBoxState, options: Options, plugin: HueSyncBoxPlugin) {
        self.kind = kind
        let name = options.name ?? (kind == .power ? "\(state.name) Power" : state.name)
        var services: [Service] = []
        var lightbulb: Service?
        var onSwitch: Service?
        var television: Service?

        switch kind {
        case .lightbulb:
            lightbulb = Self.lightbulb(name: name, isPrimary: true, key: kind.rawValue, plugin: plugin)
        case .switch:
            let service = Service(.switch, name: name, isPrimary: true)
            service.characteristic(.on).onWrite(changesOnly: true) { [weak plugin] value in await plugin?.setOn(value.boolValue ?? false) }
            onSwitch = service
        case .power:
            let service = Service(.switch, name: name, isPrimary: true)
            service.characteristic(.on).onWrite(changesOnly: true) { [weak plugin] value in await plugin?.setPower(value.boolValue ?? false) }
            onSwitch = service
        default:
            let tv = Self.television(kind: kind, name: name, state: state, plugin: plugin)
            television = tv
            services.append(contentsOf: tv.linked)
            if options.lightbulb {
                lightbulb = Self.lightbulb(name: name, isPrimary: false, key: kind.rawValue, plugin: plugin)
            }
        }
        services = [television, lightbulb, onSwitch].compactMap { $0 } + services
        self.lightbulb = lightbulb
        self.onSwitch = onSwitch
        self.television = television
        accessory = Accessory(
            id: id, name: name, manufacturer: "Philips", model: "Sync Box", serialNumber: state.uniqueID + kind.serialSuffix,
            firmwareRevision: state.firmwareVersion.nonEmpty ?? "1.0.0", category: Self.category(kind, type: options.type), services: services)
    }

    static func category(_ kind: SyncBoxKind, type: String) -> AccessoryCategory {
        switch kind {
        case .lightbulb: return .lightbulb
        case .switch, .power: return .switch
        default:
            switch type.lowercased() {
            case "settopbox": return .tvSetTopBox
            case "tvstick": return .tvStreamingStick
            case "audioreceiver": return .audioReceiver
            default: return .television
            }
        }
    }

    private static func lightbulb(name: String, isPrimary: Bool, key: String, plugin: HueSyncBoxPlugin) -> Service {
        let service = Service(.lightbulb, name: name, optional: [.brightness], isPrimary: isPrimary)
        service.characteristic(.on).onWrite(changesOnly: true) { [weak plugin] value in await plugin?.setOn(value.boolValue ?? false) }
        service.characteristic(.brightness).onWrite(changesOnly: true) { [weak plugin] value in
            await plugin?.sendBrightness(value.intValue ?? 0, key: key)
        }
        return service
    }

    /// The Television service with an InputSource linked per input (section 5.4).
    private static func television(kind: SyncBoxKind, name: String, state: SyncBoxState, plugin: HueSyncBoxPlugin) -> Service {
        guard let shape = kind.television else { preconditionFailure("not a television") }
        let inputs = kind.inputs(of: state).enumerated().map { index, label -> Service in
            let number = index + 1
            let subtype = "\(shape.inputPrefix)\(number)"
            // "HDMI 1" is named "hdmi1" (each prefix has one space).
            let serviceName = subtype.lowercased().replacingOccurrences(of: " ", with: "")
            let input = Service(.inputSource, name: serviceName, subtype: subtype, optional: [.identifier, .targetVisibilityState])
            input.characteristic(.configuredName).value = .string(label.capitalizingFirstLetter)
            input.characteristic(.inputSourceType).value = .int(HAPConstants.InputSourceType.hdmi)
            input.characteristic(.isConfigured).value = .int(HAPConstants.IsConfigured.configured)
            input.characteristic(.currentVisibilityState).value = .int(HAPConstants.CurrentVisibilityState.shown)
            input.characteristic(.targetVisibilityState).value = .int(HAPConstants.CurrentVisibilityState.shown)
            // n, not the subtype's last digit: the same for 1 to 9, and a tenth area does not repeat the first.
            input.characteristic(.identifier).value = .int(number)
            if kind != .entertainmentTV {
                input.characteristic(.targetVisibilityState).onWrite { value in
                    input.characteristic(.currentVisibilityState).value = .int(value.intValue ?? HAPConstants.CurrentVisibilityState.shown)
                }
            }
            return input
        }
        let television = Service(.television, name: name, subtype: shape.subtype, linked: inputs, isPrimary: true)
        television.characteristic(.configuredName).value = .string(name)
        television.characteristic(.sleepDiscoveryMode).value = .int(HAPConstants.SleepDiscoveryMode.alwaysDiscoverable)
        television.characteristic(.active).onWrite(changesOnly: true) { [weak plugin] value in
            await plugin?.setActive(value.intValue == HAPConstants.Active.active)
        }
        television.characteristic(.activeIdentifier).onWrite { [weak plugin] value in
            await plugin?.select(value.intValue ?? 0, on: kind)
        }
        television.characteristic(.remoteKey).onWrite { [weak plugin] value in await plugin?.remoteKey(value.intValue ?? -1) }
        return television
    }

    /// The state's values; a characteristic set to the value it has tells HomeKit nothing.
    func show(_ state: SyncBoxState, mapping: SyncBoxMapping) {
        switch kind {
        case .switch: onSwitch?.characteristic(.on).value = .bool(state.isSyncing)
        case .power: onSwitch?.characteristic(.on).value = .bool(state.mode != "powersave")
        default: break
        }
        if let lightbulb {
            lightbulb.characteristic(.on).value = .bool(state.isSyncing)
            lightbulb.characteristic(.brightness).value = .int(SyncBoxMapping.homeKitBrightness(state.brightness))
        }
        if let television {
            television.characteristic(.active).value = .int(mapping.isActive(state) ? HAPConstants.Active.active : HAPConstants.Active.inactive)
            if let identifier = kind.activeIdentifier(in: state) {
                television.characteristic(.activeIdentifier).value = .int(identifier)
            }
        }
    }
}
