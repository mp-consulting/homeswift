import Foundation
import Homeswift
import HomeswiftPlugin

/// The session the plugin keeps between launches, as the Homebridge plugin's `ewelink-tokens.json`: reused
/// for a day, then the plugin logs in again. Written owner-only: it is an account credential.
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

    let file: JSONFile<StoredTokens>
    var url: URL { file.url }

    init(directory: URL) {
        file = JSONFile(url: directory.appendingPathComponent("ewelink-tokens.json"))
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

    /// Empties the file, keeping it owner-only.
    func clear() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? OwnerOnlyFile.write(Data("{}".utf8), to: url)
    }
}
