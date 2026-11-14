import Foundation
import Homeswift
import HomeswiftFFmpeg
import HomeswiftPlugin

// The web UI's live view of a camera (docs/plugins.md, "Live video in the web UI"): FFmpeg copies the source's video into
// fragmented MP4 while a card is on screen, and stops when it leaves. The source's own codec is sent, so a camera whose
// video is not H.264 or H.265 (MJPEG) keeps its snapshots only.
extension IPCamerasPlugin {
    /// How long a viewer waits for the first picture.
    static let liveFeedTimeout: Duration = .seconds(15)

    public func liveFeed(accessoryID: String) async throws -> CameraLiveFeed? {
        guard let runtime = runtime(accessoryID), runtime.controller.isHomeKitCameraActive else { return nil }
        return try await runtime.streamer.liveFeed(timeout: Self.liveFeedTimeout)
    }

    /// A camera with a `returnAudioTarget` takes the web UI's microphone, at 16 kHz.
    public func talkFormat(accessoryID: String) async -> ReturnAudioFormat? {
        guard let runtime = runtime(accessoryID), runtime.streamer.video.returnAudioTarget != nil else { return nil }
        return ReturnAudioFormat(sampleRate: 16000)
    }

    public func talk(accessoryID: String, _ talk: Talk) async throws {
        guard let runtime = runtime(accessoryID) else { throw CameraControlError("no camera with that id") }
        guard runtime.streamer.video.returnAudioTarget != nil else { throw CameraControlError("this camera has no returnAudioTarget") }
        try await runtime.streamer.talk(talk)
    }

    private func runtime(_ accessoryID: String) -> CameraRuntime? {
        cameras.values.first { $0.accessory.id == accessoryID }
    }
}

extension CameraStreamer {
    struct LiveFeedFailure: Error, CustomStringConvertible {
        var description: String { "FFmpeg sent no video for the live view" }
    }

    /// An FFmpeg remuxing the source for one viewer.
    func liveFeed(timeout: Duration) async throws -> CameraLiveFeed {
        let process = FfmpegProcess(tools.options, commandLineArgs: FFmpegArguments.liveFeed(video))
        let (chunks, chunksContinuation) = AsyncStream.makeStream(of: Data.self)
        process.start()
        guard process.onStdout({ chunksContinuation.yield($0) }) != nil, process.onceExit({ _ in chunksContinuation.finish() }) else {
            process.stop()
            throw LiveFeedFailure()
        }
        let id = ObjectIdentifier(process)
        liveViews[id] = process
        return try await Self.liveFeed(from: chunks, timeout: timeout, log: log) { [weak self] in
            process.stop()
            Task { await self?.forgetLiveView(id) }
        }
    }

    /// How long FFmpeg has to send what it holds once a Talk from the web UI ended.
    static let talkDrainTimeout: Duration = .seconds(3)

    /// The web UI's microphone to `returnAudioTarget`: each frame into FFmpeg as it comes, until the Talk ends and FFmpeg
    /// has sent the rest.
    func talk(_ talk: Talk) async throws {
        let process = FfmpegProcess(tools.returnOptions, commandLineArgs: FFmpegArguments.webTalk(video, sampleRate: talk.format.sampleRate))
        let (exited, exit) = AsyncStream.makeStream(of: Never.self)
        process.start()
        guard process.onceExit({ [log] status in
            log.debug("Two-way audio from the web UI ended (\(status)).")
            exit.finish()
        }) else { throw CameraControlError("FFmpeg did not start") }
        log.info("Two-way audio from the web UI started.")
        for await frame in talk.frames {
            guard process.isStdinWritable else { break }
            do { try await process.writeStdin(frame.s16le) } catch { break }
        }
        process.finish()
        _ = try? await withTimeout(Self.talkDrainTimeout) { for await _ in exited {} }
        process.stop()
    }

    func forgetLiveView(_ id: ObjectIdentifier) {
        liveViews.removeValue(forKey: id)
    }

    /// A live feed from fragmented MP4 as it comes: the initialization segment once it is there (within `timeout`), then
    /// each `moof` + `mdat`. A viewer slower than the camera loses the oldest fragments, not the bridge's memory.
    static func liveFeed(from chunks: AsyncStream<Data>, timeout: Duration, log: CameraLog, onCancel: @escaping @Sendable () -> Void) async throws -> CameraLiveFeed {
        let (fragments, continuation) = AsyncThrowingStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(64))
        let (initialization, initContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1))
        let reader = Task {
            var boxes = MP4BoxReader()
            var fragmenter = RecordingFragmenter()
            var initialized = false
            do {
                for await chunk in chunks {
                    for box in try boxes.push(chunk) {
                        guard let packet = fragmenter.add(box) else { continue }
                        if initialized {
                            continuation.yield(packet)
                        } else {
                            initialized = true
                            initContinuation.yield(packet)
                            initContinuation.finish()
                        }
                    }
                }
                continuation.finish()
            } catch {
                log.error("Live view: \(error)")
                continuation.finish(throwing: error)
            }
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
            onCancel()
            throw LiveFeedFailure()
        }
        return CameraLiveFeed(initSegment: initSegment, fragments: fragments) {
            reader.cancel()
            onCancel()
        }
    }
}
