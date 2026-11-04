import Foundation
import Homeswift
import HomeswiftNetwork
import Logging

/// A zone player heard of: an SSDP answer or announcement, or an mDNS `_sonos._tcp` service.
struct DiscoveryHit: Sendable, Equatable {
    var id: String
    var address: String
    var household: String?
    var bootSeq: Int?
}

/// Finds zone players: one SSDP M-SEARCH a second after start, the SSDP announcements on port 1900, and (with `mdns`)
/// Bonjour's `_sonos._tcp`.
enum Discovery {
    static let deviceType = "urn:schemas-upnp-org:device:ZonePlayer:1"
    static let serviceType = "_sonos._tcp"

    /// A search answer (`200 OK` with `ST` the zone player type) or an `ssdp:alive` (`NT` the type): the id from `USN`,
    /// the address the datagram came from.
    static func hit(_ message: SSDPMessage, from address: String) -> DiscoveryHit? {
        let accepted = (message.isSearchResponse && message["st"] == deviceType) || (message.isAlive && message["nt"] == deviceType)
        guard accepted, let usn = message["usn"] else { return nil }
        let fields = usn.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count > 1, !fields[1].isEmpty, !address.isEmpty else { return nil }
        return DiscoveryHit(id: String(fields[1]), address: address, household: message["x-rincon-household"], bootSeq: message["x-rincon-bootseq"].flatMap { Int($0) })
    }

    /// A resolved `_sonos._tcp` service: TXT `uuid`, `hhid` and `bootseq`, and its IPv4 address.
    static func hit(_ service: BonjourService) -> DiscoveryHit? {
        guard let id = service.txt["uuid"], !id.isEmpty, let household = service.txt["hhid"], !household.isEmpty,
              let address = service.addresses.first(where: { !$0.contains(":") }) else { return nil }
        return DiscoveryHit(id: id, address: address, household: household, bootSeq: service.txt["bootseq"].flatMap { Int($0) })
    }

    /// The live discovery, until the consuming task is cancelled.
    @Sendable static func live(mdns: Bool, logger: Logger) -> AsyncStream<DiscoveryHit> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            let (announcements, close) = try await SSDP.listen()
                            await withTaskCancellationHandler {
                                for await received in announcements {
                                    if let hit = hit(received.message, from: received.address) { continuation.yield(hit) }
                                }
                            } onCancel: {
                                Task { await close() }
                            }
                        } catch {
                            logger.warning("SSDP: cannot listen on port \(SSDP.port): \(error); players are found by search\(mdns ? " and mDNS" : "") only")
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(1))
                        for await received in SSDP.search(searchTarget: deviceType, mx: 5, duration: .seconds(5)) {
                            if let hit = hit(received.message, from: received.address) { continuation.yield(hit) }
                        }
                    }
                    if mdns {
                        group.addTask {
                            for await event in BonjourBrowser.browse(type: serviceType, logger: logger) {
                                guard case .found(let service) = event else { continue }
                                if let hit = hit(service) {
                                    continuation.yield(hit)
                                } else {
                                    logger.debug("mDNS: \(service.name): no uuid, hhid or address; ignored")
                                }
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// This machine's address on the network of `ip`, for a player's event callback; the first other address otherwise.
    @Sendable static func localAddress(toward ip: String) -> String {
        let networks = localIPv4Networks().filter { !$0.isLoopback }
        if let target = IPv4Network.parse(ip), let network = networks.first(where: { $0.contains(target) }) {
            return IPv4Network.dotted(network.address)
        }
        return networks.first.map { IPv4Network.dotted($0.address) } ?? "127.0.0.1"
    }
}
