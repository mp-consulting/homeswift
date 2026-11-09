import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// A webhook's parameters: the query string of any request, whatever its method and path. Names are case-sensitive;
/// a parameter given more than once reads as its values joined by commas, as JavaScript turns the list into text, so
/// it equals nothing the kinds compare with.
struct WebhookQuery: Sendable, Equatable {
    let values: [String: String]

    init(_ values: [String: String]) {
        self.values = values
    }

    /// The query of a request target (`/any/path?accessoryId=x&state=true`): `+` as a space, then percent-decoding.
    init(uri: String) {
        guard let start = uri.firstIndex(of: "?") else {
            self.init([:])
            return
        }
        var lists: [String: [String]] = [:]
        let query = uri[uri.index(after: start)...].prefix { $0 != "#" }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = URLEncoding.decode(String(parts[0]))
            guard !name.isEmpty else { continue }
            lists[name, default: []].append(parts.count == 2 ? URLEncoding.decode(String(parts[1])) : "")
        }
        self.init(lists.mapValues { $0.joined(separator: ",") })
    }

    /// The parameter as given, even empty; nil when absent.
    subscript(name: String) -> String? { values[name] }

    /// The parameter when it is given and not empty.
    func nonEmpty(_ name: String) -> String? { values[name].flatMap { $0.isEmpty ? nil : $0 } }

    /// Whether the parameter is exactly `true` (`TRUE`, `1` and `yes` are not).
    func isTrue(_ name: String) -> Bool { values[name] == "true" }
}

enum WebhookNumber {
    /// A number from a parameter, as the Homebridge plugin converts it: the decimal text, trimmed; nil for text that is
    /// not one (the plugin then leaves the value alone rather than giving HomeKit an invalid number).
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let number = Double(trimmed), number.isFinite else { return nil }
        return number
    }

    /// An integer from a parameter (`parseInt`): the leading digits of the text, its sign included.
    static func integer(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var digits = ""
        for (index, character) in trimmed.enumerated() {
            if character.isASCII, character.isNumber || (index == 0 && (character == "-" || character == "+")) {
                digits.append(character)
            } else {
                break
            }
        }
        return Int(digits)
    }
}

/// What a webhook answers: a JSON object whose keys keep their order (`{"success":true,"state":false}`).
struct WebhookReply: Sendable, Equatable {
    var fields: [(String, JSONValue)]

    static let success = WebhookReply(fields: [("success", true)])

    static func success(_ fields: KeyValuePairs<String, JSONValue>) -> WebhookReply {
        WebhookReply(fields: [("success", true)] + fields.map { ($0.key, $0.value) })
    }

    static func == (lhs: WebhookReply, rhs: WebhookReply) -> Bool {
        lhs.fields.elementsEqual(rhs.fields) { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    var json: String {
        "{" + fields.map { "\(JSONValue.string($0.0).text()):\($0.1.text())" }.joined(separator: ",") + "}"
    }
}

/// One accessory of the block: a kind (a switch, a sensor, a lock...) that answers its webhooks and HomeKit's writes.
protocol WebhookAccessory: AnyObject, Sendable {
    /// The entry's `id`: the webhook's `accessoryId`.
    var id: String { get }
    /// The entry's `name`: the accessory's identity (`HttpWebHooks:<name>`) and its Device Id.
    var name: String { get }
    var accessory: Accessory { get }
    /// Applies a webhook's parameters and answers it.
    func handle(_ query: WebhookQuery) -> WebhookReply
}

extension HTTPWebhooksPlugin {
    /// An entry's accessory, with the Homebridge plugin's Accessory Information: `<model>-<name>` and `<model>-<id>`.
    static func accessory(
        _ model: String, id: String, name: String, category: AccessoryCategory, services: [Service], serialNumber: String? = nil
    ) -> Accessory {
        let prefix = "HttpWebHook\(model)Accessory"
        return Accessory(
            id: accessoryID(name: name), name: name, manufacturer: manufacturer, model: "\(prefix)-\(name)",
            serialNumber: serialNumber ?? "\(prefix)-\(id)", category: category, services: services)
    }
}

/// What every kind uses: the state, the outgoing calls, the log, the plugin's tasks and its delays.
struct KindEnvironment: Sendable {
    var store: StateStore
    var caller: OutgoingCaller
    var logger: Logger
    var tasks: TaskBag
    var timing: Timing

    /// The plugin's delays; tests shorten them.
    struct Timing: Sendable {
        /// A push button's On goes back to off this long after a press.
        var pushButtonRelease: Duration = .seconds(1)
        /// A window covering's Current Position follows its target this long after a write (`auto_set_current_position`).
        var currentPositionDelay: Duration = .seconds(1)
        /// Slider writes (brightness, speed, target temperature and position) wait this long, and only the last of a drag
        /// makes its call.
        var coalescing: Duration = .milliseconds(300)
        /// The timeout of an outgoing call; window coverings take `slowCallTimeout`.
        var callTimeout: Duration = .seconds(10)
        var slowCallTimeout: Duration = .seconds(35)
        /// Multiplies `autoReleaseTime`, for tests.
        var autoReleaseScale: Double = 1
        /// How an auto release waits its time: tests hold it and let it go themselves.
        var releaseWait: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    /// Makes `call`, when there is one: the HomeKit write waits for it and fails with it.
    func send(_ call: OutgoingCall?, name: String, slow: Bool = false) async throws {
        guard let call else { return }
        try await caller.send(call, timeout: slow ? timing.slowCallTimeout : timing.callTimeout, name: name)
    }
}

extension Characteristic {
    /// A number from a webhook as the characteristic takes it, within its bounds as HAP-NodeJS clamps it (an integer
    /// format its integer part); nil for a value its valid values do not list.
    func fitted(_ number: Double) -> Double? {
        var number = number
        if let minimum = type.minValue { number = Swift.max(number, minimum) }
        if let maximum = type.maxValue { number = Swift.min(number, maximum) }
        guard type.format != .float, type.format != .bool else { return number }
        guard let integer = Int(saturating: number), type.validValues?.contains(integer) ?? true else { return nil }
        return Double(integer)
    }

    /// Shows a number, `fitted` to the characteristic; one that does not fit is left out. Returns whether HomeKit was told
    /// of a change.
    @discardableResult
    func show(_ number: Double) -> Bool {
        guard let number = fitted(number) else { return false }
        let value: HAPValue = switch type.format {
        case .bool: .bool(number != 0)
        case .float: .double(number)
        default: .int(Int(number))
        }
        let changed = self.value != value
        self.value = value
        return changed
    }

    @discardableResult
    func show(_ flag: Bool) -> Bool {
        let changed = value != .bool(flag)
        value = .bool(flag)
        return changed
    }
}
