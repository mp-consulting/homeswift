import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

/// The Shelly Cloud account of an instance (an Optional Account): the email and password of the Shelly app, kept in the
/// vault.
struct ShellyCloudCredentials: Codable, Sendable, Equatable {
    var email: String
    var password: String
}

/// Shelly Cloud's record of a plug's or relay's energy, which the Shelly app graphs: for a device that keeps no records of
/// its own (an `em` keeps weeks; a plug, its last minutes).
///
/// **Unofficial.** Shelly documents no history endpoint, nor a sign-in for others' apps (its Cloud Control API, v1 and v2,
/// reads status and controls devices with an authorization key). This does what the Shelly app's web view
/// (control.shelly.cloud) does: it signs in (`POST https://api2.shelly.cloud/v2/users/auth/login`, `{email, password}`), whose
/// access token (a JWT) names the account's server (`user_api_url`) and when it expires, then asks that server
/// `GET /v2/statistics/power-consumption?id=&channel=&date_range=custom&date_from=&date_to=` with the token as a Bearer.
/// It may change or go without notice: an answer of another shape is taken as no history, never as figures. It signs in
/// again when the token is near its end or refused. The password and the token never reach a log line; addresses carry
/// neither.
actor ShellyCloud {
    let credentials: ShellyCloudCredentials
    let http: any HTTPSending
    let logger: Logger
    /// Where the sign-in goes.
    let authServer: URL
    /// The current sign-in: its token, the account's server, when the token ends.
    private var session: (token: String, server: URL, expires: Date)?

    init(credentials: ShellyCloudCredentials, http: any HTTPSending, logger: Logger, authServer: URL = URL(string: "https://api2.shelly.cloud")!) {
        self.credentials = credentials
        self.http = http
        self.logger = logger
        self.authServer = authServer
    }

    /// What the cloud said: hours of energy (Wh drawn, and sent back where it says), or why there are none.
    enum Answer: Sendable, Equatable {
        case hours([(start: Date, consumption: Double, returned: Double?)])
        /// The email and password were refused.
        case refused
        /// Nothing usable: another shape, an error, or no such device.
        case nothing

        static func == (a: Answer, b: Answer) -> Bool {
            switch (a, b) {
            case (.refused, .refused), (.nothing, .nothing): true
            case let (.hours(x), .hours(y)): x.map(\.start) == y.map(\.start) && x.map(\.consumption) == y.map(\.consumption) && x.map(\.returned) == y.map(\.returned)
            default: false
            }
        }
    }

    /// How signing in went.
    enum SignIn: Sendable, Equatable {
        case signedIn
        case refused
        case failed(String)
    }

    // MARK: Signing in

    /// Signs in with the email and password, keeping the token for the requests that follow. An account with several homes
    /// (units) signs in to the one the cloud selects, else the first.
    func signIn() async -> SignIn {
        var fields: [String: JSONValue] = ["email": .string(credentials.email.lowercased()), "password": .string(credentials.password)]
        for attempt in 0..<2 {
            guard let body = try? JSONValue.object(fields).encoded() else { return .failed("cannot write the request") }
            let request = HTTPRequest(method: "POST", url: authServer.appendingPathComponent("v2/users/auth/login"),
                                      headers: [("Content-Type", "application/json")], body: body, timeout: .seconds(30))
            let response: HomeswiftNetwork.HTTPResponse
            do { response = try await http.send(request) } catch { return .failed("Shelly Cloud does not answer (\(type(of: error)))") }
            if response.status == 401 || response.status == 403 { return .refused }
            guard let json = try? JSONValue(data: response.body) else { return .failed("Shelly Cloud answered HTTP \(response.status)") }
            if let token = json["accessToken"]?.stringValue, let claims = Self.claims(of: token),
               let server = claims["user_api_url"]?.stringValue.flatMap(URL.init(string:)) {
                let expires = claims["exp"]?.number.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(3600)
                session = (token, server, expires)
                return .signedIn
            }
            // Several homes: again, for one of them.
            if attempt == 0, let units = json["availableUnits"]?.objectValue, !units.isEmpty {
                let unit = json["selectedUnitId"]?.number.map { String(Int($0)) } ?? units.keys.sorted().first!
                if let number = Int(unit) { fields["unit"] = .number(Double(number)) }
                continue
            }
            let errors = json["errors"]?.objectValue?.keys.sorted() ?? []
            logger.debug("Shelly Cloud's sign-in gave no token", metadata: ["status": "\(response.status)", "errors": "\(errors)", "keys": "\(json.objectValue?.keys.sorted() ?? [])"])
            return response.status == 400 && !errors.isEmpty || errors.contains(where: { $0.contains("password") || $0.contains("credential") || $0.contains("user") }) ? .refused
                : .failed("Shelly Cloud gave no token (HTTP \(response.status))")
        }
        return .failed("Shelly Cloud gave no token")
    }

    /// A JWT's claims: its middle part, base64url JSON; nil for anything else.
    static func claims(of token: String) -> JSONValue? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap { try? JSONValue(data: $0) }
    }

    /// The session to ask with: the current one, else a new sign-in when it is near its end.
    private func currentSession() async -> (token: String, server: URL)? {
        if let session, session.expires.timeIntervalSinceNow > 60 { return (session.token, session.server) }
        guard await signIn() == .signedIn, let session else { return nil }
        return (session.token, session.server)
    }

    // MARK: History

    /// One day's hours of a device's channel (`id` its MAC in lowercase, as the cloud names it), midnight to midnight in
    /// `timeZone`. A refused token signs in again once.
    func consumption(id: String, channel: Int, day: Date, timeZone: TimeZone) async -> Answer {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: day)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let query = URLEncoding.form([("id", id), ("channel", String(channel)), ("date_range", "custom"),
                                      ("date_from", format.string(from: start)), ("date_to", format.string(from: start.addingTimeInterval(86_399)))])
        for attempt in 0..<2 {
            guard let session = await currentSession() else { return await signIn() == .refused ? .refused : .nothing }
            guard let url = URL(string: session.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v2/statistics/power-consumption?" + query) else { return .nothing }
            let request = HTTPRequest(url: url, headers: [("Authorization", "Bearer \(session.token)")], timeout: .seconds(30))
            let response: HomeswiftNetwork.HTTPResponse
            do { response = try await http.send(request) } catch {
                Self.describe(logger, "did not answer (\(type(of: error)))")
                return .nothing
            }
            if response.status == 401 || response.status == 403 {
                // The token ended or was revoked: a new one, once.
                self.session = nil
                if attempt == 0 { continue }
                return .refused
            }
            guard response.status == 200, let json = try? JSONValue(data: response.body) else {
                Self.describe(logger, "answered HTTP \(response.status), \(response.body.count) bytes\(response.status == 200 ? ", not JSON" : "")")
                return .nothing
            }
            let answer = Self.answer(json, timeZone: timeZone, logger: logger)
            if case .hours(let hours) = answer, !hours.isEmpty { return answer }
            // The shape of an answer with nothing in it, to see what the unofficial endpoint gives: names, never values.
            let history = (json["history"] ?? json["data"]?["history"])?.arrayValue
            Self.describe(logger, "answered isok \(json["isok"].map { "\($0)" } ?? "missing"), keys \(json.objectValue?.keys.sorted() ?? []), "
                + "data keys \(json["data"]?.objectValue?.keys.sorted() ?? []), errors \(json["errors"]?.objectValue?.keys.sorted() ?? []), "
                + "\(history.map { "\($0.count) history entries, the first with \($0.first?.objectValue?.keys.sorted() ?? [])" } ?? "no history list")")
            return answer
        }
        return .nothing
    }

    /// How many answers with nothing in them were described in the log, this run: the first few, not a year's.
    private static let described = NIOLockedValueBox(0)

    /// Says in the log what an answer without hours was like (its shape only: no token, no figures), the first three times.
    static func describe(_ logger: Logger, _ text: String) {
        guard described.withLockedValue({ count in defer { count += 1 }; return count < 3 }) else { return }
        logger.info("Shelly Cloud's history \(text)")
    }

    /// The cloud's answer read: `{"history":[{"datetime":"2026-11-04 13:00:00","consumption":12.5,"reversed":0}],
    /// "timezone":"Europe/Paris"}`, or the same under `data` with `isok`, as the web view reads either; the datetimes in
    /// its `timezone` (else `timeZone`), the figures in Wh; an hour marked `missing` left out.
    static func answer(_ json: JSONValue, timeZone: TimeZone, logger: Logger) -> Answer {
        let body = json["history"] != nil ? json : (json["data"] ?? .null)
        guard json["isok"]?.boolValue == true || json["history"] != nil else {
            let errors = json["errors"]?.objectValue?.keys.sorted() ?? []
            logger.debug("Shelly Cloud gave no history", metadata: ["errors": "\(errors)"])
            return errors.contains { $0.contains("auth") || $0.contains("unauthorized") || $0.contains("token") } ? .refused : .nothing
        }
        guard let history = body["history"]?.arrayValue else {
            logger.debug("Shelly Cloud answered without a history", metadata: ["keys": "\(body.objectValue?.keys.sorted() ?? [])"])
            return .nothing
        }
        let zone = body["timezone"]?.stringValue.flatMap(TimeZone.init(identifier:)) ?? timeZone
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let hours = history.compactMap { entry -> (start: Date, consumption: Double, returned: Double?)? in
            guard entry["missing"]?.boolValue != true, let text = entry["datetime"]?.stringValue, let start = format.date(from: text),
                  let consumption = entry["consumption"]?.number, consumption.isFinite, consumption >= 0 else { return nil }
            let returned = entry["reversed"]?.number.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            return (start, consumption, returned)
        }
        return .hours(hours)
    }
}
