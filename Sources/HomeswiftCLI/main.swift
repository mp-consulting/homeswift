import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import HomeswiftMatter
import HomeswiftPlugin
import HomeswiftUI
import Logging
import NIOConcurrencyHelpers

// The bridge: reads config.json, runs the plugins compiled in, and prints the setup codes.

/// Writes straight to the file descriptor: unbuffered, so lines reach log files (brew services) at once.
func say(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data(("homeswift: " + text + "\n").utf8))
    exit(1)
}

let usage = """
    usage: homeswift [-U <path>] [-D]
           homeswift plugins
           homeswift ask <question>
           homeswift explain <error message>
           homeswift diagnose [<log file>]
           homeswift digest [--hours <hours>]
           homeswift organize [--json]
           homeswift test-ai
           homeswift usage [--json]
           homeswift mcp [--url <url>] [--token <token>] | --generate-token | --snippets
           homeswift users list | add <username> | password <username> | check <username>
           homeswift logs [-n <lines>] [-f]
           homeswift vault list | set <name> | remove <name>

    Runs a HomeKit bridge with the plugins listed in <path>/config.json and prints its setup code.
    The file has Homebridge's shape: a "bridge" block and "platforms" blocks (see docs/plugins.md).
    A default config.json is created on the first run. A { "platform": "HomeswiftUI" } block adds the
    web UI on port 8581 (docs/ui.md).

    Options:
      -U, --user-storage-path <path>  where config.json and the state live (default: ~/.homeswift)
      -D, --debug                     log debug output
      -V, --version                   print the version
      -h, --help                      print this help

    Commands:
      plugins                         list the plugins compiled into this binary
      ask                             ask the Assistant a question (docs/ai.md)
      explain                         have the Assistant explain a device error
      diagnose                        have the Assistant diagnose a log file, or the log piped in
      digest                          a digest of the last day: the log's warnings and errors, the accessories
      organize                        rooms and clearer names for the accessories the bridge last cached
      test-ai                         check that the HomeswiftAiKit block's provider, key and model answer
      usage                           the Assistant's usage today and this month, with the budgets
      mcp                             stdio MCP server for Claude Desktop, Claude Code or Cursor, proxied to the
                                      bridge's HTTP MCP server (docs/mcp.md); --generate-token, --snippets
      users                           the web UI's accounts; passwords are read from standard input
      logs                            the last lines of the bridge's log (logs/), and the new ones with -f
      vault                           the vault's entries (docs/vault-design.md); values are read from standard input

    Environment:
      HAP_DEBUG                       log every request (trace level)
      ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY   API keys when the HomeswiftAiKit block has none
      HOMESWIFT_MCP_URL, HOMESWIFT_MCP_TOKEN              where homeswift mcp connects, and with which token
      HOMESWIFT_ALLOW_SECRETS=true    let get_config return secrets; HOMESWIFT_ELICITATION=false turns off questions
      HOMESWIFT_SECRET_FILES          the folders file: references may read (:-separated; /run/secrets when not set)
      HOMESWIFT_SECRET_ENV            the variables env: references may read (,-separated, PREFIX_* allowed; any when not set)
    """

var storagePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".homeswift")
var debug = false
var command = "run"
var commandArguments: [String] = []
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "-U", "--user-storage-path":
        guard let path = arguments.next() else { fail("\(argument) needs a path") }
        storagePath = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    case "-D", "--debug":
        debug = true
    case "-V", "--version":
        say(PluginHost.version)
        exit(0)
    case "-h", "--help":
        say(usage)
        exit(0)
    case "plugins":
        command = "plugins"
    case "ask", "explain", "diagnose", "digest", "organize", "test-ai", "usage", "mcp", "users", "logs", "vault":
        command = argument
        // Everything after the command is the question, the error or the file.
        while let rest = arguments.next() { commandArguments.append(rest) }
    default:
        fail("unknown argument \(argument); see --help")
    }
}

let level: Logger.Level = ProcessInfo.processInfo.environment["HAP_DEBUG"] != nil ? .trace : (debug ? .debug : .info)
// The bridge keeps its log on disk too, rotated, for the web UI's time ranges; the other commands do not.
let logBuffer = LogBuffer(archive: command == "run" ? LogArchive(directory: storagePath.appendingPathComponent("logs")) : nil)
// `homeswift mcp` owns stdout for the protocol: its log goes to stderr.
let logToStandardError = command == "mcp"
LoggingSystem.bootstrap { label in HomeswiftLogHandler(label: label, logLevel: level, buffer: logBuffer, standardError: logToStandardError) }
let logger = Logger(label: "homeswift")
let registry = builtInPlugins()

if command == "plugins" {
    let width = registry.entries.map(\.platform.count).max() ?? 8
    say("PLATFORM".padding(toLength: width + 2, withPad: " ", startingAt: 0) + "NAME")
    for entry in registry.entries {
        say(entry.platform.padding(toLength: width + 2, withPad: " ", startingAt: 0) + entry.name)
    }
    exit(0)
}

if command == "users" || command == "logs" || command == "vault" {
    do {
        if command == "users" {
            try UsersCommands.run(arguments: commandArguments, storagePath: storagePath)
        } else if command == "vault" {
            try VaultCommands.run(arguments: commandArguments, storagePath: storagePath)
        } else {
            try LogsCommand.run(arguments: commandArguments, storagePath: storagePath)
        }
        exit(0)
    } catch {
        fail("\(error)")
    }
}

let configURL = storagePath.appendingPathComponent("config.json")
if command == "run" {
    // A backup restored from the web UI was staged before the restart: its files go in before anything reads them.
    InstanceBackups.applyPendingRestore(storage: storagePath, logger: logger)
}
if !FileManager.default.fileExists(atPath: configURL.path) {
    do {
        // Owner-only, like the bridge's state file: config.json holds the setup code and plugin secrets.
        try OwnerOnlyFile.write(HomeswiftConfiguration.makeDefault(), to: configURL)
        logger.info("Created \(configURL.path); add platform blocks to it to run plugins")
    } catch {
        fail("could not create \(configURL.path): \(error)")
    }
}

let configuration: HomeswiftConfiguration
do {
    // Sealed secrets (`enc:v1:`) are opened and references (`vault:`, `env:`, `file:`) resolved here, so every
    // command and plugin reads the plain values.
    configuration = try ConfigurationSecrets.opening(HomeswiftConfiguration.load(from: configURL), storage: storagePath)
} catch {
    fail("\(configURL.path): \(error)")
}

if command == "mcp" || AssistantCommands.commands.contains(command) {
    // Top-level code runs on the main actor, so the command runs detached and the main thread serves Dispatch.
    let selectedCommand = command
    let selectedArguments = commandArguments
    let selectedConfiguration = configuration
    let selectedStorage = storagePath
    Task.detached {
        do {
            if selectedCommand == "mcp" {
                try await MCPCommands.run(arguments: selectedArguments, configuration: selectedConfiguration, logger: logger)
            } else {
                try await AssistantCommands.run(selectedCommand, arguments: selectedArguments, configuration: selectedConfiguration, storage: selectedStorage, logger: logger)
            }
            exit(0)
        } catch {
            fail("\(error)")
        }
    }
    dispatchMain()
}

let host: PluginHost
do {
    var hostOptions = PluginHost.Options(logger: logger)
    hostOptions.systemPlatforms.insert(UIConfiguration.platform)
    hostOptions.systemPlatforms.insert(MatterConfiguration.platform)
    host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: storagePath, options: hostOptions)
} catch {
    fail("\(error)")
}

// The Status page's memory, CPU and latency history, a week of it under metrics/.
let metrics = Metrics(directory: storagePath.appendingPathComponent("metrics"))
let mcpServer = NIOLockedValueBox<MCPHTTPServer?>(nil)
let uiServer = NIOLockedValueBox<UIServer?>(nil)
/// The catalog once made: its automations and notifications stop with the rest.
let homeCatalog = NIOLockedValueBox<HomeswiftCatalog?>(nil)
/// Set by a restart homeswift makes itself, and inherited by the process it execs: no stopped and started notifications.
let restartMarker = "HOMESWIFT_RESTARTED"
let restarted = ProcessInfo.processInfo.environment[restartMarker] == "1"
unsetenv(restartMarker)
/// Stops the servers, then the plugins and bridges: the signal handler exits afterwards, a restart execs.
let shutdown: @Sendable () async -> Void = { [host, mcpServer, uiServer] in
    logger.info("Shutdown: stopping home tasks")
    await homeCatalog.withLockedValue { $0 }?.stopHome(restarting: getenv(restartMarker) != nil)
    logger.info("Shutdown: stopping web server")
    await uiServer.withLockedValue { $0 }?.stop()
    logger.info("Shutdown: stopping MCP server")
    await mcpServer.withLockedValue { $0 }?.stop()
    logger.info("Shutdown: stopping Matter bridge")
    await homeCatalog.withLockedValue { $0 }?.matter.current?.stop()
    logger.info("Shutdown: stopping plugins and bridges")
    await host.stop()
    logger.info("Shutdown: flushing metrics and logs")
    metrics.stop()
    logBuffer.archive?.flush()
}
let main = Task {
    do {
        try await host.start()
    } catch {
        fail("could not start: \(error)")
    }
    metrics.start(following: host)
    // The control surface the MCP server and the web UI share; its restart hook execs a fresh copy of this
    // process, and a saved HomeswiftUI or HomeswiftAiKit block restarts the servers it configures in place.
    let catalogBox = NIOLockedValueBox<HomeswiftCatalog?>(nil)
    let mcpSettings = NIOLockedValueBox(MCPCommands.mcpBlock(configuration)?["mcp"])
    // The web UI's settings as last started, to fall back on when new ones cannot start.
    let uiConfiguration = NIOLockedValueBox(configuration)
    let catalog = HomeswiftCatalog(
        host: host, logs: logBuffer, metrics: metrics, configURL: configURL, allowSecrets: (ProcessInfo.processInfo.environment["HOMESWIFT_ALLOW_SECRETS"] ?? ProcessInfo.processInfo.environment["HOMEBRIDGE_ALLOW_SECRETS"]) == "true",
        restart: { Task.detached { setenv(restartMarker, "1", 1); await Restart.perform(shutdown: shutdown, replace: { Restart.exec(UICommands.relaunchExecutable) }) } },
        reloadServices: { [mcpServer, uiServer] next, platforms in
            guard let catalog = catalogBox.withLockedValue({ $0 }) else { return }
            let settings = MCPCommands.mcpBlock(next)?["mcp"]
            if platforms.contains(AIConfiguration.platform), mcpSettings.withLockedValue({ $0 }) != settings {
                await mcpServer.withLockedValue { $0 }?.stop()
                let (started, effective) = await MCPCommands.startServer(catalog: catalog, configuration: next, logger: logger)
                // With the token it may have saved, so the next change to the block compares against what runs.
                mcpSettings.withLockedValue { $0 = MCPCommands.mcpBlock(effective)?["mcp"] }
                mcpServer.withLockedValue { $0 = started }
                logger.info(started == nil ? "MCP server stopped" : "MCP server restarted with the new settings")
            }
            if platforms.contains(MatterConfiguration.platform) {
                if let bridge = await MatterCommands.reload(catalog: catalog, configuration: next, logger: logger) {
                    say(await MatterCommands.bannerLines(bridge))
                }
            }
            if platforms.contains(UIConfiguration.platform) {
                // The old server goes first: the new one usually wants the same port.
                await uiServer.withLockedValue { $0 }?.stop()
                var started = await UICommands.startServer(catalog: catalog, configuration: next, mcp: { mcpServer.withLockedValue { $0 } }, logger: logger)
                if started == nil, (try? next.block(for: UIConfiguration.platform)) != nil {
                    logger.error("The web UI could not start with its new settings; it is back on the previous ones until they are fixed")
                    started = await UICommands.startServer(catalog: catalog, configuration: uiConfiguration.withLockedValue { $0 }, mcp: { mcpServer.withLockedValue { $0 } }, logger: logger)
                } else {
                    uiConfiguration.withLockedValue { $0 = next }
                    logger.info(started == nil ? "Web UI stopped" : "Web UI restarted with the new settings")
                }
                uiServer.withLockedValue { $0 = started }
                // A new server with no account has a new set-up code: the banner's no longer works. Like the
                // banner, it goes to standard output, never to the log.
                if let started, let code = started.setupCode, started.users.isEmpty {
                    say("Web UI set-up code: \(code)   (asked once, on the visit that creates the administrator account)")
                }
            }
        },
        blockSchemas: [UIConfiguration.platform: UIConfiguration.schemaJSON, AIConfiguration.platform: AIConfiguration.schemaJSON,
                       MatterConfiguration.platform: MatterConfiguration.schemaJSON],
        logger: logger)
    catalogBox.withLockedValue { $0 = catalog }
    homeCatalog.withLockedValue { $0 = catalog }
    // Scenes' automations and the notifications (bridge started, plugin errors, accessories offline, the digest).
    catalog.startHome(restarted: restarted)
    let (startedMCP, mcpConfiguration) = await MCPCommands.startServer(catalog: catalog, configuration: configuration, logger: logger)
    mcpSettings.withLockedValue { $0 = MCPCommands.mcpBlock(mcpConfiguration)?["mcp"] }
    if let startedMCP {
        mcpServer.withLockedValue { $0 = startedMCP }
    }
    if let started = await UICommands.startServer(catalog: catalog, configuration: configuration, mcp: { mcpServer.withLockedValue { $0 } }, logger: logger) {
        uiServer.withLockedValue { $0 = started }
    }
    // The Matter switch asks the mapping whether an accessory can be a device, with Matter on or off.
    catalog.matter.maps = { HomeswiftMatterBridge.maps($0, exposeSecurity: $1) }
    let startedMatter = await MatterCommands.start(catalog: catalog, configuration: configuration, logger: logger)
    for bridge in host.bridges {
        let server = bridge.server
        let platforms = host.platforms.filter { $0.bridge === bridge }.map(\.name)
        say("""

            \(bridge.name)\(bridge.isChild ? " (child bridge)" : bridge.isExternal ? " (accessory of \(bridge.owner ?? "a plugin"))" : "")
              Setup code: \(server.setupCode)
              Setup URI:  \(server.setupURI)
              Port:       \(server.port.map(String.init) ?? "?")
              Paired:     \(server.isPaired ? "yes (\(server.pairings.count) controller(s))" : "no")
              Plugins:    \(platforms.isEmpty ? "none" : platforms.joined(separator: ", "))
            """)
    }
    let mcpLine = mcpServer.withLockedValue { $0 }.map { "MCP server: http://\($0.options.host):\($0.port ?? $0.options.port)\($0.options.path)   (homeswift mcp --snippets for client configs)\n" } ?? ""
    let uiLine = uiServer.withLockedValue { $0 }.map { server -> String in
        let host = server.configuration.host == "0.0.0.0" ? "<this machine>" : server.configuration.host
        var line = "Web UI:     \(server.configuration.scheme)://\(host):\(server.port ?? server.configuration.port)/\n"
        if let fingerprint = server.certificateFingerprint {
            line += "            Certificate SHA-256: \(fingerprint)\n"
        }
        if let code = server.setupCode, server.users.isEmpty {
            line += "            Set-up code: \(code)   (asked once, on the visit that creates the administrator account)\n"
        }
        return line
    } ?? ""
    var matterLine = ""
    if let startedMatter { matterLine = await MatterCommands.bannerLines(startedMatter) }
    say("""

        In the Home app: Add Accessory > More options > \(host.mainBridge.name), then enter the code.\(host.bridges.contains(where: \.isExternal) ? " Accessories listed on their own are added the same way, one by one." : "")
        Config: \(configURL.path)
        \(uiLine)\(mcpLine)\(matterLine)
        """)
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3600))
    }
}

// Ctrl-C, or SIGTERM from `brew services stop` and launchd.
let signals = [SIGINT, SIGTERM].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    signal(number, SIG_IGN)
    // Not main-actor code: Dispatch runs the handler on its own terms, so it only uses what it captures.
    source.setEventHandler { @Sendable [main, shutdown] in
        main.cancel()
        Task {
            await shutdown()
            exit(0)
        }
    }
    source.resume()
    return source
}
dispatchMain()
