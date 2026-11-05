import Foundation
import HomeswiftNetwork
import HomeswiftNetworkTestSupport
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftMQTTThing

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// A clock the tests move.
final class TestClock: Sendable {
    private let time = NIOLockedValueBox(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { time.withLockedValue { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLockedValue { $0 += seconds } }
}

/// A host running config.json's accessory blocks on fake brokers, one per broker URL.
final class TestEnvironment: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-MQTTThing-tests-\(UUID().uuidString)")
    let clock = TestClock()
    private let brokers = NIOLockedValueBox<[String: FakeMQTTConnection]>([:])
    private let settings = NIOLockedValueBox<[BrokerSettings]>([])
    let timeScale: Double

    init(timeScale: Double = 0.01) { self.timeScale = timeScale }

    /// The fake broker at `url`.
    func broker(_ url: String = "mqtt://broker.local") -> FakeMQTTConnection {
        brokers.withLockedValue { brokers in
            if let existing = brokers[url] { return existing }
            let made = FakeMQTTConnection()
            brokers[url] = made
            return made
        }
    }

    var connections: [BrokerSettings] { settings.withLockedValue { $0 } }

    func start(_ accessories: [[String: Any]], environment: [String: String] = [:]) async throws -> PluginHost {
        var registry = PluginRegistry()
        let dependencies = MQTTThingPlugin.Dependencies(
            connect: { settings, _, _ in
                self.settings.withLockedValue { $0.append(settings) }
                return self.broker(settings.url)
            },
            // The windows that gather a change's writes into one publish are ten times the real ones: on a busy
            // runner, HomeKit's writes of one change (one test line each) can be further apart than 20 ms.
            thing: Thing.Dependencies(
                timeScale: timeScale, coalescing: .milliseconds(200), codecDelay: .milliseconds(500), now: { self.clock.now }, hostName: "testhost.local"),
            environment: environment, backoff: Backoff(initial: .milliseconds(10), maximum: .milliseconds(50)))
        registry.register(platform: MQTTThingPlugin.platform, name: MQTTThingPlugin.name, runsAccessoryBlocks: true) { json, context in
            MQTTThingPlugin(configuration: try JSONDecoder().decode(MQTTThingPlugin.Configuration.self, from: json), context: context, dependencies: dependencies)
        }
        let root: [String: Any] = ["bridge": ["name": "Test", "port": 0], "accessories": accessories]
        let configuration = try HomeswiftConfiguration.decode(JSONSerialization.data(withJSONObject: root))
        let options = PluginHost.Options(advertise: false, logger: testLogger) { _ in MemoryStorage() }
        let host = try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
        try await host.start()
        return host
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

extension PluginHost {
    func accessory(_ id: String) -> Accessory? {
        bridges.lazy.flatMap(\.server.accessories).first { $0.id == id }
    }

    func service(_ id: String, _ type: ServiceType, subtype: String? = nil) -> Service? {
        accessory(id)?.services.first { $0.type.uuid == type.uuid && (subtype == nil || $0.subtype == subtype) }
    }

    func value(_ id: String, _ service: ServiceType, _ characteristic: CharacteristicType) -> HAPValue? {
        self.service(id, service)?[characteristic]?.value
    }
}

extension FakeMQTTConnection {
    /// Sends `payload` on `topic` once something subscribed to it.
    func send(_ topic: String, _ payload: String) async {
        _ = await eventually { self.subscriptions[topic] != nil && self.isConnected }
        receive(topic, string: payload)
    }

    func waitFor(_ topic: String, count: Int = 1) async -> [String] {
        _ = await eventually { self.published(on: topic).count >= count }
        return published(on: topic)
    }
}

/// HomeKit writing a value.
func write(_ characteristic: Characteristic?, _ value: HAPValue) async throws {
    try await #require(characteristic).write(value)
}

/// HomeKit reading it: the read handler's answer, or its error.
func read(_ characteristic: Characteristic?) async throws -> HAPValue {
    let characteristic = try #require(characteristic)
    guard let handler = characteristic.readHandler else { return characteristic.value }
    return try await handler()
}
