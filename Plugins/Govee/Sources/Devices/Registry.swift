import Foundation
import HomeswiftPlugin

/// Which handler a device gets (`device/registry.ts` and `device/index.ts`): its model's category, unless its
/// settings pick another presentation (`showAs`, `showExtraSwitch`, `tempReporting`); model-specific handlers
/// win over their category's.
enum DeviceCategory: String, Sendable, CaseIterable {
    case light, lightSwitch, outletSingle, outletDouble, outletTriple, switchSingle, switchDouble, switchTriple
    case fan, heater, heater1b, cooler, humidifier, dehumidifier, purifier, diffuser, kettle, iceMaker
    case sensorThermo, sensorThermo4, sensorThermoSwitch, sensorLeak, sensorContact, sensorPresence, sensorButton, sensorMonitor
    case tap, valve, tv, template

    /// The model lists, in the order the Homebridge plugin registered them (a later one wins).
    static let modelCategories: [String: DeviceCategory] = {
        let lists: [([String], DeviceCategory)] = [
            (GoveeConstants.Models.rgb, .light), (GoveeConstants.Models.switchSingle, .switchSingle), (GoveeConstants.Models.switchDouble, .switchDouble),
            (GoveeConstants.Models.switchTriple, .switchTriple), (GoveeConstants.Models.fan, .fan), (GoveeConstants.Models.heater1, .heater),
            (GoveeConstants.Models.heater2, .heater), (GoveeConstants.Models.humidifier, .humidifier), (GoveeConstants.Models.dehumidifier, .dehumidifier),
            (GoveeConstants.Models.purifier, .purifier), (GoveeConstants.Models.diffuser, .diffuser), (GoveeConstants.Models.kettle, .kettle),
            (GoveeConstants.Models.iceMaker, .iceMaker), (GoveeConstants.Models.sensorThermo, .sensorThermo), (GoveeConstants.Models.sensorThermo4, .sensorThermo4),
            (GoveeConstants.Models.sensorLeak, .sensorLeak), (GoveeConstants.Models.sensorButton, .sensorButton), (GoveeConstants.Models.sensorContact, .sensorContact),
            (GoveeConstants.Models.sensorPresence, .sensorPresence), (GoveeConstants.Models.sensorMonitor, .sensorMonitor), (GoveeConstants.Models.template, .template),
        ]
        var map: [String: DeviceCategory] = [:]
        for (models, category) in lists {
            for model in models { map[model.uppercased()] = category }
        }
        return map
    }()

    /// The handlers of single models, which win over their category's.
    enum ModelHandler: Sendable { case fanLight, humidifierH7160, humidifierH7142, heater1a, heater2, purifierH7120, purifierH7122, purifierH7123, purifierH7126 }

    static let modelHandlers: [String: ModelHandler] = [
        "H7105": .fanLight, "H7107": .fanLight, "H7160": .humidifierH7160, "H7142": .humidifierH7142,
        "H7130": .heater1a, "H713A": .heater1a, "H713B": .heater1a, "H713C": .heater1a, "H7131": .heater2, "H7132": .heater2,
        "H7121": .purifierH7120, "H7120": .purifierH7120, "H7122": .purifierH7122, "H7123": .purifierH7123, "H7124": .purifierH7123,
        "H7126": .purifierH7126, "H7127": .purifierH7126, "H7128": .purifierH7126, "H7129": .purifierH7126, "H712C": .purifierH7126,
    ]

    static func forModel(_ model: String) -> DeviceCategory? { modelCategories[model.uppercased()] }

    /// The category the device's handler comes from; `default` keeps the model's.
    static func resolve(model: String, settings: DeviceSettings) -> DeviceCategory? {
        let category = forModel(model)
        let showAs = settings.showAs
        switch category {
        case .light:
            return showAs == "switch" ? .lightSwitch : category
        case .switchSingle:
            let shown: [String: DeviceCategory] = [
                "outlet": .outletSingle, "switch": .switchSingle, "purifier": .purifier, "heater": .heater, "cooler": .cooler, "tap": .tap, "valve": .valve,
                "audio": .tv, "box": .tv, "stick": .tv,
            ]
            return shown[showAs] ?? category
        case .switchDouble:
            return showAs == "outlet" ? .outletDouble : category
        case .switchTriple:
            return showAs == "outlet" ? .outletTriple : category
        case .sensorThermo:
            return settings.bool("showExtraSwitch") ? .sensorThermoSwitch : category
        case .heater:
            return settings.bool("tempReporting") ? .heater1b : category
        default:
            return category
        }
    }

    /// Whether the model has a handler at all.
    static func isSupported(_ model: String) -> Bool { forModel(model) != nil }
}

extension GoveeDevice {
    /// The handler for a device, or nil for a model the plugin does not know.
    @GoveeActor
    static func make(model: String, environment: DeviceEnvironment) -> GoveeDevice? {
        guard let category = DeviceCategory.resolve(model: model, settings: environment.settings) else { return nil }
        // A setting that picks another presentation uses that category's handler; otherwise a model's own wins.
        if category == DeviceCategory.forModel(model), let handler = DeviceCategory.modelHandlers[model.uppercased()] {
            switch handler {
            case .fanLight: return FanLightDevice(environment: environment)
            case .humidifierH7160: return HumidifierH7160Device(environment: environment)
            case .humidifierH7142: return HumidifierH7142Device(environment: environment)
            case .heater1a: return Heater1aDevice(environment: environment)
            case .heater2: return Heater2Device(environment: environment)
            case .purifierH7120: return PurifierH7120Device(environment: environment)
            case .purifierH7122: return PurifierAirQualityDevice(environment: environment, model: .h7122)
            case .purifierH7123: return PurifierAirQualityDevice(environment: environment, model: .h7123)
            case .purifierH7126: return PurifierH7126Device(environment: environment)
            }
        }
        switch category {
        case .light: return LightDevice(environment: environment)
        case .lightSwitch: return LightSwitchDevice(environment: environment)
        case .outletSingle: return OutletSingleDevice(environment: environment)
        case .outletDouble: return MultiChannelDevice(environment: environment, channels: 2, kind: .outlet)
        case .outletTriple: return MultiChannelDevice(environment: environment, channels: 3, kind: .outlet)
        case .switchSingle: return SwitchSingleDevice(environment: environment)
        case .switchDouble: return MultiChannelDevice(environment: environment, channels: 2, kind: .switch)
        case .switchTriple: return MultiChannelDevice(environment: environment, channels: 3, kind: .switch)
        case .fan: return FanDevice(environment: environment)
        case .heater: return ThermostatPlugDevice(environment: environment, mode: .heater)
        case .heater1b: return Heater1bDevice(environment: environment)
        case .cooler: return ThermostatPlugDevice(environment: environment, mode: .cooler)
        case .humidifier: return HumidifierDevice(environment: environment)
        case .dehumidifier: return DehumidifierDevice(environment: environment)
        case .purifier: return PurifierDevice(environment: environment)
        case .diffuser: return DiffuserDevice(environment: environment)
        case .kettle: return KettleDevice(environment: environment)
        case .iceMaker: return IceMakerDevice(environment: environment)
        case .sensorThermo: return SensorThermoDevice(environment: environment, asThermostat: false)
        case .sensorThermoSwitch: return SensorThermoDevice(environment: environment, asThermostat: true)
        case .sensorThermo4: return SensorThermo4Device(environment: environment)
        case .sensorLeak: return SensorLeakDevice(environment: environment)
        case .sensorContact: return SensorContactDevice(environment: environment)
        case .sensorPresence: return SensorPresenceDevice(environment: environment)
        case .sensorButton: return SensorButtonDevice(environment: environment)
        case .sensorMonitor: return SensorMonitorDevice(environment: environment)
        case .tap: return ValvePlugDevice(environment: environment, kind: .tap)
        case .valve: return ValvePlugDevice(environment: environment, kind: .valve)
        case .tv: return TelevisionPlugDevice(environment: environment)
        case .template: return TemplateDevice(environment: environment)
        }
    }
}
