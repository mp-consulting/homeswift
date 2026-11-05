import Foundation
import Homeswift
import HomeswiftPlugin

/// Builds a device's accessory (section 3): one primary service without a subtype, a Lightbulb with Brightness, Hue and
/// Saturation and Color Temperature as the profile has them, or a Switch; Manufacturer MagicHome, the Wi-Fi module as
/// the model, the MAC as the serial number.
enum MagicHomeAccessory {
    static func accessoryID(_ deviceID: String) -> String { "\(MagicHomePlugin.platform):\(deviceID)" }

    static func make(device: MagicHomeDevice, name: String) async -> (accessory: Accessory, services: MagicHomeServices) {
        let profile = await device.profile
        let record = await device.record
        let id = accessoryID(device.id)
        let service: Service
        if profile.isSwitch {
            service = Service(.switch, name: name, isPrimary: true)
        } else {
            var optional: [CharacteristicType] = []
            if profile.hasBrightness { optional.append(.brightness) }
            if profile.hasColour { optional += [.hue, .saturation] }
            if profile.hasTemperature {
                let range = MagicHomeColour.miredRange
                optional.append(.colorTemperature.with(minValue: Double(range.lowerBound), maxValue: Double(range.upperBound)))
            }
            service = Service(.lightbulb, name: name, optional: optional, isPrimary: true)
        }
        let accessory = Accessory(
            id: id, name: name, manufacturer: "MagicHome", model: record.module.isEmpty ? profile.description : record.module, serialNumber: device.id,
            category: profile.isSwitch ? .switch : .lightbulb, services: [service],
            onIdentify: { await device.identify() })
        let services = MagicHomeServices(
            accessory: accessory, primary: service, on: service.characteristic(.on), brightness: service[.brightness], hue: service[.hue],
            saturation: service[.saturation], colorTemperature: service[.colorTemperature])
        attachHandlers(device: device, services: services)
        return (accessory, services)
    }

    private static func attachHandlers(device: MagicHomeDevice, services: MagicHomeServices) {
        services.on.onWrite { value in
            guard let on = value.boolValue else { throw HAPStatusError(.invalidValueInRequest) }
            try await device.write(.on(on))
        }
        services.brightness?.onWrite { value in
            guard let brightness = value.doubleValue, brightness.isFinite else { throw HAPStatusError(.invalidValueInRequest) }
            try await device.write(.brightness(brightness))
        }
        services.hue?.onWrite { value in
            guard let hue = value.doubleValue, hue.isFinite else { throw HAPStatusError(.invalidValueInRequest) }
            try await device.write(.hue(hue))
        }
        services.saturation?.onWrite { value in
            guard let saturation = value.doubleValue, saturation.isFinite else { throw HAPStatusError(.invalidValueInRequest) }
            try await device.write(.saturation(saturation))
        }
        services.colorTemperature?.onWrite { value in
            guard let mireds = value.intValue else { throw HAPStatusError(.invalidValueInRequest) }
            try await device.write(.mirek(mireds))
        }
    }
}
