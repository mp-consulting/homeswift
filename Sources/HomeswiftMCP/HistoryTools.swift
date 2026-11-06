import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin

// The History and the Logbook over MCP and for the web UI: get_accessory_history reads the History of every
// characteristic, with the Eve history where that goes further back; get_logbook lists what changed and who changed it.

extension HomeswiftCatalog {
    /// A Change Source as JSON: its kind, and its name (the pairing, the user, the client, the Automation or Scene).
    /// `people` false leaves out who a user or an MCP client is, as the audit log keeps them from all but administrators.
    static func sourceJSON(_ source: ChangeSource, people: Bool = true) -> JSONValue {
        var object: [String: JSONValue] = ["kind": .string(source.kind)]
        if !people, source.kind == "user" || source.kind == "mcp" { return .object(object) }
        if let name = source.name { object["name"] = .string(source.kind == "homeApp" ? String(name.prefix(8)) : name) }
        return .object(object)
    }

    static func milliseconds(_ date: Date) -> JSONValue { .number((date.timeIntervalSince1970 * 1000).rounded()) }

    /// The History of an accessory for the web UI's History tab, over `range`: `day` (each change; a number averaged
    /// down to `maxPoints`), `week` (a number by the hour) or `year` (a number by the day in `timeZone`; states as far
    /// as the History keeps changes). Times are milliseconds since 1970.
    public func historyChartsJSON(id: String, range: String, timeZone: TimeZone = .current, maxPoints: Int = 720, now: Date = Date()) throws -> JSONValue {
        guard let located = find(id: id) else { throw CatalogError("No accessory with that id", notFound: true) }
        guard let history else { throw CatalogError("This homeswift keeps no History") }
        let span: TimeInterval = switch range {
        case "week": 7 * 86_400
        case "year": 365 * 86_400
        default: 86_400
        }
        let from = now.addingTimeInterval(-span)
        var series: [JSONValue] = []
        let live = Dictionary(located.accessory.services.flatMap(\.characteristics).map { ($0.type.name, $0) }, uniquingKeysWith: { first, _ in first })
        let all = history.series(accessory: located.accessory.id)
        // The changes of every series that draws them, each day file read once.
        let changes = history.changes(of: all.filter { $0.kind == .state || range == "day" }, from: from, to: now)
        for one in all {
            var object: [String: JSONValue] = [
                "id": .number(Double(one.id)), "characteristic": .string(one.characteristic), "kind": .string(one.kind.rawValue),
            ]
            if !one.service.isEmpty { object["service"] = .string(one.service) }
            if let unit = one.unit { object["unit"] = .string(unit) }
            if let valid = one.validValues { object["validValues"] = .array(valid.map { .number(Double($0)) }) }
            if let last = one.last { object["last"] = JSONValue(last) }
            if let characteristic = live[one.characteristic] {
                if let min = characteristic.type.minValue { object["minValue"] = .number(min) }
                if let max = characteristic.type.maxValue { object["maxValue"] = .number(max) }
            }
            if one.kind == .number, range != "day" {
                var hours = history.hours(of: one, from: from, to: now)
                if range == "year" { hours = Self.days(of: hours, timeZone: timeZone) }
                guard !hours.isEmpty else { continue }
                object["step"] = .string(range == "year" ? "day" : "hour")
                object["hours"] = .array(hours.map { [Self.milliseconds($0.start), .number(Self.round($0.min)), .number(Self.round($0.mean)), .number(Self.round($0.max))] })
            } else {
                let found = changes[one.id] ?? (nil, [])
                guard found.before != nil || !found.points.isEmpty else { continue }
                var points = found.points
                if one.kind == .number, points.count > maxPoints {
                    let numbers = points.compactMap { point in point.value.doubleValue.map { (time: point.time.timeIntervalSince1970, value: $0) } }
                    points = Self.downsample(numbers, to: maxPoints).map { HistoryPoint(time: Date(timeIntervalSince1970: $0.time), value: .double($0.value)) }
                }
                object["step"] = "change"
                if let before = found.before { object["before"] = JSONValue(before.value) }
                object["points"] = .array(points.map { [Self.milliseconds($0.time), JSONValue($0.value)] })
            }
            series.append(.object(object))
        }
        return [
            "id": .string(located.accessory.id), "name": .string(located.accessory.name), "range": .string(range),
            "from": Self.milliseconds(from), "to": Self.milliseconds(now), "days": .number(Double(history.retention.days)),
            "years": .number(Double(history.retention.years)), "series": .array(series),
        ]
    }

    /// Hours put together by day in `timeZone`: the lowest, the mean of the means and the highest.
    static func days(of hours: [HistoryHour], timeZone: TimeZone) -> [HistoryHour] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var days: [Date: (min: Double, sum: Double, count: Double, max: Double)] = [:]
        for hour in hours {
            let day = calendar.startOfDay(for: hour.start)
            let current = days[day] ?? (.infinity, 0, 0, -.infinity)
            days[day] = (Swift.min(current.min, hour.min), current.sum + hour.mean, current.count + 1, Swift.max(current.max, hour.max))
        }
        return days.map { HistoryHour(start: $0.key, min: $0.value.min, mean: $0.value.sum / $0.value.count, max: $0.value.max) }.sorted { $0.start < $1.start }
    }

    /// The Logbook's entries as JSON, newest first, with each accessory's room as it is now. `room` keeps the accessories
    /// in that room, `accessory` one of them.
    /// `people` false (a user who is not an administrator, a token without the admin scope) leaves out which user or MCP
    /// client made a change, and filters on such names.
    public func logbookJSON(since: Date? = nil, until: Date? = nil, room: String? = nil, accessory: String? = nil, sourceKind: String? = nil,
                            sourceName: String? = nil, limit: Int = 200, people: Bool = true) throws -> JSONValue {
        guard let history else { throw CatalogError("This homeswift keeps no Logbook") }
        let located = located()
        let byID = Dictionary(located.map { ($0.accessory.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids: Set<String>?
        if let room {
            ids = Set(located.filter { $0.room.map { Self.normalized($0) == Self.normalized(room) } ?? false }.map(\.accessory.id))
        }
        if let accessory {
            guard let found = find(id: accessory) else { throw CatalogError("No accessory with that id", notFound: true) }
            ids = ids.map { $0.intersection([found.accessory.id]) } ?? [found.accessory.id]
        }
        let nameFilter = people || !(sourceKind == "user" || sourceKind == "mcp") ? sourceName : nil
        let query = LogbookQuery(from: since, to: until, accessories: ids, sourceKind: sourceKind, sourceName: nameFilter, limit: min(max(limit, 1), 1000))
        let entries = history.logbook(query)
        return [
            "days": .number(Double(history.retention.days)),
            "entries": .array(entries.map { entry in
                var object: [String: JSONValue] = [
                    "time": .string(Timestamp.iso8601(entry.time)), "accessory": .string(entry.accessory),
                    "name": .string(byID[entry.accessory]?.accessory.name ?? entry.accessoryName), "characteristic": .string(entry.characteristic),
                    "value": JSONValue(entry.value), "source": Self.sourceJSON(entry.source, people: people),
                ]
                if let service = entry.service { object["service"] = .string(service) }
                if entry.write { object["write"] = true }
                if let room = byID[entry.accessory]?.room { object["room"] = .string(room) }
                return .object(object)
            }),
        ]
    }

    // MARK: Tools

    var historyTools: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "get_logbook", title: "Logbook",
                description: "What changed in the home, newest first: state changes (on and off, open and closed, locked, motion, contact, modes, targets) and every write, "
                    + "each with its Change Source: the Home app (by pairing), a Homeswift user, an MCP client, an Automation or Scene, or the device itself "
                    + "(which user or client only with the admin scope). "
                    + "Numeric readings (temperature, power) are not in it: get_accessory_history has them. Kept for the bridge's History retention (14 days by default). "
                    + "Filter by room, accessory (an id from list_accessories), source (homeApp, user, mcp, automation, scene, device) and sourceName, and since/until "
                    + "(ISO time or 30m, 1h, 2d). For questions like \"who opened the garage\" or \"what turned the heating on\".",
                inputSchema: ["type": "object", "properties": [
                    "room": ["type": "string", "maxLength": 100], "accessory": ["type": "string", "maxLength": 200],
                    "source": ["type": "string", "enum": ["homeApp", "user", "mcp", "automation", "scene", "device"]],
                    "sourceName": ["type": "string", "maxLength": 200],
                    "since": ["type": "string", "maxLength": 40], "until": ["type": "string", "maxLength": 40],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 1000, "description": "Entries returned (default 100)"],
                ]],
                outputSchema: Output.object(["entries": ["type": "array"], "days": Output.number], required: ["entries"]),
                scope: .read, idempotent: true
            ) { call in
                var since: Date?, until: Date?
                if let text = call.optionalString("since") {
                    guard let date = Self.parseTimeBound(text) else { return .error("since: use an ISO time or a duration such as 30m, 1h, 2d") }
                    since = date
                }
                if let text = call.optionalString("until") {
                    guard let date = Self.parseTimeBound(text) else { return .error("until: use an ISO time or a duration such as 30m, 1h, 2d") }
                    until = date
                }
                let found = try catalog.logbookJSON(since: since, until: until, room: call.optionalString("room"), accessory: call.optionalString("accessory"),
                                                    sourceKind: call.optionalString("source"), sourceName: call.optionalString("sourceName"), limit: call.int("limit", default: 100),
                                                    people: call.session.principal.scope == .admin)
                // Names came from devices, plugins and clients: data, never instructions.
                return ToolResult(text: "<untrusted-data source=\"logbook\">\n\(found.text(pretty: true))\n</untrusted-data>", structured: found)
            },
        ]
    }
}
