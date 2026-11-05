import Foundation
import HomeswiftNetwork
import Logging

/// The charger's local HTTP interface (docs/clean-room/V2CTrydan.md, 3.1): plain HTTP on port 80, no authentication,
/// `GET /RealTimeData`, `GET /read/<Keyword>` and `GET /write/<Keyword>=<Value>`. One request at a time per charger:
/// its embedded server is small.
actor TrydanClient {
    /// A read is about 400 bytes: anything past this is not the charger.
    static let maximumBody = 16 * 1024

    let host: String
    let transport: any HTTPSending
    let timeout: Duration
    let logger: Logger
    /// The request in progress, which the next one waits for.
    private var tail: Task<Void, Never>?

    init(host: String, transport: any HTTPSending, timeout: Duration, logger: Logger) {
        self.host = host
        self.transport = transport
        self.timeout = timeout
        self.logger = logger
    }

    /// Every value at once, as an object (repaired when the firmware sent malformed JSON).
    func realTimeData() async throws -> TrydanJSON.Parsed {
        let response = try await get("RealTimeData")
        guard response.status == 200 else { throw Self.statusError(response) }
        do {
            return try TrydanJSON.parse(response.body)
        } catch {
            if case .invalidResponse(let excerpt) = error { logger.debug("The charger's answer is not JSON", metadata: ["host": "\(host)", "body": "\(excerpt)"]) }
            throw error
        }
    }

    /// One keyword's value, as a number; `TrydanError.unsupported` when this firmware does not know it (HTTP 404).
    func read(_ keyword: String) async throws -> Double {
        let response = try await get("read/\(keyword)")
        if response.status == 404 { throw TrydanError.unsupported(keyword) }
        guard response.status == 200 else { throw Self.statusError(response) }
        let text = String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text)?.finite else { throw TrydanError.invalidResponse("\(keyword) is not a number") }
        return value
    }

    /// Sets one keyword: done when the charger answers 200 and exactly `OK`.
    func write(_ keyword: String, _ value: Int) async throws {
        let response = try await get("write/\(keyword)=\(value)")
        let body = String(decoding: response.body.prefix(100), as: UTF8.self)
        guard response.status == 200, body == "OK" else {
            if response.status == 429 { throw Self.statusError(response) }
            throw TrydanError.writeRefused(keyword: keyword, status: response.status, body: body)
        }
    }

    /// The address's URL for a path; nil for an address that is not one.
    static func url(host: String, path: String) -> URL? {
        guard let host = TrydanIdentity.normalizedHost(host) else { return nil }
        return URL(string: "http://\(host)/\(path)")
    }

    private func get(_ path: String) async throws -> HTTPResponse {
        guard let url = Self.url(host: host, path: path) else { throw TrydanError.invalidHost(host) }
        let request = HTTPRequest(url: url, timeout: timeout)
        let transport = transport
        let previous = tail
        let task = Task<HTTPResponse, any Error> {
            await previous?.value
            return try await transport.send(request)
        }
        tail = Task { _ = try? await task.value }
        let response = try await task.value
        logger.debug("V2C Trydan request", metadata: ["host": "\(host)", "path": "/\(path)", "status": "\(response.status)", "bytes": "\(response.body.count)"])
        return response
    }

    /// A status other than 200; 429 with its `Retry-After`, from one minute to six hours.
    static func statusError(_ response: HTTPResponse) -> TrydanError {
        guard response.status == 429 else { return .status(response.status) }
        let seconds = response.header("Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 60
        return .rateLimited(.seconds(min(max(seconds, 60), 6 * 3600)))
    }
}
