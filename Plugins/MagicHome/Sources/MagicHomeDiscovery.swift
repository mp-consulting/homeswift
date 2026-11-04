import Foundation
import HomeswiftNetwork

/// A reply to `HF-A11ASSISTHREAD` (section 4.1, 10.6): `<ip>,<MAC>,<module>`.
struct MagicHomeAnnouncement: Sendable, Equatable {
    var address: String
    /// The Device Id: 12 hexadecimal digits, uppercase, without separators.
    var mac: String
    /// The Wi-Fi module (`AK001-ZJ2145`), the accessory's model.
    var module: String
}

/// A reply to `AT+LVER\r`: `+ok=<model hex>_<version hex>_<YYYYMMDD>_<module info>` (section 10.6), of which the plugin
/// reads the model and version.
struct MagicHomeVersionReply: Sendable, Equatable {
    var model: UInt8?
    var version: UInt8?
}

/// A device a scan found: its announcement, and its model and version when it answered `AT+LVER`.
struct MagicHomeFound: Sendable, Equatable {
    var announcement: MagicHomeAnnouncement
    var version: MagicHomeVersionReply?
}

/// The UDP socket a scan uses; tests use a fake.
protocol MagicHomeDiscoverySocket: Sendable {
    var datagrams: AsyncStream<(data: Data, address: String)> { get }
    func send(_ data: Data, to host: String, port: Int) async throws
    func close() async
}

extension UDPSocket: MagicHomeDiscoverySocket {}

enum MagicHomeDiscovery {
    static let port = 48899
    static let probe = Data("HF-A11ASSISTHREAD".utf8)
    static let versionQuery = Data("AT+LVER\r".utf8)
    /// The most devices one scan keeps: anyone on the network can answer.
    static let maximumReplies = 256

    /// The 12 digits of a MAC address, uppercase, without `:` or `-`; nil for what is not one.
    static func bareMAC(_ text: String) -> String? {
        MACAddress.canonical(text)?.replacingOccurrences(of: ":", with: "")
    }

    /// A discovery reply; nil for the socket's own probe heard back, a reply of fewer than 3 or more than 4 fields, or
    /// one without a MAC. The address is the datagram's sender, which the replies to `AT+LVER` are matched by and which
    /// answered from the network (a reply's own first field is anyone's say), else the reply's first field.
    static func announcement(_ data: Data, from sender: String) -> MagicHomeAnnouncement? {
        guard data != probe, data != versionQuery, data.count <= 256 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (3...4).contains(fields.count), let mac = bareMAC(fields[1]) else { return nil }
        let address = IPv4Network.parse(sender) != nil ? sender : fields[0]
        guard IPv4Network.parse(address) != nil else { return nil }
        return MagicHomeAnnouncement(address: address, mac: mac, module: fields[2])
    }

    /// An `AT+LVER` reply; nil for anything else.
    static func versionReply(_ data: Data) -> MagicHomeVersionReply? {
        guard data.count <= 256 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("+ok=") else { return nil }
        let fields = text.dropFirst(4).split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard let first = fields.first, !first.isEmpty else { return nil }
        // A single field is the version alone (old devices).
        if fields.count == 1 { return MagicHomeVersionReply(model: nil, version: UInt8(first, radix: 16)) }
        return MagicHomeVersionReply(model: UInt8(first, radix: 16), version: UInt8(fields[1], radix: 16))
    }

    /// Where the probe goes: the directed broadcast of each IPv4 interface that is not loopback, then `extra` (broadcast
    /// addresses and lights by address), each once.
    static func targets(networks: [IPv4Network], extra: [String]) -> [String] {
        var targets: [String] = []
        for network in networks where !network.isLoopback {
            let broadcast = IPv4Network.dotted(network.broadcast)
            if !targets.contains(broadcast) { targets.append(broadcast) }
        }
        for address in extra.map({ $0.trimmingCharacters(in: .whitespaces) }) where IPv4Network.parse(address) != nil && !targets.contains(address) {
            targets.append(address)
        }
        return targets
    }

    /// One scan: the probe to each target, `AT+LVER` a moment later, the replies heard within `window`. A datagram from
    /// one of `ownAddresses` is the socket's own broadcast heard back.
    static func scan(on socket: any MagicHomeDiscoverySocket, targets: [String], window: Duration, ownAddresses: Set<String>) async -> [MagicHomeFound] {
        let collected = Task { () -> (announcements: [String: MagicHomeAnnouncement], versions: [String: MagicHomeVersionReply]) in
            var announcements: [String: MagicHomeAnnouncement] = [:], versions: [String: MagicHomeVersionReply] = [:]
            for await datagram in socket.datagrams {
                guard !ownAddresses.contains(datagram.address) else { continue }
                if let version = versionReply(datagram.data), versions[datagram.address] != nil || versions.count < maximumReplies {
                    versions[datagram.address] = version
                } else if let announcement = announcement(datagram.data, from: datagram.address), announcements[announcement.mac] == nil,
                          announcements.count < maximumReplies {
                    // The first reply of a MAC wins (section 4.1); the later ones are its echoes on other interfaces.
                    announcements[announcement.mac] = announcement
                }
                if Task.isCancelled { break }
            }
            return (announcements, versions)
        }
        for target in targets { try? await socket.send(probe, to: target, port: port) }
        // flux_led's pause between its datagrams: the module answers one at a time.
        let gap = window / 5
        try? await Task.sleep(for: gap)
        for target in targets { try? await socket.send(versionQuery, to: target, port: port) }
        try? await Task.sleep(for: window - gap)
        await socket.close()
        collected.cancel()
        let result = await collected.value
        return result.announcements.values
            .map { MagicHomeFound(announcement: $0, version: result.versions[$0.address]) }
            .sorted { $0.announcement.mac < $1.announcement.mac }
    }

    /// The IPv4 addresses of this machine.
    static func ownAddresses() -> Set<String> {
        Set(NetworkInterfaces.ipv4().map { IPv4Network.dotted($0.address) })
    }
}
