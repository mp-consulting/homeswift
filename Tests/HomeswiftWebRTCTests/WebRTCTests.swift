import Foundation
import HomeswiftNetwork
import Testing

@testable import HomeswiftWebRTC

func bytes(_ hex: String) -> [UInt8] {
    let digits = Array(hex.filter { !$0.isWhitespace })
    return stride(from: 0, to: digits.count - 1, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
}

func hex(_ data: [UInt8]) -> String { data.map { String(format: "%02x", $0) }.joined() }

/// RFC 5769's STUN test vectors, byte for byte.
@Suite struct STUNTests {
    static let password = Array("VOkJxbRl1RmTxUk/WvJxBt".utf8)
    static let transaction = bytes("b7e7a701 bc34d686 fa87dfae")

    static let request = bytes("""
        00010058 2112a442 b7e7a701 bc34d686 fa87dfae 80220010 5354554e 20746573 7420636c 69656e74 00240004 6e0001ff
        80290008 932ff9b1 51263b36 00060009 6576746a 3a683676 59202020 00080014 9aeaa70c bfd8cb56 781ef2b5 b2d3f249
        c1b571a2 80280004 e57a3bcf
        """)

    static let ipv4Response = bytes("""
        0101003c 2112a442 b7e7a701 bc34d686 fa87dfae 8022000b 74657374 20766563 746f7220 00200008 0001a147 e112a643
        00080014 2b91f599 fd9e90c3 8c7489f9 2af9ba53 f06be7d7 80280004 c07d4c96
        """)

    static let ipv6Response = bytes("""
        01010048 2112a442 b7e7a701 bc34d686 fa87dfae 8022000b 74657374 20766563 746f7220 00200014 0002a147 0113a9fa
        a5d3f179 bc25f4b5 bed2b9d9 00080014 a382954e 4be67bf1 1784c97c 8292c275 bfe3ed41 80280004 c8fb0b4c
        """)

    @Test func theSampleRequestDecodesAndVerifies() throws {
        let message = try #require(STUNMessage.decode(Self.request))
        #expect(message.kind == .bindingRequest)
        #expect(message.transactionID == Self.transaction)
        #expect(message.attribute(.username).map { String(decoding: $0, as: UTF8.self) } == "evtj:h6vY")
        #expect(message.attribute(.priority) == bytes("6e0001ff"))
        #expect(STUNMessage.verifyIntegrity(Self.request, key: Self.password))
        #expect(!STUNMessage.verifyIntegrity(Self.request, key: Array("wrong".utf8)))
        #expect(STUNMessage.verifyFingerprint(Self.request))
        // Re-encoded with its attributes and the vector's space padding, it is the same bytes.
        #expect(message.encode(integrityKey: Self.password, padding: 0x20) == Self.request)
    }

    @Test func theResponsesCarryTheMappedAddress() throws {
        let v4 = try #require(STUNMessage.decode(Self.ipv4Response))
        let address = try #require(v4.attribute(.xorMappedAddress))
        #expect(STUNMessage.address(fromXOR: address, transactionID: Self.transaction)?.host == "192.0.2.1")
        #expect(STUNMessage.address(fromXOR: address, transactionID: Self.transaction)?.port == 32853)
        #expect(STUNMessage.xorAddress(host: "192.0.2.1", port: 32853, transactionID: Self.transaction) == address)
        #expect(v4.encode(integrityKey: Self.password, padding: 0x20) == Self.ipv4Response)

        let v6 = try #require(STUNMessage.decode(Self.ipv6Response))
        let address6 = try #require(v6.attribute(.xorMappedAddress))
        #expect(STUNMessage.address(fromXOR: address6, transactionID: Self.transaction)?.host == "2001:db8:1234:5678:11:2233:4455:6677")
        #expect(STUNMessage.xorAddress(host: "2001:db8:1234:5678:11:2233:4455:6677", port: 32853, transactionID: Self.transaction) == address6)
        #expect(v6.encode(integrityKey: Self.password, padding: 0x20) == Self.ipv6Response)
        #expect(STUNMessage.verifyIntegrity(Self.ipv6Response, key: Self.password))
    }

    @Test func damagedMessagesAreRefused() {
        var broken = Self.request
        broken[30] ^= 0x01
        #expect(!STUNMessage.verifyFingerprint(broken))
        #expect(!STUNMessage.verifyIntegrity(broken, key: Self.password))
        #expect(STUNMessage.decode(Array(Self.request.dropLast(3))) == nil)
        #expect(!STUNMessage.isSTUN(bytes("80 60 00 01") + [UInt8](repeating: 0, count: 16)))
    }
}

/// RFC 3711 appendix B and libsrtp's reference packets (test/srtp_driver.c, `srtp_validate`).
@Suite struct SRTPTests {
    static let masterKey = bytes("E1F97A0D3E018BE0D64FA32C06DE4139")
    static let masterSalt = bytes("0EC675AD498AFEEBB6960B3AABE6")

    @Test func keysDeriveAsTheRFCShows() throws {
        let context = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        #expect(context.rtp.cipher.withUnsafeBytes { Array($0) } == bytes("C61E7A93744F39EE10734AFE3FF7A087"))
        #expect(context.rtp.salt == bytes("30CBBC08863D8C85D49DB34A9AE1"))
        #expect(context.rtp.auth.withUnsafeBytes { Array($0) } == bytes("CEBE321F6FF7716B6FD4AB49AF256A156D38BAA4"))
    }

    @Test func theKeystreamIsAESInCounterMode() throws {
        let stream = try SRTPContext.keystream(key: .init(data: bytes("2B7E151628AED2A6ABF7158809CF4F3C")), iv: bytes("F0F1F2F3F4F5F6F7F8F9FAFBFCFD0000"), count: 48)
        #expect(hex(stream) == "e03ead0935c95e80e166b16dd92b4eb4d23513162b02d0f72a43a2fe4a5f97ab41e95b3bb0a2e8dd477901e4fca894c0")
    }

    @Test func rtpIsProtectedAsLibsrtpDoes() throws {
        var sender = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        let plain = bytes("800f1234 decafbad cafebabe") + [UInt8](repeating: 0xab, count: 16)
        let protected = try sender.protect(rtp: plain)
        #expect(hex(protected) == "800f1234decafbadcafebabe4e55dc4ce79978d88ca4d215949d2402b78d6acc99ea179b8dbb")
        var receiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        #expect(try receiver.unprotect(rtp: protected) == plain)
        var tampered = protected
        tampered[14] ^= 1
        #expect(throws: SRTPContext.Failure.authentication) { try receiver.unprotect(rtp: tampered) }
    }

    @Test func rtcpIsProtectedAsLibsrtpDoes() throws {
        var sender = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        let plain = bytes("81c8000b cafebabe") + [UInt8](repeating: 0xab, count: 16)
        let protected = try sender.protect(rtcp: plain)
        #expect(hex(protected) == "81c8000bcafebabe7128035be487b9bdbef89041f977a5a880000001993e08cd54d6c1230798")
        let receiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        #expect(try receiver.unprotect(rtcp: protected) == plain)
    }

    @Test func theRolloverCounterFollowsAWrap() throws {
        var sender = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        var receiver = try SRTPContext(masterKey: Self.masterKey, masterSalt: Self.masterSalt)
        for sequence: UInt16 in [0xfffe, 0xffff, 0x0000, 0x0001] {
            let packet = bytes("8060") + STUNMessage.be16(sequence) + bytes("00000001 11223344 0102030405")
            #expect(try receiver.unprotect(rtp: try sender.protect(rtp: packet)) == packet)
        }
    }

    @Test func badKeysAreRefused() {
        #expect(throws: SRTPContext.Failure.badKey) { try SRTPContext(masterKey: [1, 2], masterSalt: Self.masterSalt) }
    }
}

@Suite struct ICETests {
    @Test func candidatesReadAndWriteAsSDPHasThem() throws {
        let candidate = try #require(ICECandidate(sdp: "a=candidate:842163049 1 udp 1677729535 203.0.113.7 51234 typ srflx raddr 192.168.1.20 rport 51234 generation 0"))
        #expect(candidate.kind == .srflx && candidate.address == "203.0.113.7" && candidate.port == 51234 && candidate.relatedAddress == "192.168.1.20")
        #expect(candidate.sdp == "candidate:842163049 1 udp 1677729535 203.0.113.7 51234 typ srflx raddr 192.168.1.20 rport 51234")
        #expect(ICECandidate(sdp: "candidate:1 1 udp 5 host") == nil)
        // RFC 8445's formula: a host candidate on component 1 with the highest local preference.
        #expect(ICECandidate.priority(kind: .host) == 2_130_706_431)
    }

    @Test func twoAgentsFindEachOtherOnTheLoopback() async throws {
        let a = ICEAgent(socket: try await UDPSocket.bind(host: "127.0.0.1", port: 0, senderPorts: true))
        let b = ICEAgent(socket: try await UDPSocket.bind(host: "127.0.0.1", port: 0, senderPorts: true))
        for candidate in await b.hostCandidates(addresses: ["127.0.0.1"]) { await a.add(remote: candidate) }
        for candidate in await a.hostCandidates(addresses: ["127.0.0.1"]) { await b.add(remote: candidate) }
        await a.start(remote: b.local)
        await b.start(remote: a.local)
        let selectedA = await a.waitForSelection()
        let selectedB = await b.waitForSelection()
        #expect(selectedA != nil && selectedB != nil)
        // Media flows on the selected pair.
        try await a.send([0x80, 0x60, 0x00, 0x01])
        var iterator = b.received.makeAsyncIterator()
        #expect(await iterator.next() == [0x80, 0x60, 0x00, 0x01])
        await a.stop()
        await b.stop()
    }

    @Test func aWrongPasswordNeverConnects() async throws {
        let a = ICEAgent(socket: try await UDPSocket.bind(host: "127.0.0.1", port: 0, senderPorts: true), attempts: 5)
        let b = ICEAgent(socket: try await UDPSocket.bind(host: "127.0.0.1", port: 0, senderPorts: true), attempts: 5)
        for candidate in await b.hostCandidates(addresses: ["127.0.0.1"]) { await a.add(remote: candidate) }
        await a.start(remote: ICECredentials(ufrag: b.local.ufrag, password: "not-the-password-at-all"))
        await b.start(remote: a.local)
        #expect(await a.waitForSelection() == nil)
        await a.stop()
        await b.stop()
    }
}

@Suite struct SDPTests {
    @Test func theOfferHasRingsShape() {
        let offer = SDPOffer(
            fingerprint: "AA:BB", audio: .init(credentials: .init(ufrag: "Ab3d", password: "p" + String(repeating: "x", count: 23)), ssrc: 1111),
            video: .init(credentials: .init(ufrag: "Xy9z", password: "q" + String(repeating: "y", count: 23)), ssrc: 2222), sessionID: 7,
            videoRTXSSRC: 3333, cname: "c")
        let lines = offer.text.components(separatedBy: "\r\n")
        #expect(lines.contains("m=audio 9 UDP/TLS/RTP/SAVPF 96 0"))
        #expect(lines.contains("m=video 9 UDP/TLS/RTP/SAVPF 98 99"))
        #expect(lines.contains("a=fmtp:98 packetization-mode=1;profile-level-id=640029;level-asymmetry-allowed=1"))
        #expect(lines.contains("a=ssrc-group:FID 2222 3333"))
        #expect(!offer.text.contains("BUNDLE"))
        #expect(lines.filter { $0 == "a=setup:actpass" }.count == 2)
        #expect(lines.firstIndex(of: "a=sendrecv")! < lines.firstIndex(of: "a=recvonly")!)
    }

    @Test func theAnswerGivesEachMediaItsTransport() {
        let answer = SDPAnswer("""
            v=0\r
            o=- 1 1 IN IP4 0.0.0.0\r
            a=fingerprint:sha-256 11:22\r
            m=audio 9 UDP/TLS/RTP/SAVPF 96\r
            a=ice-ufrag:ring\r
            a=ice-pwd:ringpasswordringpassword\r
            a=setup:active\r
            a=rtpmap:96 opus/48000/2\r
            a=candidate:1 1 udp 2130706431 192.168.1.50 40000 typ host\r
            m=video 9 UDP/TLS/RTP/SAVPF 98\r
            a=ice-ufrag:ring2\r
            a=ice-pwd:ringpassword2ringpassword2\r
            a=setup:passive\r
            a=rtpmap:98 H264/90000\r
            """)
        #expect(answer.media.count == 2)
        #expect(answer.audioIsOpus)
        #expect(answer.audio?.credentials == ICECredentials(ufrag: "ring", password: "ringpasswordringpassword"))
        #expect(answer.audio?.fingerprint == "sha-256 11:22")
        #expect(answer.audio?.candidates.first?.port == 40000)
        #expect(answer.video?.setup == "passive" && answer.video?.codecs[98] == "H264")
    }
}
