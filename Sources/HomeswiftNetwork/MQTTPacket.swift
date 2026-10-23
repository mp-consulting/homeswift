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
    /// MQTT 5, protocol level 5: properties in CONNECT, CONNACK, PUBLISH, SUBSCRIBE, the acknowledgements and
    /// DISCONNECT, and reason codes (0x80 and above are failures). A broker that only speaks 3.1.1 answers with
    /// return code 1, `connectionRefused(code: 1)`.
    case v5
}

public enum MQTTError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidURL(String)
    /// The broker refused CONNECT with this return code (1 protocol version, 2 client id, 3 unavailable,
    /// 4 bad user name or password, 5 not authorized), or with an MQTT 5 reason code (0x80 and above: 0x84
    /// protocol version, 0x85 client id, 0x86 bad user name or password, 0x87 not authorized, 0x88 unavailable…).
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
    /// MQTT 5: the broker answered a QoS 1 PUBLISH with a failure reason code (0x87 not authorized, 0x97 quota…).
    case publishRefused(topic: String, reasonCode: UInt8)
    /// MQTT 5: the broker sent DISCONNECT with this reason code (0x8E session taken over, 0x8B shutting down…)
    /// and its reason string, if any.
    case disconnectedByBroker(reasonCode: UInt8, reason: String?)

    /// The name of an MQTT 5 reason code, as the specification (and mqtt.js) writes it.
    public static func reasonName(_ code: UInt8) -> String? {
        switch code {
        case 0x80: "Unspecified error"
        case 0x81: "Malformed Packet"
        case 0x82: "Protocol Error"
        case 0x83: "Implementation specific error"
        case 0x84: "Unsupported Protocol Version"
        case 0x85: "Client Identifier not valid"
        case 0x86: "Bad User Name or Password"
        case 0x87: "Not authorized"
        case 0x88: "Server unavailable"
        case 0x89: "Server busy"
        case 0x8A: "Banned"
        case 0x8B: "Server shutting down"
        case 0x8C: "Bad authentication method"
        case 0x8D: "Keep Alive timeout"
        case 0x8E: "Session taken over"
        case 0x8F: "Topic Filter invalid"
        case 0x90: "Topic Name invalid"
        case 0x91: "Packet identifier in use"
        case 0x92: "Packet Identifier not found"
        case 0x93: "Receive Maximum exceeded"
        case 0x94: "Topic Alias invalid"
        case 0x95: "Packet too large"
        case 0x96: "Message rate too high"
        case 0x97: "Quota exceeded"
        case 0x98: "Administrative action"
        case 0x99: "Payload format invalid"
        case 0x9A: "Retain not supported"
        case 0x9B: "QoS not supported"
        case 0x9C: "Use another server"
        case 0x9D: "Server moved"
        case 0x9E: "Shared Subscriptions not supported"
        case 0x9F: "Connection rate exceeded"
        case 0xA0: "Maximum connect time"
        case 0xA1: "Subscription Identifiers not supported"
        case 0xA2: "Wildcard Subscriptions not supported"
        default: nil
        }
    }

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
            default:
                if let name = MQTTError.reasonName(code) {
                    "the broker refused the connection: \(name.lowercased()) (code 0x\(String(code, radix: 16)))"
                } else {
                    "the broker refused the connection (code \(code))"
                }
            }
        case .timeout: "the MQTT broker did not answer in time"
        case .notConnected: "not connected to the MQTT broker"
        case .connectionLost: "the connection to the MQTT broker dropped"
        case .keepAliveTimeout: "the MQTT broker stopped answering keep-alive pings"
        case .subscriptionRefused(let topic): "the broker refused the subscription to \(topic)"
        case .packetTooLarge(let limit): "an MQTT packet is larger than \(limit) bytes"
        case .protocolError(let reason): "MQTT protocol error: \(reason)"
        case .publishRefused(let topic, let code):
            "the broker refused the message to \(topic): \(MQTTError.reasonName(code) ?? "code \(code)")"
        case .disconnectedByBroker(let code, let reason):
            "the broker closed the connection: \(reason ?? MQTTError.reasonName(code) ?? "code \(code)")"
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
    /// MQTT 5 only: the CONNECT properties (the will's are left empty).
    var properties = MQTTProperties()
}

/// MQTT 5 properties: an identifier and a value whose type the identifier fixes.
struct MQTTProperties: Equatable, Sendable, ExpressibleByArrayLiteral {
    enum Value: Equatable, Sendable {
        case byte(UInt8)
        case uint16(UInt16)
        case uint32(UInt32)
        case varint(Int)
        case string(String)
        case binary([UInt8])
        case pair(String, String)
    }

    // The identifiers the client reads or sends.
    static let sessionExpiryInterval: UInt8 = 0x11
    static let assignedClientIdentifier: UInt8 = 0x12
    static let serverKeepAlive: UInt8 = 0x13
    static let reasonString: UInt8 = 0x1F
    static let receiveMaximum: UInt8 = 0x21
    static let topicAliasMaximum: UInt8 = 0x22
    static let userProperty: UInt8 = 0x26
    static let maximumPacketSize: UInt8 = 0x27

    var entries: [(id: UInt8, value: Value)] = []

    init() {}

    init(arrayLiteral elements: (UInt8, Value)...) {
        entries = elements.map { (id: $0.0, value: $0.1) }
    }

    static func == (lhs: MQTTProperties, rhs: MQTTProperties) -> Bool {
        lhs.entries.count == rhs.entries.count && zip(lhs.entries, rhs.entries).allSatisfy { $0.id == $1.id && $0.value == $1.value }
    }

    var isEmpty: Bool { entries.isEmpty }

    func value(_ id: UInt8) -> Value? { entries.first { $0.id == id }?.value }

    func uint16(_ id: UInt8) -> UInt16? {
        if case .uint16(let value) = value(id) { return value }
        return nil
    }

    func uint32(_ id: UInt8) -> UInt32? {
        if case .uint32(let value) = value(id) { return value }
        return nil
    }

    func string(_ id: UInt8) -> String? {
        if case .string(let value) = value(id) { return value }
        return nil
    }

    /// The value type of each identifier the MQTT 5 specification defines (section 2.2.2.2).
    fileprivate enum Kind { case byte, uint16, uint32, varint, string, binary, pair }

    fileprivate static func kind(of id: UInt8) -> Kind? {
        switch id {
        case 0x01, 0x17, 0x19, 0x24, 0x25, 0x28, 0x29, 0x2A: .byte
        case 0x13, 0x21, 0x22, 0x23: .uint16
        case 0x02, 0x11, 0x18, 0x27: .uint32
        case 0x0B: .varint
        case 0x03, 0x08, 0x12, 0x15, 0x1A, 0x1C, 0x1F: .string
        case 0x09, 0x16: .binary
        case 0x26: .pair
        default: nil
        }
    }

    fileprivate func encode() -> [UInt8] {
        var bytes: [UInt8] = []
        for (id, value) in entries {
            bytes.append(id)
            switch value {
            case .byte(let byte): bytes.append(byte)
            case .uint16(let number): bytes.appendUInt16(number)
            case .uint32(let number): bytes.append(contentsOf: [UInt8(number >> 24), UInt8((number >> 16) & 0xFF), UInt8((number >> 8) & 0xFF), UInt8(number & 0xFF)])
            case .varint(let number): bytes.appendVarint(number)
            case .string(let string): bytes.appendString(string)
            case .binary(let data): bytes.appendBytes(data)
            case .pair(let key, let value):
                bytes.appendString(key)
                bytes.appendString(value)
            }
        }
        var encoded: [UInt8] = []
        encoded.appendVarint(bytes.count)
        return encoded + bytes
    }
}

struct MQTTSubscription: Equatable, Sendable {
    var topic: String
    var qos: MQTTQoS
}

/// MQTT control packets (3.1, 3.1.1 and 5), encoded and decoded. The properties and reason codes only exist on
/// the wire in MQTT 5; with the earlier versions they are left out (and read as empty and 0).
enum MQTTPacket: Equatable, Sendable {
    case connect(MQTTConnect)
    /// `returnCode` is the MQTT 5 reason code with version 5.
    case connack(sessionPresent: Bool, returnCode: UInt8, properties: MQTTProperties = [])
    case publish(MQTTMessage, packetID: UInt16?, duplicate: Bool, properties: MQTTProperties = [])
    case puback(UInt16, reasonCode: UInt8 = 0)
    case pubrec(UInt16)
    case pubrel(UInt16)
    case pubcomp(UInt16)
    case subscribe(packetID: UInt16, [MQTTSubscription])
    /// `returnCodes` are the MQTT 5 reason codes with version 5 (0x80 and above refuse).
    case suback(packetID: UInt16, returnCodes: [UInt8], properties: MQTTProperties = [])
    case unsubscribe(packetID: UInt16, [String])
    case unsuback(UInt16, reasonCodes: [UInt8] = [])
    case pingreq
    case pingresp
    case disconnect(reasonCode: UInt8 = 0, properties: MQTTProperties = [])

    /// `version` is the connection's; CONNECT carries its own.
    func encode(version: MQTTProtocolVersion = .v3_1_1) -> [UInt8] {
        let v5 = version == .v5
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
            case .v5:
                body.appendString("MQTT")
                body.append(5)
            }
            // MQTT 5 calls the clean session flag Clean Start; the session's life is the Session Expiry property.
            var flags: UInt8 = connect.cleanSession ? 0x02 : 0
            if let will = connect.will {
                flags |= 0x04 | (will.qos.rawValue << 3) | (will.retain ? 0x20 : 0)
            }
            if connect.password != nil { flags |= 0x40 }
            if connect.username != nil { flags |= 0x80 }
            body.append(flags)
            body.appendUInt16(connect.keepAlive)
            if connect.version == .v5 { body.append(contentsOf: connect.properties.encode()) }
            body.appendString(connect.clientID)
            if let will = connect.will {
                if connect.version == .v5 { body.append(0) }
                body.appendString(will.topic)
                body.appendBytes(Array(will.payload))
            }
            if let username = connect.username { body.appendString(username) }
            if let password = connect.password { body.appendBytes(Array(password.utf8)) }
        case .connack(let sessionPresent, let returnCode, let properties):
            header = 0x20
            body = [sessionPresent ? 1 : 0, returnCode]
            if v5 { body.append(contentsOf: properties.encode()) }
        case .publish(let message, let packetID, let duplicate, let properties):
            header = 0x30 | (duplicate ? 0x08 : 0) | (message.qos.rawValue << 1) | (message.retain ? 0x01 : 0)
            body.appendString(message.topic)
            if message.qos != .atMostOnce { body.appendUInt16(packetID ?? 0) }
            if v5 { body.append(contentsOf: properties.encode()) }
            body.append(contentsOf: message.payload)
        case .puback(let id, let reasonCode):
            header = 0x40
            body.appendUInt16(id)
            // A success without properties may stop after the packet identifier.
            if v5, reasonCode != 0 { body += [reasonCode, 0] }
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
            if v5 { body.append(0) }
            // In MQTT 5 the byte after the filter holds subscription options; QoS stays in its low bits.
            for subscription in subscriptions {
                body.appendString(subscription.topic)
                body.append(subscription.qos.rawValue)
            }
        case .suback(let id, let codes, let properties):
            header = 0x90
            body.appendUInt16(id)
            if v5 { body.append(contentsOf: properties.encode()) }
            body.append(contentsOf: codes)
        case .unsubscribe(let id, let topics):
            header = 0xA2
            body.appendUInt16(id)
            if v5 { body.append(0) }
            for topic in topics { body.appendString(topic) }
        case .unsuback(let id, let codes):
            header = 0xB0
            body.appendUInt16(id)
            if v5 {
                body.append(0)
                body.append(contentsOf: codes)
            }
        case .pingreq:
            header = 0xC0
        case .pingresp:
            header = 0xD0
        case .disconnect(let reasonCode, let properties):
            header = 0xE0
            if v5, reasonCode != 0 || !properties.isEmpty {
                body.append(reasonCode)
                body.append(contentsOf: properties.encode())
            }
        }
        var packet: [UInt8] = [header]
        packet.appendVarint(body.count)
        return packet + body
    }

    /// Decodes one packet's fixed-header byte and body. `version` is the connection's; CONNECT says its own.
    static func decode(header: UInt8, body: ArraySlice<UInt8>, version: MQTTProtocolVersion = .v3_1_1) throws -> MQTTPacket {
        var reader = Reader(remaining: body)
        let flags = header & 0x0F
        let v5 = version == .v5
        switch header >> 4 {
        case 1:
            let name = try reader.string()
            let level = try reader.byte()
            let version: MQTTProtocolVersion
            switch (name, level) {
            case ("MQTT", 4): version = .v3_1_1
            case ("MQIsdp", 3): version = .v3_1
            case ("MQTT", 5): version = .v5
            default: throw MQTTError.protocolError("unknown protocol \(name) \(level)")
            }
            let connectFlags = try reader.byte()
            let keepAlive = try reader.uint16()
            let properties = version == .v5 ? try reader.properties() : MQTTProperties()
            let clientID = try reader.string()
            var will: MQTTMessage?
            if connectFlags & 0x04 != 0 {
                if version == .v5 { _ = try reader.properties() }
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
                    cleanSession: connectFlags & 0x02 != 0, will: will, properties: properties
                )
            )
        case 2:
            let sessionPresent = try reader.byte() & 0x01 != 0
            let code = try reader.byte()
            // A broker that only speaks 3.1.1 answers a version 5 CONNECT with a 3.1.1 CONNACK: no properties.
            let properties = v5 && !reader.isAtEnd ? try reader.properties() : MQTTProperties()
            return .connack(sessionPresent: sessionPresent, returnCode: code, properties: properties)
        case 3:
            guard let qos = MQTTQoS(rawValue: (flags >> 1) & 0x03) else { throw MQTTError.protocolError("invalid QoS") }
            let topic = try reader.string()
            let packetID = qos == .atMostOnce ? nil : try reader.uint16()
            let properties = v5 ? try reader.properties() : MQTTProperties()
            let message = MQTTMessage(topic: topic, payload: Data(reader.rest()), qos: qos, retain: flags & 0x01 != 0)
            return .publish(message, packetID: packetID, duplicate: flags & 0x08 != 0, properties: properties)
        case 4:
            let id = try reader.uint16()
            return .puback(id, reasonCode: try reader.acknowledgementReason(v5: v5))
        case 5:
            let id = try reader.uint16()
            _ = try reader.acknowledgementReason(v5: v5)
            return .pubrec(id)
        case 6:
            let id = try reader.uint16()
            _ = try reader.acknowledgementReason(v5: v5)
            return .pubrel(id)
        case 7:
            let id = try reader.uint16()
            _ = try reader.acknowledgementReason(v5: v5)
            return .pubcomp(id)
        case 8:
            let id = try reader.uint16()
            if v5 { _ = try reader.properties() }
            var subscriptions: [MQTTSubscription] = []
            while !reader.isAtEnd {
                let topic = try reader.string()
                subscriptions.append(MQTTSubscription(topic: topic, qos: MQTTQoS(rawValue: try reader.byte() & 0x03) ?? .atMostOnce))
            }
            return .subscribe(packetID: id, subscriptions)
        case 9:
            let id = try reader.uint16()
            let properties = v5 ? try reader.properties() : MQTTProperties()
            return .suback(packetID: id, returnCodes: Array(reader.rest()), properties: properties)
        case 10:
            let id = try reader.uint16()
            if v5 { _ = try reader.properties() }
            var topics: [String] = []
            while !reader.isAtEnd { topics.append(try reader.string()) }
            return .unsubscribe(packetID: id, topics)
        case 11:
            let id = try reader.uint16()
            guard v5 else { return .unsuback(id) }
            _ = try reader.properties()
            return .unsuback(id, reasonCodes: Array(reader.rest()))
        case 12: return .pingreq
        case 13: return .pingresp
        case 14:
            guard v5, !reader.isAtEnd else { return .disconnect() }
            let code = try reader.byte()
            return .disconnect(reasonCode: code, properties: reader.isAtEnd ? MQTTProperties() : try reader.properties())
        case 15: throw MQTTError.protocolError("AUTH is not supported")
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

        mutating func uint32() throws -> UInt32 {
            UInt32(try uint16()) << 16 | UInt32(try uint16())
        }

        /// A variable byte integer (at most four bytes).
        mutating func varint() throws -> Int {
            var value = 0
            for shift in stride(from: 0, to: 28, by: 7) {
                let byte = try byte()
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
            }
            throw MQTTError.protocolError("malformed variable byte integer")
        }

        /// MQTT 5 properties: their length, then each identifier and value.
        mutating func properties() throws -> MQTTProperties {
            let length = try varint()
            guard remaining.count >= length else { throw MQTTError.protocolError("truncated properties") }
            var reader = Reader(remaining: remaining.prefix(length))
            remaining = remaining.dropFirst(length)
            var properties = MQTTProperties()
            while !reader.isAtEnd {
                let id = try reader.byte()
                guard let kind = MQTTProperties.kind(of: id) else { throw MQTTError.protocolError("unknown property \(id)") }
                let value: MQTTProperties.Value
                switch kind {
                case .byte: value = .byte(try reader.byte())
                case .uint16: value = .uint16(try reader.uint16())
                case .uint32: value = .uint32(try reader.uint32())
                case .varint: value = .varint(try reader.varint())
                case .string: value = .string(try reader.string())
                case .binary: value = .binary(Array(try reader.bytes()))
                case .pair: value = .pair(try reader.string(), try reader.string())
                }
                properties.entries.append((id: id, value: value))
            }
            return properties
        }

        /// PUBACK, PUBREC, PUBREL and PUBCOMP in MQTT 5: an optional reason code (0 when left out), then optional
        /// properties.
        mutating func acknowledgementReason(v5: Bool) throws -> UInt8 {
            guard v5, !isAtEnd else { return 0 }
            let code = try byte()
            if !isAtEnd { _ = try properties() }
            return code
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
    /// The connection's protocol version, which decides whether packets carry properties.
    var version: MQTTProtocolVersion
    private var buffer: [UInt8] = []
    private var start = 0

    init(limit: Int = 16 * 1024 * 1024, version: MQTTProtocolVersion = .v3_1_1) {
        self.limit = limit
        self.version = version
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
        return try MQTTPacket.decode(header: header, body: body, version: version)
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

    /// A variable byte integer: the fixed header's remaining length, MQTT 5's property lengths.
    fileprivate mutating func appendVarint(_ value: Int) {
        var value = value
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 { byte |= 0x80 }
            append(byte)
        } while value > 0
    }
}
