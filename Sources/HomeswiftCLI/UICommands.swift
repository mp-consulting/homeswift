import Foundation
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import HomeswiftUI
import Logging

/// Starts the web UI when config.json has a `HomeswiftUI` block.
enum UICommands {
    /// The binary a restart execs: on a Homebrew install its `opt` link, which an update moves to the new version (this
    /// one's Cellar may be gone), else this one.
    static var relaunchExecutable: String {
        let running = ReleaseWatcher.runningExecutable
        let installed = HomebrewInstaller(executable: running)?.executable.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        return installed ?? running
    }

    /// One for the process: the web UI restarts with its settings, the checks go on.
    static let releases = ReleaseWatcher()

    /// `mcp` is the bridge's MCP server as it runs now: the UI serves it at `/mcp` for OAuth clients.
    static func startServer(catalog: HomeswiftCatalog, configuration: HomeswiftConfiguration, mcp: @escaping @Sendable () -> MCPHTTPServer?, logger: Logger) async -> UIServer? {
        do {
            guard let block = try configuration.block(for: UIConfiguration.platform) else { return nil }
            let ui = try UIConfiguration(block: block)
            var options = UIServer.Options()
            options.logger = logger
            options.mcp = mcp
            if let root = ProcessInfo.processInfo.environment["HOMESWIFT_WEB_ROOT"], !root.isEmpty {
                options.webRoot = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath)
            }
            options.releases = releases
            if ui.checkForUpdates {
                releases.start()
            } else {
                releases.stop()
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
