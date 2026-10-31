import Foundation
import Homeswift
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): each light is a device whose Device Id is its MAC (`ElgatoKeyLights:<MAC>`), found over
// Bonjour or at the address `devices` gives it, and asking nothing before the bridge talks to it. A light is left out
// by its Accessory Settings (Excluded) or, as the Homebridge plugin had it, by `enabled: false` in `devices`
// (docs/adr/0001-canonical-accessory-settings.md).
extension ElgatoKeyLightsPlugin {
    /// The lights the plugin runs or tries, those Bonjour announces, and those `devices` names: a running plugin answers
    /// from what it has seen; an instance made only for Setup browses for `discoveryWindow` first.
    public func discover() async throws -> [DiscoveredDevice] {
        var lights: [String: DiscoveredDevice] = [:]
        func found(_ mac: String, name: String, model: String?, address: String?) {
            let mac = Self.canonicalMAC(mac)
            let disabled = deviceConfiguration(mac: mac)?.enabled == false
            let name = context.accessorySettings(for: mac).name ?? deviceConfiguration(mac: mac)?.displayName?.nonEmpty ?? name
            lights[mac] = DiscoveredDevice(
                deviceID: mac, name: name, model: model ?? lights[mac]?.model, address: address ?? lights[mac]?.address, isSetUp: !disabled, excludedBySettings: disabled)
        }
        for device in configuration.devices ?? [] {
            found(device.mac, name: device.name ?? device.mac, model: device.model, address: device.ip ?? device.host)
        }
        let announced = isBrowsing ? Array(announced.values) : await browseOnce()
        for light in announced {
            found(light.mac, name: light.name, model: light.model, address: light.addresses.first(where: HostResolution.isIPv4) ?? light.addresses.first ?? light.host)
        }
        for (mac, device) in devices {
            let snapshot = await device.snapshot
            found(mac, name: snapshot.name, model: snapshot.model, address: snapshot.host)
        }
        return lights.values.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    /// What Bonjour announces within `discoveryWindow`, for an instance that is not browsing all the time.
    func browseOnce() async -> [DiscoveredLight] {
        await dependencies.discover(context.logger).collect(for: dependencies.discoveryWindow)
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
