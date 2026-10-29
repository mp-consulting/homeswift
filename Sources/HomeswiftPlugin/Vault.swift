import Foundation
import Homeswift
import HomeswiftAI

/// A credential in the vault (docs/vault-design.md): a login, an API key, a token or another secret, by name. Its
/// fields are plain here and sealed in `vault.json`.
public struct VaultEntry: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case login, apiKey, token, secret

        /// The field a reference without `#field` reads, and the one `homeswift vault set` fills from standard input.
        public var mainField: String {
            switch self {
            case .login: "password"
            case .apiKey: "key"
            case .token: "token"
            case .secret: "value"
            }
        }
    }

    public var kind: Kind
    public var fields: [String: String]
    public var created: Date
    public var changed: Date
    public var lastUsed: Date?
    public var expires: Date?
    /// Nil for an entry a person made; a plugin instance's namespace (`EWeLink/<instance>`) for one it wrote.
    public var owner: String?

    public init(kind: Kind, fields: [String: String], created: Date = Date(), changed: Date? = nil, lastUsed: Date? = nil, expires: Date? = nil, owner: String? = nil) {
        self.kind = kind
        self.fields = fields
        self.created = created
        self.changed = changed ?? created
        self.lastUsed = lastUsed
        self.expires = expires
        self.owner = owner
    }

    /// The value a reference reads: `field`, else the kind's main field, else the only field there is.
    public func value(field: String?) -> String? {
        if let field { return fields[field] }
        return fields[kind.mainField] ?? (fields.count == 1 ? fields.first?.value : nil)
    }
}

/// The local vault: `vault.json` beside config.json, owner-only, each field sealed by the bridge's `secrets.key`
/// (`SecretBox`), so an instance backup restores it with its key. config.json names an entry as `vault:<name>`.
public struct CredentialVault: Sendable {
    public static let fileName = "vault.json"
    /// Letters, digits, `.`, `_` and `-`, starting with a letter or a digit: a name fits in a reference as it is.
    public static let namePattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#
    /// Read-modify-writes in this process go one at a time.
    private static let writes = NSLock()

    public let storage: URL
    public var url: URL { storage.appendingPathComponent(Self.fileName) }

    public init(storage: URL) {
        self.storage = storage
    }

    public static func isValidName(_ name: String) -> Bool {
        name.range(of: namePattern, options: .regularExpression) != nil
    }

    /// Every entry, opened. A missing file is an empty vault; a vault with entries needs the key file.
    public func entries() throws -> [String: VaultEntry] {
        let stored = try read()
        guard !stored.isEmpty else { return [:] }
        let box = try SecretBox.load(storage: storage, create: false)
        return try stored.mapValues { entry in
            VaultEntry(
                kind: entry.kind, fields: try entry.fields.mapValues { try box.open($0) }, created: entry.created, changed: entry.changed,
                lastUsed: entry.lastUsed, expires: entry.expires, owner: entry.owner
            )
        }
    }

    public func entry(named name: String) throws -> VaultEntry? {
        try entries()[name]
    }

    /// The names, without opening anything: what a listing needs.
    public func names() throws -> [String] {
        try read().keys.sorted()
    }

    /// Adds or replaces the entry `name`; a replaced entry keeps its creation date.
    public func set(_ name: String, _ entry: VaultEntry) throws {
        guard Self.isValidName(name) else { throw CredentialVaultError.invalidName(name) }
        try Self.writes.withLock {
            var stored = try read()
            let box = try SecretBox.load(storage: storage, create: true)
            var next = StoredEntry(
                kind: entry.kind, fields: try entry.fields.mapValues { try box.seal($0) }, created: entry.created, changed: entry.changed,
                lastUsed: entry.lastUsed, expires: entry.expires, owner: entry.owner
            )
            if let previous = stored[name] { next.created = previous.created }
            stored[name] = next
            try write(stored)
        }
    }

    /// Removes the entry `name`; false when there was none.
    @discardableResult
    public func remove(_ name: String) throws -> Bool {
        try Self.writes.withLock {
            var stored = try read()
            guard stored.removeValue(forKey: name) != nil else { return false }
            try write(stored)
            return true
        }
    }

    private func read() throws -> [String: StoredEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let file = try Self.decoder.decode(StoredFile.self, from: Data(contentsOf: url))
        guard file.version == 1 else { throw CredentialVaultError.unsupportedVersion(file.version) }
        return file.entries
    }

    private func write(_ entries: [String: StoredEntry]) throws {
        try OwnerOnlyFile.write(Self.encoder.encode(StoredFile(version: 1, entries: entries)), to: url)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private struct StoredFile: Codable {
        var version: Int
        var entries: [String: StoredEntry]
    }

    /// An entry as the file keeps it: each field `enc:v1:…`.
    private struct StoredEntry: Codable {
        var kind: VaultEntry.Kind
        var fields: [String: String]
        var created: Date
        var changed: Date
        var lastUsed: Date?
        var expires: Date?
        var owner: String?
    }
}

public enum CredentialVaultError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidName(String)
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .invalidName(let name): "\"\(name)\" is not a vault name: letters, digits, '.', '_' and '-', starting with a letter or a digit, 64 at most"
        case .unsupportedVersion(let version): "vault.json is version \(version), which this homeswift does not read"
        }
    }
}
