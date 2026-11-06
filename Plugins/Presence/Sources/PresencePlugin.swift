import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// Presence (GLOSSARY.md, "Presence"): the Persons who live in the home, each known by the devices they carry, and an
/// occupancy sensor for each, home while one of their devices is on the network and away once none was for the grace
/// period (10 minutes by default); plus Anyone Home, occupied while at least one Person is home. Devices are found by the
/// ARP table and a probe of their address (`NetworkPresenceSource`); `PresenceSource` is where another source (a UniFi
/// Network controller's clients) plugs in.
///
/// A Person is added through Setup (Add accessories, "Add a Person"): their name, the web UI user they are, and their
/// devices picked from those on the network. All of it is the Person's Accessory Settings (`_accessories`, by Device Id
/// `person-…`): `name`, and the plugin's own `devices` (MACs) and `user`. The board on the host (`PluginContext.presence`)
/// carries who is home to the web UI ("you are home"), Automations and notifications.
public actor PresencePlugin: HomeswiftPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        /// Minutes without any of a Person's devices before they are away; 10 by default.
        public var graceMinutes: Double?
        /// Seconds between checks; 30 by default, 10 at least.
        public var interval: Double?
    }

    /// The plugin's own Accessory Settings of a Person.
    struct PersonSettings: Decodable {
        var devices: [String]?
        var user: String?
    }

    /// What the plugin uses to see the network and the time; tests swap them.
    struct Dependencies: Sendable {
        var source: any PresenceSource = NetworkPresenceSource(network: SystemNetwork())
        /// Multiplies the interval between checks: tests check every few milliseconds.
        var timeScale: Double = 1
        /// The clock the grace period runs on: tests move it.
        var now: @Sendable () -> Date = { Date() }
    }

    public static let platform = "Presence"
    public static let name = "Presence"
    public static let icon: String? = "users"
    public static let summary: String? = "Who is home, from the phones on the network"
    public static let addsDevicesByAddress = true
    public static let addDeviceLabel: String? = "Add a Person"

    /// Anyone Home's Device Id.
    static let anyoneID = "anyone"
    static let personKind = "person"
    static let anyoneKind = "anyone"
    static let defaultGraceMinutes = 10.0
    static let graceRange = 1.0...240.0
    static let defaultInterval = 30.0
    static let intervalRange = 10.0...600.0
    /// How often a Person's last sighting is saved when nothing else changed.
    static let saveEvery: TimeInterval = 300

    let configuration: Configuration
    let context: PluginContext
    let dependencies: Dependencies
    private let tasks = TaskBag()
    private var tracker: PresenceTracker
    private let stateFile: JSONFile<[String: PersonState]>
    private var lastSave = Date.distantPast
    private var started = false
    /// The occupancy sensors, by Device Id.
    private var sensors: [String: Characteristic] = [:]
    var logger: Logger { context.logger }

    public init(configuration: Configuration, context: PluginContext) {
        self.init(configuration: configuration, context: context, dependencies: Dependencies())
    }

    init(configuration: Configuration, context: PluginContext, dependencies: Dependencies) {
        self.configuration = configuration
        self.context = context
        self.dependencies = dependencies
        stateFile = context.jsonFile("presence.json")
        tracker = PresenceTracker(grace: Self.grace(configuration))
    }

    static func grace(_ configuration: Configuration) -> TimeInterval {
        min(max(configuration.graceMinutes ?? defaultGraceMinutes, graceRange.lowerBound), graceRange.upperBound) * 60
    }

    var interval: Duration {
        let seconds = min(max(configuration.interval ?? Self.defaultInterval, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
        return .seconds(seconds * dependencies.timeScale)
    }

    static func accessoryID(_ deviceID: String) -> String { "\(platform):\(deviceID)" }

    /// The Persons of the Accessory Settings, Excluded ones left out, by name.
    var persons: [Person] {
        context.allAccessorySettings.compactMap { id, settings -> Person? in
            guard id.hasPrefix("person-"), !settings.excluded else { return nil }
            let own = settings.decode(PersonSettings.self) ?? PersonSettings()
            return Person(id: id, name: settings.name ?? id, devices: Set((own.devices ?? []).compactMap(MACAddress.canonical)), user: own.user?.nonEmpty)
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    public func start() async throws {
        started = true
        tracker = PresenceTracker(grace: tracker.grace, states: stateFile.load() ?? [:])
        let persons = persons
        for person in persons { try add(person) }
        if !context.isExcluded(Self.anyoneID) { try addAnyoneHome() }
        _ = await context.removeAccessories(keeping: Set(persons.map { Self.accessoryID($0.id) } + [Self.accessoryID(Self.anyoneID)]), message: "Removing a Person")
        show(persons, changed: [])
        let interval = interval
        tasks.add { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() async {
        tasks.cancelAll()
        guard started else { return }
        save(at: dependencies.now())
        context.presence.clear()
    }

    /// One check: which devices are on the network, then each Person's state and Anyone Home.
    func check() async {
        let persons = persons
        let seen = await dependencies.source.seen(persons.reduce(into: Set<String>()) { $0.formUnion($1.devices) })
        let now = dependencies.now()
        let (changed, dirty) = tracker.update(persons, seen: seen, at: now)
        show(persons, changed: changed)
        if !changed.isEmpty || dirty && now.timeIntervalSince(lastSave) >= Self.saveEvery { save(at: now) }
    }

    /// The sensors and the board as the tracker has them; each Person who came or went is logged.
    private func show(_ persons: [Person], changed: [String]) {
        for person in persons {
            let state = tracker.state(of: person.id)
            sensors[person.id]?.value = .int(state.isHome ? 1 : 0)
            if changed.contains(person.id) { logger.info("\(person.name) is \(state.isHome ? "home" : "away")") }
        }
        let anyone = persons.contains { tracker.state(of: $0.id).isHome }
        sensors[Self.anyoneID]?.value = .int(anyone ? 1 : 0)
        context.presence.publish(persons.map { person in
            let state = tracker.state(of: person.id)
            return PersonPresence(id: Self.accessoryID(person.id), name: person.name, isHome: state.isHome, since: state.since, user: person.user)
        })
    }

    private func save(at now: Date) {
        do {
            try stateFile.save(tracker.states)
            lastSave = now
        } catch {
            logger.warning("Could not save who is home: \(error.localizedDescription)")
        }
    }

    private func add(_ person: Person) throws {
        let sensor = Service(.occupancySensor, name: person.name, isPrimary: true)
        sensors[person.id] = sensor.characteristic(.occupancyDetected)
        try context.add(Accessory(
            id: Self.accessoryID(person.id), name: person.name, manufacturer: "Homeswift", model: "Person", serialNumber: person.id,
            category: .sensor, services: [sensor]))
    }

    private func addAnyoneHome() throws {
        let sensor = Service(.occupancySensor, name: "Anyone Home", isPrimary: true)
        sensors[Self.anyoneID] = sensor.characteristic(.occupancyDetected)
        try context.add(Accessory(
            id: Self.accessoryID(Self.anyoneID), name: "Anyone Home", manufacturer: "Homeswift", model: "Anyone Home", serialNumber: Self.anyoneID,
            category: .sensor, services: [sensor]))
    }

    public func deviceKind(of deviceID: String) async -> String? {
        deviceID == Self.anyoneID ? Self.anyoneKind : deviceID.hasPrefix("person-") ? Self.personKind : nil
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
