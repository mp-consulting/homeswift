import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging

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
/// devices). This asks the one the Shelly app uses, `/statistics/relay/consumption`, as community scripts do; it may change
/// or go without notice, and an answer of another shape is taken as no history, never as figures. The key goes in the
/// request's body, never in its address or a log line.
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
        guard let base, let url = URL(string: base.absoluteString + "/statistics/relay/consumption") else { return .nothing }
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
        let body = URLEncoding.form(fields)
        let request = HTTPRequest(method: "POST", url: url, headers: [("Content-Type", "application/x-www-form-urlencoded")], body: Data(body.utf8), timeout: .seconds(30))
        guard let response = try? await http.send(request) else { return .nothing }
        if response.status == 401 || response.status == 403 { return .refused }
        guard response.status == 200, let json = try? JSONValue(data: response.body) else { return .nothing }
        return Self.answer(json, timeZone: timeZone, logger: logger)
    }

    /// The cloud's answer read: `{"isok":true,"data":{"history":[{"datetime":"2026-11-04 13:00:00","consumption":12.5,
    /// "reversed":0}],"timezone":"Europe/Paris"}}`, the datetimes in `data.timezone` (else `timeZone`), the figures in Wh;
    /// an hour marked `missing` left out.
    static func answer(_ json: JSONValue, timeZone: TimeZone, logger: Logger) -> Answer {
        guard json["isok"]?.boolValue == true else {
            let errors = json["errors"]?.objectValue?.keys.sorted() ?? []
            logger.debug("Shelly Cloud gave no history", metadata: ["errors": "\(errors)"])
            return errors.contains { $0.contains("auth") || $0.contains("unauthorized") || $0.contains("token") } ? .refused : .nothing
        }
        guard let history = json["data"]?["history"]?.arrayValue else {
            logger.debug("Shelly Cloud answered without a history", metadata: ["keys": "\(json["data"]?.objectValue?.keys.sorted() ?? [])"])
            return .nothing
        }
        let zone = json["data"]?["timezone"]?.stringValue.flatMap(TimeZone.init(identifier:)) ?? timeZone
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
