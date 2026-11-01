import Foundation
import HomeswiftNetwork

/// Finds UniFi consoles with the Ubiquiti discovery protocol, as the settings page of the Homebridge plugin
/// does: a four-byte probe on UDP port 10001, broadcast on every local subnet and sent to each host of the
/// five /24 subnets on either side (broadcasts do not cross routers); devices answer with TLV fields.
enum UbiquitiDiscovery {
    struct Console: Sendable, Equatable {
        var firmware: String
        var ip: String
        var mac: String
        var model: String
        var modelLong: String
        var name: String

    /// A UniFi OS console, which runs UniFi Access and Protect (a gateway, a Cloud Key, a recorder), rather than one of
    /// the access points, chimes, hubs or cameras that answer the probe too: a console reports a UniFi OS version as its
    /// firmware (`5.1.34`) where a device reports its own (`UP.esp32.v1.7.20…`), and a console's model code.
    var isConsole: Bool {
        let code = model.uppercased().replacingOccurrences(of: "-", with: "")
        return ["UDM", "UDR", "UDW", "UCG", "UCK", "UNVR", "ENVR", "EFG"].contains { code.hasPrefix($0) }
            || firmware.range(of: #"^\d+\.\d+(\.\d+)*$"#, options: .regularExpression) != nil
    }
    }

    static let port = 10001
    static let probe: [UInt8] = [0x01, 0x00, 0x00, 0x00]
    static let adjacentSubnetRange = 5
    static let timeout: Duration = .seconds(5)

    /// Parses a discovery answer: a four-byte header, then type (1 byte), length (2 bytes) and value.
    static func parse(_ message: [UInt8]) -> Console? {
        guard message.count >= 4 else { return nil }
        var mac = "", ip = "", hostname = "", model = "", modelLong = "", firmware = ""
        var offset = 4
        while offset + 3 <= message.count {
            let type = message[offset]
            let length = Int(message[offset + 1]) << 8 | Int(message[offset + 2])
            offset += 3
            guard offset + length <= message.count else { break }
            let value = Array(message[offset..<(offset + length)])
            switch type {
            case 0x02 where length >= 10:
                mac = value[0..<6].map { String(format: "%02x", $0) }.joined(separator: ":")
                ip = value[6..<10].map(String.init).joined(separator: ".")
            case 0x0B: hostname = String(decoding: value, as: UTF8.self)
            case 0x0C: model = String(decoding: value, as: UTF8.self)
            case 0x14: modelLong = String(decoding: value, as: UTF8.self)
            case 0x03: firmware = String(decoding: value, as: UTF8.self)
            default: break
            }
            offset += length
        }
        guard !ip.isEmpty else { return nil }
        return Console(firmware: firmware, ip: ip, mac: mac, model: model, modelLong: modelLong, name: hostname.nonEmpty ?? model.nonEmpty ?? ip)
    }

    /// The addresses to probe: each interface's broadcast address and the hosts of adjacent /24 subnets.
    static func targets(networks: [IPv4Network]) -> [String] {
        var broadcasts: [String] = ["255.255.255.255"]
        var subnets: [UInt32] = []
        for network in networks {
            let text = IPv4Network.dotted(network.broadcast)
            if !broadcasts.contains(text) { broadcasts.append(text) }
            if network.netmask >> 8 & 0xFF == 255 { subnets.append(network.address >> 8) }
        }
        var scanned = Set(subnets)
        var hosts: [String] = []
        for subnet in subnets {
            for offset in -adjacentSubnetRange...adjacentSubnetRange {
                let third = Int(subnet & 0xFF) + offset
                guard (0...255).contains(third) else { continue }
                let key = subnet & ~0xFF | UInt32(third)
                guard scanned.insert(key).inserted else { continue }
                let prefix = "\(key >> 16).\(key >> 8 & 0xFF).\(third)"
                hosts += (1...254).map { "\(prefix).\($0)" }
            }
        }
        return broadcasts + hosts
    }

    /// Whether the console at `address` runs the app whose API answers at `path`. Asked without signing in, a console
    /// with the app answers from its API (a 401, in JSON); one without answers its own web page. One that does not
    /// answer is kept: signing in says what is wrong.
    static func runsApp(at path: String, on address: String,
                        send: @Sendable (HTTPRequest) async throws -> HTTPResponse = { try await HTTPClient(tls: .any).send($0) }) async -> Bool {
        // An answer can claim any address: not this machine's own, nor link-local ones (a cloud's metadata).
        guard !["0.", "127.", "169.254."].contains(where: address.hasPrefix) else { return false }
        guard let url = URL(string: "https://\(address)\(path)"), let response = try? await send(HTTPRequest(method: "GET", url: url, timeout: .seconds(5))) else {
            return true
        }
        return response.header("content-type")?.lowercased().hasPrefix("text/html") != true
    }

    /// The consoles that run the app at `path`, asked all at once.
    static func running<Found: Sendable>(_ consoles: [Found], app path: String, address: (Found) -> String,
                                         send: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse = { try await HTTPClient(tls: .any).send($0) }) async -> [Found] {
        let addresses = consoles.map(address)
        let answers = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, address) in addresses.enumerated() { group.addTask { (index, await runsApp(at: path, on: address, send: send)) } }
            var runs = [Bool](repeating: true, count: addresses.count)
            for await (index, answer) in group { runs[index] = answer }
            return runs
        }
        return consoles.indices.filter { answers[$0] }.map { consoles[$0] }
    }

    static func discover(log: ProtectLog) async -> [Console] {
        let socket: UDPSocket
        do {
            socket = try await UDPSocket.bind(reuseAddress: true, broadcast: true)
        } catch {
            log.debug("Discovery could not open a UDP socket: \(error)")
            return []
        }
        let listener = Task {
            var found: [Console] = []
            for await datagram in socket.datagrams {
                // A console can first answer with a stub of no model or firmware (`uum_controller`, from another port): only
                // console answers count, so the stub does not take the place of the real one.
                if let console = parse(Array(datagram.data)), console.isConsole, !found.contains(where: { $0.ip == console.ip }) { found.append(console) }
            }
            return found
        }
        // Unreachable hosts of the scan answer with ICMP errors; they mean nothing here.
        for target in targets(networks: localIPv4Networks().filter { !$0.isLoopback }) {
            try? await socket.send(Data(probe), to: target, port: port)
        }
        try? await Task.sleep(for: timeout)
        await socket.close()
        // Only consoles have a login to set up; one with several networks answers from each of its addresses.
        var consoles: [Console] = []
        for console in await listener.value where !consoles.contains(where: { !$0.mac.isEmpty && $0.mac == console.mac }) {
            consoles.append(console)
        }
        // Not those without UniFi Protect: a gateway beside a recorder that runs it, say.
        return await running(consoles, app: "/proxy/protect/api/bootstrap", address: \.ip)
    }
}
