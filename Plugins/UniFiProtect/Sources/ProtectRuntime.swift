import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// The isolation of the controllers, devices and their timers: the Homebridge plugin runs on one thread and
/// its classes call each other freely; here they share this actor. Characteristic handlers hop onto it.
@globalActor
actor ProtectActor {
    static let shared = ProtectActor()
}

/// Named, re-armable timers (`setTimeout` keyed by purpose, as the event handlers use them). Durations are
/// scaled by `timeScale` so tests run the plugin's real timings faster.
@ProtectActor
final class ProtectTimers {
    let timeScale: Double
    private var timers: [String: (id: Int, task: Task<Void, Never>)] = [:]
    private var anonymous: [Int: Task<Void, Never>] = [:]
    private var next = 0

    init(timeScale: Double) {
        self.timeScale = timeScale
    }

    func duration(milliseconds: Int) -> Duration {
        .milliseconds(Int((Double(milliseconds) * timeScale).rounded()))
    }

    func has(_ key: String) -> Bool { timers[key] != nil }

    /// Arms `key`, replacing a pending one; the action runs once after `milliseconds` and the key is cleared.
    func reset(_ key: String, after milliseconds: Int, _ action: @escaping @ProtectActor () -> Void) {
        timers[key]?.task.cancel()
        next += 1
        let id = next
        let delay = duration(milliseconds: milliseconds)
        let task = Task { @ProtectActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.timers[key]?.id == id else { return }
            self.timers[key] = nil
            action()
        }
        timers[key] = (id, task)
    }

    func cancel(_ key: String) {
        timers.removeValue(forKey: key)?.task.cancel()
    }

    /// A one-off delayed action (`setTimeout` without a handle).
    func after(_ milliseconds: Int, _ action: @escaping @ProtectActor () -> Void) {
        next += 1
        let id = next
        let delay = duration(milliseconds: milliseconds)
        anonymous[id] = Task { @ProtectActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.anonymous[id] = nil
            action()
        }
    }

    func cancelAll() {
        timers.values.forEach { $0.task.cancel() }
        anonymous.values.forEach { $0.cancel() }
        timers = [:]
        anonymous = [:]
    }

    /// Sleeps for `milliseconds`, scaled.
    func sleep(_ milliseconds: Int) async {
        try? await Task.sleep(for: duration(milliseconds: milliseconds))
    }
}

/// What the Homebridge plugin keeps in `accessory.context`, per accessory id, kept across launches in
/// `accessory-context.json` of the plugin's directory.
struct ProtectAccessoryContext: Codable, Sendable, Equatable {
    /// Whether motion detection is on for the device.
    var detectMotion: Bool?
    /// Whether doorbell rings are muted in HomeKit.
    var doorbellMuted: Bool?
    /// Legacy HKSV recording state, read once for migration.
    var hksvRecording: Bool?
    /// Whether HKSV recording was turned off with the HKSV recording switch.
    var hksvRecordingDisabled: Bool?
    /// The liveview of a liveview switch accessory.
    var liveview: String?
    /// The last state of a liveview switch.
    var liveviewState: Bool?
    /// The MAC of the Protect device. Synthetic accessories (package cameras) have none.
    var mac: String?
    /// The MAC of the controller the accessory belongs to.
    var nvr: String?
    /// The MAC of the device whose package camera this is.
    var packageCamera: String?
    /// The security system's state.
    var securityState: Int?
    /// Whether this is the controller's system information accessory.
    var systemInfo: Bool?
}

/// The contexts of every accessory of a plugin instance, saved owner-only after each change.
@ProtectActor
final class ProtectContextStore {
    private let contexts: PersistedDictionary<ProtectAccessoryContext>
    private let log: ProtectLog

    init(url: URL, log: ProtectLog) {
        contexts = PersistedDictionary(url: url, autosave: nil)
        self.log = log
    }

    subscript(id: String) -> ProtectAccessoryContext {
        get { contexts[id] ?? ProtectAccessoryContext() }
        set { if contexts.update(id, { $0 = newValue }) { save() } }
    }

    func remove(_ id: String) {
        if contexts.removeValue(forKey: id) != nil { save() }
    }

    private func save() {
        do {
            try contexts.flush()
        } catch {
            log.error("Unable to save the accessory context to \(contexts.url.path): \(error).")
        }
    }
}

/// An accessory in the making, the way the Homebridge plugin grows and trims a `PlatformAccessory`:
/// `acquire` finds or adds a service, `valid` removes one that should not be there. Homeswift accessories do
/// not change shape, so `publish()` builds a fresh `Accessory` from the services whenever the set changed
/// (the runtime keeps the aid and iids) and otherwise only values move.
@ProtectActor
final class ProtectAccessory {
    let id: String
    private(set) var name: String
    var category: AccessoryCategory
    var manufacturer = "Ubiquiti Inc."
    var model = "UniFi Protect"
    var serialNumber: String?
    var firmwareRevision = "1.0.0"
    /// Published on a server of its own (`Device.Standalone`) rather than on the bridge.
    var isStandalone = false
    private(set) var services: [Service] = []
    private(set) var isDirty = true
    private(set) var published: Accessory?
    /// The camera controller, whose services go on the accessory when it is published.
    var cameraController: CameraController? {
        didSet { isDirty = true }
    }
    private let host: any ProtectAccessoryHost
    private let log: ProtectLog

    init(id: String, name: String, category: AccessoryCategory, host: any ProtectAccessoryHost, log: ProtectLog) {
        self.id = id
        self.name = sanitizeName(name).nonEmpty ?? "Unnamed"
        self.category = category
        self.host = host
        self.log = log
    }

    /// Renames the accessory (the information service's name), as `accessoryName = …` does.
    func rename(_ newName: String) {
        let cleaned = sanitizeName(newName).nonEmpty ?? name
        guard cleaned != name else { return }
        name = cleaned
        isDirty = true
    }

    func setInformation(manufacturer: String? = nil, model: String? = nil, serialNumber: String? = nil, firmwareRevision: String? = nil) {
        if let manufacturer, manufacturer != self.manufacturer { self.manufacturer = manufacturer; isDirty = true }
        if let model, !model.isEmpty, model != self.model { self.model = model; isDirty = true }
        if let serialNumber, !serialNumber.isEmpty, serialNumber != self.serialNumber { self.serialNumber = serialNumber; isDirty = true }
        if let firmwareRevision, !firmwareRevision.isEmpty, firmwareRevision != self.firmwareRevision { self.firmwareRevision = firmwareRevision; isDirty = true }
    }

    func service(_ type: ServiceType, subtype: String? = nil) -> Service? {
        services.first { $0.type.uuid == type.uuid && $0.subtype == subtype }
    }

    /// The first service of a type, whatever its subtype (`getService`).
    func firstService(_ type: ServiceType) -> Service? {
        services.first { $0.type.uuid == type.uuid }
    }

    func services(_ type: ServiceType) -> [Service] {
        services.filter { $0.type.uuid == type.uuid }
    }

    /// The service of this type and subtype, created when missing with a Name, and a Configured Name when
    /// the service type has one (`acquireService`). `created` runs for a new service only.
    @discardableResult
    func acquire(_ type: ServiceType, name: String? = nil, subtype: String? = nil, optional: [CharacteristicType] = [], extra: [Characteristic] = [],
                 isPrimary: Bool = false, created: ((Service) -> Void)? = nil) -> Service {
        if let existing = service(type, subtype: subtype) {
            if existing.isPrimary != isPrimary, isPrimary {
                return replace(existing, isPrimary: true)
            }
            return existing
        }
        let serviceName = sanitizeName(name ?? self.name).nonEmpty ?? self.name
        var extras = extra
        if type.optional.contains(where: { $0.uuid == CharacteristicType.configuredName.uuid }), !extras.contains(where: { $0.type.uuid == CharacteristicType.configuredName.uuid }) {
            extras.append(Characteristic(.configuredName, value: .string(serviceName)))
        }
        let service = Service(type, name: serviceName, subtype: subtype, optional: optional, extra: extras, isPrimary: isPrimary)
        services.append(service)
        isDirty = true
        created?(service)
        return service
    }

    /// Keeps the service when `enabled`, removes it otherwise (`validService`). Returns `enabled`.
    @discardableResult
    func valid(_ type: ServiceType, _ enabled: Bool, subtype: String? = nil) -> Bool {
        if !enabled, let existing = service(type, subtype: subtype) { remove(existing) }
        return enabled
    }

    func remove(_ service: Service) {
        let before = services.count
        services.removeAll { $0 === service }
        if services.count != before { isDirty = true }
    }

    /// Rebuilds a service with a different set of optional characteristics, keeping its values: Homeswift
    /// services cannot gain or lose characteristics in place (`addCharacteristic`/`removeCharacteristic`).
    @discardableResult
    func reshape(_ service: Service, adding: [CharacteristicType] = [], removing: [CharacteristicType] = []) -> Service {
        let current = Set(service.characteristics.map(\.type.uuid))
        let toAdd = adding.filter { !current.contains($0.uuid) }
        let toRemove = removing.filter { type in current.contains(type.uuid) && !service.type.required.contains { $0.uuid == type.uuid } }
        guard !toAdd.isEmpty || !toRemove.isEmpty else { return service }
        let removed = Set(toRemove.map(\.uuid))
        let required = Set(service.type.required.map(\.uuid))
        let kept = service.characteristics.filter { !removed.contains($0.type.uuid) && !required.contains($0.type.uuid) && $0.type.uuid != CharacteristicType.name.uuid }
        let rebuilt = Service(service.type, name: service[.name]?.value.stringValue, subtype: service.subtype, optional: toAdd, extra: kept, isPrimary: service.isPrimary)
        for characteristic in service.characteristics where required.contains(characteristic.type.uuid) {
            rebuilt[characteristic.type]?.value = characteristic.value
        }
        swap(service, for: rebuilt)
        return rebuilt
    }

    private func replace(_ service: Service, isPrimary: Bool) -> Service {
        let requiredTypes = Set(service.type.required.map(\.uuid))
        let kept = service.characteristics.filter { $0.type.uuid != CharacteristicType.name.uuid && !requiredTypes.contains($0.type.uuid) }
        let rebuilt = Service(service.type, name: service[.name]?.value.stringValue, subtype: service.subtype, extra: kept, isPrimary: isPrimary)
        for characteristic in service.characteristics where service.type.required.contains(where: { $0.uuid == characteristic.type.uuid }) {
            rebuilt[characteristic.type]?.value = characteristic.value
        }
        swap(service, for: rebuilt)
        return rebuilt
    }

    private func swap(_ old: Service, for new: Service) {
        guard let index = services.firstIndex(where: { $0 === old }) else { return }
        services[index] = new
        isDirty = true
    }

    /// Puts the accessory on the bridge (or on its own server when standalone) when its shape changed.
    func publish() async {
        guard isDirty else { return }
        let cameraServices = cameraController?.services ?? []
        let accessory = Accessory(
            id: id, name: name, manufacturer: manufacturer, model: model, serialNumber: serialNumber, firmwareRevision: firmwareRevision,
            category: category, services: services.filter { service in !cameraServices.contains { $0 === service } })
        if let cameraController { accessory.configureController(cameraController) }
        do {
            if isStandalone {
                try await host.publishExternal(accessory)
            } else {
                try host.add(accessory)
            }
            published = accessory
            isDirty = false
        } catch {
            log.error("Unable to publish \(name) to HomeKit: \(error).")
        }
    }

    /// Restores a controller's saved state and saves its changes, under this accessory (`configureController`).
    func configureControllerState(_ controller: some SerializableController) {
        host.configureController(controller, accessoryID: id)
    }

    /// Takes the accessory off HomeKit.
    func unpublish() async {
        guard host.accessoryIDs.contains(id) else { return }
        do {
            try await host.remove(id: id)
        } catch {
            log.warning("Unable to remove \(name) from HomeKit: \(error).")
        }
        published = nil
        isDirty = true
    }
}

/// Where accessories go: the plugin's context, or a fake in tests.
protocol ProtectAccessoryHost: Sendable {
    func add(_ accessory: Accessory) throws
    func publishExternal(_ accessory: Accessory) async throws
    func remove(id: String) async throws
    var accessoryIDs: [String] { get }
    func isExternal(id: String) -> Bool
    func cachedName(id: String) -> String?
    func configureController(_ controller: some SerializableController, accessoryID: String)
}

extension PluginContext: ProtectAccessoryHost {
    var accessoryIDs: [String] { accessories.map(\.id) }

    func cachedName(id: String) -> String? { accessory(id: id)?.name }
}
