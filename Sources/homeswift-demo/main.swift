import Foundation
import Homeswift
import Logging

// A bridge with a lamp, a switch and a temperature sensor that drifts, for pairing with the Home app.

if CommandLine.arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
    print("""
        usage: homeswift-demo

        Runs a demo HomeKit bridge (a lamp, a switch, a temperature sensor) and prints its setup code.
        State is kept in ~/.homeswift/homeswift-demo.json.

        Environment:
          HAP_SETUP_CODE  setup code to use, e.g. 031-45-154 (default: random on first launch)
          HAP_DEBUG       log every request
        """)
    exit(0)
}

// Line-buffered even when not a terminal, so the setup code reaches log files (brew services).
setvbuf(stdout, nil, _IOLBF, 0)

LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = ProcessInfo.processInfo.environment["HAP_DEBUG"] != nil ? .trace : .info
    return handler
}

let lightbulb = Service(.lightbulb, name: "Demo Lamp", optional: [.brightness], isPrimary: true)
lightbulb.characteristic(.on).onWrite(changesOnly: true) { print("Lamp on: \($0.boolValue ?? false)") }
lightbulb.characteristic(.brightness).onWrite(changesOnly: true) { print("Lamp brightness: \($0.intValue ?? 0)%") }
let lamp = Accessory(
    id: "demo-lamp", name: "Demo Lamp", model: "Lamp", category: .lightbulb, services: [lightbulb],
    onIdentify: { print("Identify: Demo Lamp") })

let switchService = Service(.switch, name: "Demo Switch")
switchService.characteristic(.on).onWrite(changesOnly: true) { print("Switch on: \($0.boolValue ?? false)") }
let demoSwitch = Accessory(
    id: "demo-switch", name: "Demo Switch", model: "Switch", category: .switch, services: [switchService],
    onIdentify: { print("Identify: Demo Switch") })

let temperature = Service(.temperatureSensor, name: "Demo Temperature")
let thermometer = Accessory(
    id: "demo-temperature", name: "Demo Temperature", model: "Sensor", category: .sensor, services: [temperature],
    onIdentify: { print("Identify: Demo Temperature") })

let bridge = Accessory(
    id: "demo-bridge", name: "Homeswift Bridge", model: "Bridge", category: .bridge,
    services: [Service(.protocolInformation, extra: [Characteristic(.version, value: "1.1.0")])],
    onIdentify: { print("Identify: Homeswift Bridge") })

let server = try HAPServer(
    bridge: bridge, accessories: [lamp, demoSwitch, thermometer],
    storage: FileStorage(name: "homeswift-demo"),
    options: .init(setupCode: ProcessInfo.processInfo.environment["HAP_SETUP_CODE"].flatMap(SetupCode.init)))

print("""

    Homeswift Bridge
      Setup code: \(server.setupCode)
      Setup URI:  \(server.setupURI)
      Paired:     \(server.isPaired ? "yes (\(server.pairings.count) controller(s))" : "no")

    In the Home app: Add Accessory > More options > Homeswift Bridge, then enter the code.
    State is kept in ~/.homeswift/homeswift-demo.json; delete it to start over.

    """)

let main = Task {
    try await server.start()
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
    source.setEventHandler { @Sendable [main, server] in
        main.cancel()
        Task {
            await server.stop()
            exit(0)
        }
    }
    source.resume()
    return source
}
dispatchMain()
