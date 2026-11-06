import NIOConcurrencyHelpers

/// The HomeKit category shown during pairing, advertised as `ci`.
public enum AccessoryCategory: Int, Sendable, Codable {
    case other = 1, bridge, fan, garageDoorOpener, lightbulb, doorLock, outlet, `switch`, thermostat, sensor
    case securitySystem, door, window, windowCovering, programmableSwitch, rangeExtender, ipCamera
    case videoDoorbell, airPurifier, heater, airConditioner, humidifier, dehumidifier, appleTV, homePod
    case speaker, airport, sprinkler, faucet, showerHead, television, targetController, wifiRouter
    case audioReceiver, tvSetTopBox, tvStreamingStick
}

/// A HomeKit accessory: an Accessory Information service plus the services you give it.
///
/// `id` must be stable across launches (a serial number, MAC, or your own key): the server uses it
/// to keep the accessory's aid, and each service's iids, the same so HomeKit keeps rooms and scenes.
public final class Accessory: @unchecked Sendable {
    public let id: String
    /// Whether this accessory provides a physical identification action.
    public let supportsIdentify: Bool
    public let category: AccessoryCategory
    public let information: Service
    private let servicesBox: NIOLockedValueBox<[Service]>
    /// The Accessory Information service first, then the services given at creation.
    public var services: [Service] { servicesBox.withLockedValue { $0 } }

    let aidBox = NIOLockedValueBox(0)
    private let mirrorBox = NIOLockedValueBox<(source: String?, room: String?)>((nil, nil))
    private let separationBox = NIOLockedValueBox<(original: Accessory?, together: [[ObjectIdentifier]])>((nil, []))
    /// The camera that answers snapshot requests (`configureController`).
    let cameraControllerBox = NIOLockedValueBox<CameraController?>(nil)
    public var aid: Int { aidBox.withLockedValue { $0 } }

    public init(
        id: String,
        name: String,
        manufacturer: String = "Homeswift",
        model: String = "Accessory",
        serialNumber: String? = nil,
        firmwareRevision: String = "1.0.0",
        category: AccessoryCategory = .other,
        services: [Service],
        onIdentify: (@Sendable () async throws -> Void)? = nil
    ) {
        self.supportsIdentify = onIdentify != nil
        self.id = id
        self.category = category
        let information = Service(.accessoryInformation, name: name)
        information.characteristic(.manufacturer).value = .string(manufacturer)
        information.characteristic(.model).value = .string(model)
        information.characteristic(.serialNumber).value = .string(serialNumber ?? id)
        information.characteristic(.firmwareRevision).value = .string(firmwareRevision)
        information.characteristic(.identify).onWrite { _ in try await onIdentify?() }
        self.information = information
        servicesBox = NIOLockedValueBox([information] + services)
    }

    /// An accessory made of another's identity: its Accessory Information service itself (the same object, which the
    /// plugin keeps changing) and some of its services. What the runtime publishes in place of an accessory whose
    /// Functions are separated (Separate Functions, `HomeswiftPlugin`), under the same id.
    public init(id: String, information: Service, supportsIdentify: Bool, category: AccessoryCategory, services: [Service]) {
        self.id = id
        self.supportsIdentify = supportsIdentify
        self.category = category
        self.information = information
        servicesBox = NIOLockedValueBox([information] + services.filter { $0 !== information })
    }

    /// Takes the aid the server gave `published`, an accessory published in this one's place under its id (its Functions
    /// separated), so code that knows this one finds it.
    public func shareAid(of published: Accessory) {
        aidBox.withLockedValue { $0 = published.aid }
    }

    /// The plugin's own accessory this one was made from when its Functions are separated: the device's own accessory
    /// keeps its id with the main Function, each other Function is an accessory of its own (GLOSSARY.md, "Separate
    /// Functions"). nil for the plugin's own accessory.
    public var separatedFrom: Accessory? {
        get { separationBox.withLockedValue { $0.original } }
        set { separationBox.withLockedValue { $0.original = newValue } }
    }

    /// Says that these Functions must stay on one accessory when the accessory's Functions are separated (a light and
    /// the sensor it cannot work without). The runtime keeps a camera, a doorbell and a television whole, and a
    /// remote's buttons together, without being told.
    public func keepFunctionsTogether(_ services: [Service]) {
        separationBox.withLockedValue { $0.together.append(services.map(ObjectIdentifier.init)) }
    }

    /// The sets of services `keepFunctionsTogether` was given.
    public var functionsKeptTogether: [[Service]] {
        let together = separationBox.withLockedValue { $0.together }
        let byID = Dictionary(services.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { first, _ in first })
        return together.map { $0.compactMap { byID[$0] } }
    }

    /// The first service of the given type, if any.
    public subscript(type: ServiceType) -> Service? { service(type) }

    /// Adds a service: one the server needs on every accessory (Protocol Information), or one the runtime gives it (an
    /// Eve history). Before the accessory goes on a server: iids are given then.
    public func append(_ service: Service) {
        servicesBox.withLockedValue { $0.append(service) }
        StructureGeneration.bump()
    }

    public var name: String {
        information[.name]?.value.stringValue ?? id
    }

    /// The first service of the given type.
    public func service(_ type: ServiceType, subtype: String? = nil) -> Service? {
        services.first { $0.type.uuid == type.uuid && (subtype == nil || $0.subtype == subtype) }
    }

    /// Copies the values of a cached accessory onto this one, rebuilt from the device, so the Home app keeps showing the
    /// last readings and the names it was given until the device answers. Services match on type and subtype,
    /// characteristics on type; Accessory Information is left alone (`Service.takeValues(from:)` has the rule).
    public func takeValues(from cached: Accessory) {
        for service in services where service.type.uuid != ServiceType.accessoryInformation.uuid {
            guard let old = cached.services.first(where: { $0.type.uuid == service.type.uuid && $0.subtype == service.subtype }) else {
                continue
            }
            service.takeValues(from: old)
        }
    }

    /// Whether the accessory answers: while it does not, every read and write of its characteristics fails with
    /// "No Response" and reaches none of their handlers, so nothing is sent to the device (a paused plugin).
    /// Values and handlers are kept.
    /// A change is announced with an event of a value that did not change, so the pages following the accessory (the
    /// web UI's event stream carries `unavailable`) learn it at once.
    public var isUnavailable: Bool {
        get { services.contains { $0.characteristics.contains(where: \.isUnavailable) } }
        set { setAvailability(newValue, \.isUnavailable) }
    }

    /// No Response as the device's own controller reports it, for a mirror (the Wingman plugin: Apple Home's
    /// reachability, which lags for Matter devices): it shows as when `isUnavailable`, but writes still reach the
    /// handlers, as the Home app still tries an accessory that shows No Response, and the device's controller answers.
    /// A paused plugin's accessory is `isUnavailable` as well, which no write passes.
    public var isUnreachable: Bool {
        get { services.contains { $0.characteristics.contains(where: \.isUnreachable) } }
        set { setAvailability(newValue, \.isUnreachable) }
    }

    /// Whether it shows No Response (the web UI's cards, Matter's reachability, HomeKit's reads): `isUnavailable` or
    /// `isUnreachable`.
    public var showsNoResponse: Bool { services.contains { $0.characteristics.contains(where: \.showsNoResponse) } }

    private func setAvailability(_ value: Bool, _ flag: ReferenceWritableKeyPath<Characteristic, Bool>) {
        let characteristics = services.flatMap(\.characteristics)
        guard characteristics.contains(where: { $0[keyPath: flag] != value }) else { return }
        let showed = characteristics.contains(where: \.showsNoResponse)
        for characteristic in characteristics { characteristic[keyPath: flag] = value }
        // Only a change of what shows is announced: unreachable while paused shows No Response all along.
        guard characteristics.contains(where: \.showsNoResponse) != showed else { return }
        // A state, never a button's press (which automations take as one), and never an empty value.
        let announcer = characteristics.first {
            $0.type.permissions.contains(.events) && $0.type.uuid != CharacteristicType.programmableSwitchEvent.uuid && $0.value != .null
        }
        if let announcer { announcer.update(announcer.value, origin: nil, force: true) }
    }

    /// The controller this accessory mirrors, for an accessory HomeKit already has another way ("Apple Home": the
    /// Wingman plugin shows the Home app's accessories). The bridge keeps a mirrored accessory out of HomeKit (it
    /// is not in `GET /accessories`, and controllers cannot read, write or subscribe to it) while the web UI, the MCP
    /// server, scenes and shows use it as any other; the UI says where it comes from. Set before `context.add`.
    public var mirroredFrom: String? {
        get { mirrorBox.withLockedValue { $0.source } }
        set { mirrorBox.withLockedValue { $0.source = newValue } }
    }

    /// The room the mirrored controller puts it in: the web UI's until the user gives it one of its own.
    public var suggestedRoom: String? {
        get { mirrorBox.withLockedValue { $0.room } }
        set { mirrorBox.withLockedValue { $0.room = newValue } }
    }

    /// Runs its Identify, as a controller's write of Identify does (an accessory made of its Functions forwards its own).
    public func identify() async {
        guard !isUnavailable else { return }
        try? await information.characteristic(.identify).writeHandler(for: .bool(true))?(.bool(true))
    }
}

/// Counts the changes to accessories' structure made on the model rather than through a server (a service's `linked`,
/// a characteristic or service added): a server's cached `GET /accessories` body (`DatabaseTemplate`) is built again
/// when it moved.
enum StructureGeneration {
    private static let counter = NIOLockedValueBox<UInt64>(0)

    static var current: UInt64 { counter.withLockedValue { $0 } }

    static func bump() { counter.withLockedValue { $0 &+= 1 } }
}
