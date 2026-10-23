import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// A UniFi console that answered the discovery probe.
struct DiscoveredConsole: Sendable, Equatable {
    var ip: String
    var mac: String = ""
    var name: String
    var model: String = ""
    var modelLong: String = ""
    var firmware: String = ""

    var json: JSONValue {
        ["ip": .string(ip), "mac": .string(mac), "name": .string(name), "model": .string(model), "modelLong": .string(modelLong), "firmware": .string(firmware)]
    }
}

/// Ubiquiti's discovery protocol, as the Homebridge plugin's settings server used it: a four-byte probe to UDP
/// port 10001, broadcast on every local subnet and sent to every host of the five /24 subnets on either side of
/// each (broadcasts do not cross routers); devices answer with TLV fields.
enum UbiquitiDiscovery {
    static let port = 10001
    static let probe: [UInt8] = [0x01, 0x00, 0x00, 0x00]
    static let adjacentSubnetRange = 5
    static let timeout: Duration = .seconds(5)

    enum Field: UInt8 {
        case macIP = 0x02
        case firmware = 0x03
        case hostname = 0x0B
        case modelShort = 0x0C
        case modelLong = 0x14
    }

    /// Parses an answer: a four-byte header, then type, 16-bit length, value. nil without an IP address.
    static func parse(_ bytes: [UInt8]) -> DiscoveredConsole? {
        guard bytes.count >= 4 else { return nil }
        var offset = 4
        var ip: String?
        var mac = ""
        var hostname: String?
        var model = ""
        var modelLong = ""
        var firmware = ""
        while offset + 3 <= bytes.count {
            let type = bytes[offset]
            let length = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            offset += 3
            guard offset + length <= bytes.count else { break }
            let value = Array(bytes[offset..<offset + length])
            let text = String(decoding: value, as: UTF8.self)
            switch Field(rawValue: type) {
            case .macIP where length >= 10:
                mac = value[0..<6].map { String(format: "%02x", $0) }.joined(separator: ":")
                ip = value[6..<10].map(String.init).joined(separator: ".")
            case .hostname: hostname = text
            case .modelShort: model = text
            case .modelLong: modelLong = text
            case .firmware: firmware = text
            default: break
            }
            offset += length
        }
        guard let ip else { return nil }
        let name = [hostname, model.isEmpty ? nil : model].compactMap { $0 }.first { !$0.isEmpty } ?? ip
        return DiscoveredConsole(ip: ip, mac: mac, name: name, model: model, modelLong: modelLong, firmware: firmware)
    }

    /// Where the probe goes: the broadcast address of every IPv4 interface, and each host of the /24 subnets
    /// around the ones with a /24 mask or narrower.
    static func targets(interfaces: [IPv4Network]) -> (broadcasts: [String], unicast: [String]) {
        var broadcasts = ["255.255.255.255"]
        var local: [UInt32] = []
        for interface in interfaces {
            let broadcast = IPv4Network.dotted(interface.broadcast)
            if !broadcasts.contains(broadcast) { broadcasts.append(broadcast) }
            if interface.netmask >> 8 & 0xFF == 0xFF { local.append(interface.address >> 8) }
        }
        func dotted(_ subnet: UInt32) -> String { "\(subnet >> 16 & 0xFF).\(subnet >> 8 & 0xFF).\(subnet & 0xFF)" }
        var scanned = Set(local.map(dotted))
        var unicast: [String] = []
        for subnet in local {
            for offset in -adjacentSubnetRange...adjacentSubnetRange {
                let third = Int(subnet & 0xFF) + offset
                guard (0...255).contains(third) else { continue }
                let key = dotted(subnet & ~0xFF | UInt32(third))
                guard scanned.insert(key).inserted else { continue }
                for host in 1...254 { unicast.append("\(key).\(host)") }
            }
        }
        return (broadcasts, unicast)
    }

    static func discover(logger: Logger, timeout: Duration = timeout) async -> [DiscoveredConsole] {
        let socket: UDPSocket
        do {
            socket = try await UDPSocket.bind(reuseAddress: true, broadcast: true)
        } catch {
            logger.warning("Discovery could not open a UDP socket: \(error)")
            return []
        }
        let datagrams = socket.datagrams
        let collect = Task {
            var found: [DiscoveredConsole] = []
            for await datagram in datagrams {
                guard let console = parse(Array(datagram.data)), !found.contains(where: { $0.ip == console.ip }) else { continue }
                found.append(console)
            }
            return found
        }
        let (broadcasts, unicast) = targets(interfaces: localIPv4Networks().filter { !$0.isLoopback })
        // A probe to an address nobody has can fail; discovery carries on.
        for address in broadcasts + unicast { try? await socket.send(Data(probe), to: address, port: port) }
        try? await Task.sleep(for: timeout)
        await socket.close()
        return await collect.value
    }

    /// Whether the controller answers HTTPS on its address within five seconds (`/checkStatus`).
    static func isOnline(address: String) async -> Bool {
        guard let url = URL(string: "https://\(address)/") else { return false }
        do {
            _ = try await HTTPClient(tls: .any).send(HTTPRequest(method: "HEAD", url: url, timeout: .seconds(5)))
            return true
        } catch {
            return false
        }
    }
}
