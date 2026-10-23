import Foundation
import NIOCore
import NIOPosix

/// Wake-on-LAN: the magic packet, sent in bursts over UDP broadcast.
public enum WakeOnLAN {
    public static let port = 9

    /// The twelve hex digits of a MAC address, lowercase, however it was spelled. nil when it is not one.
    public static func hexDigits(mac: String) -> String? {
        MACAddress.canonical(mac).map { $0.replacingOccurrences(of: ":", with: "").lowercased() }
    }

    /// Six `0xFF` bytes, then the MAC sixteen times. nil for a malformed MAC.
    public static func magicPacket(mac: String) -> Data? {
        guard let digits = hexDigits(mac: mac) else { return nil }
        let characters = Array(digits)
        let bytes = stride(from: 0, to: 12, by: 2).compactMap { UInt8(String(characters[$0..<$0 + 2]), radix: 16) }
        guard bytes.count == 6 else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    /// Sends the magic packet to every address, `packetsPerBurst` times per burst, `bursts` bursts
    /// `interval` apart: a TV in deep standby polls its network interface and misses single packets.
    public static func wake(
        mac: String, addresses: [String] = ["255.255.255.255"], port: Int = port, bursts: Int = 3, packetsPerBurst: Int = 5,
        interval: Duration = .milliseconds(100), group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws {
        guard let packet = magicPacket(mac: mac) else { throw WakeOnLANError.invalidMAC(mac) }
        let targets = try addresses.map { try SocketAddress(ipAddress: $0, port: port) }
        let socket = try await UDPSocket.bind(port: 0, broadcast: true, group: group)
        do {
            for burst in 0..<max(1, bursts) {
                if burst > 0 { try await Task.sleep(for: interval) }
                for _ in 0..<max(1, packetsPerBurst) {
                    for target in targets { try await socket.send(packet, to: target) }
                }
            }
        } catch {
            await socket.close()
            throw error
        }
        await socket.close()
    }

    /// Wakes a device on the network of `ip`: the limited broadcast, and the directed broadcast of its subnet
    /// when this machine is on it (routers that drop the first still forward the second).
    public static func wake(mac: String, near ip: String) async throws {
        var addresses = ["255.255.255.255"]
        if let directed = broadcastAddress(for: ip) { addresses.append(directed) }
        try await wake(mac: mac, addresses: addresses)
    }

    /// The directed broadcast address of the local IPv4 network that contains `ip` (`192.168.1.255` for a
    /// host on `192.168.1.0/24`), when one of this machine's interfaces is on it. Routers that drop the
    /// limited broadcast still forward it on the segment.
    public static func broadcastAddress(for ip: String) -> String? {
        guard let target = ipv4(ip) else { return nil }
        let network = localIPv4Networks().first { $0.netmask != 0 && $0.netmask != 0xFFFF_FFFF && $0.contains(target) }
        return network.map { IPv4Network.dotted($0.broadcast) }
    }

    /// A dotted IPv4 address as a number; nil for anything else (a host name, IPv6).
    public static func ipv4(_ string: String) -> UInt32? { IPv4Network.parse(string) }

    public static func dotted(_ value: UInt32) -> String { IPv4Network.dotted(value) }
}

public enum WakeOnLANError: Error, CustomStringConvertible, Equatable {
    case invalidMAC(String)

    public var description: String {
        switch self {
        case .invalidMAC(let mac): "\"\(mac)\" is not a MAC address"
        }
    }
}
