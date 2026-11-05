import Foundation
import HomeswiftFFmpeg
import Logging

// Two-way talk over Baichuan (docs/clean-room/ReolinkTalk.md), Experimental: the talk ability (`cmd_id` 10), the talk's
// start (201), its IMA ADPCM audio in BcMedia frames (202) and its stop (11), one Talk of HomeKit's return audio at a time
// per channel.

/// A channel's talk format, from its talk ability (2.4): the first duplex, audio stream mode and suitable audio config.
struct ReolinkTalkConfig: Codable, Sendable, Equatable {
    var duplex: String
    var audioStreamMode: String
    var sampleRate: Int
    var lengthPerEncoder: Int

    /// IMA ADPCM block sizes (4.1): 512 code bytes, 516 bytes and 1025 samples for `lengthPerEncoder` 1024.
    var blockBytes: Int { lengthPerEncoder / 2 + 4 }
    var samplesPerBlock: Int { lengthPerEncoder + 1 }

    var summary: String { "\(duplex), \(audioStreamMode), ADPCM at \(sampleRate) Hz, \(lengthPerEncoder) per encoder" }
}

/// What a talk ability reply says (2.3, 2.5).
enum ReolinkTalkAbility: Sendable, Equatable {
    case supported(ReolinkTalkConfig)
    /// Not supported, and why (with the values, for the log).
    case unsupported(String)

    var config: ReolinkTalkConfig? {
        if case .supported(let config) = self { return config }
        return nil
    }

    /// Reads a `TalkAbility` reply: supported for `mixAudioStream`, or `followVideoStream` with a first duplex `FDX`, and
    /// an audio config of mono 16-bit ADPCM at 8 or 16 kHz with an even `lengthPerEncoder` from 64 to 4096.
    static func parse(_ xml: String) -> ReolinkTalkAbility {
        guard !xml.isEmpty, let root = try? BXParser.parse(xml), let ability = root.first("TalkAbility") else {
            return .unsupported("no TalkAbility in the reply")
        }
        func texts(_ name: String) -> [String] { ability.all(name).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } }
        let duplexes = texts("duplex"), modes = texts("audioStreamMode")
        guard modes.contains("mixAudioStream") || (modes.contains("followVideoStream") && duplexes.first == "FDX") else {
            return .unsupported("duplex \(duplexes.joined(separator: "/").nonEmptyText ?? "none"), audio stream mode \(modes.joined(separator: "/").nonEmptyText ?? "none")")
        }
        let configs = ability.all("audioConfig")
        let suitable = configs.lazy.compactMap { config -> (Int, Int)? in
            guard config.value("audioType")?.lowercased() == "adpcm", config.value("soundTrack")?.lowercased() == "mono", config.value("samplePrecision") == "16",
                  let rate = config.value("sampleRate").flatMap(Int.init), [8000, 16000].contains(rate),
                  let length = config.value("lengthPerEncoder").flatMap(Int.init), length % 2 == 0, (64...4096).contains(length) else { return nil }
            return (rate, length)
        }.first
        guard let (rate, length) = suitable, let duplex = duplexes.first, let mode = modes.first else {
            let seen = configs.map { config in
                ["audioType", "sampleRate", "samplePrecision", "lengthPerEncoder", "soundTrack"].map { config.value($0) ?? "?" }.joined(separator: " ")
            }
            return .unsupported("no audio config of mono 16-bit ADPCM at 8 or 16 kHz (\(seen.joined(separator: ", ").nonEmptyText ?? "none listed"))")
        }
        return .supported(ReolinkTalkConfig(duplex: duplex, audioStreamMode: mode, sampleRate: rate, lengthPerEncoder: length))
    }

    /// Whether a channel's abilities say it may talk (2.1, `Reolink.md` A.2): HTTP `talk`, Baichuan `ipcAudioTalk` for the
    /// channel, or a camera's (not an NVR's or a hub's) own `audioTalk`.
    static func permitted(httpTalk: Int, baichuan: [Int: [String: Int]], channel: Int, multiChannel: Bool) -> Bool {
        httpTalk > 0 || (baichuan[channel]?["ipcAudioTalk"] ?? 0) > 0 || (!multiChannel && baichuan.values.contains { ($0["audioTalk"] ?? 0) > 0 })
    }
}

extension Baichuan {
    /// The TalkConfig body (3.1); `channel` 0-based.
    static func talkConfigBody(channel: Int, config: ReolinkTalkConfig) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <TalkConfig version="1.1">
        <channelId>\(channel)</channelId>
        <duplex>\(BXParser.escape(config.duplex))</duplex>
        <audioStreamMode>\(BXParser.escape(config.audioStreamMode))</audioStreamMode>
        <audioConfig>
        <audioType>adpcm</audioType>
        <sampleRate>\(config.sampleRate)</sampleRate>
        <samplePrecision>16</samplePrecision>
        <lengthPerEncoder>\(config.lengthPerEncoder)</lengthPerEncoder>
        <soundTrack>mono</soundTrack>
        </audioConfig>
        </TalkConfig>
        </body>

        """
    }

    /// The extension of a Talk's audio (3.2): binary data follows.
    static func talkExtension(channel: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" ?>
        <Extension version="1.1">
        <binaryData>1</binaryData>
        <channelId>\(channel)</channelId>
        </Extension>

        """
    }

    /// An IMA ADPCM block in its BcMedia frame (4.2): `01wb`, the payload size twice, `00 01`, the half block size, the
    /// block, zeros to a payload that is a multiple of 8.
    static func adpcmFrame(_ block: [UInt8]) -> [UInt8] {
        let payload = block.count + 4
        let padding = (8 - payload % 8) % 8
        let size = [UInt8(payload & 0xFF), UInt8(payload >> 8 & 0xFF)]
        let half = (block.count - 4) / 2
        let header: [UInt8] = [0x00, 0x01, UInt8(half & 0xFF), UInt8(half >> 8 & 0xFF)]
        var frame: [UInt8] = Array("01wb".utf8)
        frame += size
        frame += size
        frame += header
        frame += block
        frame += [UInt8](repeating: 0, count: padding)
        return frame
    }
}

extension BaichuanSession {
    /// The talk ability of a channel (`cmd_id` 10, 2.2); a status other than 200 is "not supported".
    func talkAbility(channel: Int) async throws -> ReolinkTalkAbility {
        let reply = try await request(command: 10, channel: UInt8(clamping: channel + 1), extension: Baichuan.channelExtension(channel), body: nil,
                                      encryption: .aes, anyStatus: true)
        if let status = reply.status, status != 200 { return .unsupported("the talk ability answered status \(status)") }
        return ReolinkTalkAbility.parse((try? replyText(reply)) ?? "")
    }
}

/// How a Talk reaches its device's Baichuan session.
struct ReolinkTalkLink: Sendable {
    /// Runs `body` on the session (a battery camera's is opened and kept open while it runs); throws without one.
    var withSession: @Sendable (_ body: @escaping @Sendable (BaichuanSession) async throws -> Void) async throws -> Void
    /// A 400 to the TalkConfig is a battery camera behind a hub waking: asked again 1.5 s later, up to 3 times (7).
    var retriesWaking = false
}

/// One channel's talk (5, 8): HomeKit's Talks in turn, each started with 201, sent as ADPCM blocks of 202 on one message
/// number, and stopped with 11 once its audio has played.
actor ReolinkTalker {
    static let configTimeout: Double = 5
    static let audioTimeout: Double = 2
    static let resetTimeout: Double = 2
    /// Blocks waiting for a slow camera beyond this many: the oldest dropped (5.4).
    static let queueLimit = 3
    /// After the audio sent has played, before the stop (5.6).
    static let tail: Double = 0.1
    static let wakingRetries = 3
    static let wakingDelay: Double = 1.5
    /// Frames in one 202 after a camera refused one per message (4.3), as the official client sends.
    static let groupedFrames = 4

    let channel: Int
    let config: ReolinkTalkConfig
    private let link: ReolinkTalkLink
    private let name: String
    private let log: Logger
    private let timing: ReolinkTiming
    /// The talk messages' `ch_id`: channel + 1 first, the bare channel once a camera refused that (10).
    private var chID: UInt8
    private var framesPerMessage = 1
    private var current: Task<Void, Never>?
    private(set) var isTalking = false
    /// The Talks begun so far, and the blocks taken from the queue (tests).
    private(set) var talks = 0
    private(set) var blocksTaken = 0

    init(channel: Int, config: ReolinkTalkConfig, link: ReolinkTalkLink, name: String, log: Logger, timing: ReolinkTiming) {
        self.channel = channel
        self.config = config
        self.link = link
        self.name = name
        self.log = log
        self.timing = timing
        chID = UInt8(clamping: channel + 1)
    }

    /// The PCM a Talk is asked in: the camera's sample rate, 20 ms frames.
    nonisolated var format: ReturnAudioFormat { ReturnAudioFormat(sampleRate: config.sampleRate) }

    /// The return audio's options for the streamer.
    nonisolated var returnAudioOptions: ReturnAudioOptions {
        ReturnAudioOptions(format: format) { talk in await self.handle(talk) }
    }

    /// Runs a Talk once the one before it has stopped (one at a time per channel).
    func handle(_ talk: Talk) async {
        let previous = current
        let task = Task { [weak self] in
            await previous?.value
            await self?.run(talk)
        }
        current = task
        await task.value
    }

    /// Waits until no Talk runs: true then, false after `timeout` (a siren waits for the Talk to end, 7).
    func waitUntilIdle(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isTalking {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func run(_ talk: Talk) async {
        isTalking = true
        talks += 1
        defer { isTalking = false }
        do {
            try await link.withSession { session in try await self.talk(talk, on: session) }
        } catch BaichuanError.closed {
            // The session dropped: the Talk ends without a stop, and the next start's 422 clears it (5.7).
            log.info("\(name): the Talk ended: the connection to the camera closed.")
        } catch {
            log.info("\(name): the Talk ended: \(error).")
        }
    }

    private func talk(_ talk: Talk, on session: BaichuanSession) async throws {
        guard try await start(on: session) else { return }
        let counter = await session.nextCounter()
        let config = config
        let (frames, input) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .bufferingNewest(Self.queueLimit))
        let producer = Task {
            var encoder = IMAADPCMEncoder()
            var pending: [Int16] = []
            for await frame in talk.frames {
                pending += PCMVolume.scale(frame.samples, volume: talk.volume)
                while pending.count >= config.samplesPerBlock {
                    input.yield(Baichuan.adpcmFrame(encoder.encodeBlock(pending[..<config.samplesPerBlock])))
                    pending.removeFirst(config.samplesPerBlock)
                }
            }
            if !pending.isEmpty, !Task.isCancelled {
                pending += [Int16](repeating: 0, count: config.samplesPerBlock - pending.count)
                input.yield(Baichuan.adpcmFrame(encoder.encodeBlock(pending)))
            }
            input.finish()
        }
        defer { producer.cancel() }
        let blockDuration = Double(config.samplesPerBlock) / Double(config.sampleRate)
        var expectedEnd = ContinuousClock.now
        var iterator = frames.makeAsyncIterator()
        while true {
            var batch: [UInt8] = []
            var count = 0
            while count < framesPerMessage, let frame = await iterator.next() {
                batch += frame
                count += 1
                blocksTaken += 1
            }
            guard count > 0 else { break }
            let status: UInt16
            do {
                let reply = try await session.request(command: 202, channel: chID, extension: Baichuan.talkExtension(channel: channel), body: nil, binary: batch,
                                                      encryption: .aes, timeout: Self.audioTimeout, fixedCounter: counter, anyStatus: true,
                                                      retryWaking: false)
                status = reply.status ?? 200
            } catch BaichuanError.timeout {
                log.info("\(name): the camera did not take the Talk's audio in time: the Talk ends.")
                await reset(on: session)
                return
            }
            guard status == 200 else {
                if framesPerMessage == 1 {
                    framesPerMessage = Self.groupedFrames
                    log.info("\(name): the camera refused the Talk's audio (status \(status)): the next Talks send \(Self.groupedFrames) frames per message.")
                } else {
                    log.info("\(name): the camera refused the Talk's audio (status \(status)): the Talk ends.")
                }
                await reset(on: session)
                return
            }
            expectedEnd = max(.now, expectedEnd) + .milliseconds(Int(Double(count) * blockDuration * 1000))
        }
        // The last words play before the stop (5.6).
        let wait = expectedEnd - .now
        try? await Task.sleep(for: (wait > .zero ? wait : .zero) * timing.scale + timing.seconds(Self.tail))
        await reset(on: session)
    }

    /// The TalkConfig (5.2): true once the camera took it. Its retries are these alone: the session does not retry a Talk's
    /// requests, which would stack its waits on these (a 400 at every layer, seconds of silence). A 422 (a Talk left open) is stopped and asked once more; a
    /// refusal is asked again with the bare channel in `ch_id` before giving up (10).
    private func start(on session: BaichuanSession) async throws -> Bool {
        var resetDone = false
        var waking = 0
        let original = chID
        var triedOther = false
        while true {
            var status: UInt16?
            do {
                let reply = try await session.request(command: 201, channel: chID, extension: Baichuan.channelExtension(channel),
                                                      body: Baichuan.talkConfigBody(channel: channel, config: config), encryption: .aes,
                                                      timeout: Self.configTimeout, anyStatus: true, retryWaking: false)
                status = reply.status ?? 200
            } catch BaichuanError.timeout {
                status = nil
            }
            switch status {
            case 200?:
                if chID != original { log.info("\(name): the camera takes talk messages with channel \(chID) in their header.") }
                return true
            case 422? where !resetDone:
                resetDone = true
                log.debug("\(name): a Talk is already open on the camera: stopping it first.")
                await reset(on: session)
            case 400? where link.retriesWaking && waking < Self.wakingRetries:
                waking += 1
                try await Task.sleep(for: timing.seconds(Self.wakingDelay))
            case let refused? where refused != 422 && !triedOther:
                triedOther = true
                chID = chID == UInt8(clamping: channel + 1) ? UInt8(clamping: channel) : UInt8(clamping: channel + 1)
                log.debug("\(name): the camera answered the TalkConfig with status \(refused): asking with channel \(chID) in the header.")
            default:
                chID = original
                log.warning("\(name): the camera refused the talk format (\(config.summary)): \(status.map { "status \($0)" } ?? "no answer in \(Int(Self.configTimeout)) s").")
                return false
            }
        }
    }

    /// TalkReset (`cmd_id` 11), waiting for its reply.
    private func reset(on session: BaichuanSession) async {
        _ = try? await session.request(command: 11, channel: chID, extension: Baichuan.channelExtension(channel), body: nil, encryption: .aes,
                                       timeout: Self.resetTimeout, anyStatus: true, retryWaking: false)
    }
}
