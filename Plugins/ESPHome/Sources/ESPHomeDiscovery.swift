import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// A device ESPHome's mDNS service announces (`_esphomelib._tcp`): its host name, port, addresses and TXT record.
struct Announcement: Sendable, Equatable {
    /// The instance name: the device's `name`.
    var name: String
    /// The SRV target without its final dot: `livingroom.local`.
    var hostName: String
    var port: Int
    /// IPv4 first, then IPv6.
    var addresses: [String]
    /// The canonical MAC of the TXT `mac`.
    var mac: String?
    var friendlyName: String?
    var version: String?
    /// The TXT `api_encryption` names the Noise protocol: the device wants its key.
    var encrypted: Bool

    /// The address to connect to, as the Homebridge plugin chose it: the first IPv4 address that is not link-local, or
    /// an IPv6 one; nil keeps the host name.
    var preferredAddress: String? {
        addresses.first { $0.contains(".") && !$0.hasPrefix("169.254.") } ?? addresses.first { $0.contains(":") }
    }

    var displayName: String { friendlyName?.nonEmpty ?? name }
}

enum ESPHomeDiscovery {
    static let serviceType = "_esphomelib._tcp"

    /// What mDNS announces within `window`.
    static func browse(for window: Duration, logger: Logger) async -> [Announcement] {
        let events = BonjourBrowser.browse(type: serviceType, logger: logger)
        var announcements: [String: Announcement] = [:]
        for event in await events.collect(for: window) {
            guard case .found(let service) = event else { continue }
            let announcement = Announcement(service)
            announcements[announcement.mac ?? announcement.hostName] = announcement
        }
        return announcements.values.sorted { $0.name < $1.name }
    }
}

extension Announcement {
    /// TXT values are the device's: cut short and stripped of control characters.
    init(_ service: BonjourService) {
        var host = service.hostName
        if host.hasSuffix(".") { host.removeLast() }
        let name = Sanitized.text(service.name, limit: 63)
        self.init(
            name: name, hostName: host.isEmpty ? (service.addresses.first ?? "\(name).local") : host, port: service.port, addresses: service.addresses,
            mac: service.txt["mac"].flatMap(MACAddress.canonical), friendlyName: service.txt["friendly_name"].map { Sanitized.text($0) },
            version: service.txt["version"].map { Sanitized.text($0, limit: 32) }, encrypted: !(service.txt["api_encryption"] ?? "").isEmpty)
    }
}
