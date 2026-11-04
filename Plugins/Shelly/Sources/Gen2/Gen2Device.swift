import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import Logging

/// A `ShellyNG` device's own options: its entry in `_accessories` (by Device Id), else in the Homebridge `devices` list.
struct Gen2DeviceOptions: Sendable, Equatable {
    struct Component: Sendable, Equatable {
        var exclude = false
        /// `switch`/`outlet` for a switch; `window`/`door`/`windowCovering` for a cover.
        var type: String?
    }

    var name: String?
    var exclude = false
    var hostname: String?
    var password: String?
    /// Only `websocket` works; any other value fails the device.
    var protocolName = "websocket"
    /// `switch:0` … `switch:3`, `cover:0` (and the lights' keys, beyond the Homebridge plugin), by component key.
    var components: [String: Component] = [:]

    /// From an entry's keys: `name`, `exclude`, `hostname`, `password`, `protocol` and every `<component>:<id>` object.
    init(_ fields: [String: JSONValue]) {
        name = fields["name"]?.stringValue?.nonEmpty
        exclude = fields["exclude"]?.boolValue ?? false
        hostname = fields["hostname"]?.stringValue?.nonEmpty
        password = fields["password"]?.stringValue
        protocolName = fields["protocol"]?.stringValue ?? "websocket"
        for (key, value) in fields where ComponentKey(key) != nil {
            guard let object = value.objectValue else { continue }
            components[key] = Component(exclude: object["exclude"]?.boolValue ?? false, type: object["type"]?.stringValue?.lowercased())
        }
    }

    init() {}

    func component(_ key: String) -> Component { components[key] ?? Component() }
}

/// One Gen 2+ device once it answered: its info, status and config, the accessories they make, and how notifications
/// change them. State comes from notifications; `Shelly.GetStatus` is read again after each reconnection.
actor Gen2Device {
    let deviceID: String
    let rpc: ShellyRPC
    let info: JSONValue
    let modelName: String
    let options: Gen2DeviceOptions
    private let context: PluginContext
    private let logger: Logger
    private let writeDelay: Duration

    private(set) var status: [String: [String: JSONValue]] = [:]
    private(set) var config: [String: JSONValue] = [:]
    private(set) var isConnected = true
    private var bindings: [String: [@Sendable ([String: JSONValue]) -> Void]] = [:]
    private var buttons: [Int: Service] = [:]
    /// Adaptive Lighting of the colour-temperature lights: the services hold them only weakly.
    private var adaptiveLighting: [AdaptiveLightingController] = []
    private(set) var accessories: [Accessory] = []
    private let writes: LatestCallGuard
    private var watcher: Task<Void, Never>?

    init(deviceID: String, rpc: ShellyRPC, info: JSONValue, status: JSONValue, config: JSONValue, options: Gen2DeviceOptions, context: PluginContext,
         logger: Logger, writeDelay: Duration) {
        self.deviceID = deviceID
        self.rpc = rpc
        self.info = info
        self.options = options
        self.context = context
        self.logger = logger
        self.writeDelay = writeDelay
        writes = LatestCallGuard(delay: writeDelay)
        modelName = Gen2Models.name(model: info["model"]?.stringValue ?? "", app: info["app"]?.stringValue)
        for (key, value) in status.objectValue ?? [:] {
            if let object = value.objectValue { self.status[key] = object }
        }
        self.config = config.objectValue ?? [:]
    }

    var host: String { get async { await rpc.host } }

    /// The name accessories start with: the configured one, the device's own, else the model's.
    var baseName: String {
        options.name ?? config["sys"]?["device"]?["name"]?.stringValue?.nonEmpty ?? info["name"]?.stringValue?.nonEmpty ?? modelName
    }

    var layout: Gen2Layout {
        var inputTypes: [Int: String] = [:]
        for (key, value) in config {
            if let component = ComponentKey(key), component.type == "input", let type = value["type"]?.stringValue { inputTypes[component.id] = type }
        }
        let components = Set(status.keys.compactMap(ComponentKey.init))
        return Gen2Layout(components: components, profile: info["profile"]?.stringValue, inputTypes: inputTypes)
    }

    // MARK: Events

    /// Follows the RPC's events until it stops.
    func watch() {
        let events = rpc.events
        watcher = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    func stop() async {
        watcher?.cancel()
        await rpc.stop()
    }

    private func handle(_ event: RPCEvent) async {
        switch event {
        case .connected:
            let wasDisconnected = !isConnected
            isConnected = true
            setUnavailable(false)
            // Values missed while disconnected: read the whole status again.
            if wasDisconnected, let fresh = try? await rpc.call("Shelly.GetStatus") { apply(fresh) }
        case .disconnected:
            isConnected = false
        case .notification(let method, let params):
            switch method {
            case "NotifyStatus", "NotifyFullStatus": apply(params)
            case "NotifyEvent": handleEvents(params["events"]?.arrayValue ?? [])
            default: break
            }
        }
    }

    private func setUnavailable(_ unavailable: Bool) {
        for accessory in accessories where accessory.isUnavailable != unavailable { accessory.isUnavailable = unavailable }
    }

    /// A status object (a notification's `params`, or `Shelly.GetStatus`'s result): each component's fields laid over
    /// what it had, an object field merged key by key, and the component's services updated once it is applied.
    func apply(_ params: JSONValue) {
        for (key, value) in params.objectValue ?? [:] where key != "ts" {
            guard let fields = value.objectValue else { continue }
            var component = status[key] ?? [:]
            let before = component
            for (field, new) in fields {
                if case .object(let old) = component[field], case .object(let update) = new {
                    component[field] = .object(old.merging(update) { $1 })
                } else {
                    component[field] = new
                }
            }
            guard component != before else { continue }
            status[key] = component
            for binding in bindings[key] ?? [] { binding(component) }
        }
    }

    private func handleEvents(_ events: [JSONValue]) {
        for event in events {
            guard let component = event["component"]?.stringValue.flatMap(ComponentKey.init), component.type == "input",
                  let service = buttons[component.id] else { continue }
            let press: Int? = switch event["event"]?.stringValue {
            case "single_push": 0
            case "double_push": 1
            case "long_push": 2
            default: nil
            }
            guard let press else { continue }
            logger.debug("Input \(component.id): \(["single", "double", "long"][press]) press")
            service.characteristic(.programmableSwitchEvent).sendEvent(.int(press))
        }
    }

    private func bind(_ key: String, _ update: @escaping @Sendable ([String: JSONValue]) -> Void) {
        bindings[key, default: []].append(update)
        update(status[key] ?? [:])
    }

    // MARK: Accessories

    static func accessoryID(platform: String, deviceID: String, item: String) -> String { "\(platform):\(deviceID)-\(item)" }

    /// The device's accessories, built once when it is added: those its options leave out are not among them.
    func makeAccessories(platform: String) -> [Accessory] {
        bindings.removeAll()
        buttons.removeAll()
        adaptiveLighting.removeAll()
        var made: [Accessory] = []
        let firmware = info["ver"]?.stringValue?.nonEmpty ?? "1.0.0"
        let serial = info["mac"]?.stringValue?.uppercased() ?? deviceID
        for item in layout.items {
            let name = item.suffix.map { "\(baseName) \($0)" } ?? baseName
            let id = Self.accessoryID(platform: platform, deviceID: deviceID, item: item.accessoryID)
            guard let (services, category) = makeServices(item.part, name: name, accessoryID: id) else { continue }
            let rpc = rpc, logger = logger
            made.append(Accessory(
                id: id, name: name, manufacturer: "Allterco", model: modelName, serialNumber: serial, firmwareRevision: firmware,
                category: category, services: services, onIdentify: {
                    let host = await rpc.host
                    logger.info("\(name) at \(host) identified")
                }))
        }
        accessories = made
        return made
    }

    private func makeServices(_ part: Gen2Layout.Part, name: String, accessoryID: String) -> ([Service], AccessoryCategory)? {
        switch part {
        case .switch(let id):
            let options = options.component("switch:\(id)")
            guard !options.exclude else { return nil }
            return (switchServices(id, outlet: options.type == "outlet"), options.type == "outlet" ? .outlet : .switch)
        case .cover(let id):
            let options = options.component("cover:\(id)")
            guard !options.exclude else { return nil }
            return coverServices(id, type: options.type)
        case .buttons(let ids):
            return (buttonServices(ids), .programmableSwitch)
        case .inputSwitch(let id):
            return ([inputSwitchService(id)], .switch)
        case .light(let id), .rgb(let id), .rgbw(let id), .cct(let id):
            let key = Self.componentKey(part)
            guard !options.component(key).exclude else { return nil }
            return (lightServices(part, id: id, accessoryID: accessoryID), .lightbulb)
        case .meter(let type, let id):
            guard !options.component("\(type):\(id)").exclude else { return nil }
            return ([meterService(type, id, name: name)], .sensor)
        }
    }

    static func componentKey(_ part: Gen2Layout.Part) -> String {
        switch part {
        case .switch(let id): "switch:\(id)"
        case .cover(let id): "cover:\(id)"
        case .light(let id): "light:\(id)"
        case .rgb(let id): "rgb:\(id)"
        case .rgbw(let id): "rgbw:\(id)"
        case .cct(let id): "cct:\(id)"
        case .inputSwitch(let id): "input:\(id)"
        case .meter(let type, let id): "\(type):\(id)"
        case .buttons: "input"
        }
    }

    private func failure(_ what: String, _ error: any Error) -> HAPStatusError {
        logger.error("Failed to set \(what): \(error)")
        return HAPStatusError(.serviceCommunicationFailure, reason: "\(error)")
    }

    private func switchServices(_ id: Int, outlet: Bool) -> [Service] {
        let key = "switch:\(id)"
        let service = outlet
            ? Service(.outlet, name: "Outlet \(id + 1)", subtype: "outlet-\(id)", optional: [.outletInUse], isPrimary: true)
            : Service(.switch, name: "Switch \(id + 1)", subtype: "switch-\(id)", isPrimary: true)
        let on = service.characteristic(.on)
        let rpc = rpc
        on.onWrite { [weak self] value in
            guard let self else { return }
            let target = value.boolValue ?? false
            guard await self.status[key]?["output"]?.boolValue != target else { return }
            do {
                _ = try await rpc.call("Switch.Set", ["id": .number(Double(id)), "on": .bool(target)])
            } catch {
                throw await self.failure("switch", error)
            }
        }
        let metered = status[key]?["apower"] != nil
        bind(key) { fields in
            on.update(.bool(fields["output"]?.boolValue ?? false))
            if outlet { service.characteristic(.outletInUse).update(.bool((fields["apower"]?.number ?? 0) != 0)) }
        }
        guard metered else { return [service] }
        return [service, powerMeter(key, id: id, voltage: "voltage", current: "current", power: "apower", energy: { $0["aenergy"]?["total"]?.number })]
    }

    /// The Power Meter of a component, with the characteristics its first status had.
    private func powerMeter(_ key: String, id: Int, voltage: String, current: String, power: String, energyKey: String? = nil,
                            energy: @escaping @Sendable ([String: JSONValue]) -> Double?, record: EnergyTag? = nil) -> Service {
        let fields = status[key] ?? [:]
        var optional: [CharacteristicType] = []
        if fields[voltage] != nil { optional.append(PowerMeter.voltage) }
        if fields[current] != nil { optional.append(PowerMeter.electricCurrent) }
        let energySource = energyKey ?? key
        let hasEnergy = energy(status[energySource] ?? [:]) != nil
        if hasEnergy { optional.append(PowerMeter.totalConsumption) }
        let meter = Service(PowerMeter.service, name: "Power Meter \(id + 1)", subtype: "power-meter-\(id)", optional: optional)
        let context = context, deviceID = deviceID, present = optional
        bind(key) { fields in
            let watts = fields[power]?.number ?? 0
            meter.characteristic(PowerMeter.consumption).update(clamping: watts)
            if let volts = fields[voltage]?.number, present.contains(PowerMeter.voltage) { meter.characteristic(PowerMeter.voltage).update(clamping: volts) }
            if let amps = fields[current]?.number, present.contains(PowerMeter.electricCurrent) {
                meter.characteristic(PowerMeter.electricCurrent).update(clamping: amps)
            }
            if let record { context.recordValue(watts, series: "\(deviceID):\(key):power", energy: record) }
        }
        if hasEnergy {
            bind(energySource) { fields in
                if let wattHours = energy(fields) { meter.characteristic(PowerMeter.totalConsumption).update(clamping: wattHours / 1000) }
            }
        }
        return meter
    }

    private func coverServices(_ id: Int, type: String?) -> ([Service], AccessoryCategory) {
        let key = "cover:\(id)"
        let (serviceType, title, subtype, category): (ServiceType, String, String, AccessoryCategory) = switch type {
        case "door": (.door, "Door", "door", .door)
        case "windowcovering": (.windowCovering, "Window Covering", "windowCovering", .windowCovering)
        default: (.window, "Window", "window", .window)
        }
        let service = Service(serviceType, name: "\(title) \(id + 1)", subtype: "\(subtype)-\(id)", isPrimary: true)
        let meter = powerMeter(key, id: id, voltage: "voltage", current: "current", power: "apower", energy: { $0["aenergy"]?["total"]?.number })
        guard status[key]?["pos_control"]?.boolValue == true else {
            logger.warning("Only calibrated covers are supported.")
            return ([service, meter], category)
        }
        let current = service.characteristic(.currentPosition), target = service.characteristic(.targetPosition)
        let state = service.characteristic(.positionState)
        let rpc = rpc, writes = writes
        target.value = .int(status[key]?["target_pos"]?.intValue ?? status[key]?["current_pos"]?.intValue ?? 0)
        target.onWrite { [weak self] value in
            guard let self, let position = value.intValue else { return }
            guard await self.status[key]?["target_pos"]?.intValue != position else { return }
            guard await writes("cover-\(id)") else { return }
            do {
                _ = try await rpc.call("Cover.GoToPosition", ["id": .number(Double(id)), "pos": .number(Double(position))])
            } catch {
                throw await self.failure("target position", error)
            }
        }
        bind(key) { fields in
            let position = fields["current_pos"]?.intValue ?? 0
            current.update(.int(position))
            let moving = fields["state"]?.stringValue
            state.update(.int(moving == "opening" ? 1 : moving == "closing" ? 0 : 2))
            if let goal = fields["target_pos"]?.intValue {
                target.update(.int(goal))
            } else if moving != "opening" && moving != "closing" {
                // Stopped without a target (a wall switch moved it): the target is where it is.
                target.update(.int(position))
            }
        }
        return ([service, meter], category)
    }

    private func buttonServices(_ ids: [Int]) -> [Service] {
        var services: [Service] = []
        for id in ids {
            let button = Service(.statelessProgrammableSwitch, name: "Button \(id + 1)", subtype: "stateless-programmable-switch-\(id)", optional: [.serviceLabelIndex])
            button.characteristic(.serviceLabelIndex).value = .int(id + 1)
            buttons[id] = button
            services.append(button)
        }
        let label = Service(.serviceLabel)
        label.characteristic(.serviceLabelNamespace).value = .int(1)
        return services + [label]
    }

    private func inputSwitchService(_ id: Int) -> Service {
        var readOnly = CharacteristicType.on
        readOnly.permissions = [.pairedRead, .events]
        let service = Service(.switch, name: "Switch \(id + 1)", subtype: "readonly-switch-\(id)", extra: [Characteristic(readOnly)], isPrimary: true)
        let on = service.characteristic(.on)
        bind("input:\(id)") { fields in on.update(.bool(fields["state"]?.boolValue ?? false)) }
        return service
    }

    private func meterService(_ type: String, _ id: Int, name: String) -> Service {
        let key = "\(type):\(id)"
        // A whole home's meter (a 3EM's em, an EM's first em1) counts on the Status page's Energy section as the grid.
        switch type {
        case "em":
            return powerMeter(key, id: id, voltage: "a_voltage", current: "total_current", power: "total_act_power", energyKey: "emdata:\(id)",
                              energy: { $0["total_act"]?.number }, record: EnergyTag(role: .grid, device: name))
        case "em1":
            return powerMeter(key, id: id, voltage: "voltage", current: "current", power: "act_power", energyKey: "em1data:\(id)",
                              energy: { $0["total_act_energy"]?.number }, record: id == 0 ? EnergyTag(role: .grid, device: name) : nil)
        default:
            return powerMeter(key, id: id, voltage: "voltage", current: "current", power: "apower", energy: { $0["aenergy"]?["total"]?.number })
        }
    }

    // MARK: Lights (beyond the Homebridge plugin: Shelly's `Light`, `RGB`, `RGBW` and `CCT` components)

    private func lightServices(_ part: Gen2Layout.Part, id: Int, accessoryID: String) -> [Service] {
        let key = Self.componentKey(part)
        var optional: [CharacteristicType] = [.brightness]
        var method = "Light.Set"
        var range = (low: 2700.0, high: 6500.0)
        switch part {
        case .rgb: optional += [.hue, .saturation]; method = "RGB.Set"
        case .rgbw: optional += [.hue, .saturation]; method = "RGBW.Set"
        case .cct:
            if let limits = config[key]?["ct_range"]?.arrayValue?.compactMap(\.number), limits.count == 2, limits[0] > 0, limits[1] > limits[0] {
                range = (limits[0], limits[1])
            }
            optional.append(.colorTemperature.with(minValue: Double(ShellyColor.mireds(kelvin: range.high)), maxValue: Double(ShellyColor.mireds(kelvin: range.low))))
            method = "CCT.Set"
        default: break
        }
        let light = Service(.lightbulb, name: "Light \(id + 1)", subtype: "light-\(id)", optional: optional, isPrimary: true)
        let rpc = rpc, writes = writes, setMethod = method
        let pending = PendingWrites()
        let send: @Sendable () async throws -> Void = { [weak self] in
            guard let self, await writes(key) else { return }
            let current = pending.take(light)
            var params: [String: JSONValue] = ["id": .number(Double(id))]
            let on = current(.on).boolValue ?? false
            params["on"] = .bool(on)
            if on {
                params["brightness"] = .number(Double(max(current(.brightness).intValue ?? 100, 1)))
                switch part {
                case .rgb, .rgbw:
                    let color = ShellyColor.rgb(hue: current(.hue).doubleValue ?? 0, saturation: current(.saturation).doubleValue ?? 0)
                    params["rgb"] = [.number(Double(color.red)), .number(Double(color.green)), .number(Double(color.blue))]
                    if case .rgbw = part { params["white"] = .number(Double(min(color.red, color.green, color.blue))) }
                case .cct:
                    let mireds = current(.colorTemperature).doubleValue ?? 300
                    params["ct"] = .number((1_000_000 / max(mireds, 1)).rounded())
                default: break
                }
            }
            do {
                _ = try await rpc.call(setMethod, .object(params))
            } catch {
                throw await self.failure("light", error)
            }
        }
        pending.register(light, [.on] + optional, send)
        let controller: AdaptiveLightingController? = if case .cct = part { context.adaptiveLighting(for: light, accessoryID: accessoryID) } else { nil }
        if let controller { adaptiveLighting.append(controller) }
        bind(key) { fields in
            light.characteristic(.on).update(.bool(fields["output"]?.boolValue ?? false))
            if let brightness = fields["brightness"]?.number { light.characteristic(.brightness).update(clamping: brightness) }
            if let rgb = fields["rgb"]?.arrayValue?.compactMap(\.number), rgb.count == 3 {
                let hsv = ShellyColor.hsv(red: rgb[0], green: rgb[1], blue: rgb[2])
                light.characteristic(.hue).update(.double(Double(hsv.hue)))
                light.characteristic(.saturation).update(.double(Double(hsv.saturation)))
            }
            if let kelvin = fields["ct"]?.number, kelvin > 0 {
                let mireds = ShellyColor.mireds(kelvin: kelvin)
                controller?.disableIfChangedElsewhere(mireds: mireds)
                light.characteristic(.colorTemperature).update(clamping: Double(mireds))
            }
        }
        return [light]
    }
}
