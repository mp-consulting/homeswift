import Foundation

// ISO BMFF (fMP4) box parsing (fmp4.ts): locate boxes, split fragments into moof and mdat, tell keyframes from the trun sample
// flags, find audio tracks in an initialization segment, and reassemble top-level boxes from a chunked stream. Offsets are
// relative to the start of the `Data` given, whatever its indices.

/// The size of a box header: a 4-byte big-endian size and a 4-byte ASCII type.
public let BOX_HEADER_SIZE = 8

/// `mdat` as a 32-bit integer.
public let BOX_TYPE_MDAT: UInt32 = 0x6D64_6174

/// `moof` as a 32-bit integer.
public let BOX_TYPE_MOOF: UInt32 = 0x6D6F_6F66

/// `moov` as a 32-bit integer.
public let BOX_TYPE_MOOV: UInt32 = 0x6D6F_6F76

// trun fullbox header: box header, version and flags, sample_count.
private let TRUN_HEADER_SIZE = BOX_HEADER_SIZE + 8

// trun flags for the optional fields.
private let TRUN_FLAG_DATA_OFFSET: UInt32 = 0x000001
private let TRUN_FLAG_FIRST_SAMPLE_FLAGS: UInt32 = 0x000004
private let TRUN_FLAG_SAMPLE_DURATION: UInt32 = 0x000100
private let TRUN_FLAG_SAMPLE_SIZE: UInt32 = 0x000200
private let TRUN_FLAG_SAMPLE_FLAGS: UInt32 = 0x000400

// The sample flag of a non-sync sample: clear on a keyframe.
private let SAMPLE_FLAG_NON_SYNC: UInt32 = 0x0001_0000

// The handler type of audio tracks, "soun".
private let HDLR_TYPE_SOUN: UInt32 = 0x736F_756E

// From the start of an hdlr fullbox to handler_type: box header, version and flags, pre_defined.
private let HDLR_TYPE_OFFSET = BOX_HEADER_SIZE + 8

/// Where a box is: its offset (at the header) and total size, header included.
public struct FMp4Box: Sendable, Equatable {
    public var offset: Int
    public var size: Int

    public init(offset: Int, size: Int) {
        self.offset = offset
        self.size = size
    }
}

extension Data {
    /// The big-endian 32-bit integer at `offset` from the start.
    @inline(__always)
    func readUInt32BE(_ offset: Int) -> UInt32 {
        let start = startIndex + offset
        return UInt32(self[start]) << 24 | UInt32(self[start + 1]) << 16 | UInt32(self[start + 2]) << 8 | UInt32(self[start + 3])
    }

    /// The bytes `from` to `to` (offsets from the start), with indices starting at zero.
    func rebased(_ from: Int, _ to: Int) -> Data {
        Data(self[(startIndex + from)..<(startIndex + to)])
    }
}

/// The type code of a four-character box type, nil when it is not four ASCII characters.
func boxType(_ type: String) -> UInt32? {
    let bytes = Array(type.utf8)
    guard bytes.count == 4 else { return nil }
    return bytes.reduce(0) { $0 << 8 | UInt32($1) }
}

/// The first box of type `type` (four characters, e.g. `moof`) between `start` and `end`, walking box headers. nil when there is
/// none, or when a size is invalid (below the header size: corruption, extended or open-ended boxes) or overruns the range.
public func findBox(_ buffer: Data, _ type: String, start: Int = 0, end: Int? = nil) -> FMp4Box? {
    let limit = end ?? buffer.count
    guard let target = boxType(type) else { return nil }
    var offset = start
    while offset + BOX_HEADER_SIZE <= limit {
        let size = Int(buffer.readUInt32BE(offset))
        guard size >= BOX_HEADER_SIZE, size <= limit - offset else { return nil }
        if buffer.readUInt32BE(offset + 4) == target {
            return FMp4Box(offset: offset, size: size)
        }
        offset += size
    }
    return nil
}

/// Whether a segment (a moof and mdat pair) starts with a sync sample, from `moof > traf > trun`: `first_sample_flags` when present
/// (fragments made with `frag_keyframe`), the first sample's flags otherwise. False when the structure or flags are missing.
public func isKeyframe(_ segment: Data) -> Bool {
    guard let moof = findBox(segment, "moof"),
          let traf = findBox(segment, "traf", start: moof.offset + BOX_HEADER_SIZE, end: moof.offset + moof.size),
          let trun = findBox(segment, "trun", start: traf.offset + BOX_HEADER_SIZE, end: traf.offset + traf.size),
          trun.size >= TRUN_HEADER_SIZE
    else { return false }

    // The version is the top byte, the flags the lower 24 bits.
    let flags = segment.readUInt32BE(trun.offset + BOX_HEADER_SIZE) & 0x00FF_FFFF
    var position = trun.offset + TRUN_HEADER_SIZE
    if flags & TRUN_FLAG_DATA_OFFSET != 0 {
        position += 4
    }
    if flags & TRUN_FLAG_FIRST_SAMPLE_FLAGS != 0 {
        guard position + 4 <= trun.offset + trun.size else { return false }
        return segment.readUInt32BE(position) & SAMPLE_FLAG_NON_SYNC == 0
    }
    // Per-sample entries: duration, size, flags, composition time offset.
    if flags & TRUN_FLAG_SAMPLE_FLAGS != 0 {
        if flags & TRUN_FLAG_SAMPLE_DURATION != 0 { position += 4 }
        if flags & TRUN_FLAG_SAMPLE_SIZE != 0 { position += 4 }
        guard position + 4 <= trun.offset + trun.size else { return false }
        return segment.readUInt32BE(position) & SAMPLE_FLAG_NON_SYNC == 0
    }
    return false
}

/// Whether an initialization segment has an audio track: a `moov > trak > mdia > hdlr` with handler type `soun`.
public func hasAudioTrack(_ initSegment: Data) -> Bool {
    guard let moov = findBox(initSegment, "moov") else { return false }
    let moovEnd = moov.offset + moov.size
    var trakStart = moov.offset + BOX_HEADER_SIZE
    while let trak = findBox(initSegment, "trak", start: trakStart, end: moovEnd) {
        if let mdia = findBox(initSegment, "mdia", start: trak.offset + BOX_HEADER_SIZE, end: trak.offset + trak.size),
           let hdlr = findBox(initSegment, "hdlr", start: mdia.offset + BOX_HEADER_SIZE, end: mdia.offset + mdia.size),
           hdlr.size >= HDLR_TYPE_OFFSET + 4,
           initSegment.readUInt32BE(hdlr.offset + HDLR_TYPE_OFFSET) == HDLR_TYPE_SOUN
        {
            return true
        }
        trakStart = trak.offset + trak.size
    }
    return false
}

/// Splits a fragment at its `mdat`: everything before it (the moof and any metadata), and the mdat to the end. nil without an mdat.
public func splitMoofMdat(_ fragment: Data) -> (mdat: Data, moof: Data)? {
    guard let mdat = findBox(fragment, "mdat") else { return nil }
    return (fragment.rebased(mdat.offset, fragment.count), fragment.rebased(0, mdat.offset))
}

/// A complete box from `FMp4BoxReader`: its 8-byte header, its payload, the payload length and the type as a 32-bit integer.
public struct FMp4ParsedBox: Sendable {
    public var data: Data
    public var header: Data
    public var length: Int
    public var type: UInt32

    public init(data: Data, header: Data, length: Int, type: UInt32) {
        self.data = data
        self.header = header
        self.length = length
        self.type = type
    }
}

/// Reassembles top-level boxes from a chunked byte stream such as FFmpeg's standard output. Boxes may be split anywhere, header
/// included; partial data is concatenated once, when its box is complete. A size below the header size (zero-size, open-ended or
/// extended-size boxes) is fatal: `push` returns false, `invalidBoxSize` records it and the pending data is dropped.
public struct FMp4BoxReader: Sendable {
    /// The offending size of the last corrupt box, nil when there was none.
    public private(set) var invalidBoxSize: Int?

    // The size of the box being reassembled, 0 while its header is incomplete.
    private var boxSize = 0
    private var pending: [Data] = []
    private var pendingLength = 0

    public init() {}

    /// Feeds a chunk, calling `onBox` for every box it completes, in order. False when a corrupt box size was found.
    public mutating func push(_ chunk: Data, _ onBox: (FMp4ParsedBox) -> Void) -> Bool {
        // Nothing pending: parse the chunk directly.
        guard pendingLength > 0 else { return parse(chunk, onBox) }
        pending.append(chunk)
        pendingLength += chunk.count
        // Still short of the box we're reassembling: keep collecting.
        if boxSize > 0 && pendingLength < boxSize { return true }
        // A complete box, or a header that was split: one concatenation gives a contiguous buffer.
        var buffer = Data(capacity: pendingLength)
        for part in pending { buffer.append(part) }
        reset()
        return parse(buffer, onBox)
    }

    /// Drops any partial box and clears the corruption state.
    public mutating func reset() {
        boxSize = 0
        invalidBoxSize = nil
        pending = []
        pendingLength = 0
    }

    private mutating func parse(_ buffer: Data, _ onBox: (FMp4ParsedBox) -> Void) -> Bool {
        var offset = 0
        while true {
            let remaining = buffer.count - offset
            if remaining == 0 { return true }
            // Not even a header: keep it for the next chunk.
            if remaining < BOX_HEADER_SIZE {
                stash(buffer.rebased(offset, buffer.count), boxSize: 0)
                return true
            }
            let size = Int(buffer.readUInt32BE(offset))
            // A box smaller than its header would never advance the parser.
            if size < BOX_HEADER_SIZE {
                reset()
                invalidBoxSize = size
                return false
            }
            // An incomplete box: keep it with the size we're waiting for.
            if remaining < size {
                stash(buffer.rebased(offset, buffer.count), boxSize: size)
                return true
            }
            onBox(FMp4ParsedBox(
                data: buffer.rebased(offset + BOX_HEADER_SIZE, offset + size), header: buffer.rebased(offset, offset + BOX_HEADER_SIZE),
                length: size - BOX_HEADER_SIZE, type: buffer.readUInt32BE(offset + 4)
            ))
            offset += size
        }
    }

    private mutating func stash(_ partial: Data, boxSize: Int) {
        self.boxSize = boxSize
        pending = [partial]
        pendingLength = partial.count
    }
}
