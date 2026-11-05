import Crypto
import Foundation
import _CryptoExtras

// Baichuan, the binary protocol Reolink devices speak on TCP 9000 (docs/clean-room/Reolink.md, section 5): the header,
// its two encryptions, the login hashes and the reassembly of messages from a TCP byte stream. All integers are
// little-endian.

enum Baichuan {
    static let magic: [UInt8] = [0xF0, 0xDE, 0xBC, 0x0A]
    /// The XOR key of the "BC" encryption (5.2).
    static let xorKey: [UInt8] = [0x1F, 0x2D, 0x3C, 0x4B, 0x5A, 0x69, 0x78, 0xFF]
    /// `ch_id` of a host command, and of the event subscription.
    static let hostChannel: UInt8 = 250
    static let subscribeChannel: UInt8 = 251
    /// AES-128-CFB's IV, the same for every piece.
    static let aesIV = Array("0123456789abcdef".utf8)
    /// A request larger than this (header included) makes the camera drop the connection.
    static let maximumRequest = 38_000
    /// A received body larger than this is refused rather than buffered.
    static let maximumBody = 4 * 1024 * 1024

    /// Message classes, as bytes 18 and 19 read them.
    static let modernClass: [UInt8] = [0x14, 0x64]
    static let legacyClass: [UInt8] = [0x14, 0x65]

    // MARK: Encryption (5.2)

    /// Baichuan XOR: byte `i` XORed with `key[(offset + i) mod 8] XOR offset`. Its own inverse.
    static func xor(_ bytes: [UInt8], offset: UInt8) -> [UInt8] {
        var result = bytes
        for index in result.indices {
            result[index] ^= xorKey[(Int(offset) + index) % 8] ^ offset
        }
        return result
    }

    /// The MD5 of the UTF-8 text as upper-case hex, its last digit dropped (31 characters).
    static func md5mod(_ text: String) -> String {
        let hex = Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined()
        return String(hex.prefix(31))
    }

    /// The AES key after login: the first 16 characters of `MD5MOD(nonce + "-" + password)`, as ASCII bytes.
    static func aesKey(nonce: String, password: String) -> [UInt8] {
        Array(md5mod(nonce + "-" + password).prefix(16).utf8)
    }

    /// AES-128-CFB128 with the fixed IV, a fresh cipher state per call: no padding, the output as long as the input.
    static func aes(_ bytes: [UInt8], key: [UInt8], decrypt: Bool) throws -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        let symmetric = SymmetricKey(data: key)
        let iv = try AES._CFB.IV(ivBytes: aesIV)
        let output = decrypt ? try AES._CFB.decrypt(bytes, using: symmetric, iv: iv) : try AES._CFB.encrypt(bytes, using: symmetric, iv: iv)
        return Array(output)
    }

    // MARK: Bodies (5.3)

    /// The login body of 5.3.2, its user name and password hashed with the nonce.
    static func loginBody(username: String, password: String, nonce: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <LoginUser version="1.1">
        <userName>\(md5mod(username + nonce))</userName>
        <password>\(md5mod(password + nonce))</password>
        <userVer>1</userVer>
        </LoginUser>
        <LoginNet version="1.1">
        <type>LAN</type>
        <udpPort>0</udpPort>
        </LoginNet>
        </body>

        """
    }

    static let logoutBody = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <LoginUser version="1.1">
        <userVer>1</userVer>
        </LoginUser>
        </body>

        """

    /// The extension a channel command carries before its body; `channel` is 0-based.
    static func channelExtension(_ channel: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" ?>
        <Extension version="1.1">
        <channelId>\(channel)</channelId>
        </Extension>

        """
    }

    /// The siren body of 5.4.3 (with reolink-aio's leading newline): `times` plays (mode 0), or manual on and off (mode 2).
    /// `channel` nil is a hub's own siren.
    static func sirenBody(channel: Int?, mode: SirenMode) -> String {
        let channelLine = channel.map { "<channelId>\($0)</channelId>\n" } ?? ""
        let (playMode, times, onOff): (Int, Int, Int) = switch mode {
        case .times(let count): (0, count, 1)
        case .manual(let on): (2, 1, on ? 1 : 0)
        }
        return """

            <?xml version="1.0" encoding="UTF-8" ?>
            <body>
            <audioPlayInfo version="1.1">
            \(channelLine)<playMode>\(playMode)</playMode>
            <playDuration>10</playDuration>
            <playTimes>\(times)</playTimes>
            <onOff>\(onOff)</onOff>
            </audioPlayInfo>
            </body>
            """
    }

    enum SirenMode: Sendable, Equatable {
        case times(Int)
        case manual(Bool)
    }

    // MARK: Headers (5.1)

    /// A request's 24-byte header (class 1464).
    static func header(command: UInt32, bodyLength: Int, channel: UInt8, counter: UInt32, extensionLength: Int) -> [UInt8] {
        var bytes = magic
        bytes += littleEndian(command)
        bytes += littleEndian(UInt32(clamping: bodyLength))
        bytes.append(channel)
        bytes += littleEndian(counter & 0xFF_FFFF).prefix(3)
        bytes += [0, 0]
        bytes += modernClass
        bytes += littleEndian(UInt32(clamping: extensionLength))
        return bytes
    }

    /// The nonce request: a header-only legacy message (class 1465, 20 bytes).
    static func nonceRequest(counter: UInt32) -> [UInt8] {
        var bytes = magic
        bytes += littleEndian(UInt32(1))
        bytes += littleEndian(UInt32(0))
        bytes.append(hostChannel)
        bytes += littleEndian(counter & 0xFF_FFFF).prefix(3)
        bytes += [0x12, 0xDC]
        bytes += legacyClass
        return bytes
    }

    static func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
    }

    static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

/// How a received body is encrypted.
enum BaichuanEncryption: Sendable, Equatable {
    case none, xor, aes
}

/// One message as received: its header's fields and its body, extension and payload split.
struct BaichuanMessage: Sendable, Equatable {
    var command: UInt32
    var channel: UInt8
    var counter: UInt32
    /// The full message id: bytes 12 to 15 read as one integer (`ch_id` and the counter).
    var messageID: UInt32 { Self.messageID(channel: channel, counter: counter) }
    static func messageID(channel: UInt8, counter: UInt32) -> UInt32 { UInt32(channel) | counter << 8 }
    /// The status of a 24-byte header; nil for a 20-byte one.
    var status: UInt16?
    /// What bytes 16 and 17 of a 20-byte (class 1466) header say; nil for a 24-byte one.
    var declaredEncryption: BaichuanEncryption?
    /// The extension (24-byte header with a non-zero extension length).
    var extensionBytes: [UInt8]
    /// The XML body, or the binary payload after an extension.
    var body: [UInt8]
}

enum BaichuanError: Error, CustomStringConvertible, Equatable {
    case unknownClass(UInt8, UInt8)
    case legacyReply
    case tooLarge(Int)
    case undecryptable
    case noNonce
    case unauthorized
    case accountDevice
    case status(UInt16)
    case timeout
    case closed
    case requestTooLarge(Int)

    var description: String {
        switch self {
        case .unknownClass(let a, let b): String(format: "a message of unknown class %02x%02x", a, b)
        case .legacyReply: "a legacy (1465) reply, which is not parsed"
        case .tooLarge(let size): "a message of \(size) bytes, larger than accepted"
        case .undecryptable: "a body that decrypts to no XML"
        case .noNonce: "the device sent no nonce"
        case .unauthorized: "the device refused the user name or password"
        case .accountDevice:
            "the device is an \"account device\" bound to a Reolink cloud account, which refuses local logins: switch it back to a local device (Reolink's article \"Introduction to Reolink Local Device and Account Device\")"
        case .status(let code): "the device answered with status \(code)"
        case .timeout: "the device did not answer in time"
        case .closed: "the connection closed"
        case .requestTooLarge(let size): "a request of \(size) bytes, above the device's limit"
        }
    }
}

/// Reassembles messages from TCP chunks (5.1): it buffers until a header and its body are there, parses several messages
/// of one read in turn, drops what does not start with the magic (keeping a partial magic), and lets a new magic at the
/// start of a read replace an incomplete message.
struct BaichuanFramer: Sendable {
    private var buffer: [UInt8] = []

    /// Bytes waiting for the rest of their message.
    var pendingCount: Int { buffer.count }

    /// The messages the chunk completes; an error (an unknown class, a body above the limit) drops what was buffered.
    /// Messages are read from an offset and the buffer compacted once, so a chunk of many messages costs its length.
    mutating func push(_ chunk: [UInt8]) -> [Result<BaichuanMessage, BaichuanError>] {
        if buffer.count >= 4, chunk.starts(with: Baichuan.magic) {
            // A new message starts while one is pending: reolink-aio's choice is to drop the pending one.
            buffer = []
        }
        buffer += chunk
        var results: [Result<BaichuanMessage, BaichuanError>] = []
        var start = 0
        defer { buffer.removeFirst(min(start, buffer.count)) }
        while true {
            start = resynchronised(from: start)
            let available = buffer.count - start
            guard available >= 20 else { break }
            let bodyLength = Int(Baichuan.readUInt32(buffer, start + 8))
            guard bodyLength <= Baichuan.maximumBody else {
                start = buffer.count
                results.append(.failure(.tooLarge(bodyLength)))
                return results
            }
            let headerLength: Int
            switch (buffer[start + 18], buffer[start + 19]) {
            case (0x14, 0x64), (0x00, 0x00): headerLength = 24
            case (0x14, 0x66): headerLength = 20
            case (0x14, 0x65):
                // Not parsed, as reolink-aio: an error for the waiting request.
                guard available >= 20 + bodyLength else { return results }
                start += 20 + bodyLength
                results.append(.failure(.legacyReply))
                continue
            case let (a, b):
                start = buffer.count
                results.append(.failure(.unknownClass(a, b)))
                return results
            }
            guard available >= headerLength + bodyLength else { break }
            let bodyStart = start + headerLength
            var message = BaichuanMessage(command: Baichuan.readUInt32(buffer, start + 4), channel: buffer[start + 12],
                                          counter: Baichuan.readUInt32(buffer, start + 12) >> 8, status: nil, declaredEncryption: nil,
                                          extensionBytes: [], body: [])
            var payloadStart = bodyStart
            if headerLength == 24 {
                message.status = UInt16(buffer[start + 16]) | UInt16(buffer[start + 17]) << 8
                let extensionLength = min(Int(Baichuan.readUInt32(buffer, start + 20)), bodyLength)
                message.extensionBytes = Array(buffer[bodyStart..<(bodyStart + extensionLength)])
                payloadStart += extensionLength
            } else {
                message.declaredEncryption = switch (buffer[start + 16], buffer[start + 17]) {
                case (0x01, 0xDD), (0x12, 0xDD): .xor
                case (0x02, 0xDD), (0x03, 0xDD): .aes
                default: BaichuanEncryption.none
                }
            }
            message.body = Array(buffer[payloadStart..<(bodyStart + bodyLength)])
            start = bodyStart + bodyLength
            results.append(.success(message))
        }
        return results
    }

    /// The offset of the next magic at or after `start` when nothing valid is pending there; a trailing partial magic
    /// is kept.
    private func resynchronised(from start: Int) -> Int {
        var index = start
        while index < buffer.count {
            let rest = buffer[index...]
            if rest.starts(with: Baichuan.magic) || (rest.count < 4 && Baichuan.magic.starts(with: rest)) { return index }
            index += 1
        }
        return index
    }
}

/// Decrypting received XML (5.2): the declared or expected method first, then the other; the text must start with `<?xml`.
enum BaichuanDecoder {
    static func isXML(_ bytes: [UInt8]) -> Bool {
        let start = bytes.drop { $0 == 0x0A || $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }
        return start.starts(with: Array("<?xml".utf8))
    }

    /// The XML text of a piece. `expected` is the 20-byte header's declared method, or AES (BC for a BC request) for a
    /// 24-byte one; `key` nil when no AES key is known yet.
    static func decrypt(_ bytes: [UInt8], expected: BaichuanEncryption, offset: UInt8, key: [UInt8]?) throws -> String {
        guard !bytes.isEmpty else { return "" }
        var order: [BaichuanEncryption] = [expected]
        for method in [BaichuanEncryption.aes, .xor, .none] where !order.contains(method) { order.append(method) }
        for method in order {
            let candidate: [UInt8]?
            switch method {
            case .none: candidate = bytes
            case .xor: candidate = Baichuan.xor(bytes, offset: offset)
            case .aes: candidate = key.flatMap { try? Baichuan.aes(bytes, key: $0, decrypt: true) }
            }
            if let candidate, isXML(candidate) { return String(decoding: candidate, as: UTF8.self) }
        }
        throw BaichuanError.undecryptable
    }
}
