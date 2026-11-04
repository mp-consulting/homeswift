import Foundation

/// A top-level MP4 box: its four-character type and the whole box, header included.
struct MP4Box: Sendable, Equatable {
    var type: String
    var data: Data
}

/// Reassembles top-level boxes from FFmpeg's fragmented MP4 output (section 9.5): a 4-byte big-endian signed size that
/// counts the 8-byte header, a 4-byte type, the payload. The 64-bit and to-the-end forms (sizes 1 and 0) are not
/// supported, and a payload beyond 50 MiB is refused, so a corrupt stream cannot make it buffer without bound.
struct MP4BoxReader: Sendable {
    static let maximumPayload = 52_428_800

    struct InvalidBox: Error, CustomStringConvertible {
        var size: Int
        var description: String { "invalid MP4 box size \(size)" }
    }

    private var buffer = Data()

    /// Feeds a chunk and returns the boxes it completes, in order.
    mutating func push(_ chunk: Data) throws -> [MP4Box] {
        buffer.append(chunk)
        var boxes: [MP4Box] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 8 {
            let size = Int(Int32(bitPattern: buffer[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }))
            let payload = size - 8
            guard payload >= 0, payload <= Self.maximumPayload else {
                buffer = Data()
                throw InvalidBox(size: size)
            }
            guard buffer.endIndex - offset >= size else { break }
            let type = String(decoding: buffer[offset + 4..<offset + 8], as: UTF8.self)
            boxes.append(MP4Box(type: type, data: Data(buffer[offset..<offset + size])))
            offset += size
        }
        if offset != buffer.startIndex { buffer = Data(buffer[offset...]) }
        return boxes
    }
}

/// Turns a recording's boxes into HomeKit's packets (section 9.2): the initialization segment (every box up to and
/// including the first `moov`), then one fragment per `moof` followed by an `mdat`. Other boxes after the
/// initialization are dropped.
struct RecordingFragmenter: Sendable {
    private var initialization = Data()
    private var initialized = false
    private var moof: Data?

    /// The packet a box completes, if any.
    mutating func add(_ box: MP4Box) -> Data? {
        if !initialized {
            initialization.append(box.data)
            guard box.type == "moov" else { return nil }
            initialized = true
            defer { initialization = Data() }
            return initialization
        }
        switch box.type {
        case "moof":
            moof = box.data
            return nil
        case "mdat":
            guard let moof else { return nil }
            self.moof = nil
            return moof + box.data
        default:
            return nil
        }
    }
}
