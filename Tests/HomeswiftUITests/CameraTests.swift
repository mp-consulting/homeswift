import Foundation
import Homeswift
import HomeswiftMCP
import HomeswiftNetwork
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

    /// What reached the door camera's speaker: the frames of each Talk, and how many Talks ended.
    let spoken = NIOLockedValueBox<[[PCMFrame]]>([])
    let talksEnded = NIOLockedValueBox(0)
    /// Talks that began while another was still playing.
    let overlaps = NIOLockedValueBox(0)
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

    /// Both cameras have a speaker at 8 kHz; the garden's gives up at once.
    func talkFormat(accessoryID: String) async -> ReturnAudioFormat? {
        accessoryID == "Cams:door" || accessoryID == "Cams:still" ? ReturnAudioFormat(sampleRate: 8000) : nil
    }

    func talk(accessoryID: String, _ talk: Talk) async throws {
        guard accessoryID == "Cams:door" else { throw CameraControlError("the speaker is unplugged") }
        let source = source
        let index = source.spoken.withLockedValue { $0.append([]); return $0.count - 1 }
        if index > source.talksEnded.withLockedValue({ $0 }) { source.overlaps.withLockedValue { $0 += 1 } }
        for await frame in talk.frames { source.spoken.withLockedValue { $0[index].append(frame) } }
        source.talksEnded.withLockedValue { $0 += 1 }
    }
}

final class CameraUIEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-camera-ui-tests-\(UUID().uuidString)")
    let source = FeedSource()
    let delegate = StillCamera()
    let host: PluginHost
    let server: UIServer

    /// `talkIdleTimeout`: the silence that ends a Talk, shortened for the tests that wait for it.
    init(talkIdleTimeout: Duration? = nil) throws {
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
        if let talkIdleTimeout { serverOptions.talkIdleTimeout = talkIdleTimeout }
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

@Suite(.timeLimit(.minutes(1)))
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
        #expect(page.headers["content-security-policy"]?.contains("img-src 'self' data: blob: https://tile.openstreetmap.org;") == true)
        #expect(page.headers["permissions-policy"]?.contains("geolocation=(self)") == true)
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

@Suite struct CameraTalkTests {
    /// A request's audio: signed 16-bit little-endian samples, in base64.
    static func pcm(_ samples: [Int16]) -> JSONValue {
        .string(Data(samples.flatMap { [UInt8(UInt16(bitPattern: $0) & 0xFF), UInt8(UInt16(bitPattern: $0) >> 8)] }).base64EncodedString())
    }

    @Test func playsTheMicrophoneOnTheCamerasSpeaker() async throws {
        let environment = try CameraUIEnvironment()
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = try environment.signedIn(base)
        browser.origin = "http://127.0.0.1:\(environment.server.port!)"
        // The live view learns the camera has a speaker, and its rate, from its controls; a lamp has none.
        let controls = try await browser.get("/api/cameras/Cams:door/controls")
        #expect(controls.status == 200)
        #expect(controls.json?["talk"]?["sampleRate"] == 8000)
        #expect(controls.json?["directions"]?.arrayValue?.isEmpty == true)
        #expect(try await browser.get("/api/cameras/Cams:lamp/controls").status == 404)

        // The browser must send at the camera's rate.
        #expect(try await browser.post("/api/cameras/Cams:door/talk", ["sampleRate": 16000]).status == 409)
        let start = try await browser.post("/api/cameras/Cams:door/talk", ["sampleRate": 8000])
        #expect(start.status == 200)
        #expect(start.json?["sampleRate"] == 8000)
        // The bridge names the Talk.
        let talk = try #require(start.json?["talk"]?.stringValue)

        // 20 ms frames at 8 kHz are 160 samples: a frame and a part, then the rest of the second frame; a request older
        // than one taken is dropped.
        let samples = (0..<320).map { Int16($0 * 50 - 8000) }
        #expect(try await browser.post("/api/cameras/Cams:door/talk/\(talk)", ["seq": 0, "pcm": Self.pcm(Array(samples[0..<250]))]).status == 200)
        #expect(try await browser.post("/api/cameras/Cams:door/talk/\(talk)", ["seq": 0, "pcm": Self.pcm(Array(samples[0..<250]))]).status == 200)
        #expect(try await browser.post("/api/cameras/Cams:door/talk/\(talk)", ["seq": 1, "pcm": Self.pcm(Array(samples[250...]))]).status == 200)
        // Someone else cannot talk on it meanwhile.
        _ = try environment.server.users.create(username: "linus", password: "correct horse battery staple")
        let other = Browser(base: base)
        other.cookie = "\(UIServer.cookieName)=\(environment.server.sessions.create(username: "linus"))"
        other.origin = browser.origin
        let refused = try await other.post("/api/cameras/Cams:door/talk", ["sampleRate": 8000])
        #expect(refused.status == 409)
        #expect(refused.json?["error"]?.stringValue?.contains("rosaly") == true)
        #expect(try await other.post("/api/cameras/Cams:door/talk/\(talk)", ["seq": 2, "pcm": Self.pcm([1])]).status == 410)

        #expect(try await browser.post("/api/cameras/Cams:door/talk/\(talk)", ["end": true]).status == 200)
        #expect(await eventually { environment.source.talksEnded.withLockedValue { $0 } == 1 })
        let frames = try #require(environment.source.spoken.withLockedValue { $0.first })
        #expect(frames.map(\.offset) == [0, 160])
        #expect(frames.flatMap(\.samples) == samples)
        // An ended Talk takes nothing more.
        #expect(try await browser.post("/api/cameras/Cams:door/talk/\(talk)", ["seq": 3, "pcm": Self.pcm([1])]).status == 410)
    }

    @Test func endsATalkThatFallsSilent() async throws {
        let environment = try CameraUIEnvironment(talkIdleTimeout: .milliseconds(200))
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = try environment.signedIn(base)
        browser.origin = "http://127.0.0.1:\(environment.server.port!)"
        let start = try await browser.post("/api/cameras/Cams:door/talk", ["sampleRate": 8000])
        let talk = try #require(start.json?["talk"]?.stringValue)
        #expect(try await browser.post("/api/cameras/Cams:door/talk/\(talk)", ["seq": 0, "pcm": Self.pcm(Array(repeating: 1, count: 160))]).status == 200)
        // Nothing more from the browser (a closed tab): the Talk ends, and the camera is free for someone else.
        #expect(await eventually { environment.source.talksEnded.withLockedValue { $0 } == 1 })
        #expect(try await browser.post("/api/cameras/Cams:door/talk/\(talk)", ["seq": 1, "pcm": Self.pcm([1])]).status == 410)
        _ = try environment.server.users.create(username: "linus", password: "correct horse battery staple")
        let other = Browser(base: base)
        other.cookie = "\(UIServer.cookieName)=\(environment.server.sessions.create(username: "linus"))"
        other.origin = browser.origin
        #expect(try await other.post("/api/cameras/Cams:door/talk", ["sampleRate": 8000]).status == 200)
    }

    @Test func playsTalksOneAfterTheOther() async throws {
        let environment = try CameraUIEnvironment()
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = try environment.signedIn(base)
        browser.origin = "http://127.0.0.1:\(environment.server.port!)"
        let first = try #require(try await browser.post("/api/cameras/Cams:door/talk", ["sampleRate": 8000]).json?["talk"]?.stringValue)
        // A second tab of the same user replaces the first: the plugin finishes the first before it gets the second.
        let second = try #require(try await browser.post("/api/cameras/Cams:door/talk", ["sampleRate": 8000]).json?["talk"]?.stringValue)
        #expect(first != second)
        #expect(try await browser.post("/api/cameras/Cams:door/talk/\(first)", ["seq": 0, "pcm": Self.pcm([1])]).status == 410)
        #expect(try await browser.post("/api/cameras/Cams:door/talk/\(second)", ["seq": 0, "pcm": Self.pcm(Array(repeating: 2, count: 160))]).status == 200)
        #expect(try await browser.post("/api/cameras/Cams:door/talk/\(second)", ["end": true]).status == 200)
        #expect(await eventually { environment.source.talksEnded.withLockedValue { $0 } == 2 })
        #expect(environment.source.spoken.withLockedValue { $0.map { $0.flatMap(\.samples).count } } == [0, 160])
        #expect(environment.source.overlaps.withLockedValue { $0 } == 0)
    }

    @Test func saysWhyTheCameraGaveUp() async throws {
        let environment = try CameraUIEnvironment()
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = try environment.signedIn(base)
        browser.origin = "http://127.0.0.1:\(environment.server.port!)"
        let start = try await browser.post("/api/cameras/Cams:still/talk", ["sampleRate": 8000])
        #expect(start.status == 200)
        let talk = try #require(start.json?["talk"]?.stringValue)
        #expect(await eventually {
            let reply = try? await browser.post("/api/cameras/Cams:still/talk/\(talk)", ["seq": 0, "pcm": Self.pcm([1, 2])])
            return reply?.status == 502 && reply?.json?["error"]?.stringValue == "the speaker is unplugged"
        })
        // A camera without a speaker has no microphone.
        #expect(try await browser.post("/api/cameras/Cams:lamp/talk", [:]).status == 404)
    }
}

@Suite struct CameraTalkSocketTests {
    /// A WebSocket to the camera's Talk, as the page opens it: its cookie, its own origin.
    static func connect(_ environment: CameraUIEnvironment, _ camera: String, cookie: String?, origin: String? = nil) async throws -> WebSocket {
        let port = environment.server.port!
        var options = WebSocket.Options()
        options.timeout = .seconds(10)
        if let cookie { options.headers.append((name: "Cookie", value: cookie)) }
        options.headers.append((name: "Origin", value: origin ?? "http://127.0.0.1:\(port)"))
        return try await WebSocket.connect(to: URL(string: "ws://127.0.0.1:\(port)/api/cameras/\(camera)/talk?sampleRate=8000")!, options: options)
    }

    /// The next text message, as JSON.
    static func next(_ socket: WebSocket) async throws -> JSONValue? {
        for try await message in socket.messages {
            if case .text(let text) = message { return try JSONValue(string: text) }
        }
        return nil
    }

    static func bytes(_ samples: [Int16]) -> Data {
        Data(samples.flatMap { [UInt8(UInt16(bitPattern: $0) & 0xFF), UInt8(UInt16(bitPattern: $0) >> 8)] })
    }

    @Test func talksOverAWebSocket() async throws {
        let environment = try CameraUIEnvironment()
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = try environment.signedIn(base)
        let socket = try await Self.connect(environment, "Cams:door", cookie: browser.cookie)
        let started = try #require(try await Self.next(socket))
        #expect(started["sampleRate"] == 8000 && started["talk"]?.stringValue?.isEmpty == false)
        let samples = (0..<320).map { Int16($0 * 50 - 8000) }
        try await socket.send(binary: Self.bytes(Array(samples[0..<250])))
        try await socket.send(binary: Self.bytes(Array(samples[250...])))
        #expect(await eventually { environment.source.spoken.withLockedValue { $0.first?.count } == 2 })
        // Closing the socket ends the Talk at once.
        await socket.close()
        #expect(await eventually { environment.source.talksEnded.withLockedValue { $0 } == 1 })
        let frames = try #require(environment.source.spoken.withLockedValue { $0.first })
        #expect(frames.flatMap(\.samples) == samples)
        #expect(environment.server.cameraTalks.session("Cams:door")?.isEnded == true)
    }

    @Test func upgradesOnlyWhatTheAPIWouldAllow() async throws {
        let environment = try CameraUIEnvironment()
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = try environment.signedIn(base)
        // Signed out, from another site: no WebSocket (the page then asks over requests, which say why).
        await #expect(throws: (any Error).self) { _ = try await Self.connect(environment, "Cams:door", cookie: nil) }
        await #expect(throws: (any Error).self) { _ = try await Self.connect(environment, "Cams:door", cookie: browser.cookie, origin: "https://elsewhere.example") }
        #expect(environment.server.cameraTalks.session("Cams:door") == nil)
        // A request that was not upgraded is answered as the API answers it: why.
        #expect(try await Browser(base: base).get("/api/cameras/Cams:door/talk").status == 401)
        #expect(try await browser.get("/api/cameras/Cams:door/talk").status == 426)

        // Someone else talking: the socket opens and says so.
        let first = try await Self.connect(environment, "Cams:door", cookie: browser.cookie)
        #expect(try await Self.next(first)?["talk"] != nil)
        _ = try environment.server.users.create(username: "linus", password: "correct horse battery staple")
        let other = try await Self.connect(environment, "Cams:door", cookie: "\(UIServer.cookieName)=\(environment.server.sessions.create(username: "linus"))")
        let refused = try #require(try await Self.next(other))
        #expect(refused["status"] == 409 && refused["error"]?.stringValue?.contains("rosaly") == true)
        await first.close()

        // A plugin that gives up says why before the socket closes.
        let still = try await Self.connect(environment, "Cams:still", cookie: browser.cookie)
        var messages: [JSONValue] = []
        for try await message in still.messages { if case .text(let text) = message { messages.append(try JSONValue(string: text)) } }
        #expect(messages.last?["error"]?.stringValue == "the speaker is unplugged" && messages.last?["status"] == 502)
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
