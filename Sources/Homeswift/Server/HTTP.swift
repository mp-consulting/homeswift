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

    /// The largest body read: a characteristic write, a camera's resource request.
    static let maxBody = 1024 * 1024

    /// Takes one complete request off the front of `buffer`, or returns nil if more bytes are needed. A body longer
    /// than `maxBody` is refused before it is read.
    static func parse(_ buffer: inout Data, maxBody: Int = maxBody) throws -> HTTPRequest? {
        // The head's end, its lines and their spaces are found byte by byte: Foundation's search, line splitting and
        // character-set trimming took a fifth of a request's time on the server.
        let headEnd: Int? = buffer.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count >= 4 else { return nil }
            for index in 0...(bytes.count - 4) where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
                return index
            }
            return nil
        }
        guard let headEnd else {
            if buffer.count > 16 * 1024 { throw ParseError.malformed }
            return nil
        }
        let headStart = buffer.startIndex
        let headBytes = buffer[headStart..<(headStart + headEnd)]
        // Decoding replaces invalid UTF-8, so the head is valid exactly when its bytes come back unchanged.
        var head = String(decoding: headBytes, as: UTF8.self)
        let valid = head.utf8.count == headBytes.count && head.withUTF8 { decoded in
            headBytes.withUnsafeBytes { raw in decoded.isEmpty || memcmp(decoded.baseAddress!, raw.baseAddress!, decoded.count) == 0 }
        }
        guard valid else { throw ParseError.malformed }
        let lines = Self.lines(of: head)
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { throw ParseError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = Self.colon(in: line) else { continue }
            let name = Self.trimmed(line[..<colon]).lowercased()
            headers[name] = Self.trimmed(line[line.index(after: colon)...])
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length < maxBody else { throw ParseError.malformed }
        let bodyStart = headStart + headEnd + 4
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        return HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: body)
    }

    /// The first character that is a colon, as `firstIndex(of: ":")` finds it: its byte, then a check that a character
    /// starts there and is that colon alone (not one a combining mark joins), without walking every character.
    static func colon(in line: Substring) -> String.Index? {
        var from = line.utf8.startIndex
        while let index = line.utf8[from...].firstIndex(of: UInt8(ascii: ":")) {
            if line[index] == ":", line.index(before: line.index(after: index)) == index { return index }
            from = line.utf8.index(after: index)
        }
        return nil
    }

    /// The text between CRLFs, empty lines included: what `components(separatedBy: "\r\n")` gives.
    static func lines(of head: String) -> [Substring] {
        var lines: [Substring] = []
        let utf8 = head.utf8
        var lineStart = utf8.startIndex
        var index = utf8.startIndex
        while index != utf8.endIndex {
            let next = utf8.index(after: index)
            if utf8[index] == 13, next != utf8.endIndex, utf8[next] == 10 {
                lines.append(head[lineStart..<index])
                index = utf8.index(after: next)
                lineStart = index
            } else {
                index = next
            }
        }
        lines.append(head[lineStart...])
        return lines
    }

    /// Without the spaces and tabs around it: what `trimmingCharacters(in: .whitespaces)` removes, the set itself
    /// asked only beyond ASCII (where it holds the space and the tab; beyond, Unicode's space separators and U+200B).
    static func trimmed(_ text: Substring) -> String {
        func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII ? scalar == " " || scalar == "\t" : CharacterSet.whitespaces.contains(scalar)
        }
        var scalars = text.unicodeScalars[...]
        while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
        while let last = scalars.last, isSpace(last) { scalars.removeLast() }
        return String(Substring(scalars))
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

    static func json(_ status: Int, _ value: some JSONWritable) -> HTTPResponse {
        var json = JSONWriter()
        value.write(to: &json)
        return HTTPResponse(status: status, contentType: hapJSON, body: Data(json.bytes))
    }

    static func hapStatus(_ status: Int, _ code: HAPStatus) -> HTTPResponse {
        json(status, StatusJSON(status: code.rawValue))
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
    static let decoder = JSONDecoder()
}
