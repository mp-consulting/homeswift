import Foundation

/// One-shot multicast DNS queries (RFC 6762 section 5.1): sent from an ephemeral port, so responders answer by
/// unicast to that port, and each answer arrives with the responder's own address. dns_sd (`BonjourBrowser`) never
/// says which host sent an answer; Node's bonjour-service does (its `referer`), and plugins ported from it fall back
/// to that address when a service's records carry none usable.
///
/// ```swift
/// for response in try await MDNSQuery.query("_dyson_mqtt._tcp.local", duration: .seconds(5)) {
///     print(response.sender, response.names)
/// }
/// ```
public enum MDNSQuery {
    public static let multicastAddress = "224.0.0.251"
    public static let port = 5353
    /// The most answer packets one query collects.
    static let maximumResponses = 1024

    /// The record types this asks for.
    public enum RecordType: UInt16, Sendable {
        case a = 1
        case ptr = 12
        case txt = 16
        case aaaa = 28
        case srv = 33
        case any = 255
    }

    /// One answer packet.
    public struct Response: Sendable, Equatable {
        /// The responder's IP address, from the datagram.
        public var sender: String
        /// The owner names of the answer and additional records, and the names PTR and SRV records point to, in
        /// packet order without repeats and without the trailing dot (`ABC-AB-12345678._dyson_mqtt._tcp.local`).
        public var names: [String]

        public init(sender: String, names: [String]) {
            self.sender = sender
            self.names = names
        }
    }

    /// Asks for `name` (repeated after one and three seconds, as UDP may lose it) and collects the answers that
    /// arrive within `duration`. `host` and `port` are the multicast group's, or a test responder's.
    public static func query(
        _ name: String, type: RecordType = .ptr, duration: Duration, host: String = multicastAddress, port: Int = port
    ) async throws -> [Response] {
        let socket = try await UDPSocket.bind()
        let packet = Data(encodeQuery(name: name, type: type))
        let deadline = ContinuousClock.now + duration
        // The first query goes at once, here; the repeats from a task (a loaded machine may run it late).
        try? await socket.send(packet, to: host, port: port)
        let sender = Task {
            for delay in [Duration.seconds(1), .seconds(2)] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, ContinuousClock.now < deadline else { return }
                try? await socket.send(packet, to: host, port: port)
            }
        }
        let reader = Task { () -> [Response] in
            var responses: [Response] = []
            for await datagram in socket.datagrams {
                // Anyone on the network can answer; a flood within `duration` stops being collected, not read.
                guard responses.count < maximumResponses, let names = responseNames(Array(datagram.data)), !names.isEmpty else { continue }
                responses.append(Response(sender: datagram.address, names: names))
            }
            return responses
        }
        try? await Task.sleep(until: deadline)
        sender.cancel()
        await socket.close()
        return await reader.value
    }

    /// A standard query, id 0, one question.
    static func encodeQuery(name: String, type: RecordType) -> [UInt8] {
        var packet: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0)
        packet += [UInt8(type.rawValue >> 8), UInt8(type.rawValue & 0xFF), 0, 1]
        return packet
    }

    /// The names in a response's answer and additional records (see `Response.names`); nil for a query or a
    /// malformed packet.
    static func responseNames(_ packet: [UInt8]) -> [String]? {
        guard packet.count >= 12, packet[2] & 0x80 != 0 else { return nil }
        func count(_ offset: Int) -> Int { Int(packet[offset]) << 8 | Int(packet[offset + 1]) }
        var offset = 12
        for _ in 0..<count(4) {
            guard readName(packet, at: &offset) != nil, offset + 4 <= packet.count else { return nil }
            offset += 4
        }
        var names: [String] = []
        func add(_ name: String) { if !name.isEmpty, !names.contains(name) { names.append(name) } }
        for _ in 0..<(count(6) + count(8) + count(10)) {
            guard let owner = readName(packet, at: &offset), offset + 10 <= packet.count else { return nil }
            let type = count(offset)
            let length = count(offset + 8)
            offset += 10
            guard offset + length <= packet.count else { return nil }
            add(owner)
            var data = offset
            if type == RecordType.ptr.rawValue, let target = readName(packet, at: &data) { add(target) }
            if type == RecordType.srv.rawValue, length > 6 {
                data += 6
                if let target = readName(packet, at: &data) { add(target) }
            }
            offset += length
        }
        return names
    }

    /// A name at `offset`, following compression pointers; `offset` moves past the name as written there.
    static func readName(_ packet: [UInt8], at offset: inout Int) -> String? {
        var labels: [String] = []
        var position = offset
        var jumped = false
        var jumps = 0
        while true {
            guard position < packet.count else { return nil }
            let length = Int(packet[position])
            if length == 0 {
                if !jumped { offset = position + 1 }
                return labels.joined(separator: ".")
            }
            if length & 0xC0 == 0xC0 {
                guard position + 1 < packet.count, jumps < 32 else { return nil }
                if !jumped { offset = position + 2 }
                position = (length & 0x3F) << 8 | Int(packet[position + 1])
                jumped = true
                jumps += 1
                continue
            }
            guard length < 64, position + 1 + length <= packet.count else { return nil }
            labels.append(String(decoding: packet[(position + 1)..<(position + 1 + length)], as: UTF8.self))
            position += 1 + length
        }
    }
}
