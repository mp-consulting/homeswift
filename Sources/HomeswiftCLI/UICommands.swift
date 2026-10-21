import Foundation
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import HomeswiftUI
import Logging

/// Starts the web UI when config.json has a `HomeswiftUI` block.
enum UICommands {
    static func startServer(host: PluginHost, configuration: HomeswiftConfiguration, logs: LogBuffer, configURL: URL, logger: Logger) async -> UIServer? {
        guard let block = configuration.platforms.first(where: { $0.platform == UIConfiguration.platform }) else { return nil }
        do {
            let ui = try UIConfiguration(block: try JSONValue(data: block.json))
            let catalog = HomeswiftCatalog(host: host, logs: logs, configURL: configURL, logger: logger)
            var options = UIServer.Options()
            options.logger = logger
            let server = UIServer(configuration: ui, catalog: catalog, usersURL: configURL.deletingLastPathComponent().appendingPathComponent("ui-users.json"), options: options)
            try await server.start()
            if ui.auth == .form, server.users.isEmpty {
                logger.info("Web UI: open it to create the administrator account")
            }
            return server
        } catch {
            logger.error("Web UI not started: \(error)")
            return nil
        }
    }
}
