import Foundation

// Speech for a camera's speaker, as PCM: HomeKit's return audio once FFmpeg decoded it (HomeswiftFFmpeg's ReturnAudio.swift),
// or the web UI's microphone button (`HomeswiftPlugin.talk`). A plugin takes both through the same `Talk`.

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

extension PCMFrame {
    /// The samples as signed 16-bit little-endian bytes: FFmpeg's `s16le`.
    public var s16le: Data { samples.s16le }
}

extension Array where Element == Int16 {
    /// Signed 16-bit little-endian bytes, FFmpeg's `s16le`: the samples' own bytes on a little-endian host, swapped on a
    /// big-endian one.
    public var s16le: Data {
        #if _endian(little)
        withUnsafeBytes { Data($0) }
        #else
        map(\.littleEndian).withUnsafeBytes { Data($0) }
        #endif
    }
}

/// One continuous period during which HomeKit sends return audio, or the web UI's microphone is on; `frames` finishes when it
/// ends. `volume` is the Speaker's
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
