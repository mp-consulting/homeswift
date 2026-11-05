import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): each light is a device whose Device Id is its MAC (`ElgatoKeyLights:<MAC>`), of the Device
// Kind `light`, found over Bonjour or at an address of `addresses` (or `devices`, in a Homebridge block), and asking
// nothing before the bridge talks to it. A light is left out by its Accessory Settings (Excluded) or, as the Homebridge
// plugin had it, by `enabled: false` in `devices` (docs/adr/0001-canonical-accessory-settings.md).
extension ElgatoKeyLightsPlugin {
    /// The lights the plugin runs or tries, those Bonjour announces, and those `addresses` and `devices` name: a running
    /// plugin answers from what it has seen; an instance made only for Setup browses for `discoveryWindow` first, and asks
    /// the lights of `addresses` without a MAC who they are meanwhile.
    public func discover() async throws -> [DiscoveredDevice] {
        var lights: [String: DiscoveredDevice] = [:]
        func found(_ mac: String, name: String, model: String?, address: String?) {
            let mac = Self.canonicalMAC(mac)
            let disabled = deviceConfiguration(mac: mac)?.enabled == false
            let name = context.accessorySettings(for: mac).name ?? deviceConfiguration(mac: mac)?.displayName?.nonEmpty ?? name
            lights[mac] = DiscoveredDevice(
                deviceID: mac, name: name, model: model ?? lights[mac]?.model, address: address ?? lights[mac]?.address, isSetUp: !disabled, excludedBySettings: disabled,
                kind: Self.lightKind)
        }
        for device in configuration.devices ?? [] {
            found(device.mac, name: device.name ?? device.mac, model: device.model, address: device.ip ?? device.host)
        }
        async let probed = isBrowsing ? [] : probeAddresses()
        let announced = isBrowsing ? Array(announced.values) : await browseOnce()
        for address in configuredAddresses {
            let host = address.host.trimmingCharacters(in: .whitespaces)
            if let mac = address.mac.flatMap(MACAddress.canonical) ?? learnedMACs[Self.addressKey(host: host, port: address.port)] {
                found(mac, name: mac, model: nil, address: host)
            }
        }
        for light in await probed {
            found(light.mac, name: light.name, model: light.model, address: light.host)
        }
        for light in announced {
            found(light.mac, name: light.name, model: light.model, address: light.addresses.first(where: HostResolution.isIPv4) ?? light.addresses.first ?? light.host)
        }
        for (mac, device) in devices {
            let snapshot = await device.snapshot
            found(mac, name: snapshot.name, model: snapshot.model, address: snapshot.host)
        }
        return lights.values.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    /// A light Bonjour does not reach can be added by its address (Add by address): the light's host and port go in its
    /// Accessory Settings (`host`, `port`), under the MAC it answers with.
    public static let addsDevicesByAddress = true

    /// Add by address: asks for the light's host (and a port, 9123 by default), asks the light there who it is, and
    /// keeps where it answers in its Accessory Settings, by its MAC. A light found by Bonjour needs nothing.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard request.isNewDevice else { return .done(SetupOutcome()) }
        guard let host = request.answer("host") else {
            return .ask(SetupPrompt(message: "Enter the address of the light: its IP address or host name, as your router or the Control Center app shows it.", fields: [
                SetupField("host", label: "IP address or host name"),
                SetupField("port", label: "Port", optional: true),
            ]))
        }
        guard KeyLightClient.isValidHost(host) else { throw SetupError("\(host) is not an IP address or a host name") }
        let port = try request.answer("port").map { text in
            guard let port = Int(text), KeyLightClient.isValidPort(port) else { throw SetupError("The port must be between 1 and 65535") }
            return port
        } ?? KeyLightClient.defaultPort
        let mac: String?
        do {
            mac = try await identify(host: host, port: port).mac
        } catch {
            throw SetupError("No light answered at \(host):\(port)")
        }
        guard let mac else { throw SetupError("The light at \(host) did not give its MAC address") }
        var settings: [String: JSONValue] = ["host": .string(host)]
        // The default port is left out; a port no longer given is taken out.
        settings["port"] = port == KeyLightClient.defaultPort ? .null : .number(Double(port))
        context.logger.info("Added the light at \(host):\(port) by its address", metadata: ["light": "\(mac)"])
        return .done(SetupOutcome(settings: settings, deviceID: mac))
    }

    /// The lights of `addresses` without a MAC, asked who they are at once, for an instance that is not running.
    func probeAddresses() async -> [DiscoveredLight] {
        let transport = dependencies.transport
        let unknown = (configuration.addresses ?? []).filter { $0.mac.flatMap(MACAddress.canonical) == nil }
        return await withTaskGroup(of: DiscoveredLight?.self) { group in
            for address in unknown {
                let host = address.host.trimmingCharacters(in: .whitespaces)
                let port = address.port ?? KeyLightClient.defaultPort
                guard KeyLightClient.isValidHost(host), KeyLightClient.isValidPort(port) else { continue }
                group.addTask {
                    guard let info = try? await KeyLightClient(host: host, port: port, transport: transport).info(),
                          let mac = info.macAddress.flatMap(MACAddress.canonical) else { return nil }
                    return DiscoveredLight(name: info.displayName?.nonEmpty ?? info.productName ?? mac, mac: mac, host: host, port: port, model: info.productName)
                }
            }
            var lights: [DiscoveredLight] = []
            for await light in group { if let light { lights.append(light) } }
            return lights
        }
    }

    /// What Bonjour announces within `discoveryWindow`, for an instance that is not browsing all the time.
    func browseOnce() async -> [DiscoveredLight] {
        await dependencies.discover(context.logger).collect(for: dependencies.discoveryWindow)
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
