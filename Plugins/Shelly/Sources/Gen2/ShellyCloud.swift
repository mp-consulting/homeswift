import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging
import HomeswiftPlugin
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
/// (control.shelly.cloud) does: it signs in (`POST https://api2.shelly.cloud/v2/users/auth/login`, `{email, password}`, the
/// password's SHA-1 in hex, as the app's sign-in form sends it), whose
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
        case hours([MeterHourImport])
        /// The email and password were refused.
        case refused
        /// Nothing usable: another shape, an error, or no such device.
        case nothing
        /// The span came back in steps longer than an hour (days): it must be asked a day at a time.
        case notHourly
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
        // The password as the Shelly app sends it: its SHA-1, in lowercase hex.
        var fields: [String: JSONValue] = ["email": .string(credentials.email.lowercased()), "password": .string(TextDigest.sha1(credentials.password))]
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
        return WebPushDecryption.base64URLDecode(String(parts[1])).flatMap { try? JSONValue(data: Data($0)) }
    }

    /// The session to ask with: the current one, else a new sign-in when it is near its end; or how that sign-in went.
    private func currentSession() async -> Result<(token: String, server: URL), SignInFailure> {
        if let session, session.expires.timeIntervalSinceNow > 60 { return .success((session.token, session.server)) }
        let outcome = await signIn()
        guard outcome == .signedIn, let session else { return .failure(SignInFailure(refused: outcome == .refused)) }
        return .success((session.token, session.server))
    }

    struct SignInFailure: Error { var refused: Bool }

    /// The cloud's day and hour format, in a time zone.
    static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format
    }

    // MARK: Names

    /// The names the Shelly app gave the account's devices, which it keeps in the cloud alone (a device's own
    /// `sys.device.name` stays empty): by the cloud's id, a MAC in lowercase for a device or its channel 0, `<mac>_<n>` for
    /// channel n. Read as the app does when it starts: `POST /interface/device/get_all_lists` (an empty form) with the token,
    /// whose `data.devices` holds an entry per device and channel with its `name` ("unnamed" when it has none). Empty when
    /// the cloud refuses or answers another shape.
    func deviceNames() async -> [String: String] {
        for attempt in 0..<2 {
            guard case .success(let session) = await currentSession(),
                  let url = URL(string: session.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/interface/device/get_all_lists")
            else { return [:] }
            let request = HTTPRequest(method: "POST", url: url, headers: [("Authorization", "Bearer \(session.token)"), ("Content-Type", "application/x-www-form-urlencoded")],
                                      body: Data(), timeout: .seconds(15))
            guard let response = try? await http.send(request) else { return [:] }
            if response.status == 401 || response.status == 403 {
                self.session = nil
                if attempt == 0 { continue }
                return [:]
            }
            guard response.status == 200, let json = try? JSONValue(data: response.body) else {
                logger.debug("Shelly Cloud's device list answered HTTP \(response.status)")
                return [:]
            }
            return Self.names(json)
        }
        return [:]
    }

    /// The names in a device list: `data.devices`, an object (or a list) of entries with an `id` and a `name`.
    static func names(_ json: JSONValue) -> [String: String] {
        let devices = json["data"]?["devices"]
        let entries = devices?.objectValue.map { Array($0.values) } ?? devices?.arrayValue ?? []
        var names: [String: String] = [:]
        for entry in entries {
            let id = entry["id"]?.stringValue ?? entry["id"]?.number.map { String(Int($0)) }
            guard let id, let name = entry["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != "unnamed" else { continue }
            names[id.lowercased()] = name
        }
        return names
    }

    // MARK: History

    /// One day's hours of a device's channel (`id` its MAC in lowercase, as the cloud names it), midnight to midnight in
    /// `timeZone`. A refused token signs in again once.
    func consumption(id: String, channel: Int, day: Date, days: Int = 1, timeZone: TimeZone, endpoint: String = "") async -> Answer {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: day)
        let format = Self.formatter(timeZone)
        let query = URLEncoding.form([("id", id), ("channel", String(channel)), ("date_range", "custom"),
                                      ("date_from", format.string(from: start)),
                                      ("date_to", format.string(from: (calendar.date(byAdding: .day, value: max(1, days), to: start) ?? start.addingTimeInterval(86_400)).addingTimeInterval(-1)))])
        for attempt in 0..<2 {
            let session: (token: String, server: URL)
            switch await currentSession() {
            case .success(let current): session = current
            case .failure(let failure): return failure.refused ? .refused : .nothing
            }
            guard let url = URL(string: session.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v2/statistics/power-consumption\(endpoint)?" + query) else { return .nothing }
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
            if case .hours(let hours) = answer, !hours.isEmpty {
                // Several days asked: hourly figures only, else a day at a time (the cloud may sum a long span by day).
                let body = json["history"] != nil ? json : (json["data"] ?? .null)
                let interval = (body["interval"] ?? body["history_interval"])?.stringValue
                if days > 1 { logger.debug("Shelly Cloud gave \(days) days of history by \(interval ?? "an unnamed step") (\(hours.count) entries)", metadata: ["endpoint": "\(endpoint.isEmpty ? "relay" : endpoint)"]) }
                if days > 1, interval.map({ $0 != "hour" }) ?? (hours.count <= days) { return .notHourly }
                return answer
            }
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
    /// its `timezone` (else `timeZone`), the figures in Wh; an hour marked `missing` left out. An energy meter's phases
    /// (lists of their own) are added up by hour.
    static func answer(_ json: JSONValue, timeZone: TimeZone, logger: Logger) -> Answer {
        let body = json["history"] != nil ? json : (json["data"] ?? .null)
        // An answer with nothing in it is described once, by `consumption`.
        guard json["isok"]?.boolValue == true || json["history"] != nil else {
            let errors = json["errors"]?.objectValue?.keys.sorted() ?? []
            return errors.contains { $0.contains("auth") || $0.contains("unauthorized") || $0.contains("token") } ? .refused : .nothing
        }
        guard let history = body["history"]?.arrayValue else { return .nothing }
        let format = formatter(body["timezone"]?.stringValue.flatMap(TimeZone.init(identifier:)) ?? timeZone)
        // An energy meter's history may hold a list per phase (the web view flattens them): each hour added up.
        var byHour: [Date: MeterHourImport] = [:]
        for entry in history.flatMap({ $0.arrayValue ?? [$0] }) {
            guard entry["missing"]?.boolValue != true, let text = entry["datetime"]?.stringValue, let start = format.date(from: text),
                  let consumption = entry["consumption"]?.number, consumption.isFinite, consumption >= 0 else { continue }
            let returned = entry["reversed"]?.number.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            var hour = byHour[start] ?? MeterHourImport(start: start, consumption: 0)
            hour.consumption = (hour.consumption ?? 0) + consumption
            if let returned { hour.returned = (hour.returned ?? 0) + returned }
            byHour[start] = hour
        }
        let hours = byHour.values.sorted { $0.start < $1.start }
        return .hours(hours)
    }
}
