import Foundation
import Homeswift
import HomeswiftPlugin

/// The session the plugin keeps between launches, as the Homebridge plugin's `ewelink-tokens.json`: reused
/// for a day, then the plugin logs in again. Kept sealed in the vault: it is an account credential.
struct StoredTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var apiKey: String
    var region: String
    /// Milliseconds since 1970.
    var timestamp: Double
}

struct TokenStorage: Sendable {
    /// Tokens older than this are not reused.
    static let maximumAge: Double = 24 * 60 * 60 * 1000
    /// The file the tokens were kept in before the vault, in the plugin's folder: moved into the vault when read.
    static let fileName = "ewelink-tokens.json"

    let file: SecretFile<StoredTokens>

    init(file: SecretFile<StoredTokens>) {
        self.file = file
    }

    init(context: PluginContext) {
        file = context.secretFile(Self.fileName)
    }

    func save(accessToken: String, refreshToken: String, apiKey: String, region: String, now: Double = Date().timeIntervalSince1970 * 1000) throws {
        try file.save(StoredTokens(accessToken: accessToken, refreshToken: refreshToken, apiKey: apiKey, region: region, timestamp: now))
    }

    func load() -> StoredTokens? { file.load() }

    func isValid(_ tokens: StoredTokens?, now: Double = Date().timeIntervalSince1970 * 1000) -> Bool {
        guard let tokens else { return false }
        return now - tokens.timestamp < Self.maximumAge
    }

    /// The stored tokens while they are fresh.
    func loadValid(now: Double = Date().timeIntervalSince1970 * 1000) -> StoredTokens? {
        let tokens = load()
        return isValid(tokens, now: now) ? tokens : nil
    }

    func clear() {
        file.remove()
    }
}
