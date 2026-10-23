import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The sign-in of the setup page, as the Homebridge plugin's settings server does it: Cognito's
/// `CUSTOM_AUTH` with the email only, which sends a verification code (by email, SMS or an authenticator
/// app), then `RespondToAuthChallenge` with the code, then MyDolphin's `authenticate-user` for the robot.
/// The page stores the Cognito refresh token in the block instead of a password.
///
/// The Cognito session between the two steps stays here, keyed by email, for five minutes.
actor SetupWizard {
    static let sessionLifetime: TimeInterval = 5 * 60
    /// The robot's picture is kept for the page when it is an image this size at most.
    static let maximumImageSize = 2 * 1024 * 1024

    static let challengeMessages = [
        "SMS_MFA": "Please enter the verification code sent to your phone",
        "SOFTWARE_TOKEN_MFA": "Please enter the code from your authenticator app",
        "CUSTOM_CHALLENGE": "Please enter the verification code sent to your email",
        "MFA_SETUP": "MFA setup required. Please complete setup in the MyDolphin app first.",
    ]

    /// Cognito's errors in words; anything else is Cognito's own message.
    static let errorMessages: [(type: String, message: String)] = [
        ("NotAuthorizedException", "Invalid email or password"),
        ("UserNotFoundException", "User not found. Please check your email address."),
        ("UserNotConfirmedException", "Please confirm your email address first"),
        ("CodeMismatchException", "Invalid verification code"),
        ("ExpiredCodeException", "Verification code has expired. Please try again."),
    ]

    private struct Session {
        var session: String
        var challengeName: String
        var createdAt: Date
    }

    private let cognito: CognitoClient
    private let backend: MyDolphinClient
    private let transport: any HTTPSending
    private let images: RobotImages
    private let logger: Logger
    private var sessions: [String: Session] = [:]

    init(transport: any HTTPSending, images: RobotImages, logger: Logger) {
        cognito = CognitoClient(transport: transport, timeout: Maytronics.setupRequestTimeout)
        backend = MyDolphinClient(transport: transport, timeout: Maytronics.setupRequestTimeout)
        self.transport = transport
        self.images = images
        self.logger = logger
    }

    /// Step 1: asks Cognito for a code. The answer says which kind of code, or why not.
    func authenticate(email: String?) async -> JSONValue {
        guard let email = email?.trimmingCharacters(in: .whitespaces), !email.isEmpty else {
            return Self.failure("Email is required")
        }
        cleanExpiredSessions()
        do {
            let response = try await cognito.initiateAuth(flow: "CUSTOM_AUTH", parameters: ["USERNAME": email])
            if let challenge = response["ChallengeName"]?.stringValue, !challenge.isEmpty {
                sessions[email] = Session(session: response["Session"]?.stringValue ?? "", challengeName: challenge, createdAt: Date())
                return Self.challenge(challenge)
            }
            // Direct success, rare with CUSTOM_AUTH.
            guard let tokens = Tokens(response) else { return Self.failure("Unexpected authentication response") }
            return await completeAuthentication(tokens)
        } catch {
            logger.warning("Setup sign-in failed: \(Self.message(for: error))")
            return Self.failure(Self.message(for: error))
        }
    }

    /// Step 2: the code. Answers with the robot and the refresh token for the block.
    func verify(email: String?, code: String?) async -> JSONValue {
        guard let email = email?.trimmingCharacters(in: .whitespaces), !email.isEmpty,
            let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty
        else {
            return Self.failure("Email and OTP code are required")
        }
        cleanExpiredSessions()
        guard let session = sessions[email] else { return Self.failure("No pending authentication. Please try again.") }
        guard Date().timeIntervalSince(session.createdAt) <= Self.sessionLifetime else {
            sessions[email] = nil
            return Self.failure("Session expired. Please try again.")
        }
        let field = ["SMS_MFA": "SMS_MFA_CODE", "SOFTWARE_TOKEN_MFA": "SOFTWARE_TOKEN_MFA_CODE", "CUSTOM_CHALLENGE": "ANSWER"][session.challengeName] ?? "SMS_MFA_CODE"
        do {
            let response = try await cognito.respondToAuthChallenge(
                name: session.challengeName, session: session.session, responses: ["USERNAME": email, field: code])
            // Another challenge (rare): the next code goes with the new session.
            if let challenge = response["ChallengeName"]?.stringValue, !challenge.isEmpty {
                sessions[email] = Session(session: response["Session"]?.stringValue ?? "", challengeName: challenge, createdAt: session.createdAt)
                return Self.challenge(challenge)
            }
            guard let tokens = Tokens(response) else { return Self.failure("No authentication token received") }
            sessions[email] = nil
            return await completeAuthentication(tokens)
        } catch {
            logger.warning("Setup verification failed: \(Self.message(for: error))")
            return Self.failure(Self.message(for: error))
        }
    }

    private struct Tokens {
        var idToken: String
        var refreshToken: String?

        init?(_ response: JSONValue) {
            guard let result = response["AuthenticationResult"], let idToken = result["IdToken"]?.stringValue, !idToken.isEmpty else { return nil }
            self.idToken = idToken
            refreshToken = result["RefreshToken"]?.stringValue
        }
    }

    /// MyDolphin's `authenticate-user` for the robot, then its details for the picture. Only the refresh token
    /// leaves: the short-lived ID and access tokens never need to.
    private func completeAuthentication(_ tokens: Tokens) async -> JSONValue {
        let envelope: MyDolphinClient.Envelope
        do {
            envelope = try await backend.post("/mobapi/user/authenticate-user/", form: nil, bearer: tokens.idToken)
        } catch let error as MyDolphinHTTPError where error.status < 500 {
            // A 4xx still carries the envelope.
            envelope = (try? JSONValue(data: error.body)).map(MyDolphinClient.Envelope.init(json:)) ?? .init(status: nil)
        } catch {
            return Self.failure(Self.message(for: error))
        }
        guard envelope.isSuccess, let data = envelope.data, let serialNumber = data["Sernum"]?.stringValue else {
            return Self.failure(envelope.alert ?? "MyDolphin authentication failed")
        }
        let robotName = data["MyRobotName"]?.stringValue.nonEmpty ?? "Dolphin Robot"
        let deviceType = AuthenticationManager.deviceType(data["connectVia"])

        var imageURL: String?
        var model: String?
        do {
            let details = try await backend.post("/mobapi/serial-numbers/getRobotDetailsByRobotSN/", form: [("SERNUM", serialNumber)], bearer: tokens.idToken)
            if details.isSuccess, let data = details.data {
                imageURL = data["originalUrlImage"]?.stringValue.nonEmpty ?? data["Originalmg"]?.stringValue.nonEmpty
                model = data["PARTDES"]?.stringValue.nonEmpty
            }
        } catch {
            logger.info("Could not fetch robot image URL: \(error)")
        }
        if let imageURL { await images.fetch(imageURL, serialNumber: serialNumber, transport: transport) }

        var result: [String: JSONValue] = [
            "success": true, "serialNumber": .string(serialNumber), "robotName": .string(robotName), "deviceType": .number(Double(deviceType)),
            "robotImageUrl": imageURL.map { .string($0) } ?? .null,
        ]
        if let model { result["model"] = .string(model) }
        if let refreshToken = tokens.refreshToken { result["refreshToken"] = .string(refreshToken) }
        logger.info("Setup signed in", metadata: ["robot": "\(robotName)"])
        return .object(result)
    }

    private func cleanExpiredSessions() {
        let now = Date()
        sessions = sessions.filter { now.timeIntervalSince($0.value.createdAt) <= Self.sessionLifetime }
    }

    private static func challenge(_ name: String) -> JSONValue {
        ["success": false, "requiresOtp": true, "challengeName": .string(name), "message": .string(challengeMessages[name] ?? "Please enter the verification code")]
    }

    static func failure(_ message: String) -> JSONValue { ["success": false, "error": .string(message)] }

    static func message(for error: any Error) -> String {
        switch error {
        case let error as CognitoError:
            errorMessages.first { error.type.contains($0.type) }?.message ?? (error.message.isEmpty ? "Authentication failed" : error.message)
        case let error as MyDolphinHTTPError:
            "Maytronics API error: HTTP \(error.status)"
        case let error as DolphinError:
            error.description
        default:
            "\(error)"
        }
    }
}

/// The robots' pictures from the MyDolphin backend, kept in the plugin's directory: the UI's pages load
/// images from their own origin only, so the page gets them from the plugin as data URLs.
struct RobotImages: Sendable {
    let directory: URL?

    private func url(serialNumber: String) -> URL? {
        let safe = serialNumber.filter { $0.isLetter || $0.isNumber }
        guard !safe.isEmpty else { return nil }
        return directory?.appendingPathComponent("robot-image-\(safe).json")
    }

    /// Downloads the picture the backend named, over HTTPS, when it is an image of reasonable size.
    func fetch(_ address: String, serialNumber: String, transport: any HTTPSending) async {
        guard let source = URL(string: address), source.scheme == "https" || source.scheme == "http", let file = url(serialNumber: serialNumber) else { return }
        guard let response = try? await HTTPRedirects.send(HTTPRequest(method: "GET", url: source, timeout: .seconds(15)), through: transport), response.isSuccess,
            response.body.count <= SetupWizard.maximumImageSize,
            let type = response.header("Content-Type")?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
            ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(type)
        else { return }
        let record: JSONValue = ["contentType": .string(type), "data": .string(response.body.base64EncodedString()), "source": .string(address)]
        try? OwnerOnlyFile.write(record.encoded(), to: file)
    }

    /// The picture as a `data:` URL, when one was kept.
    func dataURL(serialNumber: String) -> String? {
        guard let file = url(serialNumber: serialNumber), let data = try? Data(contentsOf: file), let record = try? JSONValue(data: data),
            let type = record["contentType"]?.stringValue, let body = record["data"]?.stringValue
        else { return nil }
        return "data:\(type);base64,\(body)"
    }
}
