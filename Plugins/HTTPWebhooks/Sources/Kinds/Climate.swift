import Foundation
import Homeswift
import HomeswiftPlugin

/// `co2sensors[]`: a Carbon Dioxide Sensor set by `value=<ppm>`, abnormal above `co2_peak_level` (1200 by default).
final class CarbonDioxideAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    let peak: Double
    private let level: Characteristic
    private let detected: Characteristic
    private let environment: KindEnvironment
    private var levelKey: String { "http-webhook-carbon-dioxide-level-\(id)" }
    private var detectedKey: String { "http-webhook-carbon-dioxide-detected-\(id)" }

    init(id: String, name: String, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.environment = environment
        peak = entry.number("co2_peak_level", default: 1200)
        let service = Service(.carbonDioxideSensor, name: name, optional: [.carbonDioxideLevel], isPrimary: true)
        level = service.characteristic(.carbonDioxideLevel)
        detected = service.characteristic(.carbonDioxideDetected)
        accessory = Accessory(
            id: HTTPWebhooksPlugin.accessoryID(name: name), name: name, manufacturer: HTTPWebhooksPlugin.manufacturer,
            model: "HttpWebHookCarbonDioxideSensorAccessory-\(name)", serialNumber: "HttpWebHookCarbonDioxideSensorAccessory-\(id)", category: .sensor,
            services: [service])
        level.show(environment.store.number(levelKey, default: 0))
        detected.show(environment.store.bool(detectedKey) ? 1 : 0)
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        guard let text = query["value"] else { return .success(["state": .number(environment.store.number(levelKey, default: 0))]) }
        guard let value = WebhookNumber.parse(text) else {
            environment.logger.warning("\(name): ignoring value \"\(text)\", which is not a number")
            return .success
        }
        let abnormal = value > peak
        environment.store.set(levelKey, value)
        environment.store.set(detectedKey, abnormal)
        let changed = level.show(value)
        if detected.show(abnormal ? 1 : 0) || changed {
            environment.logger.info("\(name): changing HomeKit carbon dioxide level to \(Format.number(value))\(abnormal ? ", abnormal" : "")")
        }
        return .success
    }
}

/// `valves[]`: a Valve of the entry's `type` (`generic valve`, `irrigation`, `shower head`, `water faucet`). `state`
/// opens or closes it (Active and In Use), `statusFault` flags a fault; HomeKit's Active calls `on_*` or `off_*`.
final class ValveAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    private let active: Characteristic
    private let inUse: Characteristic
    private let fault: Characteristic
    private let environment: KindEnvironment
    private var key: String { "http-webhook-\(id)" }
    private var faultKey: String { "http-webhook-\(id)-statusFault" }

    static let types = ["generic valve": 0, "irrigation": 1, "shower head": 2, "water faucet": 3]

    init(id: String, name: String, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.environment = environment
        let type = entry.string("type").flatMap { Self.types[$0] } ?? 0
        let service = Service(.valve, name: name, optional: [.statusFault], extra: [Characteristic(.valveType, value: .int(type))], isPrimary: true)
        active = service.characteristic(.active)
        inUse = service.characteristic(.inUse)
        fault = service.characteristic(.statusFault)
        let category: AccessoryCategory = switch type {
        case 1: .sprinkler
        case 3: .faucet
        default: .showerHead
        }
        accessory = Accessory(
            id: HTTPWebhooksPlugin.accessoryID(name: name), name: name, manufacturer: HTTPWebhooksPlugin.manufacturer,
            model: "HttpWebHookValveAccessory-\(name)", serialNumber: "HttpWebHookValveAccessory-\(id)", category: category, services: [service])
        let open = environment.store.number(key, default: 0)
        active.show(open)
        inUse.show(open)
        fault.show(environment.store.number(faultKey, default: 0))

        let calls = (on: entry.call("on"), off: entry.call("off"))
        let (key, inUse) = (key, inUse)
        active.onWrite { [environment, name] value in
            let open = value.intValue == 1
            environment.logger.info("\(name): \(open ? "opening" : "closing") valve \(id)")
            try await environment.send(open ? calls.on : calls.off, name: name)
            environment.store.set(key, open ? 1 : 0)
            inUse.show(open ? 1 : 0)
        }
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        let state = query.nonEmpty("state")
        let statusFault = query.nonEmpty("statusFault")
        guard state != nil || statusFault != nil else {
            return .success(["state": .number(environment.store.number(key, default: 0)), "statusFault": .number(environment.store.number(faultKey, default: 0))])
        }
        if let state {
            let open: Double = state == "true" ? 1 : 0
            environment.store.set(key, open)
            let changed = active.show(open)
            if inUse.show(open) || changed { environment.logger.info("\(name): changing HomeKit Active for valve to \(Format.number(open))") }
        }
        if let statusFault {
            let faulty: Double = statusFault == "true" ? 1 : 0
            environment.store.set(faultKey, faulty)
            if fault.show(faulty) { environment.logger.info("\(name): changing HomeKit Status Fault for valve to \(Format.number(faulty))") }
        }
        return .success
    }
}
