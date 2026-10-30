import Foundation
import HomeswiftMCP
import HomeswiftMatter
import HomeswiftPlugin
import Logging

/// Starts the Matter bridge when config.json has a `HomeswiftMatter` block.
enum MatterCommands {
    static func start(catalog: HomeswiftCatalog, configuration: HomeswiftConfiguration, logger: Logger) async -> HomeswiftMatterBridge? {
        do {
            guard let block = try configuration.block(for: MatterConfiguration.platform) else { return nil }
            let matter = try MatterConfiguration(block: block)
            let bridge = try await HomeswiftMatterBridge(configuration: matter, host: catalog.host,
                                                         storageDirectory: catalog.host.storageDirectory.appendingPathComponent("matter"), logger: logger)
            try await bridge.start()
            catalog.matter.current = bridge
            return bridge
        } catch {
            logger.error("Matter bridge not started: \(error)")
            return nil
        }
    }

    /// The banner's lines: the pairing codes until a controller commissions the bridge. Standard output, never the log.
    static func bannerLines(_ bridge: HomeswiftMatterBridge) async -> String {
        let port = "Matter:     port \(bridge.configuration.port)"
        guard await !bridge.isCommissioned else { return port + ", commissioned\n" }
        let payload = bridge.setupPayload
        return port + "\n            Pairing code: \(payload.manualCode)   QR code: \(payload.qrCode)\n"
    }
}
