import Foundation
import Homeswift
import HomeswiftPlugin

/// A valve's run: when it ends, and its timer (section 6.8).
/// The characteristics of a valve its closures share; only its `Thing` touches them.
final class ValveParts: @unchecked Sendable {
    var setDuration: Characteristic?
    var remaining: Characteristic?
    var active: Characteristic?
    var previous = 0
}

/// An irrigation system's Active and its zones'; only its `Thing` touches them.
final class ZoneParts: @unchecked Sendable {
    var system: Characteristic?
    var actives: [Characteristic] = []
    var inUses: [Characteristic] = []
}

final class ValveRun: @unchecked Sendable {
    private let lock = NSLock()
    private var endValue: Date
    private var inUseValue = false
    init(end: Date) { endValue = end }

    /// Read on HomeKit's path too (RemainingDuration), so behind a lock.
    var end: Date {
        get { lock.withLock { endValue } }
        set { lock.withLock { endValue = newValue } }
    }

    var inUse: Bool {
        get { lock.withLock { inUseValue } }
        set { lock.withLock { inUseValue = newValue } }
    }
}

extension Thing {
    // MARK: Valves and irrigation

    /// Active, InUse and the durations of a valve or an irrigation zone. `onActive` and `onInUse` see every change.
    @discardableResult
    func valveCore(
        _ service: ServiceBuilder, _ entry: Entry, suffix: String = "", wantsSetDuration: Bool, wantsRemaining: Bool,
        onActive: ((Bool) -> Void)? = nil, onInUse: ((Bool) -> Void)? = nil
    ) -> (active: Characteristic, inUse: Characteristic) {
        let config = entry.config
        let now = dependencies.now
        let run = ValveRun(end: now())
        let parts = ValveParts()
        let timerKey = "duration-\(ObjectIdentifier(run))"

        func push() {
            parts.remaining?.value = .int(run.inUse ? max(0, Int(run.end.timeIntervalSince(now()))) : 0)
        }
        func startTimer(_ seconds: Int) {
            guard config.flag("durationTimer") else { return }
            after(timerKey, .seconds(seconds)) {
                guard let active = parts.active else { return }
                active.value = .int(0)
                self.publish(config, "setActive", property: "active\(suffix)", Booleans(config).encode(false))
                onActive?(false)
            }
        }
        let active = boolean(service, .active, entry, get: "getActive", set: "setActive", property: "active\(suffix)", autoOff: true) { on in
            if on, parts.setDuration == nil, let off = config.number("turnOffAfterms"), off > 0 {
                run.end = now().addingTimeInterval((off / 1000).rounded(.down))
                push()
            }
            onActive?(on)
        }
        parts.active = active
        let inUse = boolean(service, .inUse, entry, get: "getInUse", property: "inUse\(suffix)") { using in
            run.inUse = using
            if let duration = parts.setDuration?.value.intValue {
                if using {
                    run.end = now().addingTimeInterval(TimeInterval(duration))
                    startTimer(duration)
                } else {
                    self.cancel(timerKey)
                }
            }
            push()
            onInUse?(using)
        }
        if wantsSetDuration {
            let minimum = config.integer("minDuration"), maximum = config.integer("maxDuration")
            var initial = 1200
            if let minimum, initial < minimum { initial = minimum } else if let maximum, initial > maximum { initial = maximum }
            let characteristic = service.add(CharacteristicType.setDuration.with(minValue: minimum.map(Double.init), maxValue: maximum.map(Double.init)), .int(initial))
            parts.setDuration = characteristic
            parts.previous = initial
            let changed: (Int) -> Void = { new in
                defer { parts.previous = new }
                guard run.inUse else { return }
                let current = now()
                let moved = run.end.addingTimeInterval(TimeInterval(new - parts.previous))
                run.end = min(moved, current.addingTimeInterval(TimeInterval(new)))
                if self.isWaiting(timerKey) { startTimer(max(0, Int(run.end.timeIntervalSince(current)))) }
                push()
            }
            if config.has("setDuration") {
                bind(
                    characteristic, config, .int, get: "getDuration", set: "setDuration", property: "setDuration\(suffix)", online: entry.online,
                    received: { value, didChange in if didChange, let number = value.intValue { changed(number) } },
                    wrote: { value in if let number = value.intValue { changed(number) } })
            } else {
                serveReads(characteristic, entry.online)
                onWrite(characteristic) { value in
                    self.logger.debug("\(config.name): duration set to \(value.intValue ?? 0) s")
                    if let number = value.intValue { changed(number) }
                }
            }
        }
        if wantsSetDuration || wantsRemaining {
            let characteristic = service.add(.remainingDuration, .int(0))
            parts.remaining = characteristic
            let online = entry.online
            characteristic.onRead {
                guard online.isOnline else { throw HAPStatusError(.serviceCommunicationFailure) }
                return .int(run.inUse ? max(0, Int(run.end.timeIntervalSince(now()))) : 0)
            }
            if config.has("getRemainingDuration") {
                subscribe(config, "getRemainingDuration", property: "remainingDuration") { [weak characteristic] message in
                    guard let seconds = JS.parseInt(message) else { return }
                    run.end = now().addingTimeInterval(TimeInterval(seconds))
                    characteristic?.value = .int(seconds)
                    if self.isWaiting(timerKey) { startTimer(seconds) }
                }
            }
        }
        return (active, inUse)
    }

    func valve(_ entry: Entry) -> [Service] {
        let config = entry.config
        let service = ServiceBuilder(.valve)
        let types = ["sprinkler": 1, "shower": 2, "faucet": 3]
        service.add(.valveType, .int(types[config.string("valveType") ?? ""] ?? 0))
        let durations = config.has("setDuration") || config.flag("durationTimer")
        valveCore(
            service, entry, wantsSetDuration: durations,
            wantsRemaining: !durations && (config.has("getRemainingDuration") || config.number("turnOffAfterms") != nil))
        status(service, entry)
        return [primary(service, entry)]
    }

    func irrigationSystem(_ entry: Entry) -> [Service] {
        let config = entry.config
        let system = ServiceBuilder(.irrigationSystem)
        system.add(.programMode, .int(0))
        let zoneList = config["zones"]?.arrayValue ?? []
        let parts = ZoneParts()
        let systemInUse = system.add(.inUse)
        let noAutoInactive = config.flag("noAutoInactive")
        let booleans = Booleans(config)
        parts.system = active(system, entry) { on in
            guard !on else { return }
            for (index, zone) in parts.actives.enumerated() where zone.value.intValue == 1 {
                zone.value = .int(0)
                let zoneConfig = self.zoneConfig(config, zoneList[index])
                self.publish(zoneConfig, "setActive", property: "active-\(index + 1)", Booleans(zoneConfig).encode(false))
            }
        }
        boolean(system, .inUse, entry, get: "getInUse", property: "inUse")
        if config.has("getStatusFault") { boolean(system, .statusFault, entry, get: "getStatusFault", property: "statusFault") }
        var zones: [Service] = []
        if !zoneList.isEmpty {
            for (index, zone) in zoneList.enumerated() {
                let number = index + 1
                let zoneEntry = Entry(config: zoneConfig(config, zone), online: entry.online)
                let service = ServiceBuilder(.valve)
                service.add(.valveType, .int(1))
                service.add(.serviceLabelIndex, .int(number))
                service.add(.isConfigured, .int(1))
                let durations = zoneEntry.config.has("setDuration") || config.flag("durationTimer")
                let (active, inUse) = valveCore(
                    service, zoneEntry, suffix: "-\(number)", wantsSetDuration: durations, wantsRemaining: !durations,
                    onActive: { on in
                        guard let systemActive = parts.system else { return }
                        if on, systemActive.value.intValue != 1 {
                            systemActive.value = .int(1)
                            self.publish(config, "setActive", property: "active", booleans.encode(true))
                        } else if !on, !noAutoInactive, systemActive.value.intValue == 1, !parts.actives.contains(where: { $0.value.intValue == 1 }) {
                            systemActive.value = .int(0)
                            self.publish(config, "setActive", property: "active", booleans.encode(false))
                        }
                    },
                    onInUse: { using in
                        if using {
                            systemInUse.value = .int(1)
                        } else if !parts.inUses.contains(where: { $0.value.intValue == 1 }) {
                            systemInUse.value = .int(0)
                        }
                    })
                parts.actives.append(active)
                parts.inUses.append(inUse)
                // The zone's own fault topic, as intended (Gaps 6).
                if zoneEntry.config.has("getStatusFault") { boolean(service, .statusFault, zoneEntry, get: "getStatusFault", property: "statusFault") }
                zones.append(service.build(name: zone["name"]?.stringValue ?? "", subtype: String(number)))
            }
        }
        var services = [primary(system, entry, isPrimary: true, linked: zones)]
        if !zones.isEmpty {
            let label = ServiceBuilder(.serviceLabel)
            label.add(.serviceLabelNamespace, .int(1))
            services.append(label.build(name: nil, subtype: nil))
        }
        return services + zones
    }

    /// A zone's settings: the block's, with the zone's topics, and the block's duration topics where the zone has none.
    func zoneConfig(_ block: Config, _ zone: JSONValue) -> Config {
        var topics = zone["topics"]?.objectValue ?? [:]
        for key in ["setDuration", "getDuration"] where topics[key] == nil { topics[key] = block.topics[key] }
        var values = block.values
        values["topics"] = .object(topics)
        values.removeValue(forKey: "zones")
        return Config(values)
    }

    // MARK: Television

    static let remoteKeys = [
        "VOLUME_UP", "VOLUME_DOWN", "NEXT_TRACK", "PREVIOUS_TRACK", "UP", "DOWN", "LEFT", "RIGHT", "SELECT", "BACK", "EXIT", "PLAY_PAUSE", "12", "13", "14", "INFO",
    ]

    /// DisplayOrder: `01 01 n` for each input, base64.
    static func displayOrder(inputs: Int) -> String {
        Data((0..<inputs).flatMap { [UInt8(1), 1, UInt8(truncatingIfNeeded: $0 + 1)] }).base64EncodedString()
    }

    func television(_ entry: Entry) -> [Service] {
        let config = entry.config
        let tv = ServiceBuilder(.television)
        active(tv, entry)
        tv.add(.configuredName, .string(config.name))
        tv.add(.sleepDiscoveryMode, .int(1))
        let keys = Enumeration(config, keys: ["remoteKeyValues"], default: Self.remoteKeys)
        let remoteKey = tv.add(.remoteKey)
        onWrite(remoteKey) { value in self.publish(config, "setRemoteKey", property: "remoteKey", value.intValue.flatMap(keys.value)) }
        let inputs = config["inputs"]?.arrayValue ?? []
        var sources: [Service] = []
        let identifier = tv.add(.activeIdentifier, .int(0))
        if inputs.isEmpty {
            serveReads(identifier, entry.online)
        } else {
            let values = [JSONValue.string("NONE")] + inputs.enumerated().map { index, input in input["value"] ?? .number(Double(index + 1)) }
            bind(identifier, config, .enumeration(Enumeration(values: values)), get: "getActiveInput", set: "setActiveInput", property: "activeIdentifier", online: entry.online)
            tv.add(.displayOrder, .string(Self.displayOrder(inputs: inputs.count)))
            for (index, input) in inputs.enumerated() {
                let number = index + 1
                let name = input["name"]?.stringValue ?? "Input \(number)"
                let source = ServiceBuilder(.inputSource)
                source.add(.identifier, .int(number))
                source.add(.configuredName, .string(name))
                source.add(.isConfigured, .int(1))
                source.add(.inputSourceType, .int(0))
                source.add(.inputDeviceType, .int(0))
                let current = source.add(.currentVisibilityState, .int(0))
                let target = source.add(.targetVisibilityState, .int(0))
                onWrite(target) { [weak current] value in current?.value = value }
                sources.append(source.build(name: name, subtype: String(number), hidden: true))
            }
        }
        let speaker = ServiceBuilder(.televisionSpeaker)
        speaker.add(.active, .int(1))
        speaker.add(.volumeControlType, .int(3))
        let selector = speaker.add(.volumeSelector)
        onWrite(selector) { value in self.publish(config, "setRemoteKey", property: "remoteKey", value.intValue.flatMap(keys.value)) }
        return [primary(tv, entry, isPrimary: true, linked: sources), speaker.build(name: "Volume", subtype: "volumeService")] + sources
    }

    // MARK: Eve history (section 7)

    func record(_ entry: Entry, _ reading: EveHistory.Entry) { entry.history?.add(reading) }

    /// The Eve history type of an entry with `history` on, or nil for a type without one.
    static func historyKind(_ config: Config) -> EveHistory.Kind? {
        switch config.type {
        case "switch": .switch
        case "outlet": .energy
        case "motionSensor": .motion
        case "contactSensor": .door
        case "temperatureSensor", "humiditySensor", "airPressureSensor", "weatherStation": .weather
        case "airQualitySensor": config.flag("room2") ? .room2 : .room
        default: nil
        }
    }

    func makeHistory(_ config: Config) -> EveHistory? {
        guard config.flag("history"), let kind = Self.historyKind(config) else { return nil }
        var options = config["historyOptions"]?.objectValue ?? [:]
        if let old = config["history"]?.objectValue { options.merge(old) { current, _ in current } }
        let noAutoTimer = options["noAutoTimer"]?.boolValue == true || options["autoTimer"] == .bool(false) || options["mergeInterval"] != nil
        let noAutoRepeat = options["noAutoRepeat"]?.boolValue == true || options["autoRepeat"] == .bool(false)
        let eventKinds = kind == .motion || kind == .door
        let size = options["size"]?.doubleValue.map { max(1, min(Int($0), 100_000)) } ?? 4032
        let file = context.storageDirectory.appendingPathComponent("\(hostLabel)_\(Self.fileSafe(config.name))_persist.json")
        return EveHistory(
            kind, accessoryName: config.name, size: size, averaging: !noAutoTimer && !(eventKinds && noAutoRepeat),
            repeatsLastData: !noAutoRepeat, storageURL: file, now: dependencies.now)
    }

    var hostLabel: String { String(dependencies.hostName.split(separator: ".").first ?? "homeswift") }

    /// A name as part of a file name: no path separators.
    static func fileSafe(_ name: String) -> String {
        String(name.map { $0 == "/" || $0 == "\\" || $0 == ":" ? "_" : $0 })
    }

    struct Counter: Codable {
        var timesOpened: Int?
        var totalConsumption: Double?
        var resetTotal: Int
    }

    func counterFile(_ config: Config) -> JSONFile<Counter> {
        context.jsonFile("\(hostLabel)_\(Self.fileSafe(config.name))_cnt_persist.json", as: Counter.self)
    }

    func nowSeconds() -> Int { Int(dependencies.now().timeIntervalSince1970) }

    /// LastActivation on `service`, set on every change and from the newest entry 5 s after start.
    func lastActivation(_ service: ServiceBuilder, _ history: EveHistory) -> () -> Void {
        let characteristic = service.add(EveCharacteristic.lastActivation, .int(0))
        after("last-activation-\(ObjectIdentifier(history))", .seconds(5)) { [weak history, weak characteristic] in
            guard let history, let initial = history.initialTime, let newest = history.entries().last?.time else { return }
            characteristic?.value = .int(max(0, newest - initial))
        }
        return { [weak history, weak characteristic] in
            guard let initial = history?.initialTime else { return }
            characteristic?.value = .int(max(0, self.nowSeconds() - initial))
        }
    }

    func switchHistory(_ service: ServiceBuilder, _ history: EveHistory) -> (Bool) -> Void {
        let touch = lastActivation(service, history)
        return { on in
            touch()
            history.add(EveHistory.Entry(time: self.dependencies.now(), status: on ? 1 : 0))
        }
    }

    func motionHistory(_ service: ServiceBuilder, _ entry: Entry, _ history: EveHistory) -> (Bool) -> Void {
        let touch = lastActivation(service, history)
        let merge = entry.config["historyOptions"]?["mergeInterval"]?.doubleValue ?? 0
        let key = "motion-clear-\(ObjectIdentifier(history))"
        return { detected in
            touch()
            let now = self.dependencies.now()
            if detected {
                self.cancel(key)
                history.add(EveHistory.Entry(time: now, status: 1))
            } else if merge <= 0 {
                history.add(EveHistory.Entry(time: now, status: 0))
            } else {
                self.after(key, .seconds(merge * 60)) { history.add(EveHistory.Entry(time: now, status: 0)) }
            }
        }
    }

    func doorHistory(_ service: ServiceBuilder, _ entry: Entry, _ history: EveHistory) -> (Bool) -> Void {
        let touch = lastActivation(service, history)
        let file = counterFile(entry.config)
        let counter = Box(file.load() ?? Counter(timesOpened: 0, totalConsumption: nil, resetTotal: nowSeconds() - 978_307_200))
        let opened = service.add(EveCharacteristic.timesOpened, .int(counter.value.timesOpened ?? 0))
        service.add(EveCharacteristic.openDuration, .int(0))
        service.add(EveCharacteristic.closedDuration, .int(0))
        let reset = history.service.characteristic(adding: EveCharacteristic.resetTotal)
        reset.value = .int(counter.value.resetTotal)
        let name = entry.name
        func save() {
            do { try file.save(counter.value) } catch { logger.error("\(name): cannot write file to save counters: \(error)") }
        }
        onWrite(reset) { [weak opened] value in
            counter.value.timesOpened = 0
            counter.value.resetTotal = value.intValue ?? counter.value.resetTotal
            opened?.value = .int(0)
            save()
            self.logger.info("\(name): reset TimesOpened to 0")
        }
        return { [weak opened] open in
            touch()
            history.add(EveHistory.Entry(time: self.dependencies.now(), status: open ? 1 : 0))
            if open {
                counter.value.timesOpened = (counter.value.timesOpened ?? 0) + 1
                opened?.value = .int(counter.value.timesOpened ?? 0)
                save()
            }
        }
    }

    /// Records each power reading; without `getTotalConsumption`, counts the energy itself (section 7.5).
    func energyHistory(_ service: ServiceBuilder, _ entry: Entry, _ history: EveHistory, counts: Bool) -> (Double) -> Void {
        guard counts else {
            return { watts in history.add(EveHistory.Entry(time: self.dependencies.now(), power: watts)) }
        }
        let file = counterFile(entry.config)
        let counter = Box(file.load() ?? Counter(timesOpened: nil, totalConsumption: 0, resetTotal: nowSeconds() - 978_307_200))
        let total = service.add(Eve.totalConsumption, .double(counter.value.totalConsumption ?? 0))
        let reset = history.service.characteristic(adding: EveCharacteristic.resetTotal)
        reset.value = .int(counter.value.resetTotal)
        let previous = Box<(time: Int, watts: Double)?>(nil)
        let saved = Box(0)
        let name = entry.name
        func save() {
            do { try file.save(counter.value) } catch { logger.error("\(name): cannot write file to save counters: \(error)") }
        }
        onWrite(reset) { [weak total] value in
            counter.value.totalConsumption = 0
            counter.value.resetTotal = value.intValue ?? counter.value.resetTotal
            total?.value = .double(0)
            save()
            self.logger.info("\(name): reset TotalConsumption to 0")
        }
        return { [weak total] watts in
            let now = self.nowSeconds()
            if let last = previous.value {
                counter.value.totalConsumption = (counter.value.totalConsumption ?? 0) + last.watts * Double(now - last.time) / 3_600_000
            }
            previous.value = (now, watts)
            total?.value = .double(counter.value.totalConsumption ?? 0)
            // A device may report its power every second: the counter file is written at most once a minute.
            if now - saved.value >= 60 {
                saved.value = now
                save()
            }
            history.add(EveHistory.Entry(unixTime: now, power: watts))
        }
    }
}
