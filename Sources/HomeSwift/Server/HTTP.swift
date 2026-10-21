import Foundation

/// The minimal HTTP/1.1 HAP uses: one request at a time, bodies sized by Content-Length.
struct HTTPRequest {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data

    var path: String {
        target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    }

    var query: [String: String] {
        guard let index = target.firstIndex(of: "?") else { return [:] }
        var result: [String: String] = [:]
        for pair in target[target.index(after: index)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            result[key] = value
        }
        return result
    }

    enum ParseError: Error { case malformed }

    /// Takes one complete request off the front of `buffer`, or returns nil if more bytes are needed.
    static func parse(_ buffer: inout Data) throws -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            if buffer.count > 16 * 1024 { throw ParseError.malformed }
            return nil
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw ParseError.malformed
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { throw ParseError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length < 1024 * 1024 else { throw ParseError.malformed }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        return HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: body)
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String?
    var body: Data

    static let hapJSON = "application/hap+json"
    static let pairingTLV = "application/pairing+tlv8"

    init(status: Int, contentType: String? = nil, body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    static func tlv(_ tlv: TLV8) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: pairingTLV, body: tlv.encoded())
    }

    static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        HTTPResponse(status: status, contentType: hapJSON, body: (try? HAPJSON.encoder.encode(value)) ?? Data())
    }

    static func hapStatus(_ status: Int, _ code: HAPStatus) -> HTTPResponse {
        json(status, ["status": code.rawValue])
    }

    static let noContent = HTTPResponse(status: 204)

    func serialized(protocol proto: String = "HTTP/1.1") -> Data {
        var head = "\(proto) \(status) \(Self.reason(status))\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 207: "Multi-Status"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 422: "Unprocessable Entity"
        case 470: "Connection Authorization Required"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Unknown"
        }
    }
}

enum HAPJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    static let decoder = JSONDecoder()
}
