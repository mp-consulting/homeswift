import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import HomeswiftDaikinCloud

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .critical
    return logger
}()

/// A logger that keeps what it is given, to check messages.
final class LogRecorder: @unchecked Sendable {
    let lines = NIOLockedValueBox<[(level: Logger.Level, message: String)]>([])

    var logger: Logger {
        var logger = Logger(label: "daikin-test") { _ in Handler(recorder: self) }
        logger.logLevel = .trace
        return logger
    }

    func contains(_ text: String, level: Logger.Level? = nil) -> Bool {
        lines.withLockedValue { $0.contains { $0.message.contains(text) && (level == nil || $0.level == level) } }
    }

    var messages: [String] { lines.withLockedValue { $0.map(\.message) } }

    struct Handler: LogHandler {
        let recorder: LogRecorder
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(event: LogEvent) {
            recorder.lines.withLockedValue { $0.append((event.level, event.message.description)) }
        }
        func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
            recorder.lines.withLockedValue { $0.append((level, message.description)) }
        }
    }
}

/// The fixtures of the Homebridge plugin's tests, as JSON.
enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func json(_ name: String) -> JSONValue {
        // swiftlint:disable:next force_try
        try! JSONValue(data: Data(contentsOf: directory.appendingPathComponent("\(name).json")))
    }

    /// A fixture with changes made to one management point.
    static func json(_ name: String, managementPoint id: String, _ change: (inout [String: JSONValue]) -> Void) -> JSONValue {
        guard case .object(var root) = json(name), case .array(var points) = root["managementPoints"],
            let index = points.firstIndex(where: { $0["embeddedId"]?.stringValue == id }), case .object(var point) = points[index]
        else { return json(name) }
        change(&point)
        points[index] = .object(point)
        root["managementPoints"] = .array(points)
        return .object(root)
    }

    /// A fixture in another climate control operation mode.
    static func json(_ name: String, operationMode: String?) -> JSONValue {
        guard let operationMode else { return json(name) }
        return json(name, managementPoint: "climateControl") { point in
            var mode = point["operationMode"]?.objectValue ?? [:]
            mode["value"] = .string(operationMode)
            point["operationMode"] = .object(mode)
        }
    }

    static let all = [
        "dx4Airco", "dx23Airco", "dx23Airco2", "unknownJan", "unknownKitchenGuests", "althermaHeatPump", "althermaHeatPump2", "althermaCrSense2",
        "althermaWithEmbeddedIdZero", "althermaV1ckoeln", "althermaFraction", "althermaMiladcerkic", "althermaMiladcerkicOff",
    ]
}

/// A write a device sent to the API.
struct Write: Equatable, Sendable, CustomStringConvertible {
    var embeddedID: String
    var dataPoint: String
    var value: JSONValue
    var path: String?

    init(_ embeddedID: String, _ dataPoint: String, _ value: JSONValue, _ path: String? = nil) {
        self.embeddedID = embeddedID
        self.dataPoint = dataPoint
        self.value = value
        self.path = path
    }

    var description: String { "\(embeddedID) \(dataPoint) \(value) \(path ?? "-")" }
}

/// The API as a device sees it: records writes; a test can make one fail or wait.
final class RecordingAPI: DaikinDeviceWriting, @unchecked Sendable {
    let writes = NIOLockedValueBox<[Write]>([])
    let holidays = NIOLockedValueBox<[(String, Bool)]>([])
    let firmware = NIOLockedValueBox<[(String, String)]>([])
    /// Run before each write is recorded; throwing fails the write.
    let gate = NIOLockedValueBox<[@Sendable (Write) async throws -> Void]>([])

    var recorded: [Write] { writes.withLockedValue { $0 } }

    func reset() { writes.withLockedValue { $0.removeAll() } }

    /// The next write runs `body` first.
    func next(_ body: @escaping @Sendable (Write) async throws -> Void) { gate.withLockedValue { $0.append(body) } }

    /// The value sent, unless a test makes the next write answer another (a coalesced one).
    let sentValues = NIOLockedValueBox<[JSONValue]>([])

    func updateDevice(_ deviceID: String, embeddedID: String, dataPoint: String, value: JSONValue, path: String?) async throws -> JSONValue {
        let write = Write(embeddedID, dataPoint, value, path)
        let body = gate.withLockedValue { $0.isEmpty ? nil : $0.removeFirst() }
        try await body?(write)
        writes.withLockedValue { $0.append(write) }
        return sentValues.withLockedValue { $0.isEmpty ? value : $0.removeFirst() }
    }

    func setHolidayMode(_ deviceID: String, embeddedID: String, enabled: Bool, startDate: String?, endDate: String?) async throws {
        let body = gate.withLockedValue { $0.isEmpty ? nil : $0.removeFirst() }
        try await body?(Write(embeddedID, "holidayMode", .bool(enabled)))
        holidays.withLockedValue { $0.append((embeddedID, enabled)) }
    }

    func triggerFirmwareUpdate(_ deviceID: String, embeddedID: String, firmwareID: String) async throws {
        firmware.withLockedValue { $0.append((embeddedID, firmwareID)) }
    }
}

/// An HTTP server in memory: answers from a handler, records the requests.
final class FakeHTTP: HTTPSending, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest, Int) async throws -> HTTPResponse
    let requests = NIOLockedValueBox<[HTTPRequest]>([])
    private let handler: NIOLockedValueBox<Handler>

    init(_ handler: @escaping Handler = { _, _ in HTTPResponse(status: 404) }) {
        self.handler = NIOLockedValueBox(handler)
    }

    func set(_ handler: @escaping Handler) { self.handler.withLockedValue { $0 = handler } }

    var count: Int { requests.withLockedValue { $0.count } }
    var all: [HTTPRequest] { requests.withLockedValue { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let index = requests.withLockedValue { requests -> Int in
            requests.append(request)
            return requests.count
        }
        return try await handler.withLockedValue { $0 }(request, index)
    }
}

extension HTTPResponse {
    static func json(_ value: JSONValue, status: Int = 200, headers: [(name: String, value: String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: value.encoded())
    }

    static func text(_ text: String, status: Int, headers: [(name: String, value: String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: Data(text.utf8))
    }
}

extension HTTPRequest {
    var bodyText: String { body.map { String(decoding: $0, as: UTF8.self) } ?? "" }
    var bodyJSON: JSONValue? { body.flatMap { try? JSONValue(data: $0) } }
    var form: [String: String] {
        var fields: [String: String] = [:]
        for pair in bodyText.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { URLEncoding.decode(String($0)) }
            fields[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return fields
    }
}

/// An OAuth provider with a fixed token that counts refreshes.
actor FakeOAuth: OAuthProvider {
    var tokens = ["valid-token"]
    private(set) var refreshes = 0
    var refreshError: (any Error)?
    var refreshGate: (@Sendable () async -> Void)?

    func accessToken() async throws -> String { tokens.count > 1 ? tokens.removeFirst() : tokens[0] }
    func refreshToken() async throws -> TokenSet {
        refreshes += 1
        if let refreshGate { await refreshGate() }
        if let refreshError { throw refreshError }
        return TokenSet(access_token: "new-token", refresh_token: "new-refresh", token_type: "Bearer", expires_in: 3600)
    }
    func set(tokens: [String]) { self.tokens = tokens }
    func set(refreshError: (any Error)?) { self.refreshError = refreshError }
    func set(refreshGate: (@Sendable () async -> Void)?) { self.refreshGate = refreshGate }
}

/// A one-shot signal tests wait on.
final class Signal: @unchecked Sendable {
    private let state = NIOLockedValueBox<(fired: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func fire() {
        let waiters = state.withLockedValue { state -> [CheckedContinuation<Void, Never>] in
            state.fired = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let fired = state.withLockedValue { state -> Bool in
                if !state.fired { state.waiters.append(continuation) }
                return state.fired
            }
            if fired { continuation.resume() }
        }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// A port the system just handed out and nothing holds: for a test whose port has to be known before the server binds it (it
/// goes into a redirect URI). A random pick in 40000...60000 overlaps the ephemeral range and collides under a parallel run.
func freePort() async throws -> Int {
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
    let port = channel.localAddress?.port ?? 0
    try await channel.close()
    return port
}

/// A listener on a port outside every system's ephemeral range (Linux hands out 32768–60999 for port 0, macOS
/// 49152–65535): once it closes, no test running in parallel can be given that port by a `bind(port: 0)`, so a test
/// may bind it again afterwards to prove nothing else holds it.
func listenerOutsideEphemeralRange() async throws -> any Channel {
    for _ in 0..<64 {
        do {
            return try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: Int.random(in: 20000..<32000)).get()
        } catch let error as IOError where error.errnoCode == EADDRINUSE {
            continue
        }
    }
    throw IOError(errnoCode: EADDRINUSE, reason: "no free port in 20000..<32000")
}

func temporaryDirectory(_ name: String = "daikin") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-\(name)-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Settings from a block written as a dictionary.
func settings(_ raw: [String: JSONValue] = [:]) -> DaikinSettings { DaikinSettings(.init(raw)) }

/// A service context that records forced updates.
func serviceContext(_ raw: [String: JSONValue] = [:], logger: Logger = testLogger, forced: NIOLockedValueBox<Int>? = nil) -> ServiceContext {
    ServiceContext(settings: settings(raw), logger: logger) { forced?.withLockedValue { $0 += 1 } }
}
