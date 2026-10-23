import Foundation

/// Quality of service of an MQTT message or subscription.
public enum MQTTQoS: UInt8, Sendable, Codable, Comparable {
    case atMostOnce = 0
    case atLeastOnce = 1
    case exactlyOnce = 2

    public static func < (lhs: MQTTQoS, rhs: MQTTQoS) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An MQTT application message: received, published, or the will the broker publishes when the client vanishes.
public struct MQTTMessage: Sendable, Equatable {
    public var topic: String
    public var payload: Data
    public var qos: MQTTQoS
    public var retain: Bool

    public init(topic: String, payload: Data, qos: MQTTQoS = .atMostOnce, retain: Bool = false) {
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retain = retain
    }

    public init(topic: String, string: String, qos: MQTTQoS = .atMostOnce, retain: Bool = false) {
        self.init(topic: topic, payload: Data(string.utf8), qos: qos, retain: retain)
    }

    /// The payload as UTF-8 text.
    public var string: String? { String(data: payload, encoding: .utf8) }
}

/// MQTT topic filters.
public enum MQTTTopic {
    /// Whether `topic` matches `filter`, with the `+` (one level) and `#` (the rest) wildcards.
    public static func matches(filter: String, topic: String) -> Bool {
        let filterLevels = filter.split(separator: "/", omittingEmptySubsequences: false)
        let topicLevels = topic.split(separator: "/", omittingEmptySubsequences: false)
        // Wildcards at the first level do not match topics starting with $ ($SYS, $aws).
        if topic.hasPrefix("$"), let first = filterLevels.first, first == "#" || first == "+" { return false }
        for (index, level) in filterLevels.enumerated() {
            if level == "#" { return true }
            guard index < topicLevels.count else { return false }
            if level != "+", level != topicLevels[index] { return false }
        }
        return filterLevels.count == topicLevels.count
    }
}

/// The protocol level sent in CONNECT.
public enum MQTTProtocolVersion: Sendable, Equatable {
    /// MQTT 3.1.1, protocol level 4.
    case v3_1_1
    /// MQTT 3.1 (`MQIsdp`, level 3), for old brokers.
    case v3_1
}

public enum MQTTError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidURL(String)
    /// The broker refused CONNECT with this return code (1 protocol version, 2 client id, 3 unavailable,
    /// 4 bad user name or password, 5 not authorized).
    case connectionRefused(code: UInt8)
    case timeout
    case notConnected
    /// The connection dropped while waiting for an acknowledgement.
    case connectionLost
    /// The broker answered PINGREQ with nothing for two keep-alive intervals.
    case keepAliveTimeout
    /// The broker refused a subscription (SUBACK 0x80).
    case subscriptionRefused(topic: String)
    case packetTooLarge(limit: Int)
    case protocolError(String)

    public var description: String {
        switch self {
        case .invalidURL(let url): "cannot connect to the MQTT broker at \(url)"
        case .connectionRefused(let code):
            switch code {
            case 1: "the broker refused the connection: unacceptable protocol version"
            case 2: "the broker refused the connection: client identifier rejected"
            case 3: "the broker refused the connection: server unavailable"
            case 4: "the broker refused the connection: bad user name or password"
            case 5: "the broker refused the connection: not authorized"
            default: "the broker refused the connection (code \(code))"
            }
        case .timeout: "the MQTT broker did not answer in time"
        case .notConnected: "not connected to the MQTT broker"
        case .connectionLost: "the connection to the MQTT broker dropped"
        case .keepAliveTimeout: "the MQTT broker stopped answering keep-alive pings"
        case .subscriptionRefused(let topic): "the broker refused the subscription to \(topic)"
        case .packetTooLarge(let limit): "an MQTT packet is larger than \(limit) bytes"
        case .protocolError(let reason): "MQTT protocol error: \(reason)"
        }
    }
}

/// The CONNECT packet's fields.
struct MQTTConnect: Equatable, Sendable {
    var version: MQTTProtocolVersion = .v3_1_1
    var clientID: String
    var username: String?
    var password: String?
    var keepAlive: UInt16
    var cleanSession: Bool
    var will: MQTTMessage?
}

struct MQTTSubscription: Equatable, Sendable {
    var topic: String
    var qos: MQTTQoS
}

/// MQTT 3.1.1 control packets, encoded and decoded.
enum MQTTPacket: Equatable, Sendable {
    case connect(MQTTConnect)
    case connack(sessionPresent: Bool, returnCode: UInt8)
    case publish(MQTTMessage, packetID: UInt16?, duplicate: Bool)
    case puback(UInt16)
    case pubrec(UInt16)
    case pubrel(UInt16)
    case pubcomp(UInt16)
    case subscribe(packetID: UInt16, [MQTTSubscription])
    case suback(packetID: UInt16, returnCodes: [UInt8])
    case unsubscribe(packetID: UInt16, [String])
    case unsuback(UInt16)
    case pingreq
    case pingresp
    case disconnect

    func encode() -> [UInt8] {
        var body: [UInt8] = []
        let header: UInt8
        switch self {
        case .connect(let connect):
            header = 0x10
            switch connect.version {
            case .v3_1_1:
                body.appendString("MQTT")
                body.append(4)
            case .v3_1:
                body.appendString("MQIsdp")
                body.append(3)
            }
            var flags: UInt8 = connect.cleanSession ? 0x02 : 0
            if let will = connect.will {
                flags |= 0x04 | (will.qos.rawValue << 3) | (will.retain ? 0x20 : 0)
            }
            if connect.password != nil { flags |= 0x40 }
            if connect.username != nil { flags |= 0x80 }
            body.append(flags)
            body.appendUInt16(connect.keepAlive)
            body.appendString(connect.clientID)
            if let will = connect.will {
                body.appendString(will.topic)
                body.appendBytes(Array(will.payload))
            }
            if let username = connect.username { body.appendString(username) }
            if let password = connect.password { body.appendBytes(Array(password.utf8)) }
        case .connack(let sessionPresent, let returnCode):
            header = 0x20
            body = [sessionPresent ? 1 : 0, returnCode]
        case .publish(let message, let packetID, let duplicate):
            header = 0x30 | (duplicate ? 0x08 : 0) | (message.qos.rawValue << 1) | (message.retain ? 0x01 : 0)
            body.appendString(message.topic)
            if message.qos != .atMostOnce { body.appendUInt16(packetID ?? 0) }
            body.append(contentsOf: message.payload)
        case .puback(let id):
            header = 0x40
            body.appendUInt16(id)
        case .pubrec(let id):
            header = 0x50
            body.appendUInt16(id)
        case .pubrel(let id):
            header = 0x62
            body.appendUInt16(id)
        case .pubcomp(let id):
            header = 0x70
            body.appendUInt16(id)
        case .subscribe(let id, let subscriptions):
            header = 0x82
            body.appendUInt16(id)
            for subscription in subscriptions {
                body.appendString(subscription.topic)
                body.append(subscription.qos.rawValue)
            }
        case .suback(let id, let codes):
            header = 0x90
            body.appendUInt16(id)
            body.append(contentsOf: codes)
        case .unsubscribe(let id, let topics):
            header = 0xA2
            body.appendUInt16(id)
            for topic in topics { body.appendString(topic) }
        case .unsuback(let id):
            header = 0xB0
            body.appendUInt16(id)
        case .pingreq:
            header = 0xC0
        case .pingresp:
            header = 0xD0
        case .disconnect:
            header = 0xE0
        }
        var packet: [UInt8] = [header]
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 0x80 }
            packet.append(byte)
        } while length > 0
        return packet + body
    }

    /// Decodes one packet's fixed-header byte and body.
    static func decode(header: UInt8, body: ArraySlice<UInt8>) throws -> MQTTPacket {
        var reader = Reader(remaining: body)
        let flags = header & 0x0F
        switch header >> 4 {
        case 1:
            let name = try reader.string()
            let level = try reader.byte()
            let version: MQTTProtocolVersion
            switch (name, level) {
            case ("MQTT", 4): version = .v3_1_1
            case ("MQIsdp", 3): version = .v3_1
            default: throw MQTTError.protocolError("unknown protocol \(name) \(level)")
            }
            let connectFlags = try reader.byte()
            let keepAlive = try reader.uint16()
            let clientID = try reader.string()
            var will: MQTTMessage?
            if connectFlags & 0x04 != 0 {
                let topic = try reader.string()
                let payload = try reader.bytes()
                will = MQTTMessage(
                    topic: topic, payload: Data(payload), qos: MQTTQoS(rawValue: (connectFlags >> 3) & 0x03) ?? .atMostOnce,
                    retain: connectFlags & 0x20 != 0
                )
            }
            let username = connectFlags & 0x80 != 0 ? try reader.string() : nil
            let password = connectFlags & 0x40 != 0 ? String(decoding: try reader.bytes(), as: UTF8.self) : nil
            return .connect(
                MQTTConnect(
                    version: version, clientID: clientID, username: username, password: password, keepAlive: keepAlive,
                    cleanSession: connectFlags & 0x02 != 0, will: will
                )
            )
        case 2:
            return .connack(sessionPresent: try reader.byte() & 0x01 != 0, returnCode: try reader.byte())
        case 3:
            guard let qos = MQTTQoS(rawValue: (flags >> 1) & 0x03) else { throw MQTTError.protocolError("invalid QoS") }
            let topic = try reader.string()
            let packetID = qos == .atMostOnce ? nil : try reader.uint16()
            let message = MQTTMessage(topic: topic, payload: Data(reader.rest()), qos: qos, retain: flags & 0x01 != 0)
            return .publish(message, packetID: packetID, duplicate: flags & 0x08 != 0)
        case 4: return .puback(try reader.uint16())
        case 5: return .pubrec(try reader.uint16())
        case 6: return .pubrel(try reader.uint16())
        case 7: return .pubcomp(try reader.uint16())
        case 8:
            let id = try reader.uint16()
            var subscriptions: [MQTTSubscription] = []
            while !reader.isAtEnd {
                let topic = try reader.string()
                subscriptions.append(MQTTSubscription(topic: topic, qos: MQTTQoS(rawValue: try reader.byte() & 0x03) ?? .atMostOnce))
            }
            return .subscribe(packetID: id, subscriptions)
        case 9:
            let id = try reader.uint16()
            return .suback(packetID: id, returnCodes: Array(reader.rest()))
        case 10:
            let id = try reader.uint16()
            var topics: [String] = []
            while !reader.isAtEnd { topics.append(try reader.string()) }
            return .unsubscribe(packetID: id, topics)
        case 11: return .unsuback(try reader.uint16())
        case 12: return .pingreq
        case 13: return .pingresp
        case 14: return .disconnect
        default: throw MQTTError.protocolError("unknown packet type \(header >> 4)")
        }
    }

    private struct Reader {
        var remaining: ArraySlice<UInt8>

        var isAtEnd: Bool { remaining.isEmpty }

        mutating func byte() throws -> UInt8 {
            guard let byte = remaining.popFirst() else { throw MQTTError.protocolError("truncated packet") }
            return byte
        }

        mutating func uint16() throws -> UInt16 {
            UInt16(try byte()) << 8 | UInt16(try byte())
        }

        mutating func bytes() throws -> ArraySlice<UInt8> {
            let length = Int(try uint16())
            guard remaining.count >= length else { throw MQTTError.protocolError("truncated packet") }
            defer { remaining = remaining.dropFirst(length) }
            return remaining.prefix(length)
        }

        mutating func string() throws -> String {
            String(decoding: try bytes(), as: UTF8.self)
        }

        mutating func rest() -> ArraySlice<UInt8> {
            defer { remaining = [] }
            return remaining
        }
    }
}

/// Splits a byte stream into packets; bytes arrive in any chunks (TCP segments, WebSocket messages).
struct MQTTPacketParser {
    let limit: Int
    private var buffer: [UInt8] = []
    private var start = 0

    init(limit: Int = 16 * 1024 * 1024) {
        self.limit = limit
    }

    mutating func append<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        if start > 0, start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 64 * 1024 {
            buffer.removeFirst(start)
            start = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// The next complete packet, or nil until more bytes arrive.
    mutating func next() throws -> MQTTPacket? {
        guard buffer.count - start >= 2 else { return nil }
        var length = 0
        var multiplier = 1
        var index = start + 1
        while true {
            guard index < buffer.count else { return nil }
            let byte = buffer[index]
            length += Int(byte & 0x7F) * multiplier
            index += 1
            if byte & 0x80 == 0 { break }
            multiplier *= 128
            guard multiplier <= 128 * 128 * 128 else { throw MQTTError.protocolError("malformed remaining length") }
        }
        guard length <= limit else { throw MQTTError.packetTooLarge(limit: limit) }
        guard buffer.count - index >= length else { return nil }
        let header = buffer[start]
        let body = buffer[index..<(index + length)]
        start = index + length
        return try MQTTPacket.decode(header: header, body: body)
    }
}

extension [UInt8] {
    fileprivate mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    fileprivate mutating func appendBytes(_ bytes: [UInt8]) {
        appendUInt16(UInt16(clamping: bytes.count))
        append(contentsOf: bytes.prefix(Int(UInt16.max)))
    }

    fileprivate mutating func appendString(_ string: String) {
        appendBytes(Array(string.utf8))
    }
}
