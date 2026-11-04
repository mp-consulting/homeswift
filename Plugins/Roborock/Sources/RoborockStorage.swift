import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

// What the plugin keeps between launches (section 8.1), under the Homebridge plugin's file names so copied files are
// read. The session and the home data (it holds the local keys) are sealed in the vault (`secretFile`); the client
// id, home id, LAN addresses and scenes are plain owner-only files.

/// The Homebridge plugin's `{"val": …, "ack": true}` files; `val` may be a JSON string.
struct StoredValue<Value: Codable & Sendable>: Codable, Sendable {
    var val: Value
    var ack: Bool?
    var account: String?

    init(_ val: Value, account: String? = nil) {
        self.val = val
        ack = true
        self.account = account
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ack = try container.decodeIfPresent(Bool.self, forKey: .ack)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        // The Homebridge plugin writes some values as JSON text: read the text's JSON, unless the value is text itself.
        if Value.self != String.self, let text = try? container.decode(String.self, forKey: .val),
            let parsed = try? JSONDecoder().decode(Value.self, from: Data(text.utf8))
        {
            val = parsed
        } else {
            val = try container.decode(Value.self, forKey: .val)
        }
    }
}

struct RoborockStorage: Sendable {
    let context: PluginContext

    var clientID: JSONFile<StoredValue<String>> { context.jsonFile("roborock.clientID") }
    var session: SecretFile<RoborockSession> { context.secretFile("roborock.UserData") }
    var homeData: SecretFile<StoredValue<JSONValue>> { context.secretFile("roborock.HomeData") }
    var homeID: JSONFile<StoredValue<Int>> { context.jsonFile("roborock.HomeId") }
    var localDevices: JSONFile<StoredValue<[String: String]>> { context.jsonFile("roborock.LocalDevices") }
    var scenes: JSONFile<StoredValue<JSONValue>> { context.jsonFile("roborock.Scenes") }

    /// The client id, made once and kept forever: a new one looks like a new phone to the account.
    func loadOrCreateClientID() -> String {
        if let stored = clientID.load()?.val, !stored.isEmpty { return stored }
        let id = UUID().uuidString.lowercased()
        try? clientID.save(StoredValue(id))
        return id
    }

    /// A Homebridge `roborock.token.key` copied into the plugin's folder.
    func tokenKey() -> Data? {
        let url = context.storageDirectory.appendingPathComponent("roborock.token.key")
        guard let data = try? Data(contentsOf: url), data.count == 32 else { return nil }
        return data
    }

    /// The cached home data, when it is this account's.
    func cachedHome(email: String, logger: Logger) -> JSONValue? {
        guard let stored = homeData.load() else { return nil }
        if let account = stored.account, account.lowercased() != email.lowercased() {
            logger.warning("The cached device data belongs to another account: ignoring it")
            return nil
        }
        return stored.val
    }

    func cachedScenes(email: String) -> [JSONValue] {
        guard let stored = scenes.load(), stored.account.map({ $0.lowercased() == email.lowercased() }) ?? true else { return [] }
        return stored.val["result"]?.arrayValue ?? stored.val.arrayValue ?? []
    }

    /// The LAN addresses, never replaced by an empty list.
    func saveIPs(_ ips: [String: String]) {
        guard !ips.isEmpty else { return }
        try? localDevices.save(StoredValue(ips))
    }
}

/// The robots' UDP announcements on port 58866 (section 4.6): listened to for a few seconds, each run on a fresh socket,
/// concurrent asks sharing one run.
actor RoborockUDPDiscovery {
    static let port = 58866
    private var running: Task<[String: String], Never>?
    private var warned = false
    let logger: Logger
    let duration: Duration

    init(logger: Logger, duration: Duration) {
        self.logger = logger
        self.duration = duration
    }

    /// The IPs of the devices whose duid is in `known`, the first one heard for each.
    func discover(known: Set<String>) async -> [String: String] {
        if let running { return await running.value.filter { known.contains($0.key) } }
        let duration = duration
        let task = Task { [weak self] () -> [String: String] in
            let socket: UDPSocket
            do {
                socket = try await UDPSocket.bind(port: Self.port, reuseAddress: true)
            } catch {
                await self?.bindFailed(error)
                return [:]
            }
            var found: [String: String] = [:]
            let listener = Task {
                var found: [String: String] = [:]
                for await datagram in socket.datagrams {
                    guard let payload = RoborockCipher.discoveryPayload(datagram.data), let json = try? JSONValue(data: payload),
                        let duid = json["duid"]?.stringValue, let ip = json["ip"]?.stringValue, found[duid] == nil
                    else { continue }
                    found[duid] = ip
                }
                return found
            }
            try? await Task.sleep(for: duration)
            await socket.close()
            found = await listener.value
            return found
        }
        running = task
        let result = await task.value
        running = nil
        return result.filter { known.contains($0.key) }
    }

    private func bindFailed(_ error: any Error) {
        if warned {
            logger.debug("UDP discovery unavailable: \(error)")
        } else {
            warned = true
            logger.warning("UDP discovery unavailable (port \(Self.port) is in use?): using the known addresses")
        }
    }
}
