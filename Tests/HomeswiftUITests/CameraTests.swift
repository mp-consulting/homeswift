import Foundation
import Homeswift
import HomeswiftMCP
import HomeswiftPlugin
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import HomeswiftUI

/// A camera's streaming side that answers snapshots with a fixed JPEG.
final class StillCamera: CameraStreamingDelegate, @unchecked Sendable {
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9])
    let snapshots = NIOLockedValueBox<[SnapshotRequest]>([])

    func handleSnapshotRequest(_ request: SnapshotRequest) async throws -> Data {
        snapshots.withLockedValue { $0.append(request) }
        return Self.jpeg
    }

    func prepareStream(_ request: PrepareStreamRequest) async throws -> PrepareStreamResponse {
        PrepareStreamResponse(video: .init(port: 50000, ssrc: 1))
    }

    func handleStreamRequest(_ request: StreamingRequest) async throws {}
}

/// What the tests feed a live view with, and how often a viewer left.
final class FeedSource: @unchecked Sendable {
    static let initSegment = Data("ftyp…moov".utf8)
    let continuations = NIOLockedValueBox<[AsyncThrowingStream<Data, any Error>.Continuation]>([])
    let cancellations = NIOLockedValueBox(0)

    func feed() -> CameraLiveFeed {
        let (fragments, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        continuations.withLockedValue { $0.append(continuation) }
        return CameraLiveFeed(mimeType: #"video/mp4; codecs="avc1.4d4028""#, initSegment: Self.initSegment, fragments: fragments) { [self] in
            cancellations.withLockedValue { $0 += 1 }
            continuation.finish()
        }
    }

    func push(_ data: Data) {
        continuations.withLockedValue { $0.last }?.yield(data)
    }
}

/// A plugin with a camera that has a live feed, one that has snapshots only, and a lamp.
actor CameraPlugin: HomeswiftPlugin {
    struct Configuration: Decodable, Sendable {}
    static let platform = "Cams"
    let context: PluginContext
    let source: FeedSource
    let delegate: StillCamera

    init(configuration: Configuration, context: PluginContext) { self.init(context: context, source: FeedSource(), delegate: StillCamera()) }
    init(context: PluginContext, source: FeedSource, delegate: StillCamera) {
        self.context = context
        self.source = source
        self.delegate = delegate
    }

    func start() async throws {
        let options = CameraStreamingOptions(video: VideoStreamingOptions(
            codec: H264CodecParameters(profiles: [.main], levels: [.level4_0]), resolutions: [VideoResolution(1280, 720, 30)]))
        for id in ["door", "still"] {
            let camera = try CameraController(CameraControllerOptions(cameraStreamCount: 2, delegate: delegate, streamingOptions: options))
            let accessory = Accessory(id: "Cams:\(id)", name: id == "door" ? "Front Door" : "Garden", category: .ipCamera, services: [Service(.motionSensor, isPrimary: true)])
            accessory.configureController(camera)
            try context.add(accessory)
        }
        try context.add(Accessory(id: "Cams:lamp", name: "Lamp", category: .lightbulb, services: [Service(.lightbulb, isPrimary: true)]))
    }

    func liveFeed(accessoryID: String) async throws -> CameraLiveFeed? {
        accessoryID == "Cams:door" ? source.feed() : nil
    }
}

final class CameraUIEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-camera-ui-tests-\(UUID().uuidString)")
    let source = FeedSource()
    let delegate = StillCamera()
    let host: PluginHost
    let server: UIServer

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = """
            { "bridge": { "name": "Camera Bridge", "username": "0E:11:22:33:44:77", "pin": "031-45-154", "port": 0 },
              "platforms": [ { "platform": "Cams", "name": "Cams" }, { "platform": "HomeswiftUI", "port": 0 } ] }
            """
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        var registry = PluginRegistry()
        let source = source, delegate = delegate
        registry.register(platform: CameraPlugin.platform, name: CameraPlugin.platform) { _, context in CameraPlugin(context: context, source: source, delegate: delegate) }
        var options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        options.systemPlatforms.insert(UIConfiguration.platform)
        host = try PluginHost(configuration: try HomeswiftConfiguration.decode(Data(config.utf8)), registry: registry, storageDirectory: directory, options: options)
        let catalog = HomeswiftCatalog(host: host, logs: LogBuffer(), configURL: directory.appendingPathComponent("config.json"), restart: {}, logger: testLogger)
        var configuration = UIConfiguration()
        configuration.host = "127.0.0.1"
        configuration.port = 0
        var serverOptions = UIServer.Options()
        serverOptions.hashIterations = 1000
        serverOptions.logger = testLogger
        server = UIServer(configuration: configuration, catalog: catalog, usersURL: directory.appendingPathComponent("ui-users.json"), options: serverOptions)
    }

    func start() async throws -> URL {
        try await host.start()
        try await server.start()
        return URL(string: "http://127.0.0.1:\(server.port!)")!
    }

    func stop() async {
        await server.stop()
        await host.stop()
    }

    /// A signed-in browser.
    func signedIn(_ base: URL) throws -> Browser {
        try server.users.createFirst(username: "rosaly", password: "correct horse battery staple")
        let browser = Browser(base: base)
        browser.cookie = "\(UIServer.cookieName)=\(server.sessions.create(username: "rosaly"))"
        return browser
    }
}

/// A raw HTTP/1.1 connection that hands over the response as it arrives, for chunked bodies URLSession on Linux
/// cannot stream.
final class StreamingClient: @unchecked Sendable {
    private final class Collector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let continuation: AsyncStream<Data>.Continuation
        init(_ continuation: AsyncStream<Data>.Continuation) { self.continuation = continuation }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { continuation.yield(Data(bytes)) }
        }
        func channelInactive(context: ChannelHandlerContext) { continuation.finish() }
    }

    let channel: any Channel
    private var iterator: AsyncStream<Data>.Iterator
    private var buffer = Data()

    init(port: Int, path: String, cookie: String?) async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Collector(continuation)) } }
            .connect(host: "127.0.0.1", port: port).get()
        iterator = stream.makeAsyncIterator()
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n" + (cookie.map { "Cookie: \($0)\r\n" } ?? "") + "\r\n"
        try await channel.writeAndFlush(ByteBuffer(string: request)).get()
    }

    private func fill() async -> Bool {
        guard let more = await iterator.next() else { return false }
        buffer += more
        return true
    }

    /// The status and the headers, lowercased.
    func head() async -> (status: Int, headers: [String: String])? {
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil { guard await fill() else { return nil } }
        let end = buffer.range(of: Data("\r\n\r\n".utf8))!
        let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        buffer = Data(buffer[end.upperBound...])
        let status = Int(lines[0].split(separator: " ")[1]) ?? 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (status, headers)
    }

    /// The next chunk of a chunked body; nil at its end or when the connection closes.
    func chunk() async -> Data? {
        while buffer.range(of: Data("\r\n".utf8)) == nil { guard await fill() else { return nil } }
        let line = buffer.range(of: Data("\r\n".utf8))!
        guard let size = Int(String(decoding: buffer[..<line.lowerBound], as: UTF8.self), radix: 16) else { return nil }
        let start = buffer.distance(from: buffer.startIndex, to: line.upperBound)
        while buffer.count < start + size + 2 { guard await fill() else { return nil } }
        guard size > 0 else { return nil }
        let chunk = Data(buffer[(buffer.startIndex + start)..<(buffer.startIndex + start + size)])
        buffer = Data(buffer[(buffer.startIndex + start + size + 2)...])
        return chunk
    }

    func close() async { try? await channel.close() }
}

@Suite(.timeLimit(.minutes(1)), .serialized)
struct CameraUITests {
    @Test func marksCamerasAndHidesHomeKitsPlumbing() async throws {
        let environment = try CameraUIEnvironment()
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = try environment.signedIn(base)
        let accessories = try #require(try await browser.get("/api/accessories").json?.arrayValue)
        let door = try #require(accessories.first { $0["id"] == "Cams:door" })
        #expect(door["camera"] == true)
        #expect(accessories.first { $0["id"] == "Cams:lamp" }?["camera"] == nil)
        let services = door["services"]?.arrayValue ?? []
        let streams = services.filter { $0["type"] == "CameraRTPStreamManagement" }
        #expect(streams.count == 2 && streams.allSatisfy { $0["internal"] == true })
        #expect(services.first { $0["type"] == "MotionSensor" }?["internal"] == nil)
        // TLV8 values are not text: null, internal, with their size.
        let configuration = try #require(streams.first?["characteristics"]?.arrayValue?.first { $0["type"] == "Supported Video Stream Configuration" })
        #expect(configuration["value"] == .null && configuration["internal"] == true && (configuration["bytes"]?.doubleValue ?? 0) > 10)
        // The MCP view of the same accessory leaves them out of its values.
        let catalog = environment.server.catalog
        let summary = HomeswiftCatalog.accessoryJSON(try #require(catalog.find(id: "Cams:door")), detailed: false)
        let values = summary["services"]?.arrayValue?.first { $0["type"] == "CameraRTPStreamManagement" }?["values"]?.objectValue ?? [:]
        #expect(values["Supported Video Stream Configuration"] == nil && values["Active"] != nil)
    }

    @Test func snapshotsForSignedInUsers() async throws {
        let environment = try CameraUIEnvironment()
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        #expect(try await Browser(base: base).get("/api/cameras/Cams:door/snapshot").status == 401)
        let browser = try environment.signedIn(base)
        let snapshot = try await browser.get("/api/cameras/Cams:door/snapshot?width=640")
        #expect(snapshot.status == 200)
        #expect(snapshot.headers["content-type"] == "image/jpeg")
        #expect(snapshot.headers["cache-control"]?.contains("no-store") == true)
        #expect(Data(snapshot.body.utf8).count > 0)
        #expect(environment.delegate.snapshots.withLockedValue { $0.last } == SnapshotRequest(height: 360, width: 640))
        // Sizes stay sane.
        _ = try await browser.get("/api/cameras/Cams:door/snapshot?width=99999&height=1")
        #expect(environment.delegate.snapshots.withLockedValue { $0.last } == SnapshotRequest(height: 36, width: 3840))
        #expect(try await browser.get("/api/cameras/Cams:lamp/snapshot").status == 404)
        #expect(try await browser.get("/api/cameras/Cams:nope/snapshot").status == 404)
        // The page may play blob: media from MediaSource and show blob: snapshots.
        let page = try await browser.get("/")
        #expect(page.headers["content-security-policy"]?.contains("media-src 'self' blob:") == true)
        #expect(page.headers["content-security-policy"]?.contains("img-src 'self' data: blob:") == true)
    }

    @Test func streamsTheLiveFeedUntilTheBrowserLeaves() async throws {
        let environment = try CameraUIEnvironment()
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let port = environment.server.port!

        // Signed out: nothing, and no feed was asked for.
        let anonymous = try await StreamingClient(port: port, path: "/api/cameras/Cams:door/live", cookie: nil)
        #expect(await anonymous.head()?.status == 401)
        await anonymous.close()
        #expect(environment.source.continuations.withLockedValue { $0.count } == 0)

        let browser = try environment.signedIn(base)
        let client = try await StreamingClient(port: port, path: "/api/cameras/Cams:door/live", cookie: browser.cookie)
        let head = try #require(await client.head())
        #expect(head.status == 200)
        #expect(head.headers["content-type"] == "video/mp4")
        #expect(head.headers["x-camera-mime-type"] == #"video/mp4; codecs="avc1.4d4028""#)
        #expect(head.headers["transfer-encoding"] == "chunked")
        #expect(head.headers["cache-control"]?.contains("no-store") == true)
        // The initialization segment first, then the fragments in order.
        #expect(await client.chunk() == FeedSource.initSegment)
        for index in 1...3 { environment.source.push(Data("moof+mdat \(index)".utf8)) }
        for index in 1...3 { #expect(await client.chunk() == Data("moof+mdat \(index)".utf8)) }
        #expect(environment.server.cameraViewers.count("Cams:door") == 1)

        // The browser leaves: the feed is cancelled and the viewer counted out. The server notices at its next write (NIO's
        // HTTP pipeline reads nothing more while a response is under way), and the camera keeps sending.
        await client.close()
        #expect(await eventually {
            environment.source.push(Data("moof+mdat".utf8))
            return environment.source.cancellations.withLockedValue { $0 } == 1
        })
        #expect(await eventually { environment.server.cameraViewers.count("Cams:door") == 0 })
    }

    @Test func refusesWhatItCannotStream() async throws {
        let environment = try CameraUIEnvironment()
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = try environment.signedIn(base)
        // A camera without a live feed: its card shows snapshots.
        #expect(try await browser.get("/api/cameras/Cams:still/live").status == 404)
        #expect(environment.server.cameraViewers.count("Cams:still") == 0)
        #expect(try await browser.get("/api/cameras/Cams:lamp/live").status == 404)
        #expect(try await browser.get("/api/cameras/Cams:door/elsewhere").status == 404)
        // A paused plugin's camera: no snapshot or feed reaches it.
        let door = try #require(environment.server.catalog.find(id: "Cams:door")).accessory
        let asked = environment.delegate.snapshots.withLockedValue { $0.count }
        door.isUnavailable = true
        #expect(try await browser.get("/api/cameras/Cams:door/snapshot").status == 503)
        #expect(try await browser.get("/api/cameras/Cams:door/live").status == 503)
        #expect(environment.delegate.snapshots.withLockedValue { $0.count } == asked)
        #expect(environment.source.continuations.withLockedValue { $0.count } == 0)
        door.isUnavailable = false
        // Enough viewers already.
        for _ in 0..<CameraViewers.limit { #expect(environment.server.cameraViewers.enter("Cams:door")) }
        #expect(try await browser.get("/api/cameras/Cams:door/live").status == 429)
        #expect(environment.source.continuations.withLockedValue { $0.count } == 0)
    }
}

/// Polls until `condition` holds, for up to thirty seconds.
/// A ceiling, not a wait: it returns as soon as the condition holds, and a loaded CI runner can take seconds.
func eventually(_ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
