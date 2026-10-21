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
    /// Prefers the resolved IPv4 address, then IPv6, then the host name (which needs `.local` resolution).
    init?(_ service: BonjourService) {
        guard let id = service.txt["id"]?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        var hostName = service.hostName
        if hostName.hasSuffix(".") { hostName.removeLast() }
        let host = service.addresses.first { !$0.contains(":") } ?? service.addresses.first ?? hostName
        self.init(name: service.name, mac: id, host: host, port: service.port)
    }
}
