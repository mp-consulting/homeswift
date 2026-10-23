import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Maytronics Dolphin pool robots through the MyDolphin Plus cloud: a switch that starts and stops cleaning
/// in the configured mode, the water temperature, and the filter bag. State comes from the robot's AWS IoT
/// thing shadow, pushed over MQTT and polled when nothing arrived for a whole interval.
///
/// The configuration is the one of `@mp-consulting/homebridge-dolphin-pool-cleaner`, so a Homebridge block
/// works unchanged. The plugin's page signs in with a verification code and stores a refresh token, as the
/// Homebridge setup wizard does. See README.md in this directory.
public actor DolphinPoolCleanerPlugin: HomeswiftPlugin {
    public static let platform = "DolphinPoolCleaner"
    public static let name = "Dolphin Pool Cleaner"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json;
    // `webFiles` in WebFiles.swift, generated from ../Web.

    static let defaultPollingInterval = 60
    static let minimumPollingInterval = 30

    /// What the plugin uses to reach the cloud; tests swap them for fakes.
    struct Dependencies: Sendable {
        var transport: any HTTPSending = HTTPClient()
        var mqtt: ShadowClient.MQTTFactory = { MQTTClient($0) }
        var timing = DolphinTiming.standard
        /// The cloud for the account; a `MaytronicsCloud` on the transport and MQTT when nil.
        var makeCloud: (@Sendable (AccountSettings, Logger) -> any DolphinCloud)?
        /// Replaces the context's logger, for tests that check what is logged.
        var logger: Logger?
    }

    /// Where the plugin is, for the page.
    enum Status: String, Sendable {
        case notConfigured, signingIn, ready, retrying, failed, stopped
    }

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private var logger: Logger { dependencies.logger ?? context.logger }
    private let temperatures: PersistedDictionary<Double>
    private let images: RobotImages
    private let wizard: SetupWizard

    private var cloud: (any DolphinCloud)?
    private var devices: [String: DolphinDevice] = [:]
    private var bindings: [String: DolphinAccessory] = [:]
    private var robots: [RobotInfo] = []
    private var discoveryTask: Task<Void, Never>?
    private var discoveryAttempts = 0
    private var shuttingDown = false
    private(set) var status = Status.signingIn
    private var lastError: String?

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        let directory = context.storageDirectory
        temperatures = context.persistedDictionary("last-temperatures.json", of: Double.self)
        images = RobotImages(directory: directory)
        wizard = SetupWizard(transport: dependencies.transport, images: images, logger: dependencies.logger ?? context.logger)
    }

    public func start() async throws {
        logger.debug("Initializing platform: \(configuration.name ?? Self.name)")
        // Without an account the plugin stays up, so its page can sign in.
        guard configuration.hasCredentials else {
            logger.error("Missing required configuration: refreshToken or email/password")
            status = .notConfigured
            return
        }
        discoveryTask = Task { await self.discoverDevices() }
    }

    /// Stops polling, a pending retry and the MQTT connection.
    public func stop() async {
        shuttingDown = true
        status = .stopped
        discoveryTask?.cancel()
        discoveryTask = nil
        await stopDevices()
        await cloud?.disconnect()
        try? temperatures.flush()
        logger.debug("Stopped")
    }

    func device(serialNumber: String) -> DolphinDevice? { devices[serialNumber] }
    func binding(serialNumber: String) -> DolphinAccessory? { bindings[serialNumber] }

    /// Waits for the discovery in progress. For tests.
    func settle() async {
        await discoveryTask?.value
    }

    // MARK: Discovery

    func discoverDevices() async {
        guard !shuttingDown else { return }
        logger.info("Discovering Dolphin pool robots...")
        status = .signingIn
        do {
            let robots = try await initializeCloud()
            guard !shuttingDown else { return }
            let interval = configuration.effectivePollingInterval
            for robot in robots {
                await register(robot, pollingInterval: interval)
            }
            await removeStaleAccessories(keeping: robots)
            self.robots = robots
            discoveryAttempts = 0
            status = .ready
            lastError = nil
            logger.info("Discovered \(robots.count) robot(s)")
        } catch {
            guard !shuttingDown else { return }
            logger.error("Failed to discover devices: \(error)")
            lastError = "\(error)"
            scheduleDiscoveryRetry(after: error)
        }
    }

    /// Retries with exponential backoff, so an outage at startup does not leave the accessory dead until the
    /// next restart. Bad credentials do not fix themselves, so those are not retried.
    private func scheduleDiscoveryRetry(after error: any Error) {
        guard !shuttingDown else { return }
        if let error = error as? DolphinError, error.isPermanent {
            logger.error("Not retrying: update the account in the plugin settings; saving them starts the plugin again")
            status = .failed
            return
        }
        let delay = dependencies.timing.discoveryRetryDelay(after: discoveryAttempts)
        discoveryAttempts += 1
        status = .retrying
        logger.info("Retrying discovery in \(Int(delay.timeInterval.rounded()))s")
        discoveryTask = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            await self.discoverDevices()
        }
    }

    /// A fresh sign-in and connection; a retry starts from a clean slate.
    private func initializeCloud() async throws -> [RobotInfo] {
        await stopDevices()
        await cloud?.disconnect()
        let settings = AccountSettings(
            email: configuration.email, password: configuration.password, refreshToken: configuration.refreshToken, iotRegion: configuration.iotRegion)
        let cloud = dependencies.makeCloud?(settings, logger)
            ?? MaytronicsCloud(settings: settings, transport: dependencies.transport, mqtt: dependencies.mqtt, timing: dependencies.timing, logger: logger)
        self.cloud = cloud
        let result = try await cloud.login()
        logger.info("Found robot: \(result.robotName) (S/N: \(result.serialNumber))")
        return await cloud.robots()
    }

    private func register(_ robot: RobotInfo, pollingInterval: Int) async {
        guard let cloud else { return }
        let serialNumber = robot.serialNumber
        let deviceConfiguration = configuration.device(serialNumber: serialNumber)
        let device = DolphinDevice(
            serialNumber: serialNumber, name: deviceConfiguration?.name.nonEmpty ?? robot.name, deviceType: robot.deviceType,
            pollingInterval: .seconds(pollingInterval), cloud: cloud, timing: dependencies.timing, logger: logger)
        devices[serialNumber] = device

        let binding = await DolphinAccessory(
            device: device, accessoryName: robot.name, configuration: deviceConfiguration, idPrefix: Self.platform, temperatures: temperatures,
            timing: dependencies.timing, logger: logger)
        await device.setStateHandler { state in binding.handleStateChange(state) }
        bindings[serialNumber] = binding
        if context.accessory(id: binding.accessory.id) != nil {
            logger.info("Restoring existing accessory: \(robot.name)")
        } else {
            logger.info("Adding new accessory: \(robot.name)")
        }
        do {
            try context.add(binding.accessory)
        } catch {
            logger.warning("Accessory registration warning: \(error)")
        }
        if let imageURL = robot.imageURL, images.dataURL(serialNumber: serialNumber) == nil {
            let images = images, transport = dependencies.transport
            Task { await images.fetch(imageURL, serialNumber: serialNumber, transport: transport) }
        }
        await device.start()
    }

    /// Accessories of robots the account no longer has leave HomeKit.
    private func removeStaleAccessories(keeping robots: [RobotInfo]) async {
        await context.removeAccessories(keeping: Set(robots.map { "\(Self.platform):\($0.serialNumber)" }), message: "Removing stale accessory")
    }

    private func stopDevices() async {
        for device in devices.values {
            await device.setStateHandler(nil)
            await device.stop()
        }
        devices.removeAll()
        bindings.removeAll()
    }

    // MARK: The web page

    /// `POST authenticate` and `POST verify-otp` are the setup page's sign-in (the Homebridge plugin's
    /// `/authenticate` and `/verify-otp`); `GET robots` lists the robots with their state; `GET image?serial=`
    /// is a robot's picture as a data URL, or null. `Web/` is the page.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("POST", "authenticate"):
            return PluginWebResponse(await wizard.authenticate(email: request.body["email"]?.stringValue))
        case ("POST", "verify-otp"):
            return PluginWebResponse(await wizard.verify(email: request.body["email"]?.stringValue, code: request.body["otpCode"]?.stringValue))
        case ("GET", "robots"):
            var list: [JSONValue] = []
            for robot in robots {
                guard let device = devices[robot.serialNumber] else { continue }
                let state = await device.state
                var entry: [String: JSONValue] = [
                    "serialNumber": .string(robot.serialNumber), "name": .string(device.name), "model": .string(robot.model),
                    "modelName": .string(device.modelName), "deviceType": .number(Double(robot.deviceType)),
                    "connected": .bool(state.connected), "isCleaning": .bool(state.isCleaning), "cleaningMode": .string(state.cleaningMode),
                    "filterStatus": .string(state.filterStatus.rawValue), "cycleTimeRemaining": .number(state.cycleTimeRemaining.rounded()),
                    "hasImage": .bool(images.dataURL(serialNumber: robot.serialNumber) != nil),
                ]
                if let mode = state.nextCycleMode { entry["nextCycleMode"] = .string(mode) }
                if let temperature = state.temperature { entry["temperature"] = .number(temperature) }
                if let fault = state.faultDescription { entry["fault"] = .string(fault) }
                if let warranty = robot.warrantyDays { entry["warrantyDays"] = .number(Double(warranty)) }
                list.append(.object(entry))
            }
            var answer: [String: JSONValue] = ["status": .string(status.rawValue), "robots": .array(list)]
            if let lastError { answer["error"] = .string(lastError) }
            return PluginWebResponse(.object(answer))
        case ("GET", "image"):
            // No picture is an answer too: the page draws the robot instead.
            guard let serial = request.query["serial"] else { return .error(400, "a serial number is required") }
            return PluginWebResponse(["dataURL": images.dataURL(serialNumber: serial).map { .string($0) } ?? .null])
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }
}
