import Foundation
import Homeswift
import HomeswiftAI

/// A credential in the vault (docs/vault-design.md): a login, an API key, a token or another secret, by name. Its
/// fields are plain here and sealed in `vault.json`.
public struct VaultEntry: Codable, Sendable, Equatable {
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
    /// Kept by the vault from the entry's first `set`.
    public var created: Date
    public var changed: Date
    public var expires: Date?
    /// Nil for an entry a person made; a plugin instance's namespace (`EWeLink/<instance>`) for one it wrote.
    public var owner: String?

    public init(kind: Kind, fields: [String: String], created: Date = Date(), changed: Date? = nil, expires: Date? = nil, owner: String? = nil) {
        self.kind = kind
        self.fields = fields
        self.created = created
        self.changed = changed ?? created
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
    /// `Redaction.vaultNamePattern`, whole: a name fits in a reference as it is, and a plugin's
    /// (`plugin.<instance>.<file>`) fits too.
    public static let namePattern = "^\(Redaction.vaultNamePattern)$"
    public static let maximumNameLength = Redaction.vaultNameLength
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
        return try stored.mapValues { try Self.opening($0, by: box) }
    }

    /// Every entry with its fields' names and its dates, its values left sealed: what a listing shows.
    public func listing() throws -> [String: VaultEntry] {
        try read()
    }

    /// One entry, opened alone.
    public func entry(named name: String) throws -> VaultEntry? {
        guard let stored = try read()[name] else { return nil }
        return try Self.opening(stored, by: SecretBox.load(storage: storage, create: false))
    }

    /// The names, without opening anything.
    public func names() throws -> [String] {
        try read().keys.sorted()
    }

    /// Adds or replaces the entry `name`; a replaced entry keeps its creation date.
    public func set(_ name: String, _ entry: VaultEntry) throws {
        try set([name: entry])
    }

    /// Adds or replaces each entry, in one write.
    public func set(_ entries: [String: VaultEntry]) throws {
        if let invalid = entries.keys.first(where: { !Self.isValidName($0) }) { throw CredentialVaultError.invalidName(invalid) }
        guard !entries.isEmpty else { return }
        try Self.writes.withLock {
            var stored = try read()
            let box = try SecretBox.load(storage: storage, create: true)
            for (name, entry) in entries {
                var sealed = entry
                sealed.fields = try entry.fields.mapValues { try box.seal($0) }
                if let previous = stored[name] { sealed.created = previous.created }
                stored[name] = sealed
            }
            try write(stored)
        }
    }

    /// Sets the entry `name` from what a person typed: `fields` replace those of the same name and the others stay,
    /// unless the kind changes, which starts again. `expires` replaces the date (`.some(nil)` clears it), nil keeps it;
    /// a plugin's entry keeps its owner. Returns whether the entry is new.
    @discardableResult
    public func update(_ name: String, kind: VaultEntry.Kind, fields: [String: String], expires: Date?? = nil) throws -> Bool {
        guard !fields.isEmpty, fields.values.allSatisfy({ !$0.isEmpty }), fields.keys.allSatisfy({ !$0.isEmpty && !$0.contains("#") }) else {
            throw CredentialVaultError.noValue
        }
        let existing = try entry(named: name)
        var merged = existing?.kind == kind ? existing?.fields ?? [:] : [:]
        merged.merge(fields) { $1 }
        guard merged[kind.mainField] != nil || merged.count == 1 else { throw CredentialVaultError.missingField(kind.rawValue, kind.mainField) }
        try set(name, VaultEntry(kind: kind, fields: merged, changed: Date(), expires: expires ?? existing?.expires, owner: existing?.owner))
        Redaction.rememberSecrets(fields.values)
        return existing == nil
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

    /// Adds `entries`, runs `body`, and removes them again when either throws: a migration's new entries, gone if the
    /// config that names them is not written.
    public func adding<T>(_ entries: [String: VaultEntry], _ body: () throws -> T) throws -> T {
        try set(entries)
        do {
            return try body()
        } catch {
            for name in entries.keys { _ = try? remove(name) }
            throw error
        }
    }

    public func adding<T>(_ entries: [String: VaultEntry], _ body: () async throws -> T) async throws -> T {
        try set(entries)
        do {
            return try await body()
        } catch {
            for name in entries.keys { _ = try? remove(name) }
            throw error
        }
    }

    private static func opening(_ entry: VaultEntry, by box: SecretBox) throws -> VaultEntry {
        var opened = entry
        opened.fields = try entry.fields.mapValues { try box.open($0) }
        return opened
    }

    /// The entries as the file keeps them: each field `enc:v1:…`.
    private func read() throws -> [String: VaultEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let file = try Self.decoder.decode(StoredFile.self, from: Data(contentsOf: url))
        guard file.version == 1 else { throw CredentialVaultError.unsupportedVersion(file.version) }
        return file.entries
    }

    private func write(_ entries: [String: VaultEntry]) throws {
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
        var entries: [String: VaultEntry]
    }
}

public enum CredentialVaultError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidName(String)
    case unsupportedVersion(Int)
    case noValue
    case missingField(String, String)

    public var description: String {
        switch self {
        case .invalidName(let name): "\"\(name)\" is not a vault name: letters, digits, '.', '_' and '-', starting with a letter or a digit, \(Redaction.vaultNameLength) at most"
        case .unsupportedVersion(let version): "vault.json is version \(version), which this homeswift does not read"
        case .noValue: "an entry needs at least one field, each with a name and a value"
        case .missingField(let kind, let field): "a \(kind) needs its \(field) field"
        }
    }
}
