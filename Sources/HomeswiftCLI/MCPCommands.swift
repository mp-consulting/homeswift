import Foundation
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import Logging

/// `homeswift mcp`: the stdio proxy to the bridge's MCP server, token generation and client snippets.
enum MCPCommands {
    static func mcpBlock(_ configuration: HomeswiftConfiguration) -> JSONValue? {
        try? configuration.block(for: AIConfiguration.platform)
    }

    static func run(arguments: [String], configuration: HomeswiftConfiguration, logger: Logger) async throws {
        let mcp = try mcpBlock(configuration).map(MCPConfiguration.init(block:)) ?? MCPConfiguration()
        var url: String? = ProcessInfo.processInfo.environment["HOMESWIFT_MCP_URL"]
        var token: String? = ProcessInfo.processInfo.environment["HOMESWIFT_MCP_TOKEN"]
        var iterator = arguments.makeIterator()
        var generate = false
        var snippets = false
        while let argument = iterator.next() {
            switch argument {
            case "--generate-token": generate = true
            case "--snippets": snippets = true
            case "--url": url = iterator.next()
            case "--token": token = iterator.next()
            default: throw CommandError("usage: homeswift mcp [--url <url>] [--token <token>] | --generate-token | --snippets")
            }
        }
        let defaultURL = "http://\(mcp.host):\(mcp.port)/mcp"
        if generate {
            let generated = MCPConfiguration.generateToken()
            say("""
                A new client token. Put it in the HomeswiftAiKit block of config.json and restart homeswift:

                  "mcp": { "http": { "enabled": true, "token": "\(generated)" } }

                Then give it to clients (see homeswift mcp --snippets). Shown once; it is not stored anywhere else.
                """)
            return
        }
        if snippets {
            say(MCPClientSnippets.all(command: CommandLine.arguments[0], url: url ?? defaultURL, token: token ?? mcp.token))
            return
        }
        guard let resolvedURL = URL(string: url ?? defaultURL) else { throw CommandError("not a URL: \(url ?? defaultURL)") }
        guard let resolvedToken = token ?? mcp.token else {
            throw CommandError("no token: set HOMESWIFT_MCP_TOKEN, pass --token, or run homeswift mcp from the machine whose config.json has mcp.http.token")
        }
        if !mcp.enabled, url == nil {
            logger.warning("mcp.http.enabled is not true in config.json; the bridge's MCP server may not be running")
        }
        let proxy = StdioProxy(options: .init(url: resolvedURL, token: resolvedToken))
        await proxy.run(input: StdioProxy.lines(from: .standardInput)) { FileHandle.standardOutput.write($0) }
    }

    /// The bridge's MCP server, when the HomeswiftAiKit block enables it.
    static func startServer(catalog: HomeswiftCatalog, configuration: HomeswiftConfiguration, logger: Logger) async -> MCPHTTPServer? {
        guard let block = mcpBlock(configuration) else { return nil }
        do {
            let mcp = try MCPConfiguration(block: block)
            guard mcp.enabled else { return nil }
            let environment = ProcessInfo.processInfo.environment
            var options = MCPServer.Options(version: PluginHost.version, instructions: HomeswiftCatalog.instructions)
            options.elicitation = environment["HOMESWIFT_ELICITATION"] != "false"
            options.logger = logger
            let server = MCPServer(
                options: options, tools: catalog.tools, resources: catalog.resources, templates: catalog.templates, prompts: catalog.prompts,
                audit: mcp.makeAuditLog(configDirectory: catalog.configURL.deletingLastPathComponent(), logger: logger))
            let observations = catalog.attach(to: server)
            var transportOptions = MCPHTTPServer.Options(host: mcp.host, port: mcp.port, allowedOrigins: mcp.allowedOrigins)
            transportOptions.logger = logger
            let transport = MCPHTTPServer(server: server, configuration: mcp, options: transportOptions)
            transport.onStop { observations.forEach { $0.cancel() } }
            try await transport.start()
            return transport
        } catch {
            logger.error("MCP server not started: \(error)")
            return nil
        }
    }
}
