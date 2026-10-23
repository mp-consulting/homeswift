import Foundation
import Homeswift
import Logging

/// Finds lights over Bonjour: every `_elg._tcp` service with an `id` (the MAC) in its TXT record.
enum Discovery {
    static let serviceType = "_elg._tcp"

    static func browse(logger: Logger) -> AsyncStream<ElgatoKeyLightsPlugin.DiscoveredLight> {
        AsyncStream { continuation in
            let task = Task {
                for await event in BonjourBrowser.browse(type: serviceType, logger: logger) {
                    guard case .found(let service) = event else { continue }
                    guard let light = ElgatoKeyLightsPlugin.DiscoveredLight(service) else {
                        // Lights are keyed by MAC; without one, unrelated lights would overwrite each other.
                        logger.warning("Ignoring an Elgato service without a device id", metadata: ["service": "\(service.name)"])
                        continue
                    }
                    continuation.yield(light)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ElgatoKeyLightsPlugin.DiscoveredLight {
    /// The light's host name (`elgato-key-light-1234.local`) with the addresses Bonjour looked up; the plugin
    /// picks one with `useIP`. Without a host name, the first address (IPv4 first).
    init?(_ service: BonjourService) {
        guard let id = service.txt["id"]?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        var hostName = service.hostName
        if hostName.hasSuffix(".") { hostName.removeLast() }
        let host = hostName.isEmpty ? service.addresses.first ?? "" : hostName
        self.init(name: service.name, mac: id, host: host, port: service.port, addresses: service.addresses, model: service.txt["md"])
    }
}
