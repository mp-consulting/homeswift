import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// UniFi Protect controllers and their cameras, doorbells, chimes, lights, sensors and viewports, as
/// `homebridge-unifi-protect` puts them in HomeKit: motion, smart detection and occupancy sensors, doorbell
/// rings, messages and chimes, lights, the sensors' readings, liveview scenes as a security system, MQTT
/// publishing, an M3U playlist, and the feature options that tune each of them. The configuration is the
/// Homebridge plugin's `UniFi Protect` block. See README.md.
public actor UniFiProtectPlugin: HomeswiftPlugin {
    public static let platform = "UniFi Protect"
    public static let icon: String? = "logo-ubiquiti"
    public static let summary: String? = "Cameras and doorbells with HomeKit Secure Video, sensors and lights"
    public static let name = "UniFi Protect"
    // `configurationSchemaJSON` is in ConfigurationSchema.swift, generated from ../config.schema.json;
    // `webFiles` in WebFiles.swift, generated from ../Web.

    /// How long the settings page waits for a controller's devices.
    static let getDevicesTimeout: Duration = .seconds(20)

    let configuration: Configuration
    let context: PluginContext
    let dependencies: ProtectDependencies
    var logger: Logger { dependencies.logger ?? context.logger }
    private var platformState: ProtectPlatform?
    private(set) var controllers: [ProtectNVR] = []
    private var launches: [Task<Void, Never>] = []
    /// `stop()` ran: a start still awaiting starts nothing more.
    private var isStopped = false

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: ProtectDependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: ProtectDependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
    }

    public func start() async throws {
        // The controllers set up through Setup beside the block's, and the Excluded devices as feature options.
        var configuration = configuration
        configuration.controllers = controllerEntries()
        configuration.options = Self.exclusions(context) + configuration.options + Self.partChoices(context)
        let platform = await ProtectPlatform(configuration: configuration, logger: logger, host: context, storageDirectory: context.storageDirectory,
                                             dependencies: dependencies)
        guard !isStopped else { return }
        platformState = platform
        guard !configuration.controllers.isEmpty else {
            logger.info("No UniFi Protect controllers have been configured.")
            return
        }
        if configuration.debug { platform.log.debug("Debug logging on. Expect a lot of data.") }
        if configuration.verboseFfmpeg { logger.info("Verbose logging of video streaming sessions enabled. Expect a lot of data.") }
        for controller in configuration.controllers {
            guard !controller.address.isEmpty else {
                logger.info("No host or IP address has been configured.")
                continue
            }
            guard !controller.username.isEmpty, !controller.password.isEmpty else {
                logger.info("No UniFi Protect login credentials have been configured.")
                continue
            }
            let nvr = await ProtectNVR(platform: platform, config: controller)
            guard !isStopped else { return }
            controllers.append(nvr)
        }
        let controllers = self.controllers
        launches.append(Task {
            // First things first: a working FFmpeg, when this build streams video.
            if let ffmpeg = platform.ffmpeg, !(await ffmpeg.probe()) {
                platform.log.error("This plugin requires a working version of FFmpeg. If you need to specify a path to your FFmpeg, you can do so with the videoProcessor option.")
                return
            }
            await withTaskGroup(of: Void.self) { group in
                for controller in controllers { group.addTask { await controller.login() } }
            }
        })
    }

    public func stop() async {
        isStopped = true
        launches.forEach { $0.cancel() }
        for controller in controllers { await controller.stop() }
        await platformState?.timers.cancelAll()
        await platformState?.contexts.save()
        logger.debug("Stopped")
    }

    /// The controllers of this instance, for tests and the page.
    var nvrs: [ProtectNVR] { controllers }

    // MARK: The web page

    /// The settings page's requests (ui/server.js of the Homebridge plugin):
    /// - `GET options`: the feature option catalog;
    /// - `POST devices` with a controller's address and credentials: its NVR and devices, or the error;
    /// - `GET discover`: UniFi consoles on the network;
    /// - `POST check-status` with an address: whether the controller answers HTTPS;
    /// - `POST onvif`: a third-party camera's ONVIF profiles and URLs;
    /// - `POST snapshot` with a URL: a camera snapshot for the profile picker, base64;
    /// - `GET controllers`: the running controllers and their devices.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "options"):
            return PluginWebResponse(Self.catalogJSON)
        case ("POST", "devices"):
            return await devices(request.body)
        case ("GET", "discover"):
            let log = ProtectLog(logger: logger)
            let consoles = await dependencies.discover(log)
            return PluginWebResponse(["devices": .array(consoles.map { console in
                ["firmware": .string(console.firmware), "ip": .string(console.ip), "mac": .string(console.mac), "model": .string(console.model),
                 "modelLong": .string(console.modelLong), "name": .string(console.name)]
            })])
        case ("POST", "check-status"):
            let online = await AddressValidation.checkStatus(request.body.string("address"), resolve: dependencies.resolve, transport: dependencies.transport)
            return PluginWebResponse(["online": .bool(online)])
        case ("POST", "onvif"):
            let body = request.body
            do {
                let result = try await ONVIF.discover(host: body.string("host"), port: body.int("port"), servicePath: body.string("servicePath"),
                                                      username: body.string("username"), password: body.string("password") ?? "", transport: dependencies.transport,
                                                      resolve: dependencies.resolve)
                return PluginWebResponse([
                    "ok": true, "profiles": .array(result.profiles.map(\.json)), "warnings": .array(result.warnings.map(JSONValue.string)),
                    "attempts": .array(result.attempts.map { ["port": .number(Double($0.port)), "error": .string($0.error)] }),
                    "port": .number(Double(result.port)), "servicePath": .string(result.servicePath),
                ])
            } catch {
                return PluginWebResponse(["ok": false, "error": .string("\(error)")])
            }
        case ("POST", "snapshot"):
            do {
                let (contentType, data) = try await AddressValidation.fetchSnapshot(request.body.string("url"), expectedHost: request.body.string("host"),
                                                                                     resolve: dependencies.resolve, transport: dependencies.transport)
                return PluginWebResponse(["ok": true, "contentType": .string(contentType), "data": .string(data.base64EncodedString())])
            } catch {
                return PluginWebResponse(["ok": false, "error": .string("\(error)")])
            }
        case ("GET", "controllers"):
            var result: [JSONValue] = []
            for controller in controllers { result.append(await controller.statusJSON()) }
            return PluginWebResponse(["controllers": .array(result)])
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }

    /// Logs in to a controller with what the page sent, reads its bootstrap (`read`), and answers with the NVR and
    /// its adopted devices sorted by name; the error the API logged otherwise.
    private func devices(_ body: JSONValue) async -> PluginWebResponse {
        let address = body.string("address")?.trimmingCharacters(in: .whitespaces) ?? ""
        let verifyTls = body.bool("verifyTls")
        let username = body.string("username") ?? ""
        // The certificate this controller is pinned to, as the running plugin trusts it.
        let pinned = verifyTls ? nil : platformState?.tlsPins.get(address)
        // A configured controller's devices need no password from the page: the block's own is used, but only
        // over a connection that proves it is that controller (the system's roots, or its pin). A first contact
        // trusts whatever certificate answers, so the stored password is not sent to it.
        let configured = controllerEntries().first { $0.address.trimmingCharacters(in: .whitespaces).lowercased() == address.lowercased() }
        var password = body.string("password") ?? ""
        if password.isEmpty, let configured, configured.username == username {
            guard verifyTls || pinned != nil else {
                return PluginWebResponse(["devices": [], "error": "Enter the password: this controller's certificate is not pinned yet."])
            }
            password = configured.password
        }
        let bootstrap: JSONValue
        switch await read(address: address, username: username, password: password, verifyTls: verifyTls, pinned: pinned) {
        case .read(let read): bootstrap = read
        case .failed(let message): return PluginWebResponse(["devices": [], "error": .string(message)])
        }
        var devices: [JSONValue] = [bootstrap.at("nvr") ?? .object([:])]
        for category in ProtectNVR.deviceCategories {
            let adopted = bootstrap.array(category + "s").filter { !$0.bool("isAdoptedByOther") && $0.bool("isAdopted") }
            devices += adopted.sorted {
                ($0.string("name") ?? $0.string("marketName") ?? "").lowercased() < ($1.string("name") ?? $1.string("marketName") ?? "").lowercased()
            }
        }
        return PluginWebResponse(["devices": .array(devices), "error": ""])
    }

    /// A controller's bootstrap, or the error the API logged.
    enum ControllerRead: Sendable {
        case read(JSONValue)
        case failed(String)
    }

    /// Logs in to a controller and reads its bootstrap without events, twenty seconds at most: the page's device list,
    /// and Setup's check of a login and its discovery. `pinned` is the certificate to trust: by default the one the
    /// plugin's pins keep for the address (`verifyTls` off).
    func read(address: String, username: String, password: String, verifyTls: Bool, pinned: String?? = nil) async -> ControllerRead {
        // Without `verifyTls`, the login goes to the vetted address (and the port the page gave), so a second
        // DNS answer cannot steer it to another host; with it, to the name the certificate must carry.
        let connectAddress: String
        do {
            let vetted = try await AddressValidation.resolveAllowed(address, resolve: dependencies.resolve)
            let host = vetted.address.contains(":") ? "[\(vetted.address)]" : vetted.address
            connectAddress = host + (URLComponents(string: "https://" + address)?.port.map { ":\($0)" } ?? "")
        } catch {
            return .failed("\(error)")
        }
        let recorder = ErrorRecorder()
        var errorLogger = Logger(label: logger.label) { _ in recorder }
        errorLogger.logLevel = .error
        let pin = pinned ?? (verifyTls ? nil : ProtectTLSPinStore(url: context.storageDirectory.appendingPathComponent(ProtectSettings.tlsPinFile)).get(address))
        let api = ProtectAPI(log: ProtectLog(logger: errorLogger), options: .init(
            verifyTls: verifyTls, pin: ProtectTLSPin.Options(pinnedFingerprint: pin), transport: dependencies.transport, webSockets: dependencies.webSockets,
            timeScale: dependencies.timeScale, connectsEvents: false))
        let work = Task { () -> Bool in
            guard await api.login(address: verifyTls ? address : connectAddress, username: username, password: password) else { return false }
            return await api.getBootstrap()
        }
        let timeout = Task {
            try? await Task.sleep(for: Self.getDevicesTimeout * dependencies.timeScale)
            work.cancel()
        }
        let ready = await work.value
        timeout.cancel()
        defer { Task { await api.logout() } }
        guard ready, let bootstrap = await api.bootstrap else {
            return .failed(work.isCancelled && !ready
                ? "Timed out after \(Int(Self.getDevicesTimeout.components.seconds))s waiting for \(address) to respond. Check that the address and credentials are correct and that the controller is reachable from this Homeswift host."
                : recorder.last ?? "")
        }
        return .read(bootstrap)
    }

    /// The catalog as the Homebridge plugin's `/getOptions` gave it to its page.
    static let catalogJSON: JSONValue = {
        func list(_ values: [String]?) -> JSONValue? { values.map { .array($0.map(JSONValue.string)) } }
        let categories: [JSONValue] = FeatureOptionCatalog.categories.map { category in
            var object: [String: JSONValue] = ["name": .string(category.name), "description": .string(category.description), "modelKey": list(category.modelKey) ?? []]
            if let value = list(category.hasSensorFeature) { object["hasSensorFeature"] = value }
            if let value = list(category.isNotProperty) { object["isNotProperty"] = value }
            return .object(object)
        }
        var options: [String: JSONValue] = [:]
        for (category, entries) in FeatureOptionCatalog.options {
            options[category] = .array(entries.map { entry in
                var object: [String: JSONValue] = ["name": .string(entry.name), "default": .bool(entry.default), "description": .string(entry.description)]
                switch entry.defaultValue {
                case .number(let value): object["defaultValue"] = .number(value)
                case .text(let value): object["defaultValue"] = .string(value)
                case nil: break
                }
                if let group = entry.group { object["group"] = .string(group) }
                if let size = entry.inputSize { object["inputSize"] = .number(Double(size)) }
                let lists: [(String, [String]?)] = [
                    ("hasAccessFeature", entry.hasAccessFeature), ("hasCameraFeature", entry.hasCameraFeature), ("hasFeature", entry.hasFeature),
                    ("hasLightProperty", entry.hasLightProperty), ("hasProperty", entry.hasProperty), ("hasSensorProperty", entry.hasSensorProperty),
                    ("hasSmartObjectType", entry.hasSmartObjectType), ("isNotProperty", entry.isNotProperty), ("modelKey", entry.modelKey),
                ]
                for (key, value) in lists { if let value = list(value) { object[key] = value } }
                return .object(object)
            })
        }
        return ["categories": .array(categories), "options": .object(options)]
    }()
}

/// Keeps the last error a throwaway API logged, for the settings page.
private final class ErrorRecorder: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .error

    var last: String? {
        lock.lock()
        defer { lock.unlock() }
        return message
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        lock.lock()
        message = "\(event.message)"
        lock.unlock()
    }
}

extension ProtectNVR {
    /// The controller as the page lists it.
    func statusJSON() async -> JSONValue {
        let devices = deviceList.map { device -> JSONValue in
            ["name": .string(device.accessoryName), "accessoryID": .string(device.accessory.id), "modelKey": .string(device.ufp.modelKey), "mac": .string(device.ufp.mac),
             "online": .bool(device.isOnline)]
        }
        return [
            "address": .string(config.address), "name": .string(ufp.string("name") ?? config.name ?? config.address),
            "connected": .bool(await api.bootstrap != nil), "throttled": .bool(await api.isThrottled), "events": .bool(await api.isEventsConnected),
            "tlsFingerprint": (await api.tlsFingerprint).map(JSONValue.string) ?? .null, "devices": .array(devices),
        ]
    }
}
