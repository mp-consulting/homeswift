import Foundation
import Homeswift
import HomeswiftPlugin

/// The services of a hub as they are built: on its own accessory, or on a child accessory of their own when a
/// `SeparateAccessory` option moves them (`access-hub-services.ts`).
struct Built: @unchecked Sendable {
    var main: Accessory?
    /// Child accessories by group: `AccessMethods`, `Doorbell`, or a contact sensor's subtype.
    var children: [String: Accessory] = [:]
    var lock: Service?
    var garage: Service?
    var sideLock: Service?
    var doorbell: Service?
    var contact: [AccessReservedName: Service] = [:]
    var switches: [AccessReservedName: Service] = [:]
}

extension AccessHub {
    /// The door as a lock or a garage door opener: UA Gate is a garage door unless `Hub.Door.UseLock`, the others
    /// locks unless `Hub.Door.UseGarageOpener`.
    var doorServiceType: DeviceCatalogEntry.DoorService {
        if catalog.defaultDoorService == .garageDoorOpener { return hasFeature("Hub.Door.UseLock") ? .lock : .garageDoorOpener }
        return hasFeature("Hub.Door.UseGarageOpener") ? .garageDoorOpener : .lock
    }

    func childId(_ group: String) -> String { "\(id).\(group)" }

    /// Builds the accessories from the hints and the state, and puts them in HomeKit. Services keep the names
    /// HomeKit has for them (renamed with the device when its name changes); the aids and iids stay.
    func rebuild() async {
        let context = environment.context
        let previousName = context.accessory(id: id)?.name
        var built = Built()
        var mainServices: [Service] = []
        var groups: [String: (name: String, services: [Service])] = [:]
        let online = uda.isOnline ?? false
        let revertDelay = environment.timing.revert

        /// The name a service already has in HomeKit, renamed along with the device; else `fallback`.
        func name(_ fallback: String, _ type: ServiceType, _ subtype: String?, on host: String) -> String {
            guard let service = context.accessory(id: host)?.services.first(where: { $0.type.uuid == type.uuid && $0.subtype == subtype }),
                let existing = service[.configuredName]?.value.stringValue ?? service[.name]?.value.stringValue, !existing.isEmpty
            else { return AccessSettings.sanitizeName(fallback) }
            if let previousName, previousName != accessoryName, existing.hasPrefix(previousName) {
                return AccessSettings.sanitizeName(accessoryName + existing.dropFirst(previousName.count))
            }
            return existing
        }

        func place(_ service: Service, group: String?, childName: String) {
            if let group {
                groups[group, default: (AccessSettings.sanitizeName(childName), [])].services.append(service)
            } else {
                mainServices.append(service)
            }
        }

        func named(_ service: Service, _ name: String) -> Service {
            service[.name]?.value = .string(name)
            service[.configuredName]?.value = .string(name)
            return service
        }

        // Access method switches, for readers; on one accessory of their own when asked and there is one.
        let methods = Self.accessMethods.filter { has(capability: "is_reader") && uda.has(anyCapability: $0.capabilities) && hasFeature($0.option) }
        let methodsGroup = hints.separateAccessMethods && !methods.isEmpty ? Self.accessoryGroupAccessMethods : nil
        for method in methods {
            let host = methodsGroup.map(childId) ?? id
            let label = name("\(accessoryName) \(method.name)", .switch, method.subtype.rawValue, on: host)
            let service = named(Service(.switch, name: label, subtype: method.subtype.rawValue, optional: [.configuredName]), label)
            service.characteristic(.on).value = .bool(uda.config(method.key) == "yes")
            let on = service.characteristic(.on)
            on.onWrite { [weak self] value in
                guard let self else { return }
                let wanted = value.boolValue ?? false
                if !(await self.setAccessMethod(method, on: wanted)) {
                    await self.accessMethodFailed(method, wanted: wanted, characteristic: on)
                }
            }
            built.switches[method.subtype] = service
            place(service, group: methodsGroup, childName: "\(accessoryName) Access Methods")
        }

        // Terminal inputs, before the door: a garage door opener reads the DPS.
        for input in SensorInput.allCases {
            let reserved = input.reservedName
            let wired = hints.hasWiring(input)
            let group = wired && hints.separateSensors ? reserved.rawValue : nil
            guard wired else { continue }
            let host = group.map(childId) ?? id
            let label = name("\(accessoryName) \(input.label)", .contactSensor, reserved.rawValue, on: host)
            let service = contactSensor(label, reserved, state: hubInputState(input), online: online)
            built.contact[reserved] = service
            place(service, group: group, childName: "\(accessoryName) \(input.label)")
        }
        if hints.hasSideDoor, hints.hasWiringSideDoorDps {
            let reserved = AccessReservedName.contactDPSSide
            let group = hints.separateSensors ? reserved.rawValue : nil
            let host = group.map(childId) ?? id
            let syncedName = sideDoorName.flatMap { hints.syncName ? AccessSettings.sanitizeName($0) + " Door Position Sensor" : nil }
            let label = syncedName ?? name("\(accessoryName) Side Door Position Sensor", .contactSensor, reserved.rawValue, on: host)
            let service = contactSensor(label, reserved, state: sideDpsBacking, online: online)
            built.contact[reserved] = service
            place(service, group: group, childName: syncedName ?? "\(accessoryName) Side Door Position Sensor")
        }

        // The door, the primary service unless the doorbell is on the same accessory.
        let doorbellOn = has(capability: "door_bell") && hasFeature("Hub.Doorbell")
        let doorbellTriggerOn = has(capability: "door_bell") && hasFeature("Hub.Doorbell.Trigger")
        let doorbellGroup = hints.separateDoorbell && (doorbellOn || doorbellTriggerOn) ? Self.accessoryGroupDoorbell : nil
        let doorbellOnMain = doorbellOn && doorbellGroup == nil
        if has(capability: "is_hub") {
            if doorServiceType == .garageDoorOpener {
                let service = named(Service(.garageDoorOpener, name: accessoryName, optional: [.configuredName], isPrimary: !doorbellOnMain), accessoryName)
                configureGarageDoor(service)
                built.garage = service
                mainServices.append(service)
            } else {
                let service = named(Service(.lockMechanism, name: accessoryName, optional: [.configuredName], isPrimary: !doorbellOnMain), accessoryName)
                configureLock(service, side: false)
                built.lock = service
                mainServices.append(service)
            }
            if hasFeature("Hub.Lock.Trigger") {
                let service = trigger("\(accessoryName) Lock Trigger", .lockTrigger, side: false)
                built.switches[.lockTrigger] = service
                mainServices.append(service)
            }
        }
        if hints.hasSideDoor {
            let label = sideDoorName.flatMap { hints.syncName ? AccessSettings.sanitizeName($0) : nil } ?? "\(accessoryName) Side Door"
            let service = named(Service(.lockMechanism, name: label, subtype: AccessReservedName.lockDoorSide.rawValue, optional: [.configuredName]), label)
            configureLock(service, side: true)
            built.sideLock = service
            mainServices.append(service)
            if hasFeature("Hub.SideDoor.Lock.Trigger") {
                let triggerName = sideDoorName.flatMap { hints.syncName ? AccessSettings.sanitizeName($0) + " Lock Trigger" : nil } ?? "\(accessoryName) Side Door Lock Trigger"
                let service = trigger(triggerName, .lockDoorSideTrigger, side: true)
                built.switches[.lockDoorSideTrigger] = service
                mainServices.append(service)
            }
        }

        // The doorbell and its trigger travel together.
        if doorbellOn {
            let host = doorbellGroup.map(childId) ?? id
            let label = name(accessoryName, .doorbell, nil, on: host)
            let service = Service(.doorbell, name: label, isPrimary: true)
            built.doorbell = service
            place(service, group: doorbellGroup, childName: "\(accessoryName) Doorbell")
        }
        if doorbellTriggerOn {
            let label = AccessSettings.sanitizeName("\(accessoryName) Doorbell Trigger")
            let service = named(Service(.switch, name: label, subtype: AccessReservedName.doorbellTrigger.rawValue, optional: [.configuredName]), label)
            let on = service.characteristic(.on)
            on.value = .bool(doorbellRingRequestId != nil)
            // A ring cannot be started from HomeKit: the switch goes back.
            on.onWrite { [weak self] _ in
                guard let self else { return }
                on.revert(after: revertDelay) { .bool(await self.doorbellRingRequestId != nil) }
            }
            built.switches[.doorbellTrigger] = service
            place(service, group: doorbellGroup, childName: "\(accessoryName) Doorbell")
        }

        // The accessories.
        let model = uda.displayModel ?? uda.model ?? "UniFi Access"
        let firmware = uda.firmware.map(AccessSettings.firmwareRevision) ?? "1.0.0"
        let serial = AccessSettings.normalizeMac(uda.mac)
        let category: AccessoryCategory = built.garage != nil ? .garageDoorOpener : has(capability: "is_hub") ? .doorLock : .switch
        let main = Accessory(
            id: id, name: accessoryName, manufacturer: "Ubiquiti Inc.", model: model, serialNumber: serial, firmwareRevision: firmware, category: category,
            services: mainServices)
        built.main = main
        var accessories = [main]
        for (group, child) in groups.sorted(by: { $0.key < $1.key }) {
            let accessory = Accessory(
                id: childId(group), name: child.name, manufacturer: "Ubiquiti Inc.", model: model, serialNumber: "\(serial)-\(group)", firmwareRevision: firmware,
                category: group == Self.accessoryGroupDoorbell ? .videoDoorbell : group == Self.accessoryGroupAccessMethods ? .switch : .sensor,
                services: child.services)
            built.children[group] = accessory
            accessories.append(accessory)
        }
        let previousChildren = Set(self.built.children.keys)
        for group in groups.keys where !previousChildren.contains(group) {
            logger.info("\(prefix)Adding \(groups[group]?.name ?? group) to HomeKit as a separate accessory.")
        }
        self.built = built
        await environment.publish(accessories)
    }

    private func contactSensor(_ label: String, _ reserved: AccessReservedName, state: Int, online: Bool) -> Service {
        let tamper = has(capability: "tamper_proofing") ? uda.config("tamper_event") : nil
        var optional: [CharacteristicType] = [.configuredName, .statusActive]
        if tamper != nil, !(tamper?.isEmpty ?? true) { optional.append(.statusTampered) }
        let service = Service(.contactSensor, name: label, subtype: reserved.rawValue, optional: optional)
        service[.configuredName]?.value = .string(label)
        service.characteristic(.contactSensorState).value = .int(state)
        service.characteristic(.statusActive).value = .bool(online)
        if let tamper, !tamper.isEmpty { service[.statusTampered]?.value = .int(tamper == "true" ? 1 : 0) }
        return service
    }

    private func configureLock(_ service: Service, side: Bool) {
        let state = side ? sideLockBacking : lockBacking
        service.characteristic(.lockCurrentState).value = .int(state)
        service.characteristic(.lockTargetState).value = .int(Self.isLocked(state) ? HK.lockSecured : HK.lockUnsecured)
        let target = service.characteristic(.lockTargetState)
        let current = service.characteristic(.lockCurrentState)
        target.onWrite { [weak self] value in
            await self?.lockTargetWritten(value, side: side, target: target, current: current)
        }
    }

    private func configureGarageDoor(_ service: Service) {
        let current = service.characteristic(.currentDoorState)
        let target = service.characteristic(.targetDoorState)
        let state = doorState()
        current.value = .int(state)
        target.value = .int(state == HK.doorClosed || state == HK.doorClosing ? HK.doorClosed : HK.doorOpen)
        service.characteristic(.obstructionDetected).value = .bool(false)
        current.onRead { [weak self] in .int(await self?.doorState() ?? HK.doorClosed) }
        target.onWrite { [weak self] value in
            await self?.garageTargetWritten(value, target: target, current: current)
        }
    }

    private func trigger(_ label: String, _ reserved: AccessReservedName, side: Bool) -> Service {
        let label = AccessSettings.sanitizeName(label)
        let revertDelay = environment.timing.revert
        let service = Service(.switch, name: label, subtype: reserved.rawValue, optional: [.configuredName])
        service[.configuredName]?.value = .string(label)
        // On unlocks the door: the bridge's own surfaces (MCP, the Assistant, the web UI) confirm it like a lock.
        let on = service.characteristic(.on).securityControl()
        on.value = .bool(!Self.isLocked(side ? sideLockBacking : lockBacking))
        // On is unlocked, off locked.
        on.onWrite { [weak self] value in
            guard let self else { return }
            let wanted = value.boolValue ?? false
            if !(await self.doorLockCommand(locking: !wanted, side: side)) {
                on.revert(to: .bool(!wanted), after: revertDelay)
            }
        }
        return service
    }

    // MARK: Writes from HomeKit

    func lockTargetWritten(_ value: HAPValue, side: Bool, target: Characteristic, current: Characteristic) async {
        let state = side ? sideLockBacking : lockBacking
        let wantsLocked = value.intValue == HK.lockSecured
        let locked = Self.isLocked(state)
        // Already there: a sync, not a command.
        guard wantsLocked != locked else { return }
        if !(await doorLockCommand(locking: wantsLocked, side: side)) {
            target.revert(to: .int(locked ? HK.lockSecured : HK.lockUnsecured), after: environment.timing.revert)
        }
        current.value = .int(side ? sideLockBacking : lockBacking)
    }

    func garageTargetWritten(_ value: HAPValue, target: Characteristic, current: Characteristic) async {
        let close = value.intValue == HK.doorClosed
        let delay = environment.timing.revert
        let failed = {
            target.revert(to: .int(close ? HK.doorOpen : HK.doorClosed), after: delay)
            // The current state as the gate is then.
            current.revert(after: delay) { .int(await self.doorState()) }
        }
        guard catalog.usesLocationApi else {
            if !(await doorLockCommand(locking: close)) { failed() }
            return
        }
        // UA Gate: one command toggles the motor, so closing a gate that is closed (or closing) would open it.
        if close, [HK.doorClosed, HK.doorClosing].contains(doorState()) {
            logger.debug("\(prefix)The gate is already \(doorState() == HK.doorClosed ? "closed" : "closing"): not triggering it.")
            target.value = .int(HK.doorClosed)
            current.value = .int(doorState())
            return
        }
        // Events right after the command are noise while the gate starts moving.
        gateTransitionUntil = .now + environment.timing.gateCooldown
        if close { beginGateClosing() } else { startGateCycle() }
        if !(await doorLockCommand(locking: false)) {
            gateTransitionUntil = .now
            clearGatePhaseTimers()
            gateDirection = nil
            gateDirectionUntil = .now
            failed()
        }
    }

    func accessMethodFailed(_ method: AccessMethod, wanted: Bool, characteristic: Characteristic) {
        logger.error("\(prefix)Unable to \(wanted ? "activate" : "deactivate") the \(method.name) access method.")
        characteristic.revert(to: .bool(!wanted), after: environment.timing.revert)
    }

    /// Model, serial number and firmware on the accessories in place, after a refresh.
    func refreshInformation() {
        let model = uda.displayModel ?? uda.model
        let serial = AccessSettings.normalizeMac(uda.mac)
        let firmware = uda.firmware.map(AccessSettings.firmwareRevision)
        func update(_ accessory: Accessory, serial: String) {
            if let model { accessory.information[.model]?.value = .string(model) }
            if !uda.mac.isEmpty { accessory.information[.serialNumber]?.value = .string(serial) }
            if let firmware { accessory.information[.firmwareRevision]?.value = .string(firmware) }
        }
        if let main = built.main { update(main, serial: serial) }
        for (group, child) in built.children { update(child, serial: "\(serial)-\(group)") }
    }
}
