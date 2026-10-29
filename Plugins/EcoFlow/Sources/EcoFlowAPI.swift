import Crypto
import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

/// A device as the API reports it.
struct EcoFlowDevice: Sendable, Equatable {
    /// Where the device's values come from: the developer API's MQTT pushes, its REST quota, or the EcoFlow app's
    /// stream. A device's values all come from one source, so the page can show each source on its own.
    enum Source: String, Sendable, Equatable {
        case mqtt, rest, app
    }

    /// What the device is: a STREAM (solar, home, grid and battery, its sockets and panels), another home system
    /// (PowerOcean, PowerStream, a Smart Home Panel: solar, home, grid and battery), a portable station such as a RIVER
    /// (input, output and its ports) or a power bank such as a RAPID (input and output). The page lays out each kind as
    /// the app does.
    enum Kind: String, Sendable, Equatable {
        case stream, home, portable, powerBank
    }

    var id: String
    var name: String
    var online: Bool
    var state = EcoFlowState()
    var source = Source.rest
    /// The model the serial number names; nil only for the tests' devices, read as a STREAM.
    var model: EcoFlowModel?

    init(id: String, name: String, online: Bool, model: EcoFlowModel? = nil) {
        self.id = id
        self.name = name
        self.online = online
        self.model = model
    }

    var kind: Kind { model?.kind ?? .stream }

    /// The route the device's values come from.
    var route: EcoFlowModel.Route { source == .app ? .app : .developer }

    /// Whether the model was checked on a real device on this route; the page marks the others untested.
    var tested: Bool { model?.tested.contains(route) ?? true }

    /// The STREAM AC Pro (serial BK31…) has no solar input: the app shows no panels for it, so the plugin shows none.
    var hasPanelInputs: Bool { !id.hasPrefix("BK31") }

    /// The panels' solar the page shows: none for a device with no solar input.
    var panels: [Double] { hasPanelInputs ? state.power.panels : [] }

    /// The readings the device's kind shows, by series key: what the history records and the page graphs, in the
    /// page's order. A reading the model does not report on its route is left out. The panels are recorded too
    /// (`pv1`…), though the page draws no graph for them.
    var series: [(key: String, value: Double)] {
        let power = state.power
        let keys = model?.keys(on: route)
        func has(_ reading: KeyPath<EcoFlowModel.Keys, [String]>) -> Bool { keys.map { !$0[keyPath: reading].isEmpty } ?? true }
        let panelSeries = panels.enumerated().map { ("pv\($0.offset + 1)", $0.element) }
        switch kind {
        case .stream:
            return [("solar", power.solar), ("home", power.home), ("grid", power.grid), ("battery", power.battery),
                    ("ac1", power.ac1), ("ac2", power.ac2), ("ac", power.ac)] + panelSeries
        case .home:
            return [("solar", power.solar, has(\.solar) || has(\.panels)), ("home", power.home, has(\.home)),
                    ("grid", power.grid, has(\.grid)), ("battery", power.battery, has(\.battery))]
                .filter { $0.2 }.map { ($0.0, $0.1) } + panelSeries
        case .portable:
            return [("input", power.input, true), ("output", power.output, true), ("solar", power.solar, has(\.solar)),
                    ("acIn", power.acIn, has(\.acIn)), ("acOut", power.acOut, has(\.acOut)),
                    ("usbA", power.usbA, has(\.usbA)), ("usbC", power.usbC, has(\.usbC))]
                .filter { $0.2 }.map { ($0.0, $0.1) }
        case .powerBank:
            return [("input", power.input), ("output", power.output)]
        }
    }

    /// The role of a reading in the Status page's Energy section: a home system's solar, home, grid and battery power.
    /// The units of a system add up: in a STREAM Ultra with a STREAM AC Pro, the Ultra reports the whole system's flows
    /// (they balance: home = solar + grid - battery) and the AC Pro reports 0 for each, so a figure counted once (an
    /// average) would halve them. A RIVER's or a RAPID's flows have no role: they are a station's ports, not the home's.
    func energyTag(_ key: String) -> EnergyTag? {
        let role: EnergyRole
        switch key {
        case "solar": role = .solar
        case "battery": role = .battery
        case "home": role = .home
        case "grid": role = .grid
        default: return nil
        }
        // A STREAM always has the four; a home system only those its model reports.
        guard kind == .stream || (kind == .home && series.contains { $0.key == key }) else { return nil }
        return EnergyTag(role: role, device: name)
    }
}

/// What a device reports. The battery is in HomeKit's units; the power flows are watts, shown on the plugin's
/// page (HomeKit has no characteristic for them).
struct EcoFlowState: Sendable, Equatable {
    /// The Battery service.
    struct Battery: Sendable, Equatable {
        /// Status Low Battery: 0 batteryLevelNormal, 1 batteryLevelLow (read only).
        var statusLowBattery: Int = 0
        /// Battery Level: 0 to 100 % (read only).
        var batteryLevel: Int = 0
        /// Charging State: 0 notCharging, 1 charging, 2 notChargeable (read only).
        var chargingState: Int = 0
    }

    /// Watts. Signs: solar, home and the battery's charge as the device reports them, with the battery
    /// positive while charging; the grid positive while importing.
    struct Power: Sendable, Equatable {
        /// `powGetPvSum`: the solar input.
        var solar: Double = 0
        /// `powGetSysLoad`: what the home uses.
        var home: Double = 0
        /// `powGetSysGrid`: positive while importing from the grid, negative while exporting.
        var grid: Double = 0
        /// `powGetBpCms`: positive while charging, negative while discharging.
        var battery: Double = 0
        /// The solar input of each panel input, PV1 first (`powGetPv` to `powGetPv4`; from the developer MQTT pushes
        /// and the app's stream, empty from the REST quota).
        var panels: [Double] = []
        /// The AC port (the grid connection port): positive while it outputs, negative while it takes power in.
        var ac: Double = 0
        /// The two AC sockets (AC1, AC2): positive while they supply an appliance (`powGetSchuko1` and `powGetSchuko2`
        /// from the developer MQTT pushes; the app's stream only from the REST quota).
        var ac1: Double = 0
        var ac2: Double = 0
        /// A portable station's (RIVER) flows, as the app shows them: everything coming in and going out, the AC
        /// input, and the outputs by port. Zero on a STREAM.
        var input: Double = 0
        var output: Double = 0
        var acIn: Double = 0
        var acOut: Double = 0
        var usbA: Double = 0
        var usbC: Double = 0
    }

    var battery = Battery()
    var power = Power()
    /// The device's estimate of the minutes to a full battery and to an empty one; nil when it has none.
    var minutesToFull: Double?
    var minutesToEmpty: Double?

    /// The estimate that applies now: to full while charging, to empty otherwise.
    var minutesRemaining: Double? { battery.chargingState == 1 ? minutesToFull : minutesToEmpty }
    /// Whether the battery's level is known. The app's stream sends it only now and then, so a state from the
    /// power alone does not know it, and shows no level rather than 0 %.
    var knowsBatteryLevel = true

    /// Whether the quota reports anything other than zeros. The developer API answers all zeros for a device it
    /// has no live data for, which is not a flat battery.
    var hasReadings: Bool { battery.batteryLevel != 0 || power != Power() }

    /// The state a device's readings give, by its model's keys on the route (EcoFlowModel). A reading the device does
    /// not report counts as 0; without a state of charge the level is not known. The ports' outputs are read as
    /// their size (a station reports them negative).
    init(readings: [String: Double], keys: EcoFlowModel.Keys) {
        self.init(keys: keys) { readings[$0] }
    }

    /// The state from a lookup of each reading by its key: the app's route reads its slots without a dictionary.
    init(keys: EcoFlowModel.Keys, reading: (String) -> Double?) {
        func value(_ candidates: [String]) -> Double? {
            for key in candidates {
                if let reading = reading(key) { return reading * (keys.scales[key] ?? 1) }
            }
            return nil
        }
        func watts(_ candidates: [String]) -> Double { value(candidates) ?? 0 }
        var power = Power()
        power.panels = keys.panels.compactMap { value([$0]) }
        power.solar = value(keys.solar) ?? power.panels.reduce(0, +)
        power.home = watts(keys.home)
        power.grid = watts(keys.grid)
        power.input = watts(keys.input)
        power.output = watts(keys.output)
        power.battery = value(keys.battery) ?? power.input - power.output
        power.acIn = abs(watts(keys.acIn))
        power.acOut = abs(watts(keys.acOut))
        power.usbA = abs(watts(keys.usbA))
        power.usbC = abs(watts(keys.usbC))
        power.ac = watts(keys.ac)
        power.ac1 = watts(keys.ac1)
        power.ac2 = watts(keys.ac2)
        self.init(soc: value(keys.stateOfCharge), power: power)
        // 0 and 5939 (99 hours less a minute, the most the app shows) stand for no estimate.
        func minutes(_ candidates: [String]) -> Double? { value(candidates).flatMap { $0 > 0 && $0 < 5939 ? $0 : nil } }
        minutesToFull = minutes(keys.timeToFull)
        minutesToEmpty = minutes(keys.timeToEmpty)
    }

    /// The numbers of a JSON quota, by key: numbers, and numbers sent as text (a DELTA Pro sends some so); other text
    /// and nested values are left out.
    static func numbers(_ quota: [String: Any]) -> [String: Double] {
        quota.compactMapValues { value in
            (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        }
    }

    /// The state from a battery's state of charge (percent, rounded as the app shows it) and the power flows
    /// (watts). Without the state of charge the level is not known: the app's stream sends it only now and then.
    init(soc: Double?, power: Power) {
        self.power = power
        let charging = power.battery > 0 ? 1 : 0
        guard let soc else {
            knowsBatteryLevel = false
            battery = Battery(statusLowBattery: 0, batteryLevel: 0, chargingState: charging)
            return
        }
        // Clamped as a Double before the conversion: a reading out of range (or not a number) must not trap.
        let level = Int(soc.isFinite ? min(max(soc.rounded(), 0), 100) : 0)
        battery = Battery(statusLowBattery: level < 10 ? 1 : 0, batteryLevel: level, chargingState: charging)
    }

    init() {}
}

/// How the plugin reaches its devices; tests use a fake.
protocol EcoFlowAPI: Sendable {
    func devices() async throws -> [EcoFlowDevice]
    /// The devices, when another API already reports `elsewhere`: a device another route reads, checked there and not
    /// on this one, is the other route's (EcoFlowAll), so this one need not ask for it.
    func devices(besides elsewhere: [EcoFlowDevice]) async throws -> [EcoFlowDevice]
    /// Whether `devices(besides:)` uses what it is told; the others are not told (the list is made for nothing).
    var readsElsewhere: Bool { get }
    /// The changes in the endpoints' answers since the last call, as log lines.
    func schemaChanges() async -> [String]
    /// Closes the API's connections and ends its tasks, when the plugin stops.
    func stop() async
    /// The API's name in the log.
    var name: String { get }
}

extension EcoFlowAPI {
    func devices(besides elsewhere: [EcoFlowDevice]) async throws -> [EcoFlowDevice] { try await devices() }
    var readsElsewhere: Bool { false }
    func stop() async {}
    var name: String { "EcoFlow API" }
}

/// The EcoFlow developer API (https://developer.ecoflow.com): the device list and each device's quota, with a
/// signature of every request made with the access key and the secret key.
struct EcoFlowCloud: EcoFlowAPI {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case http(Int)
        case api(code: String, message: String)
        case unexpectedResponse(String)

        var description: String {
            switch self {
            case .http(let status): "the EcoFlow API answered HTTP \(status)"
            case .api(let code, let message): "the EcoFlow API refused the request (\(code)): \(message)"
            case .unexpectedResponse(let path): "the EcoFlow API answered \(path) with an unexpected body"
            }
        }
    }

    static let usBaseURL = URL(string: "https://api.ecoflow.com")!
    static let euBaseURL = URL(string: "https://api-e.ecoflow.com")!

    let accessKey: String
    let secretKey: String
    let baseURL: URL
    let transport: any HTTPSending
    /// Injected so the tests can fix the nonce and the time; the defaults are a random six digits and now.
    var nonce: @Sendable () -> String = { (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined() }
    var timestamp: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    /// The MQTT pushes of the devices, read first when they are available; nil reads the REST quota alone.
    var stream: EcoFlowDeveloperStream?
    /// Checks each answer's shape against its schema, so a change in the API is logged.
    let schemas = EcoFlowNotices()

    func schemaChanges() async -> [String] { await schemas.drain() }

    func stop() async { await stream?.stop() }

    var name: String { "EcoFlow developer API" }

    /// An MQTT login, from a certification answer (the developer API's and the app's have the same fields).
    struct MQTTAccount: Sendable, Equatable {
        let host: String
        let port: Int
        let account: String
        let password: String

        /// The port comes as a number or as text; 8883 when it is neither.
        init?(certification object: [String: Any]?) {
            guard let object, let host = object["url"] as? String,
                  let account = object["certificateAccount"] as? String,
                  let password = object["certificatePassword"] as? String else { return nil }
            let port = (object["port"] as? NSNumber)?.intValue ?? Int(object["port"] as? String ?? "") ?? 8883
            self.init(host: host, port: port, account: account, password: password)
        }

        init(host: String, port: Int, account: String, password: String) {
            self.host = host
            self.port = port
            self.account = account
            self.password = password
        }
    }

    func mqttAccount() async throws -> MQTTAccount {
        let data = try await get("/iot-open/sign/certification")
        await schemas.record(EcoFlowSchema.certification, problems: EcoFlowSchema.certification.problems(in: data))
        guard let account = MQTTAccount(certification: data as? [String: Any]) else {
            throw Failure.unexpectedResponse("iot-open/sign/certification")
        }
        return account
    }

    /// The signature of a request: the query parameters sorted by name, then the authentication parameters,
    /// joined with `&` and signed with HMAC-SHA256 under the secret key, in lowercase hex.
    static func signature(query: [(name: String, value: String)], accessKey: String, secretKey: String,
                          nonce: String, timestamp: Int64) -> String {
        let parameters = query.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value)" }
        let authentication = "accessKey=\(accessKey)&nonce=\(nonce)&timestamp=\(timestamp)"
        let text = (parameters + [authentication]).joined(separator: "&")
        let key = SymmetricKey(data: Data(secretKey.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)
        return Secrets.hex(code)
    }

    /// The devices on the account the developer API reads, each by its model (EcoFlowModel). A model the plugin does
    /// not read is left out, and the log says so once; one only the app's route reads is left out silently. A device
    /// the API refuses, whose quota has none of its model's state-of-charge keys, or whose quota is all zeros (no live
    /// data), is left out too, and the others still load.
    func devices() async throws -> [EcoFlowDevice] {
        try await devices(besides: [])
    }

    var readsElsewhere: Bool { true }

    /// A device the app's route reads, checked there and not here (a RIVER 3), is not asked for: each quota is a
    /// request of its own, and its answer would go unused.
    func devices(besides elsewhere: [EcoFlowDevice]) async throws -> [EcoFlowDevice] {
        let readElsewhere = Set(elsewhere.filter(\.tested).map(\.id))
        let list = try await get("/iot-open/sign/device/list")
        await schemas.record(EcoFlowSchema.deviceList, problems: EcoFlowSchema.deviceList.problems(in: list))
        guard let items = list as? [[String: Any]] else { throw Failure.unexpectedResponse("device/list") }
        // The devices of a model this API reads, with the model's keys.
        let known = items.compactMap { item -> (sn: String, model: EcoFlowModel, keys: EcoFlowModel.Keys, item: [String: Any])? in
            guard let sn = item["sn"] as? String, !sn.isEmpty, let model = EcoFlowModel.model(serial: sn),
                  let keys = model.developer else { return nil }
            return (sn, model, keys, item)
        }
        // A model the plugin does not read at all is logged once; one the app's route reads (a RAPID) is not.
        for item in items {
            guard let sn = item["sn"] as? String, !sn.isEmpty, EcoFlowModel.model(serial: sn) == nil else { continue }
            let what = "\(EcoFlowModel.describe(serial: sn)), which the plugin does not read"
            await schemas.report("model:\(sn)", "Left out the device \(EcoFlowModel.masked(sn)) on the developer API: \(what)", recovered: "")
        }
        // Connects to the MQTT pushes of the STREAM devices and subscribes to each; a failure leaves the REST quota in
        // charge.
        try? await stream?.watch(known.filter { $0.model.kind == .stream }.map(\.sn))
        var devices: [EcoFlowDevice] = []
        for (sn, model, keys, item) in known where !(readElsewhere.contains(sn) && !model.tested.contains(.developer)) {
            let name = item["deviceName"] as? String ?? sn
            let online = (item["online"] as? NSNumber)?.intValue == 1
            let reading: (state: EcoFlowState, source: EcoFlowDevice.Source)
            if model.kind == .stream, let live = await stream?.quota(for: sn), let state = Self.liveState(live) {
                // A complete push stands for the device: its REST quota would go unused, so it is not asked for.
                reading = (state, .mqtt)
            } else {
                let quota: [String: Any]
                do {
                    quota = try await get("/iot-open/sign/device/quota/all", query: [(name: "sn", value: sn)]) as? [String: Any] ?? [:]
                } catch Failure.api {
                    continue
                }
                if model.kind == .stream {
                    await schemas.record(EcoFlowSchema.quota, problems: EcoFlowSchema.quota.problems(in: quota))
                }
                let readings = EcoFlowState.numbers(quota)
                // A quota with none of the model's state-of-charge keys is no live data, except a STREAM's: its REST
                // quota never has the unit's level, only its power (EcoFlowModel.streamDeveloper).
                guard model.kind == .stream || keys.stateOfCharge.contains(where: { readings[$0] != nil }) else { continue }
                reading = (EcoFlowState(readings: readings, keys: keys), .rest)
            }
            guard reading.state.hasReadings else { continue }
            // The pushes are the device's own state: online while they are fresh, not by the account's list.
            let pushing = reading.source == .mqtt ? await stream?.isFresh(sn) ?? false : online
            var device = EcoFlowDevice(id: sn, name: name, online: pushing, model: model)
            device.state = reading.state
            device.source = reading.source
            devices.append(device)
        }
        return devices
    }

    /// The keys a complete MQTT push carries for a device: the battery (`f32ShowSoc`, the app's figure, rounded)
    /// and the power flows.
    static let liveKeys = ["f32ShowSoc", "powGetPvSum", "powGetSysLoad", "powGetSysGrid", "powGetBpCms", "gridConnectionPower"]

    /// The device's state from its MQTT pushes, when they carry every key in `liveKeys`: a partial push would mix
    /// two sources, so the REST quota stands for the device then (nil). The pushes add the panel inputs and the AC
    /// sockets, which the REST quota has none of: a push that lacks one (no panel on that input, no socket) shows 0
    /// for it rather than falling back.
    static func liveState(_ live: [String: Double]) -> EcoFlowState? {
        guard liveKeys.allSatisfy({ live[$0] != nil }) else { return nil }
        return EcoFlowState(readings: live, keys: EcoFlowModel.streamDeveloper)
    }

    /// A signed GET; returns the `data` of a successful answer.
    private func get(_ path: String, query: [(name: String, value: String)] = []) async throws -> Any {
        let nonce = nonce()
        let timestamp = timestamp()
        let signature = Self.signature(query: query, accessKey: accessKey, secretKey: secretKey,
                                       nonce: nonce, timestamp: timestamp)
        var components = URLComponents(string: baseURL.absoluteString + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.name, value: $0.value) }
        }
        let request = HTTPRequest(url: components.url!, headers: [
            (name: "accessKey", value: accessKey),
            (name: "nonce", value: nonce),
            (name: "timestamp", value: String(timestamp)),
            (name: "sign", value: signature),
        ], timeout: .seconds(15))
        let response = try await transport.send(request)
        guard response.isSuccess else { throw Failure.http(response.status) }
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw Failure.unexpectedResponse(path)
        }
        let code = object["code"].map { "\($0)" } ?? ""
        guard code == "0" else {
            throw Failure.api(code: code, message: object["message"] as? String ?? "")
        }
        return object["data"] ?? NSNull()
    }
}
