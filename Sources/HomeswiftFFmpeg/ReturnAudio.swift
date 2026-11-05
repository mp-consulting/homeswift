import Foundation
import Homeswift
import Logging
import NIOConcurrencyHelpers

// HomeKit's return audio for camera plugins (docs/clean-room/ReturnAudio.md): while someone talks in the Home app, HomeKit
// sends SRTP AAC-ELD to the stream's audio return port; FFmpeg decodes it to PCM, cut into frames, handed to the plugin one
// Talk at a time (a burst of speech, from the first packet to an idle gap). The plugin re-encodes them for its camera's
// speaker (AudioEncoders.swift).

/// The PCM a plugin wants: 8000 or 16000 Hz mono, in frames of 10 to 60 ms (a multiple of 10).
public struct ReturnAudioFormat: Sendable, Equatable {
    public var sampleRate: Int
    public var frameDuration: Duration

    public init(sampleRate: Int, frameDuration: Duration = .milliseconds(20)) {
        self.sampleRate = sampleRate == 8000 ? 8000 : 16000
        let milliseconds = Int((frameDuration / .milliseconds(1)).rounded())
        self.frameDuration = .milliseconds(min(max(milliseconds / 10 * 10, 10), 60))
    }

    public var samplesPerFrame: Int {
        sampleRate * Int((frameDuration / .milliseconds(1)).rounded()) / 1000
    }
}

/// One frame of a Talk: exactly `samplesPerFrame` mono samples (the last one of a Talk padded with zeros), `offset` the
/// samples since the Talk began.
public struct PCMFrame: Sendable, Equatable {
    public var samples: [Int16]
    public var offset: Int

    public init(samples: [Int16], offset: Int) {
        self.samples = samples
        self.offset = offset
    }
}

/// One continuous period during which HomeKit sends return audio; `frames` finishes when it ends. `volume` is the Speaker's
/// (0–100) when the Talk began.
public struct Talk: Sendable {
    public var sessionID: String
    public var format: ReturnAudioFormat
    public var frames: AsyncStream<PCMFrame>
    public var volume: Int

    public init(sessionID: String, format: ReturnAudioFormat, frames: AsyncStream<PCMFrame>, volume: Int) {
        self.sessionID = sessionID
        self.format = format
        self.frames = frames
        self.volume = volume
    }
}

/// Called once per Talk, on a task of its own: it opens the camera's talk channel, sends each frame, closes the channel when
/// `frames` ends. Returning early drops the Talk's remaining frames.
public typealias ReturnAudioHandler = @Sendable (Talk) async -> Void

/// A plugin's return audio: what it wants, how long a silence ends a Talk, the longest Talk, and its handler.
public struct ReturnAudioOptions: Sendable {
    public var format: ReturnAudioFormat
    public var idleTimeout: Duration
    public var maximumTalk: Duration
    public var handler: ReturnAudioHandler

    public init(format: ReturnAudioFormat, idleTimeout: Duration = .seconds(1), maximumTalk: Duration = .seconds(600), handler: @escaping ReturnAudioHandler) {
        self.format = format
        self.idleTimeout = idleTimeout
        self.maximumTalk = maximumTalk
        self.handler = handler
    }
}

/// FFmpeg's standard output, signed 16-bit little-endian mono in chunks of any size, cut into whole frames (section 3.4); the
/// remainder, an odd byte included, waits for the next chunk.
public struct PCMFramer: Sendable {
    public let samplesPerFrame: Int
    private var pending: [UInt8] = []

    public init(samplesPerFrame: Int) {
        self.samplesPerFrame = max(samplesPerFrame, 1)
    }

    /// The bytes held back.
    public var remainder: Int { pending.count }

    public mutating func push(_ bytes: some Sequence<UInt8>) -> [[Int16]] {
        pending.append(contentsOf: bytes)
        let frameBytes = samplesPerFrame * 2
        var frames: [[Int16]] = []
        var start = 0
        while pending.count - start >= frameBytes {
            frames.append(Self.samples(pending[start..<(start + frameBytes)]))
            start += frameBytes
        }
        pending.removeFirst(start)
        return frames
    }

    /// The partial frame, padded with zeros; nil when nothing is held. Forgets it.
    public mutating func flush() -> [Int16]? {
        defer { pending = [] }
        let samples = Self.samples(pending[...])
        guard !samples.isEmpty else { return nil }
        return samples + Array(repeating: 0, count: samplesPerFrame - samples.count)
    }

    public mutating func reset() { pending = [] }

    private static func samples(_ bytes: ArraySlice<UInt8>) -> [Int16] {
        var samples: [Int16] = []
        samples.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            samples.append(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))
            index += 2
        }
        return samples
    }
}

/// The SDP and command line FFmpeg decodes return audio with (sections 3.1 and 3.2).
public enum ReturnAudioArguments {
    /// The SDP on FFmpeg's standard input: HomeKit's AAC-ELD at 16 kHz, forwarded to `port` on the loopback; `srtp` is the
    /// controller's key and salt (30 bytes), a secret: never logged.
    public static func sdp(address: String, isIPv6: Bool, port: Int, payloadType: Int, srtp: Data) -> String {
        let version = isIPv6 ? "IP6" : "IP4"
        return [
            "v=0",
            "o=- 0 0 IN \(version) \(address)",
            "s=Talk",
            "c=IN \(version) \(address)",
            "t=0 0",
            "m=audio \(port) RTP/AVP \(payloadType)",
            "b=AS:24",
            "a=rtpmap:\(payloadType) MPEG4-GENERIC/16000/1",
            "a=rtcp-mux",
            "a=fmtp:\(payloadType) profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3; config=F8F0212C00BC00",
            "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:\(srtp.base64EncodedString())",
        ].joined(separator: "\r\n") + "\r\n"
    }

    /// `decoder`: `RTSPCameraFFmpeg.returnAudioDecoder()`'s; `sampleRate` the plugin's, FFmpeg resampling.
    public static func decode(decoder: [String], sampleRate: Int, debug: Bool) -> [String] {
        ["-hide_banner", "-loglevel", debug ? "level+verbose" : "error", "-protocol_whitelist", "pipe,udp,rtp,file,crypto", "-f", "sdp"]
            + decoder + ["-i", "pipe:0", "-vn", "-sn", "-dn", "-ac", "1", "-ar", "\(sampleRate)", "-acodec", "pcm_s16le", "-f", "s16le",
                         "-flush_packets", "1", "pipe:1"]
    }

    /// The decoder's name for the log: libfdk_aac, aac_at, or FFmpeg's own.
    static func decoderName(_ decoder: [String]) -> String { decoder.last ?? "FFmpeg's own AAC decoder" }
}

extension RTSPCameraFFmpeg {
    /// The decoder of HomeKit's AAC-ELD return audio: libfdk_aac when FFmpeg has it, then AudioToolbox's on macOS, then none
    /// (FFmpeg's own `aac` decodes ER AAC ELD).
    public func returnAudioDecoder() async -> [String] {
        guard let codecs = await codecs, !codecs.hasDecoder("aac", "libfdk_aac") else { return ["-c:a", "libfdk_aac"] }
        return codecs.hasDecoder("aac", "aac_at") ? ["-c:a", "aac_at"] : []
    }
}

/// The process that decodes return audio: FFmpeg, or a fake in tests. `start` writes the SDP to its standard input and
/// closes it; `output` gets standard output as it comes, `exit` once when it ends. False when it could not start.
public protocol ReturnAudioDecoding: Sendable {
    func start(sdp: Data, output: @escaping @Sendable (Data) -> Void, exit: @escaping @Sendable () -> Void) -> Bool
    func stop()
}

/// Makes a decoding process for a command line (`ReturnAudioArguments.decode`).
public typealias ReturnAudioDecoderFactory = @Sendable (_ ffmpeg: RTSPCameraFFmpeg, _ arguments: [String]) -> any ReturnAudioDecoding

/// FFmpeg as the decoder.
public final class FFmpegReturnAudioDecoder: ReturnAudioDecoding {
    private let process: FfmpegProcess

    public init(ffmpeg: RTSPCameraFFmpeg, arguments: [String]) {
        process = FfmpegProcess(ffmpeg.options, commandLineArgs: arguments)
    }

    public static let factory: ReturnAudioDecoderFactory = { FFmpegReturnAudioDecoder(ffmpeg: $0, arguments: $1) }

    public func start(sdp: Data, output: @escaping @Sendable (Data) -> Void, exit: @escaping @Sendable () -> Void) -> Bool {
        process.start()
        guard process.onStdout(output) != nil, process.onceExit({ _ in exit() }) else { return false }
        process.endStdin(sdp)
        return true
    }

    public func stop() { process.stop() }
}

/// One live stream's return audio (section 4): a demuxer on the audio return port forwarding RTP to FFmpeg on the loopback,
/// FFmpeg started on the first packet and kept until the stream stops, its PCM cut into frames for the Talk under way. Made
/// at stream start, closed at stream stop; `RTSPCameraStreamer` holds one per stream, and a plugin with a streamer of its
/// own makes one the same way.
public actor ReturnAudioReceiver {
    /// Where HomeKit's return audio comes from: the prepared stream.
    public struct Stream: Sendable {
        public var sessionID: String
        /// The audio return port answered in `PrepareStreamResponse`.
        public var returnPort: Int
        public var ipFamily: IPAddressVersion
        public var controllerAddress: String
        /// The controller's audio key and salt (30 bytes), with which HomeKit encrypts return audio.
        public var srtp: Data
        /// The RTP payload type, `StartStreamRequest.audio.pt`.
        public var payloadType: Int

        public init(sessionID: String, returnPort: Int, ipFamily: IPAddressVersion, controllerAddress: String, srtp: Data, payloadType: Int) {
            self.sessionID = sessionID
            self.returnPort = returnPort
            self.ipFamily = ipFamily
            self.controllerAddress = controllerAddress
            self.srtp = srtp
            self.payloadType = payloadType
        }
    }

    /// An FFmpeg that ends this soon after it started, twice in a row, cannot decode: the stream stops trying.
    static let quickExit: Duration = .seconds(2)
    /// A Talk's frames buffered for a slow camera: one second at 20 ms, the oldest dropped.
    static let frameBuffer = 50

    private let stream: Stream
    private let ports: RtpPortAllocator
    private let ffmpeg: RTSPCameraFFmpeg
    private let options: ReturnAudioOptions
    private let debug: Bool
    private let log: Logger
    private let name: String
    private let timeScale: Double
    private let makeDecoder: ReturnAudioDecoderFactory

    private var muted: Bool
    private var volume: Int
    private var demuxer: RtpDemuxer?
    private var rtpPort: Int?
    private var listener: (event: FfmpegEvent<Void>, id: FfmpegEvent<Void>.Listener)?
    private var packetsTask: Task<Void, Never>?
    private var closed = false

    private struct Decoder {
        var generation: Int
        var process: any ReturnAudioDecoding
        var startedAt: ContinuousClock.Instant
        var name: String
    }

    private var decoder: Decoder?
    private var decoderStarting = false
    private var generation = 0
    private var quickExits = 0
    private var gaveUp = false
    private var framer: PCMFramer

    private struct OpenTalk {
        var number: Int
        var continuation: AsyncStream<PCMFrame>.Continuation
        var offset = 0
        var startedAt: ContinuousClock.Instant
        var lastPacket: ContinuousClock.Instant
        var packets = 0
        var frames = 0
        var watcher: Task<Void, Never>?
    }

    private var talk: OpenTalk?
    private var talks = 0
    private var handlers: [Int: Task<Void, Never>] = [:]

    /// `muted` and `volume`: the Speaker's when the stream starts. `decoder` replaces FFmpeg in tests; `timeScale` shortens the
    /// idle timeout, the longest Talk and the quick-exit window.
    public init(stream: Stream, ports: RtpPortAllocator, ffmpeg: RTSPCameraFFmpeg, options: ReturnAudioOptions, name: String, log: Logger,
                debug: Bool = false, muted: Bool = false, volume: Int = 100, timeScale: Double = 1, decoder: ReturnAudioDecoderFactory? = nil) {
        self.stream = stream
        self.ports = ports
        self.ffmpeg = ffmpeg
        self.options = options
        self.name = name
        self.log = log
        self.debug = debug
        self.muted = muted
        self.volume = min(max(volume, 0), 100)
        self.timeScale = timeScale
        self.makeDecoder = decoder ?? FFmpegReturnAudioDecoder.factory
        framer = PCMFramer(samplesPerFrame: options.format.samplesPerFrame)
    }

    /// The Talks begun so far, for tests.
    public var talkCount: Int { talks }
    /// Whether a Talk is under way.
    public var isTalking: Bool { talk != nil }
    /// Whether the demuxer listens on the audio return port.
    public var isListening: Bool { demuxer?.isRunning ?? false }

    /// Binds the demuxer on the audio return port and reserves the loopback pair FFmpeg reads; FFmpeg waits for the first
    /// packet. False when either fails: the video stream goes on without two-way audio.
    @discardableResult
    public func start() async -> Bool {
        guard !closed, demuxer == nil else { return demuxer != nil }
        let port = await ports.reserve(ipFamily: stream.ipFamily, portCount: 2)
        guard port > 0 else {
            log.warning("\(name): two-way audio unavailable for this stream (no free UDP port).")
            return false
        }
        let demuxer = await RtpDemuxer(ipFamily: stream.ipFamily, inputPort: stream.returnPort, rtcpPort: port + 1, rtpPort: port, log: log)
        guard demuxer.isRunning, !closed else {
            demuxer.close()
            ports.cancel(port)
            ports.cancel(port + 1)
            if !closed { log.warning("\(name): two-way audio unavailable for this stream.") }
            return false
        }
        self.demuxer = demuxer
        rtpPort = port
        // Packets are counted in order on one task; the demuxer's event also fires when it closes, which ends nothing here.
        let (packets, arrived) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = demuxer.rtpEvents.on { arrived.yield() }
        listener = (demuxer.rtpEvents, id)
        packetsTask = Task { [weak self] in
            for await _ in packets {
                guard let self, demuxer.isRunning else { return }
                await self.packet()
            }
        }
        return true
    }

    /// HomeKit's Speaker changed: a mute ends the Talk under way at once; the volume is the next Talk's.
    public func speakerChanged(muted: Bool, volume: Int) {
        self.muted = muted
        self.volume = min(max(volume, 0), 100)
        if muted { endTalk(reason: "muted") }
    }

    /// The stream stopped: the Talk ends, the demuxer closes, FFmpeg stops, the loopback ports are released.
    public func close() async {
        guard !closed else { return }
        closed = true
        endTalk(reason: "stream stopped")
        packetsTask?.cancel()
        if let listener { listener.event.off(listener.id) }
        demuxer?.close()
        demuxer = nil
        decoder?.process.stop()
        decoder = nil
        if let rtpPort {
            ports.cancel(rtpPort)
            ports.cancel(rtpPort + 1)
        }
        rtpPort = nil
    }

    // MARK: Packets and Talks

    /// One RTP packet of return audio (section 4.2, steps 3 and 4).
    func packet() async {
        guard !closed, !muted else { return }
        if talk == nil { beginTalk() }
        talk?.lastPacket = .now
        talk?.packets += 1
        if decoder == nil, !decoderStarting, !gaveUp { await startDecoder() }
    }

    private func beginTalk() {
        talks += 1
        let number = talks
        let (frames, continuation) = AsyncStream.makeStream(of: PCMFrame.self, bufferingPolicy: .bufferingNewest(Self.frameBuffer))
        let now = ContinuousClock.now
        talk = OpenTalk(number: number, continuation: continuation, startedAt: now, lastPacket: now)
        framer.reset()
        talk?.watcher = watch(number)
        log.info("\(name): Talk started.")
        let talk = Talk(sessionID: stream.sessionID, format: options.format, frames: frames, volume: volume)
        let handler = options.handler
        handlers[number] = Task { [weak self] in
            await handler(talk)
            await self?.handlerEnded(number)
        }
    }

    private func handlerEnded(_ number: Int) { handlers[number] = nil }

    /// Ends Talk `number` after `idleTimeout` without a packet, or at `maximumTalk`.
    private func watch(_ number: Int) -> Task<Void, Never> {
        let idle = options.idleTimeout * timeScale, longest = options.maximumTalk * timeScale
        return Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let times = await self.talkTimes(number) else { return }
                let (last, started) = times
                let now = ContinuousClock.now
                if now - started >= longest {
                    await self.endTalk(number, reason: "longest Talk reached")
                    return
                }
                if now - last >= idle {
                    await self.endTalk(number, reason: "idle")
                    return
                }
                try? await Task.sleep(until: min(last + idle, started + longest), clock: .continuous)
            }
        }
    }

    private func talkTimes(_ number: Int) -> (ContinuousClock.Instant, ContinuousClock.Instant)? {
        guard let talk, talk.number == number else { return nil }
        return (talk.lastPacket, talk.startedAt)
    }

    private func endTalk(_ number: Int, reason: String) {
        guard talk?.number == number else { return }
        endTalk(reason: reason)
    }

    /// Flushes the partial frame, zero-padded, and finishes the Talk's frames (step 6).
    private func endTalk(reason: String) {
        guard var talk else { return }
        self.talk = nil
        if let samples = framer.flush() {
            talk.continuation.yield(PCMFrame(samples: samples, offset: talk.offset))
            talk.frames += 1
        }
        talk.continuation.finish()
        talk.watcher?.cancel()
        let seconds = (ContinuousClock.now - talk.startedAt) / .seconds(1)
        log.info("\(name): Talk ended (\(String(format: "%.1f", seconds)) s).")
        log.debug("\(name): Talk ended (\(reason)): \(talk.packets) packets, \(talk.frames) frames.")
    }

    // MARK: The decoder

    private func startDecoder() async {
        decoderStarting = true
        defer { decoderStarting = false }
        let decoderArguments = await ffmpeg.returnAudioDecoder()
        guard !closed, let rtpPort else { return }
        let sdp = ReturnAudioArguments.sdp(address: stream.controllerAddress, isIPv6: stream.ipFamily == .ipv6, port: rtpPort,
                                           payloadType: stream.payloadType, srtp: stream.srtp)
        let arguments = ReturnAudioArguments.decode(decoder: decoderArguments, sampleRate: options.format.sampleRate, debug: debug)
        generation += 1
        let generation = generation
        let process = makeDecoder(ffmpeg, arguments)
        // Standard output in order, on one task; the exit once it is all read.
        let (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
        decoder = Decoder(generation: generation, process: process, startedAt: .now, name: ReturnAudioArguments.decoderName(decoderArguments))
        framer.reset()
        Task { [weak self] in
            for await chunk in chunks { await self?.output(chunk, generation: generation) }
            await self?.decoderExited(generation)
        }
        log.debug("\(name): starting the return audio decoder.")
        if !process.start(sdp: Data(sdp.utf8), output: { continuation.yield($0) }, exit: { continuation.finish() }) {
            continuation.finish()
        }
    }

    /// PCM from FFmpeg: whole frames to the Talk under way; none open, they are dropped (step 5).
    private func output(_ chunk: Data, generation: Int) {
        guard decoder?.generation == generation else { return }
        let frames = framer.push(chunk)
        guard var talk else {
            framer.reset()
            return
        }
        for samples in frames {
            talk.continuation.yield(PCMFrame(samples: samples, offset: talk.offset))
            talk.offset += samples.count
            talk.frames += 1
        }
        self.talk = talk
    }

    /// FFmpeg ended: the next packet starts another, unless it could not decode twice in a row (step 9).
    private func decoderExited(_ generation: Int) {
        guard let decoder, decoder.generation == generation else { return }
        self.decoder = nil
        guard !closed else { return }
        if ContinuousClock.now - decoder.startedAt < Self.quickExit * timeScale {
            quickExits += 1
        } else {
            quickExits = 0
        }
        if quickExits >= 2 {
            gaveUp = true
            log.error("\(name): FFmpeg cannot decode HomeKit's return audio with \(decoder.name): two-way audio is off for this stream.")
            endTalk(reason: "decoder failed")
        } else {
            log.debug("\(name): the return audio decoder ended.")
        }
    }
}
