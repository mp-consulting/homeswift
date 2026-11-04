import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftDummy

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// Paris, where the tests' days and periods are.
let paris: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
}()

func parisDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    paris.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-dummy-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Push notifications sent, in memory.
final class FakeNotifier: DummyNotifying {
    let sent = NIOLockedValueBox<[(title: String?, text: String)]>([])

    func send(_ notification: NotificationConfig, title: String?, text: String) async throws -> String? {
        sent.withLockedValue { $0.append((title, text)) }
        return nil
    }
}

/// Reachability set by the test.
final class FakeProbe: ReachabilityProbing {
    let reachable = NIOLockedValueBox<[String: Bool]>([:])
    let checks = NIOLockedValueBox(0)

    func isReachable(_ target: ReachabilityTarget) async -> Bool? {
        checks.withLockedValue { $0 += 1 }
        return reachable.withLockedValue { $0[target.host] } ?? false
    }
}

/// A block's accessories on an engine with a clock the test moves, without a bridge.
struct Harness {
    let scheduler: ManualScheduler
    let engine: DummyEngine
    let services: [String: DeviceServices]
    let directory: URL
    let notifier: FakeNotifier
    let probe: FakeProbe

    init(_ entries: [JSONValue], now: Date, directory: URL = temporaryDirectory(), random: @escaping @Sendable () -> Double = { 0.5 }) async {
        scheduler = ManualScheduler(now: now)
        notifier = FakeNotifier()
        probe = FakeProbe()
        self.directory = directory
        let reader = ConfigReader(logger: testLogger)
        let configs = entries.compactMap(reader.accessory)
        var dependencies = DummyEngine.Dependencies(scheduler: scheduler, calendar: paris, random: random, notifier: notifier, probe: probe)
        dependencies.notifier = notifier
        engine = DummyEngine(
            logger: testLogger, verbose: false, storeFile: JSONFile(url: directory.appendingPathComponent("HomebridgeDummy.json")), tasks: TaskBag(),
            dependencies: dependencies)
        let builder = DummyAccessoryBuilder(engine: engine, storage: directory, logger: testLogger)
        var built: [(AccessoryConfig, DeviceServices)] = []
        var services: [String: DeviceServices] = [:]
        for config in configs {
            let made = builder.services(for: config, grouped: config.groupName != nil)
            built.append((config, made))
            services[config.identifier] = made
        }
        self.services = services
        await engine.start(built)
    }

    /// The same block after a restart at `now`, from the same stored state.
    func restarted(_ entries: [JSONValue], at now: Date) async -> Harness {
        await engine.stop()
        return await Harness(entries, now: now, directory: directory)
    }

    func value(_ id: String, _ type: CharacteristicType) -> HAPValue? { services[id]?.primary[type]?.value }

    func stored(_ id: String, _ key: String) async -> JSONValue? { await engine.stored(id, key) }

    func advance(_ seconds: Double) async { await scheduler.advance(by: seconds) }

    func webhook(_ parameters: [String: JSONValue]) async -> WebhookReply { await engine.webhook(parameters) }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
