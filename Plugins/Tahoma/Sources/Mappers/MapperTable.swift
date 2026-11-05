import Foundation

/// Which mapper shows a device (docs/clean-room/Tahoma.md 5.2): the first entry for `uiClass/widget/uniqueName`, then
/// `uiClass/widget`, then `uiClass`.
enum MapperTable {
    static let mappers: [String: Mapper.Type] = [
        // Covers (5.3, 5.4)
        "RollerShutter": RollerShutterMapper.self,
        "RollerShutter/PositionableRollerShutterUno": RollerShutterUnoMapper.self,
        "RollerShutter/PositionableRollerShutterWithLowSpeedManagement": LowSpeedRollerShutterMapper.self,
        "ExteriorScreen": RollerShutterMapper.self,
        "Screen": RollerShutterMapper.self,
        "Shutter": RollerShutterMapper.self,
        "Curtain": RollerShutterMapper.self,
        "SwingingShutter": RollerShutterMapper.self,
        "Pergola": RollerShutterMapper.self,
        "Pergola/PergolaHorizontalAwningUno": PergolaAwningUnoMapper.self,
        "Pergola/BioclimaticPergola": BioclimaticPergolaMapper.self,
        "Window": WindowMapper.self,
        "Awning": AwningMapper.self,
        "Awning/PositionableHorizontalAwningUno": AwningUnoMapper.self,
        "VenetianBlind": VenetianBlindMapper.self,
        "ExteriorVenetianBlind": VenetianBlindMapper.self,
        "AdjustableSlatsRollerShutter": AdjustableSlatsMapper.self,
        "Generic/RTSGeneric": RTSGenericMapper.self,
        // Openers, locks, alarms (5.5, 5.6, 5.8)
        "GarageDoor": GarageDoorMapper.self,
        "Generic/CyclicGeneric": GarageDoorMapper.self,
        "Generic/RTSGeneric4T": GarageDoorMapper.self,
        "Gate": GateMapper.self,
        "DoorLock": DoorLockMapper.self,
        "Alarm": AlarmMapper.self,
        "Alarm/MyFoxAlarmController": MyFoxAlarmMapper.self,
        "Alarm/TSKAlarmController": TSKAlarmMapper.self,
        // Lights and switches (5.7)
        "Light": LightMapper.self,
        "Generic/DimmerOnOff": LightMapper.self,
        "OnOff": OnOffMapper.self,
        "Siren": SirenMapper.self,
        // Sensors (5.9)
        "ContactSensor": ContactSensorMapper.self,
        "WindowHandle": WindowHandleMapper.self,
        "OccupancySensor": OccupancySensorMapper.self,
        "SmokeSensor": SmokeSensorMapper.self,
        "RainSensor": RainSensorMapper.self,
        "WaterSensor": WaterSensorMapper.self,
        "HumiditySensor": HumiditySensorMapper.self,
        "HumiditySensor/WaterDetectionSensor": WaterDetectionContactMapper.self,
        "TemperatureSensor": TemperatureSensorMapper.self,
        "EvoHome/DHWSetPoint": TemperatureSensorMapper.self,
        "LightSensor": LightSensorMapper.self,
        "AirSensor": AirSensorMapper.self,
        "AirSensor/CO2Sensor": AirSensorMapper.self,
        "AirSensor/RelativeHumiditySensor": HumiditySensorMapper.self,
        // Heating (5.10)
        "HeatingSystem": ThermostatMapper.self,
        "HeatingSystem/AtlanticElectricalHeater": PilotWireHeaterMapper.self,
        "HeatingSystem/AtlanticElectricalHeaterWithAdjustableTemperatureSetpoint": AdjustableSetpointHeaterMapper.self,
        "HeatingSystem/AtlanticElectricalTowelDryer": TowelDryerMapper.self,
        "HeatingSystem/ThermostatSetPoint": ThermostatSetPointMapper.self,
        "HeatingSystem/ProgrammableAndProtectableThermostatSetPoint": ThermostatSetPointMapper.self,
        "HeatingSystem/SomfyThermostat": SomfyThermostatMapper.self,
        "HeatingSystem/SomfyHeatingTemperatureInterface": SomfyHeatingInterfaceMapper.self,
        "HeatingSystem/ValveHeatingTemperatureInterface": ValveHeatingInterfaceMapper.self,
        "HeatingSystem/AtlanticPassAPCHeatingZone": PassAPCHeatingZoneMapper.self,
        "HeatingSystem/AtlanticPassAPCHeatingAndCoolingZone": PassAPCHeatingCoolingZoneMapper.self,
        "HeatingSystem/AtlanticPassAPCHeatPump": PassAPCHeatPumpMapper.self,
        "HeatingSystem/AtlanticPassAPCZoneControl": PassAPCZoneControlMapper.self,
        "HeatingSystem/AtlanticPassAPCBoiler": StateSwitchMapper.self,
        "HitachiHeatingSystem/HitachiAirToWaterHeatingZone": ThermostatMapper.self,
        "HitachiHeatingSystem/HitachiAirToWaterMainComponent": HitachiMainComponentMapper.self,
        "HitachiHeatingSystem/HitachiAirToAirHeatPump": HitachiAirToAirMapper.self,
        "HitachiHeatingSystem/HitachiDHW": WaterHeaterMapper.self,
        "EvoHome/EvoHomeController": EvoHomeControllerMapper.self,
        "EvoHome/HeatingSetPoint": EvoHomeSetPointMapper.self,
        "ExteriorHeatingSystem": OnOffMapper.self,
        "ExteriorHeatingSystem/DimmerExteriorHeating": DimmerExteriorHeatingMapper.self,
        // Water heating and ventilation (5.11)
        "WaterHeatingSystem": WaterHeaterMapper.self,
        "WaterHeatingSystem/AtlanticPassAPCDHW": PassAPCDHWMapper.self,
        "WaterHeatingSystem/DomesticHotWaterProduction": HotWaterProductionMapper.self,
        "WaterHeatingSystem/DomesticHotWaterProduction/AtlanticDomesticHotWaterProductionV2_SPLIT_IOComponent": HotWaterSplitMapper.self,
        "WaterHeatingSystem/DomesticHotWaterTank": StateSwitchMapper.self,
        "VentilationSystem": VentilationMapper.self,
        "VentilationSystem/DimplexVentilationInletOutlet": VentilationMapper.self,
    ]

    /// The mapper for a device; nil for one the plugin does not show (`ConsumptionSensor`, `RemoteController`, an
    /// electricity sensor, a uiClass it does not know), which is left out with a warning (10.7).
    static func mapper(for device: OverkizDevice) -> Mapper.Type? {
        let keys = [
            "\(device.uiClass)/\(device.widgetName)/\(device.uniqueName)", "\(device.uiClass)/\(device.widgetName)", device.uiClass,
        ]
        return keys.lazy.compactMap { mappers[$0] }.first
    }
}

/// The exclusions (2.3) and the grouping of sub-devices (5.2).
enum DeviceGrouping {
    /// Always left out, whatever `exclude` says.
    static let builtInExclusions: Set<String> = [
        "Pod", "ConfigurationComponent", "NetworkComponent", "ProtocolGateway", "ConsumptionSensor", "OnOffHeatingSystem", "Wifi",
        "RemoteController", "io:LightIOSystemDeviceSensor", "io:RelativeHumidityIOSystemDeviceSensor", "enocean:EnOceanHumidityComfortSensor",
        "WeatherForecastSensor",
    ]

    /// Whether an entry of the list names the device: its uiClass, widget, controllable name, label or protocol.
    static func isExcluded(_ device: OverkizDevice, by list: Set<String>) -> Bool {
        [device.uiClass, device.widgetName, device.controllableName, device.label, device.protocolName].contains(where: list.contains)
    }

    struct Group: Sendable {
        var device: OverkizDevice
        var sensors: [OverkizDevice]
        var parent: OverkizDevice?
    }

    /// Walks the listing in the server's order: a main device starts a group; a sub-device that is a sensor of the last
    /// device, else of the main device, else of an earlier sub-device of the group, is attached to it; another
    /// sub-device is exposed with the main device as its parent.
    static func group(_ devices: [OverkizDevice]) -> [Group] {
        var groups: [Group] = []
        var mainIndex: Int?
        var groupStart = 0
        for device in devices {
            if device.isMain {
                groups.append(Group(device: device, sensors: [], parent: nil))
                mainIndex = groups.count - 1
                groupStart = groups.count - 1
                continue
            }
            let candidates = [groups.indices.last, mainIndex].compactMap { $0 } + Array(groups.indices.dropFirst(groupStart).reversed())
            if let owner = candidates.first(where: { isSensor(device, of: groups[$0].device) }) {
                groups[owner].sensors.append(device)
            } else {
                groups.append(Group(device: device, sensors: [], parent: mainIndex.map { groups[$0].device }))
            }
        }
        return groups
    }

    /// The "sensor of" rules (5.2).
    static func isSensor(_ candidate: OverkizDevice, of owner: OverkizDevice) -> Bool {
        switch candidate.controllableName {
        case "io:AtlanticPassAPCOutsideTemperatureSensor":
            return false
        case "io:AtlanticPassAPCZoneTemperatureSensor":
            return owner.uiClass == "HeatingSystem"
        case "io:HeatingRelatedElectricalEnergyConsumptionSensor":
            return owner.controllableName == "io:AtlanticPassAPCHeatPumpMainComponent"
        case "io:DHWRelatedElectricalEnergyConsumptionSensor":
            return owner.controllableName == "io:AtlanticPassAPCDHWComponent"
        case "io:CumulatedElectricalEnergyConsumptionIOSystemDeviceSensor":
            return ["io:AtlanticElectricalHeaterWithAdjustableTemperatureSetpointIOComponent", "io:AtlanticElectricalTowelDryerIOComponent"]
                .contains(owner.controllableName)
        default:
            return candidate.widgetName == "TemperatureSensor" && owner.uiClass == "HeatingSystem"
        }
    }
}
