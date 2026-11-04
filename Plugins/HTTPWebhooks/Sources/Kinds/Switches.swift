import Foundation
import Homeswift
import HomeswiftPlugin

/// `switches[]` and `outlets[]`: On, set by `state=true|false`, and for an outlet Outlet In Use (`stateOutletInUse`). A
/// write from HomeKit calls `on_*` or `off_*`.
final class SwitchAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    let isOutlet: Bool
    private let on: Characteristic
    private let inUse: Characteristic?
    private let environment: KindEnvironment
    private var key: String { "http-webhook-\(id)" }
    private var inUseKey: String { "http-webhook-\(id)-inUse" }

    init(id: String, name: String, outlet: Bool, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.isOutlet = outlet
        self.environment = environment
        let service = Service(outlet ? .outlet : .switch, name: name, optional: outlet ? [.outletInUse] : [], isPrimary: true)
        on = service.characteristic(.on)
        inUse = outlet ? service.characteristic(.outletInUse) : nil
        accessory = HTTPWebhooksPlugin.accessory(outlet ? "Outlet" : "Switch", id: id, name: name, category: outlet ? .outlet : .switch, services: [service])
        on.show(environment.store.bool(key))
        inUse?.show(environment.store.bool(inUseKey))
        let calls = (on: entry.call("on"), off: entry.call("off"))
        let key = key
        on.onWrite { [environment, name] value in
            let state = value.boolValue ?? false
            environment.logger.info("\(name): switching \(state ? "on" : "off") for \(id)")
            try await environment.send(state ? calls.on : calls.off, name: name)
            environment.store.set(key, state)
        }
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        let state = query.nonEmpty("state")
        let inUseState = isOutlet ? query.nonEmpty("stateOutletInUse") : nil
        guard state != nil || inUseState != nil else {
            var reply = WebhookReply.success(["state": .bool(environment.store.bool(key))])
            if isOutlet { reply.fields.append(("stateOutletInUse", .bool(environment.store.bool(inUseKey)))) }
            return reply
        }
        if let state {
            let on = state == "true"
            environment.store.set(key, on)
            if self.on.show(on) { environment.logger.info("\(name): changing HomeKit state for \(isOutlet ? "outlet" : "switch") to \(on)") }
        }
        if let inUseState, let inUse {
            let used = inUseState == "true"
            environment.store.set(inUseKey, used)
            if inUse.show(used) { environment.logger.info("\(name): changing HomeKit Outlet In Use to \(used)") }
        }
        return .success
    }
}

/// `pushbuttons[]`: a switch that turns itself off a second after it was turned on, by HomeKit (calling `push_*`) or by
/// `state=true`. It keeps no state.
final class PushButtonAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    private let on: Characteristic
    private let environment: KindEnvironment

    init(id: String, name: String, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.environment = environment
        let service = Service(.switch, name: name, isPrimary: true)
        on = service.characteristic(.on)
        accessory = HTTPWebhooksPlugin.accessory("PushButton", id: id, name: name, category: .switch, services: [service])
        let push = entry.call("push")
        let on = on
        on.onWrite { [environment, name] value in
            guard value.boolValue == true else { return }
            environment.logger.info("\(name): pushing button \(id)")
            // Off again a second after the call ends, whether it worked or not.
            defer { environment.tasks.add(on.revert(to: .bool(false), after: environment.timing.pushButtonRelease)) }
            try await environment.send(push, name: name)
        }
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        guard query.isTrue("state") else { return .success }
        environment.logger.info("\(name): changing HomeKit state for push button to true")
        on.value = .bool(true)
        environment.tasks.add(on.revert(to: .bool(false), after: environment.timing.pushButtonRelease))
        return .success
    }
}
