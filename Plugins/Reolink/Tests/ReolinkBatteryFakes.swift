import Foundation
import HomeswiftNetwork
import NIOConcurrencyHelpers

@testable import HomeswiftReolink

/// A standalone battery camera's Baichuan side in memory (docs/clean-room/ReolinkBattery.md): it refuses connections
/// while asleep, answers the first requests after a wake with 400, and serves identity, abilities, battery, the
/// webhook, snapshots in parts (on other message numbers) and live media as binary messages, in a full-AES session.
final class FakeBatteryCamera: @unchecked Sendable {
    struct Request: Sendable {
        var raw: [UInt8]
        var command: UInt32
        var channel: UInt8
        var counter: UInt32
        var ext: String
        var body: String
    }

    struct State {
        var asleep = false
        /// Requests answered with 400 before the camera is up.
        var waking = 0
        var connections = 0
        var requests: [Request] = []
        var closed = 0
        var webhookURL = ""
        var webhookEnabled = false
        var hasWebhook = true
        var netPort = 1
        var battery = 87
        var model = "Argus 3 Pro"
        var jpeg: [UInt8] = FakeBatteryCamera.jpeg(23_644)
        var snapshotWorks = true
        /// What a media start sends, in binary messages of these sizes.
        var media: [UInt8] = []
        var mediaChunk = 700
    }

    static let uid = "95270000AAAAAAAA"
    let nonce = "0a1b2c3d4e5f6a7b"
    let password = "secret"
    let state = NIOLockedValueBox(State())
    var key: [UInt8] { Baichuan.aesKey(nonce: nonce, password: password) }

    static func jpeg(_ size: Int) -> [UInt8] { [0xFF, 0xD8] + (0..<(size - 4)).map { UInt8(truncatingIfNeeded: $0) } + [0xFF, 0xD9] }

    var requests: [Request] { state.withLockedValue { $0.requests } }
    var commands: [UInt32] { requests.map(\.command) }
    var connections: Int { state.withLockedValue { $0.connections } }
    func count(_ command: UInt32) -> Int { commands.filter { $0 == command }.count }

    /// A connection, or the error of a camera asleep (a TCP connect that fails).
    func connect() throws -> any ByteStream {
        let asleep = state.withLockedValue { state -> Bool in
            if !state.asleep { state.connections += 1 }
            return state.asleep
        }
        if asleep { throw HTTPClientError.cannotConnect(host: "camera", port: 9000, code: 60, reason: "timed out") }
        return Connection(camera: self)
    }

    final class Connection: ByteStream, @unchecked Sendable {
        let incoming: AsyncThrowingStream<[UInt8], any Error>
        private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
        private let camera: FakeBatteryCamera

        init(camera: FakeBatteryCamera) {
            self.camera = camera
            (incoming, continuation) = AsyncThrowingStream.makeStream()
        }

        func send(_ bytes: [UInt8]) async throws {
            for message in camera.handle(bytes) { continuation.yield(message) }
        }

        func close() async {
            camera.state.withLockedValue { $0.closed += 1 }
            continuation.finish()
        }
    }

    private func aes(_ text: String) -> [UInt8] { (try? Baichuan.aes(Array(text.utf8), key: key, decrypt: false)) ?? [] }
    private func clear(_ bytes: [UInt8]) -> String { String(decoding: (try? Baichuan.aes(bytes, key: key, decrypt: true)) ?? [], as: UTF8.self) }

    /// A 24-byte reply: bytes 12 to 15 as given, the status, an extension before the body.
    static func message(command: UInt32, channel: UInt8, counter: UInt32, status: UInt16, ext: [UInt8] = [], body: [UInt8]) -> [UInt8] {
        var header = Baichuan.header(command: command, bodyLength: ext.count + body.count, channel: channel, counter: counter, extensionLength: ext.count)
        header[16] = UInt8(status & 0xFF)
        header[17] = UInt8(status >> 8)
        return header + ext + body
    }

    private func binaryExtension(encryptLength: Int?) -> [UInt8] {
        aes("<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<Extension version=\"1.1\">\n<binaryData>1</binaryData>\n"
            + (encryptLength.map { "<encryptLen>\($0)</encryptLen>\n" } ?? "") + "</Extension>\n")
    }

    /// A binary payload as a full-AES camera sends it: its first 16 bytes encrypted, said in the extension.
    private func binary(command: UInt32, channel: UInt8, counter: UInt32, status: UInt16, payload: [UInt8]) -> [UInt8] {
        let encrypted = min(16, payload.count)
        let body = ((try? Baichuan.aes(Array(payload.prefix(encrypted)), key: key, decrypt: false)) ?? []) + payload.dropFirst(encrypted)
        return Self.message(command: command, channel: channel, counter: counter, status: status, ext: binaryExtension(encryptLength: encrypted), body: body)
    }

    func handle(_ bytes: [UInt8]) -> [[UInt8]] {
        guard bytes.count >= 20, bytes.starts(with: Baichuan.magic) else { return [] }
        let command = Baichuan.readUInt32(bytes, 4)
        let channel = bytes[12]
        let counter = UInt32(bytes[13]) | UInt32(bytes[14]) << 8 | UInt32(bytes[15]) << 16
        if bytes[18] == 0x14, bytes[19] == 0x65 {
            // The nonce, in a 20-byte header that says "full AES" (`12 dd`).
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<Encryption version=\"1.1\">\n<type>md5</type>\n<nonce>\(nonce)</nonce>\n</Encryption>\n</body>\n"
            let body = Baichuan.xor(Array(xml.utf8), offset: channel)
            var header = Array(bytes.prefix(16))
            header[8..<12] = ArraySlice(Baichuan.littleEndian(UInt32(body.count)))
            return [header + [0x12, 0xDD, 0x14, 0x66] + body]
        }
        let extensionLength = Int(Baichuan.readUInt32(bytes, 20))
        let payload = Array(bytes[24...])
        let ext = Array(payload.prefix(extensionLength)), rest = Array(payload.dropFirst(extensionLength))
        if command == 1 {
            let text = String(decoding: Baichuan.xor(rest, offset: channel), as: UTF8.self)
            state.withLockedValue { $0.requests.append(Request(raw: bytes, command: 1, channel: channel, counter: counter, ext: "", body: text)) }
            let good = text.contains(Baichuan.md5mod(password + nonce))
            let info = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<DeviceInfo version=\"1.1\">\n<type>ipc</type>\n<channelNum>1</channelNum>\n</DeviceInfo>\n</body>\n"
            return [Self.message(command: 1, channel: channel, counter: counter, status: good ? 200 : 401, body: good ? Baichuan.xor(Array(info.utf8), offset: channel) : [])]
        }
        let request = Request(raw: bytes, command: command, channel: channel, counter: counter, ext: clear(ext), body: clear(rest))
        let (waking, current) = state.withLockedValue { state -> (Bool, State) in
            state.requests.append(request)
            if state.waking > 0, command != 2 {
                state.waking -= 1
                return (true, state)
            }
            return (false, state)
        }
        if waking { return [Self.message(command: command, channel: channel, counter: counter, status: 400, body: [])] }
        func xml(_ text: String) -> [[UInt8]] { [Self.message(command: command, channel: channel, counter: counter, status: 200, body: aes(text))] }
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n"
        switch command {
        case 2:
            return xml("")
        case 80:
            return xml(head + "<VersionInfo version=\"1.1\">\n<name>Garden</name>\n<type>\(current.model)</type>\n<serialNumber>00000000000042</serialNumber>\n<hardwareVersion>IPC_NT1NA45MP</hardwareVersion>\n<firmwareVersion>v3.0.0.3565_2401251001</firmwareVersion>\n<buildDay>build 24012510</buildDay>\n</VersionInfo>\n</body>\n")
        case 114:
            return xml(head + "<Uid version=\"1.1\">\n<uid>\(Self.uid)</uid>\n</Uid>\n</body>\n")
        case 199:
            return xml(head + "<AbilityInfo version=\"1.1\">\n<netPort>\(current.netPort)</netPort>\n<system>\n<item>\n<chnID>0</chnID>\n<battery>1</battery>\n</item>\n</system>\n</AbilityInfo>\n</body>\n")
        case 253:
            return xml(head + "<BatteryInfo version=\"1.1\">\n<channelId>0</channelId>\n<chargeStatus>none</chargeStatus>\n<batteryPercent>\(current.battery)</batteryPercent>\n<lowPower>0</lowPower>\n</BatteryInfo>\n</body>\n")
        case 806:
            guard current.hasWebhook else { return [Self.message(command: command, channel: channel, counter: counter, status: 400, body: [])] }
            return xml(head + "<HaCfg version=\"1.1\">\n<enable>\(current.webhookEnabled ? 1 : 0)</enable>\n<url>\(current.webhookURL)</url>\n<verify_cert>0</verify_cert>\n</HaCfg>\n</body>\n")
        case 807:
            let url = (try? BXParser.parse(request.body))?.first("url")?.text ?? ""
            let enable = (try? BXParser.parse(request.body))?.first("enable")?.text == "1"
            state.withLockedValue {
                $0.webhookURL = url
                $0.webhookEnabled = enable
            }
            return xml("")
        case 109:
            guard current.snapshotWorks else { return [Self.message(command: command, channel: channel, counter: counter, status: 422, body: [])] }
            let jpeg = current.jpeg
            var replies = xml(head + "<Snap version=\"1.1\">\n<channelId>0</channelId>\n<fileName>01_20260105140240.jpg</fileName>\n<time>0</time>\n<pictureSize>\(jpeg.count)</pictureSize>\n</Snap>\n</body>\n")
            // The parts on another message number (7): 16000 bytes, then the rest with status 201.
            let first = Array(jpeg.prefix(16_000)), last = Array(jpeg.dropFirst(16_000))
            replies.append(Self.message(command: 109, channel: channel, counter: counter + 7, status: 200, ext: binaryExtension(encryptLength: nil), body: first))
            replies.append(Self.message(command: 109, channel: channel, counter: counter + 7, status: 201, body: last))
            return replies
        case 3:
            let media = current.media
            let first = Array(media.prefix(32))
            var replies = [binary(command: 3, channel: channel, counter: counter, status: 200, payload: first)]
            var offset = first.count
            while offset < media.count {
                let end = min(media.count, offset + current.mediaChunk)
                replies.append(binary(command: 3, channel: channel, counter: counter, status: 200, payload: Array(media[offset..<end])))
                offset = end
            }
            return replies
        case 4:
            return xml("")
        default:
            return [Self.message(command: command, channel: channel, counter: counter, status: 400, body: [])]
        }
    }
}

// MARK: Media frames (ReolinkBattery.md 12.2)

enum MediaVectors {
    static let info = bytes("31 30 30 32 20 00 00 00 00 09 00 00 10 05 00 00 00 0f 78 0a 06 12 24 22 78 0a 06 12 24 22 00 00")
    static let iPayload: [UInt8] = [0, 0, 0, 1, 0x67] + (0..<995).map { UInt8(truncatingIfNeeded: $0 &* 7) }
    static let iFrame = bytes("30 30 64 63 48 32 36 34 e8 03 00 00 08 00 00 00 15 cd 5b 07 00 00 00 00 00 f1 53 65 00 00 00 00") + iPayload
    static let pPayload: [UInt8] = [0, 0, 0, 1, 0x02, 1, 2, 3, 4, 5, 6, 7, 8]
    static let pFrame = bytes("30 31 64 63 48 32 36 35 0d 00 00 00 00 00 00 00 4a 4f 5c 07 00 00 00 00") + pPayload + [0, 0, 0]
    static let aacPayload: [UInt8] = [0xFF, 0xF1, 0x60, 0x40] + [UInt8](repeating: 0x21, count: 183)
    static let aac = bytes("30 35 77 62 bb 00 bb 00") + aacPayload + [0, 0, 0, 0, 0]
    static let all = info + iFrame + pFrame + aac

    /// An H.264 I-frame of the camera's stream, `timestamp` in microseconds.
    static func h264(keyframe: Bool, timestamp: UInt32, payload: [UInt8]) -> [UInt8] {
        Array((keyframe ? "00dc" : "01dc").utf8) + Array("H264".utf8) + Baichuan.littleEndian(UInt32(payload.count)) + Baichuan.littleEndian(0)
            + Baichuan.littleEndian(timestamp) + Baichuan.littleEndian(0) + payload + [UInt8](repeating: 0, count: BcMediaParser.padding(payload.count))
    }

    static func aacFrame(_ payload: [UInt8]) -> [UInt8] {
        let size = [UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)]
        return Array("05wb".utf8) + size + size + payload + [UInt8](repeating: 0, count: BcMediaParser.padding(payload.count))
    }

    /// A second of 15 fps video with AAC between the frames.
    static var stream: [UInt8] {
        var bytes = info
        for frame in 0..<15 {
            bytes += h264(keyframe: frame == 0, timestamp: UInt32(frame) * 66_666, payload: [0, 0, 0, 1, frame == 0 ? 0x65 : 0x41] + [UInt8](repeating: UInt8(frame), count: 300))
            bytes += aacFrame(aacPayload)
        }
        return bytes
    }
}
