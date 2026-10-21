import Foundation
import Homeswift
import HomeswiftMCP
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
           homeswift mcp [--url <url>] [--token <token>] | --generate-token | --snippets

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
      mcp                             stdio MCP server for Claude Desktop, Claude Code or Cursor, proxied to the
                                      bridge's HTTP MCP server (docs/mcp.md); --generate-token, --snippets

    Environment:
      HAP_DEBUG                       log every request (trace level)
      ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY   API keys when the HomeswiftAiKit block has none
      HOMESWIFT_MCP_URL, HOMESWIFT_MCP_TOKEN              where homeswift mcp connects, and with which token
      HOMESWIFT_ALLOW_SECRETS=true    let get_config return secrets; HOMESWIFT_ELICITATION=false turns off questions
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
    case "ask", "explain", "diagnose", "mcp":
        command = argument
        // Everything after the command is the question, the error or the file.
        while let rest = arguments.next() { commandArguments.append(rest) }
    default:
        fail("unknown argument \(argument); see --help")
    }
}

let level: Logger.Level = ProcessInfo.processInfo.environment["HAP_DEBUG"] != nil ? .trace : (debug ? .debug : .info)
let logBuffer = LogBuffer()
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

let configURL = storagePath.appendingPathComponent("config.json")
if !FileManager.default.fileExists(atPath: configURL.path) {
    do {
        // Owner-only, like the bridge's state file: config.json holds the setup code and plugin secrets.
        try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try HomeswiftConfiguration.makeDefault().write(to: configURL, options: .atomic)
        #if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        #endif
        logger.info("Created \(configURL.path); add platform blocks to it to run plugins")
    } catch {
        fail("could not create \(configURL.path): \(error)")
    }
}

let configuration: HomeswiftConfiguration
do {
    configuration = try HomeswiftConfiguration.load(from: configURL)
} catch {
    fail("\(configURL.path): \(error)")
}

if ["ask", "explain", "diagnose", "mcp"].contains(command) {
    // Top-level code runs on the main actor, so the command runs detached and the main thread serves Dispatch.
    let selectedCommand = command
    let selectedArguments = commandArguments
    let selectedConfiguration = configuration
    Task.detached {
        do {
            if selectedCommand == "mcp" {
                try await MCPCommands.run(arguments: selectedArguments, configuration: selectedConfiguration, logger: logger)
            } else {
                try await AssistantCommands.run(selectedCommand, arguments: selectedArguments, configuration: selectedConfiguration, logger: logger)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("homeswift: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

let host: PluginHost
do {
    var hostOptions = PluginHost.Options(logger: logger)
    hostOptions.systemPlatforms.insert(UIConfiguration.platform)
    host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: storagePath, options: hostOptions)
} catch {
    fail("\(error)")
}

let mcpServer = NIOLockedValueBox<MCPHTTPServer?>(nil)
let uiServer = NIOLockedValueBox<UIServer?>(nil)
let main = Task {
    do {
        try await host.start()
    } catch {
        fail("could not start: \(error)")
    }
    if let started = await MCPCommands.startServer(host: host, configuration: configuration, logs: logBuffer, configURL: configURL, logger: logger) {
        mcpServer.withLockedValue { $0 = started }
    }
    if let started = await UICommands.startServer(host: host, configuration: configuration, logs: logBuffer, configURL: configURL, logger: logger) {
        uiServer.withLockedValue { $0 = started }
    }
    for bridge in host.bridges {
        let server = bridge.server
        let platforms = host.platforms.filter { $0.bridge === bridge }.map(\.name)
        say("""

            \(bridge.name)\(bridge.isChild ? " (child bridge)" : "")
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
        return "Web UI:     http://\(host):\(server.port ?? server.configuration.port)/\n"
    } ?? ""
    say("""

        In the Home app: Add Accessory > More options > \(host.mainBridge.name), then enter the code.
        Config: \(configURL.path)
        \(uiLine)\(mcpLine)
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
    source.setEventHandler { @Sendable [main, host, mcpServer, uiServer] in
        main.cancel()
        Task {
            await uiServer.withLockedValue { $0 }?.stop()
            await mcpServer.withLockedValue { $0 }?.stop()
            await host.stop()
            exit(0)
        }
    }
    source.resume()
    return source
}
dispatchMain()
