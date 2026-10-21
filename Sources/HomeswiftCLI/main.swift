import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

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

    Runs a HomeKit bridge with the plugins listed in <path>/config.json and prints its setup code.
    The file has Homebridge's shape: a "bridge" block and "platforms" blocks (see docs/plugins.md).
    A default config.json is created on the first run.

    Options:
      -U, --user-storage-path <path>  where config.json and the state live (default: ~/.homeswift)
      -D, --debug                     log debug output
      -V, --version                   print the version
      -h, --help                      print this help

    Commands:
      plugins                         list the plugins compiled into this binary

    Environment:
      HAP_DEBUG                       log every request (trace level)
    """

var storagePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".homeswift")
var debug = false
var command = "run"
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
    default:
        fail("unknown argument \(argument); see --help")
    }
}

let level: Logger.Level = ProcessInfo.processInfo.environment["HAP_DEBUG"] != nil ? .trace : (debug ? .debug : .info)
LoggingSystem.bootstrap { label in HomeswiftLogHandler(label: label, logLevel: level) }
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

let host: PluginHost
do {
    host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: storagePath, options: .init(logger: logger))
} catch {
    fail("\(error)")
}

let main = Task {
    do {
        try await host.start()
    } catch {
        fail("could not start: \(error)")
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
    say("""

        In the Home app: Add Accessory > More options > \(host.mainBridge.name), then enter the code.
        Config: \(configURL.path)

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
    source.setEventHandler { @Sendable [main, host] in
        main.cancel()
        Task {
            await host.stop()
            exit(0)
        }
    }
    source.resume()
    return source
}
dispatchMain()
