import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers

// zwave-js-server's protocol (github.com/zwave-js/zwave-js-server, its README): JSON text messages over a WebSocket.
// The server speaks first with a `version` message (its home id and the API schemas it speaks); the client picks a schema
// with `set_api_schema`, then `start_listening` answers with the whole state and starts the events. Each command carries
// a `messageId` that its `result` repeats, with `success` and a `result` or an `errorCode`.

/// What went wrong talking to zwave-js-server.
enum ZWaveError: Error, CustomStringConvertible, Equatable {
    /// The server answered a command with `success: false`.
    case failed(command: String, code: String, message: String?)
    /// No answer in time.
    case timeout(String)
    /// The connection closed before the answer.
    case closed
    /// The server speaks no API schema the plugin knows.
    case unsupportedSchema(minimum: Int, maximum: Int)
    /// Another network than the one set up answered at the address.
    case otherNetwork(expected: String, found: String)
    case malformed(String)

    var description: String {
        switch self {
        case .failed(let command, let code, let message): "\(command) failed: \(code)\(message.map { " (\($0))" } ?? "")"
        case .timeout(let what): "no answer to \(what)"
        case .closed: "the connection closed"
        case .unsupportedSchema(let minimum, let maximum): "the server speaks API schemas \(minimum) to \(maximum), the plugin needs \(ZWaveClient.minimumSchema) or later"
        case .otherNetwork(let expected, let found): "the server runs the Z-Wave network \(found), not \(expected)"
        case .malformed(let what): "unexpected message: \(what)"
        }
    }
}

/// What the server said of itself when the connection opened.
struct ServerVersion: Sendable, Equatable {
    var homeID: String
    var driverVersion: String?
    var serverVersion: String?
    var minimumSchema: Int
    var maximumSchema: Int

    init?(_ json: JSONValue) {
        guard json["type"]?.stringValue == "version", let home = json["homeId"], let homeID = Self.homeID(home) else { return nil }
        self.homeID = homeID
        driverVersion = json["driverVersion"]?.stringValue
        serverVersion = json["serverVersion"]?.stringValue
        minimumSchema = json["minSchemaVersion"]?.intValue ?? 0
        maximumSchema = json["maxSchemaVersion"]?.intValue ?? 0
    }

    /// A home id as the Device Id carries it: its decimal number, as zwave-js and Home Assistant show it.
    static func homeID(_ json: JSONValue) -> String? {
        if let number = json.doubleValue, number >= 0, number <= Double(UInt32.max), number.rounded() == number { return String(UInt32(number)) }
        if let text = json.stringValue, let number = UInt32(text) { return String(number) }
        return nil
    }
}

/// One open connection to zwave-js-server: commands and their results, and the events, in order.
final class ZWaveClient: Sendable {
    /// The API schema the plugin reads (the state dump's and the events' shapes), asked for when the server speaks it.
    static let preferredSchema = 35
    /// The oldest schema the plugin reads: `node.set_value`'s result and `node added`'s fields as below.
    static let minimumSchema = 14

    private struct State {
        var nextID = 0
        var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
        var version: ServerVersion?
        var versionWaiter: CheckedContinuation<ServerVersion, any Error>?
        var closed = false
    }

    let socket: any WebSocketConnection
    /// Each event's `event` object (`source`, `event`, `nodeId`, `args`…), in order; ends when the connection closes.
    let events: AsyncStream<JSONValue>
    private let eventSink: AsyncStream<JSONValue>.Continuation
    private let state = NIOLockedValueBox(State())
    private let timeout: Duration

    init(socket: any WebSocketConnection, timeout: Duration) {
        self.socket = socket
        self.timeout = timeout
        (events, eventSink) = AsyncStream.makeStream(of: JSONValue.self, bufferingPolicy: .bufferingNewest(10_000))
    }

    /// Reads the socket until it closes; then every waiting command fails.
    func run() async {
        do {
            for try await message in socket.messages {
                guard let text = message.text else { continue }
                receive(text)
            }
        } catch {}
        finish()
    }

    /// One text message from the server.
    func receive(_ text: String) {
        guard let json = try? JSONValue(string: text) else { return }
        switch json["type"]?.stringValue {
        case "version":
            guard let version = ServerVersion(json) else { return }
            let waiter = state.withLockedValue { state -> CheckedContinuation<ServerVersion, any Error>? in
                state.version = version
                defer { state.versionWaiter = nil }
                return state.versionWaiter
            }
            waiter?.resume(returning: version)
        case "result":
            guard let id = json["messageId"]?.stringValue else { return }
            let waiter = state.withLockedValue { $0.pending.removeValue(forKey: id) }
            guard let waiter else { return }
            if json["success"]?.boolValue == true {
                waiter.resume(returning: json["result"] ?? .null)
            } else {
                let code = json["errorCode"]?.stringValue ?? "unknown"
                let message = json["message"]?.stringValue ?? json["zwaveErrorMessage"]?.stringValue
                waiter.resume(throwing: ZWaveError.failed(command: Self.command(of: id), code: code, message: message))
            }
        case "event":
            if let event = json["event"] { eventSink.yield(event) }
        default:
            break
        }
    }

    /// The connection is gone: what waits fails, the events end.
    func finish() {
        let (pending, versionWaiter) = state.withLockedValue { state in
            state.closed = true
            defer {
                state.pending = [:]
                state.versionWaiter = nil
            }
            return (Array(state.pending.values), state.versionWaiter)
        }
        for waiter in pending { waiter.resume(throwing: ZWaveError.closed) }
        versionWaiter?.resume(throwing: ZWaveError.closed)
        eventSink.finish()
    }

    /// The server's `version` message, the first it sends.
    func version() async throws -> ServerVersion {
        try await withTimeout(timeout, error: { ZWaveError.timeout("the version message") }) { [state] in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ServerVersion, any Error>) in
                    let result = state.withLockedValue { state -> Result<ServerVersion, any Error>? in
                        if let version = state.version { return .success(version) }
                        if state.closed { return .failure(ZWaveError.closed) }
                        state.versionWaiter = continuation
                        return nil
                    }
                    if let result { continuation.resume(with: result) }
                }
            } onCancel: {
                state.withLockedValue { state in
                    defer { state.versionWaiter = nil }
                    return state.versionWaiter
                }?.resume(throwing: CancellationError())
            }
        }
    }

    /// Sends a command and waits for its result.
    @discardableResult
    func command(_ name: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        let id = state.withLockedValue { state -> String in
            state.nextID += 1
            return "\(name)#\(state.nextID)"
        }
        var message = fields
        message["messageId"] = .string(id)
        message["command"] = .string(name)
        let text = JSONValue.object(message).text()
        let socket = self.socket
        return try await withTimeout(timeout, error: { ZWaveError.timeout(name) }) { [state] in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                    let closed = state.withLockedValue { state -> Bool in
                        guard !state.closed else { return true }
                        state.pending[id] = continuation
                        return false
                    }
                    if closed {
                        continuation.resume(throwing: ZWaveError.closed)
                        return
                    }
                    Task {
                        do {
                            try await socket.send(text: text)
                        } catch {
                            state.withLockedValue { $0.pending.removeValue(forKey: id) }?.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                state.withLockedValue { $0.pending.removeValue(forKey: id) }?.resume(throwing: CancellationError())
            }
        }
    }

    /// The command's name from a message id (`node.set_value#12`).
    private static func command(of id: String) -> String { String(id.split(separator: "#").first ?? Substring(id)) }

    /// Opens the session: reads the version, picks the schema, and starts listening. Answers the version and the state
    /// (`driver`, `controller`, `nodes`).
    func open(expectedHomeID: String?) async throws -> (ServerVersion, JSONValue) {
        let version = try await version()
        if let expectedHomeID, expectedHomeID != version.homeID {
            throw ZWaveError.otherNetwork(expected: expectedHomeID, found: version.homeID)
        }
        guard version.maximumSchema >= Self.minimumSchema else {
            throw ZWaveError.unsupportedSchema(minimum: version.minimumSchema, maximum: version.maximumSchema)
        }
        let schema = max(version.minimumSchema, min(Self.preferredSchema, version.maximumSchema))
        try await command("set_api_schema", ["schemaVersion": .number(Double(schema))])
        let result = try await command("start_listening")
        guard let state = result["state"], state["nodes"]?.arrayValue != nil else { throw ZWaveError.malformed("start_listening gave no nodes") }
        return (version, state)
    }

    /// `node.set_value`: a write to one value.
    func setValue(nodeID: Int, _ id: ValueID, _ value: JSONValue) async throws {
        let result = try await command("node.set_value", ["nodeId": .number(Double(nodeID)), "valueId": id.json, "value": value])
        // Later schemas answer `{ result: { status } }` (zwave-js's SetValueStatus): 0 no device support, 2 fail, 3
        // endpoint not found, 4 not implemented, 5 invalid value; 1 working, 254 and 255 success.
        if let status = result["result"]?["status"]?.intValue, [0, 2, 3, 4, 5].contains(status) {
            throw ZWaveError.failed(command: "node.set_value", code: "status \(status)", message: result["result"]?["message"]?.stringValue)
        }
        // Earlier schemas answer `{ success }`.
        if result["success"]?.boolValue == false {
            throw ZWaveError.failed(command: "node.set_value", code: "refused", message: nil)
        }
    }

    func close() async {
        await socket.close()
        finish()
    }
}
