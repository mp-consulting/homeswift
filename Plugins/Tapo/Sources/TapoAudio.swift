import Foundation
import Logging
import NIOConcurrencyHelpers

/// The camera's audio out of its MPEG-TS (docs/clean-room/TapoCamera.md, 7 and 11): a G.711 stream TP-Link declares with
/// private stream types (0x90 A-law, 0x91 μ-law), which FFmpeg's MPEG-TS demuxer guesses wrong. So it is taken out here,
/// every PES payload in order, decoded and brought to 16 kHz (`TapoAudioConverter`), and given to FFmpeg as raw PCM on an
/// input of its own.
struct MPEGTSAudioExtractor {
    enum Law: Sendable, Equatable {
        case aLaw, muLaw
    }

    /// One PES of audio: its PTS on the 90 kHz clock when it has one, and its G.711 bytes (a sample each).
    struct Chunk: Equatable {
        var pts: UInt64?
        var samples: [UInt8]
    }

    static let streamTypes: [UInt8: Law] = [0x90: .aLaw, 0x91: .muLaw]

    private var carry = Data()
    private var pmtPIDs: Set<UInt16> = []
    private(set) var stream: (pid: UInt16, law: Law)?
    /// The PMT that declared `stream`: the audio follows it when it changes (the feed reconnected, say).
    private var streamPMT: UInt16?
    /// The PES being gathered: its header and payload bytes so far, and its declared length (0: unbounded).
    private var pes: [UInt8] = []
    private var pesLength = 0

    /// The audio's G.711 law, once a PMT has declared it.
    var law: Law? { stream?.law }

    /// The audio chunks complete in `data`, which may split packets anywhere.
    /// Only the PAT's, the PMTs' and the audio's packets are copied: the video, most of the feed, is skipped by its PID.
    mutating func extract(_ data: Data) -> [Chunk] {
        var chunks: [Chunk] = []
        let size = MPEGTSLensFilter.packetSize
        // What the last call left of a packet, completed from the front of `data`; the rest is read in place.
        var input = data[...]
        if !carry.isEmpty {
            let needed = size - carry.count
            guard input.count >= needed else {
                carry.append(input)
                return chunks
            }
            carry.append(input.prefix(needed))
            input = input.dropFirst(needed)
            if carry.first == 0x47 { handle(carry, into: &chunks) } else { input = carry.dropFirst() + input }
            carry = Data()
        }
        var index = input.startIndex
        while input.endIndex - index >= size {
            guard input[index] == 0x47 else {
                index = input[(index + 1)...].firstIndex(of: 0x47) ?? input.endIndex
                continue
            }
            handle(input[index..<(index + size)], into: &chunks)
            index += size
        }
        carry = Data(input[index...])
        return chunks
    }

    /// Whether a packet with this PID may matter: the PAT, a PMT, or the audio.
    private func wanted(_ pid: UInt16) -> Bool {
        pid == 0 || pmtPIDs.contains(pid) || pid == stream?.pid
    }

    private mutating func handle(_ packet: Data, into chunks: inout [Chunk]) {
        let start = packet.startIndex
        let pid = UInt16(packet[start + 1] & 0x1F) << 8 | UInt16(packet[start + 2])
        guard wanted(pid) else { return }
        handle([UInt8](packet), into: &chunks)
    }

    private mutating func handle(_ bytes: [UInt8], into chunks: inout [Chunk]) {
        let pid = UInt16(bytes[1] & 0x1F) << 8 | UInt16(bytes[2])
        let unitStart = bytes[1] & 0x40 != 0
        let adaptation = (bytes[3] >> 4) & 0x3
        var payload = 4
        if adaptation == 2 || adaptation == 3 { payload += 1 + Int(bytes[4]) }
        guard adaptation != 2, payload < bytes.count else { return }
        if pid == 0 {
            if unitStart, let section = MPEGTSLensFilter.section(bytes, from: payload) { readPAT(section) }
            return
        }
        if pmtPIDs.contains(pid) {
            if unitStart, let section = MPEGTSLensFilter.section(bytes, from: payload) { readPMT(section, pid: pid) }
            return
        }
        guard let stream, pid == stream.pid else { return }
        if unitStart {
            if let chunk = finishPES() { chunks.append(chunk) }
            pes = Array(bytes[payload...])
            pesLength = pes.count >= 6 ? Int(pes[4]) << 8 | Int(pes[5]) : 0
        } else if !pes.isEmpty {
            pes += bytes[payload...]
        }
        // A PES of declared length is complete without waiting for the next one: less delay.
        if pesLength > 0, pes.count >= 6 + pesLength, let chunk = finishPES() { chunks.append(chunk) }
    }

    private mutating func readPAT(_ section: [UInt8]) {
        guard section[0] == 0x00 else { return }
        var offset = 8
        var found: Set<UInt16> = []
        while offset + 4 <= section.count - 4 {
            let number = UInt16(section[offset]) << 8 | UInt16(section[offset + 1])
            let pmt = UInt16(section[offset + 2] & 0x1F) << 8 | UInt16(section[offset + 3])
            if number != 0 { found.insert(pmt) }
            offset += 4
        }
        pmtPIDs = found
        if let streamPMT, !found.contains(streamPMT) { setStream(nil, pmt: nil) }
    }

    private mutating func setStream(_ new: (pid: UInt16, law: Law)?, pmt: UInt16?) {
        guard new?.pid != stream?.pid || new?.law != stream?.law else { return }
        stream = new
        streamPMT = pmt
        pes = []
        pesLength = 0
    }

    /// Every PMT, every time: a cheap read of a few bytes, and the tables may change while the feed runs.
    private mutating func readPMT(_ section: [UInt8], pid pmt: UInt16) {
        guard section[0] == 0x02, section.count >= 16 else { return }
        let infoLength = Int(section[10] & 0x0F) << 8 | Int(section[11])
        var offset = 12 + infoLength
        while offset + 5 <= section.count - 4 {
            let type = section[offset]
            let pid = UInt16(section[offset + 1] & 0x1F) << 8 | UInt16(section[offset + 2])
            let esInfo = Int(section[offset + 3] & 0x0F) << 8 | Int(section[offset + 4])
            if let law = Self.streamTypes[type] {
                setStream((pid, law), pmt: pmt)
                return
            }
            offset += 5 + esInfo
        }
        // The program that had the audio has none now.
        if streamPMT == pmt { setStream(nil, pmt: nil) }
    }

    /// The PES gathered so far as a chunk, and a fresh start.
    private mutating func finishPES() -> Chunk? {
        defer {
            pes = []
            pesLength = 0
        }
        guard pes.count >= 9, pes[0] == 0, pes[1] == 0, pes[2] == 1 else { return nil }
        let headerEnd = 9 + Int(pes[8])
        guard headerEnd <= pes.count else { return nil }
        var pts: UInt64?
        if pes[7] & 0x80 != 0, pes.count >= 14 {
            pts = UInt64(pes[9] & 0x0E) << 29 | UInt64(pes[10]) << 22 | UInt64(pes[11] & 0xFE) << 14 | UInt64(pes[12]) << 7 | UInt64(pes[13] >> 1)
        }
        let end = pesLength > 0 ? min(pes.count, 6 + pesLength) : pes.count
        guard end > headerEnd else { return nil }
        return Chunk(pts: pts, samples: Array(pes[headerEnd..<end]))
    }
}

/// G.711 to 16-bit PCM at 16 kHz, little endian, mono: what FFmpeg reads as `-f s16le -ar 16000 -ac 1`. The camera's rate
/// is measured, not assumed (8 kHz on most Tapo models, 16 kHz on some newer firmware): the first chunks' bytes per second
/// of PTS. 8 kHz is doubled by linear interpolation.
struct TapoAudioConverter {
    static let outputRate = 16_000

    let law: MPEGTSAudioExtractor.Law
    /// The camera's rate, once measured.
    private(set) var inputRate: Int?
    /// Chunks held while the rate is measured.
    private var held: [MPEGTSAudioExtractor.Chunk] = []
    private var previous: Int16?

    init(law: MPEGTSAudioExtractor.Law) { self.law = law }

    /// The PCM for `chunk`; empty while the rate is still being measured.
    mutating func convert(_ chunk: MPEGTSAudioExtractor.Chunk) -> Data {
        if inputRate == nil {
            held.append(chunk)
            guard let rate = Self.measure(held) else { return Data() }
            inputRate = rate
            let pending = held
            held = []
            return pending.reduce(into: Data()) { $0.append(pcm($1.samples)) }
        }
        return pcm(chunk.samples)
    }

    /// 8000 or 16000 from the first chunks with a PTS (the bytes before a later PTS over the time between them); 8000
    /// when they carry none, once a few have come.
    static func measure(_ chunks: [MPEGTSAudioExtractor.Chunk]) -> Int? {
        guard let first = chunks.firstIndex(where: { $0.pts != nil }) else { return chunks.count >= 4 ? 8000 : nil }
        guard let last = chunks.lastIndex(where: { $0.pts != nil }), last > first,
              let start = chunks[first].pts, let end = chunks[last].pts, end > start else { return chunks.count >= 8 ? 8000 : nil }
        let samples = chunks[first..<last].reduce(0) { $0 + $1.samples.count }
        let rate = Double(samples) * 90_000 / Double(end - start)
        return rate > 12_000 ? 16_000 : 8000
    }

    private mutating func pcm(_ samples: [UInt8]) -> Data {
        let doubled = inputRate == 8000
        var out = [UInt8]()
        out.reserveCapacity(samples.count * (doubled ? 4 : 2))
        func append(_ value: Int16) {
            out.append(UInt8(truncatingIfNeeded: value))
            out.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        for byte in samples {
            let value = law == .muLaw ? Self.muLaw(byte) : Self.aLaw(byte)
            if doubled { append(Int16((Int(previous ?? value) + Int(value)) / 2)) }
            append(value)
            previous = value
        }
        return Data(out)
    }

    /// ITU-T G.711 μ-law to linear.
    static func muLaw(_ byte: UInt8) -> Int16 {
        let u = ~byte
        let magnitude = ((Int(u & 0x0F) << 3) + 0x84) << Int((u & 0x70) >> 4)
        return Int16(u & 0x80 != 0 ? 0x84 - magnitude : magnitude - 0x84)
    }

    /// ITU-T G.711 A-law to linear.
    static func aLaw(_ byte: UInt8) -> Int16 {
        let a = byte ^ 0x55
        var magnitude = Int(a & 0x0F) << 4
        let segment = Int((a & 0x70) >> 4)
        switch segment {
        case 0: magnitude += 8
        case 1: magnitude += 0x108
        default: magnitude = (magnitude + 0x108) << (segment - 1)
        }
        return Int16(a & 0x80 != 0 ? magnitude : -magnitude)
    }
}

/// The camera's audio as FFmpeg should get it: even, in real time, as little behind the camera as its bursts allow. The
/// camera's parts come in bursts (a good session: 0.26 s late at worst; a bad one: 0.7 s), and audio sent as it arrives
/// plays crackling. So it is released on the wall clock, `frame` at a time, behind the camera by a delay that adapts:
/// the worst lateness of the last `window` (how late a chunk arrives against its place on the camera's timeline,
/// measured from the earliest), plus `margin`, within `minimum` and `maximum`. The delay starts at `initial`, grows by
/// playing a frame of silence and shrinks by skipping one, both only on a quiet frame (`quiet`, RMS), where neither is
/// heard; more than `catchUp` too far behind, it skips frames whatever they hold. A frame the camera has not sent in
/// time, or never sends (its microphone off), is silence.
struct TapoAudioJitterBuffer {
    static let bytesPerSecond = TapoAudioConverter.outputRate * 2
    static let frame: Duration = .milliseconds(20)
    static let frameBytes = bytes(frame)

    var initial: Duration = .milliseconds(300)
    var minimum: Duration = .milliseconds(120)
    var maximum: Duration = .milliseconds(1200)
    var margin: Duration = .milliseconds(60)
    var window: Duration = .seconds(15)
    var catchUp: Duration = .milliseconds(300)
    var quiet: Double = 400

    private var pending = Data()
    private var start: ContinuousClock.Instant?
    /// Frames given out, and the camera's bytes appended and played (or skipped).
    private var framesOut = 0
    private var appended = 0
    private var consumed = 0
    /// Each real chunk's lateness against the camera's timeline (seconds), with when it came, for the last `window`.
    private var lateness: [(at: ContinuousClock.Instant, late: Double)] = []
    /// Silence played since the camera's last frame ran out, in bytes.
    private var silenceRun = 0
    /// For the log: silence played, and the camera's audio skipped, in bytes.
    private(set) var silence = 0
    private(set) var dropped = 0

    init() {}

    var isStarted: Bool { start != nil }

    /// The clock starts, with the video.
    mutating func begin(at now: ContinuousClock.Instant) {
        if start == nil { start = now }
    }

    /// Camera audio that came at `now`, to release in order.
    mutating func append(_ pcm: Data, at now: ContinuousClock.Instant) {
        guard let start, !pcm.isEmpty else { return }
        // Audio after a silence longer than any lateness (its microphone was off, its audio paused): the camera's
        // timeline skipped, so does the buffer's, and what came before says nothing of its bursts now.
        if silenceRun >= Self.bytes(maximum), pending.count < Self.frameBytes {
            consumed += silenceRun
            appended = consumed + pending.count
            lateness.removeAll()
        }
        silenceRun = 0
        lateness.append((now, Self.seconds(now - start) - Double(appended) / Double(Self.bytesPerSecond)))
        lateness.removeAll { now - $0.at > window }
        appended += pcm.count
        pending.append(pcm)
    }

    /// How far behind the camera's timeline playback should be now: where the earliest chunk would play, plus the
    /// delay its bursts call for.
    func targetDelay() -> Double {
        guard let earliest = lateness.map(\.late).min(), let latest = lateness.map(\.late).max() else { return Self.seconds(initial) }
        let wanted = min(max(latest - earliest + Self.seconds(margin), Self.seconds(minimum)), Self.seconds(maximum))
        return earliest + wanted
    }

    /// How far behind the camera's timeline playback is at `now`.
    func currentDelay(at now: ContinuousClock.Instant) -> Double {
        guard let start else { return 0 }
        return Self.seconds(now - start) - Double(consumed) / Double(Self.bytesPerSecond)
    }

    /// The frames due at `now`.
    mutating func take(at now: ContinuousClock.Instant) -> Data {
        guard let start else { return Data() }
        let due = Int((Self.seconds(now - start) - Self.seconds(initial)) / Self.seconds(Self.frame))
        var out = Data()
        while framesOut < due {
            framesOut += 1
            out.append(nextFrame(at: now))
        }
        return out
    }

    private mutating func nextFrame(at now: ContinuousClock.Instant) -> Data {
        let target = targetDelay()
        let frameSeconds = Self.seconds(Self.frame)
        // Far behind (a burst came after its silence, or audio after none): skip to the target, whatever it holds.
        while currentDelay(at: now) > target + Self.seconds(catchUp), pending.count >= 2 * Self.frameBytes {
            skipFrame()
        }
        guard pending.count >= Self.frameBytes else {
            silence += Self.frameBytes
            silenceRun += Self.frameBytes
            return Data(count: Self.frameBytes)
        }
        let delay = currentDelay(at: now)
        if delay < target - frameSeconds, isQuiet(pending.prefix(Self.frameBytes)) {
            // Too close to the camera for its bursts: a frame of silence, where a quiet one was.
            silence += Self.frameBytes
            return Data(count: Self.frameBytes)
        }
        if delay > target + 2 * frameSeconds, pending.count >= 2 * Self.frameBytes, isQuiet(pending.prefix(Self.frameBytes)) {
            // Further behind than needed: a quiet frame skipped.
            skipFrame()
        }
        let frame = Data(pending.prefix(Self.frameBytes))
        pending.removeFirst(Self.frameBytes)
        consumed += Self.frameBytes
        return frame
    }

    private mutating func skipFrame() {
        pending.removeFirst(Self.frameBytes)
        consumed += Self.frameBytes
        dropped += Self.frameBytes
    }

    private func isQuiet(_ frame: Data) -> Bool {
        var sum = 0.0
        var count = 0
        var index = frame.startIndex
        while index + 1 < frame.endIndex {
            let sample = Double(Int16(bitPattern: UInt16(frame[index]) | UInt16(frame[index + 1]) << 8))
            sum += sample * sample
            count += 1
            index += 2
        }
        return count > 0 && (sum / Double(count)).squareRoot() < quiet
    }

    static func bytes(_ duration: Duration) -> Int {
        Int(seconds(duration) * Double(bytesPerSecond)) & ~1
    }

    static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// A viewer's share of the camera's feed (a HomeKit stream, a web UI live view): `split` takes each part as it comes
/// and gives back the lens's video for FFmpeg's standard input (`MPEGTSLensFilter`); with audio, it also takes the
/// camera's G.711 out (`MPEGTSAudioExtractor`, `TapoAudioConverter`), from the video's first keyframe on so both start
/// together, into a `TapoAudioJitterBuffer` that `runAudio` releases in real time, 20 ms at a time. When the audio's
/// writer fails, audio stops being kept: nothing waits for a reader that is gone.
final class TapoFeedSplitter: Sendable {
    private struct State {
        var filter: MPEGTSLensFilter
        var extractor = MPEGTSAudioExtractor()
        var converter: TapoAudioConverter?
        var buffer = TapoAudioJitterBuffer()
        /// Audio is kept until its writer fails (or none was wanted).
        var keepsAudio: Bool
    }

    private let state: NIOLockedValueBox<State>
    private let name: String
    private let log: Logger

    /// `buffer` is the jitter buffer's settings (tests give a shorter delay).
    init(videoIndex: Int, audio: Bool, buffer: TapoAudioJitterBuffer = TapoAudioJitterBuffer(), name: String, log: Logger) {
        state = NIOLockedValueBox(State(filter: MPEGTSLensFilter(videoIndex: videoIndex), buffer: buffer, keepsAudio: audio))
        self.name = name
        self.log = log
    }

    /// The lens's video in `data` (a part of the feed, split anywhere), taking its audio aside.
    func split(_ data: Data) -> Data {
        let (video, found) = state.withLockedValue { state -> (Data, MPEGTSAudioExtractor.Law?) in
            let video = state.filter.filter(data)
            guard state.keepsAudio else { return (video, nil) }
            let chunks = state.extractor.extract(data)
            guard state.filter.hasStarted else { return (video, nil) }
            let now = ContinuousClock.now
            state.buffer.begin(at: now)
            guard let law = state.extractor.law else { return (video, nil) }
            var announce: MPEGTSAudioExtractor.Law?
            if state.converter?.law != law {
                state.converter = TapoAudioConverter(law: law)
                announce = law
            }
            var pcm = Data()
            for chunk in chunks { pcm.append(state.converter!.convert(chunk)) }
            state.buffer.append(pcm, at: now)
            return (video, announce)
        }
        if let found { log.debug("\(name): the camera's audio is G.711 \(found == .muLaw ? "μ-law" : "A-law").") }
        return video
    }

    /// Releases the audio to `write` until it returns false or the task is cancelled, then keeps no more; a debug line
    /// every 10 s says how far behind the camera it plays.
    func runAudio(_ write: @escaping @Sendable (Data) async -> Bool) -> Task<Void, Never> {
        Task { [state, name, log] in
            defer { state.withLockedValue { $0.keepsAudio = false } }
            var reported = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: TapoAudioJitterBuffer.frame)
                let now = ContinuousClock.now
                let (pcm, delay, silence, dropped) = state.withLockedValue { state in
                    (state.buffer.take(at: now), state.buffer.currentDelay(at: now), state.buffer.silence, state.buffer.dropped)
                }
                if now - reported >= .seconds(10) {
                    reported = now
                    let second = Double(TapoAudioJitterBuffer.bytesPerSecond)
                    log.debug("\(name): audio \(Int(delay * 1000)) ms behind the camera; \(String(format: "%.1f", Double(silence) / second)) s of silence, \(String(format: "%.1f", Double(dropped) / second)) s skipped so far.")
                }
                guard !pcm.isEmpty else { continue }
                guard await write(pcm) else { return }
            }
        }
    }

    /// Whether audio is still kept (for tests).
    var keepsAudio: Bool { state.withLockedValue { $0.keepsAudio } }
}
