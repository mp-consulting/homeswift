import Foundation
import Homeswift
import HomeswiftPlugin

/// The Programmable Switch Event values a button allows, from its `single_press`, `double_press` and `long_press` flags
/// (each on when missing): 0 single, 1 double, 2 long. All three when every flag is off, which HomeKit cannot take.
func pressEvents(_ flags: (single: Bool, double: Bool, long: Bool)) -> [Int] {
    let events = [(0, flags.single), (1, flags.double), (2, flags.long)].filter(\.1).map(\.0)
    return events.isEmpty ? [0, 1, 2] : events
}

func pressFlags(of entry: JSONValue) -> (single: Bool, double: Bool, long: Bool) {
    func flag(_ key: String) -> Bool {
        guard let value = entry[key], !value.isNull else { return true }
        return Loose.truthy(value)
    }
    return (flag("single_press"), flag("double_press"), flag("long_press"))
}

extension CharacteristicType {
    /// Programmable Switch Event limited to `events`.
    static func switchEvent(_ events: [Int]) -> CharacteristicType {
        .programmableSwitchEvent.with(minValue: Double(events.min() ?? 0), maxValue: Double(events.max() ?? 2), validValues: events)
    }
}

/// `doorbells[]`: a Stateless Programmable Switch (`sps`) and a Doorbell (`db`), both rung by `event=0|1|2`, which must
/// be one of the events the entry allows.
final class DoorbellAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    let events: [Int]
    private let switchEvent: Characteristic
    private let doorbellEvent: Characteristic
    private let environment: KindEnvironment

    init(id: String, name: String, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.environment = environment
        let flags = pressFlags(of: entry.json)
        if !flags.single && !flags.double && !flags.long {
            environment.logger.warning("\(name): single_press, double_press and long_press are all off; allowing all three")
        }
        events = pressEvents(flags)
        let programmable = Service(.statelessProgrammableSwitch, name: name, subtype: "sps", optional: [.switchEvent(events)])
        let doorbell = Service(.doorbell, name: name, subtype: "db", optional: [.switchEvent(events)], isPrimary: true)
        switchEvent = programmable.characteristic(.programmableSwitchEvent)
        doorbellEvent = doorbell.characteristic(.programmableSwitchEvent)
        // The doorbell's serial number is the bare id, as the Homebridge plugin has it.
        accessory = HTTPWebhooksPlugin.accessory("Doorbell", id: id, name: name, category: .videoDoorbell, services: [programmable, doorbell], serialNumber: id)
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        guard let text = query.nonEmpty("event") else { return .success }
        guard let event = WebhookNumber.parse(text).flatMap({ Int(exactly: $0) }), events.contains(event) else {
            let allowed = events.map(String.init).joined(separator: ",")
            environment.logger.warning("\(name): event value \(text) is outside of valid values: \(allowed)")
            return WebhookReply(fields: [("error", .string("event value \(text) is outside of valid values: \(allowed)"))])
        }
        environment.logger.info("\(name): ringing the doorbell with event \(event)")
        switchEvent.sendEvent(.int(event))
        doorbellEvent.sendEvent(.int(event))
        return .success
    }
}

/// `statelessswitches[]`: one Stateless Programmable Switch per button, in order (subtypes `0`, `1`...), pressed by
/// `buttonName=<name>&event=0|1|2`.
final class StatelessSwitchAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    /// Each button's name and event characteristic, in order.
    private let buttons: [(name: String, event: Characteristic)]
    private let environment: KindEnvironment

    init(id: String, name: String, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.environment = environment
        var services: [Service] = []
        var buttons: [(String, Characteristic)] = []
        for (index, button) in (entry["buttons"]?.arrayValue ?? []).enumerated() where button.objectValue != nil {
            let buttonName = button["name"]?.stringValue ?? "\(name) \(index + 1)"
            let service = Service(
                .statelessProgrammableSwitch, name: buttonName, subtype: String(index),
                extra: [Characteristic(.switchEvent(pressEvents(pressFlags(of: button)))), Characteristic(.serviceLabelIndex, value: .int(index + 1))],
                isPrimary: index == 0)
            services.append(service)
            buttons.append((buttonName, service.characteristic(.programmableSwitchEvent)))
        }
        self.buttons = buttons
        accessory = HTTPWebhooksPlugin.accessory("StatelessSwitch", id: id, name: name, category: .programmableSwitch, services: services)
    }

    /// Every button of that name gets the event, unchecked against its flags, as the Homebridge plugin does.
    func handle(_ query: WebhookQuery) -> WebhookReply {
        guard let text = query.nonEmpty("event"), let event = WebhookNumber.parse(text).flatMap({ Int(saturating: $0, in: 0...2) }) else { return .success }
        for button in buttons where button.name == query["buttonName"] {
            environment.logger.info("\(name): pressing \(button.name) with event \(event)")
            button.event.sendEvent(.int(event))
        }
        return .success
    }
}
