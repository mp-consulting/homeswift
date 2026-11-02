import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// eWeLink (SONOFF and compatible) devices: switches, outlets with power monitoring, lights, curtains,
/// fans, thermostats, sensors, panels, RF Bridge remotes and sensors, Zigbee devices, groups, and the
/// simulations that show a switch as a blind, a garage door, a lock, a valve, a heater and more.
///
/// The cloud API logs in and lists the devices; the WebSocket brings changes as they happen; commands go
/// over the LAN first (mDNS discovery, encrypted HTTP) and through the cloud otherwise. The configuration is
/// the one of `@mp-consulting/homebridge-ewelink`, so a Homebridge block works unchanged. See README.md.
public actor EWeLinkPlugin: HomeswiftPlugin {
    public static let platform = "eWeLink"
    public static let icon: String? = "switch"
    public static let summary: String? = "Sonoff and other eWeLink switches, outlets, lights, curtains and sensors"
    public static let name = "eWeLink"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json;
    // `webFiles` in WebFiles.swift, generated from ../Web.

    /// What the plugin uses to reach the cloud and the LAN; tests swap them for fakes.
    struct Dependencies: Sendable {
        var transport: any HTTPSending = HTTPClient.eWeLinkCloud
        var connectSocket: CloudSocket.Connect = CloudSocket.connectWebSocket
        var lanNetwork: any LANNetwork = SystemLANNetwork()
        var clock = EWeLinkClock()
        var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
        /// How long the settings page's LAN scan listens, in milliseconds.
        var lanScanDuration = 3000.0
    }

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    var logger: Logger { context.logger }
    private var platformTask: Task<Void, Never>?
    /// The session the settings page logged in with: it never leaves the plugin.
    private var pageSession: CloudAPI?
    private let holder = PlatformHolder()

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        // The password Setup keeps in the vault (EWeLinkSetup.swift) in place of the block's.
        self.configuration = Self.withStoredPassword(configuration, context)
        self.context = context
        self.dependencies = dependencies
    }

    public func start() async throws {
        let platform = await makePlatform()
        // Login and discovery retry for as long as it takes: start() returns at once.
        platformTask = Task { await platform.start() }
    }

    @EWeLinkActor
    private func makePlatform() -> EWeLinkPlatform {
        let platform = EWeLinkPlatform(configuration: configuration, context: context, dependencies: dependencies)
        holder.platform = platform
        return platform
    }

    /// The running platform, for tests and the page.
    @EWeLinkActor
    func platformCore() -> EWeLinkPlatform? { holder.platform }

    public func stop() async {
        logger.info("Shutting down eWeLink platform...")
        platformTask?.cancel()
        if let core = await platformCore() { await core.stop() }
    }

    /// Waits until the first login and discovery attempt finished. For tests.
    func settle() async {
        await platformTask?.value
    }

    // MARK: The web page

    /// The Homebridge plugin's settings page: `POST login` checks an account (and keeps the session here, not
    /// in the browser), `GET session` says whether the plugin has a session to reuse, `GET devices` lists the
    /// account's devices and RF sub-devices with what a 3 s mDNS scan found, `POST test-device` sends a
    /// command, `GET accessories` the instance's accessories (Homebridge's `/getCachedAccessories`), `GET status`
    /// the connection.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("POST", "login"):
            let username = request.body["username"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            let password = request.body["password"]?.stringValue ?? ""
            let missing = [("username", username), ("password", password)].filter { $0.1.isEmpty }.map(\.0)
            guard missing.isEmpty else { return .error(400, "Missing required fields: \(missing.joined(separator: ", "))") }
            let api = CloudAPI(
                credentials: .init(username: username, password: password, countryCode: request.body["countryCode"]?.stringValue),
                transport: dependencies.transport, storage: nil, logger: logger)
            do {
                try await api.login()
            } catch {
                return .error(401, "\(error)")
            }
            pageSession = api
            return PluginWebResponse(["success": true, "region": .string(await api.region.rawValue)])
        case ("GET", "session"):
            if pageSession != nil { return PluginWebResponse(["success": true, "region": .string(await pageSession?.region.rawValue ?? "")]) }
            guard let tokens = TokenStorage(context: context).loadValid() else {
                return PluginWebResponse(["success": false, "message": "No valid session found"])
            }
            return PluginWebResponse(["success": true, "region": .string(tokens.region)])
        case ("GET", "devices"):
            guard let api = await sessionAPI() else { return .error(401, "Not logged in to eWeLink: connect your account first") }
            return await listDevices(api)
        case ("POST", "test-device"):
            guard let api = await sessionAPI() else { return .error(401, "Not logged in to eWeLink: connect your account first") }
            guard let deviceID = request.body["deviceId"]?.stringValue, !deviceID.isEmpty else { return .error(400, "Missing required fields: deviceId") }
            let params = request.body["params"]?.objectValue ?? ["switch": "on"]
            let success = await api.setDeviceState(deviceID, params: params)
            return PluginWebResponse(["success": .bool(success), "message": .string(success ? "Command sent successfully" : "Failed to send command")])
        case ("GET", "accessories"):
            return PluginWebResponse(await accessories())
        case ("GET", "status"):
            return PluginWebResponse(await status())
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }

    /// The page's session, else the plugin's own tokens (saved by its last login, less than a day old).
    func sessionAPI() async -> CloudAPI? {
        if let pageSession { return pageSession }
        guard let tokens = TokenStorage(context: context).loadValid() else { return nil }
        let api = CloudAPI(credentials: .init(countryCode: configuration.countryCode), transport: dependencies.transport, storage: nil, logger: logger)
        await api.setCredentials(accessToken: tokens.accessToken, apiKey: tokens.apiKey, refreshToken: tokens.refreshToken, region: tokens.region)
        return api
    }

    /// The instance's accessories, those restored from the cache included, as the Homebridge page's cached
    /// accessory entries: the id, name, category, and the values the handler keeps (`accessory-context.json`).
    @EWeLinkActor
    private func accessories() async -> JSONValue {
        let contexts = holder.platform?.contexts
        return .array(context.accessories.sorted { $0.aid < $1.aid }.map { accessory in
            [
                "id": .string(accessory.id), "aid": .number(Double(accessory.aid)), "displayName": .string(accessory.name),
                "category": .number(Double(accessory.category.rawValue)), "platform": .string(Self.platform),
                "context": .object(contexts?[accessory.id] ?? [:]),
            ]
        })
    }

    @EWeLinkActor
    private func status() async -> JSONValue {
        guard let core = holder.platform else { return ["configured": false] }
        let socketConnected = await core.socket?.isConnected ?? false
        let lanCount = await core.lan?.devices.count ?? 0
        return [
            "configured": .bool(configuration.username?.isEmpty == false && configuration.password?.isEmpty == false),
            "initialized": .bool(core.initialized), "mode": .string(configuration.connectionMode.rawValue),
            "websocket": .bool(socketConnected), "lanDevices": .number(Double(lanCount)), "accessories": .number(Double(core.context.accessories.count)),
            "retrying": .bool(core.hasPendingRetry),
        ]
    }

    /// The account's devices, RF sub-devices under their bridge, with the LAN addresses mDNS found meanwhile.
    private func listDevices(_ api: CloudAPI) async -> PluginWebResponse {
        let network = dependencies.lanNetwork, clock = dependencies.clock, duration = dependencies.lanScanDuration, logger = logger
        let scan = Task { await Self.scanLAN(network: network, clock: clock, duration: duration, logger: logger) }
        let devices: [EWeLinkDevice]
        do {
            devices = try await api.devices().devices
        } catch {
            scan.cancel()
            return .error(500, "\(error)")
        }
        let lan = await scan.value
        var list: [JSONValue] = []
        for device in devices {
            let found = lan[device.deviceid]
            let lanIP: JSONValue = (found?.ip ?? device.ip).map { .string($0) } ?? .null
            let lanPort: JSONValue = (found?.port ?? device.port).map { .number(Double($0)) } ?? .null
            let lanEnabled = device.localtype == 1 || found != nil
            let uiid = device.uiid
            list.append([
                "deviceId": .string(device.deviceid), "name": .string(device.name), "brand": device.brandName.map { .string($0) } ?? .null,
                "model": (device.productModel ?? device.model).map { .string($0) } ?? .null, "uiid": .number(Double(uiid)),
                "online": .bool(device.online), "lanEnabled": .bool(lanEnabled), "lanIp": lanIP, "lanPort": lanPort,
            ])
            guard [28, 98].contains(uiid) else { continue }
            var channel = 0
            for remote in device.rfDevices {
                let subType =
                    DeviceLimits.rfButtonTypes.contains(remote.remoteType) ? "RF Button"
                    : remote.remoteType == DeviceLimits.rfCurtainType ? "RF Curtain"
                    : DeviceLimits.rfSensorTypes.contains(remote.remoteType) ? "RF Sensor" : "RF Device"
                let buttonCount = max(remote.buttons.count, 1)
                list.append([
                    "deviceId": .string("\(device.deviceid)SW\(channel + 1)"), "name": .string(remote.name),
                    "brand": device.brandName.map { .string($0) } ?? .null, "model": .string(subType), "uiid": .string("\(uiid)-sub"),
                    "online": .bool(device.online), "lanEnabled": .bool(lanEnabled), "lanIp": lanIP, "lanPort": lanPort,
                    "isRfSubdevice": true, "parentDeviceId": .string(device.deviceid), "buttons": .array(remote.buttons.map { .string($0.name) }),
                    "buttonCount": .number(Double(buttonCount)),
                ])
                channel += buttonCount
            }
        }
        return PluginWebResponse(["success": true, "devices": .array(list), "total": .number(Double(list.count))])
    }

    @EWeLinkActor
    final class PlatformHolder: Sendable {
        var platform: EWeLinkPlatform?
        nonisolated init() {}
    }

    /// `_ewelink._tcp` services for a moment: device id to address.
    static func scanLAN(network: any LANNetwork, clock: EWeLinkClock, duration: Double, logger: Logger) async -> [String: (ip: String, port: Int)] {
        let events = network.browse(logger: logger)
        let collector = Task { () -> [String: (ip: String, port: Int)] in
            var found: [String: (ip: String, port: Int)] = [:]
            for await event in events {
                guard case .found(let name, let addresses, let port, _) = event, let id = LANControl.deviceID(fromServiceName: name),
                    let ip = addresses.first(where: { !$0.contains(":") })
                else { continue }
                found[id] = (ip, port == 0 ? Timing.lanHTTPPort : port)
                if Task.isCancelled { break }
            }
            return found
        }
        let partial = Task { () -> [String: (ip: String, port: Int)] in
            try? await clock.sleep(milliseconds: duration)
            collector.cancel()
            return await collector.value
        }
        return await partial.value
    }
}
