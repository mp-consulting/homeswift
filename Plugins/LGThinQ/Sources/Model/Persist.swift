import Crypto
import Foundation
import Homeswift
import HomeswiftPlugin

/// The plugin's own files, under its storage directory: each device's model JSON (downloaded once) and the
/// MQTT client key and certificate request (made once). Files are named by the SHA-256 of their key, as
/// node-persist names them, and written owner-only. The key and the request (`secretKeys`) are kept sealed in
/// the vault instead (`secret`), as the same `{ key, value }` datum; a file of theirs from before moves there
/// when it is read.
struct Persist: Sendable {
    /// What is a secret: the MQTT client's private key, and the certificate request made with it.
    static let secretKeys: Set<String> = ["keys", "csr"]

    let directory: URL
    /// The vault entry of a secret key, given the file it was kept in before; nil keeps every key in a file (tests).
    let secret: (@Sendable (_ key: String, _ legacyFile: URL) -> SecretFile<JSONValue>)?

    init(directory: URL, secret: (@Sendable (_ key: String, _ legacyFile: URL) -> SecretFile<JSONValue>)? = nil) {
        self.directory = directory
        self.secret = secret
    }

    /// The datum's entry in the vault when `key` is a secret.
    private func vaultEntry(_ key: String) -> SecretFile<JSONValue>? {
        guard Self.secretKeys.contains(key), let secret else { return nil }
        return secret(key, url(key))
    }

    func url(_ key: String) -> URL {
        directory.appendingPathComponent(Secrets.hex(SHA256.hash(data: Data(key.utf8))))
    }

    func item(_ key: String) -> JSONValue? {
        // node-persist's { key, value } datum.
        if let entry = vaultEntry(key) { return entry.load()?["value"] }
        guard let data = try? Data(contentsOf: url(key)), let datum = try? JSONValue(data: data) else { return nil }
        return datum["value"]
    }

    func setItem(_ key: String, _ value: JSONValue) throws {
        let datum = JSONValue.object(["key": .string(key), "value": value])
        if let entry = vaultEntry(key) { return try entry.save(datum) }
        try OwnerOnlyFile.write(datum.encoded(), to: url(key))
    }

    func removeItem(_ key: String) {
        if let entry = vaultEntry(key) { return entry.remove() }
        try? FileManager.default.removeItem(at: url(key))
    }

    /// The stored value, or `make()`'s, stored for good.
    func cacheForever(_ key: String, isolation: isolated (any Actor)? = #isolation, _ make: () async throws -> JSONValue) async throws -> JSONValue {
        if let value = item(key), JS.truthy(value) { return value }
        let value = try await make()
        try setItem(key, value)
        return value
    }
}
