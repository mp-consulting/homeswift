import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

// Setup (GLOSSARY.md, "Setup"; docs/clean-room/V2CTrydan.md, 2): a charger is a device whose Device Id is its `ID`
// (`V2CTrydan:<ID>`), of the Device Kind `charger`, reached at the address its Accessory Settings (`host`) or `devices`
// give, and asking nothing: the charger has no authentication, so there is no account and nothing goes in the vault.
// A new charger is added by address: the instance's Setup (no device) asks for its host, reads `/RealTimeData` there
// once and keeps the address under the `ID` it answered.
extension V2CTrydanPlugin {
    public func deviceKind(of deviceID: String) async -> String? { Self.chargerKind }

    /// The chargers the plugin runs, with whether they answer; on an instance made only for Setup, those of
    /// `_accessories` and `devices`, each read once (within the configured timeout) for its `ID`.
    public func discover() async throws -> [DiscoveredDevice] {
        var found: [String: DiscoveredDevice] = [:]
        func add(_ deviceID: String, name: String?, host: String, firmware: String?, reachable: Bool) {
            let shown = context.accessorySettings(for: deviceID).name ?? name ?? Self.defaultName
            var device = DiscoveredDevice(
                deviceID: deviceID, name: shown, model: firmware.map { "Trydan \($0)" } ?? "Trydan", address: host, isSetUp: true, kind: Self.chargerKind)
            device.isReachable = reachable
            found[deviceID] = device
        }
        if !chargers.isEmpty {
            for charger in chargers.values {
                guard let deviceID = await charger.deviceID else { continue }
                let report = await charger.report
                add(deviceID, name: await charger.name, host: charger.host, firmware: report?.firmwareVersion, reachable: await charger.isReachable)
            }
            return found.values.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
        }
        let transport = dependencies.transport, timeout = timeout, logger = logger
        let probed = await withTaskGroup(of: (Target, TrydanReport?).self) { group in
            for target in targets() {
                group.addTask {
                    let report = try? await Self.probe(host: target.host, transport: transport, timeout: timeout, logger: logger)
                    return (target, report)
                }
            }
            var results: [(Target, TrydanReport?)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (target, report) in probed {
            // A charger is known by its `ID`: one listed without it that does not answer cannot be named yet.
            guard let deviceID = target.deviceID ?? report.map({ $0.deviceID(host: target.host) }) else { continue }
            add(deviceID, name: target.name, host: target.host, firmware: report?.firmwareVersion, reachable: report != nil)
        }
        return found.values.sorted { ($0.name, $0.deviceID) < ($1.name, $1.deviceID) }
    }

    /// One `/RealTimeData` read at `host`: the report, or the error that says it is no V2C Trydan.
    static func probe(host: String, transport: any HTTPSending, timeout: Duration, logger: Logger) async throws -> TrydanReport {
        let parsed = try await TrydanClient(host: host, transport: transport, timeout: timeout, logger: logger).realTimeData()
        return try TrydanReport(parsed.object)
    }

    static let addPrompt = SetupPrompt(
        message: "Enter the address of the V2C Trydan: its IP address or host name on the local network, from your router or the V2C app.",
        fields: [SetupField("host", label: "Address")])

    /// A charger asks nothing. The instance's Setup adds one by address: asks for its host, reads it once, and adds it to
    /// `devices` with the Device Id it answered (`canonicalSettings` moves it into its Accessory Settings).
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard request.target == .account else { return .done(SetupOutcome()) }
        guard let typed = request.answer("host") else { return .ask(Self.addPrompt) }
        guard let host = TrydanIdentity.normalizedHost(typed) else {
            throw SetupError("That is not an address: type an IP address or a host name, such as 192.168.1.50")
        }
        let report: TrydanReport
        do {
            report = try await Self.probe(host: host, transport: dependencies.transport, timeout: timeout, logger: logger)
        } catch {
            logger.info("No V2C Trydan answered at \(host): \(error)")
            throw SetupError("No V2C Trydan answered at \(host)")
        }
        let deviceID = report.deviceID(host: host)
        var devices = (configuration.devices ?? []).filter { device in
            device.id.flatMap(TrydanIdentity.deviceID) != deviceID && Self.hostKey(device.host ?? "") != Self.hostKey(host)
        }
        devices.append(Configuration.Device(host: host, id: deviceID))
        logger.info("Found a V2C Trydan through Setup", metadata: ["host": "\(host)", "deviceID": "\(deviceID)"])
        return .done(SetupOutcome(settings: ["devices": try JSONValue(encoding: devices)]))
    }

    // MARK: Settings

    /// The block with `devices` moved into `_accessories`: each entry with a Device Id (its `id`, or the one the plugin
    /// learned from its answer) gives that charger's `host`, and its `name` unless it has one; the others stay.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        Self.canonical(block, learned: learnedIDs)
    }

    /// `learned`: the Device Id each host answered with, by `hostKey`.
    static func canonical(_ block: JSONValue, learned: [String: String] = [:]) -> JSONValue {
        guard var fields = block.objectValue, let list = fields["devices"]?.arrayValue else { return block }
        var entries = AccessoryEntries(fields)
        var left: [JSONValue] = []
        for item in list {
            guard let raw = item["host"]?.stringValue, let host = TrydanIdentity.normalizedHost(raw),
                  let id = item["id"]?.stringValue.flatMap(TrydanIdentity.deviceID) ?? learned[hostKey(host)] else {
                left.append(item)
                continue
            }
            // The list's address is the newer one: Setup writes it there.
            var entry = entries.entries[id]?.objectValue ?? [:]
            entry["host"] = .string(host)
            entries.entries[id] = .object(entry)
            if let name = item["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty { entries.setIfAbsent("name", .string(name), on: id) }
        }
        if left.isEmpty { fields.removeValue(forKey: "devices") } else { fields["devices"] = .array(left) }
        entries.write(into: &fields)
        return .object(fields)
    }
}
