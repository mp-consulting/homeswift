import Foundation
import HomeswiftAI
import HomeswiftNetwork

// A camera on the LAN (docs/clean-room/Imou.md, sections 5.3 and 5.4): IMOU cameras run Dahua's firmware, whose HTTP CGI
// answers with Digest authentication, the user `admin` and the safety code as its password unless it was changed.

/// What reaches a camera: the HTTP client, or a fake camera in tests.
typealias DahuaTransport = HTTPSending & HTTPStreaming

enum DahuaError: Error, CustomStringConvertible, Equatable {
    /// A 401 to a request that carried the Digest answer: the password (the safety code) is wrong.
    case wrongPassword
    /// The CGI is not there (404, 501…): some models and firmwares leave it out.
    case unsupported(Int)
    case http(Int)
    case notAPicture
    /// The event stream went 30 seconds without a part or a heartbeat.
    case silent

    var description: String {
        switch self {
        case .wrongPassword: "the camera refused the user name and safety code"
        case .unsupported(let status): "the camera has no such CGI (HTTP \(status))"
        case .http(let status): "the camera answered HTTP \(status)"
        case .notAPicture: "the camera's snapshot is not a JPEG"
        case .silent: "the camera's event stream went silent"
        }
    }
}

/// The CGI of one camera, signed in with Digest: the challenge of the first 401 is kept, so later requests answer it at
/// once.
actor DahuaClient {
    nonisolated let host: String
    nonisolated let port: Int
    private let transport: any DahuaTransport
    private var digest: DigestAuthentication
    private let base: URL

    init?(host: String, port: Int, username: String, password: String, transport: any DahuaTransport) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let base = URL(string: "http://\(hostHeader(host: trimmed, port: port, defaultPort: -1))") else { return nil }
        self.host = trimmed
        self.port = port
        self.base = base
        self.transport = transport
        digest = DigestAuthentication(username: username, password: password)
    }

    /// A request for `target` (a path and query, sent as written): the URL says only where to connect.
    private func request(_ target: String, timeout: Duration) -> HomeswiftNetwork.HTTPRequest {
        var request = HomeswiftNetwork.HTTPRequest(method: "GET", url: base, timeout: timeout)
        request.target = target
        return request
    }

    private func authorized(_ target: String, timeout: Duration) -> HomeswiftNetwork.HTTPRequest {
        var request = request(target, timeout: timeout)
        if let header = digest.authorization(method: "GET", uri: target) { request.setHeader("Authorization", header) }
        return request
    }

    /// A GET answered in full; a 401 is answered once with Digest.
    func get(_ target: String, timeout: Duration = .seconds(10)) async throws -> HomeswiftNetwork.HTTPResponse {
        try await signed(target, timeout: timeout, status: \.status, challenge: { $0.header("WWW-Authenticate") }) { try await self.transport.send($0) }
    }

    /// Sends `target` with the Digest answer kept, and once more with the challenge of a 401 (one kept from before may have
    /// gone stale); a second 401 is a wrong password.
    private func signed<Response>(_ target: String, timeout: Duration, headers: [(String, String)] = [], status: (Response) -> Int,
                                  challenge: (Response) -> String?, send: (HomeswiftNetwork.HTTPRequest) async throws -> Response) async throws -> Response {
        func attempt() async throws -> Response {
            var request = authorized(target, timeout: timeout)
            for (name, value) in headers { request.setHeader(name, value) }
            return try await send(request)
        }
        var response = try await attempt()
        if status(response) == 401 {
            guard let header = challenge(response), digest.accept(challenge: header) else { throw DahuaError.wrongPassword }
            response = try await attempt()
            if status(response) == 401 {
                digest.clear()
                throw DahuaError.wrongPassword
            }
        }
        try Self.check(status(response))
        return response
    }

    static func check(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401: throw DahuaError.wrongPassword
        case 404, 405, 501: throw DahuaError.unsupported(status)
        default: throw DahuaError.http(status)
        }
    }

    /// `magicBox.cgi?action=getSerialNo`: `sn=<serial>` (Dahua's HTTP API); the serial is the cloud's Device Id.
    func serialNumber() async throws -> String {
        let response = try await get("/cgi-bin/magicBox.cgi?action=getSerialNo")
        guard let serial = Self.serial(String(decoding: response.body.prefix(1024), as: UTF8.self)) else { throw DahuaError.http(response.status) }
        return serial
    }

    /// The `sn=` line of a `getSerialNo` answer, letters and digits only.
    static func serial(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "sn" else { continue }
            if let serial = validSerial(parts[1].trimmingCharacters(in: .whitespaces)) { return serial }
        }
        return nil
    }

    /// The serial in a Digest realm `Login to <serial>`, the form Dahua firmware gives it.
    static func serial(realm: String) -> String? {
        let prefix = "Login to "
        guard realm.hasPrefix(prefix) else { return nil }
        return validSerial(realm.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
    }

    /// A serial of 1 to 64 ASCII letters and digits.
    private static func validSerial(_ serial: String) -> String? {
        !serial.isEmpty && serial.count <= 64 && serial.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? serial : nil
    }

    /// The realm of the camera's challenge, asked without credentials; nil when it gives none.
    func realm() async throws -> String? {
        let response = try await transport.send(request("/cgi-bin/magicBox.cgi?action=getSerialNo", timeout: .seconds(10)))
        return response.header("WWW-Authenticate").flatMap(DigestAuthentication.Challenge.init(header:))?.realm
    }

    /// `snapshot.cgi?channel=<n>`: a JPEG (n is the cloud's channel plus one).
    func snapshot(channel: Int) async throws -> Data {
        let response = try await get("/cgi-bin/snapshot.cgi?channel=\(channel)", timeout: .seconds(10))
        guard response.body.starts(with: [0xFF, 0xD8]) else { throw DahuaError.notAPicture }
        return response.body
    }

    /// `eventManager.cgi?action=attach`: the never-ending multipart stream of the camera's events, a heartbeat every five
    /// seconds. The codes go in brackets, sent as written.
    func events(codes: [String]) async throws -> HTTPStreamingResponse {
        let target = "/cgi-bin/eventManager.cgi?action=attach&codes=[\(codes.joined(separator: ","))]&heartbeat=5"
        return try await signed(target, timeout: .seconds(10), headers: [("Accept", "multipart/x-mixed-replace")], status: \.status,
                                challenge: { $0.header("WWW-Authenticate") }) { try await self.transport.stream($0) }
    }
}

/// One event of the stream: `Code=<code>;action=<Start|Stop|Pulse>;index=<n>[;data={…}]`.
struct DahuaEvent: Sendable, Equatable {
    enum Action: String, Sendable { case start = "Start", stop = "Stop", pulse = "Pulse" }

    var code: String
    var action: Action
    /// The zero-based channel: the cloud's `channelId`.
    var index: Int
    var data: JSONValue?

    init(code: String, action: Action, index: Int, data: JSONValue? = nil) {
        self.code = code
        self.action = action
        self.index = index
        self.data = data
    }

    /// A part's text; nil for a heartbeat or anything else.
    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var head = Substring(trimmed)
        var data: JSONValue?
        if let range = trimmed.range(of: ";data=") {
            head = trimmed[..<range.lowerBound]
            data = try? JSONValue(string: String(trimmed[range.upperBound...]))
        }
        var fields: [String: String] = [:]
        for pair in head.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        guard let code = fields["Code"], !code.isEmpty, let action = fields["action"].flatMap(Action.init(rawValue:)) else { return nil }
        self.code = String(code.prefix(64))
        self.action = action
        index = fields["index"].flatMap { Int($0) }.map { min(max($0, 0), 255) } ?? 0
        self.data = data
    }
}

/// The multipart body of the event stream, parsed by each part's `Content-Length` (a part without one ends at the next
/// boundary), CRLF or LF, across any chunking. Bounded: a part over 64 KiB is dropped.
struct DahuaMultipartParser {
    static let maximumPart = 64 * 1024

    private let boundary: [UInt8]
    private var buffer: [UInt8] = []
    /// Where the unread bytes of `buffer` start: what is read is dropped once a feed, not once a line.
    private var start = 0
    private enum State { case boundary, headers(length: Int?), body(length: Int?) }
    private var state = State.boundary

    /// `boundary` from the response's `Content-Type` (`multipart/x-mixed-replace; boundary=myboundary`).
    init(contentType: String?) {
        var name = "myboundary"
        if let contentType, let range = contentType.range(of: "boundary=", options: .caseInsensitive) {
            let value = contentType[range.upperBound...].prefix { $0 != ";" }.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !value.isEmpty { name = String((value.hasPrefix("--") ? String(value.dropFirst(2)) : value).prefix(70)) }
        }
        boundary = Array("--\(name)".utf8)
    }

    /// The text of each part completed by these bytes.
    mutating func feed(_ bytes: [UInt8]) -> [String] {
        buffer += bytes
        var parts: [String] = []
        defer { compact() }
        while true {
            switch state {
            case .boundary:
                guard let at = find(boundary) else {
                    // Keep what could be the start of a boundary.
                    start = max(start, buffer.count - boundary.count)
                    return parts
                }
                guard let end = buffer[(at + boundary.count)...].firstIndex(of: 0x0A) else {
                    start = at
                    if buffer.count - start > Self.maximumPart { reset() }
                    return parts
                }
                start = end + 1
                state = .headers(length: nil)
            case .headers(let length):
                guard let end = buffer[start...].firstIndex(of: 0x0A) else {
                    if buffer.count - start > Self.maximumPart { reset() }
                    return parts
                }
                var line = buffer[start..<end]
                if line.last == 0x0D { line = line.dropLast() }
                start = end + 1
                let text = String(decoding: line, as: UTF8.self)
                if text.isEmpty {
                    state = .body(length: length)
                } else if let colon = text.firstIndex(of: ":"), text[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    // A length out of bounds is kept as -1: the part is skipped.
                    let value = Int(text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                    state = .headers(length: value.map { $0 >= 0 && $0 <= Self.maximumPart ? $0 : -1 } ?? length)
                }
            case .body(let length):
                if let length, length < 0 {
                    // Too large to keep: skip to the next part.
                    state = .boundary
                    continue
                }
                if let length {
                    guard buffer.count - start >= length else { return parts }
                    parts.append(String(decoding: buffer[start..<(start + length)], as: UTF8.self))
                    start += length
                    state = .boundary
                } else {
                    guard let next = find(boundary) else {
                        if buffer.count - start > Self.maximumPart { reset() }
                        return parts
                    }
                    parts.append(String(decoding: buffer[start..<next], as: UTF8.self))
                    start = next
                    state = .boundary
                }
            }
        }
    }

    private mutating func compact() {
        if start > 0 { buffer.removeFirst(min(start, buffer.count)) }
        start = 0
    }

    private mutating func reset() {
        buffer.removeAll()
        start = 0
        state = .boundary
    }

    /// The first `needle` in the unread bytes.
    private func find(_ needle: [UInt8]) -> Int? {
        guard let first = needle.first, buffer.count - start >= needle.count else { return nil }
        var index = start
        while index <= buffer.count - needle.count {
            if buffer[index] == first, buffer[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }
}

/// The local RTSP address of a channel (section 5.4): Dahua's `cam/realmonitor`, the user and password percent-encoded.
func dahuaRTSPURL(host: String, port: Int, username: String, password: String, channel: Int, subStream: Bool) -> String {
    "rtsp://\(URLEncoding.rfc3986(username)):\(URLEncoding.rfc3986(password))@\(hostHeader(host: host, port: port, defaultPort: -1))/cam/realmonitor?channel=\(channel)&subtype=\(subStream ? 1 : 0)"
}
