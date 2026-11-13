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
// - `GET /api/cameras/<accessory id>/controls` answers the camera's `CameraControls` (directions, presets, home) and,
//   for a camera with a speaker, `talk` (CameraTalk.swift); 404 for a camera that neither moves nor talks.
//   `POST /api/cameras/<accessory id>/control` with `{"move": "left"}`, `{"preset": "<id>"}` or `{"home": true}` moves
//   it, for any signed-in user, as controlling an accessory.
//
// They are API routes, so they need a signed-in user, and they refuse while the camera is off in the Home app.

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

/// The snapshot each camera is taking: a request while one is under way waits for it, whatever size it asked for,
/// rather than starting another (an FFmpeg each, for many plugins), so tabs and scripts cannot pile them up.
final class CameraSnapshots: Sendable {
    private let running = NIOLockedValueBox<[String: Task<Data, any Error>]>([:])

    func take(_ id: String, _ make: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let task = running.withLockedValue { running in
            if let task = running[id] { return task }
            let task = Task { try await make() }
            running[id] = task
            return task
        }
        defer { running.withLockedValue { if $0[id] == task { $0[id] = nil } } }
        return try await task.value
    }
}

extension UIServer {
    /// Headers that keep a proxy or the browser from replaying old frames.
    static let noCache = ["Cache-Control": "no-store, no-cache, must-revalidate", "Pragma": "no-cache"]

    /// A camera the routes may reach: its controller and name, or the reply that refuses it.
    func reachableCamera(_ id: String) -> Result<(camera: CameraController, name: String), ReplyError> {
        guard let found = catalog.find(id: id), let camera = found.accessory.cameraController else { return .failure(ReplyError(404, "no camera \(id)")) }
        let name = found.accessory.name
        // A paused plugin's camera: nothing reaches the device, as HomeKit's snapshots get No Response.
        guard !found.accessory.isUnavailable else { return .failure(ReplyError(503, "\(name) is paused: its plugin does not run")) }
        guard camera.isHomeKitCameraActive else { return .failure(ReplyError(409, "\(name) is turned off in the Home app")) }
        return .success((camera, name))
    }

    func camera(_ id: String, _ action: String, _ request: Request, username: String) async -> Reply {
        let camera: CameraController, name: String
        switch reachableCamera(id) {
        case .success(let found): (camera, name) = found
        case .failure(let refusal): return .error(refusal.status, refusal.message)
        }
        switch action {
        case "snapshot":
            // The card asks for its own size; 16:9 when it gives only a width.
            let width = min(max(request.query["width"].flatMap { Int($0) } ?? 1280, 64), 3840)
            let height = min(max(request.query["height"].flatMap { Int($0) } ?? width * 9 / 16, 36), 2160)
            do {
                let image = try await cameraSnapshots.take(id) { try await camera.previewSnapshot(width: width, height: height) }
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
        case "controls":
            // What the live view's buttons can do: pan and tilt, and the microphone (`talk`, the rate it sends at).
            let controls = await catalog.host.cameraControls(accessoryID: id)
            let talk = await catalog.host.talkFormat(accessoryID: id)
            guard controls != nil || talk != nil else { return .error(404, "\(name) neither moves nor has a speaker") }
            do {
                var answer = try JSONValue(encoding: controls ?? CameraControls(directions: [], presets: [], home: false)).objectValue ?? [:]
                if let talk { answer["talk"] = ["sampleRate": .number(Double(talk.sampleRate))] }
                return .json(.object(answer), headers: Self.noCache)
            } catch {
                return .error(500, "\(error)")
            }
        default:
            return .error(404, "unknown camera route \(action)")
        }
    }

    /// Moves a camera from its live view: one step in a direction, a preset or home.
    func controlCamera(_ id: String, _ body: JSONValue, username: String) async -> Reply {
        let name: String
        switch reachableCamera(id) {
        case .success(let found): name = found.name
        case .failure(let refusal): return .error(refusal.status, refusal.message)
        }
        let command: CameraCommand
        if let move = body["move"]?.stringValue {
            guard let direction = CameraControls.Direction(rawValue: move) else { return .error(400, "move must be up, down, left or right") }
            command = .move(direction)
        } else if let preset = body["preset"]?.stringValue ?? body["preset"]?.saturatingIntValue.map(String.init) {
            command = .preset(preset)
        } else if body["home"]?.boolValue == true {
            command = .home
        } else {
            return .error(400, "give move, preset or home")
        }
        do {
            try await catalog.host.controlCamera(accessoryID: id, command)
            logger.info("Web UI user \(username) moved \(name)", metadata: ["command": "\(command)"])
            return .json(JSONValue.object([:]))
        } catch let error as CameraControlError {
            return .error(400, error.description)
        } catch {
            logger.debug("Web UI camera control failed", metadata: ["accessory": "\(name)", "error": "\(error)"])
            return .error(502, "\(name) did not move: \(error)")
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

/// A route's refusal, before its reply is built.
struct ReplyError: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}
