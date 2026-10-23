import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOCore
import NIOPosix

/// Daikin air conditioners and Altherma heat pumps through the Daikin Onecta cloud: a HeaterCooler per
/// climate control (power, mode, temperatures, fan speed, swing), a Thermostat for an Altherma's hot water
/// tank, and optional switches for Powerful, Econo, Streamer, silent modes, Auto fan, Oscillation, Dry, Fan
/// only, Holiday and firmware updates, with a separate Fan tile on request.
///
/// The configuration is the one of `@mp-consulting/homebridge-daikin-cloud`. Logging in happens on the
/// plugin's page in the web UI: the Developer Portal's OAuth flow (with its HTTPS callback server) or the
/// Onecta app's email and password. See README.md.
public actor DaikinCloudPlugin: HomeswiftPlugin {
    public static let platform = "DaikinCloud"
    public static let name = "Daikin Cloud"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json;
    // `webFiles` in WebFiles.swift, generated from ../Web.

    static let rateLimitFileName = ".daikin-rate-limit.json"
    static let certificateDirectoryName = "daikin-cloud-certs"
    static let climateControlIDs = ["climateControl", "climateControlMainZone", "climateControlSecondaryZone"]
    /// How long a Developer Portal login may take before the callback server stops.
    static let authorizationWindow: Duration = .seconds(600)
    /// How long the settings page reuses a device list before calling the API again.
    static let devicesCacheLifetime: TimeInterval = 300

    /// What the plugin reaches the world with; tests swap them.
    struct Dependencies: Sendable {
        var transport: @Sendable (TransportMode) -> any HTTPSending = DaikinHTTP.makeTransport
        /// Opens the WebSocket; nil polls only.
        var webSocket: DaikinWebSocket.Connect? = DaikinWebSocket.connect
        var addresses: @Sendable () -> [String] = NetworkInfo.ipv4Addresses
        var sessionTiming = DaikinSession.Timing()
        var apiDependencies = DaikinAPI.Dependencies()
        /// Replaces the context's logger; for tests that check messages.
        var logger: Logger?
    }

    let configuration: Configuration
    let settings: DaikinSettings
    let context: PluginContext
    let dependencies: Dependencies
    let http: DaikinHTTP
    var logger: Logger { dependencies.logger ?? context.logger }
    var session: DaikinSession?
    private var startTask: Task<Void, Never>?
    private var stopped = false

    // The settings page's state.
    var pendingAuth: PendingAuth?
    /// Counts logins started or cancelled on the page, so a failed exchange restores only its own login.
    var authAttempt = 0
    var authResult: JSONValue?
    var devicesCache: [AuthMode: (result: [String: JSONValue], fetchedAt: Date)] = [:]
    let callbackServer: CallbackServer

    struct PendingAuth: Sendable {
        var state: String
        var clientID: String
        var clientSecret: String
        var redirectURI: String
        var port: Int
        var createdAt: Date
    }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        settings = DaikinSettings(configuration)
        self.context = context
        self.dependencies = dependencies
        http = DaikinHTTP(transport: dependencies.transport(DaikinHTTP.transport(for: settings.httpTransport)))
        callbackServer = CallbackServer(logger: dependencies.logger ?? context.logger)
    }

    var storage: URL { context.storageDirectory }
    func tokenFile(_ mode: AuthMode) -> URL { storage.appendingPathComponent(mode.tokenFileName) }

    // MARK: Lifecycle

    public func start() async throws {
        logger.info("--- Daikin info for debugging reasons (enable Debug Mode for more logs) ---")
        logger.debug("[Platform] Initializing platform: \(settings.name ?? "")")
        logger.info("[Config] Authentication mode: \(settings.authMode.rawValue)")
        if DaikinHTTP.transport(for: settings.httpTransport) == .curl {
            logger.info("[Config] HTTP transport: curl subprocess (WAF fingerprint workaround). Note: WebSocket connections still use the built-in TLS — disable WebSocket if it cannot connect.")
        }
        let validation = DaikinSettings.validate(configuration.raw)
        for warning in validation.warnings { logger.warning("[Config] \(warning)") }
        if settings.authMode == .mobileApp {
            guard settings.mobileCredentials != nil else {
                logger.warning("[Config] Daikin email and/or password not configured.")
                logger.warning("[Config] Mobile App mode expects the config keys \"daikinEmail\" and \"daikinPassword\".")
                logger.warning("[Config] Please configure the plugin on its page in the Homeswift UI.")
                logger.info("--------------- End Daikin info for debugging reasons --------------------")
                return
            }
        } else if !settings.hasDeveloperCredentials {
            logger.warning("[Config] Client ID and/or Client Secret not configured.")
            logger.warning("[Config] Please configure the plugin on its page in the Homeswift UI.")
            logger.info("--------------- End Daikin info for debugging reasons --------------------")
            return
        }
        // With credentials, the remaining errors (a localhost callback address, a bad port) do not stop the
        // plugin, but must be seen.
        for error in validation.errors { logger.error("[Config] \(error)") }
        logger.debug("[Config] Homeswift config \(DaikinSettings.redacted(configuration.raw, excluded: settings.excludedDeviceIDs).text())")
        let file = tokenFile(settings.authMode)
        if let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date {
            logger.debug("[Config] Token file exists, last modified: \(modified)")
        } else {
            logger.debug("[Config] Token file does NOT exist.")
            if settings.authMode == .developerPortal { logger.debug("[Config] Please authenticate on the plugin's page in the Homeswift UI.") }
        }
        startSession()
    }

    public func stop() async {
        stopped = true
        startTask?.cancel()
        await session?.stop()
        await callbackServer.stop()
        logger.debug("Stopped")
    }

    /// Starts the work in the background: `start()` returns at once. Never after `stop()`.
    private func startSession() {
        guard !stopped else { return }
        let session = DaikinSession(
            settings: settings, context: context, logger: logger, http: http, webSocket: dependencies.webSocket, timing: dependencies.sessionTiming,
            apiDependencies: dependencies.apiDependencies)
        self.session = session
        startTask = Task { await session.run() }
    }

    /// Waits for the start to finish. For tests.
    func settle() async { await startTask?.value }

    /// After a login on the page, an instance that could not start does now, without a restart.
    func resumeIfIdle(_ mode: AuthMode) async {
        guard !stopped, mode == settings.authMode else { return }
        if let session, await session.isRunning { return }
        guard settings.authMode == .mobileApp ? settings.mobileCredentials != nil : settings.hasDeveloperCredentials else { return }
        logger.info("[Auth] Authenticated from the settings page; connecting")
        let previous = session
        await previous?.stop()
        // `stop()`, or another resume, may have run during the await.
        guard !stopped, session === previous else { return }
        startSession()
    }
}

/// The addresses of this machine, to suggest the callback address.
enum NetworkInfo {
    @Sendable static func ipv4Addresses() -> [String] {
        guard let devices = try? System.enumerateDevices() else { return [] }
        var addresses: [String] = []
        for device in devices {
            guard let address = device.address, case .v4 = address, let ip = address.ipAddress, !ip.hasPrefix("127.") else { continue }
            if !addresses.contains(ip) { addresses.append(ip) }
        }
        return addresses
    }

    static var hostName: String { ProcessInfo.processInfo.hostName }

    /// Loopback: 127.0.0.0/8, ::1, IPv4-mapped loopback and `localhost`.
    static func isLoopback(_ host: String) -> Bool {
        let value = host.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "localhost" || value.hasSuffix(".localhost") { return true }
        if isIPv4(value) { return value.hasPrefix("127.") }
        if SelfSignedCertificate.ipAddressBytes(value) != nil { return value == "::1" || value.hasPrefix("::ffff:127.") }
        return false
    }

    /// Dotted-quad, ASCII digits only: `isNumber` also takes "½" or "٣", which `Int` cannot read.
    static func isIPv4(_ string: String) -> Bool {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isWholeNumber } && (Int(part).map { $0 <= 255 } ?? false)
        }
    }

    /// The bind address when it is an IP literal, else the default.
    static func bindAddress(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
        return !trimmed.isEmpty && SelfSignedCertificate.ipAddressBytes(trimmed) != nil ? trimmed : DaikinSettings.defaultCallbackBindAddress
    }
}
