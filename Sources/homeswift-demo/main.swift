import Foundation
import Homeswift
import HomeswiftMatter
import Logging
import NIOConcurrencyHelpers

// A bridge with a lamp (with Adaptive Lighting), a switch and a temperature sensor that drifts, for pairing with the Home app.
// With --matter, the same accessories are a Matter bridge too, for Google Home, Alexa, SmartThings or Home Assistant.

/// Writes straight to the file descriptor: unbuffered, so lines reach log files (brew services) at once.
func say(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

if CommandLine.arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
    say("""
        usage: homeswift-demo [--matter] [--matter-device <id>]...

        Runs a demo HomeKit bridge (a lamp, a switch, a temperature sensor) and prints its setup code.
        State is kept in ~/.homeswift/homeswift-demo.json.

          --matter        also bridge the accessories over Matter (UDP port 5540) and print its pairing codes;
                          the Matter node's state is kept in ~/.homeswift/homeswift-demo-matter/
          --matter-device <id>
                          make an accessory (demo-lamp, demo-switch, demo-temperature) a Matter device of its own,
                          with its own pairing code; implies --matter

        Environment:
          HAP_SETUP_CODE  setup code to use, e.g. 031-45-154 (default: random on first launch)
          HAP_DEBUG       log every request

        SIGUSR1 turns the lamp's Adaptive Lighting on again with the last schedule the Home app sent.
        """)
    exit(0)
}

LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = ProcessInfo.processInfo.environment["HAP_DEBUG"] != nil ? .trace : .info
    return handler
}

let lightbulb = Service(.lightbulb, name: "Demo Lamp", optional: [.brightness, .colorTemperature], isPrimary: true)
lightbulb.characteristic(.on).onWrite(changesOnly: true) { say("Lamp on: \($0.boolValue ?? false)") }
lightbulb.characteristic(.brightness).onWrite(changesOnly: true) { say("Lamp brightness: \($0.intValue ?? 0)%") }
lightbulb.characteristic(.colorTemperature).onWrite(changesOnly: true) { say("Lamp colour temperature: \($0.intValue ?? 0) mired") }
let adaptiveLighting = AdaptiveLightingController(lightbulb)
let lamp = Accessory(
    id: "demo-lamp", name: "Demo Lamp", model: "Lamp", category: .lightbulb, services: [lightbulb],
    onIdentify: { say("Identify: Demo Lamp") })

let switchService = Service(.switch, name: "Demo Switch")
switchService.characteristic(.on).onWrite(changesOnly: true) { say("Switch on: \($0.boolValue ?? false)") }
let demoSwitch = Accessory(
    id: "demo-switch", name: "Demo Switch", model: "Switch", category: .switch, services: [switchService],
    onIdentify: { say("Identify: Demo Switch") })

let temperature = Service(.temperatureSensor, name: "Demo Temperature")
let thermometer = Accessory(
    id: "demo-temperature", name: "Demo Temperature", model: "Sensor", category: .sensor, services: [temperature],
    onIdentify: { say("Identify: Demo Temperature") })

let bridge = Accessory(
    id: "demo-bridge", name: "Homeswift Bridge", model: "Bridge", category: .bridge,
    services: [Service(.protocolInformation, extra: [Characteristic(.version, value: "1.1.0")])],
    onIdentify: { say("Identify: Homeswift Bridge") })

let server = try HAPServer(
    bridge: bridge, accessories: [lamp, demoSwitch, thermometer],
    storage: FileStorage(name: "homeswift-demo"),
    options: .init(setupCode: ProcessInfo.processInfo.environment["HAP_SETUP_CODE"].flatMap(SetupCode.init)))

say("""

    Homeswift Bridge
      Setup code: \(server.setupCode)
      Setup URI:  \(server.setupURI)
      Paired:     \(server.isPaired ? "yes (\(server.pairings.count) controller(s))" : "no")

    In the Home app: Add Accessory > More options > Homeswift Bridge, then enter the code.
    State is kept in ~/.homeswift/homeswift-demo.json; delete it to start over.

    """)

let arguments = Array(CommandLine.arguments.dropFirst())
let matterDevices = arguments.indices.filter { arguments[$0] == "--matter-device" }.map { index in
    let ids = ["demo-lamp", "demo-switch", "demo-temperature"]
    guard index + 1 < arguments.count, ids.contains(arguments[index + 1]) else {
        say("--matter-device takes one of \(ids.joined(separator: ", "))")
        exit(1)
    }
    return arguments[index + 1]
}
let bridgesMatter = arguments.contains("--matter") || !matterDevices.isEmpty
// Set once it is made, for the signal handler to stop it.
let matterBridge = NIOLockedValueBox<HomeswiftMatterBridge?>(nil)

let matterDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".homeswift/homeswift-demo-matter")

let main = Task {
    try await server.start()
    if bridgesMatter {
        var configuration = MatterConfiguration()
        configuration.devices = matterDevices
        let matter = try await HomeswiftMatterBridge(
            configuration: configuration, source: ServerAccessories(server),
            storage: MatterFileStorage(directory: matterDirectory), deviceStorage: { MatterFileStorage(device: $0, in: matterDirectory) })
        matterBridge.withLockedValue { $0 = matter }
        try await matter.start()
        // The demo shows the pairing codes on purpose: they are how a person commissions it.
        say(await matter.pairingLines())
    }
    var reading = 21.0
    while !Task.isCancelled {
        try await Task.sleep(for: .seconds(10))
        reading += Double.random(in: -0.3...0.3)
        temperature.characteristic(.currentTemperature).value = .double((reading * 10).rounded() / 10)
    }
}

// Ctrl-C, or SIGTERM from `brew services stop` and launchd.
let signals = [SIGINT, SIGTERM].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    signal(number, SIG_IGN)
    // Not main-actor code: Dispatch runs the handler on its own terms, so it only uses what it captures.
    source.setEventHandler { @Sendable [main, server, matterBridge] in
        main.cancel()
        Task {
            await matterBridge.withLockedValue { $0 }?.stop()
            await server.stop()
            exit(0)
        }
    }
    source.resume()
    return source
}
// SIGUSR1 turns the lamp's Adaptive Lighting on again with the last schedule the Home app sent.
signal(SIGUSR1, SIG_IGN)
let resume = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
resume.setEventHandler { @Sendable [adaptiveLighting] in
    say(adaptiveLighting.resumeAdaptiveLighting() ? "Adaptive Lighting resumed" : "Adaptive Lighting: nothing to resume")
}
resume.resume()
dispatchMain()
