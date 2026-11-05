import Foundation

// The media frames a battery camera streams over Baichuan (docs/clean-room/ReolinkBattery.md, 5.2) and their remux into
// MPEG-TS for FFmpeg (5.3). Integers are little-endian in the frames, big-endian in MPEG-TS. Foundation only.

/// A video codec of the frames' headers.
enum BcMediaCodec: String, Sendable, Equatable {
    case h264, h265

    /// MPEG-TS's stream type (5.3).
    var streamType: UInt8 { self == .h264 ? 0x1B : 0x24 }
    /// FFmpeg's elementary-stream demuxer.
    var demuxer: String { self == .h264 ? "h264" : "hevc" }
}

/// One media frame (5.2).
enum BcMediaFrame: Sendable, Equatable {
    /// `1001`/`1002`: the stream's size and frame rate.
    case info(width: Int, height: Int, fps: Int)
    /// `d0dc` (I-frame) or `d1dc` (P-frame): an Annex B payload, its timestamp in microseconds (wrapping at 2³²).
    case video(codec: BcMediaCodec, keyframe: Bool, timestamp: UInt32, payload: [UInt8])
    /// `05wb`: an ADTS frame.
    case aac([UInt8])
    /// `01wb`: a DVI-4 IMA ADPCM block.
    case adpcm([UInt8])
}

enum BcMediaError: Error, Equatable, CustomStringConvertible {
    case frameTooLarge(Int)

    var description: String {
        switch self {
        case .frameTooLarge(let size): "a media frame of \(size) bytes, larger than accepted"
        }
    }
}

/// Splits the concatenated binary bodies of media messages into frames, with reolink-aio's tolerance (5.2): unknown bytes
/// are skipped to the next known magic, a duplicate of the previous video frame and audio before the first video frame
/// are dropped, and a frame above `maximumFrame` ends the stream.
struct BcMediaParser: Sendable {
    static let maximumFrame = 4 * 1024 * 1024
    /// The magics searched for when resynchronising.
    static let knownMagics: [[UInt8]] = ["1001", "1002", "00dc", "01dc", "05wb", "01wb"].map { Array($0.utf8) }

    private var buffer: [UInt8] = []
    private var lastVideo: [UInt8]?
    private var seenVideo = false

    /// Bytes waiting for the rest of their frame.
    var pendingCount: Int { buffer.count }

    static func padding(_ length: Int) -> Int { (8 - length % 8) % 8 }

    private enum Kind { case info, iframe, pframe, aac, adpcm }

    private static func kind(_ bytes: ArraySlice<UInt8>) -> Kind? {
        guard bytes.count >= 4 else { return nil }
        let a = bytes[bytes.startIndex], b = bytes[bytes.startIndex + 1], c = bytes[bytes.startIndex + 2], d = bytes[bytes.startIndex + 3]
        switch (a, b, c, d) {
        case (0x31, 0x30, 0x30, 0x31), (0x31, 0x30, 0x30, 0x32): return .info
        case (0x30...0x39, 0x30, 0x64, 0x63): return .iframe
        case (0x30...0x39, 0x31, 0x64, 0x63): return .pframe
        case (0x30, 0x35, 0x77, 0x62): return .aac
        case (0x30, 0x31, 0x77, 0x62): return .adpcm
        default: return nil
        }
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    /// The frames `chunk` completes.
    mutating func push(_ chunk: [UInt8]) throws -> [BcMediaFrame] {
        buffer += chunk
        var frames: [BcMediaFrame] = []
        var start = 0
        defer { buffer.removeFirst(min(start, buffer.count)) }
        while true {
            guard buffer.count - start >= 4 else { break }
            guard let kind = Self.kind(buffer[start...]) else {
                start = resynchronised(from: start + 1)
                continue
            }
            let available = buffer.count - start
            guard available >= 8 else { break }
            let total: Int
            var frame: BcMediaFrame?
            switch kind {
            case .info:
                total = 32
                guard available >= total else { return frames }
                let width = Int(Self.uint32(buffer, start + 8)), height = Int(Self.uint32(buffer, start + 12))
                frame = .info(width: width, height: height, fps: Int(buffer[start + 17]))
            case .iframe, .pframe:
                guard available >= 24 else { return frames }
                let size = Int(Self.uint32(buffer, start + 8)), extra = Int(Self.uint32(buffer, start + 12))
                guard size <= Self.maximumFrame, extra <= Self.maximumFrame else {
                    start = buffer.count
                    throw BcMediaError.frameTooLarge(max(size, extra))
                }
                total = 24 + extra + size + Self.padding(size)
                guard available >= total else { return frames }
                let codecBytes = Array(buffer[(start + 4)..<(start + 8)])
                let codec: BcMediaCodec = codecBytes == Array("H265".utf8) ? .h265 : .h264
                let payloadStart = start + 24 + extra
                let payload = Array(buffer[payloadStart..<(payloadStart + size)])
                frame = .video(codec: codec, keyframe: kind == .iframe, timestamp: Self.uint32(buffer, start + 16), payload: payload)
            case .aac, .adpcm:
                let size = Self.uint16(buffer, start + 4)
                total = 8 + size + Self.padding(size)
                guard available >= total else { return frames }
                if kind == .aac {
                    frame = .aac(Array(buffer[(start + 8)..<(start + 8 + size)]))
                } else {
                    // A sub-magic and a half block size come first: the block is the rest.
                    frame = size >= 4 ? .adpcm(Array(buffer[(start + 12)..<(start + 8 + size)])) : nil
                }
            }
            start += total
            switch frame {
            case .video(_, _, _, let payload)?:
                seenVideo = true
                if payload == lastVideo { continue }
                lastVideo = payload
            case .aac?, .adpcm?:
                if !seenVideo { continue }
            default:
                break
            }
            if let frame { frames.append(frame) }
        }
        if buffer.count - start > Self.maximumFrame + 64 {
            start = buffer.count
            throw BcMediaError.frameTooLarge(buffer.count)
        }
        return frames
    }

    /// The offset of the next known magic at or after `start`; the last 3 bytes are kept when none is found, in case a
    /// magic straddles two messages.
    private func resynchronised(from start: Int) -> Int {
        var index = start
        while index + 4 <= buffer.count {
            let slice = buffer[index..<(index + 4)]
            if Self.knownMagics.contains(where: { $0.elementsEqual(slice) }) { return index }
            index += 1
        }
        return max(start, buffer.count - 3)
    }
}

// MARK: MPEG-TS (5.3)

/// Remuxes media frames into an MPEG-TS stream for FFmpeg: a video PID (H.264 or H.265) and, when audio is wanted and the
/// camera sends AAC, an ADTS PID. Writing starts at the first I-frame; with audio, the header waits for the first AAC
/// frame for up to 2 seconds of video. Video PTS are 90000 + the microseconds since the first written frame × 9/100;
/// audio PTS run on from the first audio frame by 1024 × 90000 / sample rate, moved up to the video's when more than a
/// second behind.
struct BcMediaMuxer: Sendable {
    static let packetSize = 188
    static let patPID: UInt16 = 0
    static let pmtPID: UInt16 = 0x1000
    static let videoPID: UInt16 = 0x100
    static let audioPID: UInt16 = 0x101
    /// How long, in video time, the header waits for the first audio frame.
    static let audioWait: UInt64 = 2 * 90000
    /// ADTS's sampling frequencies by index.
    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    let wantsAudio: Bool
    private(set) var codec: BcMediaCodec?
    private(set) var fps: Int?
    private(set) var hasAudio = false
    private var headerWritten = false
    private var pending: [BcMediaFrame] = []
    private var firstTimestamp: UInt32?
    private var lastTimestamp: UInt32 = 0
    private var elapsed: UInt64 = 0
    private var videoPTS: UInt64 = 90000
    private var audioPTS: UInt64?
    private var continuity: [UInt16: UInt8] = [:]

    init(audio: Bool) {
        wantsAudio = audio
    }

    /// Whether the first I-frame came (the codec is known).
    var hasStarted: Bool { codec != nil }

    /// The TS bytes the frame makes (none while it waits for the first I-frame or the audio).
    mutating func push(_ frame: BcMediaFrame) -> [UInt8] {
        switch frame {
        case .info(_, _, let fps):
            if fps > 0 { self.fps = fps }
            return []
        case .adpcm:
            // No MPEG-TS mapping (5.3): dropped.
            return []
        case .video(let codec, let keyframe, _, _):
            if self.codec == nil {
                guard keyframe else { return [] }
                self.codec = codec
            }
            guard codec == self.codec else { return [] }
        case .aac:
            guard wantsAudio, codec != nil else { return [] }
        }
        if !headerWritten {
            if case .aac = frame { hasAudio = true }
            pending.append(frame)
            let waited = pendingVideoSpan
            guard !wantsAudio || hasAudio || waited >= Self.audioWait else { return [] }
            headerWritten = true
            var output = tables()
            for item in pending { output += write(item) }
            pending = []
            return output
        }
        return write(frame)
    }

    /// The video time the pending frames span, in 90 kHz units.
    private var pendingVideoSpan: UInt64 {
        var first: UInt32?
        var span: UInt64 = 0
        var last: UInt32 = 0
        for case .video(_, _, let timestamp, _) in pending {
            if first == nil { first = timestamp; last = timestamp; continue }
            span += Self.forward(from: last, to: timestamp)
            last = timestamp
        }
        return span * 9 / 100
    }

    /// Microseconds from one timestamp to the next across the 32-bit wrap; a step back counts as none.
    static func forward(from last: UInt32, to next: UInt32) -> UInt64 {
        let delta = next &- last
        return delta > 0x8000_0000 ? 0 : UInt64(delta)
    }

    private mutating func write(_ frame: BcMediaFrame) -> [UInt8] {
        switch frame {
        case .video(_, let keyframe, let timestamp, let payload):
            if firstTimestamp == nil {
                firstTimestamp = timestamp
                lastTimestamp = timestamp
            }
            elapsed += Self.forward(from: lastTimestamp, to: timestamp)
            lastTimestamp = timestamp
            videoPTS = 90000 + elapsed * 9 / 100
            var output = keyframe ? tables() : []
            output += pes(pid: Self.videoPID, streamID: 0xE0, pts: videoPTS, payload: payload, pcr: true, randomAccess: keyframe)
            return output
        case .aac(let payload):
            guard hasAudio else { return [] }
            let rate = payload.count > 2 ? Self.sampleRates[min(Int(payload[2] >> 2 & 0x0F), Self.sampleRates.count - 1)] : 16000
            var pts = audioPTS ?? videoPTS
            if pts + 90000 < videoPTS { pts = videoPTS }
            audioPTS = pts + UInt64(1024 * 90000 / rate)
            return pes(pid: Self.audioPID, streamID: 0xC0, pts: pts, payload: payload, pcr: false, randomAccess: false)
        default:
            return []
        }
    }

    // MARK: Tables

    /// The PAT and the PMT, a packet each.
    private mutating func tables() -> [UInt8] {
        var pat: [UInt8] = [0x00, 0xB0, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE0 | UInt8(Self.pmtPID >> 8), UInt8(Self.pmtPID & 0xFF)]
        pat[2] = UInt8(pat.count - 3 + 4)
        pat += Self.bigEndian(Self.crc32(pat))
        guard let codec else { return [] }
        var streams: [(UInt8, UInt16)] = [(codec.streamType, Self.videoPID)]
        if hasAudio { streams.append((0x0F, Self.audioPID)) }
        var pmt: [UInt8] = [0x02, 0xB0, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00]
        for (type, pid) in streams { pmt += [type, 0xE0 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0xF0, 0x00] }
        pmt[2] = UInt8(pmt.count - 3 + 4)
        pmt += Self.bigEndian(Self.crc32(pmt))
        return section(pid: Self.patPID, pat) + section(pid: Self.pmtPID, pmt)
    }

    private mutating func section(pid: UInt16, _ table: [UInt8]) -> [UInt8] {
        var packet = header(pid: pid, start: true, adaptation: false)
        packet.append(0x00)
        packet += table
        packet += [UInt8](repeating: 0xFF, count: Self.packetSize - packet.count)
        return packet
    }

    private mutating func header(pid: UInt16, start: Bool, adaptation: Bool) -> [UInt8] {
        let counter = continuity[pid, default: 0]
        continuity[pid] = (counter + 1) & 0x0F
        return [0x47, (start ? 0x40 : 0x00) | UInt8(pid >> 8 & 0x1F), UInt8(pid & 0xFF), (adaptation ? 0x30 : 0x10) | counter]
    }

    // MARK: PES

    static func ptsBytes(_ pts: UInt64) -> [UInt8] {
        let value = pts & 0x1_FFFF_FFFF
        return [0x21 | UInt8(value >> 29 & 0x0E), UInt8(value >> 22 & 0xFF), UInt8(value >> 14 & 0xFE) | 1, UInt8(value >> 7 & 0xFF), UInt8(value << 1 & 0xFE) | 1]
    }

    private mutating func pes(pid: UInt16, streamID: UInt8, pts: UInt64, payload: [UInt8], pcr: Bool, randomAccess: Bool) -> [UInt8] {
        let headerData = Self.ptsBytes(pts)
        let length = 3 + headerData.count + payload.count
        // Video may leave the length at 0 (unbounded); audio frames always fit.
        let declared = streamID == 0xE0 && length > 0xFFFF ? 0 : length
        var pes: [UInt8] = [0x00, 0x00, 0x01, streamID, UInt8(declared >> 8 & 0xFF), UInt8(declared & 0xFF), 0x80, 0x80, UInt8(headerData.count)]
        pes += headerData
        pes += payload
        var output: [UInt8] = []
        output.reserveCapacity((pes.count / 184 + 2) * Self.packetSize)
        var offset = 0
        var first = true
        while offset < pes.count {
            var adaptation: [UInt8] = []
            if first, pcr || randomAccess {
                var flags: UInt8 = 0
                if randomAccess { flags |= 0x40 }
                if pcr { flags |= 0x10 }
                adaptation = [flags]
                if pcr {
                    let base = pts & 0x1_FFFF_FFFF
                    adaptation += [UInt8(base >> 25 & 0xFF), UInt8(base >> 17 & 0xFF), UInt8(base >> 9 & 0xFF), UInt8(base >> 1 & 0xFF), UInt8(base << 7 & 0x80) | 0x7E, 0x00]
                }
            }
            let room = 184 - (adaptation.isEmpty ? 0 : adaptation.count + 1)
            let remaining = pes.count - offset
            if remaining < room {
                // Stuffing in the adaptation field fills the last packet.
                let stuffing = room - remaining
                if adaptation.isEmpty {
                    adaptation = stuffing == 1 ? [] : [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 2)
                    var packet = header(pid: pid, start: first, adaptation: true)
                    packet.append(UInt8(adaptation.count))
                    packet += adaptation
                    packet += pes[offset...]
                    output += packet
                    break
                }
                adaptation += [UInt8](repeating: 0xFF, count: stuffing)
            }
            var packet = header(pid: pid, start: first, adaptation: !adaptation.isEmpty)
            if !adaptation.isEmpty {
                packet.append(UInt8(adaptation.count))
                packet += adaptation
            }
            let take = min(Self.packetSize - packet.count, remaining)
            packet += pes[offset..<(offset + take)]
            offset += take
            output += packet
            first = false
        }
        return output
    }

    // MARK: CRC

    static func bigEndian(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

    /// MPEG-2's CRC-32: polynomial 0x04C11DB7, initial value 0xFFFFFFFF, most significant bit first, no final XOR.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? crc << 1 ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }
}
