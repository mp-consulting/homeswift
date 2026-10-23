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

/// Keeps the account token and the AWS IoT certificate between launches (`connection/credentials.ts`), both
/// readable by the owner only: `credentials.json` and `govee.pfx` in the plugin's directory.
struct CredentialStore: Sendable {
    let directory: URL
    let username: String
    let logger: Logger

    var credentialsFile: URL { directory.appendingPathComponent("credentials.json") }
    /// The account's AWS IoT client certificate and key (PKCS#12).
    var iotFile: URL { directory.appendingPathComponent("govee.pfx") }

    private struct Stored: Codable {
        var username: String
        var credentials: AccountCredentials
    }

    /// The credentials of an earlier login of the same user, or nil when a login is needed (nothing kept,
    /// another user, or the certificate is missing).
    func load() -> AccountCredentials? {
        logger.debug("[HTTP] Checking for cached credentials...")
        do {
            guard FileManager.default.fileExists(atPath: credentialsFile.path) else { throw StoreError.missing(Lang.accTokenNoExist) }
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: credentialsFile))
            guard stored.username == username else { throw StoreError.missing(Lang.accTokenUserChange) }
            guard FileManager.default.fileExists(atPath: iotFile.path) else { throw StoreError.missing("iot certificate does not exist") }
            logger.debug("[HTTP] \(Lang.accTokenFromCache).")
            return stored.credentials
        } catch {
            logger.debug("[HTTP] Cache not available (\(error)), performing fresh login...")
            return nil
        }
    }

    /// Saves a fresh login and its certificate (base64 PKCS#12).
    func save(_ credentials: AccountCredentials, iotCertificate: String) throws {
        try OwnerOnlyFile.write(Govee.bytes(base64: iotCertificate).data, to: iotFile)
        do {
            try OwnerOnlyFile.write(JSONEncoder().encode(Stored(username: username, credentials: credentials)), to: credentialsFile)
        } catch {
            logger.warning("[HTTP] \(Lang.accTokenStoreErr) \(error).")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: credentialsFile)
    }

    func certificate() throws -> Data { try Data(contentsOf: iotFile) }

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
            if case .twoFactorRequired = error { logger.warning("[HTTP] \(error)") }
            if case .twoFactorInvalid = error { logger.warning("[HTTP] \(error)") }
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
