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
        let authority = trimmed.contains(":") && !trimmed.hasPrefix("[") ? "[\(trimmed)]" : trimmed
        guard !trimmed.isEmpty, let base = URL(string: "http://\(authority):\(port)") else { return nil }
        self.host = trimmed
        self.port = port
        self.base = base
        self.transport = transport
        digest = DigestAuthentication(username: username, password: password)
    }

    /// A request for `target` (a path and query, sent as written), its URL the same for the client's connection.
    private func request(_ target: String, timeout: Duration) -> HomeswiftNetwork.HTTPRequest {
        var request = HomeswiftNetwork.HTTPRequest(method: "GET", url: base.appendingPathComponent(String(target.prefix { $0 != "?" }.dropFirst())), timeout: timeout)
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
        var response = try await transport.send(authorized(target, timeout: timeout))
        if response.status == 401 {
            guard let challenge = response.header("WWW-Authenticate"), digest.accept(challenge: challenge) else { throw DahuaError.wrongPassword }
            // A challenge kept from before may have gone stale: one more try with the new one.
            response = try await transport.send(authorized(target, timeout: timeout))
            if response.status == 401 {
                digest.clear()
                throw DahuaError.wrongPassword
            }
        }
        try Self.check(response.status)
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
            let serial = parts[1].trimmingCharacters(in: .whitespaces)
            if !serial.isEmpty, serial.count <= 64, serial.allSatisfy({ $0.isLetter || $0.isNumber }) { return serial }
        }
        return nil
    }

    /// The serial in a Digest realm `Login to <serial>`, the form Dahua firmware gives it.
    static func serial(realm: String) -> String? {
        let prefix = "Login to "
        guard realm.hasPrefix(prefix) else { return nil }
        let serial = realm.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return !serial.isEmpty && serial.count <= 64 && serial.allSatisfy({ $0.isLetter || $0.isNumber }) ? serial : nil
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
        func open() async throws -> HTTPStreamingResponse {
            var request = authorized(target, timeout: .seconds(10))
            request.setHeader("Accept", "multipart/x-mixed-replace")
            return try await transport.stream(request)
        }
        var response = try await open()
        if response.status == 401 {
            guard let challenge = response.header("WWW-Authenticate"), digest.accept(challenge: challenge) else { throw DahuaError.wrongPassword }
            response = try await open()
            if response.status == 401 {
                digest.clear()
                throw DahuaError.wrongPassword
            }
        }
        try Self.check(response.status)
        return response
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
    private enum State { case boundary, headers(length: Int?), body(length: Int?) }
    private var state = State.boundary

    /// `boundary` from the response's `Content-Type` (`multipart/x-mixed-replace; boundary=myboundary`).
    init(contentType: String?) {
        var name = "myboundary"
        if let contentType, let range = contentType.range(of: "boundary=", options: .caseInsensitive) {
            let value = contentType[range.upperBound...].prefix { $0 != ";" }.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !value.isEmpty { name = value.hasPrefix("--") ? String(value.dropFirst(2)) : value }
        }
        boundary = Array("--\(name)".utf8)
    }

    /// The text of each part completed by these bytes.
    mutating func feed(_ bytes: [UInt8]) -> [String] {
        buffer += bytes
        var parts: [String] = []
        while true {
            switch state {
            case .boundary:
                guard let start = Self.find(boundary, in: buffer) else {
                    // Keep what could be the start of a boundary.
                    if buffer.count > boundary.count { buffer.removeFirst(buffer.count - boundary.count) }
                    return parts
                }
                guard let end = buffer[(start + boundary.count)...].firstIndex(of: 0x0A) else {
                    if start > 0 { buffer.removeFirst(start) }
                    return parts
                }
                buffer.removeFirst(end + 1)
                state = .headers(length: nil)
            case .headers(let length):
                guard let end = buffer.firstIndex(of: 0x0A) else {
                    if buffer.count > Self.maximumPart { reset() }
                    return parts
                }
                var line = buffer[..<end]
                if line.last == 0x0D { line = line.dropLast() }
                buffer.removeFirst(end + 1)
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
                    guard buffer.count >= length else { return parts }
                    parts.append(String(decoding: buffer[..<length], as: UTF8.self))
                    buffer.removeFirst(length)
                    state = .boundary
                } else {
                    guard let next = Self.find(boundary, in: buffer) else {
                        if buffer.count > Self.maximumPart { reset() }
                        return parts
                    }
                    parts.append(String(decoding: buffer[..<next], as: UTF8.self))
                    buffer.removeFirst(next)
                    state = .boundary
                }
            }
        }
    }

    private mutating func reset() {
        buffer.removeAll()
        state = .boundary
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count, let first = needle.first else { return nil }
        var index = 0
        while index <= haystack.count - needle.count {
            if haystack[index] == first, haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }
}

/// The local RTSP address of a channel (section 5.4): Dahua's `cam/realmonitor`, the user and password percent-encoded.
func dahuaRTSPURL(host: String, port: Int, username: String, password: String, channel: Int, subStream: Bool) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let user = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
    let pass = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password
    let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    return "rtsp://\(user):\(pass)@\(authority):\(port)/cam/realmonitor?channel=\(channel)&subtype=\(subStream ? 1 : 0)"
}
