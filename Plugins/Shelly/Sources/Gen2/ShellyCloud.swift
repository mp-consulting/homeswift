import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

/// The Shelly Cloud account of an instance (an Optional Account): its server, as the Shelly app shows it beside the key
/// (`shelly-238-eu.shelly.cloud`), and its authorization cloud key (User settings, Authorization cloud key), kept in the
/// vault. Anyone with the key controls the account's devices; it changes with the account's password.
struct ShellyCloudCredentials: Codable, Sendable, Equatable {
    var server: String
    var authKey: String
}

/// Shelly Cloud's record of a plug's or relay's energy, which the Shelly app graphs: for a device that keeps no records of
/// its own (an `em` keeps weeks; a plug, its last minutes).
///
/// **Unofficial.** Shelly documents no history endpoint (its Cloud Control API, v1 and v2, only reads status and controls
/// devices). This asks the one the Shelly app's web view (control.shelly.cloud) asks for a plug's or relay's charts,
/// `GET /v2/statistics/power-consumption?id=&channel=&date_range=custom&date_from=&date_to=`; it may change or go without
/// notice, and an answer of another shape is taken as no history, never as figures. The key goes in the query, as the
/// documented v2 API takes it (`?auth_key=`); the address is never logged.
struct ShellyCloud: Sendable {
    let credentials: ShellyCloudCredentials
    let http: any HTTPSending
    let logger: Logger

    /// What the cloud said: hours of energy (Wh drawn, and sent back where it says), or why there are none.
    enum Answer: Sendable, Equatable {
        case hours([(start: Date, consumption: Double, returned: Double?)])
        /// The key or the server was refused (401, 403, or `isok` false with an authorization error).
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

    /// The server as an address: a host given alone gets `https://`.
    var base: URL? {
        let server = credentials.server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !server.isEmpty else { return nil }
        return URL(string: server.contains("://") ? server : "https://\(server)")
    }

    /// One day's hours of a device's channel (`id` its MAC in lowercase, as the cloud names it), midnight to midnight in
    /// `timeZone`.
    func consumption(id: String, channel: Int, day: Date, timeZone: TimeZone) async -> Answer {
        guard let base else { return .nothing }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: day)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let fields = [("id", id), ("channel", String(channel)), ("date_range", "custom"),
                      ("date_from", format.string(from: start)), ("date_to", format.string(from: start.addingTimeInterval(86_399))),
                      ("auth_key", credentials.authKey)]
        guard let url = URL(string: base.absoluteString + "/v2/statistics/power-consumption?" + URLEncoding.form(fields)) else { return .nothing }
        let request = HTTPRequest(url: url, timeout: .seconds(30))
        let response: HomeswiftNetwork.HTTPResponse
        do { response = try await http.send(request) } catch {
            // The error's kind only: its text could carry the address, and the address the key.
            Self.describe(logger, "did not answer (\(type(of: error)))")
            return .nothing
        }
        if response.status == 401 || response.status == 403 { return .refused }
        guard response.status == 200, let json = try? JSONValue(data: response.body) else {
            Self.describe(logger, "answered HTTP \(response.status), \(response.body.count) bytes\(response.status == 200 ? ", not JSON" : "")")
            return .nothing
        }
        let answer = Self.answer(json, timeZone: timeZone, logger: logger)
        if case .hours(let hours) = answer, !hours.isEmpty {
            // A day of zeros said once or twice too, with its dates and how it was cut: the endpoint's ways are not known.
            if hours.allSatisfy({ $0.consumption == 0 && ($0.returned ?? 0) == 0 }) {
                let body = json["history"] != nil ? json : (json["data"] ?? .null)
                Self.describe(logger, "gave \(hours.count) hours of zeros for \(format.string(from: start)), interval \(body["interval"]?.stringValue ?? body["history_interval"]?.stringValue ?? "none"), "
                    + "keys \(body.objectValue?.keys.sorted() ?? []), first entry \(body["history"]?[0]?.objectValue?.keys.sorted() ?? []) at \(body["history"]?[0]?["datetime"]?.stringValue ?? "?")")
            }
            return answer
        }
        // The shape of an answer with nothing in it, to see what the unofficial endpoint gives: names, never values.
        let history = (json["history"] ?? json["data"]?["history"])?.arrayValue
        Self.describe(logger, "answered isok \(json["isok"].map { "\($0)" } ?? "missing"), keys \(json.objectValue?.keys.sorted() ?? []), "
            + "data keys \(json["data"]?.objectValue?.keys.sorted() ?? []), errors \(json["errors"]?.objectValue?.keys.sorted() ?? []), "
            + "\(history.map { "\($0.count) history entries, the first with \($0.first?.objectValue?.keys.sorted() ?? [])" } ?? "no history list")")
        return answer
    }

    /// How many answers with nothing in them were described in the log, this run: the first few, not a year's.
    private static let described = NIOLockedValueBox(0)

    /// Says in the log what an answer without hours was like (its shape only: no key, no figures), the first three times.
    static func describe(_ logger: Logger, _ text: String) {
        guard described.withLockedValue({ count in defer { count += 1 }; return count < 3 }) else { return }
        logger.info("Shelly Cloud's history \(text)")
    }

    /// The cloud's answer read: `{"history":[{"datetime":"2026-11-04 13:00:00","consumption":12.5,"reversed":0}],
    /// "timezone":"Europe/Paris"}`, or the same under `data` with `isok`, as the web view reads either; the datetimes in
    /// its `timezone` (else `timeZone`), the figures in Wh;
    /// an hour marked `missing` left out.
    static func answer(_ json: JSONValue, timeZone: TimeZone, logger: Logger) -> Answer {
        let body = json["history"] != nil ? json : (json["data"] ?? .null)
        guard json["isok"]?.boolValue == true || json["history"] != nil else {
            let errors = json["errors"]?.objectValue?.keys.sorted() ?? []
            logger.debug("Shelly Cloud gave no history", metadata: ["errors": "\(errors)"])
            return errors.contains { $0.contains("auth") || $0.contains("unauthorized") || $0.contains("token") } ? .refused : .nothing
        }
        guard let history = body["history"]?.arrayValue else {
            logger.debug("Shelly Cloud answered without a history", metadata: ["keys": "\(json["data"]?.objectValue?.keys.sorted() ?? [])"])
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
