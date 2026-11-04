import Foundation
import Homeswift
import HomeswiftPlugin

/// The Eve app's energy characteristics, with the props the Homebridge plugin gives them (section 4.6).
enum KasaEve {
    private static func eve(_ short: String) -> HAPUUID { HAPUUID("E863\(short)-079E-48FF-8F27-9C2605A29F52") }
    private static func reading(_ name: String, _ short: String, step: Double) -> CharacteristicType {
        CharacteristicType(name: name, uuid: eve(short), format: .float, permissions: [.pairedRead, .events], minValue: 0, maxValue: 65535, minStep: step)
    }

    static let volts = reading("Volts", "F10A", step: 0.1)
    static let amperes = reading("Amperes", "F126", step: 0.01)
    static let watts = reading("Consumption", "F10D", step: 0.1)
    static let voltAmperes = reading("Apparent Power", "F110", step: 0.1)
    static let kilowattHours = reading("Total Consumption", "F10C", step: 0.001)
}

/// Builds the accessory of a unit (sections 4.3 to 4.6): one primary service without a subtype, the Eve energy
/// characteristics on it when the device meters, and an Eve history for a metering plug.
enum KasaAccessory {
    struct Built {
        var accessory: Accessory
        var services: KasaServices
        var lightbulb: Service?
        var history: EveHistory?
    }

    struct Options {
        var addCustomCharacteristics: Bool
        /// Where the Eve history is kept; nil keeps it in memory.
        var historyDirectory: URL?
        /// The energy is not polled: a read asks the meter.
        var refreshEnergyOnRead: Bool
    }

    static func accessoryID(_ deviceID: String) -> String { "\(TPLinkSmarthomePlugin.platform):\(deviceID)" }

    static func make(unit: KasaUnit, options: Options) async -> Built {
        let sysinfo = await unit.sysinfo
        let presentation = unit.presentation
        let name = await unit.name
        let id = accessoryID(unit.id)
        let metered = options.addCustomCharacteristics && sysinfo.supportsEnergy
        let miredRange = KasaColorTemperature.miredRange(model: sysinfo.model)

        var energy: [Characteristic] = []
        var volts: Characteristic?, amperes: Characteristic?, watts: Characteristic?, voltAmperes: Characteristic?, kilowattHours: Characteristic?
        if metered {
            watts = Characteristic(KasaEve.watts, value: .double(0))
            energy.append(watts!)
            // A bulb's meter gives its power only.
            if sysinfo.kind == .plug {
                amperes = Characteristic(KasaEve.amperes, value: .double(0))
                kilowattHours = Characteristic(KasaEve.kilowattHours, value: .double(0))
                voltAmperes = Characteristic(KasaEve.voltAmperes, value: .double(0))
                volts = Characteristic(KasaEve.volts, value: .double(0))
                energy += [amperes!, kilowattHours!, voltAmperes!, volts!]
            }
        }

        let service: Service
        let category: AccessoryCategory
        switch presentation {
        case .outlet:
            service = Service(.outlet, name: name, optional: [.outletInUse], extra: energy, isPrimary: true)
            category = .outlet
        case .switch:
            service = Service(.switch, name: name, extra: energy, isPrimary: true)
            category = .switch
        case .dimmer:
            service = Service(.lightbulb, name: name, optional: [.brightness], extra: energy, isPrimary: true)
            category = .lightbulb
        case .bulb:
            var optional: [CharacteristicType] = []
            if sysinfo.isDimmable { optional.append(.brightness) }
            if sysinfo.isVariableColorTemperature {
                optional.append(.colorTemperature.with(minValue: Double(miredRange.lowerBound), maxValue: Double(miredRange.upperBound)))
            }
            if sysinfo.isColor { optional += [.hue, .saturation] }
            service = Service(.lightbulb, name: name, optional: optional, extra: energy, isPrimary: true)
            category = .lightbulb
        }

        let services = KasaServices(
            primary: service, on: service.characteristic(.on), outletInUse: service[.outletInUse], brightness: service[.brightness],
            colorTemperature: service[.colorTemperature], hue: service[.hue], saturation: service[.saturation],
            volts: volts, amperes: amperes, watts: watts, voltAmperes: voltAmperes, kilowattHours: kilowattHours, miredRange: miredRange)
        await showInitialValues(unit: unit, sysinfo: sysinfo, services: services)
        attachHandlers(unit: unit, services: services, refreshEnergyOnRead: metered && options.refreshEnergyOnRead)

        var history: EveHistory?
        if metered, sysinfo.kind == .plug {
            // The id's device part is letters and digits only (`KasaSysinfo.isPlainID`): it names no other directory.
            let file = options.historyDirectory?.appendingPathComponent("\(id.replacingOccurrences(of: ":", with: "_"))_persist.json")
            history = EveHistory(.energy, accessoryName: name, storageURL: file)
        }

        let mac = sysinfo.mac
        let accessory = Accessory(
            id: id, name: name, manufacturer: "TP-Link", model: sysinfo.model, serialNumber: mac.isEmpty ? unit.id : "\(mac) \(unit.id)",
            firmwareRevision: KasaSysinfo.firmwareRevision(sysinfo.softwareVersion), category: category,
            services: [service] + (history.map { [$0.service] } ?? []),
            onIdentify: { await unit.identify() })
        if !sysinfo.hardwareVersion.isEmpty {
            accessory.information.characteristic(adding: .hardwareRevision).value = .string(sysinfo.hardwareVersion)
        }
        return Built(accessory: accessory, services: services, lightbulb: service.type.uuid == ServiceType.lightbulb.uuid ? service : nil, history: history)
    }

    /// What the reads give before the first report (section 4.7): an off bulb's `dft_on_state`, else 0 or the warmest
    /// white.
    private static func showInitialValues(unit: KasaUnit, sysinfo: KasaSysinfo, services: KasaServices) async {
        if sysinfo.kind == .plug {
            services.on.value = .bool(await unit.relayOn)
            services.outletInUse?.value = .bool(await unit.inUse)
            if unit.presentation == .dimmer { services.brightness?.value = .int(sysinfo.brightness ?? 0) }
            return
        }
        let light = sysinfo.lightState ?? KasaLightState()
        let defaults = light.defaultOn
        services.on.value = .bool(light.onOff == 1)
        services.brightness?.value = .int(light.brightness ?? defaults?.brightness ?? 0)
        let kelvin = [light.colorTemperature, defaults?.colorTemperature].compactMap { $0 }.first { $0 > 0 } ?? 0
        services.colorTemperature?.value = .int(KasaColorTemperature.mireds(kelvin: kelvin, within: services.miredRange))
        services.hue?.value = .double(Double(light.hue ?? defaults?.hue ?? 0))
        services.saturation?.value = .double(Double(light.saturation ?? defaults?.saturation ?? 0))
    }

    private static func attachHandlers(unit: KasaUnit, services: KasaServices, refreshEnergyOnRead: Bool) {
        let isBulb = unit.presentation == .bulb
        services.on.onWrite { value in
            guard let on = value.boolValue else { throw HAPStatusError(.invalidValueInRequest) }
            if isBulb { try await unit.setLight(.on(on)) } else { try await unit.setOn(on) }
        }
        services.brightness?.onWrite { value in
            guard let brightness = value.doubleValue else { throw HAPStatusError(.invalidValueInRequest) }
            if isBulb { try await unit.setLight(.brightness(brightness)) } else { try await unit.setDimmerBrightness(Int(brightness.rounded())) }
        }
        services.colorTemperature?.onWrite { value in
            guard let mireds = value.intValue else { throw HAPStatusError(.invalidValueInRequest) }
            try await unit.setLight(.mirek(min(max(mireds, services.miredRange.lowerBound), services.miredRange.upperBound)))
        }
        services.hue?.onWrite { value in
            guard let hue = value.doubleValue else { throw HAPStatusError(.invalidValueInRequest) }
            try await unit.setLight(.hue(hue))
        }
        services.saturation?.onWrite { value in
            guard let saturation = value.doubleValue else { throw HAPStatusError(.invalidValueInRequest) }
            try await unit.setLight(.saturation(saturation))
        }
        if refreshEnergyOnRead, let watts = services.watts {
            watts.onRead { [weak watts] in
                await unit.refreshEnergyInBackground()
                return watts?.value ?? .double(0)
            }
        }
    }
}
