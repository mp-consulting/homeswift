import Foundation
import HomeswiftNetwork
import Logging
import Testing

@testable import HomeswiftReolink

/// The spec's vectors (section 9) byte for byte, and the parser's checks.
@Suite struct BaichuanVectorTests {
    @Test func xorKeystreams() {
        #expect(hex(Baichuan.xor([UInt8](repeating: 0, count: 8), offset: 0)) == "1f 2d 3c 4b 5a 69 78 ff")
        #expect(hex(Baichuan.xor([UInt8](repeating: 0, count: 8), offset: 250)) == "c6 b1 a0 93 82 05 e5 d7")
        // It repeats every eight bytes.
        #expect(Array(Baichuan.xor([UInt8](repeating: 0, count: 16), offset: 250)[8...]) == Baichuan.xor([UInt8](repeating: 0, count: 8), offset: 250))
        #expect(hex(Baichuan.xor(Array("<?xml version=\"1.0\"".utf8), offset: 250)) == "fa 8e d8 fe ee 25 93 b2 b4 c2 c9 fc ec 38 c7 e6 e8 81 82")
        let text = Array("anything".utf8)
        #expect(Baichuan.xor(Baichuan.xor(text, offset: 77), offset: 77) == text)
    }

    @Test func hashesAndKey() {
        let nonce = "0a1b2c3d4e5f6a7b"
        #expect(Baichuan.md5mod("admin" + nonce) == "7D99C1CE9846F14A9EF988709951595")
        #expect(Baichuan.md5mod("Secret123" + nonce) == "B6368B64B0B8014C8B91739A9B971AB")
        #expect(Baichuan.md5mod("x").count == 31)
        let key = Baichuan.aesKey(nonce: nonce, password: "Secret123")
        #expect(String(decoding: key, as: UTF8.self) == "9CAEAF70935CDBA6")
        #expect(hex(key) == "39 43 41 45 41 46 37 30 39 33 35 43 44 42 41 36")
    }

    @Test func aesCFB128() throws {
        let key = Baichuan.aesKey(nonce: "0a1b2c3d4e5f6a7b", password: "Secret123")
        let plain = Array("<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body/>".utf8)
        // The spec's table says 48 bytes; the text and its ciphertext are 47.
        #expect(plain.count == 47)
        let cipher = try Baichuan.aes(plain, key: key, decrypt: false)
        #expect(hex(cipher).replacingOccurrences(of: " ", with: "")
            == "197170e110398a66ba77386c4cd2678ed5a7f3930e4dadf2379965476c8ef189c6d53830c07217f5eafdd9ea9e78a9")
        #expect(try Baichuan.aes(cipher, key: key, decrypt: true) == plain)
        // No padding: any length, a fresh state each time.
        #expect(try Baichuan.aes(Array(plain.prefix(5)), key: key, decrypt: false) == Array(cipher.prefix(5)))
    }

    @Test func loginBody() {
        let body = Baichuan.loginBody(username: "admin", password: "Secret123", nonce: "0a1b2c3d4e5f6a7b")
        #expect(body.utf8.count == 296)
        #expect(body.hasSuffix("</body>\n"))
        let encrypted = Baichuan.xor(Array(body.utf8), offset: 250)
        #expect(hex(Array(encrypted.prefix(32)))
            == "fa 8e d8 fe ee 25 93 b2 b4 c2 c9 fc ec 38 c7 e6 e8 81 82 b3 e7 6b 86 b8 a2 d8 ce f4 bf 27 b0 83")
    }

    @Test func headers() {
        #expect(hex(Baichuan.nonceRequest(counter: 1)) == "f0 de bc 0a 01 00 00 00 00 00 00 00 fa 01 00 00 12 dc 14 65")
        #expect(hex(Baichuan.header(command: 1, bodyLength: 296, channel: 250, counter: 2, extensionLength: 0))
            == "f0 de bc 0a 01 00 00 00 28 01 00 00 fa 02 00 00 00 00 14 64 00 00 00 00")
        #expect(hex(Baichuan.header(command: 31, bodyLength: 0, channel: 251, counter: 3, extensionLength: 0))
            == "f0 de bc 0a 1f 00 00 00 00 00 00 00 fb 03 00 00 00 00 14 64 00 00 00 00")
        #expect(hex(Baichuan.header(command: 93, bodyLength: 0, channel: 250, counter: 4, extensionLength: 0))
            == "f0 de bc 0a 5d 00 00 00 00 00 00 00 fa 04 00 00 00 00 14 64 00 00 00 00")
        let ext = Baichuan.channelExtension(0)
        let siren = Baichuan.sirenBody(channel: 0, mode: .times(2))
        #expect(ext.utf8.count == 104)
        #expect(siren.utf8.count == 224)
        #expect(siren.hasPrefix("\n<?xml"))
        #expect(hex(Baichuan.header(command: 263, bodyLength: ext.utf8.count + siren.utf8.count, channel: 1, counter: 5, extensionLength: ext.utf8.count))
            == "f0 de bc 0a 07 01 00 00 48 01 00 00 01 05 00 00 00 00 14 64 68 00 00 00")
    }

    @Test func pushHeader() {
        var framer = BaichuanFramer()
        let header = bytes("f0 de bc 0a 21 00 00 00 2c 01 00 00 fb 00 00 00 c8 00 14 64 00 00 00 00")
        let results = framer.push(header + [UInt8](repeating: 0x41, count: 300))
        let message = try? #require(results.first).get()
        #expect(message?.command == 33)
        #expect(message?.channel == 251)
        #expect(message?.status == 200)
        #expect(message?.body.count == 300)
    }

    // MARK: Reassembly

    static func message(_ command: UInt32, counter: UInt32, status: UInt16 = 200, body: [UInt8]) -> [UInt8] {
        var header = Baichuan.header(command: command, bodyLength: body.count, channel: 250, counter: counter, extensionLength: 0)
        header[16] = UInt8(status & 0xFF)
        header[17] = UInt8(status >> 8)
        return header + body
    }

    @Test func twoMessagesInOneRead() {
        var framer = BaichuanFramer()
        let results = framer.push(Self.message(31, counter: 3, body: [1, 2, 3]) + Self.message(93, counter: 4, body: []))
        #expect(results.compactMap { try? $0.get().command } == [31, 93])
        #expect(framer.pendingCount == 0)
    }

    @Test func splitMessages() {
        let message = Self.message(33, counter: 7, body: Array("<?xml version=\"1.0\"?><body/>".utf8))
        for split in [3, 10, 22, 30] {
            var framer = BaichuanFramer()
            #expect(framer.push(Array(message[..<split])).isEmpty, "split at \(split)")
            let results = framer.push(Array(message[split...]))
            #expect(results.count == 1, "split at \(split)")
            #expect((try? results.first?.get())?.body == Array(message[24...]))
        }
    }

    @Test func garbageBeforeAMagicIsDropped() {
        var framer = BaichuanFramer()
        let results = framer.push([1, 2, 3, 4, 5] + Self.message(31, counter: 1, body: []))
        #expect(results.count == 1)
        // A partial magic waits for the rest.
        #expect(framer.push([0xF0, 0xDE]).isEmpty)
        #expect(framer.pendingCount == 2)
    }

    @Test func encryptedClassReply() throws {
        // A 1466 reply whose bytes 16-17 say Baichuan XOR.
        let xml = Array("<?xml version=\"1.0\" ?><body><nonce>abc</nonce></body>".utf8)
        let body = Baichuan.xor(xml, offset: 250)
        var header = Baichuan.magic + Baichuan.littleEndian(1) + Baichuan.littleEndian(UInt32(body.count))
        header += [250, 1, 0, 0, 0x01, 0xDD, 0x14, 0x66]
        var framer = BaichuanFramer()
        let message = try #require(framer.push(header + body).first).get()
        #expect(message.declaredEncryption == .xor)
        #expect(message.status == nil)
        let text = try BaichuanDecoder.decrypt(message.body, expected: .xor, offset: message.channel, key: nil)
        #expect(try BXParser.parse(text).first("nonce")?.text == "abc")
    }

    @Test func statusOkAndUnauthorised() {
        var framer = BaichuanFramer()
        let ok = framer.push(Self.message(1, counter: 2, status: 200, body: []))
        let refused = framer.push(Self.message(1, counter: 2, status: 401, body: []))
        #expect((try? ok.first?.get())?.status == 200)
        #expect(hex(Array(Self.message(1, counter: 2, status: 401, body: [])[16...17])) == "91 01")
        #expect((try? refused.first?.get())?.status == 401)
    }

    @Test func unknownClassIsAnError() {
        var framer = BaichuanFramer()
        var message = Self.message(1, counter: 1, body: [])
        message[18] = 0x99
        message[19] = 0x99
        let results = framer.push(message)
        if case .failure(let error)? = results.first { #expect(error == .unknownClass(0x99, 0x99)) } else { Issue.record("no error") }
    }

    @Test func decryptionFallsBackToTheOtherMethod() throws {
        let key = Baichuan.aesKey(nonce: "n", password: "p")
        let xml = "<?xml version=\"1.0\" ?><body/>"
        // Expected AES but sent as XOR.
        #expect(try BaichuanDecoder.decrypt(Baichuan.xor(Array(xml.utf8), offset: 251), expected: .aes, offset: 251, key: key) == xml)
        #expect(try BaichuanDecoder.decrypt(try Baichuan.aes(Array(xml.utf8), key: key, decrypt: false), expected: .aes, offset: 0, key: key) == xml)
        #expect(try BaichuanDecoder.decrypt(Array(xml.utf8), expected: .aes, offset: 0, key: key) == xml)
        #expect(throws: BaichuanError.undecryptable) { try BaichuanDecoder.decrypt([1, 2, 3], expected: .aes, offset: 0, key: key) }
        #expect(try BaichuanDecoder.decrypt([], expected: .aes, offset: 0, key: key) == "")
    }

    // MARK: Events (5.4.1)

    @Test func alarmEvents() {
        var unknown: Set<String> = []
        let pushes = BaichuanEvents.parse(command: 33, xml: alarmXML(status: "MD,visitor", ai: "people"), unknown: &unknown)
        #expect(pushes == [.alarm(channel: 0, motion: true, visitor: true, aiDetected: ["people"])])
        let cleared = BaichuanEvents.parse(command: 33, xml: alarmXML(status: "none", ai: "none"), unknown: &unknown)
        #expect(cleared == [.alarm(channel: 0, motion: false, visitor: false, aiDetected: ["none"])])
        // A battery camera's PIR comes as `other`.
        let pir = BaichuanEvents.parse(command: 33, xml: alarmXML(channel: 3, status: "none", ai: "other"), unknown: &unknown)
        #expect(pir == [.alarm(channel: 3, motion: true, visitor: false, aiDetected: ["other"])])
        _ = BaichuanEvents.parse(command: 33, xml: alarmXML(status: "MD", ai: "people,bicycle"), unknown: &unknown)
        #expect(unknown.contains("AI type bicycle"))
    }

    @Test func otherPushes() {
        var unknown: Set<String> = []
        let sleep = "<?xml version=\"1.0\" ?><body><ChannelInfoList><ChannelInfo><channelId>2</channelId><loginState>standby</loginState></ChannelInfo></ChannelInfoList></body>"
        #expect(BaichuanEvents.parse(command: 145, xml: sleep, unknown: &unknown) == [.sleep(channel: 2, asleep: true)])
        let light = "<?xml version=\"1.0\" ?><body><FloodlightStatusList><FloodlightStatus><channel>0</channel><status>1</status></FloodlightStatus></FloodlightStatusList></body>"
        #expect(BaichuanEvents.parse(command: 291, xml: light, unknown: &unknown) == [.floodlight(channel: 0, on: true)])
        let siren = "<?xml version=\"1.0\" ?><body><SirenStatusList><SirenStatus><channel>1</channel><status>0</status></SirenStatus></SirenStatusList></body>"
        #expect(BaichuanEvents.parse(command: 547, xml: siren, unknown: &unknown) == [.siren(channel: 1, playing: false)])
        #expect(BaichuanEvents.parse(command: 33, xml: "not xml", unknown: &unknown).isEmpty)
    }
}

/// A session against the fake camera: the login, the subscription, events, the keepalive, the siren, reconnects.
@Suite struct BaichuanSessionTests {
    func session(_ camera: FakeBaichuanCamera, password: String = "secret", scale: Double = 0.01, connects: NIOCounter = NIOCounter()) -> BaichuanSession {
        BaichuanSession(host: "camera", port: 9000, username: "admin", password: password, connect: { _, _, _ in
            connects.increment()
            return camera
        }, log: testLogger, timing: ReolinkTiming(scale: scale))
    }

    @Test func logsInSubscribesAndDeliversEvents() async throws {
        let camera = FakeBaichuanCamera()
        let session = session(camera)
        let runner = Task { await session.run() }
        defer { runner.cancel() }
        #expect(await eventually { await session.isConnected })
        #expect(camera.commands.prefix(2) == [1, 31])
        camera.push(alarmXML(status: "MD", ai: "people"))
        var iterator = session.events.makeAsyncIterator()
        #expect(await iterator.next() == .active(true))
        #expect(await iterator.next() == .push(.alarm(channel: 0, motion: true, visitor: false, aiDetected: ["people"])))
        // Keepalive: 93 once events are active.
        #expect(await eventually { camera.commands.contains(93) })
        try await session.siren(channel: 0, mode: .manual(true))
        #expect(camera.sirenBodies.first?.contains("<playMode>2</playMode>") == true)
        #expect(camera.sirenBodies.first?.contains("<onOff>1</onOff>") == true)
        await session.stop()
        #expect(camera.commands.contains(2))
    }

    @Test func wrongPasswordIsRefusedAndRetriedSlowly() async {
        let camera = FakeBaichuanCamera()
        let connects = NIOCounter()
        let session = session(camera, password: "wrong", connects: connects)
        let runner = Task { await session.run() }
        try? await Task.sleep(for: .milliseconds(300))
        runner.cancel()
        #expect(await !session.isConnected)
        // Logins at most every 15 s and Backoff from 5 s, both scaled by 0.01: a handful, not hundreds.
        #expect(connects.value >= 1 && connects.value < 5)
    }
}

/// A thread-safe counter.
final class NIOCounter: Sendable {
    private let box = NIOLockedValueBox(0)
    func increment() { box.withLockedValue { $0 += 1 } }
    var value: Int { box.withLockedValue { $0 } }
}

import NIOConcurrencyHelpers
