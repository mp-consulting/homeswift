import Foundation
import HomeswiftPlugin

// Power On (GLOSSARY.md, the bridge's `PowerOn.swift`): what a Key Light does when its power comes back, its settings'
// `powerOnBehavior`: 1 its last brightness and white (Last on), 2 the brightness and white it keeps (Custom). The light
// always comes back on, so the bridge's Natural Light is 2 at its brightness now, in the white the bridge gives.
extension ElgatoKeyLightsPlugin {
    /// Its whites: 2900 to 7000 K (344 to 143 mirek).
    static let powerOnWhite = 2900...7000

    private func powerOnDevice(_ accessoryID: String) -> KeyLightDevice? {
        device(mac: AccessoryNaming.deviceID(of: accessoryID, platform: Self.platform))
    }

    public func powerOnSupport(of accessoryID: String) async -> PowerOnSupport? {
        guard powerOnDevice(accessoryID) != nil else { return nil }
        return PowerOnSupport(behaviours: [.natural, .lastOn, .custom], brightness: true, white: Self.powerOnWhite)
    }

    public func powerOn(of accessoryID: String) async throws -> PowerOn? {
        guard let settings = await powerOnDevice(accessoryID)?.settings else { return nil }
        guard settings.powerOnBehavior == 2 else { return PowerOn(.lastOn) }
        return PowerOn(.custom, brightness: settings.powerOnBrightness, temperature: settings.powerOnTemperature.map(PowerOn.kelvin(mirek:)))
    }

    public func setPowerOn(_ value: PowerOn, of accessoryID: String) async throws {
        guard let device = powerOnDevice(accessoryID) else { throw PowerOnError("No such Elgato light") }
        var settings = await settings(for: device)
        switch value.behaviour {
        case .lastOn:
            settings.powerOnBehavior = 1
        case .custom, .natural:
            settings.powerOnBehavior = 2
            // Natural Light keeps the brightness the light has now; Custom's, else the one it keeps.
            let brightness = value.behaviour == .natural ? await device.state.brightness : value.brightness
            if let brightness { settings.powerOnBrightness = min(100, max(3, brightness)) }
            if let kelvin = value.temperature { settings.powerOnTemperature = Self.mirek(kelvin: kelvin) }
        default:
            throw PowerOnError("An Elgato light comes back with its last settings or the ones it keeps")
        }
        try await device.updateSettings(settings)
    }
}
