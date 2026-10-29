import Crypto
import Foundation
import Homeswift
import HomeswiftAI

/// One of a plugin's own secrets (a cloud's tokens, a hub's token, a client key), kept as an entry of the vault in the
/// instance's namespace (`context.secretFile`, docs/vault-design.md): `JSONFile`'s interface, sealed. The plain file the
/// plugin kept it in before (`legacyFile`) moves into the vault the first time it is read, and is removed.
public struct SecretFile<Value: Codable>: Sendable {
    public let vault: CredentialVault
    /// `plugin.<instance>.<name>`: the instance's namespace, the only entries a plugin reads.
    public let entryName: String
    /// `<platform>/<name>`, the entry's owner.
    public let owner: String
    public let legacyFile: URL?

    /// The field the JSON is kept in.
    static var field: String { VaultEntry.Kind.token.mainField }

    public init(vault: CredentialVault, entryName: String, owner: String, legacyFile: URL? = nil) {
        self.vault = vault
        self.entryName = entryName
        self.owner = owner
        self.legacyFile = legacyFile
    }

    /// The stored value; nil when there is none or it does not decode. A legacy file is moved into the vault here.
    public func load() -> Value? {
        if let text = (try? vault.entry(named: entryName))?.fields[Self.field] {
            return decoded(Data(text.utf8))
        }
        guard let legacyFile, let data = try? Data(contentsOf: legacyFile), let value = decoded(data) else { return nil }
        // Moved as it was written: the value decodes, so the plugin reads it back the same.
        if (try? store(data)) != nil { try? FileManager.default.removeItem(at: legacyFile) }
        return value
    }

    public func save(_ value: Value) throws {
        try store(JSONFile<Value>.encoder.encode(value))
        if let legacyFile { try? FileManager.default.removeItem(at: legacyFile) }
    }

    public func remove() {
        _ = try? vault.remove(entryName)
        if let legacyFile { try? FileManager.default.removeItem(at: legacyFile) }
    }

    /// The vault keeps the entry's creation date.
    private func store(_ data: Data) throws {
        try vault.set(entryName, VaultEntry(kind: .token, fields: [Self.field: String(decoding: data, as: UTF8.self)], owner: owner))
    }

    private func decoded(_ data: Data) -> Value? {
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else { return nil }
        // What it holds under secret-named keys (an access token, a private key) is masked in logs from now on.
        if let json = try? JSONValue(data: data) {
            var secrets: [String] = []
            SecretWalk.forEach(json) { _, _, secret in if let text = secret.stringValue { secrets.append(text) } }
            Redaction.rememberSecrets(secrets)
        }
        return value
    }

    /// `plugin.<instance key>.<name>` with what a vault name cannot hold replaced by `-` and a file's leading dots
    /// dropped (`.daikin-mobile-tokenset`); a name too long keeps its start and a hash of the whole.
    public static func entryName(instance: String, file: String) -> String {
        func clean(_ text: String) -> String {
            String(text.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "-" })
        }
        var trimmed = Substring(file)
        while trimmed.first == "." { trimmed = trimmed.dropFirst() }
        let name = "plugin.\(clean(instance)).\(clean(String(trimmed.isEmpty ? "secret" : trimmed)))"
        guard name.count > CredentialVault.maximumNameLength else { return name }
        let hash = Secrets.hex(SHA256.hash(data: Data(name.utf8))).prefix(8)
        return "\(name.prefix(CredentialVault.maximumNameLength - 9))-\(hash)"
    }
}

extension PluginContext {
    /// One of the plugin's secrets in the vault, by name, in place of `jsonFile` for a token or a key: sealed, listed
    /// with the instance as its owner, and moved there from the file of that name in the storage directory (or
    /// `legacyFile`) the first time it is read.
    public func secretFile<Value: Codable>(_ name: String, as type: Value.Type = Value.self, legacyFile: URL? = nil) -> SecretFile<Value> {
        SecretFile(
            vault: CredentialVault(storage: vaultStorage), entryName: SecretFile<Value>.entryName(instance: key, file: name),
            owner: "\(platform)/\(self.name)", legacyFile: legacyFile ?? storageFile(name)
        )
    }
}
