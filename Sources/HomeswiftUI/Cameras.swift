import Foundation
import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

// The camera cards of the Accessories page: a snapshot of any camera, and the live feed of a plugin that has one.
//
// - `GET /api/cameras/<accessory id>/snapshot?width=&height=` answers a JPEG from the camera's streaming delegate.
// - `GET /api/cameras/<accessory id>/live` answers `video/mp4`, chunked: the fMP4 initialization segment, then each
//   fragment as the camera sends it, for Media Source Extensions. `X-Camera-Mime-Type` carries the type and codecs
//   for `addSourceBuffer`. The feed stops when the browser disconnects; a camera has at most
//   `CameraViewers.limit` viewers at once.
//
// Both are API routes, so they need a signed-in user, and both refuse while the camera is off in the Home app.

/// A chunked body for `UIServer.Reply.media`: what comes first, the rest as it comes, and what ends it.
struct MediaStream: Sendable {
    var contentType: String
    var headers: [String: String]
    var first: Data
    var rest: AsyncThrowingStream<Data, any Error>
    /// Runs once the body ended, whoever ended it.
    var finished: @Sendable () -> Void
}

/// The live viewers of each camera, so ten tabs cannot pull ten streams from one camera.
final class CameraViewers: Sendable {
    static let limit = 4
    private let counts = NIOLockedValueBox<[String: Int]>([:])

    /// Counts a viewer in; false when the camera has `limit` already.
    func enter(_ id: String) -> Bool {
        counts.withLockedValue { counts in
            guard counts[id, default: 0] < Self.limit else { return false }
            counts[id, default: 0] += 1
            return true
        }
    }

    func leave(_ id: String) {
        counts.withLockedValue { counts in
            let remaining = counts[id, default: 0] - 1
            counts[id] = remaining > 0 ? remaining : nil
        }
    }

    func count(_ id: String) -> Int { counts.withLockedValue { $0[id] ?? 0 } }
}

extension UIServer {
    /// Headers that keep a proxy or the browser from replaying old frames.
    static let noCache = ["Cache-Control": "no-store, no-cache, must-revalidate", "Pragma": "no-cache"]

    func camera(_ id: String, _ action: String, _ request: Request, username: String) async -> Reply {
        guard let found = catalog.find(id: id), let camera = found.accessory.cameraController else { return .error(404, "no camera \(id)") }
        let name = found.accessory.name
        // A paused plugin's camera: nothing reaches the device, as HomeKit's snapshots get No Response.
        guard !found.accessory.isUnavailable else { return .error(503, "\(name) is paused: its plugin does not run") }
        guard camera.isHomeKitCameraActive else { return .error(409, "\(name) is turned off in the Home app") }
        switch action {
        case "snapshot":
            // The card asks for its own size; 16:9 when it gives only a width.
            let width = min(max(request.query["width"].flatMap { Int($0) } ?? 1280, 64), 3840)
            let height = min(max(request.query["height"].flatMap { Int($0) } ?? width * 9 / 16, 36), 2160)
            do {
                let image = try await camera.previewSnapshot(width: width, height: height)
                return .data(status: 200, contentType: "image/jpeg", body: image, headers: Self.noCache)
            } catch {
                logger.debug("Web UI snapshot failed", metadata: ["accessory": "\(name)", "error": "\(error)"])
                return .error(502, "\(name) gave no snapshot: \(error)")
            }
        case "live":
            guard cameraViewers.enter(id) else { return .error(429, "\(name) has \(CameraViewers.limit) viewers already") }
            let feed: CameraLiveFeed?
            do {
                feed = try await catalog.host.liveFeed(accessoryID: id)
            } catch {
                cameraViewers.leave(id)
                logger.debug("Web UI live feed failed", metadata: ["accessory": "\(name)", "error": "\(error)"])
                return .error(502, "\(name) gave no live video: \(error)")
            }
            guard let feed else {
                cameraViewers.leave(id)
                return .error(404, "\(name) has no live feed; its card shows snapshots")
            }
            logger.debug("Web UI live view started", metadata: ["accessory": "\(name)", "user": "\(username)", "type": "\(feed.mimeType)"])
            let viewers = cameraViewers, logger = logger
            var headers = Self.noCache
            headers["X-Camera-Mime-Type"] = feed.mimeType
            return .media(MediaStream(contentType: "video/mp4", headers: headers, first: feed.initSegment, rest: feed.fragments) {
                feed.cancel()
                viewers.leave(id)
                logger.debug("Web UI live view ended", metadata: ["accessory": "\(name)", "user": "\(username)"])
            })
        default:
            return .error(404, "unknown camera route \(action)")
        }
    }
}

extension UIRequestHandler {
    /// Writes a chunked body, each chunk once the previous one is out, so a slow browser slows the reading rather
    /// than filling memory; a disconnect cancels the reading. NIO's HTTP pipeline reads nothing while a response
    /// is under way, so a browser that left shows at the next write, a fragment later.
    static func writeMedia(_ media: MediaStream, head: HTTPResponseHead, to channel: any Channel) async {
        var head = head
        head.headers.add(name: "Content-Type", value: media.contentType)
        head.headers.add(name: "Connection", value: "close")
        for (name, value) in media.headers { head.headers.replaceOrAdd(name: name, value: value) }
        let pump = Task {
            try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
            try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: media.first)))).get()
            for try await chunk in media.rest {
                try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: chunk)))).get()
            }
            try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        }
        channel.closeFuture.whenComplete { _ in pump.cancel() }
        _ = await pump.result
        media.finished()
        channel.close(promise: nil)
    }
}
