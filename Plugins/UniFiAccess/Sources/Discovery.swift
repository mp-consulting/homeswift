import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A UniFi console that answered the discovery probe.
struct DiscoveredConsole: Sendable, Equatable {
    var ip: String
    var mac: String = ""
    var name: String
    var model: String = ""
    var modelLong: String = ""
    var firmware: String = ""

    /// A UniFi OS console, which runs UniFi Access and Protect (a gateway, a Cloud Key, a recorder), rather than one of
    /// the access points, chimes, hubs or cameras that answer the probe too: a console reports a UniFi OS version as its
    /// firmware (`5.1.34`) where a device reports its own (`UP.esp32.v1.7.20…`), and a console's model code.
    var isConsole: Bool {
        let code = model.uppercased().replacingOccurrences(of: "-", with: "")
        return ["UDM", "UDR", "UDW", "UCG", "UCK", "UNVR", "ENVR", "EFG"].contains { code.hasPrefix($0) }
            || firmware.range(of: #"^\d+\.\d+(\.\d+)*$"#, options: .regularExpression) != nil
    }

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
                // A console can first answer with a stub of no model or firmware (`uum_controller`, from another port): only
                // console answers count, so the stub does not take the place of the real one.
                guard let console = parse(Array(datagram.data)), console.isConsole, !found.contains(where: { $0.ip == console.ip }) else { continue }
                found.append(console)
            }
            return found
        }
        let (broadcasts, unicast) = targets(interfaces: localIPv4Networks().filter { !$0.isLoopback })
        // A probe to an address nobody has can fail; discovery carries on.
        for address in broadcasts + unicast { try? await socket.send(Data(probe), to: address, port: port) }
        try? await Task.sleep(for: timeout)
        await socket.close()
        // Only consoles have a login to set up; one with several networks answers from each of its addresses.
        var consoles: [DiscoveredConsole] = []
        for console in await collect.value where !consoles.contains(where: { !$0.mac.isEmpty && $0.mac == console.mac }) {
            consoles.append(console)
        }
        // Not those without UniFi Access: a gateway beside a recorder that runs it, say.
        return await running(consoles, app: "/proxy/access/api/v2/access/info", address: \.ip)
    }

    /// Whether the controller answers HTTPS on its address within five seconds (`/checkStatus`). The name is
    /// resolved here once and every address it has vetted: one on loopback, link-local or unspecified answers
    /// false (`isValidAddress` only sees the spelling), and the probe goes to the vetted address with the name as
    /// `Host`, so a second DNS answer cannot steer it elsewhere.
    static func isOnline(address: String, resolve: @Sendable (String) async -> [String] = systemResolve) async -> Bool {
        guard AccessSettings.isValidAddress(address), let components = URLComponents(string: "https://\(address)/"), let host = components.host else { return false }
        let addresses = await resolve(host)
        guard let vetted = addresses.first, !addresses.contains(where: isBlocked) else { return false }
        var target = components
        target.host = vetted.contains(":") ? "[\(vetted)]" : vetted
        guard let url = target.url else { return false }
        var request = HTTPRequest(method: "HEAD", url: url, timeout: .seconds(5))
        request.setHeader("Host", address)
        do {
            _ = try await HTTPClient(tls: .any).send(request)
            return true
        } catch {
            return false
        }
    }

    /// Whether a numeric address is refused: loopback, link-local (the cloud metadata address among them),
    /// unspecified, and anything that is not an address.
    static func isBlocked(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let raw = UInt32(bigEndian: v4.s_addr)
            return raw >> 24 == 0 || raw >> 24 == 127 || raw >> 16 == 0xA9FE
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address.split(separator: "%").first.map(String.init) ?? address, &v6) == 1 else { return true }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        // An IPv4-mapped address is judged as its IPv4 address.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF { return isBlocked(bytes[12..<16].map(String.init).joined(separator: ".")) }
        // ::/96 (unspecified, loopback, IPv4-compatible) and fe80::/10.
        return bytes[0..<12].allSatisfy { $0 == 0 } || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
    }

    /// The system resolver (`getaddrinfo`, off the cooperative pool): every address of a name, numeric.
    @Sendable static func systemResolve(_ host: String) async -> [String] {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            #if canImport(Glibc)
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
            #else
            hints.ai_socktype = SOCK_STREAM
            #endif
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
            defer { freeaddrinfo(first) }
            var addresses: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let entry = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !addresses.contains(text) { addresses.append(text) }
                }
                cursor = entry.pointee.ai_next
            }
            return addresses
        }.value
    }
}
