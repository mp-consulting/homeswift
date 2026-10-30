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
            let directory = catalog.host.storageDirectory.appendingPathComponent("matter")
            let bridge = try await HomeswiftMatterBridge(configuration: matter, source: catalog.host, storage: MatterFileStorage(directory: directory),
                                                         deviceStorage: { MatterFileStorage(device: $0, in: directory) }, logger: logger)
            try await bridge.start()
            bridge.onChange { [slot = catalog.matter] device in slot.changed(device: device) }
            catalog.matter.current = bridge
            return bridge
        } catch {
            logger.error("Matter bridge not started: \(error)")
            return nil
        }
    }

    /// The banner's lines: each node's pairing codes until a controller commissions it. Standard output, never the log.
    static func bannerLines(_ bridge: HomeswiftMatterBridge) async -> String {
        await bridge.pairingLines()
    }

    /// A changed `HomeswiftMatter` block: applied to the running bridge when it keeps the nodes' setup (which
    /// accessories are on Matter, and how), else the bridge restarts. Nil when Matter is off.
    static func reload(catalog: HomeswiftCatalog, configuration: HomeswiftConfiguration, logger: Logger) async -> HomeswiftMatterBridge? {
        if let running = catalog.matter.current as? HomeswiftMatterBridge,
           let block = try? configuration.block(for: MatterConfiguration.platform), let next = try? MatterConfiguration(block: block),
           await running.apply(next) {
            logger.info("Matter: applied the new settings")
            return running
        }
        // The old bridge goes first: the new one wants the same port. Its fabrics stay in storage.
        await catalog.matter.current?.stop()
        catalog.matter.current = nil
        let started = await start(catalog: catalog, configuration: configuration, logger: logger)
        logger.info(started == nil ? "Matter bridge stopped" : "Matter bridge restarted with the new settings")
        return started
    }
}
