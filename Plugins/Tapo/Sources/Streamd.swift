import Crypto
import Foundation
import _CryptoExtras

/// The wire format of Streamd, the media server of Tapo battery cameras on TCP 8800 (docs/clean-room/TapoCamera.md):
/// an HTTP Digest login with a hash of the cloud password, then a multipart body each way, the camera's parts AES-128-CBC
/// encrypted MPEG-TS.
enum Streamd {
    static let port = 8800
    /// The user name of the Digest login and of the keys: always `admin`, never the cloud e-mail (1).
    static let username = "admin"
    static let clientBoundary = "--client-stream-boundary--"
    static let deviceBoundary = "--device-stream-boundary--"

    /// What the client asks for: the main stream (both lenses of a C675D, HEVC) or the sub stream (its tele lens, H.264).
    enum Resolution: String, Sendable, Equatable {
        case hd = "HD"
        case vga = "VGA"
    }

    /// The password as the camera checks it (3): the uppercase hex of its SHA-256 or MD5.
    static func passwordHash(_ password: String, sha256: Bool) -> String {
        let data = Data(password.utf8)
        return sha256 ? hex(SHA256.hash(data: data)).uppercased() : hex(Insecure.MD5.hash(data: data)).uppercased()
    }

    /// The request that opens a session, with the Digest answer once the camera asked for one (2).
    static func request(authorization: String? = nil) -> [UInt8] {
        var head = "POST /stream HTTP/1.1\r\nContent-Type: multipart/mixed;boundary=\(clientBoundary)\r\nConnection: keep-alive\r\nContent-Length: -1\r\n"
        if let authorization { head += "Authorization: \(authorization)\r\n" }
        head += "\r\n"
        return Array(head.utf8)
    }

    /// `key=value` pairs separated by commas or spaces, quotes removed, a leading scheme (`Digest`) skipped: the
    /// challenge and the `Key-Exchange` header. Tokens without `=` are skipped.
    static func fields(_ header: String) -> [String: String] {
        var fields: [String: String] = [:]
        var index = header.startIndex
        func skipSeparators() {
            while index < header.endIndex, header[index] == "," || header[index] == " " || header[index] == "\t" { index = header.index(after: index) }
        }
        while true {
            skipSeparators()
            guard index < header.endIndex else { break }
            let start = index
            while index < header.endIndex, header[index] != "=", header[index] != ",", header[index] != " " { index = header.index(after: index) }
            let key = String(header[start..<index]).lowercased()
            guard index < header.endIndex, header[index] == "=" else { continue }
            index = header.index(after: index)
            var value = ""
            if index < header.endIndex, header[index] == "\"" {
                index = header.index(after: index)
                while index < header.endIndex, header[index] != "\"" {
                    if header[index] == "\\", header.index(after: index) < header.endIndex { index = header.index(after: index) }
                    value.append(header[index])
                    index = header.index(after: index)
                }
                if index < header.endIndex { index = header.index(after: index) }
            } else {
                while index < header.endIndex, header[index] != ",", header[index] != " " {
                    value.append(header[index])
                    index = header.index(after: index)
                }
            }
            if !key.isEmpty { fields[key] = value }
        }
        return fields
    }

    /// Whether a challenge asks for the SHA-256 of the password (`encrypt_type="3"`), else its MD5 (3).
    static func wantsSHA256(_ challenge: [String: String]) -> Bool { challenge["encrypt_type"] == "3" }

    /// The `Authorization` value for a challenge (2.4): RFC 2617 MD5 Digest with qop `auth`, user `admin`, the password
    /// hash as the password.
    static func authorization(challenge: [String: String], passwordHash: String, cnonce: String) -> String? {
        guard let realm = challenge["realm"], let nonce = challenge["nonce"] else { return nil }
        let nc = "00000001"
        let ha1 = md5Hex("\(username):\(realm):\(passwordHash)")
        let ha2 = md5Hex("POST:/stream")
        let response = md5Hex("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
        var header = "Digest username=\"\(username)\",realm=\"\(realm)\",uri=\"/stream\",algorithm=MD5,nonce=\"\(nonce)\",nc=\(nc),cnonce=\"\(cnonce)\",qop=auth,response=\"\(response)\""
        if let opaque = challenge["opaque"] { header += ",opaque=\"\(opaque)\"" }
        return header
    }

    /// A random client nonce: 24 bytes in hex.
    static func randomCNonce() -> String { hex((0..<24).map { _ in UInt8.random(in: 0...255) }) }

    /// The keys of a session (4), from the 200's `Key-Exchange` and the password hash that signed in.
    struct Keys: Sendable {
        let key: SymmetricKey
        let iv: Data

        /// The fixed key of the `username="none"` variant (published with CVE-2022-37255).
        static let unencryptedSecret = "TPL075526460603"

        init?(keyExchange header: String, passwordHash: String) {
            let fields = Streamd.fields(header)
            guard let nonce = fields["nonce"], !nonce.isEmpty else { return nil }
            let user = fields["username"].flatMap { $0.isEmpty ? nil : $0 } ?? Streamd.username
            let secret = user == "none" ? Self.unencryptedSecret : passwordHash
            key = SymmetricKey(data: Data(Insecure.MD5.hash(data: Data("\(nonce):\(secret)".utf8))))
            iv = Data(Insecure.MD5.hash(data: Data("\(user):\(nonce)".utf8)))
        }

        /// One part's plaintext: each part is a CBC message of its own, from the same IV, PKCS#7 padded.
        func decrypt(_ body: Data) throws -> Data {
            guard !body.isEmpty, body.count % 16 == 0 else { throw StreamdError.invalidResponse("an encrypted part of \(body.count) bytes") }
            do {
                return try AES._CBC.decrypt(body, using: key, iv: AES._CBC.IV(ivBytes: iv))
            } catch {
                throw StreamdError.invalidResponse("a part that does not decrypt")
            }
        }

        func encrypt(_ plaintext: Data) throws -> Data {
            try AES._CBC.encrypt(plaintext, using: key, iv: AES._CBC.IV(ivBytes: iv))
        }
    }

    /// The live view request (6), compact as the camera expects it.
    static func previewRequest(channel: Int, resolution: Resolution) -> String {
        #"{"params":{"preview":{"audio":["default"],"channels":[\#(channel)],"resolutions":["\#(resolution.rawValue)"]},"method":"get"},"seq":1,"type":"request"}"#
    }

    /// A JSON part from the client (5.1), in clear.
    static func jsonPart(_ json: String) -> [UInt8] {
        let body = Array(json.utf8)
        return Array("--\(clientBoundary)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body + Array("\r\n".utf8)
    }

    /// Codes the camera answers when it already serves as many viewers as it can (6).
    static let busyCodes: Set<Int> = [-52405, -52407, -52417, -52435]

    static func md5Hex(_ text: String) -> String { hex(Insecure.MD5.hash(data: Data(text.utf8))) }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum StreamdError: Error, Equatable, CustomStringConvertible {
    /// The camera refused both hashes of the password.
    case invalidCredentials
    /// The camera serves as many viewers as it can.
    case busy(Int)
    /// The camera refused the request with this code.
    case refused(Int)
    case invalidResponse(String)
    /// Nothing came for the silence timeout: the camera went to standby, or its connection hangs.
    case silent
    case closed

    var description: String {
        switch self {
        case .invalidCredentials: "the camera refused the Tapo account's password"
        case .busy(let code): "the camera has too many viewers (\(code))"
        case .refused(let code): "the camera refused the stream (\(code))"
        case .invalidResponse(let what): "unexpected answer: \(what)"
        case .silent: "the camera stopped sending"
        case .closed: "the camera closed the connection"
        }
    }
}

/// Bytes as they come off a connection, read as HTTP heads and multipart parts.
struct StreamdBuffer {
    private(set) var bytes: [UInt8] = []
    private var start = 0

    var count: Int { bytes.count - start }

    mutating func append(_ more: [UInt8]) {
        if start > 0, start >= bytes.count / 2 {
            bytes.removeFirst(start)
            start = 0
        }
        bytes.append(contentsOf: more)
    }

    /// The index of `pattern` at or after `start`, or nil.
    func find(_ pattern: [UInt8], from offset: Int = 0) -> Int? {
        guard let first = pattern.first, count >= pattern.count else { return nil }
        var index = start + offset
        let last = bytes.count - pattern.count
        while index <= last {
            if bytes[index] == first {
                var matches = true
                for k in 1..<pattern.count where bytes[index + k] != pattern[k] {
                    matches = false
                    break
                }
                if matches { return index - start }
            }
            index += 1
        }
        return nil
    }

    mutating func drop(_ n: Int) { start = min(bytes.count, start + n) }

    mutating func take(_ n: Int) -> [UInt8] {
        let taken = Array(bytes[start..<start + n])
        start += n
        return taken
    }

    /// An HTTP response's status and headers (names lowercased), the bytes before its `HTTP/1.` skipped (2.3: a 401's
    /// body runs into the next status line); nil until the blank line has come.
    mutating func readHead() throws -> (status: Int, headers: [String: String])? {
        guard let at = find(Array("HTTP/1.".utf8)) else {
            if count > 64 * 1024 { throw StreamdError.invalidResponse("no HTTP answer") }
            return nil
        }
        guard let end = find(Array("\r\n\r\n".utf8), from: at) else {
            if count - at > 64 * 1024 { throw StreamdError.invalidResponse("an endless HTTP head") }
            return nil
        }
        drop(at)
        let head = String(decoding: take(end - at), as: UTF8.self)
        drop(4)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { throw StreamdError.invalidResponse("a status line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (status, headers)
    }

    /// The next part of a multipart body with `boundary` (5.2): what comes before its delimiter is skipped; nil until all
    /// of it has come.
    mutating func readPart(boundary: String) throws -> StreamdPart? {
        let delimiter = Array("--\(boundary)\r\n".utf8)
        guard let at = find(delimiter) else {
            // Keep a tail that may be the start of a delimiter.
            if count > delimiter.count { drop(count - delimiter.count) }
            return nil
        }
        guard let end = find(Array("\r\n\r\n".utf8), from: at + delimiter.count - 2) else {
            if count - at > 16 * 1024 { throw StreamdError.invalidResponse("an endless part head") }
            return nil
        }
        let headStart = at + delimiter.count
        let headLength = max(0, end - headStart)
        var headers: [String: String] = [:]
        if headLength > 0 {
            let head = String(decoding: bytes[(start + headStart)..<(start + headStart + headLength)], as: UTF8.self)
            for line in head.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let length = headers["content-length"].flatMap({ Int($0) }), length >= 0, length <= 16 * 1024 * 1024 else {
            throw StreamdError.invalidResponse("a part without a length")
        }
        let bodyStart = end + 4
        guard count >= bodyStart + length else { return nil }
        drop(bodyStart)
        let body = take(length)
        return StreamdPart(headers: headers, body: Data(body))
    }
}

/// One part of the camera's multipart body.
struct StreamdPart: Sendable, Equatable {
    var headers: [String: String]
    var body: Data

    var contentType: String { headers["content-type"]?.lowercased() ?? "" }
    var isEncrypted: Bool { headers["x-if-encrypt"] == "1" }
}
