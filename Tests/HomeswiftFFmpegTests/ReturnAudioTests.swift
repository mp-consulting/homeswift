import Foundation
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftFFmpeg

// docs/clean-room/ReturnAudio.md: the encoders against section 8's vectors, the SDP and command line, the framing, and the
// receiver against packets sent to its audio return port, with a fake decoder standing in for FFmpeg.

@Suite struct AudioEncoderTests {
    @Test func g711MatchesTheVectors() {
        let samples: [Int16] = [0, 1, -1, 1000, -1000, 8000, -8000, 32767, -32768]
        #expect(G711.aLaw(samples) == [0xD5, 0xD5, 0x55, 0xFA, 0x7A, 0x8A, 0x0A, 0xAA, 0x2A])
        #expect(G711.muLaw(samples) == [0xFF, 0xFF, 0x7E, 0xCE, 0x4E, 0xA0, 0x20, 0x80, 0x00])
    }

    @Test func imaADPCMMatchesTheVectors() {
        let input = (0..<2050).map { Int16((8000 * sin(2 * Double.pi * 1000 * Double($0) / 16000)).rounded()) }
        #expect(IMAADPCMEncoder.samplesPerBlock(blockSize: 516) == 1025)
        var encoder = IMAADPCMEncoder()
        let first = encoder.encodeBlock(input[0..<1025])
        let second = encoder.encodeBlock(input[1025..<2050])
        #expect(first.count == 516 && second.count == 516)
        #expect(Array(first.prefix(24)) == [0x00, 0x00, 0x00, 0x00, 0x77, 0x77, 0x77, 0xE7, 0xBC, 0x99, 0x21, 0x35, 0x34, 0x02, 0xB8, 0xDC,
                                            0xAB, 0x8A, 0x20, 0x45, 0x23, 0x02, 0xB8, 0xDC])
        #expect(Array(first.suffix(8)) == [0x23, 0x02, 0xB8, 0xDC, 0xAB, 0x8A, 0x30, 0x54])
        #expect(Array(second.prefix(12)) == [0xF5, 0x0B, 0x41, 0x00, 0x22, 0x80, 0xCA, 0xBC, 0xBB, 0x18, 0x52, 0x34])
        #expect(encoder.index == 63)
    }

    @Test func volumeScalesWithoutAmplifying() {
        #expect(PCMVolume.scale([1000, -1000, 32767], volume: 50) == [500, -500, 16383])
        #expect(PCMVolume.scale([1000], volume: 150) == [1000])
        #expect(PCMVolume.scale([1000], volume: 0) == [0])
    }

    @Test func adtsFramesAreSplitAtSyncWords() {
        // Two frames of 9 bytes (header 7, no CRC), in odd chunks with a stray byte in front.
        func frame(_ fill: UInt8) -> [UInt8] { [0xFF, 0xF1, 0x50, 0x80, 0x01, 0x20, 0xFC, fill, fill] }
        var splitter = ADTSFrameSplitter()
        let stream = [0x00] + frame(1) + frame(2)
        #expect(splitter.push(stream.prefix(5)).isEmpty)
        let frames = splitter.push(stream.dropFirst(5))
        #expect(frames == [frame(1), frame(2)])
        #expect(Array(ADTSFrameSplitter.payload(of: frame(1))) == [1, 1])
    }
}

@Suite struct ReturnAudioArgumentTests {
    @Test func sdpMatchesTheVector() {
        let sdp = ReturnAudioArguments.sdp(address: "192.168.1.20", isIPv6: false, port: 50002, payloadType: 110, srtp: Data(0..<30))
        #expect(sdp.contains("a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwd\r\n"))
        #expect(sdp.contains("\r\nm=audio 50002 RTP/AVP 110\r\n"))
        #expect(sdp.hasPrefix("v=0\r\no=- 0 0 IN IP4 192.168.1.20\r\ns=Talk\r\nc=IN IP4 192.168.1.20\r\nt=0 0\r\n"))
        #expect(sdp.contains("a=fmtp:110 profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3; config=F8F0212C00BC00\r\n"))
        let other = ReturnAudioArguments.sdp(address: "fe80::1", isIPv6: true, port: 50004, payloadType: 111, srtp: Data(0..<30))
        #expect(other.contains("a=rtpmap:111 MPEG4-GENERIC/16000/1") && other.contains("c=IN IP6 fe80::1"))
    }

    @Test func decodeCommandLine() {
        let arguments = ReturnAudioArguments.decode(decoder: ["-c:a", "libfdk_aac"], sampleRate: 8000, debug: false)
        #expect(arguments.joined(separator: " ") ==
            "-hide_banner -loglevel error -protocol_whitelist pipe,udp,rtp,file,crypto -f sdp -c:a libfdk_aac -i pipe:0 -vn -sn -dn -ac 1 -ar 8000 -acodec pcm_s16le -f s16le -flush_packets 1 pipe:1")
        #expect(ReturnAudioArguments.decode(decoder: [], sampleRate: 16000, debug: true).starts(with: ["-hide_banner", "-loglevel", "level+verbose"]))
    }

    @Test func decoderFollowsTheCodecs() async {
        func ffmpeg(_ decoders: Set<String>) -> RTSPCameraFFmpeg {
            let codecs = FfmpegCodecs(log: Logger(label: "test"), ffmpegVersion: "7.0", decoders: ["aac": decoders])
            let config = FfmpegOptionsConfig(codecSupport: codecs, hardwareDecoding: false, hardwareTranscoding: false, log: Logger(label: "test"), name: { "test" })
            return RTSPCameraFFmpeg(options: FfmpegOptions(config), codecs: codecs)
        }
        #expect(await ffmpeg(["aac", "libfdk_aac"]).returnAudioDecoder() == ["-c:a", "libfdk_aac"])
        #expect(await ffmpeg(["aac", "aac_at"]).returnAudioDecoder() == ["-c:a", "aac_at"])
        #expect(await ffmpeg(["aac"]).returnAudioDecoder() == [])
    }

    @Test func aacEncoderCommandLine() {
        #expect(AACTalkEncoder.arguments(sampleRate: 16000).joined(separator: " ") ==
            "-hide_banner -loglevel error -f s16le -ar 16000 -ac 1 -i pipe:0 -c:a aac -profile:a aac_low -b:a 32k -f adts -flush_packets 1 pipe:1")
    }

    @Test func formats() {
        #expect(ReturnAudioFormat(sampleRate: 8000).samplesPerFrame == 160)
        #expect(ReturnAudioFormat(sampleRate: 16000).samplesPerFrame == 320)
        #expect(ReturnAudioFormat(sampleRate: 16000, frameDuration: .milliseconds(100)).frameDuration == .milliseconds(60))
        #expect(ReturnAudioFormat(sampleRate: 8000, frameDuration: .milliseconds(5)).samplesPerFrame == 80)
    }
}

@Suite struct PCMFramerTests {
    @Test func chunksOfAnySizeGiveWholeFrames() {
        var framer = PCMFramer(samplesPerFrame: 320)
        let bytes = (0..<1284).map { UInt8($0 & 0xFF) }
        var frames: [[Int16]] = []
        var at = 0
        for size in [1, 639, 641, 3] {
            frames += framer.push(bytes[at..<(at + size)])
            at += size
        }
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0.count == 320 })
        #expect(framer.remainder == 4)
        #expect(frames[0][0] == Int16(bitPattern: 0x0100))
        let last = framer.flush()
        #expect(last?.count == 320 && last?[2] == 0)
        #expect(framer.flush() == nil)
    }

    @Test func theSpecsFraming() {
        var framer = PCMFramer(samplesPerFrame: 320)
        #expect(framer.push([UInt8](repeating: 1, count: 1000)).count == 1)
        #expect(framer.remainder == 360)
        #expect(framer.push([UInt8](repeating: 1, count: 280)).count == 1)
        #expect(framer.remainder == 0)
        var narrow = PCMFramer(samplesPerFrame: ReturnAudioFormat(sampleRate: 8000).samplesPerFrame)
        #expect(narrow.push([UInt8](repeating: 0, count: 320)).count == 1)
    }
}

/// A decoder that runs nothing: the test writes its standard output and ends it.
final class FakeReturnAudioDecoder: ReturnAudioDecoding {
    struct State {
        var output: (@Sendable (Data) -> Void)?
        var exit: (@Sendable () -> Void)?
        var sdp = ""
        var stopped = false
    }

    let arguments: [String]
    let state = NIOLockedValueBox(State())

    init(arguments: [String]) { self.arguments = arguments }

    func start(sdp: Data, output: @escaping @Sendable (Data) -> Void, exit: @escaping @Sendable () -> Void) -> Bool {
        state.withLockedValue {
            $0.output = output
            $0.exit = exit
            $0.sdp = String(decoding: sdp, as: UTF8.self)
        }
        return true
    }

    func stop() {
        let exit = state.withLockedValue { state -> (@Sendable () -> Void)? in
            state.stopped = true
            defer { state.exit = nil }
            return state.exit
        }
        exit?()
    }

    func emit(_ data: Data) { state.withLockedValue { $0.output }?(data) }

    func end() { state.withLockedValue { state in defer { state.exit = nil }; return state.exit }?() }
}

/// The decoders made, in order.
final class FakeDecoders: Sendable {
    let made = NIOLockedValueBox<[FakeReturnAudioDecoder]>([])

    var factory: ReturnAudioDecoderFactory {
        { [made] _, arguments in
            let decoder = FakeReturnAudioDecoder(arguments: arguments)
            made.withLockedValue { $0.append(decoder) }
            return decoder
        }
    }

    var count: Int { made.withLockedValue { $0.count } }
    var last: FakeReturnAudioDecoder? { made.withLockedValue { $0.last } }
}

/// What the handler saw of each Talk.
final class TalkRecorder: Sendable {
    struct Record: Sendable {
        var volume: Int
        var frames: [PCMFrame] = []
        var ended = false
    }

    let talks = NIOLockedValueBox<[Record]>([])

    var handler: ReturnAudioHandler {
        { [talks] talk in
            let index = talks.withLockedValue { talks in
                talks.append(Record(volume: talk.volume))
                return talks.count - 1
            }
            for await frame in talk.frames { talks.withLockedValue { $0[index].frames.append(frame) } }
            talks.withLockedValue { $0[index].ended = true }
        }
    }

    var count: Int { talks.withLockedValue { $0.count } }
    func talk(_ index: Int) -> Record? { talks.withLockedValue { index < $0.count ? $0[index] : nil } }
}

@Suite struct ReturnAudioReceiverTests {
    /// A return audio RTP packet (section 8.4), before SRTP: the receiver counts it and never reads it.
    static let packet = Data([0x80, 0x6E, 0x00, 0x01, 0x00, 0x00, 0x01, 0xE0, 0x00, 0xAB, 0xCD, 0xEF, 0x00, 0x10, 0x03, 0xC0] + [UInt8](repeating: 0, count: 120))
    static let rtcp = Data([0x80, 0xC9, 0x00, 0x01, 0x00, 0xAB, 0xCD, 0xEF])

    struct Fixture {
        let receiver: ReturnAudioReceiver
        let decoders: FakeDecoders
        let talks: TalkRecorder
        let port: Int
        let ports: RtpPortAllocator
        let logs: LogRecorder
    }

    func fixture(idle: Duration = .seconds(1), maximum: Duration = .seconds(600), rate: Int = 16000, volume: Int = 100) async throws -> Fixture {
        let ports = RtpPortAllocator()
        let port = await ports.reserve()
        try #require(port > 0)
        let decoders = FakeDecoders(), talks = TalkRecorder(), logs = LogRecorder()
        let codecs = FfmpegCodecs(log: logs.logger, ffmpegVersion: "7.0", decoders: ["aac": ["aac", "libfdk_aac"]])
        let config = FfmpegOptionsConfig(codecSupport: codecs, hardwareDecoding: false, hardwareTranscoding: false, log: logs.logger, name: { "test" })
        let receiver = ReturnAudioReceiver(
            stream: .init(sessionID: "session", returnPort: port, ipFamily: .ipv4, controllerAddress: "127.0.0.1", srtp: Data(0..<30), payloadType: 110),
            ports: ports, ffmpeg: RTSPCameraFFmpeg(options: FfmpegOptions(config), codecs: codecs),
            options: ReturnAudioOptions(format: ReturnAudioFormat(sampleRate: rate), idleTimeout: idle, maximumTalk: maximum, handler: talks.handler),
            name: "Camera", log: logs.logger, volume: volume, timeScale: 0.1, decoder: decoders.factory)
        return Fixture(receiver: receiver, decoders: decoders, talks: talks, port: port, ports: ports, logs: logs)
    }

    @Test func nothingHappensWithoutAudio() async throws {
        let f = try await fixture()
        #expect(await f.receiver.start())
        #expect(await f.receiver.isListening)
        try await sendUDP(Self.rtcp, to: f.port)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.decoders.count == 0)
        #expect(f.talks.count == 0)
        let reserved = f.ports.reservedPorts.count
        await f.receiver.close()
        #expect(f.ports.reservedPorts.count == reserved - 2)
        #expect(!f.logs.messages.contains { $0.contains("Talk") })
    }

    @Test func aTalkGetsWholeFramesUntilItGoesIdle() async throws {
        let f = try await fixture(volume: 70)
        #expect(await f.receiver.start())
        try await sendUDP(Self.packet, to: f.port)
        #expect(await eventually { f.decoders.count == 1 && f.talks.count == 1 })
        let decoder = try #require(f.decoders.last)
        #expect(decoder.arguments.contains("libfdk_aac") && decoder.arguments.contains("16000"))
        #expect(decoder.state.withLockedValue { $0.sdp }.contains("inline:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwd"))
        decoder.emit(Data(repeating: 0x01, count: 1000))
        decoder.emit(Data(repeating: 0x01, count: 100))
        #expect(await eventually { f.talks.talk(0)?.ended == true })
        let talk = try #require(f.talks.talk(0))
        #expect(talk.volume == 70)
        #expect(talk.frames.map(\.offset) == [0, 320])
        #expect(talk.frames.allSatisfy { $0.samples.count == 320 })
        // The partial frame: 460 bytes, 230 samples, then zeros.
        #expect(talk.frames[1].samples[229] == 0x0101 && talk.frames[1].samples[230] == 0)
        #expect(f.logs.messages.contains("Camera: Talk started."))
        #expect(f.logs.messages.contains { $0.hasPrefix("Camera: Talk ended (") })
        // FFmpeg flushing late, no Talk open: dropped.
        decoder.emit(Data(repeating: 0, count: 640))
        try await sendUDP(Self.packet, to: f.port)
        #expect(await eventually { f.talks.count == 2 })
        #expect(f.decoders.count == 1)
        await f.receiver.close()
        #expect(await eventually { f.talks.talk(1)?.ended == true })
        #expect(f.talks.talk(1)?.frames.isEmpty == true)
        #expect(decoder.state.withLockedValue { $0.stopped })
    }

    @Test func packetsKeepATalkOpenAndAGapEndsIt() async throws {
        // Idle 5 s × 0.1: packets every 30 ms keep it open, the silence after them ends it.
        let f = try await fixture(idle: .seconds(5))
        #expect(await f.receiver.start())
        for _ in 0..<10 {
            try await sendUDP(Self.packet, to: f.port)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(f.talks.count == 1)
        #expect(await eventuallyAsync { await !f.receiver.isTalking })
        for _ in 0..<3 {
            try await sendUDP(Self.packet, to: f.port)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await eventually { f.talks.count == 2 })
        #expect(await f.receiver.talkCount == 2)
        await f.receiver.close()
    }

    @Test func theLongestTalkEnds() async throws {
        let f = try await fixture(idle: .seconds(60), maximum: .seconds(1))
        #expect(await f.receiver.start())
        try await sendUDP(Self.packet, to: f.port)
        #expect(await eventually { f.talks.talk(0)?.ended == true })
        await f.receiver.close()
    }

    @Test func muteEndsATalkAndStopsNewOnes() async throws {
        let f = try await fixture(idle: .seconds(60))
        #expect(await f.receiver.start())
        try await sendUDP(Self.packet, to: f.port)
        #expect(await eventuallyAsync { await f.receiver.isTalking })
        await f.receiver.speakerChanged(muted: true, volume: 40)
        #expect(await eventually { f.talks.talk(0)?.ended == true })
        try await sendUDP(Self.packet, to: f.port)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.talks.count == 1)
        await f.receiver.speakerChanged(muted: false, volume: 40)
        try await sendUDP(Self.packet, to: f.port)
        #expect(await eventually { f.talks.count == 2 })
        #expect(f.talks.talk(1)?.volume == 40)
        await f.receiver.close()
    }

    @Test func aDecoderThatCannotDecodeIsGivenUpOn() async throws {
        let f = try await fixture(idle: .seconds(60))
        #expect(await f.receiver.start())
        try await sendUDP(Self.packet, to: f.port)
        #expect(await eventually { f.decoders.count == 1 })
        f.decoders.last?.end()
        try await Task.sleep(for: .milliseconds(20))
        try await sendUDP(Self.packet, to: f.port)
        #expect(await eventually { f.decoders.count == 2 })
        f.decoders.last?.end()
        #expect(await eventually { f.logs.messages(.error).contains { $0.contains("cannot decode") && $0.contains("libfdk_aac") } })
        try await sendUDP(Self.packet, to: f.port)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.decoders.count == 2)
        await f.receiver.close()
    }

    @Test func aPortInUseLeavesTwoWayAudioOff() async throws {
        let f = try await fixture()
        let other = try await UDPReceiver(host: "0.0.0.0", port: f.port)
        #expect(await !f.receiver.start())
        #expect(f.logs.messages(.warning).contains { $0.contains("two-way audio unavailable") })
        await other.close()
        await f.receiver.close()
    }
}

/// `eventually` for a condition that awaits.
@discardableResult
func eventuallyAsync(timeout: Duration = .seconds(30), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
