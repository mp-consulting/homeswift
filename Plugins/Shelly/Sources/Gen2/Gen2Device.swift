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
    private let writes: LatestCallGuard
    private var watcher: Task<Void, Never>?
    /// For the records' CSV (`importHistory`), with the device's password when it has one.
    private let http: any HTTPSending
    private let password: String?
    /// The energy meters whose per-minute records are imported (`importHistory`): the RPC method, the component's id,
    /// its Meter, and the record's keys of energy drawn and sent back, added up (a 3EM's three phases).
    private var historyJobs: [HistoryJob] = []
    private var importer: Task<Void, Never>?

    struct HistoryJob: Sendable {
        /// The component: `emdata` or `em1data`.
        var component: String
        var id: Int
        var meter: PluginMeter
        var drawn: [String]
        var back: [String]
        var key: String { "\(component):\(id)" }
        /// `EMData.GetRecords` or `EM1Data.GetRecords`: the spans of records the device keeps.
        var recordsMethod: String { component == "emdata" ? "EMData.GetRecords" : "EM1Data.GetRecords" }
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

    /// The name accessories start with: the configured one, the device's own, else the model's.
    var baseName: String {
        options.name ?? config["sys"]?["device"]?["name"]?.stringValue?.trimmedNonEmpty ?? info["name"]?.stringValue?.trimmedNonEmpty ?? modelName
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

    /// The Power Meter of a component, with the characteristics its first status had. `takeOver` makes its Meter the
    /// plugin's (`PluginContext.meter(of:)`): the power with its sign, the energy counter and `returned`'s, and the role
    /// suggested for the Home Energy; the series keeps the name it had when the plugin recorded the power itself.
    private func powerMeter(_ key: String, id: Int, voltage: String, current: String, power: String, energyKey: String? = nil,
                            energy: @escaping @Sendable ([String: JSONValue]) -> Double?, returned: (@Sendable ([String: JSONValue]) -> Double?)? = nil,
                            takeOver: (accessoryID: String, device: String, role: EnergyRole?)? = nil,
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
        let owned = takeOver.map { context.meter(of: meter, accessoryID: $0.accessoryID, device: $0.device, suggestedRole: $0.role, series: "\(deviceID):\(key):power") }
        if let owned, let history { historyJobs.append(HistoryJob(component: history.component, id: id, meter: owned, drawn: history.drawn, back: history.back)) }
        bind(key) { fields in
            let watts = fields[power]?.number ?? 0
            meter.characteristic(PowerMeter.consumption).update(clamping: watts)
            if let volts = fields[voltage]?.number, present.contains(PowerMeter.voltage) { meter.characteristic(PowerMeter.voltage).update(clamping: volts) }
            if let amps = fields[current]?.number, present.contains(PowerMeter.electricCurrent) {
                meter.characteristic(PowerMeter.electricCurrent).update(clamping: amps)
            }
            if let watts = fields[power]?.number { owned?.record(watts: watts) }
        }
        if hasEnergy {
            bind(energySource) { fields in
                guard let wattHours = energy(fields) else { return }
                meter.characteristic(PowerMeter.totalConsumption).update(clamping: wattHours / 1000)
                owned?.record(counter: wattHours)
                if let back = returned?(fields) { owned?.record(counter: back, direction: .returned) }
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

    private func meterService(_ type: String, _ id: Int, name: String, accessoryID: String) -> Service {
        let key = "\(type):\(id)"
        // An energy meter is the plugin's Meter, with what it sent back to the grid; a whole home's (a 3EM's em, an EM's
        // first em1) suggested as the grid, the person's to change.
        switch type {
        case "em":
            return powerMeter(key, id: id, voltage: "a_voltage", current: "total_current", power: "total_act_power", energyKey: "emdata:\(id)",
                              energy: { $0["total_act"]?.number }, returned: { $0["total_act_ret"]?.number },
                              takeOver: (accessoryID, name, .grid),
                              history: ("emdata", ["a", "b", "c"].map { "\($0)_total_act_energy" }, ["a", "b", "c"].map { "\($0)_total_act_ret_energy" }))
        case "em1":
            return powerMeter(key, id: id, voltage: "voltage", current: "current", power: "act_power", energyKey: "em1data:\(id)",
                              energy: { $0["total_act_energy"]?.number }, returned: { $0["total_act_ret_energy"]?.number },
                              takeOver: (accessoryID, name, id == 0 ? .grid : nil),
                              history: ("em1data", ["total_act_energy"], ["total_act_ret_energy"]))
        default:
            return powerMeter(key, id: id, voltage: "voltage", current: "current", power: "apower", energy: { $0["aenergy"]?["total"]?.number })
        }
    }

    // MARK: History

    /// The records asked for at a time: a day of minutes, half a megabyte of CSV that a Pro 3EM takes half a minute to make.
    static let historyChunk = 86_400
    /// How long one day's CSV may take.
    static let historyTimeout: Duration = .seconds(180)

    /// What was imported of a meter's records, kept in `shelly-ng-history.json` by `<device>/<component>:<id>`: from the
    /// oldest record to the newest, in Unix seconds.
    struct ImportedSpan: Codable, Equatable {
        var from: Int
        var through: Int
    }

    /// Imports each energy meter's records the device keeps (a row of Wh a minute, for weeks), by the day as the device
    /// writes them (`/emdata/<id>/data.csv`, `/em1data/<id>/data.csv`; `EMData.GetData` gives seven rows a request),
    /// added up by hour into its Meter (`PluginMeter.importHours`). The newest days come first, so recent weeks fill in
    /// soon; then back to the oldest record (`EMData.GetRecords`). What was covered is kept after each day, so a restart
    /// starts with what is new and goes on where it stopped. Says on the Status page how far it is.
    func importHistory(now: Date = Date()) async {
        let file = context.jsonFile("shelly-ng-history.json", as: [String: ImportedSpan].self)
        var spans = file.load() ?? [:]
        let end = Int(now.timeIntervalSince1970)
        var covered: (from: Int, through: Int)?
        for job in historyJobs {
            let key = "\(deviceID)/\(job.key)"
            let oldest = await oldestRecord(job) ?? (end - 7 * 86_400)
            var span = spans[key]
            // The day chunks: what is new since the last import (its last hour again: it was still filling), newest
            // first, then what is older than the import reached, back to the oldest record.
            var chunks: [(from: Int, to: Int)] = []
            let newFrom = span.map { max(oldest, $0.through - 3600) } ?? oldest
            var to = end
            while to > newFrom { chunks.append((max(newFrom, to - Self.historyChunk), to)); to -= Self.historyChunk }
            if let known = span { to = known.from; while to > oldest { chunks.append((max(oldest, to - Self.historyChunk), to)); to -= Self.historyChunk } }
            for (index, chunk) in chunks.enumerated() {
                guard !Task.isCancelled else { return }
                context.reportEnergyImport(EnergyImportProgress(state: .running, done: index, total: chunks.count))
                guard let hours = await recordsCSV(job, from: chunk.from, to: chunk.to) else {
                    context.reportEnergyImport(EnergyImportProgress(state: .failed, message: "\(baseName) did not give its records; the next start tries again"))
                    try? file.save(spans)
                    return
                }
                if !hours.isEmpty {
                    job.meter.importHours(hours.keys.sorted().map { hour in
                        MeterHourImport(start: Date(timeIntervalSince1970: TimeInterval(hour)), consumption: hours[hour]!.drawn, returned: hours[hour]!.back)
                    })
                }
                span = ImportedSpan(from: min(span?.from ?? chunk.from, chunk.from), through: max(span?.through ?? chunk.to, chunk.to))
                spans[key] = span
                try? file.save(spans)
            }
            if let span { covered = (min(covered?.from ?? span.from, span.from), max(covered?.through ?? span.through, span.through)) }
        }
        if let covered {
            context.reportEnergyImport(EnergyImportProgress(state: .done, from: Date(timeIntervalSince1970: TimeInterval(covered.from)),
                                                            through: Date(timeIntervalSince1970: TimeInterval(covered.through))))
        }
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
           let header = response.headers.first(where: { $0.name.lowercased() == "www-authenticate" })?.value {
            var digest = DigestAuthentication(username: "admin", password: password)
            guard digest.accept(challenge: header), let authorization = digest.authorization(method: "GET", uri: url.path + (url.query.map { "?\($0)" } ?? "")) else { return nil }
            request.headers.append(("Authorization", authorization))
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
