import Foundation

/// The wire formats of an FCM web-push receiver (docs/clean-room/FCMReceiver.md): the Android check-in, the MCS
/// messages to and from `mtalk.google.com:5228` (Chromium's GCM engine's schemas, proto2) and their framing.
///
/// Proto2 writes an optional field that is set even when it holds its default, so these builders use
/// `ProtobufWriter.varint` and `bytes`, which always write, rather than the proto3-style typed writers.
public enum FCMProtocol {
    /// The MCS version byte the client sends first; the server answers 41 or more (or 38).
    public static let version: UInt8 = 41

    /// The tags of the MCS messages.
    public enum Tag: UInt8, Sendable {
        case heartbeatPing = 0
        case heartbeatAck = 1
        case loginRequest = 2
        case loginResponse = 3
        case close = 4
        case iqStanza = 7
        case dataMessageStanza = 8
        case streamErrorStanza = 10
    }

    // MARK: Check-in

    /// How the check-in request is written: `chrome` as the Eneris receiver does (its defaults written out, a time
    /// zone), or `minimal` as the original receiver did. The server accepts either.
    public enum CheckinStyle: Sendable {
        case chrome(timeZone: String)
        case minimal
    }

    /// An `AndroidCheckinRequest` as a Chrome browser (device type 3). `androidID` and `securityToken` are given when
    /// checking in again with stored credentials.
    public static func checkinRequest(
        androidID: UInt64? = nil, securityToken: UInt64? = nil, chromeVersion: String, platform: Int = 2, channel: Int = 1,
        style: CheckinStyle
    ) -> [UInt8] {
        var build = ProtobufWriter()
        build.varint(1, UInt64(platform))
        build.bytes(2, Array(chromeVersion.utf8))
        build.varint(3, UInt64(channel))

        var checkin = ProtobufWriter()
        if case .chrome = style {
            checkin.varint(2, 0)     // last_checkin_msec
            checkin.bytes(6, [])     // cell_operator
            checkin.bytes(7, [])     // sim_operator
            checkin.bytes(8, [])     // roaming
            checkin.varint(9, 0)     // user_number
        }
        checkin.varint(12, 3)        // type: Chrome browser
        checkin.bytes(13, build.bytes)

        var request = ProtobufWriter()
        if let androidID { request.varint(2, androidID) }
        if case .chrome = style { request.bytes(3, []) }   // digest
        request.bytes(4, checkin.bytes)
        if case .chrome(let timeZone) = style {
            request.bytes(5, [])     // desired_build
            request.bytes(6, [])     // locale
            request.varint(7, 0)     // logging_id
            request.bytes(8, [])     // market_checkin
            request.bytes(12, Array(timeZone.utf8))
        }
        // security_token is a fixed64, which the shared writer has no method for.
        let token = securityToken.map { Protobuf.tag(13, .fixed64) + withUnsafeBytes(of: $0.littleEndian, Array.init) } ?? []
        var rest = ProtobufWriter()
        rest.varint(14, 3)           // version
        if case .chrome = style {
            rest.varint(20, 0)       // fragment
            rest.bytes(21, [])       // user_name
        }
        rest.varint(22, 0)           // user_serial_number
        return request.bytes + token + rest.bytes
    }

    /// The Android id and security token of an `AndroidCheckinResponse` (fields 7 and 8, fixed64, unsigned).
    public static func checkinResponse(_ bytes: [UInt8]) -> (androidID: UInt64, securityToken: UInt64)? {
        guard let message = ProtobufMessage(bytes), message.has(7), message.has(8) else { return nil }
        let androidID = message.uint64(7), securityToken = message.uint64(8)
        guard androidID != 0, securityToken != 0 else { return nil }
        return (androidID, securityToken)
    }

    // MARK: MCS messages

    /// The `LoginRequest`, framed as the client's first write: the version byte, its tag and its length.
    public static func loginFrame(
        androidID: String, securityToken: String, chromeVersion: String, persistentIDs: [String], heartbeatIntervalMilliseconds: Int
    ) -> [UInt8] {
        var login = ProtobufWriter()
        login.bytes(1, Array("chrome-\(chromeVersion)".utf8))
        login.bytes(2, Array("mcs.android.com".utf8))
        login.bytes(3, Array(androidID.utf8))
        login.bytes(4, Array(androidID.utf8))
        login.bytes(5, Array(securityToken.utf8))
        let hex = UInt64(androidID).map { String(Int64(bitPattern: $0), radix: 16) } ?? androidID
        login.bytes(6, Array("android-\(hex)".utf8))
        var setting = ProtobufWriter()
        setting.bytes(1, Array("new_vc".utf8))
        setting.bytes(2, Array("1".utf8))
        login.bytes(8, setting.bytes)
        for id in persistentIDs { login.bytes(10, Array(id.utf8)) }
        login.varint(12, 0)          // adaptive_heartbeat: false
        if heartbeatIntervalMilliseconds > 0 {
            var stat = ProtobufWriter()
            stat.bytes(1, [])
            stat.varint(2, 1)
            stat.varint(3, UInt64(heartbeatIntervalMilliseconds))
            login.bytes(13, stat.bytes)
        }
        login.varint(14, 1)          // use_rmq2
        login.varint(16, 2)          // auth_service: ANDROID_ID
        login.varint(17, 1)          // network_type
        return [version] + frame(.loginRequest, login.bytes)
    }

    /// A message after the first: its tag, its length as a varint, its bytes.
    public static func frame(_ tag: Tag, _ body: [UInt8]) -> [UInt8] {
        [tag.rawValue] + Protobuf.varint(UInt64(body.count)) + body
    }

    /// A `HeartbeatPing` (tag 0) or `HeartbeatAck` (tag 1): `last_stream_id_received` when there is a new one, and the
    /// ping's `status` in an ack.
    public static func heartbeat(_ tag: Tag, lastStreamIDReceived: Int32?, status: Int64? = nil) -> [UInt8] {
        var body = ProtobufWriter()
        if let lastStreamIDReceived { body.varint(2, UInt64(bitPattern: Int64(lastStreamIDReceived))) }
        if let status, status != 0 { body.varint(3, UInt64(bitPattern: status)) }
        return frame(tag, body.bytes)
    }

    /// What the receiver reads of a `DataMessageStanza`: its persistent id, its app data and its encrypted payload.
    public struct DataMessage: Sendable, Equatable {
        public var persistentID: String?
        public var appData: [String: String]
        public var rawData: [UInt8]?

        public init?(_ bytes: [UInt8]) {
            guard let message = ProtobufMessage(bytes) else { return nil }
            persistentID = message.has(9) ? message.string(9) : nil
            var appData: [String: String] = [:]
            for field in message.fields where field.number == 7 {
                guard case .bytes(let entry) = field.value, let pair = ProtobufMessage(entry) else { continue }
                appData[pair.string(1)] = pair.string(2)
            }
            self.appData = appData
            rawData = message.has(21) ? message.bytes(21) : nil
        }
    }
}

/// Splits the bytes the MCS server sends into messages, however TCP cuts them: the version byte first, then
/// `tag ‖ varint length ‖ bytes` again and again (docs/clean-room/FCMReceiver.md, 6.2). Bytes are buffered until a
/// message is whole; an unknown tag or version is a fatal error, after which the connection is dropped.
public struct MCSFrameParser: Sendable {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unsupportedVersion(UInt8)
        case unknownTag(UInt8)
        case oversizedMessage

        public var description: String {
            switch self {
            case .unsupportedVersion(let version): "unsupported MCS version \(version)"
            case .unknownTag(let tag): "unknown MCS tag \(tag)"
            case .oversizedMessage: "an MCS message larger than 16 MiB"
            }
        }
    }

    private var buffer: [UInt8] = []
    private var start = 0
    private var versionRead = false
    /// The largest message accepted: FCM's are a few kilobytes.
    static let maximumSize = 16 * 1024 * 1024

    public init() {}

    /// Adds received bytes and returns the messages they complete, in order.
    public mutating func feed(_ bytes: [UInt8]) throws -> [(tag: FCMProtocol.Tag, body: [UInt8])] {
        buffer += bytes
        var messages: [(tag: FCMProtocol.Tag, body: [UInt8])] = []
        while true {
            if !versionRead {
                guard buffer.count - start >= 3 else { break }
                let version = buffer[start]
                guard version >= 41 || version == 38 else { throw ParseError.unsupportedVersion(version) }
                start += 1
                versionRead = true
            }
            guard start < buffer.count else { break }
            let rawTag = buffer[start]
            guard let tag = FCMProtocol.Tag(rawValue: rawTag) else { throw ParseError.unknownTag(rawTag) }
            var index = start + 1
            let size = buffer.withUnsafeBytes { Protobuf.readVarint($0, &index) }
            guard let size else {
                // An incomplete length waits for more bytes; one longer than an int32's five is not MCS.
                if buffer.count - start > 6 { throw ParseError.oversizedMessage }
                break
            }
            guard size <= UInt64(Self.maximumSize) else { throw ParseError.oversizedMessage }
            guard buffer.count - index >= Int(size) else { break }
            messages.append((tag, Array(buffer[index..<index + Int(size)])))
            start = index + Int(size)
        }
        // Keep only what is not read yet.
        if start > 0 {
            buffer.removeFirst(start)
            start = 0
        }
        return messages
    }
}
