import Foundation
import Testing

@testable import Homeswift

/// The request parser reads what the Foundation version it replaced read: the same requests, headers, bodies and
/// leftovers, and the same refusals.
@Suite struct HTTPParseTests {
    /// The parser before it went byte by byte, kept as the reference.
    static func reference(_ buffer: inout Data) throws -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            if buffer.count > 16 * 1024 { throw HTTPRequest.ParseError.malformed }
            return nil
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { throw HTTPRequest.ParseError.malformed }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { throw HTTPRequest.ParseError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length < 1024 * 1024 else { throw HTTPRequest.ParseError.malformed }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        return HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: body)
    }

    static func outcome(_ parse: (inout Data) throws -> HTTPRequest?, _ input: Data) -> String {
        var buffer = input
        do {
            guard let request = try parse(&buffer) else { return "more, \(buffer.count) left" }
            return "\(request.method) \(request.target) \(request.headers.sorted { $0.key < $1.key }) \(request.body.base64EncodedString()) | \(buffer.base64EncodedString())"
        } catch {
            return "malformed"
        }
    }

    @Test func readsWhatTheFoundationParserRead() throws {
        let spaces = ["", " ", "  ", "\t", " \t ", "\u{a0}", "\u{3000}", "\u{2009}", "\u{200b}", "\n", "\r"]
        let names = ["Content-Length", "content-type", "Host", "X-Test", "Ünïcode", "Empty", "", "Content-length", "a\u{600}", "e\u{301}"]
        let values = ["0", "5", "12", "-1", "abc", "2000000", "application/hap+json", "a b", "x:y", "é", "", ":\u{301}x", "\u{600}:y", "a:\u{301}b", "\r", "\u{0}"]
        let lines = ["GET /accessories HTTP/1.1", "PUT /characteristics HTTP/1.1", "POST /pair-setup HTTP/1.1", "GET", "", " GET /x", "GET  /a?b=c HTTP/1.1"]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            var head = lines.randomElement(using: &generator)!
            for _ in 0..<Int.random(in: 0...4, using: &generator) {
                let space = { spaces.randomElement(using: &generator)! }
                head += "\r\n" + space() + names.randomElement(using: &generator)! + space() + (Bool.random(using: &generator) ? ":" : "") + space() + values.randomElement(using: &generator)! + space()
            }
            if Int.random(in: 0..<8, using: &generator) == 0 { head += "\r\n" }
            var bytes = Data(head.utf8) + Data("\r\n\r\n".utf8) + Data((0..<Int.random(in: 0...20, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
            if Int.random(in: 0..<10, using: &generator) == 0 { bytes.insert(0xFF, at: Int.random(in: 0..<bytes.count, using: &generator)) }
            if Int.random(in: 0..<6, using: &generator) == 0 { bytes = bytes.prefix(Int.random(in: 0...bytes.count, using: &generator)) }
            // A slice of a larger buffer too, whose indices do not start at zero.
            let sliced = (Data("junk".utf8) + bytes).dropFirst(4)
            for input in [bytes, Data(sliced)] + [sliced] {
                #expect(Self.outcome(HTTPRequest.parse, input) == Self.outcome(Self.reference, input), "\(head.debugDescription)")
            }
        }
        // Two requests in one buffer: the first comes off, the second stays.
        var two = Data("GET /a HTTP/1.1\r\nContent-Length: 2\r\n\r\nhiGET /b HTTP/1.1\r\n\r\n".utf8)
        #expect(try HTTPRequest.parse(&two)?.body == Data("hi".utf8))
        #expect(try HTTPRequest.parse(&two)?.target == "/b")
        #expect(two.isEmpty)
    }
}
