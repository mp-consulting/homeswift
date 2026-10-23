import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Temporary AWS credentials for AWS IoT, from MyDolphin's `getToken`.
struct IoTCredentials: Sendable, Equatable {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String
    var expiration: Date
}

/// The account's sign-in settings from config.json.
struct AccountSettings: Sendable, Equatable {
    var email: String?
    var password: String?
    var refreshToken: String?
    var iotRegion: String?
}

/// What a sign-in produced.
struct LoginResult: Sendable, Equatable {
    var serialNumber: String
    var robotName: String
    var deviceType: Int
}

/// Signs in to MyDolphin Plus in three steps, as the app does:
/// 1. AWS Cognito: the refresh token the setup page stored, else the email and password
///    (`USER_PASSWORD_AUTH`), for an ID token;
/// 2. MyDolphin's `authenticate-user` with the ID token: the robot's serial number, name and device type;
/// 3. MyDolphin's `getToken`: temporary AWS credentials for AWS IoT.
///
/// The IoT endpoint is fixed per region (it belongs to the MyDolphin AWS account), so it comes from
/// `Maytronics.iotEndpoints` rather than a DescribeEndpoint call. Concurrent callers share one sign-in.
actor AuthenticationManager {
    let settings: AccountSettings
    let iotRegion: String
    let iotEndpoint: String
    let cognito: CognitoClient
    let backend: MyDolphinClient
    private let logger: Logger
    private var pendingLogin: Task<LoginResult, any Error>?

    private(set) var idToken: String?
    private(set) var serialNumber: String?
    private(set) var robotName: String?
    private(set) var deviceType: Int?
    private(set) var awsCredentials: IoTCredentials?

    init(settings: AccountSettings, transport: any HTTPSending, logger: Logger) {
        self.settings = settings
        self.logger = logger
        cognito = CognitoClient(transport: transport)
        backend = MyDolphinClient(transport: transport)
        // The endpoint and the signing region must match, so both come from the same entry.
        var region = Maytronics.defaultIoTRegion
        if let configured = settings.iotRegion, !configured.isEmpty {
            if Maytronics.iotEndpoints[configured] != nil {
                region = configured
            } else {
                logger.warning("Unknown IoT region \"\(configured)\", using \(Maytronics.defaultIoTRegion)")
            }
        }
        iotRegion = region
        iotEndpoint = Maytronics.iotEndpoints[region]!
    }

    /// The whole sign-in. Concurrent callers share one attempt.
    func login() async throws -> LoginResult {
        if let pendingLogin { return try await pendingLogin.value }
        let task = Task { try await performLogin() }
        pendingLogin = task
        defer { pendingLogin = nil }
        return try await task.value
    }

    /// Signs in again when the AWS credentials expire within the hour.
    func ensureValidCredentials() async throws {
        if needsRefresh {
            logger.debug("Credentials expired or expiring soon, refreshing...")
            _ = try await login()
        }
    }

    var needsRefresh: Bool {
        guard let awsCredentials else { return true }
        return awsCredentials.expiration < Date().addingTimeInterval(Maytronics.credentialRefreshMargin)
    }

    private func performLogin() async throws -> LoginResult {
        do {
            logger.debug("Starting authentication flow...")
            try await authenticateWithCognito()
            try await authenticateWithMyDolphin()
            try await fetchIoTCredentials()
            logger.info("Successfully authenticated with MyDolphin Plus")
            guard let serialNumber else { throw DolphinError.myDolphinFailed("No robot serial number after authentication") }
            return LoginResult(serialNumber: serialNumber, robotName: robotName ?? "Dolphin Robot", deviceType: deviceType ?? Maytronics.defaultDeviceType)
        } catch {
            logger.error("Login failed: \(error)")
            throw error
        }
    }

    /// Step 1: an ID token from Cognito.
    private func authenticateWithCognito() async throws {
        let response: JSONValue
        do {
            if let refreshToken = settings.refreshToken, !refreshToken.isEmpty {
                logger.debug("Authenticating with refresh token...")
                response = try await cognito.initiateAuth(flow: "REFRESH_TOKEN_AUTH", parameters: ["REFRESH_TOKEN": refreshToken])
            } else if let email = settings.email, !email.isEmpty, let password = settings.password, !password.isEmpty {
                logger.debug("Authenticating with email/password...")
                response = try await cognito.initiateAuth(flow: "USER_PASSWORD_AUTH", parameters: ["USERNAME": email, "PASSWORD": password])
            } else {
                throw DolphinError.invalidCredentials("No authentication credentials available (need refreshToken or email/password)")
            }
        } catch let error as DolphinError where error.isPermanent {
            throw error
        } catch let error as CognitoError {
            switch error.type {
            case "NotAuthorizedException" where settings.refreshToken?.isEmpty == false:
                throw DolphinError.tokenExpired("Refresh token expired. Please re-authenticate through the plugin settings.")
            case "NotAuthorizedException":
                throw DolphinError.invalidCredentials("Invalid email or password")
            case "UserNotFoundException":
                throw DolphinError.invalidCredentials("User not found. Please check your email address.")
            default:
                logger.error("Cognito authentication failed: \(error)")
                throw DolphinError.cognitoFailed("Failed to authenticate with AWS Cognito")
            }
        } catch {
            logger.error("Cognito authentication failed: \(error)")
            throw DolphinError.cognitoFailed("Failed to authenticate with AWS Cognito")
        }
        // A challenge (the account asks for a code) leaves no token: the setup page handles those.
        guard let token = response["AuthenticationResult"]?["IdToken"]?.stringValue, !token.isEmpty else {
            throw DolphinError.cognitoFailed("No ID token received from Cognito")
        }
        idToken = token
        logger.debug("Cognito authentication successful")
    }

    /// Step 2: the MyDolphin backend, with the Cognito ID token.
    private func authenticateWithMyDolphin() async throws {
        let envelope: MyDolphinClient.Envelope
        do {
            envelope = try await backend.post("/mobapi/user/authenticate-user/", form: nil, bearer: idToken)
        } catch {
            logger.error("MyDolphin API error: \(error)")
            throw DolphinError.myDolphinFailed("Failed to authenticate with MyDolphin backend")
        }
        guard envelope.isSuccess, let data = envelope.data, let serial = data["Sernum"]?.stringValue else {
            throw DolphinError.myDolphinFailed("Authentication failed: \(envelope.alert ?? "Unknown error")")
        }
        serialNumber = serial
        robotName = data["MyRobotName"]?.stringValue
        deviceType = Self.deviceType(data["connectVia"])
        logger.debug("MyDolphin backend authentication successful")
        logger.debug("Robot serial: \(serial), Name: \(robotName ?? "")")
    }

    /// Step 3: temporary AWS credentials for AWS IoT.
    private func fetchIoTCredentials() async throws {
        let envelope: MyDolphinClient.Envelope
        do {
            envelope = try await backend.get(
                "/mt-sso/aws/getToken/", parameters: [("sernum", serialNumber), ("device_type", deviceType.map(String.init))], bearer: idToken)
        } catch {
            logger.error("AWS credentials error: \(error)")
            throw DolphinError.awsCredentialsFailed("Failed to get AWS IoT credentials")
        }
        logger.debug("AWS credentials response received, status: \(envelope.status ?? "none")")
        guard envelope.isSuccess, let data = envelope.data,
            let accessKey = data["AccessKeyId"]?.stringValue, let secret = data["SecretAccessKey"]?.stringValue, let token = data["Token"]?.stringValue
        else {
            throw DolphinError.awsCredentialsFailed("Failed to get AWS credentials: \(envelope.alert ?? "Unknown error")")
        }
        // An unreadable date never compares as expired in JavaScript; the same here.
        let expiration = data["TokenExpiration"]?.stringValue.flatMap(Self.parseDate) ?? Date.distantFuture
        awsCredentials = IoTCredentials(accessKeyID: accessKey, secretAccessKey: secret, sessionToken: token, expiration: expiration)
        logger.debug("AWS credentials obtained, expire at: \(expiration)")
    }

    /// `connectVia` as a number: 62 when missing or unreadable.
    static func deviceType(_ value: JSONValue?) -> Int {
        let parsed: Int? = switch value {
        case .string(let text)?: Int(text.prefix { $0.isNumber || $0 == "-" })
        case .number(let number)?: Int(saturating: number)
        default: nil
        }
        guard let parsed, parsed != 0 else { return Maytronics.defaultDeviceType }
        return parsed
    }

    /// The expiration as JavaScript's `new Date()` reads it: ISO 8601, with or without fractions.
    static func parseDate(_ text: String) -> Date? {
        internetDate.date(from: text) ?? fractionalDate.date(from: text) ?? spacedDate.date(from: text)
    }

    // Formatters only read from, which they allow from any thread. `Date.ISO8601FormatStyle` would be Sendable
    // but reads differently (it rejects leading spaces, keeps more than milliseconds).
    nonisolated(unsafe) private static let internetDate = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    /// "2026-01-01 12:00:00" in UTC, as some backends write it.
    nonisolated(unsafe) private static let spacedDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
