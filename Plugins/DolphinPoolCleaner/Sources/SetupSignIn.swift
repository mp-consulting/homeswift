import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// What Setup's sign-in (DolphinSetup.swift) needs once Cognito has answered, as the Homebridge plugin's settings
/// server does it: MyDolphin's `authenticate-user` for the robot and its picture, and Cognito's errors in words.
actor SetupSignIn {
    /// The robot's picture is kept for the page when it is an image this size at most.
    static let maximumImageSize = 2 * 1024 * 1024

    /// Cognito's errors in words; anything else is Cognito's own message.
    static let errorMessages: [(type: String, message: String)] = [
        ("NotAuthorizedException", "Invalid email or password"),
        ("UserNotFoundException", "User not found. Please check your email address."),
        ("UserNotConfirmedException", "Please confirm your email address first"),
        ("CodeMismatchException", "Invalid verification code"),
        ("ExpiredCodeException", "Verification code has expired. Please try again."),
    ]

    private let backend: MyDolphinClient
    private let transport: any HTTPSending
    private let images: RobotImages
    private let logger: Logger

    init(transport: any HTTPSending, images: RobotImages, logger: Logger) {
        backend = MyDolphinClient(transport: transport, timeout: Maytronics.setupRequestTimeout)
        self.transport = transport
        self.images = images
        self.logger = logger
    }

    struct Tokens {
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
    func completeAuthentication(_ tokens: Tokens) async -> JSONValue {
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
            response.body.count <= SetupSignIn.maximumImageSize,
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
