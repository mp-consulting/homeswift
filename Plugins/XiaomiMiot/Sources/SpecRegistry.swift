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

    /// An instances list as it is read: for each model, its highest version of each status (an entry without one under
    /// `""`), the rest of the list (about 48,000 entries) dropped while parsing.
    struct Listing: Decodable, Sendable {
        var best: [String: [String: Instance]] = [:]

        private enum Keys: String, CodingKey { case instances }

        /// One entry, its fields read leniently: decoding it never fails, so the list goes on past one that is not whole.
        private struct Entry: Decodable {
            var instance: Instance?

            private enum Keys: String, CodingKey { case model, version, type, status }

            init(from decoder: any Decoder) {
                guard let fields = try? decoder.container(keyedBy: Keys.self),
                      let model = try? fields.decode(String.self, forKey: .model), let version = try? fields.decode(Int.self, forKey: .version),
                      let type = try? fields.decode(String.self, forKey: .type) else { return }
                instance = Instance(model: model, version: version, type: type, status: try? fields.decode(String.self, forKey: .status))
            }
        }

        init(from decoder: any Decoder) throws {
            guard var list = try? decoder.container(keyedBy: Keys.self).nestedUnkeyedContainer(forKey: .instances) else { return }
            while !list.isAtEnd {
                guard let instance = try list.decode(Entry.self).instance else { continue }
                let status = instance.status ?? ""
                if let kept = best[instance.model]?[status], kept.version >= instance.version { continue }
                best[instance.model, default: [:]][status] = instance
            }
        }

        /// The model's highest version of any status.
        func highest(model: String) -> Instance? {
            best[model]?.values.max { $0.version < $1.version }
        }

        /// The model's highest version of `status`.
        func highest(model: String, status: String) -> Instance? {
            best[model]?[status]
        }
    }

    private let http: any HTTPSending
    private let file: @Sendable (String) -> JSONFile<Stored>
    private let logger: Logger
    private let now: @Sendable () -> Date
    /// The specs read, with the URN each is of: a refresh compares it without reading the stored file again.
    private var memory: [String: (spec: MiotSpec, urn: String)] = [:]
    /// The lists by the status asked (`released`, `all`), kept a day.
    private var lists: [String: (listing: Listing, at: Date)] = [:]
    private var downloads: [String: Task<Listing, any Error>] = [:]
    /// Each model's fetch under way: devices of one model starting together fetch and write it once.
    private var fetching: [String: Task<MiotSpec, any Error>] = [:]
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
        kept(model: model)?.spec
    }

    private func kept(model: String) -> (spec: MiotSpec, urn: String)? {
        if let kept = memory[model] { return kept }
        guard let stored = file(model).load(), let spec = try? MiotSpec(json: stored.instance) else { return nil }
        memory[model] = (spec, stored.urn)
        return (spec, stored.urn)
    }

    /// The model's spec: the kept one, else fetched and kept. `refresh` checks the instances list (at most once a day
    /// per model) for a higher released version and fetches it.
    func spec(model: String, refresh: Bool = false) async throws -> MiotSpec {
        if let spec = cached(model: model) {
            guard refresh else { return spec }
            if let last = checked[model], now().timeIntervalSince(last) < 86_400 { return spec }
        }
        if let running = fetching[model] { return try await running.value }
        let task = Task { try await self.fetch(model: model) }
        fetching[model] = task
        defer { fetching[model] = nil }
        return try await task.value
    }

    private func fetch(model: String) async throws -> MiotSpec {
        do {
            let instance = try await choose(model: model)
            checked[model] = now()
            if let kept = kept(model: model), kept.urn == instance.type { return kept.spec }
            let json = try await fetch(urn: instance.type)
            let spec = try MiotSpec(json: json)
            try? file(model).save(Stored(fetchedAt: now().timeIntervalSince1970 * 1000, urn: instance.type, version: instance.version, instance: json))
            memory[model] = (spec, instance.type)
            logger.info("Spec \(instance.type) fetched for \(model)")
            return spec
        } catch {
            if let spec = cached(model: model) { return spec }
            throw error
        }
    }

    /// The URN to use for a model (6.1): the highest released version; without one, the highest preview, then debug.
    func choose(model: String) async throws -> Instance {
        if let best = try await list("released").highest(model: model) { return best }
        let every = try await list("all")
        for status in ["preview", "debug"] {
            if let best = every.highest(model: model, status: status) {
                logger.info("Using an unreleased spec (\(status)) for \(model)")
                return best
            }
        }
        throw RegistryError.unknownModel(model)
    }

    /// A list, kept a day. One download of a list at a time: devices starting together wait for the same one (the
    /// released list is about 2 MB).
    private func list(_ status: String) async throws -> Listing {
        if let kept = lists[status], now().timeIntervalSince(kept.at) < 86_400 { return kept.listing }
        if let running = downloads[status] { return try await running.value }
        let task = Task { try await self.instances(status: status) }
        downloads[status] = task
        defer { downloads[status] = nil }
        let listing = try await task.value
        lists[status] = (listing, now())
        return listing
    }

    private func instances(status: String) async throws -> Listing {
        try JSONDecoder().decode(Listing.self, from: try await get("\(Self.base)/instances?status=\(status)"))
    }

    private func fetch(urn: String) async throws -> JSONValue {
        try JSONValue(data: try await get("\(Self.base)/instance?type=\(URLEncoding.rfc3986(urn))"))
    }

    private func get(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw RegistryError.unreachable("bad address") }
        let response = try await http.send(HTTPRequest(url: url, timeout: .seconds(30)))
        guard response.isSuccess else { throw RegistryError.unreachable("HTTP \(response.status)") }
        return response.body
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
