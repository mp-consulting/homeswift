import Foundation
import Logging

/// The TV's `notifychange` long-poll, as the Philips TV Remote app uses it: a POST that the TV answers when
/// one of the subscribed resources changes, or with nothing after a while. Its own client, so a request
/// held open for a minute never queues behind the commands.
actor NotifyChangeClient {
    static let timeout: Duration = .seconds(60)
    static let minimumInterval: Duration = .seconds(2)
    static let reconnectDelay: Duration = .seconds(1)
    static let maximumReconnectDelay: Duration = .seconds(30)
    static let maximumConsecutiveFailures = 5
    /// `activities/tv` is in because the TV pushes it on every change, including app switches from the
    /// remote that some models never report through `activities/current`.
    static let resources = ["activities/current", "activities/tv", "ambilight/currentconfiguration", "ambilight/power", "audio/volume", "powerstate"]

    enum Event: Sendable {
        /// The resources that changed, with their new values.
        case notification([String: JSONPayload])
        /// Too many failures in a row: the caller falls back to polling.
        case failed
    }

    private let client: JointSpaceClient
    private let logger: Logger
    private var task: Task<Void, Never>?
    private let timeScale: Double

    init(client: JointSpaceClient, logger: Logger, timeScale: Double = 1) {
        self.client = client
        self.logger = logger
        self.timeScale = timeScale
    }

    /// Starts the loop; events reach `handler` until `stop()` or a failure.
    func start(_ handler: @escaping @Sendable (Event) async -> Void) {
        guard task == nil else { return }
        let client = client
        let logger = logger
        let reconnectDelay = Self.reconnectDelay * timeScale, maximumReconnectDelay = Self.maximumReconnectDelay * timeScale
        let minimumInterval = Self.minimumInterval * timeScale
        task = Task {
            var failures = 0
            var delay = reconnectDelay
            while !Task.isCancelled {
                let started = ContinuousClock.now
                do {
                    let payload = try await Self.poll(client)
                    if Task.isCancelled { return }
                    if payload.isEmpty {
                        // The TV answered with nothing: not a delivery, but the transport works.
                        failures += 1
                        logger.debug("notifychange answered with no changes (\(failures)/\(Self.maximumConsecutiveFailures))")
                    } else {
                        failures = 0
                        delay = reconnectDelay
                        await handler(.notification(payload))
                    }
                    let elapsed = ContinuousClock.now - started
                    if elapsed < minimumInterval { try await Task.sleep(for: minimumInterval - elapsed) }
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    logger.debug("notifychange failed (\(failures)/\(Self.maximumConsecutiveFailures)): \(error)")
                    do { try await Task.sleep(for: delay) } catch { return }
                    delay = min(delay * 2, maximumReconnectDelay)
                }
                if failures >= Self.maximumConsecutiveFailures {
                    logger.debug("notifychange: giving up after \(failures) failures")
                    await handler(.failed)
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func poll(_ client: JointSpaceClient) async throws -> [String: JSONPayload] {
        struct Body: Encodable {
            var notification: [String: JSONPayload?]
        }
        let body = Body(notification: Dictionary(uniqueKeysWithValues: resources.map { ($0, nil) }))
        let data = try await client.longPost("notifychange", body, timeout: timeout)
        guard !data.isEmpty else { return [:] }
        do {
            return try JSONDecoder().decode([String: JSONPayload].self, from: data)
        } catch {
            throw JointSpaceError.invalidResponse("notifychange: \(error)")
        }
    }
}

/// A JSON value as the TV sends it in a notification: enough to read the few fields the plugin acts on.
enum JSONPayload: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONPayload])
    case array([JSONPayload])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONPayload].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONPayload].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not JSON")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONPayload? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

}
