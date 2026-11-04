import Foundation
import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// `sensors[]`: a contact, motion, occupancy or smoke sensor set by `state=true|false`, or a temperature, humidity, air
/// quality, light or leak sensor set by `value=<number>`. Contact, motion and occupancy sensors can go back to rest on
/// their own (`autoRelease`).
final class SensorAccessory: WebhookAccessory {
    enum Kind: String, CaseIterable, Sendable {
        case contact, motion, occupancy, smoke, temperature, humidity, airquality, light, leak

        var service: ServiceType {
            switch self {
            case .contact: .contactSensor
            case .motion: .motionSensor
            case .occupancy: .occupancySensor
            case .smoke: .smokeSensor
            case .temperature: .temperatureSensor
            case .humidity: .humiditySensor
            case .airquality: .airQualitySensor
            case .light: .lightSensor
            case .leak: .leakSensor
            }
        }

        var characteristic: CharacteristicType {
            switch self {
            case .contact: .contactSensorState
            case .motion: .motionDetected
            case .occupancy: .occupancyDetected
            case .smoke: .smokeDetected
            case .temperature: .currentTemperature.with(minValue: -100, maxValue: 140)
            case .humidity: .currentRelativeHumidity
            case .airquality: .airQuality
            case .light: .currentAmbientLightLevel
            case .leak: .leakDetected
            }
        }

        /// Set by `state` (a boolean) rather than `value` (a number).
        var isBoolean: Bool { [.contact, .motion, .occupancy, .smoke].contains(self) }
        var releases: Bool { [.contact, .motion, .occupancy].contains(self) }
        /// Where an auto release puts it: a contact sensor closed (`true`), motion and occupancy not detected.
        var resting: Bool { self == .contact }

        var label: String {
            switch self {
            case .contact: "Contact sensor"
            case .motion: "Motion sensor"
            case .occupancy: "Occupancy sensor"
            case .smoke: "Smoke sensor"
            case .temperature: "Temperature sensor"
            case .humidity: "Humidity sensor"
            case .airquality: "Air quality sensor"
            case .light: "Light sensor"
            case .leak: "Leak sensor"
            }
        }
    }

    let id: String
    let name: String
    let kind: Kind
    let accessory: Accessory
    private let characteristic: Characteristic
    private let autoRelease: Duration?
    private let environment: KindEnvironment
    private let releaseTask = NIOLockedValueBox<Task<Void, Never>?>(nil)
    private var key: String { "http-webhook-\(id)" }

    init(id: String, name: String, kind: Kind, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.kind = kind
        self.environment = environment
        let service = Service(kind.service, name: name, optional: [kind.characteristic], isPrimary: true)
        characteristic = service.characteristic(kind.characteristic)
        let releaseTime = entry.number("autoReleaseTime", default: 5000)
        autoRelease = kind.releases && entry.flag("autoRelease", default: false)
            ? .milliseconds(Int(saturating: max(0, releaseTime) * environment.timing.autoReleaseScale) ?? 5000) : nil
        accessory = Accessory(
            id: HTTPWebhooksPlugin.accessoryID(name: name), name: name, manufacturer: HTTPWebhooksPlugin.manufacturer,
            model: "HttpWebHookSensorAccessory-\(name)", serialNumber: "HttpWebHookSensorAccessory-\(id)", category: .sensor, services: [service])
        if kind.isBoolean {
            show(environment.store.bool(key))
        } else {
            show(number: environment.store.number(key, default: 0))
        }
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        if kind.isBoolean {
            guard let state = query["state"] else { return .success(["state": .bool(environment.store.bool(key))]) }
            let detected = state == "true"
            environment.store.set(key, detected)
            if show(detected) { environment.logger.info("\(name): changing HomeKit state for \(kind.label.lowercased()) to \(detected)") }
            if let autoRelease { scheduleRelease(after: autoRelease, triggered: detected != kind.resting) }
            return .success
        }
        guard let text = query["value"] else { return .success(["state": .number(environment.store.number(key, default: 0))]) }
        guard let value = WebhookNumber.parse(text) else {
            environment.logger.warning("\(name): ignoring value \"\(text)\", which is not a number")
            return .success
        }
        environment.store.set(key, value)
        if show(number: value) { environment.logger.info("\(name): changing HomeKit value for \(kind.label.lowercased()) to \(Format.number(value))") }
        return .success
    }

    /// Shows the boolean state on the kind's characteristic: contact detected is 0, occupancy and smoke detected 1.
    @discardableResult
    private func show(_ detected: Bool) -> Bool {
        switch kind {
        case .motion: characteristic.show(detected)
        case .contact: characteristic.show(detected ? 0 : 1)
        default: characteristic.show(detected ? 1 : 0)
        }
    }

    @discardableResult
    private func show(number value: Double) -> Bool {
        // A light sensor's lowest level is HAP's minimum, 0.0001 lux.
        characteristic.show(kind == .light && value <= 0 ? 0.0001 : value)
    }

    /// A trigger (re)starts the release; the resting state cancels a release in progress.
    private func scheduleRelease(after delay: Duration, triggered: Bool) {
        let resting = kind.resting
        let task = triggered
            ? environment.tasks.add { [weak self] in
                guard (try? await Task.sleep(for: delay)) != nil, let self else { return }
                self.environment.store.set(self.key, resting)
                if self.show(resting) { self.environment.logger.info("\(self.name): auto release, changing HomeKit state to \(resting)") }
            } : nil
        releaseTask.withLockedValue { current in
            current?.cancel()
            current = task
        }
    }
}
