import Foundation
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import HomeswiftUI
import Logging

/// Starts the web UI when config.json has a `HomeswiftUI` block.
enum UICommands {
    static func startServer(catalog: HomeswiftCatalog, configuration: HomeswiftConfiguration, logger: Logger) async -> UIServer? {
        do {
            guard let block = try configuration.block(for: UIConfiguration.platform) else { return nil }
            let ui = try UIConfiguration(block: block)
            var options = UIServer.Options()
            options.logger = logger
            if let root = ProcessInfo.processInfo.environment["HOMESWIFT_WEB_ROOT"], !root.isEmpty {
                options.webRoot = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath)
            }
            let server = UIServer(configuration: ui, catalog: catalog, usersURL: catalog.configURL.deletingLastPathComponent().appendingPathComponent("ui-users.json"), options: options)
            try await server.start()
            if ui.auth == .form, server.users.isEmpty {
                // The set-up code itself goes to the banner (stdout), never to the log the MCP tools can read.
                logger.info("Web UI: no account yet; the set-up code in the bridge's output creates the first one")
            }
            return server
        } catch {
            logger.error("Web UI not started: \(error)")
            return nil
        }
    }
}
