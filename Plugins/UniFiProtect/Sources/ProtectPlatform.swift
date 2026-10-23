import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// What the plugin uses to reach the world; tests swap them for fakes.
struct ProtectDependencies: Sendable {
    var transport: any ProtectHTTPTransport = NetworkHTTPTransport()
    var webSockets: ProtectWebSocketFactory = { try await WebSocket.connect(to: $0, options: $1) }
    var mqtt: @Sendable (MQTTConfiguration) -> any MQTTConnection = { MQTTClient($0) }
    /// Scales every timer of the plugin (motion durations, retries, refreshes); tests run them faster.
    var timeScale = 1.0
    /// Finds UniFi consoles on the network for the web page.
    var discover: @Sendable (ProtectLog) async -> [UbiquitiDiscovery.Console] = { log in await UbiquitiDiscovery.discover(log: log) }
    /// Resolves names for the web page's address checks.
    var resolve: @Sendable (String) async throws -> [String] = AddressValidation.systemResolve
    /// FFmpeg for camera streaming, snapshots and HomeKit Secure Video, from the block's `videoProcessor` and
    /// `verboseFfmpeg`. nil in a build without it: cameras then come without video.
    var ffmpeg: (@Sendable (_ videoProcessor: String?, _ verbose: Bool, _ logger: Logger) -> any ProtectFfmpegKit)? = {
        HomeswiftFfmpegKit(videoProcessor: $0, verbose: $1, logger: $2)
    }
    /// The clock of snapshot budgets and timeouts; tests stop it.
    var snapshotClock: any ProtectClock = SystemProtectClock()
    /// Whether the M3U playlist may listen (tests leave the port alone).
    var allowPlaylistServer = true
    /// Logs here instead of the instance's logger (tests read the lines).
    var logger: Logger?
}

/// What the controllers of one platform block share (`ProtectPlatform`): the configuration and its feature
/// options, the accessory contexts, the certificate pins and the timers.
@ProtectActor
final class ProtectPlatform {
    let configuration: UniFiProtectPlugin.Configuration
    let featureOptions: FeatureOptions
    let log: ProtectLog
    let host: any ProtectAccessoryHost
    let contexts: ProtectContextStore
    let tlsPins: ProtectTLSPinStore
    let timers: ProtectTimers
    let dependencies: ProtectDependencies
    /// FFmpeg (`codecSupport`, `rtpPorts`), when the build has it.
    let ffmpeg: (any ProtectFfmpegKit)?
    let verboseFfmpeg: Bool

    /// The accessory id of a device or of a synthetic accessory: `UniFi Protect:<seed>`.
    nonisolated static func accessoryID(_ seed: String) -> String { "\(UniFiProtectPlugin.platform):\(seed)" }

    init(configuration: UniFiProtectPlugin.Configuration, logger: Logger, host: any ProtectAccessoryHost, storageDirectory: URL, dependencies: ProtectDependencies) {
        self.configuration = configuration
        featureOptions = FeatureOptions(categories: FeatureOptionCatalog.categories, options: FeatureOptionCatalog.options, configuredOptions: configuration.options,
                                        dottedIdentifiers: configuration.controllers.map(\.address))
        let log = ProtectLog(logger: logger, debugAll: configuration.debug)
        self.log = log
        self.host = host
        contexts = ProtectContextStore(url: storageDirectory.appendingPathComponent("accessory-context.json"), log: log)
        tlsPins = ProtectTLSPinStore(url: storageDirectory.appendingPathComponent(ProtectSettings.tlsPinFile)) { message in
            log.error(message)
        }
        timers = ProtectTimers(timeScale: dependencies.timeScale)
        self.dependencies = dependencies
        ffmpeg = dependencies.ffmpeg?(configuration.videoProcessor, configuration.verboseFfmpeg, logger)
        verboseFfmpeg = configuration.verboseFfmpeg
    }

    /// The Homebridge plugin's `debug()`: only with the block's `debug` option... or `homeswift -D`.
    func debug(_ message: @autoclosure () -> String) { log.debug(message()) }
}
