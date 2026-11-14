import Foundation

#if canImport(Speech) && canImport(AVFAudio)
import AVFAudio
import os
import Speech
#endif

/// Apple's speech recognition on this Mac (macOS 26's `SpeechAnalyzer` and `SpeechTranscriber`): on the device, no key,
/// nothing sent anywhere. A language's model is downloaded by macOS the first time it is asked for, once; a command-line
/// process uses it without a permission prompt. Elsewhere (Linux, an earlier macOS) there is none, and the chat keeps the
/// browser's dictation.
public enum AppleTranscriber {
    /// Whether this Mac can run it.
    public static var isAvailable: Bool {
        #if canImport(Speech) && canImport(AVFAudio)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }

    /// The engine, or nil where it cannot run.
    public static func make() -> (any SpeechToText)? {
        #if canImport(Speech) && canImport(AVFAudio)
        if #available(macOS 26, *) { return OnDevice() }
        #endif
        return nil
    }

    #if canImport(Speech) && canImport(AVFAudio)
    @available(macOS 26, *)
    struct OnDevice: SpeechToText {
        func transcribe(pcm: Data, sampleRate: Int, language: String?) async throws -> String {
            let asked = language.map { Locale(identifier: $0) } ?? Locale.current
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: asked) else {
                throw ProviderError(provider: "transcription", message: "Apple's speech recognition does not know \(asked.identifier)")
            }
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            // A language used for the first time: macOS downloads its model, once.
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await installation.downloadAndInstall()
            }
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
                  let recording = Self.buffer(pcm, format: format) else {
                throw ProviderError(provider: "transcription", message: "the recording could not be read")
            }
            let wanted = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: format) ?? format
            let input = try Self.converted(recording, to: wanted)

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let words = Task {
                var text = ""
                for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }
                return text
            }
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            do {
                try await analyzer.start(inputSequence: stream)
                continuation.yield(AnalyzerInput(buffer: input))
                continuation.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                continuation.finish()
                words.cancel()
                await analyzer.cancelAndFinishNow()
                throw ProviderError(provider: "transcription", message: "Apple's speech recognition failed: \(error.localizedDescription)")
            }
            return try await words.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// The samples as an audio buffer.
        static func buffer(_ pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
            let frames = AVAudioFrameCount(pcm.count / 2)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channel = buffer.int16ChannelData?[0] else { return nil }
            buffer.frameLength = frames
            pcm.withUnsafeBytes { bytes in
                for index in 0..<Int(frames) { channel[index] = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)) }
            }
            return buffer
        }

        /// The buffer in the format the analyzer reads best: as it is when they match (16 kHz 16-bit mono, the page's).
        static func converted(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
            guard buffer.format != format else { return buffer }
            guard let converter = AVAudioConverter(from: buffer.format, to: format),
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1024) else {
                throw ProviderError(provider: "transcription", message: "the recording could not be converted for Apple's speech recognition")
            }
            // The converter asks for input from its own thread: the one buffer, then the end of it.
            let fed = OSAllocatedUnfairLock(initialState: false)
            var failure: NSError?
            converter.convert(to: output, error: &failure) { _, status in
                let first = fed.withLock { sent in
                    defer { sent = true }
                    return !sent
                }
                status.pointee = first ? .haveData : .endOfStream
                return first ? buffer : nil
            }
            if let failure { throw ProviderError(provider: "transcription", message: "the recording could not be converted: \(failure.localizedDescription)") }
            return output
        }
    }
    #endif
}
