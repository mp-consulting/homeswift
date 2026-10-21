import Foundation
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import HomeswiftUI
import Logging

/// Starts the web UI when config.json has a `HomeswiftUI` block.
enum UICommands {
    static func startServer(host: PluginHost, configuration: HomeswiftConfiguration, logs: LogBuffer, configURL: URL, logger: Logger, restart: (@Sendable () -> Void)? = nil) async -> UIServer? {
        guard let block = configuration.platforms.first(where: { $0.platform == UIConfiguration.platform }) else { return nil }
        do {
            let ui = try UIConfiguration(block: try JSONValue(data: block.json))
            let catalog = HomeswiftCatalog(host: host, logs: logs, configURL: configURL, restart: restart, logger: logger)
            var options = UIServer.Options()
            options.logger = logger
            let server = UIServer(configuration: ui, catalog: catalog, usersURL: configURL.deletingLastPathComponent().appendingPathComponent("ui-users.json"), options: options)
            try await server.start()
            if ui.auth == .form, server.users.isEmpty {
                // The set-up code itself goes to the banner (stdout), never to the log the MCP tools can read.
                logger.info("Web UI: no account yet; the set-up code printed at startup creates the first one")
            }
            return server
        } catch {
            logger.error("Web UI not started: \(error)")
            return nil
        }
    }
}
