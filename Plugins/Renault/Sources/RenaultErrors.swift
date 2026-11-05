import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// What can go wrong talking to Renault, in words a log or a Setup step can show. Never carries a token, a password, a
/// VIN in full or a body.
enum RenaultError: Error, CustomStringConvertible, Equatable, Sendable {
    /// Gigya: `403042`.
    case invalidCredentials
    /// Gigya: `403101`, with the registration token the 2FA flow needs.
    case needsTwoFactor(regToken: String)
    /// Gigya: `400006` at the code step.
    case wrongCode
    /// Gigya at getJWT: the login token is dead (`403005`, `403013`).
    case loginTokenExpired
    /// Any other Gigya error.
    case gigya(code: Int, details: String)
    case kamereon(KamereonError)
    case http(status: Int)
    case invalidJSON
    case unknownLocale(String)
    /// The hourly budget of requests is spent (6.1), or Renault said so (6.2's cool-down).
    case quota
    case notSignedIn
    /// The Kamereon account in the block is no longer the person's.
    case accountGone
    case missing(String)

    var description: String {
        switch self {
        case .invalidCredentials: "Renault refused the e-mail or the password"
        case .needsTwoFactor: "Renault asks for a one-time code"
        case .wrongCode: "The code is wrong; check it and try again"
        case .loginTokenExpired: "Renault's sign-in expired"
        case .gigya(let code, let details): "Renault's sign-in answered \(code)\(details.isEmpty ? "" : ": \(details)")"
        case .kamereon(let error): error.description
        case .http(let status): "Renault answered HTTP \(status)"
        case .invalidJSON: "Renault answered something that is not JSON"
        case .unknownLocale(let locale): "Renault has no servers for the locale \(locale)"
        case .quota: "the hourly quota of Renault requests is spent"
        case .notSignedIn: "the Renault account is not set up"
        case .accountGone: "the Kamereon account set up is no longer the person's"
        case .missing(let what): "Renault's answer has no \(what)"
        }
    }

    /// A refusal of the account (Needs Authorization), not a cloud that does not answer.
    var isRefusal: Bool {
        switch self {
        case .invalidCredentials, .needsTwoFactor, .loginTokenExpired, .accountGone: true
        default: false
        }
    }

    /// What Needs Authorization says for a refusal.
    var refusalReason: String {
        switch self {
        case .invalidCredentials: "Renault refused the password"
        case .needsTwoFactor: "Renault asks for a one-time code: set up the account again"
        case .loginTokenExpired: "Renault's sign-in expired and no password is stored"
        case .accountGone: "The Kamereon account set up is no longer the person's: set up the account again"
        default: description
        }
    }

    /// Kamereon refused the JWT: mint a new one and try once more.
    var isUnauthorizedSession: Bool {
        switch self {
        case .kamereon(let error): error.code == KamereonError.unauthorized || error.status == 401
        case .http(let status): status == 401
        default: false
        }
    }
}

/// A Kamereon error entry (4.7): its code and the readable detail of its message.
struct KamereonError: Error, CustomStringConvertible, Equatable, Sendable {
    var code: String
    var detail: String
    /// The HTTP status it came with.
    var status: Int

    static let overloaded = "err.func.wired.overloaded"
    static let unauthorized = "err.func.wired.unauthorized"
    static let forbidden = "err.func.wired.forbidden"
    static let accessDenied = "err.func.403"
    static let notSupported = "err.tech.501"

    var description: String {
        let known: String? = switch code {
        case Self.overloaded: "Renault's quota is reached"
        case "err.func.privacy.on": "the car's privacy mode is on"
        case "err.func.wired.low.battery.level": "the battery is too low for that"
        case "409001": "a charge mode change is already in progress"
        case Self.unauthorized: "Renault refused the session"
        case Self.forbidden: "Renault forbids that for this car"
        case Self.notSupported: "not supported by this car's gateway"
        default: nil
        }
        return "\(known ?? "Renault error") (\(code)\(detail.isEmpty ? "" : ": \(logSafe(detail))"))"
    }

    /// The first read of an endpoint failing with this means the car does not have it (4.7's Recommendation).
    var meansMissingEndpoint: Bool {
        [Self.notSupported, Self.forbidden, "err.func.wired.notFound", "err.func.wired.not-found", "400001", Self.accessDenied].contains(code)
            || (code.isEmpty && status == 404)
    }

    /// "Not supported" stops an endpoint at any time, not only on its first read.
    var alwaysDrops: Bool { code == Self.notSupported }

    /// The detail, short and on one line: Renault's texts can echo what was sent.
    private func logSafe(_ text: String) -> String {
        maskingVINs(in: logExcerpt(text, limit: 160) ?? "")
    }

    /// The readable detail of `errorMessage`: a JSON text with `errors[]` gives each one's `title`, `source.pointer` and
    /// `detail` joined with spaces, the errors joined with ", "; any other text as it is.
    static func detail(of message: String) -> String {
        guard message.hasPrefix("{"), let json = try? JSONValue(string: message), let errors = json["errors"]?.arrayValue else { return message }
        return errors.map { error in
            [error["title"]?.stringValue, error["source"]?["pointer"]?.stringValue, error["detail"]?.stringValue]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        }.joined(separator: ", ")
    }
}

/// A VIN as the log may show it: its first 3 and last 4 characters (7's Recommendation).
func maskedVIN(_ vin: String) -> String {
    guard vin.count > 7 else { return "…" }
    return "\(vin.prefix(3))…\(vin.suffix(4))"
}

/// `text` with anything shaped like a VIN (17 capital letters and digits) masked.
private let vinPattern = try? NSRegularExpression(pattern: "\\b[A-HJ-NPR-Z0-9]{17}\\b")

func maskingVINs(in text: String) -> String {
    guard text.utf8.count >= 17, let pattern = vinPattern else { return text }
    var result = text
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        result.replaceSubrange(range, with: maskedVIN(String(result[range])))
    }
    return result
}
