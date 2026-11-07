import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// The waits of a device's life (docs/clean-room/XiaomiMiot.md section 9); tests shorten them.
struct DeviceTimings: Sendable {
    /// The interval without a setting (15 s), and the shortest one taken.
    var defaultInterval: Duration = .seconds(15)
    var minimumInterval: Duration = .seconds(1)
    /// The reconnect waits at least this after 4 failed polls (9.2).
    var reconnectFloor: Duration = .seconds(30)
    var reconnectMaximum: Duration = .seconds(600)
    /// The slider writes' debounce (7.5).
    var debounce: Duration = .milliseconds(500)
    var miio = MiioTimings()
    var accessory = AccessoryTimings()
}

/// What one device needs from the plugin.
struct DeviceEnvironment: Sendable {
    var context: PluginContext
    var registry: SpecRegistry
    var hub: MiioHub
    var timings: DeviceTimings
    var defaults: MappingDefaults
    var logger: Logger
}

/// One device of the instance: its connection, its spec, its accessory and its polling (section 9). MIoT devices
/// through their spec; the Roborock-family robots through the legacy miIO commands.
actor MiotDevice: MiotDeviceIO {
    enum Path: String, Sendable { case unknown, miot, legacy, unsupported }

    let did: String
    private(set) var name: String
    private(set) var model: String?
    private(set) var host: String
    let options: DeviceOptions
    /// The MAC (uppercase hex) the cloud or the device gave, else the did.
    private(set) var serialNumber: String
    private(set) var firmware: String
    private let environment: DeviceEnvironment
    private let client: MiioClient
    private let handle = DeviceHandle()
    private let debounce: LatestCallGuard
    private var logger: Logger { environment.logger }
    private var context: PluginContext { environment.context }

    private(set) var path: Path = .unknown
    private(set) var spec: MiotSpec?
    private(set) var built: BuiltAccessory?
    private var legacy: LegacyVacuumAccessory?
    private(set) var values: PropertyValues = [:]
    private(set) var isReachable = false
    private(set) var lastPoll: Date?
    private var failures = 0
    private var interval: Duration
    private var doubledForBusy = false
    private var polls = 0
    private var task: Task<Void, Never>?
    private var outageLogged = false
    /// Why it is not published, for the page.
    private(set) var problem: String?

    var accessoryID: String { context.accessoryID(of: did) }

    init(did: String, name: String, model: String?, host: String, token: MiioToken, options: DeviceOptions, serialNumber: String, firmware: String?,
         environment: DeviceEnvironment) {
        self.did = did
        self.name = name
        self.model = model
        self.host = host
        self.options = options
        self.serialNumber = serialNumber
        self.firmware = firmware ?? "Unknown"
        self.environment = environment
        client = MiioClient(host: host, token: token, deviceID: UInt32(did), hub: environment.hub, timings: environment.timings.miio, logger: environment.logger)
        debounce = LatestCallGuard(delay: environment.timings.debounce)
        let seconds = options.pollingInterval.map { Duration.seconds($0) } ?? environment.timings.defaultInterval
        interval = max(seconds, environment.timings.minimumInterval)
    }

    var pollingInterval: Duration { interval }

    // MARK: Life

    func start() {
        handle.attach(self)
        task = Task { [weak self] in await self?.run() }
    }

    func stop() async {
        task?.cancel()
        task = nil
        await client.detach()
    }

    private func run() async {
        await client.attach()
        if let model, MiotSpec.isLegacyVacuum(model: model) {
            buildLegacy(model: model)
        } else if let model, let spec = await environment.registry.cached(model: model) {
            // Known: on the bridge at once, before the device answers.
            build(spec: spec, model: model)
        }
        let backoff = Backoff(initial: max(interval * 4, environment.timings.reconnectFloor), maximum: environment.timings.reconnectMaximum)
        var attempt = 0
        while !Task.isCancelled {
            if await connect() {
                attempt = 0
                guard await prepare() else { return }
                guard options.deviceEnabled else {
                    logger.info("\(name) is not polled (deviceEnabled is false)")
                    return
                }
                await pollLoop()
                if Task.isCancelled || path == .unsupported { return }
            }
            let delay = backoff.delay(attempt: attempt)
            attempt += 1
            if !outageLogged {
                outageLogged = true
                logger.warning("\(name) is not responding; reconnecting in \(Int(delay.components.seconds)) s")
            }
            try? await Task.sleep(for: delay)
        }
    }

    /// The handshake and `miIO.info` (9.1 step 2): the model and firmware.
    private func connect() async -> Bool {
        do {
            let info = try await client.info()
            if let reported = info["model"]?.stringValue, !reported.isEmpty {
                if let model, model != reported {
                    logger.debug("\(name) reports the model \(reported); using the configured \(model)")
                } else if model == nil {
                    model = reported
                }
            }
            if let version = info["fw_ver"]?.stringValue, !version.isEmpty, version != firmware {
                firmware = version
                built?.accessory.information.characteristic(.firmwareRevision).value = .string(version)
                legacy?.accessory.information.characteristic(.firmwareRevision).value = .string(version)
            }
            // The device's MAC is its Serial Number when the cloud gave none.
            if serialNumber == did, let mac = info["mac"]?.stringValue.flatMap(MiCloud.serialNumber(mac:)) {
                serialNumber = mac
                for accessory in [built?.accessory, legacy?.accessory].compactMap({ $0 }) {
                    accessory.information.characteristic(.serialNumber).value = .string(mac)
                }
            }
            setReachable(true)
            logger.info("Connected to \(name) (\(model ?? "unknown model"), firmware \(firmware))")
            return true
        } catch {
            setReachable(false)
            if !outageLogged {
                if case MiioError.wrongToken = error {
                    logger.warning("The token of \(name) does not open the device at \(host)")
                } else {
                    logger.debug("\(name) did not answer at \(host): \(error)")
                }
            }
            return false
        }
    }

    /// The spec and the accessory, once connected (9.1 step 3). False when the device cannot be published.
    private func prepare() async -> Bool {
        guard let model else {
            problem = "The device did not say its model: set its model in its settings."
            logger.warning("\(name) did not say its model; set model in its settings")
            return false
        }
        if MiotSpec.isLegacyVacuum(model: model) {
            if legacy == nil { buildLegacy(model: model) }
            return true
        }
        if options.micloud["forceMiCloud"]?.boolValue == true {
            logger.warning("\(name): micloud.forceMiCloud is not supported yet; the device is reached on the LAN")
        }
        do {
            let spec = try await environment.registry.spec(model: model)
            if self.spec != spec || built == nil { build(spec: spec, model: model) }
            return built != nil
        } catch {
            problem = "miot-spec.org did not give the spec of \(model), and none is kept: Homeswift tries again at the next connection."
            logger.error("No spec for \(model) of \(name) and none kept: \(error)")
            return false
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            do {
                try await poll()
                failures = 0
                setReachable(true)
            } catch MiioError.unknownMethod where path == .miot && polls == 0 {
                await fallBackToLegacy()
                if path == .unsupported { return }
                continue
            } catch {
                if let error = error as? MiioError, error.isBusy, !doubledForBusy {
                    doubledForBusy = true
                    interval = interval * 2
                    logger.info("\(name) is busy (user ack timeout); polling every \(Int(interval.components.seconds)) s")
                }
                failures += 1
                logger.debug("Poll of \(name) failed (\(failures)): \(error)")
                if failures >= 4 {
                    failures = 0
                    setReachable(false)
                    return
                }
            }
            try? await Task.sleep(for: interval)
        }
    }

    /// The first `get_properties` answered `unknown_method`: `get_status` decides (8.1 rule 2).
    private func fallBackToLegacy() async {
        if let status = try? await client.call("get_status"), LegacyVacuumAccessory.status(status) != nil {
            logger.info("\(name) answers get_status: using the miIO vacuum commands")
            if let model { buildLegacy(model: model) }
            return
        }
        path = .unsupported
        problem = "\(model ?? name) does not answer MIoT on the local network: it needs the Xiaomi cloud, which this plugin does not use yet."
        logger.info("\(model ?? name) needs the Xiaomi cloud; set micloud.forceMiCloud to use it")
        if context.accessory(id: accessoryID) != nil { try? await context.remove(id: accessoryID) }
        built = nil
    }

    private func setReachable(_ reachable: Bool) {
        if reachable, !isReachable, outageLogged {
            logger.info("\(name) is responding again")
            outageLogged = false
        }
        isReachable = reachable
        let accessory = built?.accessory ?? legacy?.accessory
        if let accessory, accessory.isUnavailable == reachable { accessory.isUnavailable = !reachable }
        for service in built?.statusActive ?? [] { MiotAccessoryBuilder.set(service[.statusActive], .bool(reachable)) }
        if let legacy { MiotAccessoryBuilder.set(legacy.fan[.statusActive], .bool(reachable)) }
    }

    // MARK: Building

    private func build(spec: MiotSpec, model: String) {
        if MiotSpec.skippedDeviceTypes.contains(spec.deviceType) {
            path = .unsupported
            problem = "\(spec.deviceType) devices are not supported."
            logger.info("\(name) (\(model)) is a \(spec.deviceType): not supported")
            return
        }
        let context = context
        let accessoryID = accessoryID
        let builder = MiotAccessoryBuilder(
            spec: spec, model: model, name: name, accessoryID: accessoryID, serialNumber: serialNumber, firmware: firmware, options: options,
            defaults: environment.defaults, handle: handle, timings: environment.timings.accessory, logger: logger,
            makeAdaptiveLighting: { context.adaptiveLighting(for: $0, accessoryID: accessoryID) })
        guard let made = builder.build() else {
            problem = "Nothing of this device maps to HomeKit: add what you want with propertyControl in its settings."
            logger.info("No HomeKit mapping for \(model); use propertyControl")
            path = .miot
            self.spec = spec
            return
        }
        if let cached = context.accessory(id: accessoryID) { made.accessory.takeValues(from: cached) }
        do {
            try context.add(made.accessory)
        } catch {
            problem = "\(error)"
            logger.error("Could not add \(name) to the bridge: \(error)")
            return
        }
        problem = nil
        path = .miot
        self.spec = spec
        built = made
        legacy = nil
        logger.info("\(name) published with \(made.accessory.services.count - 1) services from \(spec.type)")
        // What is known shows at once.
        for binding in made.bindings { binding.apply(values, false) }
    }

    private func buildLegacy(model: String) {
        let extra = MiotAccessoryBuilder.methodButtons(options: options, handle: handle, timings: environment.timings.accessory, logger: logger) {
            MiotConversions.homeKitName($0)
        }
        let vacuum = LegacyVacuumAccessory(accessoryID: accessoryID, name: name, model: model, serialNumber: serialNumber, firmware: firmware, handle: handle,
                                           extra: extra)
        if let cached = context.accessory(id: accessoryID) { vacuum.accessory.takeValues(from: cached) }
        do {
            try context.add(vacuum.accessory)
        } catch {
            problem = "\(error)"
            logger.error("Could not add \(name) to the bridge: \(error)")
            return
        }
        handle.attach(self)
        path = .legacy
        legacy = vacuum
        built = nil
        problem = nil
        logger.info("\(name) published as a miIO vacuum (\(model))")
    }

    // MARK: Polling

    /// Reads the polled properties, at most `propertyChunkSize` (14) a request, one request after another (5.9); or
    /// the legacy robot's status, its consumables every 10 polls (8.3).
    func poll() async throws {
        switch path {
        case .legacy:
            guard let legacy else { return }
            let status = try await client.call("get_status")
            guard let fields = LegacyVacuumAccessory.status(status) else { throw MiioError.invalidReply }
            legacy.show(status: fields)
            if polls % 10 == 0, let consumables = try? await client.call("get_consumable") { legacy.show(consumables: consumables) }
        case .miot:
            guard let built else { return }
            let read = try await readProperties(built.polled)
            apply(read, fromDevice: true)
        case .unknown, .unsupported:
            return
        }
        polls += 1
        lastPoll = Date()
    }

    /// The values of `keys` the device answers (an item with an error keeps the old value).
    func readProperties(_ keys: [PropertyKey]) async throws -> PropertyValues {
        let size = options.propertyChunkSize ?? MiotSpec.quirks(model: model).chunkSize ?? 14
        var read: PropertyValues = [:]
        var start = 0
        while start < keys.count {
            let chunk = Array(keys[start..<min(start + size, keys.count)])
            start += size
            let params = OrderedJSON.array(chunk.map { key in
                .object([("did", .string(did)), ("siid", .int(key.siid)), ("piid", .int(key.piid))])
            })
            let result = try await client.call("get_properties", params)
            guard let items = result.arrayValue, !items.isEmpty else {
                if result.arrayValue == nil, result.stringValue != nil { throw MiioError.unknownMethod }
                throw MiioError.invalidReply
            }
            for item in items {
                guard let siid = item["siid"]?.intValue, let piid = item["piid"]?.intValue else { continue }
                let code = item["code"]?.intValue
                guard code == 0 || (code == nil && item["value"] != nil), let value = item["value"] else {
                    logger.debug("\(name): \(siid).\(piid) not read (code \(code.map(String.init) ?? "none"))")
                    continue
                }
                read[PropertyKey(siid: siid, piid: piid)] = value
            }
        }
        return read
    }

    /// New values in: each binding of a property that changed shows it.
    private func apply(_ read: PropertyValues, fromDevice: Bool) {
        var changed = Set<PropertyKey>()
        for (key, value) in read where values[key] != value {
            values[key] = value
            changed.insert(key)
        }
        guard !changed.isEmpty, let built else { return }
        for binding in built.bindings where !binding.keys.isDisjoint(with: changed) { binding.apply(values, fromDevice) }
    }

    // MARK: MiotDeviceIO

    func value(_ key: PropertyKey) -> JSONValue? { values[key] }

    func write(_ property: MiotSpec.Property, _ value: JSONValue, debounce shouldDebounce: Bool) async throws {
        if shouldDebounce {
            guard await debounce(property.key.description) else { return }
        }
        guard isReachable else { throw HAPStatusError(.serviceCommunicationFailure) }
        let coerced = property.coerce(value)
        // A value it has already is not sent again; a write-only property (a motor's command) always is.
        if property.isReadable, let current = values[property.key], MiotSpec.sameValue(current, coerced), current.stringValue == nil || current == coerced {
            return
        }
        let params = OrderedJSON.array([.object([
            ("did", .string(did)), ("siid", .int(property.siid)), ("piid", .int(property.iid)), ("value", .value(coerced)),
        ])])
        let result: JSONValue
        do {
            result = try await client.call("set_properties", params)
        } catch {
            logger.warning("Could not set \(property.name) of \(name): \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        let code = result[0]?["code"]?.intValue ?? 0
        guard code == 0 || code == 1 else {
            // The write fails, so HomeKit keeps the value it had: polls would not correct it, the device's being unchanged.
            logger.warning("\(name) refused \(property.name): code \(code)")
            throw HAPStatusError(.invalidValueInRequest)
        }
        if property.isReadable { apply([property.key: coerced], fromDevice: false) }
    }

    func run(_ action: MiotSpec.Action, inputs: [JSONValue]) async throws {
        guard isReachable else { throw HAPStatusError(.serviceCommunicationFailure) }
        let plain = MiotSpec.quirks(model: model).plainActionInputs
        var entries: [OrderedJSON] = []
        for (index, input) in inputs.enumerated() where !input.isNull {
            if let piid = input["piid"]?.intValue, let value = input["value"] {
                entries.append(plain ? .value(value) : .object([("piid", .int(piid)), ("value", .value(value))]))
            } else if index < action.inputs.count {
                let property = spec?.property(PropertyKey(siid: action.siid, piid: action.inputs[index]))
                let value = property?.coerce(input) ?? input
                entries.append(plain ? .value(value) : .object([("piid", .int(action.inputs[index])), ("value", .value(value))]))
            }
        }
        let params = OrderedJSON.object([("did", .string(did)), ("siid", .int(action.siid)), ("aiid", .int(action.iid)), ("in", .array(entries))])
        let result: JSONValue
        do {
            result = try await client.call("action", params)
        } catch {
            logger.warning("Could not run \(action.name) on \(name): \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        if let code = result["code"]?.intValue, code != 0, code != 1 {
            logger.warning("\(name) refused \(action.name): code \(code)")
            return
        }
        // What the action changed shows with a poll.
        Task { try? await self.poll() }
    }

    func raw(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard isReachable || path == .legacy else { throw HAPStatusError(.serviceCommunicationFailure) }
        do {
            return try await client.call(method, OrderedJSON(params))
        } catch MiioError.unknownMethod {
            throw MiioError.unknownMethod
        } catch {
            logger.warning("\(method) on \(name) failed: \(error)")
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    // MARK: The page and the Assistant

    /// Follows the device to another address (the hello broadcast or the cloud list saw it there).
    func move(to newHost: String) async {
        guard newHost != host else { return }
        logger.info("\(name) moved to \(newHost)")
        host = newHost
        await client.move(to: newHost)
    }

    /// Its Device Kind: its spec's device type; a vacuum on the legacy path; else its model's.
    var kind: String {
        if let spec { return MiotSpec.kind(deviceType: spec.deviceType) }
        if path == .legacy { return "vacuum" }
        return model.map(MiotSpec.kind(model:)) ?? "other"
    }

    /// What the page lists.
    func summary() -> JSONValue {
        var fields: [String: JSONValue] = [
            "deviceId": .string(did), "accessoryId": .string(accessoryID), "name": .string(name), "ip": .string(host),
            "reachable": .bool(isReachable), "path": .string(path.rawValue), "firmware": firmware == "Unknown" ? .null : .string(firmware), "kind": .string(kind),
            "pollingInterval": .number(Double(interval.components.seconds)),
        ]
        if let model { fields["model"] = .string(model) }
        if let spec { fields["spec"] = .string(spec.type) }
        if let problem { fields["problem"] = .string(problem) }
        if let lastPoll { fields["lastPoll"] = .number(lastPoll.timeIntervalSince1970 * 1000) }
        return .object(fields)
    }

    /// Every readable property of the spec read now, with the spec's services, properties and actions (15.9).
    func describe() async throws -> JSONValue {
        guard let spec else { throw PageError(404, "\(name) has no MIoT spec") }
        guard isReachable else { throw PageError(503, "\(name) is not responding") }
        let keys = spec.readableProperties.map(\.key)
        let read = try await readProperties(keys)
        apply(read.filter { built?.polled.contains($0.key) ?? false }, fromDevice: true)
        var services: [JSONValue] = []
        for service in spec.services where service.urn.name != "device-information" {
            let properties: [JSONValue] = service.properties.map { property in
                var fields: [String: JSONValue] = [
                    "id": .string(property.key.description), "name": .string(property.name), "description": .string(property.description),
                    "format": .string(property.format), "access": .array(property.access.map(JSONValue.string)),
                    "value": read[property.key] ?? values[property.key] ?? .null,
                ]
                if let unit = property.unit { fields["unit"] = .string(unit) }
                if let range = property.range { fields["range"] = .array(range.map(JSONValue.number)) }
                if let list = property.values { fields["values"] = .array(list.map { ["value": $0.value, "description": .string($0.description)] }) }
                return .object(fields)
            }
            let actions: [JSONValue] = service.actions.map { action in
                ["id": .string("\(action.siid).\(action.iid)"), "name": .string(action.name), "description": .string(action.description),
                 "in": .array(action.inputs.map { .number(Double($0)) })]
            }
            services.append(["siid": .number(Double(service.iid)), "name": .string(service.name), "description": .string(service.description),
                             "standard": .bool(service.urn.isStandard), "properties": .array(properties), "actions": .array(actions)])
        }
        return ["device": summary(), "services": .array(services)]
    }

    /// Writes a property by name or `siid.piid`, from the page or the Assistant.
    func setProperty(_ reference: String, _ value: JSONValue) async throws -> JSONValue {
        guard let property = spec?.property(named: reference) else { throw PageError(404, "\(name) has no property \(reference)") }
        guard property.isWritable else { throw PageError(400, "\(property.name) cannot be written") }
        do {
            try await write(property, value, debounce: false)
        } catch {
            throw PageError(502, "\(name) did not take \(property.name)")
        }
        return ["property": .string(property.name), "value": values[property.key] ?? property.coerce(value)]
    }

    func runAction(_ reference: String, _ inputs: [JSONValue]) async throws -> JSONValue {
        guard let action = spec?.action(named: reference) else { throw PageError(404, "\(name) has no action \(reference)") }
        do {
            try await run(action, inputs: inputs)
        } catch {
            throw PageError(502, "\(name) did not run \(action.name)")
        }
        return ["action": .string(action.name), "done": true]
    }
}

/// An answer the page shows as it is: a status and a sentence.
struct PageError: Error, CustomStringConvertible {
    var status: Int
    var description: String

    init(_ status: Int, _ description: String) {
        self.status = status
        self.description = description
    }
}
