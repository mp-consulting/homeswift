import Foundation
import Homeswift
import HomeswiftFFmpeg

// The web UI's live view of a lens (docs/plugins.md, "Live video in the web UI"): a viewer of the camera's feed, so it
// shares the session of HomeKit's streams, its lens filtered out (`MPEGTSLensFilter`) and transcoded by FFmpeg to a
// small H.264 in fragmented MP4 (browsers do not all play HEVC, and a card needs no 4K), with the camera's audio as AAC
// (`TapoFeedSplitter`, on `pipe:3`: FFmpeg misreads the TS's G.711). Like every view, it reaches the camera only while it
// lasts: the feed's session closes a few seconds after the card leaves the screen.
extension TapoPlugin {
    /// How long a viewer waits for the first picture: the camera may have to wake.
    static let liveFeedTimeout: Duration = .seconds(20)

    public func liveFeed(accessoryID: String) async throws -> CameraLiveFeed? {
        for runtime in cameraRuntimes.values {
            guard let camera = runtime.cameras.first(where: { $0.accessory.id == accessoryID }) else { continue }
            guard camera.controller.isHomeKitCameraActive else { return nil }
            return try await camera.streamer.liveFeed(timeout: Self.liveFeedTimeout)
        }
        return nil
    }
}

extension TapoCameraStreamer {
    struct LiveFeedFailure: Error, CustomStringConvertible {
        var description: String { "FFmpeg sent no video for the live view" }
    }

    /// FFmpeg's command line for the web UI: the lens's TS on standard input and the camera's audio as 16 kHz PCM on
    /// `pipe:3`, 640 x 360 H.264 and AAC-LC out as fragmented MP4. Both inputs have deep queues: FFmpeg keeps them in
    /// step, and the audio comes a jitter buffer's delay after its picture.
    static func liveFeedArguments() -> [String] {
        var arguments = ["-hide_banner", "-loglevel", "error", "-fflags", "+genpts+discardcorrupt+nobuffer", "-err_detect", "ignore_err"]
        #if os(macOS)
        arguments += ["-hwaccel", "videotoolbox"]
        #endif
        arguments += ["-probesize", "1M", "-analyzeduration", "500000", "-thread_queue_size", "1024", "-f", "mpegts", "-i", "pipe:0",
                      "-thread_queue_size", "1024", "-f", "s16le", "-ar", "\(TapoAudioConverter.outputRate)", "-ac", "1", "-i", "pipe:3",
                      "-map", "0:v:0", "-map", "1:a:0", "-sn", "-dn",
                      "-codec:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-pix_fmt", "yuv420p", "-profile:v", "main",
                      "-g", "15", "-b:v", "800k", "-maxrate", "1200k", "-bufsize", "1200k",
                      "-filter:v", "scale='min(640,iw)':'min(360,ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2",
                      "-codec:a", "aac", "-b:a", "64k", "-ar", "48000", "-ac", "1",
                      "-f", "mp4", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "pipe:1"]
        return arguments
    }

    /// A live feed for one web viewer: the initialization segment once FFmpeg wrote it (within `timeout`), then each
    /// `moof` + `mdat`. A viewer slower than the camera loses the oldest fragments, not the bridge's memory.
    func liveFeed(timeout: Duration) async throws -> CameraLiveFeed {
        let process = FfmpegProcess(ffmpeg, commandLineArgs: Self.liveFeedArguments(), extraInputs: 1)
        let (chunks, chunksContinuation) = AsyncStream.makeStream(of: Data.self)
        process.start()
        guard process.onStdout({ chunksContinuation.yield($0) }) != nil, process.onceExit({ _ in chunksContinuation.finish() }) else {
            process.stop()
            throw LiveFeedFailure()
        }
        let (viewer, stream) = await feed.join()
        let splitter = TapoFeedSplitter(videoIndex: videoIndex, audio: true, name: liveName, log: liveLog)
        // Never awaited: the audio waits for nothing, and what FFmpeg does not read is dropped.
        let audioClock = splitter.runAudio { pcm in process.send(pcm, toInput: 0) || process.isRunning }
        let pump = Task {
            let (video, writer) = Self.videoWriter(process)
            for await data in stream {
                let lens = splitter.split(data)
                guard !lens.isEmpty else { continue }
                if case .terminated = video.yield(lens) { break }
            }
            video.finish()
            writer.cancel()
            process.stop()
        }
        let feed = feed
        let release: @Sendable () -> Void = {
            pump.cancel()
            audioClock.cancel()
            process.stop()
            Task { await feed.leave(viewer) }
        }
        let (fragments, continuation) = AsyncThrowingStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(64))
        let (initialization, initContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1))
        let reader = Task {
            var boxes = FMp4BoxReader()
            var head = Data()
            var moof: Data?
            var initialized = false
            for await chunk in chunks {
                var boxesDone: [FMp4ParsedBox] = []
                guard boxes.push(chunk, { boxesDone.append($0) }) else {
                    continuation.finish(throwing: LiveFeedFailure())
                    initContinuation.finish()
                    return
                }
                for box in boxesDone {
                    let whole = box.header + box.data
                    switch box.type {
                    case BOX_TYPE_MOOF:
                        moof = whole
                    case BOX_TYPE_MDAT:
                        guard let start = moof else { continue }
                        moof = nil
                        continuation.yield(start + whole)
                    default:
                        guard !initialized else { continue }
                        head.append(whole)
                        if box.type == BOX_TYPE_MOOV {
                            initialized = true
                            initContinuation.yield(head)
                            initContinuation.finish()
                        }
                    }
                }
            }
            continuation.finish()
            initContinuation.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            initContinuation.finish()
        }
        var iterator = initialization.makeAsyncIterator()
        let initSegment = await iterator.next()
        timer.cancel()
        guard let initSegment else {
            reader.cancel()
            release()
            throw LiveFeedFailure()
        }
        return CameraLiveFeed(initSegment: initSegment, fragments: fragments) {
            reader.cancel()
            release()
        }
    }
}
