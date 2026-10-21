import Crypto
import Foundation

/// A controller (iPhone, Home hub) that paired with the accessory.
public struct Pairing: Codable, Sendable, Equatable {
    public var identifier: String
    public var publicKey: Data
    public var isAdmin: Bool
}

/// Everything the server must keep across launches. Losing it means HomeKit must pair again.
struct PersistedState: Codable {
    var deviceID: String
    var signingKey: Data
    var setupCode: String
    var setupID: String
    var configurationNumber = 1
    var databaseHash = ""
    var port: Int?
    var pairings: [Pairing] = []
    /// Stable aids per accessory id, and iids per service/characteristic key.
    var aids: [String: Int] = [:]
    var iids: [String: Int] = [:]

    static func new(setupCode: SetupCode?) -> PersistedState {
        let mac = (0..<6).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined(separator: ":")
        return PersistedState(
            deviceID: mac,
            signingKey: Curve25519.Signing.PrivateKey().rawRepresentation,
            setupCode: (setupCode ?? .random()).rawValue,
            setupID: SetupID.random()
        )
    }
}

/// Where the server keeps its identity and pairings.
public protocol HAPStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// Stores state as a JSON file. The default lives in `~/.homeswift/<name>.json`.
public struct FileStorage: HAPStorage {
    public let url: URL

    public init(url: URL) { self.url = url }

    public init(name: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(url: home.appendingPathComponent(".homeswift").appendingPathComponent("\(name).json"))
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        #if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }
}

/// Keeps state in memory only, for tests.
public final class MemoryStorage: HAPStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    public init() {}

    public func load() throws -> Data? { lock.withLock { data } }
    public func save(_ data: Data) throws { lock.withLock { self.data = data } }
}
