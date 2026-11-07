import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

// The MIoT spec registry (docs/clean-room/XiaomiMiot.md section 6.1): a model's instance spec is fetched from
// miot-spec.org once, kept on the bridge (`spec_<model>.json` in the plugin's folder, `jsonFile("spec/<model>.json")`) and used from then on, also while
// the registry cannot be reached. Nothing is bundled.
actor SpecRegistry {
    static let base = "https://miot-spec.org/miot-spec-v2"

    /// What is kept per model: the instance JSON as served, beside when and from which URN.
    struct Stored: Codable, Sendable {
        var fetchedAt: Double
        var urn: String
        var version: Int?
        var instance: JSONValue
    }

    /// One entry of the instances list.
    struct Instance: Sendable, Equatable {
        var model: String
        var version: Int
        var type: String
        var status: String?
    }

    private let http: any HTTPSending
    private let file: @Sendable (String) -> JSONFile<Stored>
    private let logger: Logger
    private let now: @Sendable () -> Date
    private var memory: [String: MiotSpec] = [:]
    private var released: (list: [Instance], at: Date)?
    private var all: (list: [Instance], at: Date)?
    private var downloads: [String: Task<[Instance], any Error>] = [:]
    /// Models whose list was checked for a newer version today.
    private var checked: [String: Date] = [:]

    init(http: any HTTPSending, file: @escaping @Sendable (String) -> JSONFile<Stored>, logger: Logger, now: @escaping @Sendable () -> Date = Date.init) {
        self.http = http
        self.file = file
        self.logger = logger
        self.now = now
    }

    /// The kept spec of a model, without asking the registry.
    func cached(model: String) -> MiotSpec? {
        if let spec = memory[model] { return spec }
        guard let stored = file(model).load(), let spec = try? MiotSpec(json: stored.instance) else { return nil }
        memory[model] = spec
        return spec
    }

    /// The model's spec: the kept one, else fetched and kept. `refresh` checks the instances list (at most once a day
    /// per model) for a higher released version and fetches it.
    func spec(model: String, refresh: Bool = false) async throws -> MiotSpec {
        if let spec = cached(model: model) {
            guard refresh else { return spec }
            if let last = checked[model], now().timeIntervalSince(last) < 86_400 { return spec }
        }
        let stored = file(model).load()
        do {
            let instance = try await choose(model: model)
            checked[model] = now()
            if let stored, stored.urn == instance.type, let spec = cached(model: model) { return spec }
            let json = try await fetch(urn: instance.type)
            let spec = try MiotSpec(json: json)
            try? file(model).save(Stored(fetchedAt: now().timeIntervalSince1970 * 1000, urn: instance.type, version: instance.version, instance: json))
            memory[model] = spec
            logger.info("Spec \(instance.type) fetched for \(model)")
            return spec
        } catch {
            if let spec = cached(model: model) { return spec }
            throw error
        }
    }

    /// The URN to use for a model (6.1): the highest released version; without one, the highest preview, then debug.
    func choose(model: String) async throws -> Instance {
        if let best = Self.highest(model: model, in: try await releasedList()) { return best }
        let every = try await allList().filter { $0.model == model }
        for status in ["preview", "debug"] {
            if let best = Self.highest(model: model, in: every.filter { $0.status == status }) {
                logger.info("Using an unreleased spec (\(status)) for \(model)")
                return best
            }
        }
        throw RegistryError.unknownModel(model)
    }

    static func highest(model: String, in list: [Instance]) -> Instance? {
        list.filter { $0.model == model }.max { $0.version < $1.version }
    }

    private func releasedList() async throws -> [Instance] {
        if let released, now().timeIntervalSince(released.at) < 86_400 { return released.list }
        let list = try await download("released")
        released = (list, now())
        return list
    }

    private func allList() async throws -> [Instance] {
        if let all, now().timeIntervalSince(all.at) < 86_400 { return all.list }
        let list = try await download("all")
        all = (list, now())
        return list
    }

    /// One download of a list at a time: devices starting together wait for the same one (the released list is about 2 MB).
    private func download(_ status: String) async throws -> [Instance] {
        if let running = downloads[status] { return try await running.value }
        let task = Task { try await self.instances(status: status) }
        downloads[status] = task
        defer { downloads[status] = nil }
        return try await task.value
    }

    private func instances(status: String) async throws -> [Instance] {
        let json = try await get("\(Self.base)/instances?status=\(status)")
        return Self.parseInstances(json)
    }

    static func parseInstances(_ json: JSONValue) -> [Instance] {
        (json["instances"]?.arrayValue ?? []).compactMap { entry in
            guard let model = entry["model"]?.stringValue, let version = entry["version"]?.intValue, let type = entry["type"]?.stringValue else { return nil }
            return Instance(model: model, version: version, type: type, status: entry["status"]?.stringValue)
        }
    }

    private func fetch(urn: String) async throws -> JSONValue {
        try await get("\(Self.base)/instance?type=\(URLEncoding.rfc3986(urn))")
    }

    private func get(_ address: String) async throws -> JSONValue {
        guard let url = URL(string: address) else { throw RegistryError.unreachable("bad address") }
        let response = try await http.send(HTTPRequest(url: url, timeout: .seconds(30)))
        guard response.isSuccess else { throw RegistryError.unreachable("HTTP \(response.status)") }
        return try JSONValue(data: response.body)
    }

    enum RegistryError: Error, CustomStringConvertible {
        case unknownModel(String)
        case unreachable(String)

        var description: String {
            switch self {
            case .unknownModel(let model): "miot-spec.org has no spec for \(model)"
            case .unreachable(let reason): "miot-spec.org did not answer: \(reason)"
            }
        }
    }
}
