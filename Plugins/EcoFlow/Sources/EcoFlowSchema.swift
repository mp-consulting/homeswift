import Foundation

/// The shape an EcoFlow endpoint's answer must have, as the plugin reads it. A field is named by its path ("data.url",
/// counted from the answer's top level); `items` are the fields each item of a list answer must carry.
struct EcoFlowSchema: Sendable {
    enum Kind: Sendable {
        case text, number, identifier, object, array
    }

    struct Field: Sendable {
        let path: String
        let kind: Kind
    }

    let endpoint: String
    let fields: [Field]
    let items: [Field]

    /// The problems in an answer: each field that is missing or not of its kind, by path; an item field once, as
    /// `[*].path`, however many items lack it, so the same change reads the same in every answer (a month of points
    /// or another) and is reported once.
    func problems(in value: Any?) -> [String] {
        var problems = fields.filter { !Self.matches(value, $0) }.map(\.path)
        if !items.isEmpty {
            guard let list = value as? [Any] else { return problems + ["items"] }
            problems += items.filter { field in list.contains { !Self.matches($0, field) } }.map { "[*].\($0.path)" }
        }
        return problems
    }

    private static func matches(_ root: Any?, _ field: Field) -> Bool {
        var current = root
        for key in field.path.split(separator: ".") {
            current = (current as? [String: Any])?[String(key)]
        }
        switch field.kind {
        case .text: return current is String
        case .number: return current is NSNumber
        case .identifier: return current is String || current is NSNumber
        case .object: return current is [String: Any]
        case .array: return current is [Any]
        }
    }
}

/// The answers the plugin reads, each with the shape it must have.
extension EcoFlowSchema {
    static let deviceList = EcoFlowSchema(endpoint: "device/list", fields: [], items: [
        Field(path: "sn", kind: .text), Field(path: "deviceName", kind: .text), Field(path: "online", kind: .number),
    ])
    static let quota = EcoFlowSchema(endpoint: "device/quota/all", fields: [Field(path: "cmsBattSoc", kind: .number)], items: [])
    static let certification = EcoFlowSchema(endpoint: "sign/certification", fields: [
        Field(path: "url", kind: .text), Field(path: "port", kind: .identifier),
        Field(path: "certificateAccount", kind: .text), Field(path: "certificatePassword", kind: .text),
    ], items: [])
    static let appLogin = EcoFlowSchema(endpoint: "app/auth/login", fields: [
        Field(path: "data.token", kind: .text), Field(path: "data.user", kind: .object),
        Field(path: "data.user.userId", kind: .identifier),
    ], items: [])
    static let appDeviceList = EcoFlowSchema(endpoint: "app/user/device/list", fields: [], items: [
        Field(path: "sn", kind: .text), Field(path: "deviceName", kind: .text), Field(path: "productType", kind: .number),
    ])
    static let appCertification = EcoFlowSchema(endpoint: "app/iot-auth/app/certification", fields: [
        Field(path: "data.url", kind: .text), Field(path: "data.certificateAccount", kind: .text),
        Field(path: "data.certificatePassword", kind: .text),
    ], items: [])

    // The energy history's answers (EcoFlowHistory): the space, its systems, and each chart's points.
    static let historySpace = EcoFlowSchema(endpoint: "app/space/getSpaceInfoBySn", fields: [
        Field(path: "data.spaceId", kind: .text), Field(path: "data.rootSpaceId", kind: .text), Field(path: "data.properties", kind: .array),
    ], items: [])
    /// The device list as the history reads it: only the serial numbers.
    static let historyDevices = EcoFlowSchema(endpoint: "app/user/device/list (history)", fields: [], items: [Field(path: "sn", kind: .text)])
    /// Checked on `data.systemList`, each system's set-up time.
    static let historySystems = EcoFlowSchema(endpoint: "app/space/system/list", fields: [], items: [Field(path: "createTime", kind: .text)])
    /// A chart's points: the value as a number or as text; a two-way chart's with their direction (`extra`).
    static func historyChart(_ name: String, twoWay: Bool = false) -> EcoFlowSchema {
        EcoFlowSchema(endpoint: "app/commonQuery/query \(name)", fields: [], items: [
            Field(path: "indexName", kind: .text), Field(path: "indexValue", kind: .identifier), Field(path: "unit", kind: .text),
        ] + (twoWay ? [Field(path: "extra", kind: .identifier)] : []))
    }
}

/// What the plugin logs about its APIs, kept until the plugin reads it: an answer whose shape changed, an API that
/// failed. Each is reported once when it changes, and once more when it is back to normal; a steady state is silent.
actor EcoFlowNotices {
    private var last: [String: String] = [:]
    private var pending: [String] = []

    /// Reports `problem` under `key` when it differs from the last one; nil is the normal state, reported with
    /// `recovered` when it comes back.
    func report(_ key: String, _ problem: String?, recovered: String) {
        guard last[key] != problem else { return }
        if let problem {
            pending.append(problem)
        } else if last[key] != nil {
            pending.append(recovered)
        }
        last[key] = problem
    }

    /// Records an answer's problems, found where the answer was read: only the schema and its problems cross into
    /// the actor, never the answer itself.
    func record(_ schema: EcoFlowSchema, problems: [String]) {
        let endpoint = schema.endpoint
        report(endpoint,
               problems.isEmpty ? nil : "The EcoFlow answer for \(endpoint) changed: missing or not as expected: \(problems.joined(separator: ", "))",
               recovered: "The EcoFlow answer for \(endpoint) matches its schema again")
    }

    func drain() -> [String] {
        let changes = pending
        pending = []
        return changes
    }
}
