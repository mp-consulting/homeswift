import Crypto
import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// What a Govee login yields, and what the HTTP and AWS IoT clients need. Kept between launches.
struct AccountCredentials: Sendable, Equatable, Codable {
    var topic: String
    var token: String
    var accountId: String
    var endpoint: String
    var iotPass: String
}

/// What the vault keeps of the account (the instance's account credentials, `context.credentials()`): the login a
/// sign-in gave and the AWS IoT certificate, and the password when Setup signed in, so a refused token can be renewed.
struct StoredLogin: Sendable, Equatable, Codable {
    var username: String
    /// Set by Setup, which takes it out of config.json; nil for a login the block's password gave.
    var password: String?
    var credentials: AccountCredentials?
    /// The account's AWS IoT client certificate and key, base64 PKCS#12.
    var iot: String?
}

/// Keeps the account token and the AWS IoT certificate between launches (`connection/credentials.ts`), in the vault as
/// the account's credentials. `credentials.json` and `govee.pfx`, the owner-only files of the plugin's directory they
/// were kept in before, move into the vault the first time they are read.
struct CredentialStore: Sendable {
    let context: PluginContext
    let username: String
    let logger: Logger

    var directory: URL { context.storageDirectory }
    /// Before the vault: `{"username", "credentials"}`.
    var legacyCredentialsFile: URL { directory.appendingPathComponent("credentials.json") }
    /// Before the vault: the certificate, PKCS#12.
    var legacyIoTFile: URL { directory.appendingPathComponent("govee.pfx") }

    private struct LegacyStored: Codable {
        var username: String
        var credentials: AccountCredentials
    }

    /// What the vault holds, after moving the legacy files into it.
    static func stored(_ context: PluginContext) -> StoredLogin? {
        if let stored = context.credentials(as: StoredLogin.self) { return stored }
        let directory = context.storageDirectory
        let file = directory.appendingPathComponent("credentials.json"), certificate = directory.appendingPathComponent("govee.pfx")
        guard let data = try? Data(contentsOf: file), let legacy = try? JSONDecoder().decode(LegacyStored.self, from: data) else { return nil }
        let iot = (try? Data(contentsOf: certificate))?.base64EncodedString()
        let stored = StoredLogin(username: legacy.username, credentials: legacy.credentials, iot: iot)
        guard (try? context.saveCredentials(stored)) != nil else { return stored }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: certificate)
        return stored
    }

    /// The credentials of an earlier login of the same user, or nil when a login is needed (nothing kept,
    /// another user, or the certificate is missing).
    func load() -> AccountCredentials? {
        logger.debug("[HTTP] Checking for cached credentials...")
        do {
            guard let stored = Self.stored(context), let credentials = stored.credentials else { throw StoreError.missing(Lang.accTokenNoExist) }
            guard stored.username == username else { throw StoreError.missing(Lang.accTokenUserChange) }
            guard stored.iot != nil else { throw StoreError.missing("iot certificate does not exist") }
            logger.debug("[HTTP] \(Lang.accTokenFromCache).")
            return credentials
        } catch {
            logger.debug("[HTTP] Cache not available (\(error)), performing fresh login...")
            return nil
        }
    }

    /// Saves a fresh login and its certificate (base64 PKCS#12), keeping the password Setup kept for the same user.
    func save(_ credentials: AccountCredentials, iotCertificate: String) throws {
        let previous = Self.stored(context)
        let password = previous?.username == username ? previous?.password : nil
        do {
            try context.saveCredentials(StoredLogin(username: username, password: password, credentials: credentials, iot: iotCertificate))
        } catch {
            logger.warning("[HTTP] \(Lang.accTokenStoreErr) \(error).")
            throw error
        }
    }

    /// Forgets the token and the certificate. The password Setup kept stays, so the account is still signed in to.
    func clear() { Self.clear(context) }

    static func clear(_ context: PluginContext) {
        try? FileManager.default.removeItem(at: context.storageDirectory.appendingPathComponent("credentials.json"))
        try? FileManager.default.removeItem(at: context.storageDirectory.appendingPathComponent("govee.pfx"))
        guard var stored = context.credentials(as: StoredLogin.self) else { return }
        guard stored.password != nil else { return context.removeCredentials() }
        stored.credentials = nil
        stored.iot = nil
        try? context.saveCredentials(stored)
    }

    /// Written once a Homebridge login was imported, so it is imported once (Clear Cache leaves it).
    var importMarker: URL { directory.appendingPathComponent("homebridge-import") }
    /// node-persist names a key's file by its SHA-256.
    static let homebridgeKey = "Govee_All_Devices_temp"

    /// The Homebridge plugin's login, for a first start that has none: in `govee_cache`, node-persist's file for
    /// `Govee_All_Devices_temp` (`{"key", "value", "ttl"}`, the value `topic:::token:::username:::accountId:::endpoint:::iotPass:::`),
    /// and its certificate, `persist/govee.pfx`, of a Homebridge storage path. Kept as this store's own when the
    /// username is the same; nil when there is nothing to import.
    func importHomebridge(from storagePath: URL) -> AccountCredentials? {
        guard !FileManager.default.fileExists(atPath: importMarker.path) else { return nil }
        let name = SHA256.hash(data: Data(Self.homebridgeKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let cacheFile = storagePath.appendingPathComponent("govee_cache").appendingPathComponent(name)
        let certificateFile = storagePath.appendingPathComponent("persist").appendingPathComponent("govee.pfx")
        guard let cached = try? Data(contentsOf: cacheFile), let value = (try? JSONValue(data: cached))?["value"]?.stringValue,
            let certificate = try? Data(contentsOf: certificateFile)
        else { return nil }
        let parts = value.components(separatedBy: ":::")
        guard parts.count == 7, parts[2] == username else {
            logger.debug("[HTTP] Homebridge cache at \(storagePath.path) is for another account, not imported")
            return nil
        }
        let credentials = AccountCredentials(topic: parts[0], token: parts[1], accountId: parts[3], endpoint: parts[4], iotPass: parts[5])
        do {
            try save(credentials, iotCertificate: certificate.base64EncodedString())
            try OwnerOnlyFile.write(Data(storagePath.path.utf8), to: importMarker)
        } catch {
            return nil
        }
        logger.info("[HTTP] imported the Homebridge plugin's login from \(storagePath.path).")
        return credentials
    }

    func certificate() throws -> Data {
        guard let iot = Self.stored(context)?.iot else { throw StoreError.missing("iot certificate does not exist") }
        return Govee.bytes(base64: iot).data
    }

    enum StoreError: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self {
            case .missing(let reason): reason
            }
        }
    }
}

extension [UInt8] {
    var data: Data { Data(self) }
}

/// The account side of the HTTP client (`connection/http.ts`): logs in (with retries when Govee cannot be
/// reached), fetches the IoT certificate, lists the devices and the leak alerts with the current token.
actor GoveeAccount {
    static let maximumRetries = 3
    static let retryDelay: Duration = .seconds(30)

    let api: GoveeAPI
    let username: String
    let password: String
    let code: String?
    let logger: Logger
    private(set) var token: String?
    private let retryDelay: Duration

    init(api: GoveeAPI, username: String, password: String, code: String?, logger: Logger, retryDelay: Duration = GoveeAccount.retryDelay) {
        self.api = api
        self.username = username
        self.password = password
        self.code = code
        self.logger = logger
        self.retryDelay = retryDelay
    }

    var clientId: String { api.clientId }

    func setToken(_ token: String) { self.token = token }

    struct LoginResult: Sendable {
        var credentials: AccountCredentials
        /// The certificate, base64 PKCS#12.
        var iot: String
    }

    func login(retry: Int = 0) async throws -> LoginResult {
        do {
            logger.debug("[HTTP] Attempting login...")
            let login = try await api.login(username: username, password: password, code: code)
            token = login.token
            logger.debug("[HTTP] \(Lang.loginSuccess). AccountId: \(login.accountId)")
            logger.debug("[HTTP] Fetching IoT credentials...")
            let key = try await api.iotKey(token: login.token)
            logger.debug("[HTTP] IoT credentials received. Endpoint: \(key.endpoint)")
            return LoginResult(
                credentials: AccountCredentials(topic: login.topic, token: login.token, accountId: login.accountId, endpoint: key.endpoint, iotPass: key.p12Password),
                iot: key.p12)
        } catch let error as GoveeAPIError {
            if error.needsVerificationCode { logger.warning("[HTTP] \(error)") }
            guard case .unreachable(let reason) = error else { throw error }
            guard retry < Self.maximumRetries else {
                logger.warning("[HTTP] login() failed after \(Self.maximumRetries) retries [\(reason)].")
                throw error
            }
            logger.warning("[HTTP] \(Lang.httpRetry) [login() - \(reason)] (attempt \(retry + 1)/\(Self.maximumRetries)).")
            try await Task.sleep(for: retryDelay)
            return try await login(retry: retry + 1)
        }
    }

    func logout() async {
        guard let token else { return }
        do {
            try await api.logout(token: token)
        } catch {
            logger.warning("[HTTP] \(Lang.logoutFail) \(error).")
        }
    }

    func devices() async throws -> [JSONValue] {
        guard let token else {
            logger.debug("[HTTP] getDevices called but no token exists")
            throw GoveeAPIError.message(Lang.noTokenExists)
        }
        logger.debug("[HTTP] Fetching device list...")
        let devices = try await api.devices(token: token)
        logger.debug("[HTTP] Found \(devices.count) devices")
        for (index, device) in devices.enumerated() {
            logger.debug("[HTTP] Device \(index + 1): \(device["deviceName"]?.stringValue ?? "") (\(device["sku"]?.stringValue ?? "")) - \(device["device"]?.stringValue ?? "")")
        }
        return devices
    }

    func leakWarnings(deviceId: String, sku: String) async throws -> [JSONValue] {
        guard let token else { throw GoveeAPIError.message(Lang.noTokenExists) }
        return try await api.leakWarnings(token: token, deviceId: deviceId, sku: sku)
    }
}
