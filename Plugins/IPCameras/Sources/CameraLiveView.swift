import Foundation
import Homeswift
import HomeswiftFFmpeg

// The web UI's live view of a camera (docs/plugins.md, "Live video in the web UI"): FFmpeg copies the source's video into
// fragmented MP4 while a card is on screen, and stops when it leaves. The source's own codec is sent, so a camera whose
// video is not H.264 or H.265 (MJPEG) keeps its snapshots only.
extension IPCamerasPlugin {
    /// How long a viewer waits for the first picture.
    static let liveFeedTimeout: Duration = .seconds(15)

    public func liveFeed(accessoryID: String) async throws -> CameraLiveFeed? {
        guard let runtime = cameras.values.first(where: { $0.accessory.id == accessoryID }), runtime.controller.isHomeKitCameraActive else { return nil }
        return try await runtime.streamer.liveFeed(timeout: Self.liveFeedTimeout)
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
