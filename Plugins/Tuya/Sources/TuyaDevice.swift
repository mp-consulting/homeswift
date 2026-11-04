import Foundation
import HomeswiftAI
import Logging
import NIOConcurrencyHelpers

/// One DP's specification: its type, mode (`rw`, `ro`, `wo`) and property (`min`, `max`, `scale`, `step`, `unit`; an
/// Enum's `range`; a colour's `h`, `s`, `v`).
struct TuyaSchemaItem: Sendable, Equatable {
    var code: String
    var mode: String
    var type: String
    var property: JSONValue

    var min: Double { property["min"]?.doubleValue ?? 0 }
    var max: Double { property["max"]?.doubleValue ?? 0 }
    var scale: Int { property["scale"]?.intValue ?? 0 }
    var step: Double { property["step"]?.doubleValue ?? 1 }
    var unit: String { property["unit"]?.stringValue ?? "" }
    /// 10 to the scale: Tuya's integers are fixed-point.
    var multiple: Double { pow(10, Double(Swift.max(-6, Swift.min(scale, 9)))) }
    var range: [String] { property["range"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    /// A colour's component (`h`, `s`, `v`), as an Integer specification of its own.
    func component(_ key: String) -> TuyaSchemaItem? {
        guard let value = property[key], value.objectValue != nil else { return nil }
        return TuyaSchemaItem(code: "\(code).\(key)", mode: mode, type: "Integer", property: value)
    }
}

/// A DP's specification from the cloud's `status` and `functions` lists: `status` first wins, `rw` when in both.
enum TuyaSpecification {
    static func merge(_ result: JSONValue?) -> [String: TuyaSchemaItem] {
        let status = result?["status"]?.arrayValue ?? []
        let functions = result?["functions"]?.arrayValue ?? []
        let readable = Set(status.compactMap { $0["code"]?.stringValue })
        let writable = Set(functions.compactMap { $0["code"]?.stringValue })
        var items: [String: TuyaSchemaItem] = [:]
        for entry in status + functions {
            guard let code = entry["code"]?.stringValue, items[code] == nil else { continue }
            // `values` is JSON in a string; a code whose values do not parse is left out (an IR remote's, usually).
            guard let text = entry["values"]?.stringValue, let property = try? JSONValue(string: text) else { continue }
            let mode = readable.contains(code) ? (writable.contains(code) ? "rw" : "ro") : "wo"
            items[code] = TuyaSchemaItem(code: code, mode: mode, type: entry["type"]?.stringValue ?? "", property: property)
        }
        return items
    }
}

/// An IR remote's keys (`/v2.0/infrareds/<hub>/remotes/<remote>/keys`), with a DIY remote's learned codes.
struct TuyaRemoteKeys: Sendable {
    struct Key: Sendable {
        var key: String
        var keyID: Int
        var name: String
        var learnedCode: String?
    }

    var categoryID: Int
    var remoteIndex: Int
    var keys: [Key]
    /// An AC's modes with their temperatures (`key_range`).
    var modes: [Int: [Int]]

    init(_ json: JSONValue) {
        categoryID = json["category_id"]?.intValue ?? 0
        remoteIndex = json["remote_index"]?.intValue ?? 0
        keys = (json["key_list"]?.arrayValue ?? []).compactMap { key in
            guard let name = key["key"]?.stringValue else { return nil }
            return Key(key: name, keyID: key["key_id"]?.intValue ?? 0, name: key["key_name"]?.stringValue ?? name)
        }
        var modes: [Int: [Int]] = [:]
        for range in json["key_range"]?.arrayValue ?? [] {
            guard let mode = range["mode"]?.intValue else { continue }
            modes[mode] = (range["temp_list"]?.arrayValue ?? []).compactMap { $0["temp"]?.intValue }
        }
        self.modes = modes
    }

    init(categoryID: Int, remoteIndex: Int, keys: [Key], modes: [Int: [Int]] = [:]) {
        self.categoryID = categoryID
        self.remoteIndex = remoteIndex
        self.keys = keys
        self.modes = modes
    }
}

/// A Tuya device (or a Smart Home scene): its record, specification and the DP values last known, with the block's
/// override applied to what the accessories read and write.
final class TuyaDevice: Sendable {
    let id: String
    let uuid: String
    let productID: String
    let productName: String
    let ownerID: String
    /// The category after the override's.
    let category: String
    let schema: [String: TuyaSchemaItem]
    let override: TuyaConfiguration.DeviceOverride?
    let parentID: String?
    let remote: TuyaRemoteKeys?
    let isScene: Bool

    private struct State {
        var name: String
        var online: Bool
        var status: [String: JSONValue]
    }

    private let state: NIOLockedValueBox<State>
    /// The override's elements by the code they answer to, and their compiled expressions.
    private let elements: [String: TuyaConfiguration.SchemaOverride]
    private let onGet: [String: TuyaExpression]
    private let onSet: [String: TuyaExpression]
    private let warned = NIOLockedValueBox(Set<String>())
    private let logger: Logger?

    init(
        id: String, uuid: String = "", name: String, online: Bool, productID: String = "", productName: String = "", ownerID: String = "",
        category: String, status: [String: JSONValue], schema: [String: TuyaSchemaItem], override: TuyaConfiguration.DeviceOverride? = nil,
        parentID: String? = nil, remote: TuyaRemoteKeys? = nil, isScene: Bool = false, logger: Logger? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.productID = productID
        self.productName = productName
        self.ownerID = ownerID
        self.category = category
        self.schema = schema
        self.override = override
        self.parentID = parentID
        self.remote = remote
        self.isScene = isScene
        self.logger = logger
        state = NIOLockedValueBox(State(name: name, online: online, status: status))
        var elements: [String: TuyaConfiguration.SchemaOverride] = [:]
        var onGet: [String: TuyaExpression] = [:]
        var onSet: [String: TuyaExpression] = [:]
        for element in override?.schema ?? [] where !element.code.isEmpty {
            elements[element.requestedCode] = element
            for (source, isGet) in [(element.onGet, true), (element.onSet, false)] {
                guard let source else { continue }
                do {
                    let expression = try TuyaExpression(source)
                    if isGet { onGet[element.requestedCode] = expression } else { onSet[element.requestedCode] = expression }
                } catch {
                    logger?.warning("Ignoring the \(isGet ? "onGet" : "onSet") of \(element.code) on \(id), which Homeswift cannot run (\(error)): \(source)")
                }
            }
        }
        self.elements = elements
        self.onGet = onGet
        self.onSet = onSet
    }

    /// A device record from the cloud with its specification.
    convenience init(record: JSONValue, specification: JSONValue?, override: TuyaConfiguration.DeviceOverride?, logger: Logger?) {
        var status: [String: JSONValue] = [:]
        for entry in record["status"]?.arrayValue ?? [] {
            if let code = entry["code"]?.stringValue { status[code] = entry["value"] ?? .null }
        }
        let category = record["category"]?.stringValue ?? ""
        self.init(
            id: record["id"]?.stringValue ?? "", uuid: record["uuid"]?.stringValue ?? "", name: record["name"]?.stringValue ?? "Tuya device",
            online: record["online"]?.boolValue ?? false, productID: record["product_id"]?.stringValue ?? "",
            productName: record["product_name"]?.stringValue ?? "", ownerID: TuyaDevice.text(record["owner_id"]),
            category: override?.category.flatMap { $0.isEmpty ? nil : $0 } ?? category, status: status,
            schema: TuyaSpecification.merge(specification), override: override, logger: logger)
    }

    /// The same device with another category, parent or remote, or with its status replaced (an IR remote's).
    func with(category: String? = nil, parentID: String? = nil, remote: TuyaRemoteKeys? = nil, status: [String: JSONValue]? = nil,
              schema: [String: TuyaSchemaItem]? = nil) -> TuyaDevice {
        let current = state.withLockedValue { $0 }
        return TuyaDevice(
            id: id, uuid: uuid, name: current.name, online: current.online, productID: productID, productName: productName, ownerID: ownerID,
            category: category ?? self.category, status: status ?? current.status, schema: schema ?? self.schema, override: override,
            parentID: parentID ?? self.parentID, remote: remote ?? self.remote, isScene: isScene, logger: logger)
    }

    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)?: text
        case .number(let number)? where number.rounded() == number: String(Int64(number))
        default: ""
        }
    }

    var name: String {
        get { state.withLockedValue { $0.name } }
        set { state.withLockedValue { $0.name = newValue } }
    }

    var online: Bool {
        get { isScene || state.withLockedValue { $0.online } }
        set { state.withLockedValue { $0.online = newValue } }
    }

    var statusCount: Int { state.withLockedValue { $0.status.count } }

    /// The codes of the specification, sorted.
    var specificationCodes: [String] { schema.keys.sorted() }

    /// The device's own value of a DP, without conversion.
    func rawStatus(_ code: String) -> JSONValue? { state.withLockedValue { $0.status[code] } }

    // MARK: Overrides

    private func element(for code: String) -> TuyaConfiguration.SchemaOverride? { elements[code] }

    /// The code the device reports for one the accessories ask for.
    func deviceCode(for code: String) -> String { elements[code]?.code ?? code }

    /// The first of `codes` the device has (§ "Finding a DP"): through the override (renamed, retyped, hidden), else a DP
    /// with a status, or a write-only one.
    func find(_ codes: [String]) -> TuyaSchemaItem? {
        for code in codes {
            if let element = element(for: code) {
                if element.hidden == true { return nil }
                if let original = schema[element.code] {
                    return TuyaSchemaItem(code: code, mode: original.mode, type: element.type ?? original.type, property: element.property ?? original.property)
                }
            }
            if let item = schema[code], item.mode == "wo" || rawStatus(code) != nil { return item }
        }
        return nil
    }

    func find(_ codes: String...) -> TuyaSchemaItem? { find(codes) }

    /// A DP's value as the accessories see it: through the override's `onGet`.
    func status(_ code: String) -> JSONValue? {
        if let element = element(for: code), let raw = rawStatus(element.code) {
            guard let expression = onGet[code] else { return raw }
            do {
                return try expression.evaluate(value: TuyaExpression.Value(raw), device: expressionDevice()).json
            } catch {
                warnOnce("get:\(code)", "The onGet of \(element.code) on \(id) failed (\(error)): the device's value is used")
                return raw
            }
        }
        return rawStatus(code)
    }

    /// Commands as the device takes them: renamed back to its codes and through `onSet`; one whose value is then
    /// undefined is dropped, as are those without a code.
    func deviceCommands(_ commands: [TuyaCommand]) -> [TuyaCommand] {
        commands.compactMap { command in
            guard !command.code.isEmpty else { return nil }
            guard let element = element(for: command.code) else { return command }
            guard let expression = onSet[command.code] else { return TuyaCommand(code: element.code, value: command.value) }
            do {
                guard let value = try expression.evaluate(value: TuyaExpression.Value(command.value), device: expressionDevice()).json else { return nil }
                return TuyaCommand(code: element.code, value: value)
            } catch {
                warnOnce("set:\(command.code)", "The onSet of \(element.code) on \(id) failed (\(error)): the command is not sent")
                return nil
            }
        }
    }

    /// The device record the expressions see as `device`.
    func expressionDevice() -> TuyaExpression.Value {
        let current = state.withLockedValue { $0 }
        let status = current.status.keys.sorted().map { code in
            TuyaExpression.Value.object(["code": .string(code), "value": TuyaExpression.Value(current.status[code])])
        }
        return .object([
            "id": .string(id), "uuid": .string(uuid), "name": .string(current.name), "online": .bool(online), "product_id": .string(productID),
            "product_name": .string(productName), "category": .string(category), "owner_id": .string(ownerID), "status": .array(status),
        ])
    }

    private func warnOnce(_ key: String, _ message: String) {
        guard warned.withLockedValue({ $0.insert(key).inserted }) else { return }
        logger?.warning("\(message)")
    }

    // MARK: Changes

    /// Device-side values written locally, so the next reads and writes see them.
    func store(_ commands: [TuyaCommand]) {
        state.withLockedValue { state in
            for command in commands { state.status[command.code] = command.value }
        }
    }

    /// A push's values for the codes the device has; the others are not added. Answers whether anything changed.
    @discardableResult
    func apply(_ items: [(code: String, value: JSONValue)]) -> Bool {
        state.withLockedValue { state in
            var changed = false
            for item in items where state.status[item.code] != nil && state.status[item.code] != item.value {
                state.status[item.code] = item.value
                changed = true
            }
            return changed
        }
    }

    /// The status replaced as a whole (an IR AC's state).
    func replaceStatus(_ status: [String: JSONValue]) {
        state.withLockedValue { $0.status = status }
    }
}
