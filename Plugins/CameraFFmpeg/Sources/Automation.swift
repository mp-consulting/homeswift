import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

// The automation inputs of homebridge-camera-ffmpeg (sections 6.4 and 6.5): MQTT messages and a small HTTP API that
// trigger a camera's motion sensor and doorbell.

/// What an MQTT message or an HTTP request does to a camera.
enum TriggerAction: Sendable, Equatable {
    case motion
    case motionReset
    case doorbell

    func run(on triggers: CameraTriggers) async -> TriggerResult {
        switch self {
        case .motion: await triggers.motion(true, minimumTimeout: 0)
        case .motionReset: await triggers.motion(false, minimumTimeout: 0)
        case .doorbell: await triggers.doorbell(true)
        }
    }
}

/// The topics of every camera: topic, then exact payload, then the actions, in camera order and, per camera, motion,
/// motion reset, doorbell.
struct MQTTRoutes: Sendable {
    struct Route: Sendable {
        var message: String
        var action: TriggerAction
        var triggers: CameraTriggers
    }

    private(set) var routes: [String: [Route]] = [:]
    /// The topics in the order they were first registered.
    private(set) var topics: [String] = []

    mutating func register(camera name: String, mqtt: CameraFFmpegPlugin.CameraMQTT, triggers: CameraTriggers) {
        func add(_ topic: String?, _ message: String?, _ action: TriggerAction) {
            guard let topic else { return }
            if routes[topic] == nil { topics.append(topic) }
            routes[topic, default: []].append(Route(message: message ?? name, action: action, triggers: triggers))
        }
        add(mqtt.motionTopic, mqtt.motionMessage, .motion)
        add(mqtt.motionResetTopic, mqtt.motionResetMessage, .motionReset)
        add(mqtt.doorbellTopic, mqtt.doorbellMessage, .doorbell)
    }

    /// The routes a message matches: its payload as text, compared exactly.
    func matching(topic: String, payload: Data) -> [Route] {
        guard let candidates = routes[topic] else { return [] }
        let text = String(decoding: payload, as: UTF8.self)
        return candidates.filter { $0.message == text }
    }
}

/// The MQTT client: subscribes to every camera's topics (the client renews them on each reconnection) and runs what the
/// messages match. Errors (a sensor that is not enabled) are ignored, as the original does.
final class MQTTAutomation: Sendable {
    let connection: any MQTTConnection
    private let tasks = TaskBag()

    init(configuration: CameraFFmpegPlugin.Configuration, host: String, password: String?, routes: MQTTRoutes, logger: Logger,
         connect: @Sendable (MQTTConfiguration) -> any MQTTConnection) {
        let port = configuration.mqttPort
        let transport: MQTTConfiguration.Transport = configuration.mqttTLS ? .tls(host: host, port: port) : .tcp(host: host, port: port)
        var mqtt = MQTTConfiguration(
            transport: transport, clientID: "homeswift_" + String(format: "%08x", UInt32.random(in: 0...UInt32.max)),
            username: configuration.mqttUsername, password: password)
        // The original reconnects every second; this backs off to a minute while the broker stays away.
        mqtt.reconnect = MQTTConfiguration.Reconnect(delay: .seconds(1), maximumDelay: .seconds(60), jitter: .proportional(0.2), firstConnection: true)
        connection = connect(mqtt)
        let connection = connection
        let url = "\(configuration.mqttTLS ? "mqtts" : "mqtt")://\(host):\(port)"
        logger.info("Setting up MQTT connection with topics: \(routes.topics.joined(separator: ", ")) (\(url))")
        let states = connection.states
        let messages = connection.messages
        tasks.add {
            var connected = false
            var reportedFailure = false
            for await state in states {
                switch state {
                case .connected:
                    connected = true
                    reportedFailure = false
                    logger.info("MQTT connected: \(url)")
                case .connectionLost(let reason):
                    // Once per outage, not once per attempt.
                    if connected || !reportedFailure { logger.warning("MQTT connection lost: \(Masking.text(reason))") }
                    connected = false
                    reportedFailure = true
                default:
                    break
                }
            }
        }
        tasks.add {
            for await message in messages {
                for route in routes.matching(topic: message.topic, payload: message.payload) {
                    _ = await route.action.run(on: route.triggers)
                }
            }
        }
        tasks.add {
            for topic in routes.topics {
                logger.debug("Subscribing to MQTT topic: \(topic)")
                try? await connection.subscribe(topic, qos: .atMostOnce)
            }
            try? await connection.connect()
        }
    }

    func stop() async {
        tasks.cancelAll()
        await connection.disconnect()
    }
}

// MARK: HTTP

/// The HTTP API: `GET /motion?<camera>`, `/motion/reset?<camera>`, `/doorbell?<camera>` (section 6.5).
enum HTTPAutomation {
    /// What a request target asks: the camera and the action, or the error message.
    static func route(_ target: String) -> Result<(camera: String, action: TriggerAction), TriggerResult> {
        let parts = target.split(separator: "?", omittingEmptySubsequences: false)
        guard parts.count == 2, let decoded = String(parts[1]).removingPercentEncoding else {
            return .failure(.failure("Malformed URL."))
        }
        let camera = String(decoded.prefix { $0 != "=" })
        let segments = parts[0].split(separator: "/").map(String.init)
        let first = segments.first
        if first == "motion" {
            return .success((camera, segments.count > 1 && segments[1] == "reset" ? .motionReset : .motion))
        }
        if first == "doorbell" {
            return .success((camera, .doorbell))
        }
        return .failure(.failure("First directory level must be \"motion\" or \"doorbell\", got \"\(first ?? "undefined")\"."))
    }

    /// The answer to a request target: 200 with the result, 500 for an error.
    static func respond(to target: String, cameras: [String: CameraTriggers]) async -> (status: Int, body: String) {
        let result: TriggerResult
        switch route(target) {
        case .failure(let failure):
            result = failure
        case .success(let (camera, action)):
            if let triggers = cameras[camera] {
                result = await action.run(on: triggers)
            } else {
                result = .failure("Camera \"\(camera)\" not found.")
            }
        }
        return (result.error ? 500 : 200, result.json)
    }
}

/// The HTTP server of the API, on its own port: no authentication, no TLS, as the original. A request is answered from its
/// target alone (method and body ignored); a malformed one closes its connection.
final class HTTPAutomationServer: Sendable {
    typealias Handler = @Sendable (_ target: String) async -> (status: Int, body: String)

    /// A connection quiet this long is closed.
    static let idleTimeout: TimeAmount = .seconds(30)

    private let channels = NIOLockedValueBox<[any Channel]>([])

    /// Binds `port` on the loopback addresses (`localOnly`) or every interface; the port bound (port 0 picks one).
    @discardableResult
    func start(port: Int, localOnly: Bool, handler: @escaping Handler, logger: Logger,
               group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 32)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(IdleStateHandler(allTimeout: Self.idleTimeout))
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(AutomationHandler(handler: handler))
                }
            }
        var bound: [any Channel] = []
        var boundPort = port
        // Node's `localhost`: the IPv4 loopback, and the IPv6 one where there is one.
        for host in localOnly ? ["127.0.0.1", "::1"] : ["0.0.0.0"] {
            do {
                let channel = try await bootstrap.bind(host: host, port: boundPort).get()
                boundPort = channel.localAddress?.port ?? boundPort
                bound.append(channel)
            } catch where host == "::1" {
                // No IPv6 loopback on this host.
            }
        }
        channels.withLockedValue { $0 += bound }
        logger.info("Starting HTTP server on port \(boundPort)\(localOnly ? " (localhost only)" : "").")
        return boundPort
    }

    func stop() async {
        let channels = channels.withLockedValue { channels in
            defer { channels = [] }
            return channels
        }
        for channel in channels { try? await channel.close() }
    }
}

private final class AutomationHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let handler: HTTPAutomationServer.Handler
    private var target = "/"
    private var keepAlive = true

    init(handler: @escaping HTTPAutomationServer.Handler) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            target = head.uri
            keepAlive = head.isKeepAlive
        case .body:
            break
        case .end:
            let target = target
            let keepAlive = keepAlive
            let handler = handler
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            let loop = context.eventLoop
            Task {
                let (status, body) = await handler(target)
                loop.execute {
                    let context = bound.value
                    var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
                    buffer.writeString(body)
                    var headers = HTTPHeaders()
                    headers.add(name: "Content-Length", value: "\(buffer.readableBytes)")
                    if !keepAlive { headers.add(name: "Connection", value: "close") }
                    let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers)
                    context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
                    context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                    let done = context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)))
                    if !keepAlive { let channel = context.channel; done.whenComplete { _ in channel.close(promise: nil) } }
                }
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
