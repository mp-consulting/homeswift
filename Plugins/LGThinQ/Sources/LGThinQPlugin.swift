import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// LG ThinQ appliances through LG's cloud, as `homebridge-lg-thinq` does: air conditioners, air purifiers and
/// the AeroTower, refrigerators, washers, dryers and WashTowers, dishwashers, dehumidifiers, ovens, microwaves,
/// range hoods and stylers, on ThinQ v2 (pushed over AWS IoT MQTT) and ThinQ v1 (polled). The configuration is
/// the Homebridge plugin's; the sign-in and the device list are on the plugin's page in the web UI. See README.md.
public actor LGThinQPlugin: HomeswiftPlugin {
    public static let platform = "LGThinQ"
    public static let icon: String? = "logo-lg"
    public static let summary: String? = "Air conditioners, washers, fridges and other appliances through LG's cloud"
    public static let name = "LG ThinQ"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json;
    // `webFiles` in WebFiles.swift, generated from ../Web.

    /// What the plugin reaches LG with; tests swap them for fakes.
    public struct Dependencies: Sendable {
        public var transport: any HTTPSending
        /// The MQTT client for ThinQ2 pushes, made per connection.
        public var mqtt: @Sendable (MQTTConfiguration) async throws -> any MQTTConnection

        public static let mqttClient: @Sendable (MQTTConfiguration) async throws -> any MQTTConnection = { MQTTClient($0) }

        public init(transport: any HTTPSending = URLSessionThinQTransport(),
                    mqtt: @escaping @Sendable (MQTTConfiguration) async throws -> any MQTTConnection = Dependencies.mqttClient) {
            self.transport = transport
            self.mqtt = mqtt
        }
    }

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private var platformInstance: LGThinQPlatform?
    private var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    public init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    public func start() async throws {
        let platform = await LGThinQPlatform(configuration: configuration, context: context, transport: dependencies.transport, mqtt: dependencies.mqtt)
        platformInstance = platform
        await platform.start()
    }

    public func stop() async {
        await platformInstance?.stop()
        logger.debug("Stopped")
    }

    /// The running platform, for tests.
    var platform: LGThinQPlatform? { platformInstance }

    // MARK: The web page

    /// The routes of the Homebridge plugin's settings server: `POST login-by-user-pass` signs in and answers
    /// the refresh token; `POST get-all-devices` lists the account's devices for a refresh token. Both take
    /// the region, since the page signs in before the block has one. `GET login-url` and `POST
    /// login-by-redirect` are the plugin's `thinq auth` command, for accounts that sign in with Google, Apple,
    /// Facebook or Amazon. `GET devices` lists what this instance runs, `GET account-devices` every device of
    /// the account the instance signed in with (for the Assistant, which never holds the refresh token). The
    /// page saves the block itself, and restarts through the UI's own API.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("POST", "login-by-user-pass"):
            if let missing = Self.missing(request.body, ["username", "password", "country", "language"]) { return missing }
            let body = request.body
            do {
                let token = try await Self.login(
                    username: JS.string(body["username"]), password: JS.string(body["password"]), country: JS.string(body["country"]),
                    language: JS.string(body["language"]), transport: dependencies.transport, logger: logger)
                logger.info("Signed in to LG ThinQ from the web page", metadata: ["country": "\(JS.string(body["country"]))"])
                return PluginWebResponse(["success": true, "token": .string(token)])
            } catch {
                logger.warning("Sign-in from the web page failed: \(error)")
                return PluginWebResponse(["success": false, "error": .string(Self.message(error, fallback: "Login failed"))])
            }
        case ("POST", "get-all-devices"):
            if let missing = Self.missing(request.body, ["refresh_token", "country", "language"]) { return missing }
            let body = request.body
            do {
                let devices = try await Self.listDevices(
                    refreshToken: JS.string(body["refresh_token"]), country: JS.string(body["country"]), language: JS.string(body["language"]),
                    transport: dependencies.transport, logger: logger)
                return PluginWebResponse(["success": true, "devices": .array(devices)])
            } catch {
                return PluginWebResponse(["success": false, "error": .string(Self.message(error, fallback: "Failed to get devices"))])
            }
        case ("GET", "login-url"):
            // The `thinq auth` command of the Homebridge plugin, for accounts that sign in with Google, Apple and others.
            let country = request.query["country"] ?? configuration.country ?? "US"
            let language = request.query["language"] ?? configuration.language ?? "en-US"
            do {
                let url = try await Self.thirdPartyLoginURL(country: country, language: language, transport: dependencies.transport, logger: logger)
                return PluginWebResponse(["url": .string(url)])
            } catch {
                return .error(502, Self.message(error, fallback: "Cannot reach LG"))
            }
        case ("POST", "login-by-redirect"):
            if let missing = Self.missing(request.body, ["url", "country", "language"]) { return missing }
            let body = request.body
            do {
                let token = try await Self.loginWithRedirect(
                    JS.string(body["url"]), country: JS.string(body["country"]), language: JS.string(body["language"]), transport: dependencies.transport, logger: logger)
                return PluginWebResponse(["success": true, "token": .string(token)])
            } catch {
                return PluginWebResponse(["success": false, "error": .string(Self.message(error, fallback: "Login failed"))])
            }
        case ("GET", "devices"):
            let devices = await platformInstance?.webDevices() ?? []
            return PluginWebResponse(["devices": .array(devices)])
        case ("GET", "account-devices"):
            guard let platform = platformInstance, await platform.isConfigured else {
                return .error(409, "This instance has no LG sign-in yet: sign in on the LG ThinQ plugin page first.")
            }
            guard let listing = await platform.accountDevices() else { return .error(502, "LG ThinQ did not answer; try again later.") }
            return PluginWebResponse(["devices": .array(listing.devices), "complete": .bool(listing.complete)])
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }

    static func missing(_ body: JSONValue, _ fields: [String]) -> PluginWebResponse? {
        let missing = fields.filter { !JS.truthy(body[$0]) }
        return missing.isEmpty ? nil : .error(400, "Missing required fields: \(missing.joined(separator: ", "))")
    }

    static func message(_ error: any Error, fallback: String) -> String {
        let text = "\(error)"
        return text.isEmpty ? fallback : text
    }

    /// Signs in with an account and answers its refresh token.
    @ThinQActor
    static func login(username: String, password: String, country: String, language: String, transport: any HTTPSending, logger: Logger) async throws -> String {
        let client = RequestClient(transport: transport, logger: logger)
        let api = ThinQAPI(country: country, language: language, client: client, logger: logger)
        let auth = Auth(gateway: try await api.gateway(), client: client, logger: logger)
        return try await auth.login(username: username, password: password).refreshToken
    }

    /// LG's own sign-in page, on the mobile host, with Apple ID enabled and a redirect the user can copy.
    @ThinQActor
    static func thirdPartyLoginURL(country: String, language: String, transport: any HTTPSending, logger: Logger) async throws -> String {
        let client = RequestClient(transport: transport, logger: logger)
        let api = ThinQAPI(country: country, language: language, client: client, logger: logger)
        let auth = Auth(gateway: try await api.gateway(), client: client, logger: logger)
        guard var components = URLComponents(string: auth.loginURL()), let scheme = components.scheme, let host = components.host else {
            throw ThinQError.invalid("LG returned no sign-in page")
        }
        let origin = "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
        components.host = "us.m.lgaccount.com"
        components.port = nil
        var items = components.queryItems ?? []
        for (name, value) in [("division", "ha"), ("redirect_uri", origin + "/login/iabClose"), ("callback_url", origin + "/login/iabClose")] {
            if let index = items.firstIndex(where: { $0.name == name }) { items[index].value = value } else { items.append(URLQueryItem(name: name, value: value)) }
        }
        components.queryItems = items
        return components.url?.absoluteString ?? auth.loginURL()
    }

    /// The refresh token from the URL LG's sign-in page redirected to: in it, or from the third-party token.
    @ThinQActor
    static func loginWithRedirect(_ redirect: String, country: String, language: String, transport: any HTTPSending, logger: Logger) async throws -> String {
        guard let components = URLComponents(string: redirect.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ThinQError.invalid("That is not a URL.") }
        let items = components.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        if let token = item("refresh_token") { return token }
        let thirdParty = ["APPL": "apple", "FBK": "facebook", "GGL": "google", "AMZ": "amazon"]
        guard let username = item("user_id"), let token = item("user_thirdparty_token"), let party = thirdParty[item("user_id_type") ?? ""] else {
            throw ThinQError.invalid("The redirected URL is not valid: try again, or use an LG account.")
        }
        let client = RequestClient(transport: transport, logger: logger)
        let api = ThinQAPI(country: country, language: language, client: client, logger: logger)
        let auth = Auth(gateway: try await api.gateway(), client: client, logger: logger)
        return try await auth.loginStep2(username: username, encryptedPassword: token, extra: [("third_party", party)]).refreshToken
    }

    /// The account's devices, as the settings page lists them.
    @ThinQActor
    static func listDevices(refreshToken: String, country: String, language: String, transport: any HTTPSending, logger: Logger) async throws -> [JSONValue] {
        let api = ThinQAPI(country: country, language: language, client: RequestClient(transport: transport, logger: logger), logger: logger)
        try api.setRefreshToken(refreshToken)
        try await api.ready()
        return await api.listDevices().map { device in
            return [
                "id": device["deviceId"] ?? .null, "name": device["alias"] ?? .null,
                "type": DeviceType.code(device["deviceType"]).flatMap { DeviceType.names[$0] }.map { .string($0) } ?? device["deviceType"] ?? .null,
                "online": .bool(device["online"] != .bool(false)),
            ]
        }
    }
}

extension LGThinQPlatform {
    /// What this instance runs, for the page.
    func webDevices() -> [JSONValue] {
        handlers.values.sorted { $0.device.name < $1.device.name }.map { handler in
            let device = handler.device
            return [
                "id": .string(device.id), "name": .string(device.name), "type": .string(device.type), "model": .string(device.model),
                "platform": .string(device.platform ?? ""), "online": .bool(device.online), "external": .bool(DeviceRegistry.isExternal(device.type)),
                "accessory": .string("\(BaseDevice.platformPrefix):\(device.id)"),
            ]
        }
    }

    /// Every device of the account, with whether this instance runs it; nil when LG answered nothing.
    func accountDevices() async -> (devices: [JSONValue], complete: Bool)? {
        guard !stopped else { return nil }
        if (try? await thinq.isReady()) == nil { return nil }
        let listing = await thinq.deviceListing()
        if listing.devices.isEmpty, !listing.complete { return nil }
        let configured = Set(configuredDevices.compactMap(\.id))
        let devices = listing.devices.sorted { $0.name < $1.name }.map { device -> JSONValue in
            [
                "id": .string(device.id), "name": .string(device.name), "type": .string(device.type), "model": .string(device.model),
                "platform": .string(device.platform ?? ""), "online": .bool(device.online),
                "supported": .bool(DeviceRegistry.handler(for: device.type, platform: device.platform) != nil),
                "configured": .bool(configuredDevices.isEmpty || configured.contains(device.id)), "running": .bool(handlers[device.id] != nil),
            ]
        }
        return (devices, listing.complete)
    }
}
