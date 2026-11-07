import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Xiaomi Mi Home Wi-Fi devices that speak MIoT over the miIO LAN protocol, and the older Roborock-family robot vacuums
/// that speak only miIO's vacuum commands (docs/clean-room/XiaomiMiot.md, a clean-room implementation).
///
/// Each device is reached on UDP 54321 at its address with its own token; its MIoT spec is fetched once from
/// miot-spec.org and kept, and its standard services map to HomeKit by their type URNs (MiotAccessory.swift), with extra
/// controls turned on per device (MiotControls.swift). The Xiaomi account is optional: through Setup (XiaomiSetup.swift)
/// it finds the devices and their tokens; it is never used at run time. A homebridge-miot block (`miot`, `devices[]`)
/// loads as it is and moves into `_accessories` by Device Id (the did) with the next settings write (XiaomiSettings.swift).
/// See README.md in this directory.
public actor XiaomiMiotPlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        /// The block as it is: read leniently, as homebridge-miot does.
        public var raw: JSONValue

        public init(from decoder: any Decoder) throws {
            raw = try JSONValue(from: decoder)
        }

        init(raw: JSONValue) { self.raw = raw }

        var micloud: [String: JSONValue] { raw["micloud"]?.objectValue ?? [:] }
        var country: String {
            let value = micloud["country"]?.stringValue?.lowercased() ?? "cn"
            return MiCloud.regions.contains(value) ? value : "cn"
        }
        var devices: [JSONValue] { raw["devices"]?.arrayValue ?? [] }
        /// The plugin-wide polling interval in seconds (`x-default` of a device's).
        var pollingInterval: Double? { DeviceOptions.interval(raw["pollingInterval"]) }
    }

    /// What the plugin reaches devices, the registry and the cloud with; tests swap them.
    struct Dependencies: Sendable {
        var network: any MiioNetwork = UDPMiioNetwork()
        /// miot-spec.org and the Xiaomi cloud: the registry's instance list is about 2 MB.
        var http: any HTTPSending = HTTPClient(maximumBodySize: 32 * 1024 * 1024)
        var timings = DeviceTimings()
        /// How long the hello broadcast gathers replies (3.5).
        var discoveryWindow: Duration = .seconds(2)
        /// How long the account's list is kept (3.5).
        var cloudListAge: TimeInterval = 300
        /// The QR code's long poll (3.2).
        var qrPollTimeout: Duration = .seconds(10)
        var now: @Sendable () -> Date = Date.init
        /// The log, when not the instance's own (tests read it).
        var logger: Logger?
    }

    public static let platform = "miot"
    public static let name = "Xiaomi"
    public static let icon: String? = "plugin"
    public static let summary: String? = "Mi Home Wi-Fi devices and robot vacuums on the local network"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json.

    let configuration: Configuration
    nonisolated let context: PluginContext
    let dependencies: Dependencies
    let tasks = TaskBag()
    var logger: Logger { dependencies.logger ?? context.logger }
    private(set) var hub: MiioHub?
    private(set) var devices: [String: MiotDevice] = [:]
    /// The did each `devices[]` entry without one answered with, by its ip, for `canonicalSettings`.
    private(set) var learnedDIDs: [String: String] = [:]
    /// Addresses the hello broadcast or the cloud list saw a device at, by did, for `canonicalSettings`.
    private(set) var learnedAddresses: [String: String] = [:]
    var cloudList: (devices: [CloudDevice], at: Date)?
    var skippedLogged = Set<String>()
    let registry: SpecRegistry

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        registry = SpecRegistry(http: dependencies.http, file: { model in context.jsonFile("spec/\(model).json", as: SpecRegistry.Stored.self) },
                                logger: dependencies.logger ?? context.logger, now: dependencies.now)
    }

    var cloud: MiCloud { MiCloud(http: dependencies.http, now: dependencies.now) }

    func sharedHub() -> MiioHub {
        if let hub { return hub }
        let made = MiioHub(network: dependencies.network, logger: logger)
        hub = made
        return made
    }

    var mappingDefaults: MappingDefaults {
        var defaults = MappingDefaults()
        if let raw = configuration.raw["pm25Breakpoints"], !raw.isNull {
            if let valid = MiotConversions.validBreakpoints(raw) { defaults.pm25Breakpoints = valid } else { logger.warning("pm25Breakpoints is not four increasing integers; using 7, 15, 30, 55") }
        }
        if let raw = configuration.raw["co2AbnormalThreshold"], !raw.isNull {
            if let value = raw.doubleValue { defaults.co2AbnormalThreshold = value } else { logger.warning("co2AbnormalThreshold is not a number; using 1000") }
        }
        return defaults
    }

    // MARK: Lifecycle

    public func start() async throws {
        _ = sharedHub()
        tasks.add { [weak self] in await self?.startDevices() }
    }

    public func stop() async {
        tasks.cancelAll()
        for device in devices.values { await device.stop() }
        devices.removeAll()
        await hub?.close()
        hub = nil
    }

    /// One device to run: from `_accessories` (Setup's, its token in the vault) or a Homebridge-shaped `devices[]` entry.
    struct ConfiguredDevice: Sendable {
        var did: String?
        var ip: String
        var token: MiioToken
        var options: DeviceOptions
    }

    /// The devices the block and the vault name, Excluded ones left out.
    func configuredDevices() -> [ConfiguredDevice] {
        var found: [String: ConfiguredDevice] = [:]
        var withoutID: [ConfiguredDevice] = []
        var legacyByDID: [String: [String: JSONValue]] = [:]
        for entry in configuration.devices {
            guard let fields = entry.objectValue else { continue }
            let options = DeviceOptions(fields)
            if let did = options.deviceID ?? options.ip.flatMap({ learnedDIDs[$0] }) { legacyByDID[did] = fields }
            guard let ip = options.ip, let token = options.token.flatMap(MiioToken.init(hex:)) else {
                if options.ip != nil { logger.warning("A device in devices has no valid token (32 hexadecimal characters); skipped") }
                continue
            }
            guard let did = options.deviceID ?? learnedDIDs[ip] else {
                withoutID.append(ConfiguredDevice(did: nil, ip: ip, token: token, options: options))
                continue
            }
            if fields["micloud"]?["username"] != nil || fields["micloud"]?["password"] != nil {
                logger.warning("A device's own Xiaomi account (micloud.username in devices) is not supported; the plugin's is used")
            }
            found[did] = ConfiguredDevice(did: did, ip: ip, token: token, options: options)
        }
        for (did, settings) in context.allAccessorySettings where !settings.excluded {
            let options = DeviceOptions(legacy: legacyByDID[did], settings: settings.plugin)
            let token = (context.credentials(for: did)?["token"]?.stringValue).flatMap(MiioToken.init(hex:)) ?? found[did]?.token
            guard let ip = learnedAddresses[did] ?? options.ip ?? found[did]?.ip, let token else { continue }
            var merged = options
            if let name = settings.name { merged.raw["name"] = .string(name) }
            found[did] = ConfiguredDevice(did: did, ip: ip, token: token, options: merged)
        }
        return found.values.filter { !context.isExcluded($0.did ?? "") }.sorted { ($0.did ?? "") < ($1.did ?? "") } + withoutID
    }

    private func startDevices() async {
        let hub = sharedHub()
        var keep = Set<String>()
        for configured in configuredDevices() {
            guard !Task.isCancelled else { return }
            var configured = configured
            if configured.did == nil {
                // homebridge-miot learns the did from the hello reply.
                guard let did = await learnDID(ip: configured.ip, token: configured.token) else {
                    logger.warning("The device at \(configured.ip) did not answer; its did is unknown, so it is not added yet")
                    continue
                }
                learnedDIDs[configured.ip] = did
                configured.did = did
            }
            guard let did = configured.did, !context.isExcluded(did), devices[did] == nil else { continue }
            let device = makeDevice(did: did, configured: configured, hub: hub)
            devices[did] = device
            keep.insert(context.accessoryID(of: did))
            await device.start()
        }
        _ = await context.removeAccessories(keeping: keep)
    }

    func makeDevice(did: String, configured: ConfiguredDevice, hub: MiioHub) -> MiotDevice {
        let known = knownDevices.load()?[did]
        let cached = context.accessory(id: context.accessoryID(of: did))
        let model = configured.options.model ?? cached?.information[.model]?.value.stringValue.flatMap { $0 == "Accessory" ? nil : $0 } ?? known?.model
        let name = context.accessorySettings(for: did).name ?? configured.options.name ?? known?.name ?? "Miot device"
        // The plugin-wide options under the device's own (2.1, 2.4).
        var options = configured.options
        var micloud = configuration.micloud.filter { $0.key != "username" && $0.key != "password" }
        micloud.merge(options.micloud) { $1 }
        if !micloud.isEmpty { options.raw["micloud"] = .object(micloud) }
        if options.raw["pollingInterval"] == nil, let interval = configuration.raw["pollingInterval"] { options.raw["pollingInterval"] = interval }
        var defaults = mappingDefaults
        if let raw = options.raw["pm25Breakpoints"], !raw.isNull {
            if let valid = MiotConversions.validBreakpoints(raw) { defaults.pm25Breakpoints = valid } else { logger.warning("pm25Breakpoints of \(name) is not four increasing integers; using the default") }
        }
        if let raw = options.raw["co2AbnormalThreshold"], !raw.isNull {
            if let value = raw.doubleValue { defaults.co2AbnormalThreshold = value } else { logger.warning("co2AbnormalThreshold of \(name) is not a number; using the default") }
        }
        let environment = DeviceEnvironment(context: context, registry: registry, hub: hub, timings: dependencies.timings, defaults: defaults, logger: logger)
        return MiotDevice(did: did, name: name, model: model, host: configured.ip, token: configured.token, options: options,
                          serialNumber: known?.serialNumber ?? did, firmware: known?.firmware, environment: environment)
    }

    /// Asks the device at `ip` who it is: the did of its hello reply.
    func learnDID(ip: String, token: MiioToken) async -> String? {
        let client = MiioClient(host: ip, token: token, hub: sharedHub(), timings: dependencies.timings.miio, logger: logger)
        await client.attach()
        defer { Task { await client.detach() } }
        _ = try? await client.info()
        return await client.deviceID.map { String($0) }
    }

    // MARK: What is known of the account's devices (not secret)

    /// The MAC (as the Serial Number), firmware, name and model the cloud listed, by did.
    struct KnownDevice: Codable, Sendable, Equatable {
        var name: String?
        var model: String?
        var serialNumber: String?
        var firmware: String?
    }

    var knownDevices: JSONFile<[String: KnownDevice]> { context.jsonFile("known-devices.json", as: [String: KnownDevice].self) }

    func remember(_ list: [CloudDevice]) {
        var known = knownDevices.load() ?? [:]
        var changed = false
        for device in list where !device.isOutOfScope {
            let entry = KnownDevice(name: device.name, model: device.model, serialNumber: device.serialNumber, firmware: device.firmware)
            if known[device.did] != entry { known[device.did] = entry; changed = true }
        }
        if changed { try? knownDevices.save(known) }
    }

    func learned(address: String, for did: String) async {
        guard let device = devices[did], await device.host != address else { return }
        learnedAddresses[did] = address
        await device.move(to: address)
    }

    func device(_ did: String) -> MiotDevice? { devices[did] }
}
