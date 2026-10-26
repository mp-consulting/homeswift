import Crypto
import Foundation
import Homeswift

/// Sealed secrets in config.json. A secret a plugin must send back to its service (a password, a cloud token)
/// is stored as `enc:v1:` followed by base64 of ChaCha20-Poly1305's nonce, ciphertext and tag, under a random
/// 256-bit key in `secrets.key` beside config.json. Each value has its own random nonce, so equal secrets seal
/// to different text. The key file is owner-only; anyone with both files can read the secrets, so the sealing
/// keeps them out of copies of config.json, backups and version control, not out of reach of the bridge's owner.
public struct SecretBox: Sendable {
    public static let prefix = "enc:v1:"
    public static let fileName = "secrets.key"

    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// The key in `storage`'s key file, made on first use when `create` is true.
    public static func load(storage: URL, create: Bool) throws -> SecretBox {
        let url = storage.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            let stored = try JSONDecoder().decode(StoredKey.self, from: Data(contentsOf: url))
            guard stored.version == 1, let raw = Data(base64Encoded: stored.key), raw.count == 32 else {
                throw SecretBoxError.malformedKeyFile(url.path)
            }
            return SecretBox(key: SymmetricKey(data: raw))
        }
        guard create else { throw SecretBoxError.missingKeyFile(url.path) }
        let raw = Secrets.randomBytes(32)
        let data = try JSONEncoder().encode(StoredKey(version: 1, key: raw.base64EncodedString()))
        try OwnerOnlyFile.write(data, to: url)
        return SecretBox(key: SymmetricKey(data: raw))
    }

    /// `value` sealed as `enc:v1:…`.
    public func seal(_ value: String) throws -> String {
        let sealed = try ChaChaPoly.seal(Data(value.utf8), using: key)
        return Self.prefix + sealed.combined.base64EncodedString()
    }

    /// The plaintext of a sealed value; throws when the text is not sealed by this key.
    public func open(_ sealed: String) throws -> String {
        guard Self.isSealed(sealed), let combined = Data(base64Encoded: String(sealed.dropFirst(Self.prefix.count))) else {
            throw SecretBoxError.notSealed
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: combined)
            return String(decoding: try ChaChaPoly.open(box, using: key), as: UTF8.self)
        } catch {
            throw SecretBoxError.wrongKey
        }
    }

    public static func isSealed(_ value: String) -> Bool { value.hasPrefix(prefix) }

    /// `configuration` with its sealed secrets opened, as the runtime reads them. Only a config that holds sealed
    /// text needs the key file, so a config without any never touches it.
    public static func revealing(_ configuration: HomeswiftConfiguration, storage: URL) throws -> HomeswiftConfiguration {
        guard configuration.platforms.contains(where: { String(decoding: $0.json, as: UTF8.self).contains(prefix) }) else {
            return configuration
        }
        return try load(storage: storage, create: false).revealing(configuration)
    }

    /// `config` with every sealed string in its platform blocks and bridge opened, for the runtime to read.
    public func revealing(_ configuration: HomeswiftConfiguration) throws -> HomeswiftConfiguration {
        var result = configuration
        for index in result.platforms.indices {
            let block = try JSONValue(data: result.platforms[index].json)
            let revealed = try revealing(block)
            result.platforms[index].json = revealed.encoded()
            if var child = result.platforms[index].childBridge {
                child.pin = try child.pin.map(revealText)
                child.username = try child.username.map(revealText)
                result.platforms[index].childBridge = child
            }
        }
        return result
    }

    private func revealText(_ text: String) throws -> String {
        Self.isSealed(text) ? try open(text) : text
    }

    private func revealing(_ value: JSONValue) throws -> JSONValue {
        switch value {
        case .string(let text) where Self.isSealed(text): return .string(try open(text))
        case .array(let items): return .array(try items.map(revealing))
        case .object(let object): return .object(try object.mapValues(revealing))
        default: return value
        }
    }

    private struct StoredKey: Codable {
        var version: Int
        var key: String
    }
}

public enum SecretBoxError: Error, CustomStringConvertible, Equatable, Sendable {
    case missingKeyFile(String)
    case malformedKeyFile(String)
    case notSealed
    case wrongKey

    public var description: String {
        switch self {
        case .missingKeyFile(let path): "\(path) is missing: config.json has sealed secrets that cannot be opened without it"
        case .malformedKeyFile(let path): "\(path) is not a valid key file"
        case .notSealed: "the value is not a sealed secret"
        case .wrongKey: "a sealed secret does not open with this bridge's key"
        }
    }
}
