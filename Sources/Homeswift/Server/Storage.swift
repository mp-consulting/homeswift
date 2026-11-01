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
    /// Pair setups that failed since the last that succeeded: at 100 the accessory refuses more (`maxTries`), as
    /// the spec asks; kept so a restart does not reset it, as the ADK keeps it. Nil when none.
    var failedPairSetupAttempts: Int?

    /// The JSON `JSONDecoder` reads back, written directly: the server saves it after every accessory it gives new
    /// ids, and `JSONEncoder` cost as much as the rest of adding one (the iid map grows with every accessory).
    func encoded() -> Data {
        var json = JSONWriter(capacity: 512 + iids.count * 64 + aids.count * 48)
        json.object { json in
            json.field("deviceID", deviceID)
            json.field("signingKey", signingKey.base64EncodedString())
            json.field("setupCode", setupCode)
            json.field("setupID", setupID)
            json.field("configurationNumber", configurationNumber)
            json.field("databaseHash", databaseHash)
            json.field("port", port)
            json.field("failedPairSetupAttempts", failedPairSetupAttempts)
            json.key("pairings")
            json.array { json in
                for pairing in pairings {
                    json.object { json in
                        json.field("identifier", pairing.identifier)
                        json.field("publicKey", pairing.publicKey.base64EncodedString())
                        json.field("isAdmin", pairing.isAdmin)
                    }
                }
            }
            for (name, map) in [("aids", aids), ("iids", iids)] {
                json.key(name)
                json.object { json in
                    for (key, value) in map { json.field(key, value) }
                }
            }
        }
        return Data(json.bytes)
    }

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
        try OwnerOnlyFile.write(data, to: url)
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

/// A file the owner alone can read: the directory 0700, an atomic write, the file 0600. Every file the
/// bridge keeps (state, config.json, caches, users, sessions, the audit log) is written through here.
public enum OwnerOnlyFile {
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(Windows)
        try data.write(to: url, options: .atomic)
        #else
        // A temporary file created 0600, so the contents are never readable by others, then renamed over the file.
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? handle.close()
            unlink(temporary.path)
            throw error
        }
        #endif
    }
}
