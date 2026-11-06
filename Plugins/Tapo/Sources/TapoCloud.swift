import Crypto
import Foundation
import HomeswiftNetwork
import Logging

/// The TP-Link cloud as far as the cameras' motion needs it (docs/clean-room/TapoCloudEvents.md): the signed v2 login of
/// the Tapo account (with the e-mail code of a new terminal), its token's refresh, the account's cameras and its
/// notification inbox. Nothing here reaches a camera: the inbox is what the cloud keeps of the detections the cameras
/// reported when their own sensor woke them (7).
actor TapoCloud {
    /// What the account's sign-in leaves, sealed in the vault: the terminal is kept so the cloud trusts it after its first
    /// e-mail code.
    struct Session: Codable, Sendable, Equatable {
        var terminalUUID: String
        var username: String?
        var token: String?
        var refreshToken: String?
        var appServerURL: String?
        /// The account's NBU app server (4.4.1), which keeps each device's details; asked once.
        var nbuAppServerURL: String?
    }

    /// One notification of the inbox (5.3).
    struct Notification: Sendable, Equatable {
        var id: String
        var type: String
        var deviceID: String
        /// Unix seconds.
        var time: Double
    }

    /// A camera of the account (4.1).
    struct Device: Sendable, Equatable {
        var deviceID: String
        var alias: String
        var model: String
        var mac: String
        /// `fwVer`, as the cloud last heard it from the camera.
        var firmware: String = ""
    }

    /// The Android app's documented key pair (3.1): it identifies the app build, not the user.
    static let accessKey = "4d11b6b9d5ea4d19a829adbb9714b057"
    static let secret = "6ed7d97f3e73467f8a5bab90b577ba4c"
    static let appType = "TP-Link_Tapo_Android"
    static let appVersion = "3.20.753"
    static let entry = URL(string: "https://n-wap-gw.tplinkcloud.com")!

    /// TP-Link's private root (`CN=tp-link-CA`, valid to 2068, SHA-256 8B:54:F0:36:…:FD:EC:19), which the cloud's
    /// `*.tplinkcloud.com` certificates chain to through `TP-LINK CA P1` and which no system trusts: the cloud's
    /// requests trust it alone, rather than accepting any certificate.
    static let rootCA = """
        -----BEGIN CERTIFICATE-----
        MIIDBzCCAe+gAwIBAgIQT5x0ma7QnINHCQvhnmzR9zANBgkqhkiG9w0BAQsFADAV
        MRMwEQYDVQQDEwp0cC1saW5rLUNBMCAXDTE4MDExOTA4Mjc1MloYDzIwNjgwMTE5
        MDgzNzUyWjAVMRMwEQYDVQQDEwp0cC1saW5rLUNBMIIBIjANBgkqhkiG9w0BAQEF
        AAOCAQ8AMIIBCgKCAQEAuGG8n5zEUN1j5wuvUz4pAIMurhKHbpfUUu+b2acFHKS6
        iU9hNJWvDyhXcihY5Wz6aq9m4D5SZcgW3k31YoNNtrztDjdg2qw7AaX85S99/G0B
        VbIXktrhs34OW19WA/haDwut3dFhLem+gCRRKUXcmuqchZc84dY7JFVfhPcJci4m
        sRjLCFNO0ho9OX+MZwfO4BLaeAqKVoAor6rf4BXVtO0xjYHDKO0fb3AWLLJ4EjGe
        q6YieqPiYlPFEqRm5PrvBXTm0IuQogygyVpK4LHr/K207ZLyV33DxLLbsUgSEJVn
        pZUv/WUujXjlIDgxIvyZZCYiXO3dle2/MEvpmZk6JQIDAQABo1EwTzALBgNVHQ8E
        BAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUxu2iBRTsef5iNnsADVhM
        JDQWi6kwEAYJKwYBBAGCNxUBBAMCAQAwDQYJKoZIhvcNAQELBQADggEBAB52Majd
        +wo3cb5BsTo63z2Psbbyl4ACMUaw68NxUMy61Oihx3mcLzLJqiIZcKePiHskLqLJ
        F7QfT9TqjvizMjFJVgsLuVubUBXKBzqyN+3KKlQci0PO3mH+ObhyaE7BzV+qrS3P
        dVTgsCWFv8DkgLTRudSWxL7VwVoedc7lRz5EroGgJ33nRGCR0ngcW919tLTARDQO
        pULmzulcdWeZgG+0PLX0xjJQIjFEvbOxR1Z+gxMupBz0rWFokmWYrcga8eWiWzjQ
        Ia3/ASBVJ69srV77trWlfLumkChbXk9i64NXBKnce0Jmll0Y9OC1nMPqrbQKnzcn
        dSAA4fejD/qMQn0=
        -----END CERTIFICATE-----
        """
    /// TP-Link's newer private root (`CN=TP-Link Cloud Root CA`, ECDSA P-256, valid to 2055, SHA-256 8D:27:22:4D:…:1D:A2:89,
    /// TapoCloudEvents.md 4.4), which the `*.i.tplinkcloud.com` hosts chain to through `TP-Link Cloud Server CA`: a
    /// device's NBU app server among them. The cloud's requests trust it and `rootCA`, and nothing else.
    static let cloudRootCA = """
        -----BEGIN CERTIFICATE-----
        MIICKTCCAdCgAwIBAgIUXZHoRKIvheKCxJL4s2rZ/alfEGMwCgYIKoZIzj0EAwMw
        cjEeMBwGA1UEAwwVVFAtTGluayBDbG91ZCBSb290IENBMR0wGwYDVQQKDBRUUC1M
        aW5rIFN5c3RlbXMgSW5jLjEPMA0GA1UEBwwGSXJ2aW5lMRMwEQYDVQQIDApDYWxp
        Zm9ybmlhMQswCQYDVQQGEwJVUzAgFw0yNTAyMjUwMzQ3MTFaGA8yMDU1MDIxODAz
        NDcxMVowcjEeMBwGA1UEAwwVVFAtTGluayBDbG91ZCBSb290IENBMR0wGwYDVQQK
        DBRUUC1MaW5rIFN5c3RlbXMgSW5jLjEPMA0GA1UEBwwGSXJ2aW5lMRMwEQYDVQQI
        DApDYWxpZm9ybmlhMQswCQYDVQQGEwJVUzBZMBMGByqGSM49AgEGCCqGSM49AwEH
        A0IABAHpyZzXk1E4VWyIB+9VMci2Sw5OdeQ+kyFc2/R/f/OiHt6hk4PfMcCKKgS6
        hkVVYyVlobJNn052z+s9DJKJgfajQjBAMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0P
        AQH/BAQDAgGGMB0GA1UdDgQWBBQLV0PTee1jvnJMcUCEtQgJSg/oyTAKBggqhkjO
        PQQDAwNHADBEAiAURU4PvHXUrVViDF+rCky3RD9BeUpe91kYoNWe0oKVUwIgY0C5
        MsDHbQrwLHs1I7+f2MvZDGBHhNjnl0n4MF9q0L0=
        -----END CERTIFICATE-----
        """
    /// Both roots, for the cloud's client.
    static var roots: String { rootCA + "\n" + cloudRootCA }
    /// The detections the inbox is asked for, and the low and empty battery (docs/clean-room/TapoBattery.md, 4.4).
    static let detectionTypes = [
        "Motion", "PersonDetected", "PersonEnhanced", "VehicleDetected", "PetDetected", "animalDetected", "tapoCameraLinecrossingDetection",
        "tapoCameraAreaIntrusionDetection", "deliverPackageDetected", "pickUpPackageDetected", "ringEvent", "CameraLowBattery", "BatteryEmpty",
    ]

    private let http: any HTTPSending
    private let credentials: @Sendable () -> TapoCredentials?
    private let store: @Sendable () -> Session?
    private let save: @Sendable (Session) -> Void
    private let logger: Logger
    private let entry: URL
    private var session: Session

    init(http: any HTTPSending, entry: URL = TapoCloud.entry, credentials: @escaping @Sendable () -> TapoCredentials?,
         load: @escaping @Sendable () -> Session?, save: @escaping @Sendable (Session) -> Void, logger: Logger) {
        self.http = http
        self.entry = entry
        self.credentials = credentials
        self.store = load
        self.save = save
        self.logger = logger
        session = load() ?? Session(terminalUUID: UUID().uuidString.replacingOccurrences(of: "-", with: ""))
    }

    var isSignedIn: Bool { session.token != nil }
    var currentSession: Session { session }

    // MARK: Signing

    /// The `Content-MD5` and `X-Authorization` of a body sent to `path` (3.1).
    static func signature(body: Data, path: String, nonce: String, timestamp: String = "9999999999") -> (contentMD5: String, authorization: String) {
        let contentMD5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
        let message = "\(contentMD5)\n\(timestamp)\n\(nonce)\n\(path)"
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        let signature = Data(mac).map { String(format: "%02x", $0) }.joined()
        return (contentMD5, "Timestamp=\(timestamp), Nonce=\(nonce), AccessKey=\(accessKey), Signature=\(signature)")
    }

    private func query(token: String?) -> String {
        var items = ["appName=\(Self.appType)", "appVer=\(Self.appVersion)", "netType=wifi", "termID=\(session.terminalUUID)", "ospf=Android%2014",
                     "brand=TPLINK", "locale=en_US", "model=Homeswift", "termName=Homeswift", "termMeta=1"]
        if let token { items.insert("token=\(token)", at: 0) }
        return items.joined(separator: "&")
    }

    /// A signed POST; the answer's `result`, or the error code from either level of the answer (3.3).
    private func call(_ path: String, host: URL? = nil, _ body: [String: Any], token: String? = nil) async throws -> [String: Any] {
        let base = host ?? session.appServerURL.flatMap(URL.init(string:)) ?? entry
        guard let url = URL(string: "\(base.absoluteString.trimmingSuffix("/"))\(path)?\(query(token: token))") else { throw TapoCloudError.invalidResponse(path) }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (contentMD5, authorization) = Self.signature(body: data, path: path, nonce: UUID().uuidString.lowercased())
        let request = HTTPRequest(method: "POST", url: url, headers: [
            ("Content-Type", "application/json;charset=UTF-8"), ("Content-MD5", contentMD5), ("X-Authorization", authorization),
            ("User-Agent", "\(Self.appType)/\(Self.appVersion)(Homeswift/;Android 14)"),
        ], body: data, timeout: .seconds(15))
        let response = try await http.send(request)
        if response.status == 401 || response.status == 403 { throw TapoCloudError.code(-20651) }
        guard (200..<300).contains(response.status) else { throw TapoCloudError.http(response.status) }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { throw TapoCloudError.invalidResponse(path) }
        let code = Self.int(object["error_code"]) ?? 0
        let result = object["result"] as? [String: Any] ?? [:]
        if code != 0 { throw TapoCloudError.code(code, appServerURL: result["appServerUrl"] as? String, processID: result["MFAProcessId"] as? String) }
        if let inner = Self.int(result["errorCode"]), inner != 0 {
            throw TapoCloudError.code(inner, appServerURL: result["appServerUrl"] as? String, processID: result["MFAProcessId"] as? String)
        }
        return result
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    // MARK: Sign-in

    /// Signs in with the account's password (3.2, 3.3). Throws `mfaRequired` when the cloud wants an e-mail code first:
    /// `requestCode` sends it and `finish` completes the sign-in.
    func signIn() async throws {
        guard let credentials = credentials(), !credentials.username.isEmpty, !credentials.password.isEmpty else { throw TapoCloudError.noAccount }
        if session.username != credentials.username {
            session.username = credentials.username
            session.appServerURL = nil
        }
        if session.appServerURL == nil {
            if let found = try? await call("/api/v2/account/getAccountStatusAndUrl", host: entry, ["appType": Self.appType, "cloudUserName": credentials.username]),
               let url = found["appServerUrl"] as? String, !url.isEmpty {
                session.appServerURL = url
            }
        }
        let body: [String: Any] = [
            "appType": Self.appType, "appVersion": Self.appVersion, "cloudUserName": credentials.username, "cloudPassword": credentials.password,
            "terminalUUID": session.terminalUUID, "terminalName": "Homeswift", "terminalMeta": "1", "platform": "Android 14", "refreshTokenNeeded": true,
        ]
        let result: [String: Any]
        do {
            result = try await call("/api/v2/account/login", body)
        } catch TapoCloudError.code(-20212, let url, _) {
            guard let url, !url.isEmpty else { throw TapoCloudError.code(-20212) }
            session.appServerURL = url
            result = try await call("/api/v2/account/login", body)
        } catch TapoCloudError.code(-20677, _, let process) {
            throw TapoCloudError.mfaRequired(processID: process ?? "")
        }
        if result["token"] == nil, let process = result["MFAProcessId"] as? String {
            throw TapoCloudError.mfaRequired(processID: process)
        }
        try accept(result)
    }

    /// Asks the cloud to e-mail the account a code for this terminal (3.4).
    func requestCode() async throws {
        guard let credentials = credentials() else { throw TapoCloudError.noAccount }
        _ = try await call("/api/v2/account/getEmailVC4TerminalMFA", [
            "appType": Self.appType, "cloudUserName": credentials.username, "cloudPassword": credentials.password,
            "terminalUUID": session.terminalUUID, "locale": "en_US",
        ])
    }

    /// Completes a sign-in with the e-mailed code; this terminal is then trusted, so later sign-ins ask for none.
    func finish(code: String, processID: String) async throws {
        guard let credentials = credentials() else { throw TapoCloudError.noAccount }
        let result = try await call("/api/v2/account/checkMFACodeAndLogin", [
            "appType": Self.appType, "cloudUserName": credentials.username, "code": code, "MFAProcessId": processID, "MFAType": 2,
            "terminalBindEnabled": true,
        ])
        try accept(result)
    }

    private func accept(_ result: [String: Any]) throws {
        guard let token = result["token"] as? String, !token.isEmpty else { throw TapoCloudError.invalidResponse("a sign-in without a token") }
        session.token = token
        if let refresh = result["refreshToken"] as? String, !refresh.isEmpty { session.refreshToken = refresh }
        if let url = result["appServerUrl"] as? String, !url.isEmpty { session.appServerURL = url }
        save(session)
    }

    /// A new token from the refresh token (3.5), else a new sign-in.
    private func renew() async throws {
        if let refresh = session.refreshToken {
            do {
                let result = try await call("/api/v2/account/refreshToken", ["appType": Self.appType, "refreshToken": refresh, "terminalUUID": session.terminalUUID])
                if let token = result["token"] as? String, !token.isEmpty {
                    session.token = token
                    if let next = result["refreshToken"] as? String, !next.isEmpty { session.refreshToken = next }
                    save(session)
                    return
                }
            } catch let error as TapoCloudError where error.isRefusedSignIn {
                throw error
            } catch {
                logger.debug("The Tapo cloud refused the refresh token: signing in again")
            }
        }
        session.token = nil
        session.refreshToken = nil
        try await signIn()
    }

    /// A call with the token: signs in first when there is none, renews it once when it expired.
    private func authorized(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        if session.token == nil { try await signIn() }
        do {
            return try await call(path, body, token: session.token)
        } catch TapoCloudError.code(let code, _, _) where code == -20651 || code == -20655 {
            try await renew()
            return try await call(path, body, token: session.token)
        }
    }

    // MARK: Cameras and their detections

    /// The account's cameras (4.1).
    func cameras() async throws -> [Device] {
        var devices: [Device] = []
        var index = 0
        while index < 200 {
            let result = try await authorized("/api/v2/common/getDeviceListByPage", ["deviceTypeList": ["SMART.IPCAMERA", "SMART.TAPODOORBELL"], "index": index, "limit": 20])
            let list = result["deviceList"] as? [[String: Any]] ?? []
            for item in list {
                guard let id = item["deviceId"] as? String else { continue }
                devices.append(Device(deviceID: id, alias: Self.alias(item["alias"] as? String ?? ""), model: item["deviceModel"] as? String ?? "",
                                      mac: Self.normalizedMAC(item["deviceMac"] as? String ?? ""), firmware: item["fwVer"] as? String ?? ""))
            }
            if list.count < 20 { break }
            index += 20
        }
        return devices
    }

    // MARK: A camera's address

    /// The LAN address the cloud's registry keeps for a camera (4.4.1): `GET {NBU app server}/v1/things/{deviceId}/details`,
    /// its top-level `ip`, the address the camera reported when it last connected. Read from the cloud only: the camera is
    /// not reached, so a battery camera sleeps on. nil when the record has no IPv4 address.
    func lanAddress(of deviceID: String) async throws -> String? {
        let server = try await nbuAppServer()
        guard let url = URL(string: "\(server.trimmingSuffix("/"))/v1/things/\(deviceID)/details") else { throw TapoCloudError.invalidResponse("details") }
        let object: [String: Any]
        do {
            object = try await nbuGET(url)
        } catch TapoCloudError.code(-20651, _, _) {
            try await renew()
            object = try await nbuGET(url)
        }
        return (object["ip"] as? String).flatMap { IPv4Network.parse($0) != nil ? $0 : nil }
    }

    /// The account's NBU app server, from the signed `getAppServiceUrl` (4.4.1), kept with the session.
    private func nbuAppServer() async throws -> String {
        if let known = session.nbuAppServerURL { return known }
        let service = "nbu.iot-app-server.app-v2"
        let result = try await authorized("/api/v2/common/getAppServiceUrl", ["serviceIds": [service]])
        guard let url = (result["serviceUrls"] as? [String: Any])?[service] as? String, !url.isEmpty else {
            throw TapoCloudError.invalidResponse("no NBU app server")
        }
        session.nbuAppServerURL = url
        save(session)
        return url
    }

    /// A GET with the NBU headers (5.1): a bare JSON answer, its failures HTTP statuses (401 and 403: the token).
    private func nbuGET(_ url: URL) async throws -> [String: Any] {
        let terminal = session.terminalUUID
        let request = HTTPRequest(method: "GET", url: url, headers: [
            ("Authorization", "ut|\(session.token ?? "")"), ("app-cid", "app:\(Self.appType):\(terminal)"), ("x-app-name", Self.appType),
            ("x-app-version", Self.appVersion), ("x-term-id", terminal), ("x-ospf", "Android 14"), ("x-net-type", "wifi"), ("x-locale", "en_US"),
            ("x-strict", "0"), ("Content-Type", "application/json;UTF-8"), ("User-Agent", "\(Self.appType)/\(Self.appVersion)(Homeswift/;Android 14)"),
        ], body: nil, timeout: .seconds(10))
        let response = try await http.send(request)
        if response.status == 401 || response.status == 403 { throw TapoCloudError.code(-20651) }
        guard (200..<300).contains(response.status) else { throw TapoCloudError.http(response.status) }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { throw TapoCloudError.invalidResponse(url.path) }
        return object
    }

    /// Notifications since `since` (Unix seconds), oldest first (5.3). The inbox pages from `indexTime` in milliseconds,
    /// as its messages' `time` is.
    func notifications(since: Int) async throws -> [Notification] {
        let result = try await authorized("/api/v2/common/getAppNotificationByPage", [
            "appType": Self.appType, "contentVersion": 2, "deviceToken": "", "direction": "asc", "index": 0, "indexTime": since * 1000, "limit": 50,
            "locale": "en_US", "mobileType": "ANDROID", "msgTypes": Self.detectionTypes, "terminalUUID": session.terminalUUID,
        ])
        let list = (result["notifications"] as? [[String: Any]]) ?? (result["msgList"] as? [[String: Any]]) ?? []
        return list.compactMap(Self.notification(_:)).sorted { $0.time < $1.time }
    }

    /// A message of the inbox: its type and time at the top, the camera in `attachments` (`deviceId`, and `chnId`,
    /// `deviceModel`, `alias`), as the cloud answers; a `deviceId` at the top is read too.
    static func notification(_ item: [String: Any]) -> Notification? {
        let attachments = item["attachments"] as? [String: Any] ?? [:]
        guard let deviceID = (item["deviceId"] as? String) ?? (attachments["deviceId"] as? String), !deviceID.isEmpty else { return nil }
        let id = (item["msgId"] as? String) ?? (item["msgId"] as? NSNumber)?.stringValue ?? ""
        var time = (item["time"] as? NSNumber)?.doubleValue ?? (item["time"] as? String).flatMap(Double.init) ?? 0
        // Milliseconds, if that is what came.
        if time > 100_000_000_000 { time /= 1000 }
        return Notification(id: id, type: item["msgType"] as? String ?? item["eventType"] as? String ?? "", deviceID: deviceID, time: time)
    }

    /// A Tapo device's alias is Base64 of its name (4.1); one that does not decode is the name.
    static func alias(_ text: String) -> String {
        guard let data = Data(base64Encoded: text), let name = String(data: data, encoding: .utf8), !name.isEmpty else { return text }
        return name
    }

    static func normalizedMAC(_ mac: String) -> String {
        mac.uppercased().filter { $0.isHexDigit }
    }
}

enum TapoCloudError: Error, CustomStringConvertible {
    case noAccount
    case mfaRequired(processID: String)
    case code(Int, appServerURL: String? = nil, processID: String? = nil)
    case http(Int)
    case invalidResponse(String)

    /// A refusal no retry fixes: a wrong password, a locked account, a code needed.
    var isRefusedSignIn: Bool {
        switch self {
        case .noAccount, .mfaRequired: true
        case .code(let code, _, _): code == -20601 || code == -20675 || code == -20677
        default: false
        }
    }

    var description: String {
        switch self {
        case .noAccount: "no Tapo account"
        case .mfaRequired: "the Tapo cloud wants a code it e-mails to the account"
        case .code(-20601, _, _): "the Tapo cloud refused the e-mail and password"
        case .code(-20675, _, _): "the Tapo account is locked after too many attempts"
        case .code(let code, _, _): "the Tapo cloud answered error \(code)"
        case .http(let status): "the Tapo cloud answered HTTP \(status)"
        case .invalidResponse(let what): "unexpected answer from the Tapo cloud (\(what))"
        }
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}
