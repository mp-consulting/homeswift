import Foundation
@testable import Homeswift
import HomeswiftFFmpeg
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftTapo

/// The camera's G.711 out of its MPEG-TS, as 16 kHz PCM for FFmpeg (docs/clean-room/TapoCamera.md, 7 and 11).
struct TapoAudioTests {
    typealias TS = MPEGTSLensFilterTests

    /// An audio PES of `samples` with a PTS, in as many packets as it takes, its length declared when `declared`.
    static func audioPES(_ samples: [UInt8], pts: UInt64, declared: Bool = true) -> Data {
        let ptsBytes: [UInt8] = [0x21 | UInt8((pts >> 29) & 0x0E), UInt8((pts >> 22) & 0xFF), UInt8((pts >> 14) & 0xFE) | 1,
                                 UInt8((pts >> 7) & 0xFF), UInt8((pts << 1) & 0xFE) | 1]
        let length = declared ? 3 + 5 + samples.count : 0
        var pes: [UInt8] = [0x00, 0x00, 0x01, 0xC0, UInt8(length >> 8), UInt8(length & 0xFF), 0x80, 0x80, 0x05] + ptsBytes + samples
        var out = Data()
        var first = true
        while !pes.isEmpty {
            let room = 184
            var header: [UInt8] = [0x47, (first ? 0x40 : 0x00) | UInt8(TS.audio >> 8), UInt8(TS.audio & 0xFF), 0x10]
            var body = Array(pes.prefix(room))
            pes.removeFirst(body.count)
            if body.count < room {
                // Stuffing in an adaptation field, so the payload ends where the PES does.
                let stuffing = room - body.count
                header[3] = 0x30
                body = (stuffing == 1 ? [0x00] : [UInt8(stuffing - 1), 0x00] + [UInt8](repeating: 0xFF, count: stuffing - 2)) + body
            }
            out += Data(header + body)
            first = false
        }
        return out
    }

    @Test func extractsTheAudioPESInOrder() {
        let one = [UInt8](repeating: 0x11, count: 320), two = [UInt8](repeating: 0x22, count: 320)
        let input = TS.tables + TS.pes(TS.wide, keyframe: true, mark: 1) + Self.audioPES(one, pts: 90_000)
            + TS.pes(TS.tele, keyframe: true, mark: 2) + Self.audioPES(two, pts: 93_600)
        var extractor = MPEGTSAudioExtractor()
        var chunks: [MPEGTSAudioExtractor.Chunk] = []
        var index = 0
        for size in [50, 188, 7, 400, 1000, 10_000] where index < input.count {
            let end = min(input.count, index + size)
            chunks += extractor.extract(input[index..<end])
            index = end
        }
        #expect(extractor.law == .muLaw)
        #expect(chunks == [.init(pts: 90_000, samples: one), .init(pts: 93_600, samples: two)])
    }

    @Test func aPESWithoutALengthEndsAtTheNextOne() {
        var extractor = MPEGTSAudioExtractor()
        let one = [UInt8](repeating: 0x33, count: 100)
        #expect(extractor.extract(TS.tables + Self.audioPES(one, pts: 9000, declared: false)).isEmpty)
        let chunks = extractor.extract(Self.audioPES([0x44], pts: 9900, declared: false))
        #expect(chunks == [.init(pts: 9000, samples: one)])
    }

    @Test func aLawIsTold() {
        let tables = TS.pat + TS.pmt(pid: 0x1000, program: 1, type: 0x24, stream: TS.wide) + TS.pmt(pid: 0x1001, program: 2, type: 0x90, stream: TS.audio)
            + TS.pmt(pid: 0x1002, program: 3, type: 0x24, stream: TS.tele)
        var extractor = MPEGTSAudioExtractor()
        _ = extractor.extract(tables)
        #expect(extractor.law == .aLaw)
    }

    @Test func noAudioWithoutAG711Stream() {
        let tables = TS.pat + TS.pmt(pid: 0x1000, program: 1, type: 0x24, stream: TS.wide) + TS.pmt(pid: 0x1001, program: 2, type: 0x0F, stream: TS.audio)
            + TS.pmt(pid: 0x1002, program: 3, type: 0x24, stream: TS.tele)
        var extractor = MPEGTSAudioExtractor()
        #expect(extractor.extract(tables + Self.audioPES([1, 2, 3], pts: 0)).isEmpty)
        #expect(extractor.law == nil)
    }

    /// ITU-T G.711's reference values.
    @Test func decodesG711() {
        #expect(TapoAudioConverter.muLaw(0xFF) == 0)
        #expect(TapoAudioConverter.muLaw(0x7F) == 0)
        #expect(TapoAudioConverter.muLaw(0x80) == 32124)
        #expect(TapoAudioConverter.muLaw(0x00) == -32124)
        #expect(TapoAudioConverter.aLaw(0xD5) == 8)
        #expect(TapoAudioConverter.aLaw(0x55) == -8)
        #expect(TapoAudioConverter.aLaw(0xAA) == 32256)
        #expect(TapoAudioConverter.aLaw(0x2A) == -32256)
    }

    @Test func measuresTheRate() {
        typealias Chunk = MPEGTSAudioExtractor.Chunk
        // 320 bytes every 40 ms: 8 kHz; every 20 ms: 16 kHz.
        let eight = [Chunk(pts: 0, samples: .init(repeating: 0, count: 320)), Chunk(pts: 3600, samples: [])]
        let sixteen = [Chunk(pts: 0, samples: .init(repeating: 0, count: 320)), Chunk(pts: 1800, samples: [])]
        #expect(TapoAudioConverter.measure(eight) == 8000)
        #expect(TapoAudioConverter.measure(sixteen) == 16000)
        #expect(TapoAudioConverter.measure([Chunk(pts: 0, samples: [1])]) == nil)
        #expect(TapoAudioConverter.measure(.init(repeating: Chunk(pts: nil, samples: [1]), count: 4)) == 8000)
    }

    @Test func eightKilohertzIsDoubled() {
        var converter = TapoAudioConverter(law: .muLaw)
        let samples = [UInt8](repeating: 0x80, count: 320)
        // Held until the rate is known, then given out together.
        #expect(converter.convert(.init(pts: 0, samples: samples)).isEmpty)
        let pcm = converter.convert(.init(pts: 3600, samples: samples))
        #expect(converter.inputRate == 8000)
        #expect(pcm.count == 2 * 320 * 2 * 2)
        let first = Int16(bitPattern: UInt16(pcm[0]) | UInt16(pcm[1]) << 8)
        #expect(first == 32124)
    }

    @Test func sixteenKilohertzPassesAsItIs() {
        var converter = TapoAudioConverter(law: .aLaw)
        _ = converter.convert(.init(pts: 0, samples: .init(repeating: 0xD5, count: 320)))
        let pcm = converter.convert(.init(pts: 1800, samples: .init(repeating: 0xD5, count: 320)))
        #expect(converter.inputRate == 16000)
        #expect(pcm.count == 2 * 320 * 2)
        #expect(Array(pcm.prefix(2)) == [8, 0])
    }

    /// Feeds 68 ms chunks of `level` (as the C675D sends them), each arriving `late(index)` seconds after its time, and
    /// plays 20 ms ticks for `seconds`; returns the buffer.
    static func run(seconds: Double, level: Int16 = 0, late: (Int) -> Double) -> (buffer: TapoAudioJitterBuffer, out: Int) {
        var buffer = TapoAudioJitterBuffer()
        let start = ContinuousClock.now
        buffer.begin(at: start)
        let chunk = Data((0..<1088).flatMap { _ in [UInt8(truncatingIfNeeded: level), UInt8(truncatingIfNeeded: level >> 8)] })
        var arrivals = (0..<Int(seconds / 0.068)).map { (at: Double($0) * 0.068 + late($0), index: $0) }
        arrivals.sort { $0.at < $1.at }
        var next = 0
        var out = 0
        var tick = 0.0
        while tick < seconds {
            while next < arrivals.count, arrivals[next].at <= tick {
                buffer.append(chunk, at: start + .milliseconds(Int(arrivals[next].at * 1000)))
                next += 1
            }
            out += buffer.take(at: start + .milliseconds(Int(tick * 1000))).count
            tick += 0.02
        }
        return (buffer, out)
    }

    @Test func aSteadyCameraIsPlayedCloseBehind() {
        // Up to 100 ms late: the delay settles near 160 ms, below where it started.
        let (buffer, out) = Self.run(seconds: 30) { index in Double(index % 7) * 0.015 }
        #expect(buffer.targetDelay() < 0.2)
        #expect(out > 0)
    }

    @Test func burstsMakeTheDelayGrowInQuietFrames() {
        // Every 2 s, half a second late: the delay grows past it, and once grown nothing more is filled.
        let late: (Int) -> Double = { index in
            let time = Double(index) * 0.068
            let cycle = time.truncatingRemainder(dividingBy: 2)
            return cycle < 0.5 ? 0.5 - cycle : 0
        }
        let early = Self.run(seconds: 10, late: late).buffer
        let later = Self.run(seconds: 30, late: late).buffer
        #expect(early.targetDelay() > 0.5)
        #expect(later.silence - early.silence < TapoAudioJitterBuffer.frameBytes * 5)
    }

    @Test func loudAudioIsNeverCut() {
        // Loud all along: the delay may not shrink or grow by a frame, so nothing is skipped or inserted once going.
        let (buffer, _) = Self.run(seconds: 20, level: 8000) { index in Double(index % 3) * 0.02 }
        #expect(buffer.dropped == 0)
    }

    @Test func noMicrophoneIsSilence() {
        var buffer = TapoAudioJitterBuffer()
        let start = ContinuousClock.now
        buffer.begin(at: start)
        let out = buffer.take(at: start + .seconds(1))
        #expect(out.count == TapoAudioJitterBuffer.bytes(.milliseconds(700)))
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test func theSplitterGivesTheLensAndKeepsItsAudio() async {
        let splitter = TapoFeedSplitter(videoIndex: 1, audio: true, name: "Lens", log: testLogger)
        let samples = [UInt8](repeating: 0x80, count: 320)
        let video = splitter.split(TS.tables + TS.pes(TS.tele, keyframe: true, mark: 1) + Self.audioPES(samples, pts: 0) + Self.audioPES(samples, pts: 1800)
            + Self.audioPES(samples, pts: 3600))
        // The tele lens alone, from its keyframe; the audio is not in it.
        #expect(TS.pids(video) == [0, 0x1002, TS.tele])
        let written = NIOLockedValueBox(Data())
        let clock = splitter.runAudio { pcm in
            written.withLockedValue { $0.append(pcm) }
            return true
        }
        #expect(await eventually { written.withLockedValue { $0.contains(0x7D) } })
        clock.cancel()
    }

    /// A writer that fails (the audio's FFmpeg ended) stops the audio being kept: nothing piles up for nobody.
    @Test func noAudioIsKeptOnceItsWriterFails() async {
        let splitter = TapoFeedSplitter(videoIndex: 0, audio: true, name: "Lens", log: testLogger)
        _ = splitter.split(TS.tables + TS.pes(TS.wide, keyframe: true, mark: 1))
        let clock = splitter.runAudio { _ in false }
        #expect(await eventually { !splitter.keepsAudio })
        await clock.value
    }

    @Test func aSplitterWithoutAudioKeepsNone() {
        let splitter = TapoFeedSplitter(videoIndex: 0, audio: false, name: "Lens", log: testLogger)
        _ = splitter.split(TS.tables + TS.pes(TS.wide, keyframe: true, mark: 1) + Self.audioPES([1, 2], pts: 0))
        #expect(!splitter.keepsAudio)
    }

    @Test func theExtractorReadsPacketsSplitAcrossParts() {
        var extractor = MPEGTSAudioExtractor()
        let samples = [UInt8](repeating: 0x42, count: 500)
        let input = TS.tables + TS.pes(TS.wide, keyframe: true, mark: 1) + Self.audioPES(samples, pts: 0)
        var chunks: [MPEGTSAudioExtractor.Chunk] = []
        // One byte at a time: every packet is completed from the carry.
        for index in input.indices { chunks += extractor.extract(input[index...index]) }
        #expect(chunks == [.init(pts: 0, samples: samples)])
    }

    static let request = StartStreamRequest(
        sessionID: "s",
        video: VideoInfo(codec: 0, profile: 2, level: 2, packetizationMode: 0, cvoId: nil, width: 1280, height: 720, fps: 15, pt: 99, ssrc: 1,
                         maxBitRate: 800, rtcpInterval: 0.5, mtu: 1378),
        audio: AudioInfo(codec: .opus, channel: 1, bitRate: .variable, sampleRate: 16, packetTime: 20, pt: 110, ssrc: 2, maxBitRate: 24,
                         rtcpInterval: 5, comfortPT: 13, comfortNoiseEnabled: false))

    static func ffmpeg() -> FfmpegOptions {
        FfmpegOptions(FfmpegOptionsConfig(codecSupport: FfmpegCodecs(ffmpegExec: "ffmpeg", log: testLogger), hardwareDecoding: false, hardwareTranscoding: false, log: testLogger, name: { "Tapo" }))
    }

    @Test func theAudioHasAnFFmpegOfItsOwn() {
        let arguments = TapoCameraStreamer.audioArguments(
            request: Self.request, target: ("10.0.0.2", false, 50002, Data(repeating: 2, count: 30), 22), encoder: ["-codec:a", "libopus"], debug: false)
        let line = arguments.joined(separator: " ")
        #expect(line.hasPrefix("-hide_banner -nostats -f s16le -ar 16000 -ac 1 -i pipe:0 -map 0:a:0 -vn -sn -dn -codec:a libopus"))
        #expect(line.contains("-flags +global_header -ar 16k -b:a 24k -ac 1 -payload_type 110 -ssrc 22"))
        #expect(line.contains("-srtp_out_params \(Data(repeating: 2, count: 30).base64EncodedString()) srtp://10.0.0.2:50002?rtcpport=50002&pkt_size=188"))
    }

    @Test func theVideosFFmpegHasNoAudio() {
        let arguments = TapoCameraStreamer.arguments(
            videoIndex: 0, request: Self.request, target: ("10.0.0.2", false, 50000, Data(repeating: 1, count: 30), 11),
            ffmpeg: Self.ffmpeg(), inputFps: 15, debug: false)
        #expect(arguments.filter { $0 == "-i" }.count == 1)
        #expect(arguments.contains("-an"))
    }

    @Test func opusIsPreferred() async {
        let codecs = FfmpegCodecs(ffmpegExec: "ffmpeg", log: testLogger)
        _ = await codecs.probe()
        let ffmpeg = FfmpegOptions(FfmpegOptionsConfig(codecSupport: codecs, hardwareDecoding: false, hardwareTranscoding: false, log: testLogger, name: { "Tapo" }))
        if ffmpeg.hasOpusEncoder { #expect(TapoCameraStreamer.audioCodec(ffmpeg) == .opus) }
    }
}
