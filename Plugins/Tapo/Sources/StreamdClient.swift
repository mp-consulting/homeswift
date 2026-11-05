import Foundation
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

/// Opens live view sessions with a camera's Streamd server (docs/clean-room/TapoCamera.md, 2 to 8): one TCP connection
/// per session, the Digest login (the SHA-256 of the password when the camera asks for it, then once more with its MD5 on
/// a new connection), the preview request, and the MPEG-TS of the camera's parts, decrypted. Closing the connection is
/// the only way to stop.
struct StreamdClient: Sendable {
    typealias Connect = @Sendable (_ host: String, _ port: Int, _ timeout: Duration) async throws -> any ByteStream

    var host: String
    var port: Int = Streamd.port
    var password: @Sendable () -> String?
    var connect: Connect
    /// How long the connection and the login may take: a sleeping camera may accept TCP and say nothing (8).
    var handshakeTimeout: Duration = .seconds(20)
    /// How long without a part ends the session (8): the camera went to standby.
    var silenceTimeout: Duration = .seconds(10)
    var logger: Logger

    /// A session, once the camera accepted the preview request: its MPEG-TS, until it ends; `close()` ends it.
    final class Session: Sendable {
        let sessionID: String?
        let stream: AsyncThrowingStream<Data, any Error>
        private let connection: any ByteStream
        private let reader: Task<Void, Never>

        init(sessionID: String?, stream: AsyncThrowingStream<Data, any Error>, connection: any ByteStream, reader: Task<Void, Never>) {
            self.sessionID = sessionID
            self.stream = stream
            self.connection = connection
            self.reader = reader
        }

        func close() async {
            reader.cancel()
            await connection.close()
        }
    }

    /// Opens a live view of `channel` at `resolution`.
    func open(channel: Int = 0, resolution: Streamd.Resolution) async throws -> Session {
        guard let password = password(), !password.isEmpty else { throw StreamdError.invalidCredentials }
        do {
            return try await attempt(password: password, forceMD5: false, channel: channel, resolution: resolution)
        } catch StreamdHandshakeError.refused(let triedSHA256) where triedSHA256 {
            logger.debug("[\(host)] Streamd refused the SHA-256 of the password: trying its MD5")
            do {
                return try await attempt(password: password, forceMD5: true, channel: channel, resolution: resolution)
            } catch StreamdHandshakeError.refused {
                throw StreamdError.invalidCredentials
            }
        } catch StreamdHandshakeError.refused {
            throw StreamdError.invalidCredentials
        }
    }

    private func attempt(password: String, forceMD5: Bool, channel: Int, resolution: Streamd.Resolution) async throws -> Session {
        let connection = try await connect(host, port, handshakeTimeout)
        do {
            return try await withDeadline(handshakeTimeout, onTimeout: { await connection.close() }) {
                try await handshake(connection, password: password, forceMD5: forceMD5, channel: channel, resolution: resolution)
            }
        } catch {
            await connection.close()
            throw error
        }
    }

    private func handshake(_ connection: any ByteStream, password: String, forceMD5: Bool, channel: Int, resolution: Streamd.Resolution) async throws -> Session {
        var iterator = connection.incoming.makeAsyncIterator()
        var buffer = StreamdBuffer()
        func head() async throws -> (status: Int, headers: [String: String]) {
            while true {
                if let head = try buffer.readHead() { return head }
                guard let more = try await iterator.next() else { throw StreamdError.closed }
                buffer.append(more)
            }
        }

        try await connection.send(Streamd.request())
        var response = try await head()
        guard response.status == 401, let header = response.headers["www-authenticate"] else {
            throw StreamdError.invalidResponse("status \(response.status) without a challenge")
        }
        let challenge = Streamd.fields(header)
        let sha256 = !forceMD5 && Streamd.wantsSHA256(challenge)
        let hash = Streamd.passwordHash(password, sha256: sha256)
        guard let authorization = Streamd.authorization(challenge: challenge, passwordHash: hash, cnonce: Streamd.randomCNonce()) else {
            throw StreamdError.invalidResponse("a challenge without realm or nonce")
        }
        // The 401's body, if any, is skipped by `readHead`, which looks for the next status line.
        try await connection.send(Streamd.request(authorization: authorization))
        response = try await head()
        if response.status == 401 { throw StreamdHandshakeError.refused(triedSHA256: sha256) }
        guard response.status == 200 else { throw StreamdError.invalidResponse("status \(response.status)") }
        guard let exchange = response.headers["key-exchange"], let keys = Streamd.Keys(keyExchange: exchange, passwordHash: hash) else {
            throw StreamdError.invalidResponse("no Key-Exchange")
        }
        let boundary = response.headers["content-type"].flatMap(Self.boundary(of:)) ?? Streamd.deviceBoundary

        try await connection.send(Streamd.jsonPart(Streamd.previewRequest(channel: channel, resolution: resolution)))
        // The reply: a JSON part with the session id, or a refusal.
        var early: [Data] = []
        var sessionID: String?
        replyLoop: while true {
            while let part = try buffer.readPart(boundary: boundary) {
                let body = part.isEncrypted ? try keys.decrypt(part.body) : part.body
                if part.contentType.contains("json") {
                    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
                    if let params = object["params"] as? [String: Any] {
                        if let code = (params["error_code"] as? NSNumber)?.intValue, code != 0 {
                            throw Streamd.busyCodes.contains(code) ? StreamdError.busy(code) : StreamdError.refused(code)
                        }
                        if object["type"] as? String == "response" {
                            sessionID = (params["session_id"] as? String) ?? (params["session_id"] as? NSNumber)?.stringValue
                            break replyLoop
                        }
                    }
                } else if part.contentType.contains("mp2t") {
                    // Media before the reply: the session is on.
                    early.append(body)
                    break replyLoop
                }
            }
            guard let more = try await iterator.next() else { throw StreamdError.closed }
            buffer.append(more)
        }

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        for data in early { continuation.yield(data) }
        let lastPart = NIOLockedValueBox(ContinuousClock.now)
        let silence = silenceTimeout
        let host = host
        let logger = logger
        let carried = buffer
        let iteratorBox = UnsafeTransfer(iterator)
        let reader = Task {
            var iterator = iteratorBox.value
            var buffer = carried
            let watchdog = Task {
                while !Task.isCancelled {
                    let idle = ContinuousClock.now - lastPart.withLockedValue { $0 }
                    if idle >= silence {
                        continuation.finish(throwing: StreamdError.silent)
                        await connection.close()
                        return
                    }
                    try? await Task.sleep(for: silence - idle)
                }
            }
            defer { watchdog.cancel() }
            do {
                while !Task.isCancelled {
                    while let part = try buffer.readPart(boundary: boundary) {
                        lastPart.withLockedValue { $0 = .now }
                        let body = part.isEncrypted ? try keys.decrypt(part.body) : part.body
                        if part.contentType.contains("mp2t") {
                            continuation.yield(body)
                        } else if part.contentType.contains("json"), Self.isFinished(body) {
                            continuation.finish(throwing: StreamdError.closed)
                            return
                        }
                    }
                    guard let more = try await iterator.next() else {
                        continuation.finish(throwing: StreamdError.closed)
                        return
                    }
                    buffer.append(more)
                }
                continuation.finish()
            } catch {
                logger.trace("[\(host)] Streamd session ended: \(error)")
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in reader.cancel() }
        return Session(sessionID: sessionID, stream: stream, connection: connection, reader: reader)
    }

    /// `{"type":"notification","params":{"event_type":"stream_status","status":"finished"}}` (6).
    static func isFinished(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let params = object["params"] as? [String: Any] else { return false }
        return params["event_type"] as? String == "stream_status" && params["status"] as? String == "finished"
    }

    static func boundary(of contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=") else { return nil }
        let value = contentType[range.upperBound...].split(separator: ";").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The login was refused; `triedSHA256` says whether the MD5 is still to try.
enum StreamdHandshakeError: Error {
    case refused(triedSHA256: Bool)
}

/// Moves a value that is used by one task at a time across an isolation boundary.
struct UnsafeTransfer<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Runs `body`, or calls `onTimeout` and throws `StreamdError.silent` once `timeout` passes first.
func withDeadline<T: Sendable>(_ timeout: Duration, onTimeout: @escaping @Sendable () async -> Void, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw StreamdError.silent }
        if let first { return first }
        await onTimeout()
        throw StreamdError.silent
    }
}
