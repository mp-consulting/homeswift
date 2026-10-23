import Foundation

/// zlib decompression (RFC 1950 around RFC 1951 DEFLATE), for the deflated frames of the realtime events API.
///
/// Foundation has no zlib on Linux and the package depends on no zlib binding, so this is a small canonical
/// Huffman decoder after Mark Adler's `puff`. The frames are small JSON documents; `maximumSize` caps the
/// output so a hostile or broken endpoint cannot make us allocate without bound.
enum Inflate {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidHeader
        case invalidData(String)
        case truncated
        case tooLarge(Int)
        case checksumMismatch

        var description: String {
            switch self {
            case .invalidHeader: "not a zlib stream"
            case .invalidData(let reason): "invalid deflate data (\(reason))"
            case .truncated: "the compressed data is truncated"
            case .tooLarge(let limit): "decompressed size exceeds \(limit) bytes"
            case .checksumMismatch: "the Adler-32 checksum does not match"
            }
        }
    }

    /// Decompresses a zlib stream: a two-byte header, DEFLATE blocks, an Adler-32 checksum.
    static func zlib(_ data: Data, maximumSize: Int) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { throw Failure.truncated }
        let cmf = Int(bytes[0]), flags = Int(bytes[1])
        guard cmf & 0x0F == 8, cmf >> 4 <= 7, (cmf * 256 + flags) % 31 == 0, flags & 0x20 == 0 else { throw Failure.invalidHeader }
        var reader = BitReader(bytes: bytes, position: 2)
        var output: [UInt8] = []
        try inflate(&reader, into: &output, maximumSize: maximumSize)
        let end = reader.alignedPosition
        guard end + 4 <= bytes.count else { throw Failure.truncated }
        let expected = UInt32(bytes[end]) << 24 | UInt32(bytes[end + 1]) << 16 | UInt32(bytes[end + 2]) << 8 | UInt32(bytes[end + 3])
        guard adler32(output) == expected else { throw Failure.checksumMismatch }
        return Data(output)
    }

    /// Decompresses raw DEFLATE data.
    static func raw(_ data: Data, maximumSize: Int) throws -> Data {
        var reader = BitReader(bytes: [UInt8](data), position: 0)
        var output: [UInt8] = []
        try inflate(&reader, into: &output, maximumSize: maximumSize)
        return Data(output)
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for chunk in stride(from: 0, to: bytes.count, by: 5552) {
            for byte in bytes[chunk..<min(chunk + 5552, bytes.count)] {
                a += UInt32(byte)
                b += a
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }

    // MARK: DEFLATE

    private struct BitReader {
        let bytes: [UInt8]
        var position: Int
        var buffer: UInt32 = 0
        var count = 0

        init(bytes: [UInt8], position: Int) {
            self.bytes = bytes
            self.position = position
        }

        mutating func bits(_ needed: Int) throws -> Int {
            while count < needed {
                guard position < bytes.count else { throw Failure.truncated }
                buffer |= UInt32(bytes[position]) << UInt32(count)
                position += 1
                count += 8
            }
            let value = buffer & ((1 << UInt32(needed)) - 1)
            buffer >>= UInt32(needed)
            count -= needed
            return Int(value)
        }

        /// Drops the bits left in the current byte.
        mutating func align() {
            buffer = 0
            count = 0
        }

        /// The first byte after the bits consumed so far.
        var alignedPosition: Int { position - count / 8 }
    }

    /// A canonical Huffman code: how many codes of each length, and the symbols in code order.
    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]

        init(lengths: [Int]) throws {
            symbols = [Int](repeating: 0, count: lengths.count)
            for length in lengths { counts[length] += 1 }
            var left = 1
            for length in 1..<16 {
                left <<= 1
                left -= counts[length]
                guard left >= 0 else { throw Failure.invalidData("over-subscribed code") }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }

        func decode(_ reader: inout BitReader) throws -> Int {
            var code = 0, first = 0, index = 0
            for length in 1..<16 {
                code |= try reader.bits(1)
                let count = counts[length]
                if code - count < first { return symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.invalidData("no code of that length")
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let fixedCodes: (Huffman, Huffman) = {
        var lengths = [Int](repeating: 8, count: 288)
        for symbol in 144..<256 { lengths[symbol] = 9 }
        for symbol in 256..<280 { lengths[symbol] = 7 }
        // The fixed codes are well formed; `try!` cannot fail here.
        let literals = try! Huffman(lengths: lengths)
        let distances = try! Huffman(lengths: [Int](repeating: 5, count: 30))
        return (literals, distances)
    }()

    private static func inflate(_ reader: inout BitReader, into output: inout [UInt8], maximumSize: Int) throws {
        var last = false
        while !last {
            last = try reader.bits(1) == 1
            switch try reader.bits(2) {
            case 0: try stored(&reader, into: &output, maximumSize: maximumSize)
            case 1: try codes(&reader, into: &output, literals: fixedCodes.0, distances: fixedCodes.1, maximumSize: maximumSize)
            case 2:
                let (literals, distances) = try dynamicCodes(&reader)
                try codes(&reader, into: &output, literals: literals, distances: distances, maximumSize: maximumSize)
            default: throw Failure.invalidData("invalid block type")
            }
        }
    }

    private static func stored(_ reader: inout BitReader, into output: inout [UInt8], maximumSize: Int) throws {
        reader.align()
        let start = reader.position
        guard start + 4 <= reader.bytes.count else { throw Failure.truncated }
        let length = Int(reader.bytes[start]) | Int(reader.bytes[start + 1]) << 8
        let complement = Int(reader.bytes[start + 2]) | Int(reader.bytes[start + 3]) << 8
        guard length == ~complement & 0xFFFF else { throw Failure.invalidData("stored block length does not match its complement") }
        guard start + 4 + length <= reader.bytes.count else { throw Failure.truncated }
        guard output.count + length <= maximumSize else { throw Failure.tooLarge(maximumSize) }
        output.append(contentsOf: reader.bytes[(start + 4)..<(start + 4 + length)])
        reader.position = start + 4 + length
    }

    private static func dynamicCodes(_ reader: inout BitReader) throws -> (Huffman, Huffman) {
        let literalCount = try reader.bits(5) + 257
        let distanceCount = try reader.bits(5) + 1
        let codeLengthCount = try reader.bits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw Failure.invalidData("bad counts") }
        var codeLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeLengthCount { codeLengths[codeLengthOrder[index]] = try reader.bits(3) }
        let lengthCode = try Huffman(lengths: codeLengths)
        var lengths: [Int] = []
        while lengths.count < literalCount + distanceCount {
            let symbol = try lengthCode.decode(&reader)
            switch symbol {
            case 0..<16: lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else { throw Failure.invalidData("repeat with no previous length") }
                lengths += [Int](repeating: previous, count: 3 + (try reader.bits(2)))
            case 17: lengths += [Int](repeating: 0, count: 3 + (try reader.bits(3)))
            default: lengths += [Int](repeating: 0, count: 11 + (try reader.bits(7)))
            }
        }
        guard lengths.count == literalCount + distanceCount else { throw Failure.invalidData("too many lengths") }
        guard lengths[256] != 0 else { throw Failure.invalidData("no end-of-block code") }
        return (try Huffman(lengths: Array(lengths[0..<literalCount])), try Huffman(lengths: Array(lengths[literalCount...])))
    }

    private static func codes(_ reader: inout BitReader, into output: inout [UInt8], literals: Huffman, distances: Huffman, maximumSize: Int) throws {
        while true {
            let symbol = try literals.decode(&reader)
            if symbol < 256 {
                guard output.count < maximumSize else { throw Failure.tooLarge(maximumSize) }
                output.append(UInt8(symbol))
                continue
            }
            if symbol == 256 { return }
            let lengthIndex = symbol - 257
            guard lengthIndex < lengthBase.count else { throw Failure.invalidData("bad length symbol") }
            let length = lengthBase[lengthIndex] + (try reader.bits(lengthExtra[lengthIndex]))
            let distanceSymbol = try distances.decode(&reader)
            guard distanceSymbol < distanceBase.count else { throw Failure.invalidData("bad distance symbol") }
            let distance = distanceBase[distanceSymbol] + (try reader.bits(distanceExtra[distanceSymbol]))
            guard distance <= output.count else { throw Failure.invalidData("distance too far back") }
            guard output.count + length <= maximumSize else { throw Failure.tooLarge(maximumSize) }
            let start = output.count - distance
            for offset in 0..<length { output.append(output[start + offset]) }
        }
    }
}
