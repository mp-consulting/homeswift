import Crypto
import Foundation
import Homeswift
import HomeswiftAI

/// Sealed secrets in config.json. A secret a plugin must send back to its service (a password, a cloud token)
/// is stored as `enc:v1:` followed by base64 of ChaCha20-Poly1305's nonce, ciphertext and tag, under a random
/// 256-bit key in `secrets.key` beside config.json. Each value has its own random nonce, so equal secrets seal
/// to different text. The key file is owner-only; anyone with both files can read the secrets, so the sealing
/// keeps them out of copies of config.json and version control, not out of reach of the bridge's owner. An instance
/// backup holds the key too, so it restores the bridge with its secrets: keep a backup as private as the key.
public struct SecretBox: Sendable {
    public static let prefix = Redaction.sealedPrefix
    public static let fileName = "secrets.key"

    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// The key a key file holds (a backup's `secrets.key` included); throws when it is not one.
    public static func fromKeyFile(_ data: Data, path: String = "the key file") throws -> SecretBox {
        let stored = try JSONDecoder().decode(StoredKey.self, from: data)
        guard stored.version == 1, let raw = Data(base64Encoded: stored.key), raw.count == 32 else {
            throw SecretBoxError.malformedKeyFile(path)
        }
        return SecretBox(key: SymmetricKey(data: raw))
    }

    /// The key in `storage`'s key file, made on first use when `create` is true.
    public static func load(storage: URL, create: Bool) throws -> SecretBox {
        let url = storage.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            return try fromKeyFile(Data(contentsOf: url), path: url.path)
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

    /// `value` with every plain string under a secret-named key sealed by `seal` (a key's whole subtree counts). A
    /// string already sealed, or the redaction placeholder, is kept as it is. A number under a secret's name is sealed
    /// as its text. Nothing is sealed, and `seal` is never called, when no secret is plain.
    public static func sealingSecrets(_ value: JSONValue, underSecret: Bool = false, seal: (String) throws -> String) rethrows -> JSONValue {
        switch value {
        case .string(let text) where (underSecret || Redaction.isCredentialURL(text)) && !text.isEmpty && !isSealed(text) && text != Redaction.placeholder:
            return .string(try seal(text))
        case .number where underSecret:
            // A secret is text (the schemas' password fields are strings): a number under a secret's name is sealed as its text.
            return .string(try seal(value.text()))
        case .array(let items):
            return .array(try items.map { try sealingSecrets($0, underSecret: underSecret, seal: seal) })
        case .object(let object):
            return .object(try object.reduce(into: [:]) { result, entry in
                result[entry.key] = try sealingSecrets(entry.value, underSecret: underSecret || Redaction.isSecretKey(entry.key), seal: seal)
            })
        default:
            return value
        }
    }

    /// Whether a string value anywhere in `value` is sealed: only a value that starts with the prefix counts.
    static func holdsSealed(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let text): isSealed(text)
        case .array(let items): items.contains(where: holdsSealed)
        case .object(let object): object.values.contains(where: holdsSealed)
        default: false
        }
    }

    /// `configuration` with its sealed secrets opened, as the runtime reads them. Only a config that holds sealed
    /// text needs the key file, so a config without any never touches it.
    public static func revealing(_ configuration: HomeswiftConfiguration, storage: URL) throws -> HomeswiftConfiguration {
        // A byte search first: only a block that carries the prefix is parsed to see whether a value starts with it.
        guard holdsSealed(configuration) else { return configuration }
        return try load(storage: storage, create: false).revealing(configuration)
    }

    /// `configuration` with its sealed secrets opened by `key` (a backup's, read from its archive). A configuration
    /// with no sealed secret needs no key; one with sealed secrets and no key throws.
    public static func revealing(_ configuration: HomeswiftConfiguration, key: SecretBox?) throws -> HomeswiftConfiguration {
        guard holdsSealed(configuration) else { return configuration }
        guard let key else { throw SecretBoxError.missingKeyFile("the backup's secrets.key") }
        return try key.revealing(configuration)
    }

    /// `config` (a config.json value) with its sealed secrets opened from `storage`'s key; unchanged when none is sealed.
    public static func revealed(_ config: JSONValue, storage: URL) throws -> JSONValue {
        guard holdsSealed(config) else { return config }
        return try load(storage: storage, create: false).revealing(config)
    }

    /// Whether a sealed secret is in `configuration`: a platform block that carries the prefix (the child bridge's PIN
    /// included), or the bridge's PIN.
    static func holdsSealed(_ configuration: HomeswiftConfiguration) -> Bool {
        let sealedPlatform = configuration.platforms.contains { platform in
            guard platform.json.range(of: Data(prefix.utf8)) != nil else { return false }
            guard let block = try? JSONValue(data: platform.json) else { return false }
            return holdsSealed(block)
        }
        return sealedPlatform || isSealed(configuration.bridge.pin ?? "")
    }

    /// `config` with every sealed string in its platform blocks and bridge opened, for the runtime to read.
    public func revealing(_ configuration: HomeswiftConfiguration) throws -> HomeswiftConfiguration {
        var result = configuration
        result.bridge.pin = try result.bridge.pin.map(revealText)
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

    /// `config` (a config.json value) with the sealed secrets this key opens: a backup's, opened with its own key.
    public func opening(_ config: JSONValue) throws -> JSONValue {
        try revealing(config)
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
