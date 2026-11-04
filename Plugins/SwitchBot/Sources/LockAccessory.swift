import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// The Smart Lock family: Lock Mechanism (a security control), its door's Contact Sensor and the Latch switch, which
/// unlocks at once (a security control too).
final class LockAccessory: DeviceAccessory, @unchecked Sendable {
    let mechanism: Service
    let contact: Service?
    let latch: Service?
    let battery: Service
    private var target = 1
    private var reported: Int?

    override var category: AccessoryCategory { .doorLock }

    override init(info: DeviceInfo, link: DeviceLink, debounce: Duration, logger: Logger) {
        mechanism = Service(.lockMechanism, name: info.name, isPrimary: true)
        contact = info.options.flag("hide_contactsensor") ? nil : Service(.contactSensor, name: "\(info.name) Contact Sensor")
        latch = info.options.bool("activate_latchbutton") == false ? nil : Service(.switch, name: "\(info.name) Latch", subtype: "Latch")
        battery = Self.batteryService(info.name)
        super.init(info: info, link: link, debounce: debounce, logger: logger)
        adopt([mechanism, contact, latch, battery])
        mechanism.characteristic(.lockCurrentState).value = .int(1)
        mechanism.characteristic(.lockTargetState).value = .int(1)
        mechanism.characteristic(.lockTargetState).onWrite { [weak self] value in
            try await self?.write { self?.target = value.intValue == 0 ? 0 : 1 }
        }
        if let latch {
            let on = latch.characteristic(.on).securityControl()
            on.onWrite { [weak self] value in
                guard let self, value.boolValue == true else { return }
                try await send([Command(command: "unlock")])
                on.revert(to: .bool(false), after: .milliseconds(500))
            }
        }
    }

    override func show(_ status: [String: JSONValue], webhook: Bool) {
        showBattery(status, on: battery)
        if let state = status["lockState"]?.stringValue?.lowercased() {
            // Jammed shows as jammed (4.x shows it unlocked); the target stays where it was.
            let current = state == "locked" ? 1 : state == "jammed" ? 2 : 0
            mechanism.characteristic(.lockCurrentState).value = .int(current)
            if current != 2 {
                lock.withLock {
                    target = current
                    reported = current
                }
                mechanism.characteristic(.lockTargetState).value = .int(current)
            }
        }
        if let door = status["doorState"]?.stringValue {
            contact?.characteristic(.contactSensorState).value = .int(door == "opened" || door == "open" ? 1 : 0)
        }
    }

    override func showOffline() {
        mechanism.characteristic(.lockCurrentState).value = .int(1)
        mechanism.characteristic(.lockTargetState).value = .int(1)
        contact?.characteristic(.contactSensorState).value = .int(0)
    }

    override func push() async throws {
        let (target, reported) = lock.withLock { (self.target, self.reported) }
        guard target != reported else { return }
        if try await send([Command(command: target == 1 ? "lock" : "unlock")]) { lock.withLock { self.reported = target } }
    }
}
