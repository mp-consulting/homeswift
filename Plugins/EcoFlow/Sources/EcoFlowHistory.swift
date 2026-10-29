import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// The EcoFlow cloud's energy history for the home a STREAM belongs to, as the app shows it: each hour's solar
/// production and home use (from the system's smart meter when it has one), as the Space dashboard has them, and the
/// system's battery charge and discharge and grid import and export, as its Battery and Grid pages have them, back to
/// when the system was set up. It is the app's own, unofficial API, with the account's email and password: one
/// sign-in, then a request per month and chart.
///
/// The space's answers also carry the home's address and coordinates: only its id and time zone are read, and no
/// answer is logged.
struct EcoFlowHistory: Sendable {
    let email: String
    let password: String
    let transport: any HTTPSending
    /// Changes in the answers' shapes, and a chart the cloud stops answering, for the plugin's log (EcoFlowSchema).
    let schemas = EcoFlowNotices()
    /// The pauses before a chart is asked for again after a failure: the cloud answers a "Server error" now and then,
    /// and one month's failure would otherwise end the whole import.
    var retryDelays: [Duration] = [.seconds(2), .seconds(6)]

    /// The headers the app sends: the space and history services answer a bare 400 without them.
    static let appHeaders: [(name: String, value: String)] = [
        (name: "lang", value: "en_US"), (name: "platform", value: "ios"), (name: "version", value: "6.17.5"),
        (name: "phoneModel", value: "Homeswift"), (name: "sysVersion", value: "1.0"),
    ]
    /// The charts read: an hour's watt-hours over a month at a time. Solar and home use are the space's; the battery
    /// and the grid are the STREAM system's, asked for by a unit's serial number, each point's `extra` saying which way
    /// ("1" charge or import, "2" discharge or export). These codes are the ones the app's dashboard lists for the
    /// system's Battery and Grid pages (`getPageListById`, `getPageChartByPageId`).
    static let solarCode = "SPACE-APP-SOLAR-ENERGY-BAR-DAY"
    static let homeCode = "SPACE-APP-LOAD-ENERGY-BAR-DAY"
    static let batteryCode = "BKW3_SYSTEM-Pro_App-BATTERY-BATTERY-ENERGY-FLOW-chart_battery_bar_dual_charging_discharging_sys-DAY-CHART_DATA"
    static let gridCode = "BKW3_SYSTEM-Pro_App-GRID-GRID-ENERGY-FLOW-chart_grid_bar_dual_es_sys-DAY-CHART_DATA"
    /// Each two-way chart's directions: the `extra` of its points, and the flow each fills.
    nonisolated(unsafe) static let twoWay: [(code: String, name: String, ways: [(extra: String, field: WritableKeyPath<EnergyFlows, Double?>)])] = [
        (batteryCode, "battery", [("1", \.batteryCharge), ("2", \.batteryDischarge)]),
        (gridCode, "grid", [("1", \.gridImport), ("2", \.gridExport)]),
    ]

    enum Failure: Error, CustomStringConvertible {
        case signIn(String), noSpace, noStream, refused(String, String), http(String, Int)

        var description: String {
            switch self {
            case .signIn(let message): "the EcoFlow app's sign-in failed: \(message)"
            case .noSpace: "the STREAM belongs to no home in the EcoFlow app"
            case .noStream: "the EcoFlow account has no STREAM, whose home the history is kept for"
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

    /// Each whole hour from the month `since` is in (the system's set-up without it) to now, oldest first: solar, home
    /// use, and the battery's and the grid's both ways when the cloud has them, in watt-hours. The hour under way is left out. `month` hears each month as it arrives, with how many
    /// are done of how many, so the history fills in while the import runs. Without a serial number, the account's
    /// first STREAM in the app's device list is the one.
    @discardableResult
    func hours(serial: String?, since: Date?, now: Date = Date(),
               month report: @Sendable ([EnergyHourImport], _ done: Int, _ total: Int) async -> Void = { _, _, _ in }) async throws -> [EnergyHourImport] {
        let token = try await signIn()
        let serial = if let serial { serial } else { try await stream(token: token) }
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
        // The history starts the day of `since`, or the day the system was set up: the battery and grid charts fill the
        // days of that first month before it with zeros.
        let firstDay = (since ?? space.created).map { calendar.startOfDay(for: $0) } ?? .distantPast
        var all: [EnergyHourImport] = []
        // The battery and grid charts, until the cloud refuses one: a system without those pages keeps its solar and
        // home history.
        var twoWay = true
        await report([], 0, months.count)
        for (index, start) in months.enumerated() {
            let end = min(calendar.date(byAdding: .month, value: 1, to: start)!.addingTimeInterval(-1), now)
            let (from, to) = (format.string(from: start), format.string(from: end))
            var hours: [Date: EnergyFlows] = [:]
            func add(_ points: [(Date, Double)], to field: WritableKeyPath<EnergyFlows, Double?>) {
                for (hour, wattHours) in points {
                    // The hour under way, and hours before the history's start, are left out.
                    guard hour.addingTimeInterval(3600) <= now, hour >= firstDay else { continue }
                    hours[hour, default: EnergyFlows()][keyPath: field] = wattHours
                }
            }
            for (code, name, field) in [(Self.solarCode, "solar", \EnergyFlows.solar), (Self.homeCode, "home", \EnergyFlows.home)] {
                let data = try await chart(code, space: space, from: from, to: to, token: token)
                await schemas.record(EcoFlowSchema.historyChart(name), problems: EcoFlowSchema.historyChart(name).problems(in: data))
                add(Self.points(data, format: format), to: field)
            }
            for chart2 in Self.twoWay where twoWay {
                let data: Any?
                do {
                    data = try await chart(chart2.code, serial: serial, from: from, to: to, token: token)
                    await schemas.report("refused \(chart2.name)", nil,
                                         recovered: "The EcoFlow cloud answers the \(chart2.name) history chart again")
                } catch {
                    // A chart that stops answering is what a renamed code looks like: said once, until it answers again.
                    await schemas.report("refused \(chart2.name)",
                                         "The EcoFlow cloud did not answer the \(chart2.name) history chart (\(error)): the history goes on without the battery and the grid",
                                         recovered: "")
                    twoWay = false
                    break
                }
                let schema = EcoFlowSchema.historyChart(chart2.name, twoWay: true)
                await schemas.record(schema, problems: schema.problems(in: data))
                for way in chart2.ways { add(Self.points(data, format: format, extra: way.extra), to: way.field) }
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

    /// The account's first STREAM, from the app's device list.
    func stream(token: String) async throws -> String {
        let list = try await send("/app/user/device/list", method: "GET", body: nil, token: token)
        await schemas.record(EcoFlowSchema.historyDevices, problems: EcoFlowSchema.historyDevices.problems(in: list["data"]))
        guard let stream = EcoFlowAppAPI.listedDevices(list["data"]).first(where: { EcoFlowModel.model(serial: $0.serial)?.kind == .stream }) else {
            throw Failure.noStream
        }
        return stream.serial
    }

    func space(serial: String, token: String) async throws -> Space {
        let info = try await send("/app/space/getSpaceInfoBySn?sn=\(serial)", method: "GET", body: nil, token: token)
        await schemas.record(EcoFlowSchema.historySpace, problems: EcoFlowSchema.historySpace.problems(in: info))
        guard let data = info["data"] as? [String: Any], let id = data["spaceId"] as? String else { throw Failure.noSpace }
        let properties = data["properties"] as? [[String: Any]] ?? []
        let zone = properties.first { $0["key"] as? String == "timezone" }?["value"] as? String
        var space = Space(id: id, rootID: data["rootSpaceId"] as? String ?? id, timeZone: zone.flatMap(TimeZone.init(identifier:)) ?? .current)
        // When the system was set up: the history starts there. Not knowing it, a year back is asked.
        if let systems = try? await send("/app/space/system/list?spaceId=\(id)", method: "GET", body: nil, token: token),
           let list = (systems["data"] as? [String: Any])?["systemList"] as? [[String: Any]] {
            await schemas.record(EcoFlowSchema.historySystems, problems: EcoFlowSchema.historySystems.problems(in: list))
            let format = Self.formatter(space.timeZone)
            space.created = list.compactMap { ($0["createTime"] as? String).flatMap(format.date(from:)) }.min()
        }
        return space
    }

    /// One chart over a span: each point's hour and watt-hours.
    private func chart(_ code: String, space: Space, from: String, to: String, token: String) async throws -> Any? {
        try await query([
            "code": code, "params": ["spaceId": space.id, "rootSpaceId": space.rootID, "beginTime": from, "endTime": to],
        ], token: token)
    }

    /// One chart of a device's system over a span, as the app's dashboard asks for it: by the serial number.
    private func chart(_ code: String, serial: String, from: String, to: String, token: String) async throws -> Any? {
        try await query([
            "code": code, "sn": serial, "params": ["sn": serial, "beginTime": from, "endTime": to, "queryType": 0],
        ], token: token)
    }

    /// A chart query's `data`, asked for again after a failure (`retryDelays`).
    private func query(_ request: [String: Any], token: String) async throws -> Any? {
        let body = try JSONSerialization.data(withJSONObject: request)
        var attempt = 0
        while true {
            do {
                let object = try await send("/app/commonQuery/query", method: "POST", body: body, token: token)
                return object["data"]
            } catch {
                guard attempt < retryDelays.count, !Task.isCancelled else { throw error }
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    /// The points of a chart's answer: `{"indexName": "chart_data", "indexValue": 731.0, "time": "2026-10-26 08:00:00",
    /// "unit": "wh"}`, the time local to the space; a two-way chart's of one direction, by their `extra`. The value may
    /// come as text (the battery and grid charts send `"731"`). Points of another kind, or without a time or a value,
    /// are skipped.
    static func points(_ data: Any?, format: DateFormatter, extra: String? = nil) -> [(Date, Double)] {
        (data as? [[String: Any]] ?? []).compactMap { point in
            guard (point["indexName"] as? String ?? "chart_data") == "chart_data", let time = point["time"] as? String,
                  extra == nil || (point["extra"] as? String ?? (point["extra"] as? NSNumber)?.stringValue) == extra,
                  let value = (point["indexValue"] as? NSNumber)?.doubleValue ?? (point["indexValue"] as? String).flatMap(Double.init),
                  value.isFinite, let date = format.date(from: time) else { return nil }
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
