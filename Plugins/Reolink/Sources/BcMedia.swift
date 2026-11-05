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

extension BcMediaFrame {
    /// The payload's bytes.
    var size: Int {
        switch self {
        case .info: 0
        case .video(_, _, _, let payload), .aac(let payload), .adpcm(let payload): payload.count
        }
    }
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

    /// Bytes consumed before the buffer is compacted (a frame is at most 4 MiB; a message's frames cost their length).
    static let compaction = 64 * 1024
    static let h265Tag = Array("H265".utf8)

    private var buffer: [UInt8] = []
    /// Where the bytes not parsed yet start: those before it go at the next compaction.
    private var head = 0
    private var lastVideo: [UInt8]?
    private var seenVideo = false

    /// Bytes waiting for the rest of their frame.
    var pendingCount: Int { buffer.count - head }

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

    /// The frames `chunk` completes.
    mutating func push(_ chunk: [UInt8]) throws -> [BcMediaFrame] {
        buffer += chunk
        var frames: [BcMediaFrame] = []
        var start = head
        defer { compact(to: min(start, buffer.count)) }
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
                let width = Int(Baichuan.readUInt32(buffer, start + 8)), height = Int(Baichuan.readUInt32(buffer, start + 12))
                frame = .info(width: width, height: height, fps: Int(buffer[start + 17]))
            case .iframe, .pframe:
                guard available >= 24 else { return frames }
                let size = Int(Baichuan.readUInt32(buffer, start + 8)), extra = Int(Baichuan.readUInt32(buffer, start + 12))
                guard size <= Self.maximumFrame, extra <= Self.maximumFrame else {
                    start = buffer.count
                    throw BcMediaError.frameTooLarge(max(size, extra))
                }
                total = 24 + extra + size + Self.padding(size)
                guard available >= total else { return frames }
                let codec: BcMediaCodec = buffer[(start + 4)..<(start + 8)].elementsEqual(Self.h265Tag) ? .h265 : .h264
                let payloadStart = start + 24 + extra
                let payload = Array(buffer[payloadStart..<(payloadStart + size)])
                frame = .video(codec: codec, keyframe: kind == .iframe, timestamp: Baichuan.readUInt32(buffer, start + 16), payload: payload)
            case .aac, .adpcm:
                let size = Int(Baichuan.readUInt16(buffer, start + 4))
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

    /// Moves the read position to `start`: the buffer emptied when all of it was read, else compacted past `compaction`.
    private mutating func compact(to start: Int) {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            head = 0
        } else if start >= Self.compaction {
            buffer.removeFirst(start)
            head = 0
        } else {
            head = start
        }
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
    /// The most frames, and bytes, held while the header waits for audio: a camera whose timestamps do not advance would
    /// otherwise have them pile up (a frame may be 4 MiB). Reached, the header goes without audio.
    static let pendingFrames = 120
    static let pendingBytes = 8 * 1024 * 1024
    /// ADTS's sampling frequencies by index.
    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    let wantsAudio: Bool
    private(set) var codec: BcMediaCodec?
    private(set) var fps: Int?
    private(set) var hasAudio = false
    private var headerWritten = false
    private var pending: [BcMediaFrame] = []
    private var pendingSize = 0
    private var firstTimestamp: UInt32?
    private var lastTimestamp: UInt32 = 0
    private var elapsed: UInt64 = 0
    private var videoPTS: UInt64 = 90000
    private var audioPTS: UInt64?
    private var continuity: [UInt16: UInt8] = [:]

    init(audio: Bool) {
        wantsAudio = audio
    }

    /// The TS bytes the frame makes (none while it waits for the first I-frame or the audio).
    mutating func push(_ frame: BcMediaFrame) -> [UInt8] {
        var output: [UInt8] = []
        push(frame, into: &output)
        return output
    }

    /// Appends the TS bytes the frame makes to `output`.
    mutating func push(_ frame: BcMediaFrame, into output: inout some RangeReplaceableCollection<UInt8>) {
        switch frame {
        case .info(_, _, let fps):
            if fps > 0 { self.fps = fps }
            return
        case .adpcm:
            // No MPEG-TS mapping (5.3): dropped.
            return
        case .video(let codec, let keyframe, _, _):
            if self.codec == nil {
                guard keyframe else { return }
                self.codec = codec
            }
            guard codec == self.codec else { return }
        case .aac:
            guard wantsAudio, codec != nil else { return }
        }
        if !headerWritten {
            if case .aac = frame { hasAudio = true }
            pending.append(frame)
            pendingSize += frame.size
            let full = pending.count >= Self.pendingFrames || pendingSize >= Self.pendingBytes
            guard !wantsAudio || hasAudio || full || pendingVideoSpan >= Self.audioWait else { return }
            headerWritten = true
            tables(into: &output)
            for item in pending { write(item, into: &output) }
            pending = []
            pendingSize = 0
            return
        }
        write(frame, into: &output)
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

    private mutating func write(_ frame: BcMediaFrame, into output: inout some RangeReplaceableCollection<UInt8>) {
        switch frame {
        case .video(_, let keyframe, let timestamp, let payload):
            if firstTimestamp == nil {
                firstTimestamp = timestamp
                lastTimestamp = timestamp
            }
            elapsed += Self.forward(from: lastTimestamp, to: timestamp)
            lastTimestamp = timestamp
            videoPTS = 90000 + elapsed * 9 / 100
            if keyframe { tables(into: &output) }
            pes(pid: Self.videoPID, streamID: 0xE0, pts: videoPTS, payload: payload, pcr: true, randomAccess: keyframe, into: &output)
        case .aac(let payload):
            guard hasAudio else { return }
            let rate = payload.count > 2 ? Self.sampleRates[min(Int(payload[2] >> 2 & 0x0F), Self.sampleRates.count - 1)] : 16000
            var pts = audioPTS ?? videoPTS
            if pts + 90000 < videoPTS { pts = videoPTS }
            audioPTS = pts + UInt64(1024 * 90000 / rate)
            pes(pid: Self.audioPID, streamID: 0xC0, pts: pts, payload: payload, pcr: false, randomAccess: false, into: &output)
        default:
            return
        }
    }

    // MARK: Tables

    /// The PAT and the PMT, a packet each.
    private mutating func tables(into output: inout some RangeReplaceableCollection<UInt8>) {
        var pat: [UInt8] = [0x00, 0xB0, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE0 | UInt8(Self.pmtPID >> 8), UInt8(Self.pmtPID & 0xFF)]
        pat[2] = UInt8(pat.count - 3 + 4)
        pat += Self.bigEndian(Self.crc32(pat))
        guard let codec else { return }
        var streams: [(UInt8, UInt16)] = [(codec.streamType, Self.videoPID)]
        if hasAudio { streams.append((0x0F, Self.audioPID)) }
        var pmt: [UInt8] = [0x02, 0xB0, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00]
        for (type, pid) in streams { pmt += [type, 0xE0 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0xF0, 0x00] }
        pmt[2] = UInt8(pmt.count - 3 + 4)
        pmt += Self.bigEndian(Self.crc32(pmt))
        section(pid: Self.patPID, pat, into: &output)
        section(pid: Self.pmtPID, pmt, into: &output)
    }

    private mutating func section(pid: UInt16, _ table: [UInt8], into output: inout some RangeReplaceableCollection<UInt8>) {
        header(pid: pid, start: true, adaptation: false, into: &output)
        output.append(0x00)
        output.append(contentsOf: table)
        output.append(contentsOf: repeatElement(0xFF, count: Self.packetSize - 5 - table.count))
    }

    private mutating func header(pid: UInt16, start: Bool, adaptation: Bool, into output: inout some RangeReplaceableCollection<UInt8>) {
        let counter = continuity[pid, default: 0]
        continuity[pid] = (counter + 1) & 0x0F
        output.append(0x47)
        output.append((start ? 0x40 : 0x00) | UInt8(pid >> 8 & 0x1F))
        output.append(UInt8(pid & 0xFF))
        output.append((adaptation ? 0x30 : 0x10) | counter)
    }

    // MARK: PES

    static func ptsBytes(_ pts: UInt64) -> [UInt8] {
        let value = pts & 0x1_FFFF_FFFF
        return [0x21 | UInt8(value >> 29 & 0x0E), UInt8(value >> 22 & 0xFF), UInt8(value >> 14 & 0xFE) | 1, UInt8(value >> 7 & 0xFF), UInt8(value << 1 & 0xFE) | 1]
    }

    /// The PES packet of `payload` in TS packets, written straight into `output`: its header in the first packet, the
    /// payload sliced after it.
    private mutating func pes(pid: UInt16, streamID: UInt8, pts: UInt64, payload: [UInt8], pcr: Bool, randomAccess: Bool,
                              into output: inout some RangeReplaceableCollection<UInt8>) {
        let headerData = Self.ptsBytes(pts)
        let length = 3 + headerData.count + payload.count
        // Video may leave the length at 0 (unbounded); audio frames always fit.
        let declared = streamID == 0xE0 && length > 0xFFFF ? 0 : length
        var pesHeader: [UInt8] = [0x00, 0x00, 0x01, streamID, UInt8(declared >> 8 & 0xFF), UInt8(declared & 0xFF), 0x80, 0x80, UInt8(headerData.count)]
        pesHeader += headerData
        let total = pesHeader.count + payload.count
        output.reserveCapacity(output.count + (total / 184 + 2) * Self.packetSize)
        var offset = 0
        /// The next `count` bytes of the PES packet: the rest of its header, then the payload's.
        func copy(_ count: Int) {
            var count = count
            if offset < pesHeader.count {
                let taken = min(count, pesHeader.count - offset)
                output.append(contentsOf: pesHeader[offset..<(offset + taken)])
                offset += taken
                count -= taken
            }
            guard count > 0 else { return }
            let from = offset - pesHeader.count
            output.append(contentsOf: payload[from..<(from + count)])
            offset += count
        }
        var first = true
        while offset < total {
            // The first packet's adaptation field: its flags, and the PCR.
            let field = first && (pcr || randomAccess) ? (pcr ? 7 : 1) : 0
            let room = 184 - (field == 0 ? 0 : field + 1)
            let remaining = total - offset
            // Stuffing in the adaptation field fills the last packet.
            let stuffing = remaining < room ? room - remaining : 0
            if field == 0, stuffing > 0 {
                header(pid: pid, start: first, adaptation: true, into: &output)
                if stuffing == 1 {
                    output.append(0x00)
                } else {
                    output.append(UInt8(stuffing - 1))
                    output.append(0x00)
                    output.append(contentsOf: repeatElement(0xFF, count: stuffing - 2))
                }
                copy(remaining)
                break
            }
            header(pid: pid, start: first, adaptation: field > 0, into: &output)
            if field > 0 {
                output.append(UInt8(field + stuffing))
                output.append((randomAccess ? 0x40 : 0) | (pcr ? 0x10 : 0))
                if pcr {
                    let base = pts & 0x1_FFFF_FFFF
                    output.append(UInt8(base >> 25 & 0xFF))
                    output.append(UInt8(base >> 17 & 0xFF))
                    output.append(UInt8(base >> 9 & 0xFF))
                    output.append(UInt8(base >> 1 & 0xFF))
                    output.append(UInt8(base << 7 & 0x80) | 0x7E)
                    output.append(0x00)
                }
                output.append(contentsOf: repeatElement(0xFF, count: stuffing))
            }
            copy(min(room - stuffing, remaining))
            first = false
        }
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
