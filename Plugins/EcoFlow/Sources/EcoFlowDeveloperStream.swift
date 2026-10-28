import Foundation
import HomeswiftNetwork

/// The developer API's MQTT quota pushes: the same quota keys as the REST quota, sent as the device reports them,
/// so they are the only source the developer route reads once they have arrived. Each device's values are merged
/// across its pushes and kept from then on, whatever the age of the last push: a device that has stopped pushing
/// shows its last values, marked offline, rather than the REST quota. A push is fresh for ten minutes; the devices
/// push irregularly, so a shorter window would mark them offline between pushes.
///
/// The battery's percentage is `f32ShowSoc`, the figure the EcoFlow app shows (rounded to the nearest percent). The REST quota's
/// `cmsBattSoc` drifts from the app's figure, so the battery reads from here when it is available.
actor EcoFlowDeveloperStream {
    typealias MQTTFactory = @Sendable (MQTTConfiguration) async throws -> any MQTTConnection

    /// A device whose last push is older than this is offline; its values are still the last ones pushed.
    static let staleAfter: Duration = .seconds(600)
    /// After a failed connect, no new attempt (a signed certification request and a TLS connect) for this long.
    static let retryDelay: Duration = .seconds(300)

    private let cloud: EcoFlowCloud
    private let makeConnection: MQTTFactory
    private var connection: (any MQTTConnection)?
    private var account = ""
    private var listener: Task<Void, Never>?
    private var subscribed: Set<String> = []
    private var lastFailure: ContinuousClock.Instant?
    /// Each device's latest numeric values, merged across pushes, and when the last push came.
    private var quotas: [String: [String: Double]] = [:]
    private var updated: [String: ContinuousClock.Instant] = [:]
    /// Each quota topic's serial number.
    private var topicSerials: [String: String] = [:]

    init(cloud: EcoFlowCloud, mqtt: @escaping MQTTFactory) {
        self.cloud = cloud
        self.makeConnection = mqtt
    }

    /// Connects on first use, then subscribes to the quota of each serial not yet subscribed to.
    func watch(_ serials: [String]) async throws {
        if connection == nil {
            if let failed = lastFailure, ContinuousClock.now < failed + Self.retryDelay { return }
            lastFailure = ContinuousClock.now
            let login = try await cloud.mqttAccount()
            let configuration = MQTTConfiguration(
                transport: .tls(host: login.host, port: login.port, options: .system),
                clientID: login.account, username: login.account, password: login.password,
                reconnect: .init(delay: .seconds(5), maximumDelay: .seconds(60)))
            let connection = try await makeConnection(configuration)
            try await connection.connect()
            lastFailure = nil
            // Taken now, not inside the task: a push that arrives before the task starts is still delivered.
            let messages = connection.messages
            self.connection = connection
            account = login.account
            listener = Task { [weak self] in
                for await message in messages {
                    await self?.receive(message)
                }
            }
        }
        guard let connection else { return }
        for serial in serials where !subscribed.contains(serial) {
            try await connection.subscribe("/open/\(account)/\(serial)/quota")
            subscribed.insert(serial)
        }
    }

    /// Ends the listener and closes the connection, when the plugin stops.
    func stop() async {
        listener?.cancel()
        listener = nil
        await connection?.disconnect()
        connection = nil
        subscribed = []
    }

    /// The device's latest values from its MQTT pushes, or nil when no push has come yet.
    func quota(for serial: String) -> [String: Double]? {
        quotas[serial]
    }

    /// Whether the device pushed within `staleAfter`.
    func isFresh(_ serial: String) -> Bool {
        guard let at = updated[serial] else { return false }
        return ContinuousClock.now < at + Self.staleAfter
    }

    func receive(_ message: MQTTMessage) {
        // /open/<certificate account>/<serial>/quota, its serial number read once per topic.
        let serial: String
        if let known = topicSerials[message.topic] {
            serial = known
        } else {
            let parts = message.topic.split(separator: "/")
            guard parts.count == 4, parts[0] == "open", parts[3] == "quota" else { return }
            serial = String(parts[2])
            topicSerials[message.topic] = serial
        }
        // Only the keys the plugin reads are kept: a push carries up to a few hundred.
        let wanted = Self.wanted
        let numbers: [String: Double]
        if let flat = Self.numbers(message.payload, wanted: wanted, shapes: Self.wantedShapes) {
            numbers = flat
        } else {
            guard let json = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any] else { return }
            numbers = json.compactMapValues { ($0 as? NSNumber)?.doubleValue }.filter { wanted.contains($0.key) }
        }
        quotas[serial, default: [:]].merge(numbers) { _, new in new }
        updated[serial] = ContinuousClock.now
    }

    /// The keys a STREAM's state is read from (`EcoFlowCloud.liveState`).
    static let wanted = EcoFlowModel.streamDeveloper.all.union(EcoFlowCloud.liveKeys)
    static let wantedShapes = shapes(wanted)

    /// Each name's length and first and last bytes, packed: a name of none of these shapes is not wanted.
    static func shapes(_ names: Set<String>) -> Set<Int> {
        Set(names.map { shape($0.utf8.count, $0.utf8.first ?? 0, $0.utf8.last ?? 0) })
    }

    private static func shape(_ length: Int, _ first: UInt8, _ last: UInt8) -> Int { length << 16 | Int(first) << 8 | Int(last) }

    /// The numbers of a JSON object's members (`{"powGetPvSum": 512.5, …}`, as the pushes are) whose names are
    /// `wanted`, read from the bytes without building the others: text, literals and nested values are skipped. nil
    /// for bytes that are not an object, which the caller reads with JSONSerialization.
    static func numbers(_ payload: Data, wanted: Set<String>, shapes: Set<Int>? = nil) -> [String: Double]? {
        let shapes = shapes ?? Self.shapes(wanted)
        return payload.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [String: Double]? in
            var index = 0
            func skipSpace() {
                while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D || bytes[index] == 0x09 {
                    index += 1
                }
            }
            func expect(_ byte: UInt8) -> Bool {
                skipSpace()
                guard index < bytes.count, bytes[index] == byte else { return false }
                index += 1
                return true
            }
            /// Past a string whose opening quote is read; false at the end of the bytes.
            func skipString() -> Bool {
                while index < bytes.count {
                    let byte = bytes[index]
                    index += byte == UInt8(ascii: "\\") ? 2 : 1
                    if byte == UInt8(ascii: "\"") { return true }
                }
                return false
            }
            /// Past a value that is not a number: a string, an object or an array (nested ones too), a literal.
            func skipValue() -> Bool {
                guard index < bytes.count else { return false }
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    index += 1
                    return skipString()
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    var depth = 0
                    while index < bytes.count {
                        let byte = bytes[index]
                        index += 1
                        if byte == UInt8(ascii: "\"") {
                            guard skipString() else { return false }
                        } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                            depth += 1
                        } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                            depth -= 1
                            if depth == 0 { return true }
                        }
                    }
                    return false
                default:
                    for literal in ["true", "false", "null"] where bytes[index...].starts(with: literal.utf8) {
                        index += literal.utf8.count
                        return true
                    }
                    return false
                }
            }
            guard expect(UInt8(ascii: "{")) else { return nil }
            var numbers: [String: Double] = [:]
            if expect(UInt8(ascii: "}")) { return numbers }
            repeat {
                guard expect(UInt8(ascii: "\"")) else { return nil }
                let nameStart = index
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                    // An escaped name could spell a wanted one: JSONSerialization reads it.
                    guard bytes[index] != UInt8(ascii: "\\") else { return nil }
                    index += 1
                }
                guard index < bytes.count else { return nil }
                // A name is made into text only when its length and its first and last bytes are a wanted name's.
                let length = index - nameStart
                let name = length > 0 && shapes.contains(shape(length, bytes[nameStart], bytes[index - 1]))
                    ? String(decoding: UnsafeRawBufferPointer(rebasing: bytes[nameStart..<index]), as: UTF8.self) : nil
                index += 1
                guard expect(UInt8(ascii: ":")) else { return nil }
                skipSpace()
                let valueStart = index
                while index < bytes.count, let byte = Optional(bytes[index]),
                      (byte >= 0x30 && byte <= 0x39) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
                        || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                    index += 1
                }
                if index == valueStart {
                    guard skipValue() else { return nil }
                } else if let name, wanted.contains(name) {
                    guard let value = Double(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[valueStart..<index]), as: UTF8.self)) else { return nil }
                    numbers[name] = value
                }
            } while expect(UInt8(ascii: ","))
            guard expect(UInt8(ascii: "}")) else { return nil }
            skipSpace()
            return index == bytes.count ? numbers : nil
        }
    }
}
