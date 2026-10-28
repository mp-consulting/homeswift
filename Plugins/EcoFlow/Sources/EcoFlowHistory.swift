import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// The EcoFlow cloud's energy history for the home a STREAM belongs to, as the app's Space dashboard shows it: each
/// hour's solar production and home use (from the system's smart meter when it has one), back to when the system was
/// set up. It is the app's own, unofficial API, with the account's email and password: one sign-in, then a request
/// per month and flow. The cloud keeps no grid or battery history there.
///
/// The space's answers also carry the home's address and coordinates: only its id and time zone are read, and no
/// answer is logged.
struct EcoFlowHistory: Sendable {
    let email: String
    let password: String
    let transport: any HTTPSending

    /// The headers the app sends: the space and history services answer a bare 400 without them.
    static let appHeaders: [(name: String, value: String)] = [
        (name: "lang", value: "en_US"), (name: "platform", value: "ios"), (name: "version", value: "6.17.5"),
        (name: "phoneModel", value: "Homeswift"), (name: "sysVersion", value: "1.0"),
    ]
    /// The charts read: an hour's watt-hours over a month at a time.
    static let solarCode = "SPACE-APP-SOLAR-ENERGY-BAR-DAY"
    static let homeCode = "SPACE-APP-LOAD-ENERGY-BAR-DAY"

    enum Failure: Error, CustomStringConvertible {
        case signIn(String), noSpace, refused(String, String), http(String, Int)

        var description: String {
            switch self {
            case .signIn(let message): "the EcoFlow app's sign-in failed: \(message)"
            case .noSpace: "the STREAM belongs to no home in the EcoFlow app"
            case .refused(let path, let message): "\(path) was refused: \(message)"
            case .http(let path, let status): "\(path) answered HTTP \(status)"
            }
        }
    }

    /// The home a device belongs to: its id, its time zone (the history's times are local to it) and when its system
    /// was set up.
    struct Space: Equatable {
        var id: String
        var rootID: String
        var timeZone: TimeZone
        var created: Date?
    }

    /// Each whole hour from the month `since` is in (the system's set-up without it) to now, oldest first: solar and
    /// home use, in watt-hours. The hour under way is left out. `month` hears each month as it arrives, with how many
    /// are done of how many, so the history fills in while the import runs.
    @discardableResult
    func hours(serial: String, since: Date?, now: Date = Date(),
               month report: @Sendable ([EnergyHourImport], _ done: Int, _ total: Int) async -> Void = { _, _, _ in }) async throws -> [EnergyHourImport] {
        let token = try await signIn()
        let space = try await space(serial: serial, token: token)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = space.timeZone
        let first = since ?? space.created ?? calendar.date(byAdding: .year, value: -1, to: now)!
        guard var month = calendar.date(from: calendar.dateComponents([.year, .month], from: min(first, now))) else { return [] }
        var months: [Date] = []
        while month <= now {
            months.append(month)
            month = calendar.date(byAdding: .month, value: 1, to: month)!
        }
        let format = Self.formatter(space.timeZone)
        let firstDay = since.map { calendar.startOfDay(for: $0) } ?? .distantPast
        var all: [EnergyHourImport] = []
        await report([], 0, months.count)
        for (index, start) in months.enumerated() {
            let end = min(calendar.date(byAdding: .month, value: 1, to: start)!.addingTimeInterval(-1), now)
            var hours: [Date: EnergyFlows] = [:]
            for (code, field) in [(Self.solarCode, \EnergyFlows.solar), (Self.homeCode, \EnergyFlows.home)] {
                for (hour, wattHours) in try await chart(code, space: space, from: format.string(from: start), to: format.string(from: end), token: token, format: format) {
                    // The hour under way, and hours before the history's start, are left out.
                    guard hour.addingTimeInterval(3600) <= now, hour >= firstDay else { continue }
                    hours[hour, default: EnergyFlows()][keyPath: field] = wattHours
                }
            }
            let batch = hours.keys.sorted().map { EnergyHourImport(start: $0, flows: hours[$0]!) }
            all += batch
            await report(batch, index + 1, months.count)
        }
        return all
    }

    /// "2026-10-26 13:00:00", local to the space.
    static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    private func signIn() async throws -> String {
        let object = try await send("/auth/login", method: "POST", body: EcoFlowAppAPI.signInBody(email: email, password: password),
                                    token: nil, appHeaders: false)
        guard let token = (object["data"] as? [String: Any])?["token"] as? String else { throw Failure.signIn("no token in the answer") }
        return token
    }

    func space(serial: String, token: String) async throws -> Space {
        let info = try await send("/app/space/getSpaceInfoBySn?sn=\(serial)", method: "GET", body: nil, token: token)
        guard let data = info["data"] as? [String: Any], let id = data["spaceId"] as? String else { throw Failure.noSpace }
        let properties = data["properties"] as? [[String: Any]] ?? []
        let zone = properties.first { $0["key"] as? String == "timezone" }?["value"] as? String
        var space = Space(id: id, rootID: data["rootSpaceId"] as? String ?? id, timeZone: zone.flatMap(TimeZone.init(identifier:)) ?? .current)
        // When the system was set up: the history starts there. Not knowing it, a year back is asked.
        if let systems = try? await send("/app/space/system/list?spaceId=\(id)", method: "GET", body: nil, token: token),
           let list = (systems["data"] as? [String: Any])?["systemList"] as? [[String: Any]] {
            let format = Self.formatter(space.timeZone)
            space.created = list.compactMap { ($0["createTime"] as? String).flatMap(format.date(from:)) }.min()
        }
        return space
    }

    /// One chart over a span: each point's hour and watt-hours.
    private func chart(_ code: String, space: Space, from: String, to: String, token: String, format: DateFormatter) async throws -> [(Date, Double)] {
        let body = try JSONSerialization.data(withJSONObject: [
            "code": code, "params": ["spaceId": space.id, "rootSpaceId": space.rootID, "beginTime": from, "endTime": to],
        ])
        let object = try await send("/app/commonQuery/query", method: "POST", body: body, token: token)
        return Self.points(object["data"], format: format)
    }

    /// The points of a chart's answer: `{"indexName": "chart_data", "indexValue": 731.0, "time": "2026-10-26 08:00:00",
    /// "unit": "wh"}`, the time local to the space. Points of another kind, or without a time or a value, are skipped.
    static func points(_ data: Any?, format: DateFormatter) -> [(Date, Double)] {
        (data as? [[String: Any]] ?? []).compactMap { point in
            guard (point["indexName"] as? String ?? "chart_data") == "chart_data", let time = point["time"] as? String,
                  let value = (point["indexValue"] as? NSNumber)?.doubleValue, value.isFinite, let date = format.date(from: time) else { return nil }
            let unit = (point["unit"] as? String)?.lowercased()
            return (date, unit == "kwh" ? value * 1000 : value)
        }
    }

    /// One request; returns the answer's object when its code is 0. A refusal carries the server's message, never the
    /// request's body or the answer's data.
    private func send(_ pathAndQuery: String, method: String, body: Data?, token: String?, appHeaders: Bool = true) async throws -> [String: Any] {
        var headers: [(name: String, value: String)] = [(name: "Accept", value: "application/json")]
        if body != nil { headers.append((name: "Content-Type", value: "application/json")) }
        if let token { headers.append((name: "Authorization", value: "Bearer \(token)")) }
        // The sign-in goes without the app's headers: with them it asks for a country code.
        if appHeaders { headers += Self.appHeaders }
        let request = HomeswiftNetwork.HTTPRequest(method: method, url: URL(string: EcoFlowAppAPI.baseURL.absoluteString + pathAndQuery)!,
                                                   headers: headers, body: body, timeout: .seconds(20))
        let response = try await transport.send(request)
        let path = String(pathAndQuery.prefix { $0 != "?" })
        guard response.isSuccess else { throw Failure.http(path, response.status) }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { throw Failure.refused(path, "not JSON") }
        let code = (object["code"] as? String) ?? (object["code"] as? NSNumber)?.stringValue ?? "0"
        guard code == "0", object["data"] != nil else {
            let message = object["message"] as? String ?? "no data"
            throw path == "/auth/login" ? Failure.signIn(message) : Failure.refused(path, message)
        }
        return object
    }
}
