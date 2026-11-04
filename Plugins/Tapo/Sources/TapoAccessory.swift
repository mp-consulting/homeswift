import Foundation
import Homeswift
import HomeswiftPlugin

/// Eve's consumption characteristics as the Homebridge plugin defines them for Tapo: watts as a float, so a plug's
/// 15.3 W stays 15.3 (the bridge's shared one is a whole number, and `with` cannot change a format), and kWh to the
/// watt-hour.
enum TapoEve {
    static let currentConsumption = CharacteristicType(
        name: "Current Consumption", uuid: EveCharacteristic.currentConsumption.uuid, format: .float, permissions: [.pairedRead, .events],
        minValue: 0, maxValue: 65535, minStep: 0.1)
    static let totalConsumption = EveCharacteristic.totalConsumption.with(minStep: 0.001)
}

/// A device's accessory and the services the plugin sets (docs/clean-room/Tapo.md, 3.4).
struct TapoServices: Sendable {
    let kind: TapoKind
    let accessory: Accessory
    /// The Outlet or the Lightbulb.
    let primary: Service
    /// Eve's energy history, for the P110 and the L530.
    let history: EveHistory?
    /// On the bulbs with a white temperature; the service holds it weakly.
    let adaptiveLighting: AdaptiveLightingController?

    /// Builds the accessory; `write` is what a HomeKit write becomes. `cached` gives its last values back.
    static func make(
        id: String, name: String, kind: TapoKind, cached: Accessory?, historyURL: URL?, context: PluginContext,
        write: @escaping @Sendable (LightChangeBatcher.Change) async throws -> Void
    ) -> TapoServices {
        let primary: Service
        if kind.isLight {
            var optional: [CharacteristicType] = [.brightness]
            if let range = kind.colorTemperatureRange {
                optional.append(.colorTemperature.with(minValue: Double(range.lowerBound), maxValue: Double(range.upperBound), minStep: 1))
            }
            if kind.hasColor { optional += [.hue, .saturation] }
            primary = Service(.lightbulb, name: name, optional: optional, extra: energyCharacteristics(kind), isPrimary: true)
        } else {
            primary = Service(.outlet, name: name, optional: [.outletInUse], extra: energyCharacteristics(kind), isPrimary: true)
            // A P100 cannot tell whether something draws power: in use, as the Homebridge plugin says.
            primary.characteristic(.outletInUse).value = .bool(true)
        }
        let history = kind.measuresEnergy ? EveHistory(.energy, accessoryName: name, size: 4096, storageURL: historyURL) : nil
        let accessory = Accessory(
            id: id, name: name, manufacturer: "TP-Link", model: kind.model, category: kind.isLight ? .lightbulb : .outlet,
            services: [primary] + (history.map { [$0.service] } ?? []))
        if let cached { accessory.takeValues(from: cached) }

        primary.characteristic(.on).onWrite { value in try await write(.on(value.boolValue ?? false)) }
        if kind.isLight {
            primary.characteristic(.brightness).onWrite(changesOnly: true) { value in
                try await write(.brightness(value.doubleValue ?? 0))
            }
        }
        var adaptiveLighting: AdaptiveLightingController?
        if kind.colorTemperatureRange != nil {
            primary.characteristic(.colorTemperature).onWrite(changesOnly: true) { value in
                try await write(.mirek(Int(saturating: value.doubleValue ?? 0) ?? 0))
            }
            adaptiveLighting = context.adaptiveLighting(for: primary, accessoryID: id)
        }
        if kind.hasColor {
            primary.characteristic(.hue).onWrite(changesOnly: true) { value in
                try await write(.hue(value.doubleValue ?? 0))
            }
            primary.characteristic(.saturation).onWrite(changesOnly: true) { value in
                try await write(.saturation(value.doubleValue ?? 0))
            }
        }
        return TapoServices(kind: kind, accessory: accessory, primary: primary, history: history, adaptiveLighting: adaptiveLighting)
    }

    private static func energyCharacteristics(_ kind: TapoKind) -> [Characteristic] {
        guard kind.measuresEnergy else { return [] }
        return [Characteristic(TapoEve.currentConsumption, value: .double(0)), Characteristic(TapoEve.totalConsumption, value: .double(0))]
    }

    /// Shows what the device reported; `previous` is its report before, to tell a white or a colour set elsewhere.
    func show(_ state: TapoState, previous: TapoState?) {
        if let on = state.on { primary.characteristic(.on).value = .bool(on) }
        guard kind.isLight else { return }
        if let brightness = state.brightness { primary.characteristic(.brightness).value = .int(min(max(brightness, 0), 100)) }
        if kind.colorTemperatureRange != nil, let kelvin = state.kelvin {
            let reported = kelvin > 0 ? TapoConversion.mireds(kelvin: kelvin) : nil
            // Only a change the device reports: the echo of a write of the bridge's own matches what is shown.
            if let previous, previous.kelvin != kelvin || previous.hue != state.hue || previous.saturation != state.saturation {
                adaptiveLighting?.disableIfChangedElsewhere(mireds: reported)
            }
            if let reported { primary.characteristic(.colorTemperature).value = .int(reported) }
        }
        if kind.hasColor {
            if let hue = state.hue { primary.characteristic(.hue).value = .double(Double(min(max(hue, 0), 360))) }
            if let saturation = state.saturation { primary.characteristic(.saturation).value = .double(Double(min(max(saturation, 0), 100))) }
        }
    }

    func show(_ energy: TapoEnergy) {
        primary.characteristic(TapoEve.currentConsumption).value = .double((energy.watts * 10).rounded() / 10)
        primary.characteristic(TapoEve.totalConsumption).value = .double(energy.todayKWh)
        if kind == .powerPlug { primary.characteristic(.outletInUse).value = .bool(energy.watts > 0) }
    }

    /// Accessory Information from the device: its hardware id as the serial number, its firmware's version.
    func showInformation(_ state: TapoState) {
        if let hardwareID = state.hardwareID, !hardwareID.isEmpty { accessory.information.characteristic(.serialNumber).value = .string(hardwareID) }
        if let firmware = state.firmwareRevision { accessory.information.characteristic(.firmwareRevision).value = .string(firmware) }
    }
}
