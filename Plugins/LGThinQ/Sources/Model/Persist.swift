import Crypto
import Foundation
import Homeswift
import HomeswiftPlugin

/// The plugin's own files, under its storage directory: each device's model JSON (downloaded once) and the
/// MQTT client key and certificate request (made once). Owner-only: the key is a secret. Files are named by
/// the SHA-256 of their key, as node-persist names them.
struct Persist: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func url(_ key: String) -> URL {
        directory.appendingPathComponent(Secrets.hex(SHA256.hash(data: Data(key.utf8))))
    }

    func item(_ key: String) -> JSONValue? {
        guard let data = try? Data(contentsOf: url(key)), let datum = try? JSONValue(data: data) else { return nil }
        // node-persist's { key, value } datum.
        return datum["value"]
    }

    func setItem(_ key: String, _ value: JSONValue) throws {
        try OwnerOnlyFile.write(JSONValue.object(["key": .string(key), "value": value]).encoded(), to: url(key))
    }

    func removeItem(_ key: String) {
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
