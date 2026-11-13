import Foundation
import Homeswift
import NIOConcurrencyHelpers

// What a camera plugin turns HomeKit's return audio into for a camera's speaker (docs/clean-room/ReturnAudio.md, section 5):
// G.711 A-law and µ-law and IMA ADPCM in Swift, from the public standards (ITU-T G.711, the IMA/DVI ADPCM algorithm); AAC
// through FFmpeg (`AACTalkEncoder`), an encoder not being worth writing.

/// ITU-T G.711: a 16-bit sample in one byte, A-law (PCMA) or µ-law (PCMU), at 8000 Hz.
public enum G711 {
    /// A-law (section 5.1): the 13-bit value, its sign, a segment and four bits of mantissa, inverted every other bit.
    public static func aLaw(_ sample: Int16) -> UInt8 {
        let value = Int(sample) >> 3
        let sign: Int = value >= 0 ? 0x80 : 0
        let magnitude = min(value >= 0 ? value : -value - 1, 0xFFF)
        let code: Int
        if magnitude < 32 {
            code = magnitude >> 1
        } else {
            // The segment is one more than the position of the highest set bit of magnitude >> 5.
            var segment = 1
            var rest = magnitude >> 5
            while rest > 1 {
                rest >>= 1
                segment += 1
            }
            code = segment << 4 | (magnitude >> segment) & 0x0F
        }
        return UInt8((code | sign) ^ 0x55)
    }

    private static let muLawBounds = [0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF]

    /// µ-law (section 5.2), the classic reference formulation on the 14-bit value.
    public static func muLaw(_ sample: Int16) -> UInt8 {
        var value = Int(sample) >> 2
        let mask: Int
        if value < 0 {
            value = -value
            mask = 0x7F
        } else {
            mask = 0xFF
        }
        value = min(value, 8159) + 33
        let segment = muLawBounds.firstIndex { $0 >= value } ?? 8
        guard segment < 8 else { return UInt8(0x7F ^ mask) }
        return UInt8((segment << 4 | (value >> (segment + 1)) & 0x0F) ^ mask)
    }

    public static func aLaw(_ samples: [Int16]) -> [UInt8] { samples.map(aLaw) }
    public static func muLaw(_ samples: [Int16]) -> [UInt8] { samples.map(muLaw) }
}

/// IMA ADPCM (DVI-4) in the block layout of Microsoft's IMA ADPCM WAV (section 5.3): a block of `4 + n` bytes holds `2n + 1`
/// samples, the first of them as the block's predictor. The step index goes on from one block to the next.
public struct IMAADPCMEncoder: Sendable {
    static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060,
        1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484,
        7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]
    static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8]

    /// The step index the next block starts at: 0 for a Talk's first block.
    public private(set) var index: Int

    public init(index: Int = 0) {
        self.index = min(max(index, 0), 88)
    }

    /// The samples a block of `blockSize` bytes holds: 1025 for Reolink's 516.
    public static func samplesPerBlock(blockSize: Int) -> Int { (blockSize - 4) * 2 + 1 }

    /// One block of `samples` (an odd count, `2n + 1`; an even count is padded with a zero sample).
    public mutating func encodeBlock<Samples: Collection>(_ samples: Samples) -> [UInt8] where Samples.Element == Int16 {
        guard let first = samples.first else { return [] }
        var block: [UInt8] = [UInt8(truncatingIfNeeded: UInt16(bitPattern: first)), UInt8(truncatingIfNeeded: UInt16(bitPattern: first) >> 8),
                              UInt8(index), 0]
        var predictor = Int32(first)
        var index = self.index
        var pending: UInt8?
        func encode(_ sample: Int16) -> UInt8 {
            var step = Self.stepTable[index]
            var difference = Int32(sample) - predictor
            var code: UInt8 = 0
            if difference < 0 {
                code = 8
                difference = -difference
            }
            var reconstructed = step >> 3
            if difference >= step {
                code |= 4
                difference -= step
                reconstructed += step
            }
            step >>= 1
            if difference >= step {
                code |= 2
                difference -= step
                reconstructed += step
            }
            step >>= 1
            if difference >= step {
                code |= 1
                reconstructed += step
            }
            predictor = code & 8 != 0 ? predictor - reconstructed : predictor + reconstructed
            predictor = min(max(predictor, Int32(Int16.min)), Int32(Int16.max))
            index = min(max(index + Self.indexTable[Int(code & 7)], 0), 88)
            return code
        }
        for sample in samples.dropFirst() {
            let code = encode(sample)
            if let low = pending {
                block.append(low | code << 4)
                pending = nil
            } else {
                pending = code
            }
        }
        if let low = pending { block.append(low | encode(0) << 4) }
        self.index = index
        return block
    }
}

/// HomeKit's Speaker Volume applied to samples (section 5.5): scaled by `volume / 100`, never amplified.
public enum PCMVolume {
    public static func scale(_ samples: [Int16], volume: Int) -> [Int16] {
        let volume = min(max(volume, 0), 100)
        guard volume < 100 else { return samples }
        return samples.map { Int16(Int($0) * volume / 100) }
    }
}

/// Cuts an ADTS byte stream into whole frames at its sync words (section 5.4): 12 bits `0xFFF`, the frame's length in the
/// 13 bits from bit 30 of the header. Bytes before a sync word are skipped.
public struct ADTSFrameSplitter: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func push(_ bytes: some Sequence<UInt8>) -> [[UInt8]] {
        buffer.append(contentsOf: bytes)
        var frames: [[UInt8]] = []
        var start = 0
        while buffer.count - start >= 7 {
            guard buffer[start] == 0xFF, buffer[start + 1] & 0xF0 == 0xF0 else {
                start += 1
                continue
            }
            let length = Int(buffer[start + 3] & 0x03) << 11 | Int(buffer[start + 4]) << 3 | Int(buffer[start + 5]) >> 5
            guard length >= 7 else {
                start += 1
                continue
            }
            guard buffer.count - start >= length else { break }
            frames.append(Array(buffer[start..<(start + length)]))
            start += length
        }
        buffer.removeFirst(start)
        return frames
    }

    /// The access unit of an ADTS frame: the frame without its 7-byte header (9 with a CRC).
    public static func payload(of frame: [UInt8]) -> ArraySlice<UInt8> {
        guard frame.count >= 7 else { return [] }
        let header = frame[1] & 0x01 == 0 ? 9 : 7
        return frame.count >= header ? frame[header...] : []
    }
}

/// AAC-LC in ADTS from PCM, through a second FFmpeg (section 5.4): frames go to its standard input as they come, ADTS frames
/// come out of `frames`, which ends when FFmpeg does (after `finish()`, or when it fails).
public final class AACTalkEncoder: Sendable {
    /// `sampleRate` is the PCM's; `outputRate`, when another, the AAC's, FFmpeg resampling.
    public static func arguments(sampleRate: Int, outputRate: Int? = nil, debug: Bool = false) -> [String] {
        ["-hide_banner", "-loglevel", debug ? "level+verbose" : "error", "-f", "s16le", "-ar", "\(sampleRate)", "-ac", "1", "-i", "pipe:0"]
            + (outputRate.map { $0 == sampleRate ? [] : ["-ar", "\($0)"] } ?? [])
            + ["-c:a", "aac", "-profile:a", "aac_low", "-b:a", "32k", "-f", "adts", "-flush_packets", "1", "pipe:1"]
    }

    public let frames: AsyncStream<[UInt8]>
    private let process: FfmpegProcess

    /// Starts FFmpeg; nil when it cannot.
    public init?(ffmpeg: RTSPCameraFFmpeg, sampleRate: Int, outputRate: Int? = nil, debug: Bool = false) {
        let process = FfmpegProcess(ffmpeg.options, commandLineArgs: Self.arguments(sampleRate: sampleRate, outputRate: outputRate, debug: debug))
        let (frames, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        process.start()
        let splitter = NIOLockedSplitter()
        guard process.onStdout({ chunk in for frame in splitter.push(chunk) { continuation.yield(frame) } }) != nil,
              process.onceExit({ _ in continuation.finish() }) else {
            continuation.finish()
            return nil
        }
        self.process = process
        self.frames = frames
    }

    public func write(_ samples: [Int16]) async throws {
        // s16le: the samples' own bytes on a little-endian host, swapped on a big-endian one.
        #if _endian(little)
        let data = samples.withUnsafeBytes { Data($0) }
        #else
        let data = samples.map(\.littleEndian).withUnsafeBytes { Data($0) }
        #endif
        try await process.writeStdin(data)
    }

    /// Closes FFmpeg's input: it writes what it has and ends.
    public func finish() { process.endStdin() }

    public func stop() { process.stop() }
}

private final class NIOLockedSplitter: Sendable {
    private let splitter = NIOLockedValueBox(ADTSFrameSplitter())
    func push(_ data: Data) -> [[UInt8]] { splitter.withLockedValue { $0.push(data) } }
}
