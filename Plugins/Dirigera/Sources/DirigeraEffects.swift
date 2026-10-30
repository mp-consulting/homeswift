import Foundation
import HomeswiftPlugin

extension DirigeraPlugin {
    /// IKEA lights have no effects; a sunrise or a sunset is played as one long fade of the light level, which the hub
    /// runs itself (`transitionTime`), from a warm white. Homeswift plays the other styles.
    public func animate(_ effect: LightEffect, accessoryIDs: [String]) async -> Set<String> {
        guard effect.style == .sunrise || effect.style == .sunset else { return [] }
        let milliseconds = Int(((effect.durationSeconds ?? LightEffect.defaultDuration) * 1000).rounded())
        let top = effect.brightness ?? 100
        var played: Set<String> = []
        for hub in hubs.values {
            for device in hub.devices.values where device.kind == .light && accessoryIDs.contains(Self.accessoryID(deviceID: device.id)) && device.brightness != nil {
                do {
                    // A fading light ignores the next command (openHAB): the start goes first, then the fade alone.
                    if effect.style == .sunrise {
                        try await hub.client.patch(deviceID: device.id, attributes: ["isOn": true])
                        try await hub.client.patch(deviceID: device.id, attributes: ["lightLevel": 1])
                        if let range = device.mirekRange { try await hub.client.patch(deviceID: device.id, attributes: .object(DirigeraLightCommands.white(mirek: range.upperBound))) }
                        try await hub.client.patch(deviceID: device.id, attributes: ["lightLevel": .number(top.rounded())], transitionMs: milliseconds)
                    } else {
                        try await hub.client.patch(deviceID: device.id, attributes: ["lightLevel": 1], transitionMs: milliseconds)
                    }
                    played.insert(Self.accessoryID(deviceID: device.id))
                } catch {
                    context.logger.warning("\(device.name) did not take the \(effect.style.rawValue): \(error)")
                }
            }
        }
        return played
    }
}
