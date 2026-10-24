import Foundation
import NIOConcurrencyHelpers

/// A camera's live video for a browser: fragmented MP4 that Media Source Extensions play as it comes. The web UI
/// sends the initialization segment first, then each fragment (a `moof` and its `mdat`), and cancels the feed when
/// the viewer leaves; a plugin hands one out from `HomeswiftPlugin.liveFeed(accessoryID:)`.
///
/// ```swift
/// let (fragments, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
/// source.onFragment { continuation.yield($0) }
/// return CameraLiveFeed(initSegment: initSegment, fragments: fragments) { source.stop() }
/// ```
public struct CameraLiveFeed: Sendable {
    /// For `MediaSource.isTypeSupported` and `addSourceBuffer`: `video/mp4; codecs="avc1.640028, mp4a.40.2"`.
    public let mimeType: String
    /// `ftyp` and `moov`: the tracks and their codec configurations.
    public let initSegment: Data
    /// The media fragments, in order; the sequence ends when the source does.
    public let fragments: AsyncThrowingStream<Data, any Error>
    private let release: Release

    /// `mimeType` defaults to what the initialization segment describes (`mimeType(initSegment:)`); `onCancel`
    /// releases the source and runs once, at the first `cancel()`.
    public init(mimeType: String? = nil, initSegment: Data, fragments: AsyncThrowingStream<Data, any Error>, onCancel: @escaping @Sendable () -> Void) {
        self.mimeType = mimeType ?? Self.mimeType(initSegment: initSegment) ?? "video/mp4"
        self.initSegment = initSegment
        self.fragments = fragments
        release = Release(onCancel)
    }

    /// Stops the feed and releases its source: the viewer left. Later calls do nothing.
    public func cancel() {
        release.run()
    }

    private final class Release: Sendable {
        private let action: NIOLockedValueBox<(@Sendable () -> Void)?>

        init(_ action: @escaping @Sendable () -> Void) {
            self.action = NIOLockedValueBox(action)
        }

        func run() {
            let action = action.withLockedValue { action -> (@Sendable () -> Void)? in
                defer { action = nil }
                return action
            }
            action?()
        }
    }

    // MARK: Codecs

    /// The MIME type with the codecs of every track of an initialization segment, as RFC 6381 names them for
    /// MSE: `video/mp4; codecs="avc1.640028, mp4a.40.2"`. The video codec comes from its `avcC` or `hvcC` box,
    /// AAC's object type from `esds`. nil when the segment has no track this can name.
    public static func mimeType(initSegment: Data) -> String? {
        let codecs = codecs(initSegment: initSegment)
        guard !codecs.isEmpty else { return nil }
        return "video/mp4; codecs=\"\(codecs.joined(separator: ", "))\""
    }

    /// The RFC 6381 codec of each track (`avc1.640028`, `hvc1.1.6.L93.B0`, `mp4a.40.2`, `opus`), video first.
    public static func codecs(initSegment: Data) -> [String] {
        let bytes = [UInt8](initSegment)
        guard let moov = MP4Boxes.children(bytes, 0..<bytes.count).first(where: { $0.type == "moov" }) else { return [] }
        var video: [String] = []
        var audio: [String] = []
        for trak in MP4Boxes.children(bytes, moov.body) where trak.type == "trak" {
            guard let stsd = MP4Boxes.find(bytes, trak.body, path: ["mdia", "minf", "stbl", "stsd"]) else { continue }
            // A full box: version and flags, then the entry count.
            guard let entries = MP4Boxes.body(stsd, after: 8), let entry = MP4Boxes.children(bytes, entries).first else { continue }
            switch entry.type {
            case "avc1", "avc3", "hvc1", "hev1":
                // A visual sample entry's fields take 78 bytes before its boxes.
                let boxes = MP4Boxes.body(entry, after: 78).map { MP4Boxes.children(bytes, $0) } ?? []
                if let avcC = boxes.first(where: { $0.type == "avcC" }), avcC.body.count >= 4 {
                    let start = avcC.body.lowerBound
                    video.append(entry.type + "." + [bytes[start + 1], bytes[start + 2], bytes[start + 3]].map { hex($0, width: 2) }.joined())
                } else if let hvcC = boxes.first(where: { $0.type == "hvcC" }), hvcC.body.count >= 13 {
                    video.append(entry.type + "." + hevcParameters(Array(bytes[hvcC.body])))
                } else {
                    video.append(entry.type)
                }
            case "mp4a":
                // An audio sample entry's fields take 28 bytes before its boxes.
                let boxes = MP4Boxes.body(entry, after: 28).map { MP4Boxes.children(bytes, $0) } ?? []
                let objectType = boxes.first(where: { $0.type == "esds" }).flatMap { aacObjectType(Array(bytes[$0.body])) }
                audio.append(objectType.map { "mp4a.\(hex(UInt8($0.indication), width: 2)).\($0.audioObjectType)" } ?? "mp4a.40.2")
            case "Opus":
                audio.append("opus")
            case "fLaC":
                audio.append("flac")
            default:
                continue
            }
        }
        return video + audio
    }

    /// `hvcC`'s profile, compatibility flags, tier, level and constraints as ISO/IEC 14496-15 annex E writes them:
    /// `1.6.L93.B0`.
    static func hevcParameters(_ hvcC: [UInt8]) -> String {
        let profileSpace = Int(hvcC[1] >> 6), tier = (hvcC[1] >> 5) & 1, profile = Int(hvcC[1] & 0x1F)
        let compatibility = hvcC[2..<6].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var reversed: UInt32 = 0
        for bit in 0..<32 where compatibility & (1 << bit) != 0 { reversed |= 1 << (31 - bit) }
        var constraints = Array(hvcC[6..<12])
        while constraints.last == 0 { constraints.removeLast() }
        let space = ["", "A", "B", "C"][profileSpace]
        return "\(space)\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier == 1 ? "H" : "L")\(hvcC[12])"
            + constraints.map { "." + String($0, radix: 16, uppercase: true) }.joined()
    }

    /// The object type indication of an `esds` box's decoder configuration and the audio object type of its
    /// AudioSpecificConfig: `(0x40, 2)` for AAC-LC.
    static func aacObjectType(_ esds: [UInt8]) -> (indication: Int, audioObjectType: Int)? {
        var reader = DescriptorReader(bytes: esds, offset: 4)   // past version and flags
        guard let es = reader.descriptor(tag: 0x03) else { return nil }
        var inner = DescriptorReader(bytes: esds, offset: es.lowerBound)
        // ES_ID, then the flags of what follows.
        guard let flags = inner.read(3)?.last else { return nil }
        if flags & 0x80 != 0 { inner.offset += 2 }
        if flags & 0x40 != 0, let length = inner.read(1)?.first { inner.offset += Int(length) }
        if flags & 0x20 != 0 { inner.offset += 2 }
        guard let decoderConfig = inner.descriptor(tag: 0x04), decoderConfig.count >= 13 else { return nil }
        let indication = Int(esds[decoderConfig.lowerBound])
        var specific = DescriptorReader(bytes: esds, offset: decoderConfig.lowerBound + 13)
        guard let info = specific.descriptor(tag: 0x05), !info.isEmpty else { return (indication, 2) }
        var objectType = Int(esds[info.lowerBound] >> 3)
        if objectType == 31, info.count >= 2 {
            objectType = 32 + Int((esds[info.lowerBound] & 0x07) << 3 | esds[info.lowerBound + 1] >> 5)
        }
        return (indication, objectType)
    }

    private static func hex(_ byte: UInt8, width: Int) -> String {
        let text = String(byte, radix: 16)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    /// MPEG-4 descriptors: a tag, a size of up to four 7-bit bytes, the payload.
    private struct DescriptorReader {
        let bytes: [UInt8]
        var offset: Int

        mutating func read(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return bytes[offset..<(offset + count)]
        }

        /// The payload of the next descriptor when it has this tag, and moves past its header.
        mutating func descriptor(tag: UInt8) -> Range<Int>? {
            guard let found = read(1), found.first == tag else { return nil }
            var size = 0
            for _ in 0..<4 {
                guard let byte = read(1)?.first else { return nil }
                size = size << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            guard offset + size <= bytes.count else { return nil }
            return offset..<(offset + size)
        }
    }
}

/// Just enough ISO BMFF to find a box: each is a 32-bit size, a four-character type and its body.
enum MP4Boxes {
    struct Box {
        var type: String
        var body: Range<Int>
    }

    /// The boxes directly inside a range; stops at the first malformed size.
    static func children(_ bytes: [UInt8], _ range: Range<Int>) -> [Box] {
        var boxes: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            var header = 8
            if size == 1, offset + 16 <= range.upperBound {
                // A 64-bit size follows the type.
                size = bytes[(offset + 8)..<(offset + 16)].reduce(0) { $0 << 8 | Int($1) }
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            // Compared without adding: a 64-bit size from the file would overflow `offset + size`.
            guard size >= header, size <= range.upperBound - offset else { break }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            boxes.append(Box(type: type, body: (offset + header)..<(offset + size)))
            offset += size
        }
        return boxes
    }

    /// What follows the first `count` bytes of a box's body (a full box's header, a sample entry's fields); nil
    /// when the body is shorter.
    static func body(_ box: Box, after count: Int) -> Range<Int>? {
        box.body.count >= count ? (box.body.lowerBound + count)..<box.body.upperBound : nil
    }

    /// The box at the end of a path of nested types.
    static func find(_ bytes: [UInt8], _ range: Range<Int>, path: [String]) -> Box? {
        var current = range
        var found: Box?
        for type in path {
            guard let box = children(bytes, current).first(where: { $0.type == type }) else { return nil }
            found = box
            current = box.body
        }
        return found
    }
}
