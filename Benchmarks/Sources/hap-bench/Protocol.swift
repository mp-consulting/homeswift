import Crypto
import Foundation

// The controller side of HAP over IP, copied from Sources/Homeswift so the client is independent of the
// server's build: TLV8, SRP-6a (client), the pairing crypto helpers, the encrypted session framing and the
// HTTP response parser (HAP-NodeJS answers through Node's http module, so bodies may be chunked).

// MARK: TLV8

enum TLVType: UInt8 {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case retryDelay = 0x08
    case certificate = 0x09
    case signature = 0x0A
    case permissions = 0x0B
    case fragmentData = 0x0C
    case fragmentLast = 0x0D
    case sessionID = 0x0E
    case flags = 0x13
    case separator = 0xFF
}

enum TLVError: UInt8, Error {
    case unknown = 0x01
    case authentication = 0x02
    case backoff = 0x03
    case maxPeers = 0x04
    case maxTries = 0x05
    case unavailable = 0x06
    case busy = 0x07
}

struct TLV8: Equatable {
    struct Item: Equatable {
        var type: UInt8
        var value: Data
    }

    var items: [Item] = []

    init(_ items: [Item] = []) { self.items = items }

    init(decoding data: Data) throws {
        var index = data.startIndex
        var lastFragmentWasFull = false
        while index < data.endIndex {
            guard data.distance(from: index, to: data.endIndex) >= 2 else { throw TLVError.unknown }
            let type = data[index]
            let length = Int(data[data.index(after: index)])
            let start = data.index(index, offsetBy: 2)
            guard data.distance(from: start, to: data.endIndex) >= length else { throw TLVError.unknown }
            let end = data.index(start, offsetBy: length)
            let value = Data(data[start..<end])
            if lastFragmentWasFull, let last = items.last, last.type == type {
                items[items.count - 1].value.append(value)
            } else {
                items.append(Item(type: type, value: value))
            }
            lastFragmentWasFull = length == 255
            index = end
        }
    }

    subscript(type: TLVType) -> Data? {
        items.first { $0.type == type.rawValue }?.value
    }

    func byte(_ type: TLVType) -> UInt8? {
        self[type]?.first
    }

    mutating func append(_ type: TLVType, _ value: Data) {
        items.append(Item(type: type.rawValue, value: value))
    }

    mutating func append(_ type: TLVType, _ byte: UInt8) {
        append(type, Data([byte]))
    }

    var groups: [TLV8] {
        var groups: [TLV8] = [TLV8()]
        for item in items {
            if item.type == TLVType.separator.rawValue {
                groups.append(TLV8())
            } else {
                groups[groups.count - 1].items.append(item)
            }
        }
        return groups.filter { !$0.items.isEmpty }
    }

    func encoded() -> Data {
        var out = Data()
        for item in items {
            if item.value.isEmpty {
                out.append(item.type)
                out.append(0)
                continue
            }
            var offset = item.value.startIndex
            while offset < item.value.endIndex {
                let end = item.value.index(offset, offsetBy: 255, limitedBy: item.value.endIndex) ?? item.value.endIndex
                out.append(item.type)
                out.append(UInt8(item.value.distance(from: offset, to: end)))
                out.append(item.value[offset..<end])
                offset = end
            }
        }
        return out
    }
}

// MARK: SRP-6a (controller side)

/// SRP-6a with the RFC 5054 3072-bit group and SHA-512, as HAP pair setup uses it.
enum SRP {
    static let modulusHex =
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF"
    static let username = "Pair-Setup"

    static let modulusBytes: Data = {
        var data = Data()
        var index = modulusHex.startIndex
        while index < modulusHex.endIndex {
            let next = modulusHex.index(index, offsetBy: 2)
            data.append(UInt8(modulusHex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }()

    static let field = ModularField(modulusBytes: modulusBytes)
    static let g = field.number(5)
    static let gBytes = Data([5])

    static func H(_ parts: Data...) -> Data {
        var hasher = SHA512()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    /// k = H(N | PAD(g))
    static let k = field.number(H(modulusBytes, field.bytes(g)))!

    /// x = H(s | H(I ":" P))
    static func x(salt: Data, password: String) -> Data {
        H(salt, H(Data("\(username):\(password)".utf8)))
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// M1 = H(H(N) xor H(g), H(I), s, A, B, K)
    static func clientProof(salt: Data, A: Data, B: Data, K: Data) -> Data {
        let xor = Data(zip(H(modulusBytes), H(gBytes)).map { $0 ^ $1 })
        return H(xor, H(Data(username.utf8)), salt, A, B, K)
    }

    struct Client {
        let privateKey: Data
        let publicKey: Data

        init(privateKey: Data = SRP.randomBytes(32)) {
            self.privateKey = privateKey
            publicKey = field.bytes(field.power(g, privateKey))
        }

        func proof(salt: Data, serverPublicKey B: Data, password: String) -> (sessionKey: Data, proof: Data, expectedServerProof: Data) {
            let bValue = field.number(B) ?? field.number(0)
            let u = SRP.H(publicKey, field.bytes(bValue))
            let x = SRP.x(salt: salt, password: password)
            // S = (B - k*g^x) ^ (a + u*x) = base^a * (base^u)^x
            let base = field.subtract(bValue, field.multiply(k, field.power(g, x)))
            let S = field.multiply(field.power(base, privateKey), field.power(field.power(base, u), x))
            let K = SRP.H(field.bytes(S))
            let M1 = SRP.clientProof(salt: salt, A: publicKey, B: field.bytes(bValue), K: K)
            return (K, M1, SRP.H(publicKey, M1, K))
        }
    }
}

// MARK: Pairing crypto

enum HAPCrypto {
    static func hkdf(_ inputKeyMaterial: Data, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    static func nonce(_ label: String) -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        bytes.append(Data(label.utf8))
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    static func nonce(counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func open(_ data: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) throws -> Data {
        guard data.count >= 16 else { throw TLVError.authentication }
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16))
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }
}

extension SharedSecret {
    var data: Data { withUnsafeBytes { Data($0) } }
}

extension SymmetricKey {
    var data: Data { withUnsafeBytes { Data($0) } }
}

// MARK: Session framing

/// The encrypted framing used after pair verify, from the controller's side.
struct SecureSession {
    static let maxFrame = 1024

    private let readKey: SymmetricKey
    private let writeKey: SymmetricKey
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0

    init(sharedSecret: Data) {
        readKey = HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
        writeKey = HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
    }

    mutating func encrypt(_ plaintext: Data) throws -> Data {
        let frames = max(1, (plaintext.count + Self.maxFrame - 1) / Self.maxFrame)
        var out = Data(capacity: plaintext.count + frames * 18)
        var offset = plaintext.startIndex
        repeat {
            let end = plaintext.index(offset, offsetBy: Self.maxFrame, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
            let length = UInt16(end - offset)
            let aad = Data([UInt8(length & 0xFF), UInt8(length >> 8)])
            let sealed = try HAPCrypto.seal(plaintext[offset..<end], key: writeKey, nonce: HAPCrypto.nonce(counter: writeCounter), aad: aad)
            writeCounter += 1
            out.append(aad)
            out.append(sealed)
            offset = end
        } while offset < plaintext.endIndex
        return out
    }

    mutating func decrypt(_ buffer: inout Data) throws -> Data {
        var out = Data()
        var start = buffer.startIndex
        while buffer.endIndex - start >= 2 {
            let length = Int(buffer[start]) | Int(buffer[start + 1]) << 8
            guard length <= Self.maxFrame else { throw TLVError.authentication }
            let total = 2 + length + 16
            guard buffer.endIndex - start >= total else { break }
            let aad = Data(buffer[start..<start + 2])
            out.append(try HAPCrypto.open(buffer[start + 2..<start + total], key: readKey, nonce: HAPCrypto.nonce(counter: readCounter), aad: aad))
            readCounter += 1
            start += total
        }
        if start != buffer.startIndex { buffer = Data(buffer[start...]) }
        return out
    }
}

// MARK: HTTP responses and events

struct HTTPMessage {
    var version: String
    var status: Int
    var headers: [String: String]
    var body: Data

    var isEvent: Bool { version.hasPrefix("EVENT") }
    var json: Any? { try? JSONSerialization.jsonObject(with: body) }

    enum ParseError: Error { case malformed }

    /// Takes one complete response (or event) off the front of `buffer`, or returns nil if more bytes are needed.
    static func parse(_ buffer: inout Data) throws -> HTTPMessage? {
        let crlf = Data("\r\n".utf8)
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 64 * 1024 { throw ParseError.malformed }
            return nil
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw ParseError.malformed
        }
        let lines = head.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { throw ParseError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var cursor = headerEnd.upperBound
        var body = Data()
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while true {
                guard let lineEnd = buffer[cursor...].range(of: crlf) else { return nil }
                let sizeText = String(decoding: buffer[cursor..<lineEnd.lowerBound], as: UTF8.self)
                    .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(sizeText, radix: 16) else { throw ParseError.malformed }
                cursor = lineEnd.upperBound
                if size == 0 {
                    guard let end = buffer[cursor...].range(of: crlf) else { return nil }
                    cursor = end.upperBound
                    break
                }
                guard buffer.endIndex - cursor >= size + 2 else { return nil }
                body.append(buffer[cursor..<cursor + size])
                cursor += size + 2
            }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard buffer.endIndex - cursor >= length else { return nil }
            body = Data(buffer[cursor..<cursor + length])
            cursor += length
        }
        buffer = Data(buffer[cursor...])
        return HTTPMessage(version: String(statusLine[0]), status: status, headers: headers, body: body)
    }
}
