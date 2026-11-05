import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
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
        name = fields["name"]?.stringValue?.trimmedNonEmpty
        exclude = fields["exclude"]?.boolValue ?? false
        hostname = fields["hostname"]?.stringValue?.trimmedNonEmpty
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

    private(set) var status: [String: [String: JSONValue]] = [:]
    private(set) var config: [String: JSONValue] = [:]
    private(set) var isConnected = true
    private var bindings: [String: [@Sendable ([String: JSONValue]) -> Void]] = [:]
    private var buttons: [Int: Service] = [:]
    /// Adaptive Lighting of the colour-temperature lights: the services hold them only weakly.
    private var adaptiveLighting: [AdaptiveLightingController] = []
    private(set) var accessories: [Accessory] = []
    /// The names the Shelly app gave the account's devices in Shelly Cloud (`ShellyCloud.deviceNames`), by cloud id.
    private(set) var cloudNames: [String: String] = [:]

    func setCloudNames(_ names: [String: String]) { cloudNames = names }
    private let writes: LatestCallGuard
    private var watcher: Task<Void, Never>?
    /// For the records' CSV (`importHistory`), with the device's password when it has one.
    private let http: any HTTPSending
    private let password: String?
    /// The energy meters whose per-minute records are imported (`importHistory`): the RPC method, the component's id,
    /// its Meter, and the record's keys of energy drawn and sent back, added up (a 3EM's three phases).
    private var historyJobs: [HistoryJob] = []
    private var importer: Task<Void, Never>?
    /// The relays' meters, whose history Shelly Cloud keeps (`importCloudHistory`), by channel.
    private var cloudJobs: [CloudJob] = []

    /// A Meter whose history Shelly Cloud keeps: a relay's channel (`power-consumption`), or an energy meter
    /// (`power-consumption/em-3p`, `em-1p`), which keeps weeks of its own records, so the cloud fills the days before them.
    struct CloudJob: Sendable {
        var key: String
        var channel: Int
        var endpoint: String
        var meter: PluginMeter
        /// The component whose own records the device keeps (`emdata:0`), when it has some.
        var records: String?
    }
    private var cloudImporter: Task<Void, Never>?

    struct HistoryJob: Sendable {
        /// The component: `emdata` or `em1data`.
        var component: String
        var id: Int
        var meter: PluginMeter
        var drawn: [String]
        var back: [String]
        var key: String { "\(component):\(id)" }
        /// `EMData.GetRecords` or `EM1Data.GetRecords`: the spans of records the device keeps.
        var recordsMethod: String { "\(service).GetRecords" }
        /// `EMData.GetNetEnergies` or `EM1Data.GetNetEnergies`: each hour's energy, net of what was sent back.
        var netMethod: String { "\(service).GetNetEnergies" }
        /// The component's RPC service.
        var service: String { component == "emdata" ? "EMData" : "EM1Data" }
    }

    init(deviceID: String, rpc: ShellyRPC, info: JSONValue, status: JSONValue, config: JSONValue, options: Gen2DeviceOptions, context: PluginContext,
         logger: Logger, writeDelay: Duration, http: any HTTPSending = HTTPClient(), password: String? = nil) {
        self.http = http
        self.password = password
        self.deviceID = deviceID
        self.rpc = rpc
        self.info = info
        self.options = options
        self.context = context
        self.logger = logger
        writes = LatestCallGuard(delay: writeDelay)
        modelName = Gen2Models.name(model: info["model"]?.stringValue ?? "", app: info["app"]?.stringValue)
        for (key, value) in status.objectValue ?? [:] {
            if let object = value.objectValue { self.status[key] = object }
        }
        self.config = config.objectValue ?? [:]
    }

    var host: String { get async { await rpc.host } }

    /// The device as Shelly Cloud names it: its MAC in lowercase.
    nonisolated var cloudID: String? { info["mac"]?.stringValue?.lowercased() }

    /// The name accessories start with: the configured one, the device's own, else the model's.
    var baseName: String {
        options.name ?? config["sys"]?["device"]?["name"]?.stringValue?.trimmedNonEmpty ?? info["name"]?.stringValue?.trimmedNonEmpty ?? modelName
    }

    /// Whether a person named the device here or on the device: else the Shelly app's names in the cloud count.
    private var isNamed: Bool {
        options.name != nil || config["sys"]?["device"]?["name"]?.stringValue?.trimmedNonEmpty != nil || info["name"]?.stringValue?.trimmedNonEmpty != nil
    }

    /// An accessory's name: the device's name and the item's suffix; for a device named nowhere else, the name the Shelly
    /// app gave that channel in Shelly Cloud (`<mac>` for channel 0, `<mac>_<n>`), alone.
    func name(of item: Gen2Layout.Item) -> String {
        if !isNamed, let mac = cloudID {
            let channel = item.part.channel ?? 0
            if let name = cloudNames[channel == 0 ? mac : "\(mac)_\(channel)"] { return name }
        }
        return item.suffix.map { "\(baseName) \($0)" } ?? baseName
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
        if !historyJobs.isEmpty, importer == nil { importer = Task { [weak self] in await self?.importHistory() } }
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
        importer?.cancel()
        cloudImporter?.cancel()
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
            setUnavailable(true)
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
            // A cover reports `target_pos` only while it moves to one: once it stops, an old one is gone.
            if key.hasPrefix("cover:"), let state = fields["state"]?.stringValue, state != "opening", state != "closing", fields["target_pos"] == nil {
                component.removeValue(forKey: "target_pos")
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
        let firmware = info["ver"]?.stringValue?.trimmedNonEmpty ?? "1.0.0"
        let serial = info["mac"]?.stringValue?.uppercased() ?? deviceID
        for item in layout.items {
            let name = name(of: item)
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
            return (switchServices(id, outlet: options.type == "outlet", owner: (accessoryID, name)), options.type == "outlet" ? .outlet : .switch)
        case .cover(let id):
            let options = options.component("cover:\(id)")
            guard !options.exclude else { return nil }
            return coverServices(id, type: options.type, owner: (accessoryID, name))
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
            return ([meterService(type, id, name: name, accessoryID: accessoryID)], .sensor)
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

    private func switchServices(_ id: Int, outlet: Bool, owner: (accessoryID: String, device: String)) -> [Service] {
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
        return [service, powerMeter(key, id: id, voltage: "voltage", current: "current", power: "apower", energy: { $0["aenergy"]?["total"]?.number }, owner: owner)]
    }

    /// The Power Meter of a component, with the characteristics its first status had. Its Meter is the plugin's, of `owner`'s
    /// accessory (`PluginContext.meter(of:)`): the power with its sign, the energy counter and `returned`'s, and `role`
    /// suggested for the Home Energy; the series keeps the name it had when the plugin recorded the power itself.
    private func powerMeter(_ key: String, id: Int, voltage: String, current: String, power: String, energyKey: String? = nil,
                            energy: @escaping @Sendable ([String: JSONValue]) -> Double?, returned: (@Sendable ([String: JSONValue]) -> Double?)? = nil,
                            owner: (accessoryID: String, device: String), role: EnergyRole? = nil,
                            history: (component: String, drawn: [String], back: [String])? = nil) -> Service {
        let fields = status[key] ?? [:]
        var optional: [CharacteristicType] = []
        if fields[voltage] != nil { optional.append(PowerMeter.voltage) }
        if fields[current] != nil { optional.append(PowerMeter.electricCurrent) }
        let energySource = energyKey ?? key
        let hasEnergy = energy(status[energySource] ?? [:]) != nil
        if hasEnergy { optional.append(PowerMeter.totalConsumption) }
        let meter = Service(PowerMeter.service, name: "Power Meter \(id + 1)", subtype: "power-meter-\(id)", optional: optional)
        let deviceID = deviceID, present = optional
        // Every power meter is the plugin's Meter: the device's own watt-hours (Total Consumption is in steps of 0.1 kWh, a
        // small plug's hours long), the power with its sign, and what a component sent back (`ret_aenergy`).
        let returned: (@Sendable ([String: JSONValue]) -> Double?)? = returned ?? (energyKey == nil ? Self.returnedEnergy : nil)
        let owned = context.meter(of: meter, accessoryID: owner.accessoryID, device: owner.device, suggestedRole: role, series: "\(deviceID):\(key):power")
        // A relay keeps no records: Shelly Cloud's are its history, with an account.
        if key.hasPrefix("switch:") { cloudJobs.append(CloudJob(key: key, channel: id, endpoint: "", meter: owned)) }
        if let history {
            // An energy meter's history in the cloud: three phases (an `em`) or one (an `em1`, a channel of its own).
            let threePhase = history.component == "emdata"
            cloudJobs.append(CloudJob(key: key, channel: threePhase ? 0 : id, endpoint: threePhase ? "/em-3p" : "/em-1p", meter: owned,
                                      records: "\(history.component):\(id)"))
        }
        if let history { historyJobs.append(HistoryJob(component: history.component, id: id, meter: owned, drawn: history.drawn, back: history.back)) }
        bind(key) { fields in
            let watts = fields[power]?.number ?? 0
            meter.characteristic(PowerMeter.consumption).update(clamping: watts)
            if let volts = fields[voltage]?.number, present.contains(PowerMeter.voltage) { meter.characteristic(PowerMeter.voltage).update(clamping: volts) }
            if let amps = fields[current]?.number, present.contains(PowerMeter.electricCurrent) {
                meter.characteristic(PowerMeter.electricCurrent).update(clamping: amps)
            }
            if let watts = fields[power]?.number { owned.record(watts: watts) }
        }
        if hasEnergy {
            bind(energySource) { fields in
                guard let wattHours = energy(fields) else { return }
                meter.characteristic(PowerMeter.totalConsumption).update(clamping: wattHours / 1000)
                owned.record(counter: wattHours)
                if let back = returned?(fields) { owned.record(counter: back, direction: .returned) }
            }
        }
        return meter
    }

    private func coverServices(_ id: Int, type: String?, owner: (accessoryID: String, device: String)) -> ([Service], AccessoryCategory) {
        let key = "cover:\(id)"
        let (serviceType, title, subtype, category): (ServiceType, String, String, AccessoryCategory) = switch type {
        case "door": (.door, "Door", "door", .door)
        case "windowcovering": (.windowCovering, "Window Covering", "windowCovering", .windowCovering)
        default: (.window, "Window", "window", .window)
        }
        let service = Service(serviceType, name: "\(title) \(id + 1)", subtype: "\(subtype)-\(id)", isPrimary: true)
        let meter = powerMeter(key, id: id, voltage: "voltage", current: "current", power: "apower", energy: { $0["aenergy"]?["total"]?.number }, owner: owner)
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

    private func meterService(_ type: String, _ id: Int, name: String, accessoryID: String) -> Service {
        let key = "\(type):\(id)"
        // An energy meter is the plugin's Meter, with what it sent back to the grid; a whole home's (a 3EM's em, an EM's
        // first em1) suggested as the grid, the person's to change.
        switch type {
        case "em":
            return powerMeter(key, id: id, voltage: "a_voltage", current: "total_current", power: "total_act_power", energyKey: "emdata:\(id)",
                              energy: { $0["total_act"]?.number }, returned: { $0["total_act_ret"]?.number },
                              owner: (accessoryID, name), role: .grid,
                              history: ("emdata", ["a", "b", "c"].map { "\($0)_total_act_energy" }, ["a", "b", "c"].map { "\($0)_total_act_ret_energy" }))
        case "em1":
            return powerMeter(key, id: id, voltage: "voltage", current: "current", power: "act_power", energyKey: "em1data:\(id)",
                              energy: { $0["total_act_energy"]?.number }, returned: { $0["total_act_ret_energy"]?.number },
                              owner: (accessoryID, name), role: id == 0 ? .grid : nil,
                              history: ("em1data", ["total_act_energy"], ["total_act_ret_energy"]))
        default:
            return powerMeter(key, id: id, voltage: "voltage", current: "current", power: "apower", energy: { $0["aenergy"]?["total"]?.number },
                              owner: (accessoryID, name))
        }
    }

    // MARK: History

    /// What a switch's or cover's meter sent back, in Wh.
    @Sendable static func returnedEnergy(_ fields: [String: JSONValue]) -> Double? { fields["ret_aenergy"]?["total"]?.number }

    /// The most pages of hours asked for one meter: years of them, a hundred hours a page.
    static let historyPages = 1000

    /// The records asked for at a time from the CSV: a day of minutes, half a megabyte that a Pro 3EM takes half a minute to make.
    static let historyChunk = 86_400
    /// How long one day's CSV may take.
    static let historyTimeout: Duration = .seconds(180)

    /// What was imported of a meter's records, kept in `shelly-ng-history.json` by `<device>/<component>:<id>`: from the
    /// oldest record to the newest, in Unix seconds.
    struct ImportedSpan: Codable, Equatable {
        var from: Int
        var through: Int
    }

    /// Imports each energy meter's records the device keeps, for weeks, into its Meter by the hour
    /// (`PluginMeter.importHours`), from the oldest record (`EMData.GetRecords`) the first time, then from where the last
    /// import stopped (its last hour again: it was still filling); what was covered is kept as each part comes, so a
    /// restart goes on from there. Each hour comes summed by the device (`EMData.GetNetEnergies`: a hundred hours a
    /// request, seconds for months): net of what was sent back, so an hour above zero is drawn and one below sent back.
    /// A device without it gives its per-minute records by the day instead (its CSV, half a minute a day). Says on the
    /// Status page how far it is.
    func importHistory(now: Date = Date()) async {
        let file = context.jsonFile("shelly-ng-history.json", as: [String: ImportedSpan].self)
        var spans = file.load() ?? [:]
        let end = Int(now.timeIntervalSince1970)
        var covered: (from: Int, through: Int)?
        for job in historyJobs {
            let key = "\(deviceID)/\(job.key)"
            let oldest = (await oldestRecord(job) ?? (end - 7 * 86_400)) / 3600 * 3600
            let known = spans[key]
            // A first import, or one that stopped before the oldest record: from the oldest; else from the last hour.
            let from = known.map { $0.from > oldest + 3600 ? oldest : max(oldest, ($0.through - 3600) / 3600 * 3600) } ?? oldest
            guard from < end else { continue }
            let save = { (part: (from: Int, to: Int)) in
                let span = ImportedSpan(from: min(spans[key]?.from ?? part.from, part.from), through: max(spans[key]?.through ?? part.to, part.to))
                spans[key] = span
                try? file.save(spans)
            }
            var done = await importNet(job, from: from, to: end, save: save)
            if !done { done = await importCSV(job, from: from, to: end, save: save) }
            guard done else {
                context.reportEnergyImport(EnergyImportProgress(state: .failed, message: "\(baseName) did not give its records; the next start tries again"))
                return
            }
            if let span = spans[key] { covered = (min(covered?.from ?? span.from, span.from), max(covered?.through ?? span.through, span.through)) }
        }
        if let covered {
            context.reportEnergyImport(EnergyImportProgress(state: .done, from: Date(timeIntervalSince1970: TimeInterval(covered.from)),
                                                            through: Date(timeIntervalSince1970: TimeInterval(covered.through))))
        }
    }

    /// The hours from `from` (on the hour) to `to` from `GetNetEnergies`, a page at a time as the device chunks them
    /// (`next_record_ts`): each phase's net energy added up. False when the device does not answer it.
    private func importNet(_ job: HistoryJob, from: Int, to: Int, save: (_ part: (from: Int, to: Int)) -> Void) async -> Bool {
        var ts = from
        for _ in 0..<Self.historyPages {
            guard !Task.isCancelled else { return true }
            guard let page = try? await rpc.call(job.netMethod, ["id": .number(Double(job.id)), "ts": .number(Double(ts)), "end_ts": .number(Double(to)), "period": 3600]),
                  let keys = page["keys"]?.arrayValue?.compactMap(\.stringValue) else { return ts > from }
            let columns = keys.indices.filter { keys[$0].hasSuffix("net_act_energy") }
            guard !columns.isEmpty else { return ts > from }
            var hours: [MeterHourImport] = []
            var last = ts
            for block in page["data"]?.arrayValue ?? [] {
                guard let start = block["ts"]?.number, let period = block["period"]?.number, period > 0 else { continue }
                for (index, row) in (block["values"]?.arrayValue ?? []).enumerated() {
                    let values = row.arrayValue?.map { $0.number } ?? []
                    let known = columns.compactMap { $0 < values.count ? values[$0] : nil }
                    guard known.count == columns.count else { continue }
                    let net = known.reduce(0, +), at = Int(start) + index * Int(period)
                    hours.append(MeterHourImport(start: Date(timeIntervalSince1970: TimeInterval(at)), consumption: max(0, net), returned: max(0, -net)))
                    last = max(last, at + Int(period))
                }
            }
            if !hours.isEmpty { job.meter.importHours(hours) }
            save((ts, min(last, to)))
            context.reportEnergyImport(EnergyImportProgress(state: .running, done: (min(last, to) - from) / 3600, total: max(1, (to - from) / 3600)))
            guard let next = page["next_record_ts"]?.number.map(Int.init), next > ts, next < to else { return true }
            ts = next
        }
        return true
    }

    /// The days from `from` to `to` from the per-minute CSV, the newest first, so recent weeks come soon.
    private func importCSV(_ job: HistoryJob, from: Int, to: Int, save: (_ part: (from: Int, to: Int)) -> Void) async -> Bool {
        var chunks: [(from: Int, to: Int)] = []
        var end = to
        while end > from { chunks.append((max(from, end - Self.historyChunk), end)); end -= Self.historyChunk }
        for (index, chunk) in chunks.enumerated() {
            guard !Task.isCancelled else { return true }
            context.reportEnergyImport(EnergyImportProgress(state: .running, done: index, total: chunks.count))
            guard let hours = await recordsCSV(job, from: chunk.from, to: chunk.to) else { return index > 0 }
            if !hours.isEmpty {
                job.meter.importHours(hours.keys.sorted().map { hour in
                    MeterHourImport(start: Date(timeIntervalSince1970: TimeInterval(hour)), consumption: hours[hour]!.drawn, returned: hours[hour]!.back)
                })
            }
            save(chunk)
        }
        return true
    }

    // MARK: Shelly Cloud's history

    /// How far back a first import from the cloud looks; it stops sooner after `cloudEmptyDays` days in a row with nothing.
    static let cloudDays = 3660, cloudEmptyDays = 45
    /// The days first asked of the cloud at a time; halved while it answers them by day (it gives three days by hour).
    static let cloudSpan = 7

    /// Imports the relays' and the energy meters' history from Shelly Cloud (`ShellyCloud`: unofficial), once (an energy
    /// meter's from the day before its own records begin): a week a request (a day when the cloud sums a week by day), the
    /// newest first,
    /// one a second (the cloud's limit, `delay`), back to the day the last import reached (`shelly-cloud-history.json`) or,
    /// the first time, until the cloud has nothing for `cloudEmptyDays` days in a row. A refused key is said on the
    /// Plugins page (`accountRefused`). Hours the bridge measured keep their own figures.
    func startCloudImport(_ cloud: ShellyCloud, delay: Duration, now: Date = Date()) {
        guard !cloudJobs.isEmpty, cloudImporter == nil, let id = cloudID else { return }
        // After the device's own records (`importHistory`): the cloud fills the days before them, and the two never say
        // their progress at once.
        let local = importer
        cloudImporter = Task { [weak self] in
            await local?.value
            await self?.importCloudHistory(cloud, id: id, delay: delay, now: now)
        }
    }

    /// A stretch of days asked of the cloud, the newest first: from `newest` back to `oldest`. A first import's (`first`)
    /// ends sooner, where the cloud's history does, and says how far it went as it goes (`<key>#resume`), so a restart
    /// goes on from there.
    private struct CloudStretch {
        var newest: Date
        var oldest: Date
        var first: Bool
    }

    func importCloudHistory(_ cloud: ShellyCloud, id: String, delay: Duration, now: Date) async {
        let file = context.jsonFile("shelly-cloud-history.json", as: [String: Int].self)
        var reached = file.load() ?? [:]
        let day = 86_400.0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // Where each energy meter's own records begin (`importHistory`): the cloud fills the days before.
        let local = context.jsonFile("shelly-ng-history.json", as: [String: ImportedSpan].self).load() ?? [:]
        for job in cloudJobs {
            let key = "\(deviceID)/\(job.key)", resumeKey = "\(key)#resume"
            let first = job.records.flatMap { local["\(deviceID)/\($0)"] }.map { Date(timeIntervalSince1970: TimeInterval($0.from) - day) }
            let start = min(now, first ?? now)
            let floor = start.addingTimeInterval(-Double(Self.cloudDays) * day)
            // The days since the last import (its last day again), then what a first import left to do.
            var stretches: [CloudStretch] = []
            if let through = reached[key] {
                stretches.append(CloudStretch(newest: start, oldest: Date(timeIntervalSince1970: TimeInterval(through) - day), first: false))
                if let resume = reached[resumeKey] {
                    stretches.append(CloudStretch(newest: Date(timeIntervalSince1970: TimeInterval(resume) - day), oldest: floor, first: true))
                }
            } else {
                stretches.append(CloudStretch(newest: start, oldest: floor, first: true))
            }
            stretches = stretches.filter { $0.oldest < $0.newest }
            let total = max(1, stretches.map { Int($0.newest.timeIntervalSince($0.oldest) / day) + 1 }.reduce(0, +))
            var done = 0
            for stretch in stretches {
                // Seeded from what is kept: a resumed first import keeps the newest day the last run found.
                var newest: Date? = stretch.first ? reached[key].map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
                // A week a request, the newest first; shorter spans when the cloud sums a week by day, down to a day.
                var span = Self.cloudSpan, empty = 0
                var last = calendar.startOfDay(for: stretch.newest)
                let bottom = calendar.startOfDay(for: stretch.oldest)
                while last >= bottom {
                    guard !Task.isCancelled else { return }
                    if done > 0 { try? await Task.sleep(for: delay) }
                    let first = max(bottom, calendar.date(byAdding: .day, value: -(span - 1), to: last) ?? last)
                    let days = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
                    context.reportEnergyImport(EnergyImportProgress(state: .running, done: done, total: total))
                    switch await cloud.consumption(id: id, channel: job.channel, day: first, days: days, timeZone: .current, endpoint: job.endpoint) {
                    case .refused:
                        context.accountRefused("Shelly Cloud refused the email and password: sign in again")
                        context.reportEnergyImport(EnergyImportProgress(state: .failed, message: "Shelly Cloud refused the email and password"))
                        return
                    case .notHourly:
                        // The cloud sums so long a span by day: half as long (7, 3, then 1 day), kept for the rest.
                        span = max(1, span / 2)
                        continue
                    case .nothing:
                        empty += days
                    case .hours(let hours):
                        // By day, newest first: a day of zeros alone is taken as nothing (the cloud answers so for a day it
                        // has no record of, and once for days it had), and its zeros would stand over the day's real figures.
                        let byDay = Dictionary(grouping: hours) { calendar.startOfDay(for: $0.start) }
                        for offset in 0..<days {
                            guard let date = calendar.date(byAdding: .day, value: -offset, to: last) else { continue }
                            let hours = byDay[date] ?? []
                            if hours.contains(where: { ($0.consumption ?? 0) > 0 || ($0.returned ?? 0) > 0 }) {
                                job.meter.importHours(hours)
                                newest = newest ?? date
                                empty = 0
                            } else {
                                empty += 1
                            }
                        }
                    }
                    done += days
                    // A first import says how far it went after each request, and ends where the cloud's history does.
                    if stretch.first {
                        reached[key] = Int((newest ?? stretch.newest).timeIntervalSince1970)
                        reached[resumeKey] = Int(first.timeIntervalSince1970)
                        try? file.save(reached)
                        if empty >= Self.cloudEmptyDays { break }
                    }
                    guard let next = calendar.date(byAdding: .day, value: -1, to: first) else { break }
                    last = next
                }
                if stretch.first {
                    reached.removeValue(forKey: resumeKey)
                } else {
                    reached[key] = Int((newest ?? stretch.newest).timeIntervalSince1970)
                }
                try? file.save(reached)
            }
        }
        context.reportEnergyImport(EnergyImportProgress(state: .done, through: now))
    }

    /// The first record a meter keeps: the earliest of its data blocks.
    private func oldestRecord(_ job: HistoryJob) async -> Int? {
        guard let records = try? await rpc.call(job.recordsMethod, ["id": .number(Double(job.id))]) else { return nil }
        return records["data_blocks"]?.arrayValue?.compactMap { $0["ts"]?.number }.min().map(Int.init)
    }

    /// A span of a meter's records as its CSV has them, added up by hour: the energy drawn and sent back (a 3EM's phases
    /// added up); nil when the device does not give them. With a password, Digest authentication answers its challenge.
    private func recordsCSV(_ job: HistoryJob, from: Int, to: Int) async -> [Int: (drawn: Double, back: Double?)]? {
        let host = await rpc.host
        guard let url = URL(string: "http://\(ShellyRPC.bracketed(host))/\(job.component)/\(job.id)/data.csv?add_keys=true&ts=\(from)&end_ts=\(to)") else { return nil }
        var request = HTTPRequest(url: url, timeout: Self.historyTimeout)
        guard var response = try? await http.send(request) else { return nil }
        if response.status == 401, let password,
           let header = response.header("WWW-Authenticate") {
            var digest = DigestAuthentication(username: "admin", password: password)
            guard digest.accept(challenge: header), let authorization = digest.authorization(method: "GET", uri: url.path + (url.query.map { "?\($0)" } ?? "")) else { return nil }
            request.setHeader("Authorization", authorization)
            guard let again = try? await http.send(request) else { return nil }
            response = again
        }
        guard response.status == 200 else { return nil }
        return Self.hours(csv: response.body, drawn: job.drawn, back: job.back)
    }

    /// The records of a CSV (a header of `timestamp` and the keys, then a row a period) added up by hour.
    static func hours(csv: Data, drawn: [String], back: [String]) -> [Int: (drawn: Double, back: Double?)]? {
        var lines = String(decoding: csv, as: UTF8.self).split(whereSeparator: \.isNewline).makeIterator()
        guard let header = lines.next()?.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }),
              let time = header.firstIndex(of: "timestamp") else { return nil }
        let drawnColumns = drawn.compactMap { header.firstIndex(of: $0) }, backColumns = back.compactMap { header.firstIndex(of: $0) }
        guard drawnColumns.count == drawn.count else { return nil }
        let returns = backColumns.count == back.count
        var hours: [Int: (drawn: Double, back: Double?)] = [:]
        while let line = lines.next() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard time < fields.count, let at = Int(fields[time]) else { continue }
            let value = { (column: Int) in column < fields.count ? Double(fields[column]) : nil }
            let used = drawnColumns.compactMap(value)
            guard used.count == drawnColumns.count else { continue }
            let hour = at / 3600 * 3600
            var known = hours[hour] ?? (0, returns ? 0 : nil)
            known.drawn += used.reduce(0, +)
            if returns { known.back = (known.back ?? 0) + backColumns.compactMap(value).reduce(0, +) }
            hours[hour] = known
        }
        return hours
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
