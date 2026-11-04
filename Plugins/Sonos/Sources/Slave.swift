import Foundation
import Homeswift
import NIOConcurrencyHelpers

/// A stereo pair's other player, a sub or a surround (`ZP:<player id>`, with `leds`): its LED and button lock, its
/// last contact and fault, and its battery.
final class SlaveAccessory: @unchecked Sendable {
    let id: String
    let description: DeviceDescription
    private let box: NIOLockedValueBox<(player: TopologyPlayer, accessory: Accessory?, led: Service?, battery: Service?)>
    let blinking = NIOLockedValueBox(false)

    init(player: TopologyPlayer, description: DeviceDescription) {
        id = player.id
        self.description = description
        box = NIOLockedValueBox((player, nil, nil, nil))
    }

    var accessory: Accessory? { box.withLockedValue { $0.accessory } }
    var led: Service? { box.withLockedValue { $0.led } }
    var player: TopologyPlayer { box.withLockedValue { $0.player } }
    /// Whether the accessory's services must change for `player` (a battery came or went).
    func needsRebuild(for player: TopologyPlayer) -> Bool { box.withLockedValue { ($0.battery != nil) != (player.battery != nil) } }

    func build(player: TopologyPlayer, settings: SonosPlugin.Settings, host: PluginReference, cached: Accessory? = nil, identify: @escaping @Sendable () async throws -> Void) -> Accessory {
        let channel = player.channel ?? ""
        let name = "\(player.zoneName) Sonos \(channel) LED"
        let led = LEDService.make(name: name, channel: channel, faultStatus: true)
        led.characteristic(adding: SonosCharacteristic.configuredName).value = .string(name)
        led.characteristic(SonosCharacteristic.configuredName).onWrite { value in
            guard value.stringValue?.isEmpty == false else { throw HAPStatusError(.invalidValueInRequest) }
        }
        led.characteristic(adding: SonosCharacteristic.lastSeen).value = .string(LastSeen.never)
        var services = [led]
        var battery: Service?
        if let level = player.battery {
            let service = Service(.battery, name: "\(player.accessoryName) Battery", optional: [.batteryLevel, .chargingState])
            ZoneAccessory.show(level, on: service)
            battery = service
            services.append(service)
        }
        let accessory = Accessory(
            id: SonosPlugin.accessoryID(id), name: player.accessoryName, manufacturer: description.manufacturer, model: description.model,
            serialNumber: id, firmwareRevision: description.displayVersion, category: .speaker, services: services, onIdentify: identify)
        if let source = self.accessory ?? cached { accessory.takeValues(from: source) }
        let id = id
        LEDService.wire(led, settings: settings, client: { await host.plugin?.client(id) }, isBlinking: { [blinking] in blinking.withLockedValue { $0 } })
        box.withLockedValue { $0 = (player, accessory, led, battery) }
        return accessory
    }

    func applyTopology(_ player: TopologyPlayer) {
        let battery = box.withLockedValue { state -> Service? in
            state.player = player
            return state.battery
        }
        if let battery, let level = player.battery { ZoneAccessory.show(level, on: battery) }
    }

    func setLost(_ lost: Bool) {
        guard let accessory, let led else { return }
        led[.statusFault]?.value = .int(lost ? HAPConstants.StatusFault.generalFault : HAPConstants.StatusFault.noFault)
        if accessory.isUnavailable != lost { accessory.isUnavailable = lost }
    }

    func seen(_ date: Date?) {
        led?[SonosCharacteristic.lastSeen]?.value = .string(LastSeen.text(date))
    }
}
