import Foundation

// The writes (docs/clean-room/EcoFlowWrites.md): the AC, AC2, DC 12 V and USB outputs, the charge limit and the
// discharge limit, on the developer API and on the EcoFlow app's route; a RIVER 3 Plus's light (section 8). Each model's writes, how they are encoded on
// each route, and which models' writes were seen working (`EcoFlowWrites.checked`).

/// An output a model can switch: a HomeKit Outlet on the device's accessory, its subtype the raw value. A STREAM's AC1
/// and AC2 sockets are `ac` and `ac2`; a DELTA Pro 3's high-voltage and low-voltage AC are `ac` and `ac2` too.
enum EcoFlowOutput: String, Sendable, CaseIterable, Hashable, Comparable {
    case ac, ac2, dc12v, usb

    static func < (a: EcoFlowOutput, b: EcoFlowOutput) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// One write to a device.
enum EcoFlowWrite: Sendable, Equatable, CustomStringConvertible {
    case output(EcoFlowOutput, Bool)
    /// The maximum state of charge, %.
    case chargeLimit(Int)
    /// The minimum state of charge, %.
    case dischargeLimit(Int)
    /// A RIVER 3 Plus's light: one of `EcoFlowLight`'s modes (spec 8.1).
    case lightMode(Int)

    var description: String {
        switch self {
        case let .output(output, on): "\(output.rawValue) \(on ? "on" : "off")"
        case let .chargeLimit(value): "charge limit \(value) %"
        case let .dischargeLimit(value): "discharge limit \(value) %"
        case let .lightMode(mode): "light \(EcoFlowLight.name(mode))"
        }
    }
}

/// A RIVER 3 Plus's light (spec 8): a mode, not a switch. No other value is ever sent (8.1: unknown).
enum EcoFlowLight {
    static let off = 0, dim = 1, bright = 2, sos = 3
    static let modes = 0...3

    static func name(_ mode: Int) -> String {
        switch mode {
        case off: "off"
        case dim: "dim"
        case bright: "bright"
        case sos: "SOS"
        default: "mode \(mode)"
        }
    }

    /// The mode a HomeKit change asks for: On false is Off; a Brightness up to 50 % is Dim, above it Bright (0 % Off);
    /// On true alone is `previous` (the last Dim or Bright the device had), else Bright.
    static func mode(on: Bool?, brightness: Double?, previous: Int?) -> Int? {
        if on == false { return off }
        if let brightness { return brightness <= 0 ? off : brightness <= 50 ? dim : bright }
        if on == true { return previous.flatMap { $0 == dim || $0 == bright ? $0 : nil } ?? bright }
        return nil
    }
}

/// Why a write did not happen.
enum EcoFlowWriteError: Error, CustomStringConvertible, Equatable {
    /// The route has no such write for the model.
    case unsupported(String)
    /// The route is not connected yet.
    case notConnected
    /// The device or the cloud refused it.
    case refused(String)
    /// No answer in time.
    case unanswered

    var description: String {
        switch self {
        case .unsupported(let what): "\(what) cannot be written on this route"
        case .notConnected: "the EcoFlow app's route is not connected"
        case .refused(let reason): "the write was refused: \(reason)"
        case .unanswered: "the device did not answer the write"
        }
    }
}

/// The writes an API sends for a device, each with the route it goes by.
struct EcoFlowCapabilities: Sendable, Equatable {
    var outputs: [EcoFlowOutput: EcoFlowModel.Route] = [:]
    /// The route of the charge and discharge limits; nil when they cannot be written.
    var limits: EcoFlowModel.Route?
    /// The route of the light's mode (a RIVER 3 Plus's, spec 8); nil when it cannot be written.
    var light: EcoFlowModel.Route?

    var isEmpty: Bool { outputs.isEmpty && limits == nil && light == nil }

    func route(for write: EcoFlowWrite) -> EcoFlowModel.Route? {
        switch write {
        case .output(let output, _): outputs[output]
        case .chargeLimit, .dischargeLimit: limits
        case .lightMode: light
        }
    }

    /// Only the writes `allowed` lets through, by route; the light's by `allowedLight`.
    func filter(_ allowed: (EcoFlowModel.Route) -> Bool, light allowedLight: ((EcoFlowModel.Route) -> Bool)? = nil) -> EcoFlowCapabilities {
        EcoFlowCapabilities(outputs: outputs.filter { allowed($0.value) }, limits: limits.flatMap { allowed($0) ? $0 : nil },
                            light: light.flatMap { route in (allowedLight.map { $0(route) } ?? allowed(route)) ? route : nil })
    }

    /// `self`, completed by `other` where it has nothing; a write on a checked route wins over one that is not.
    func merging(_ other: EcoFlowCapabilities, checked: (EcoFlowModel.Route) -> Bool) -> EcoFlowCapabilities {
        var merged = self
        for (output, route) in other.outputs where merged.outputs[output].map({ !checked($0) && checked(route) }) ?? true {
            merged.outputs[output] = route
        }
        if let route = other.limits, merged.limits.map({ !checked($0) && checked(route) }) ?? true { merged.limits = route }
        if let route = other.light, merged.light.map({ !checked($0) && checked(route) }) ?? true { merged.light = route }
        return merged
    }
}

enum EcoFlowWrites {
    // MARK: - Which models' writes were seen working

    /// The models whose writes were seen working on a real device, by the model table's name (so every serial prefix of
    /// the model counts), on each route: the ones the plugin's author owns. Every other model's writes are sent only
    /// with the plugin's `untestedWrites` setting.
    static let checked: [EcoFlowModel.Route: Set<String>] = [
        .app: ["STREAM Ultra", "STREAM AC Pro", "RIVER 3", "RIVER 3 Plus"],
    ]

    static func isChecked(serial: String, route: EcoFlowModel.Route) -> Bool {
        EcoFlowModel.model(serial: serial).map { checked[route]?.contains($0.name) ?? false } ?? false
    }

    /// The models whose light was seen working, likewise: none yet. The RIVER 3 Plus's other writes were checked, its
    /// light was not (spec 8.1), so it is written only with `untestedWrites`.
    static let checkedLight: [EcoFlowModel.Route: Set<String>] = [:]

    static func isLightChecked(serial: String, route: EcoFlowModel.Route) -> Bool {
        EcoFlowModel.model(serial: serial).map { checkedLight[route]?.contains($0.name) ?? false } ?? false
    }

    // MARK: - Each model's writes

    /// How a model's writes are encoded: the message family its sources name (spec 3, 4 and 5).
    enum Family: Sendable, Equatable {
        /// Protobuf with the STREAM header (5.1, 5.4); no developer writes (their bodies carry booleans).
        case stream
        /// Protobuf with the header of the other models (5.1, 5.2, 5.3).
        case river3, delta3, deltaPro3
        /// JSON with `moduleType` and `operateType` (3.3, 4.2).
        case delta2, delta2Max, river2
        /// JSON with `operateType` "TCP" (3.4, 4.3).
        case deltaPro, deltaMax, deltaMini
        /// The developer API's `cmdCode` (3.5); not read on the app's route.
        case deltaProUltra
        /// Protobuf with its own header on the app's route (5.5); `cmdCode` on the developer API (3.6).
        case powerStream
    }

    /// A model's writes on each route.
    struct Table: Sendable, Equatable {
        var family: Family
        /// The outputs written on the app's route, and on the developer API.
        var app: [EcoFlowOutput] = []
        var appLimits = true
        var developer: [EcoFlowOutput] = []
        var developerLimits = false
        /// Whether the app's route writes the light's mode (spec 8: a RIVER 3 Plus's).
        var appLight = false
        /// Each output's name, as the port is labelled.
        var names: [EcoFlowOutput: String] = [.ac: "AC", .ac2: "AC2", .dc12v: "DC 12 V", .usb: "USB"]
        /// The limits' ranges.
        var charge: ClosedRange<Int> = 50...100
        var discharge: ClosedRange<Int> = 0...30
    }

    /// The writes of the model with this name (EcoFlowModel.all); nil for a model with no fitting writes.
    static let tables: [String: Table] = {
        let stream = Table(family: .stream, app: [.ac, .ac2], names: [.ac: "AC1", .ac2: "AC2"])
        let delta3 = Table(family: .delta3, app: [.ac, .usb])
        return [
            "STREAM Ultra": stream, "STREAM Pro": stream, "STREAM AC Pro": stream, "STREAM Ultra X": stream,
            "STREAM Max": Table(family: .stream, app: [.ac]),
            "STREAM AC": Table(family: .stream),
            "RIVER 3": Table(family: .river3, app: [.ac, .dc12v]),
            // The light on the Plus only (8.1): no source shows the plain RIVER 3 with one.
            "RIVER 3 Plus": Table(family: .river3, app: [.ac, .dc12v], appLight: true),
            // The 12 V output only where a source writes it on that model (5.2): the Classic, the Max and the Max Plus.
            "DELTA 3": delta3, "DELTA 3 Plus": delta3, "DELTA 3 Ultra": delta3,
            "DELTA 3 Classic": Table(family: .delta3, app: [.ac, .dc12v, .usb]),
            "DELTA 3 Air": Table(family: .delta3, app: [.ac]),
            "DELTA 3 Max": Table(family: .delta3, app: [.ac, .dc12v, .usb]),
            "DELTA 3 Max Plus": Table(family: .delta3, app: [.ac, .ac2, .dc12v, .usb]),
            "DELTA 3 Ultra Plus": Table(family: .delta3, app: [.ac, .ac2, .usb]),
            "DELTA Pro 3": Table(family: .deltaPro3, app: [.ac, .ac2, .dc12v],
                                 names: [.ac: "AC (high voltage)", .ac2: "AC (low voltage)", .dc12v: "DC 12 V"]),
            // The developer API's AC write carries the X-Boost and the frequency, whose current values it has no
            // documented key for (3.3): the AC goes by the app's route only.
            "DELTA 2": Table(family: .delta2, app: [.ac, .dc12v, .usb], developer: [.dc12v, .usb], developerLimits: true),
            "DELTA 2 Max": Table(family: .delta2Max, app: [.ac, .dc12v, .usb], developer: [.dc12v, .usb], developerLimits: true),
            "RIVER 2": Table(family: .river2, app: [.ac, .dc12v]),
            "RIVER 2 Max": Table(family: .river2, app: [.ac, .dc12v]),
            "RIVER 2 Pro": Table(family: .river2, app: [.ac, .dc12v], developer: [.dc12v], developerLimits: true),
            "DELTA Pro": Table(family: .deltaPro, app: [.ac, .dc12v], developer: [.ac, .dc12v], developerLimits: true),
            "DELTA Max": Table(family: .deltaMax, app: [.ac, .dc12v, .usb]),
            "DELTA Mini": Table(family: .deltaMini, app: [.ac, .dc12v]),
            // Its AC write carries an X-Boost and a frequency whose meanings are not documented (3.5): the DC only.
            "DELTA Pro Ultra": Table(family: .deltaProUltra, appLimits: false, developer: [.dc12v], developerLimits: true,
                                     names: [.dc12v: "DC"]),
            "PowerStream": Table(family: .powerStream, developerLimits: true, charge: 70...100, discharge: 1...30),
        ]
    }()

    static func table(_ model: EcoFlowModel?) -> Table? { model.flatMap { tables[$0.name] } }

    /// What a route writes for a device of `model`. The app's route needs the model read there (a DELTA Pro Ultra is not).
    static func capabilities(_ model: EcoFlowModel?, route: EcoFlowModel.Route) -> EcoFlowCapabilities {
        guard let model, let table = table(model) else { return EcoFlowCapabilities() }
        switch route {
        case .app:
            guard model.app != nil else { return EcoFlowCapabilities() }
            return EcoFlowCapabilities(outputs: Dictionary(uniqueKeysWithValues: table.app.map { ($0, .app) }),
                                       limits: table.appLimits ? .app : nil, light: table.appLight ? .app : nil)
        case .developer:
            guard model.developer != nil else { return EcoFlowCapabilities() }
            return EcoFlowCapabilities(outputs: Dictionary(uniqueKeysWithValues: table.developer.map { ($0, .developer) }),
                                       limits: table.developerLimits ? .developer : nil)
        }
    }

    /// The limits clamped to the model's ranges, the charge limit kept above the discharge limit (`current`, the
    /// device's, where one is not asked for). nil stays nil.
    static func clamp(charge: Int?, discharge: Int?, current: (charge: Int?, discharge: Int?) = (nil, nil),
                      table: Table) -> (charge: Int?, discharge: Int?) {
        func into(_ range: ClosedRange<Int>, _ value: Int) -> Int { min(max(value, range.lowerBound), range.upperBound) }
        var charge = charge.map { into(table.charge, $0) }
        var discharge = discharge.map { into(table.discharge, $0) }
        guard let low = discharge ?? current.discharge, let high = charge ?? current.charge, high <= low else { return (charge, discharge) }
        // The charge limit asked for goes up above the discharge limit where its range leaves room; else the discharge
        // limit asked for comes down below it.
        if charge != nil { charge = into(table.charge, low + 1) }
        if let raised = charge ?? current.charge, raised <= low, discharge != nil { discharge = into(table.discharge, raised - 1) }
        return (charge, discharge)
    }

    // MARK: - The app's route: protobuf (spec 5)

    /// A header's fields, in field-number order (5.1).
    struct Header: Sendable, Equatable {
        var src = 32
        var dest = 2
        var dSrc = 1
        var dDest = 1
        var checkType: Int?
        var cmdFunc = 254
        var cmdID = 17
        var needAck = 1
        var seq: Int
        var productID: Int?
        var version: Int
        var payloadVersion = 1
        var from: String?
        var deviceSN: String?

        /// The STREAM's header (`[IOB]`'s STREAM column).
        static func stream(seq: Int) -> Header {
            Header(seq: seq, productID: 56, version: 3, from: "Android")
        }

        /// The header of RIVER 3, DELTA 3 and DELTA Pro 3 (`[HA]`'s column), with the serial number.
        static func device(seq: Int, serial: String) -> Header {
            Header(seq: seq, productID: 1, version: 19, deviceSN: serial)
        }

        /// The PowerStream's (5.5): `dest` 53, `check_type` 3, `cmd_func` 20.
        static func powerStream(seq: Int, cmdID: Int) -> Header {
            Header(dest: 53, checkType: 3, cmdFunc: 20, cmdID: cmdID, seq: seq, version: 19, from: "Homeswift")
        }
    }

    /// The message: field 1 holds the header, whose field 1 is `pdata`; `data_len` is `pdata`'s real length.
    static func message(pdata: [UInt8], header: Header) -> Data {
        typealias P = EcoFlowProtobuf
        var fields: [UInt8] = P.bytesField(1, pdata)
        fields += P.varintField(2, UInt64(header.src)) + P.varintField(3, UInt64(header.dest))
        fields += P.varintField(4, UInt64(header.dSrc)) + P.varintField(5, UInt64(header.dDest))
        if let checkType = header.checkType { fields += P.varintField(7, UInt64(checkType)) }
        fields += P.varintField(8, UInt64(header.cmdFunc)) + P.varintField(9, UInt64(header.cmdID))
        fields += P.varintField(10, UInt64(pdata.count)) + P.varintField(11, UInt64(header.needAck))
        fields += P.varintField(14, UInt64(header.seq))
        if let productID = header.productID { fields += P.varintField(15, UInt64(productID)) }
        fields += P.varintField(16, UInt64(header.version)) + P.varintField(17, UInt64(header.payloadVersion))
        if let from = header.from { fields += P.bytesField(23, Array(from.utf8)) }
        if let serial = header.deviceSN { fields += P.bytesField(25, Array(serial.utf8)) }
        return Data(P.bytesField(1, fields))
    }

    /// The ConfigWrite field of a write (5.2, 5.3, 5.4); nil when the family does not write it.
    static func configField(_ write: EcoFlowWrite, family: Family) -> (number: Int, value: UInt64)? {
        switch (family, write) {
        case (_, .chargeLimit(let value)): return (33, UInt64(max(value, 0)))
        case (_, .dischargeLimit(let value)): return (34, UInt64(max(value, 0)))
        // `cfg_led_mode` (8.1), its four modes only; Off is sent as an explicit 0.
        case (.river3, .lightMode(let mode)): return EcoFlowLight.modes.contains(mode) ? (89, UInt64(mode)) : nil
        case (_, .lightMode): return nil
        case (.stream, .output(.ac, let on)): return (380, on ? 1 : 0)
        case (.stream, .output(.ac2, let on)): return (381, on ? 1 : 0)
        case (.river3, .output(let output, let on)), (.delta3, .output(let output, let on)):
            let number: Int? = switch output { case .ac: 76; case .ac2: 377; case .dc12v: 18; case .usb: 19 }
            return number.map { ($0, on ? 1 : 0) }
        case (.deltaPro3, .output(let output, let on)):
            let number: Int? = switch output { case .ac: 15; case .ac2: 16; case .dc12v: 18; case .usb: nil }
            return number.map { ($0, on ? 1 : 0) }
        default: return nil
        }
    }

    /// The protobuf message of a write on the app's route, nil when the family has none for it. A STREAM's carries
    /// the time (`cfg_utc_time`, field 6) before the field written (5.4).
    static func protobufPayload(_ write: EcoFlowWrite, family: Family, serial: String, seq: Int, now: Date) -> Data? {
        switch family {
        case .stream:
            guard let field = configField(write, family: family) else { return nil }
            let pdata = EcoFlowProtobuf.varintField(6, UInt64(max(0, now.timeIntervalSince1970.rounded(.down))))
                + EcoFlowProtobuf.varintField(field.number, field.value)
            return message(pdata: pdata, header: .stream(seq: seq))
        case .river3, .delta3, .deltaPro3:
            guard let field = configField(write, family: family) else { return nil }
            return message(pdata: EcoFlowProtobuf.varintField(field.number, field.value), header: .device(seq: seq, serial: serial))
        case .powerStream:
            // 132 the lower limit, 133 the upper, each in field 1 (5.5).
            switch write {
            case .dischargeLimit(let value):
                return message(pdata: EcoFlowProtobuf.varintField(1, UInt64(max(value, 0))), header: .powerStream(seq: seq, cmdID: 132))
            case .chargeLimit(let value):
                return message(pdata: EcoFlowProtobuf.varintField(1, UInt64(max(value, 0))), header: .powerStream(seq: seq, cmdID: 133))
            case .output, .lightMode: return nil
            }
        default:
            return nil
        }
    }

    // MARK: - The app's route: JSON (spec 4)

    /// The JSON message of a write on the app's route, in the envelope of 4.2; nil when the family has none for it.
    static func jsonPayload(_ write: EcoFlowWrite, family: Family, serial: String, id: Int) -> Data? {
        let module: (type: Int, operation: String, params: [String: Any])
        switch (family, write) {
        case (.delta2, _), (.delta2Max, _), (.river2, _):
            switch write {
            case .output(.ac, let on):
                module = (family == .delta2Max ? 3 : 5, "acOutCfg", ["enabled": on ? 1 : 0, "out_voltage": -1, "out_freq": 255, "xboost": 255])
            case .output(.dc12v, let on): module = (5, "mpptCar", ["enabled": on ? 1 : 0])
            case .output(.usb, let on) where family != .river2: module = (1, "dcOutCfg", ["enabled": on ? 1 : 0])
            case .chargeLimit(let value): module = (2, "upsConfig", ["maxChgSoc": value])
            case .dischargeLimit(let value): module = (2, "dsgCfg", ["minDsgSoc": value])
            default: return nil
            }
        case (.deltaPro, _), (.deltaMax, _), (.deltaMini, _):
            // `cmdSet` 32 as the developer form documents it (4.3); the limits' `moduleType` is 2 on a DELTA Max.
            let limitsModule = family == .deltaMax ? 2 : 0
            switch write {
            case .output(.ac, let on): module = (0, "TCP", ["cmdSet": 32, "id": 66, "enabled": on ? 1 : 0])
            case .output(.dc12v, let on): module = (0, "TCP", ["cmdSet": 32, "id": 81, "enabled": on ? 1 : 0])
            case .output(.usb, let on) where family == .deltaMax: module = (0, "TCP", ["cmdSet": 32, "id": 34, "enabled": on ? 1 : 0])
            case .chargeLimit(let value): module = (limitsModule, "TCP", ["cmdSet": 32, "id": 49, "maxChgSoc": value])
            case .dischargeLimit(let value): module = (limitsModule, "TCP", ["cmdSet": 32, "id": 51, "minDsgSoc": value])
            default: return nil
            }
        default:
            return nil
        }
        var envelope: [String: Any] = ["from": "Homeswift", "id": String(id), "version": "1.0",
                                       "moduleType": module.type, "operateType": module.operation, "params": module.params]
        // A DELTA 2 Max's PD, BMS and inverter writes name the device (4.2), its car charger's does not.
        if family == .delta2Max, [1, 2, 3].contains(module.type) { envelope["moduleSn"] = serial }
        return try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    /// The payload of a write on the app's route, protobuf or JSON as the model speaks.
    static func appPayload(_ write: EcoFlowWrite, model: EcoFlowModel, serial: String, seq: Int, now: Date) -> Data? {
        guard let table = table(model) else { return nil }
        switch write {
        case .output(let output, _): guard table.app.contains(output) else { return nil }
        case .chargeLimit, .dischargeLimit: guard table.appLimits else { return nil }
        case .lightMode: guard table.appLight else { return nil }
        }
        return model.format == .json
            ? jsonPayload(write, family: table.family, serial: serial, id: seq)
            : protobufPayload(write, family: table.family, serial: serial, seq: seq, now: now)
    }

    // MARK: - Replies (5.6, 4.4)

    /// What a `set_reply` says.
    enum Reply: Sendable, Equatable {
        case accepted
        case refused(String)
    }

    /// The reply in a `set_reply` payload; nil when it cannot be read. A protobuf reply is the header framing with
    /// `cmd_func` 254 and `cmd_id` 18, its body a ConfigWriteAck (field 2, `config_ok`: 1 applied); its body may come
    /// encrypted, or the whole payload base64-encoded. A reply whose body has no `config_ok` (a STREAM's, a
    /// PowerStream's: not decoded by any source) counts as accepted: the device answered the write. A JSON reply is
    /// refused when its `code` is not "0" or its `configOk` is false.
    static func reply(_ payload: Data) -> Reply? {
        if payload.first == UInt8(ascii: "{") {
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
            if let code = object["code"], "\(code)" != "0" {
                return .refused(object["message"] as? String ?? "code \(code)")
            }
            if let data = object["data"] as? [String: Any], let ok = data["configOk"] as? Bool, !ok {
                return .refused("configOk false")
            }
            return .accepted
        }
        var messages = EcoFlowProtobuf.messages(payload)
        if messages.isEmpty, let text = String(data: payload, encoding: .utf8),
           let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            messages = EcoFlowProtobuf.messages(decoded)
        }
        guard !messages.isEmpty else { return nil }
        if let ack = messages.first(where: { $0.command == EcoFlowProtobuf.Command(function: 254, id: 18) }),
           let fields = EcoFlowProtobuf.fields(ack.body),
           case .varint(let ok)? = fields.last(where: { $0.number == 2 })?.value {
            return ok == 1 ? .accepted : .refused("config_ok \(ok)")
        }
        return .accepted
    }

    // MARK: - The developer API (spec 2 and 3)

    /// A JSON body, kept as a tree so it is signed and sent the same.
    indirect enum Body: Sendable, Equatable {
        case int(Int)
        case string(String)
        case object([String: Body])

        /// The leaves as `parent.child=value` pairs (2.2), in no particular order: the signature sorts them.
        func flattened(_ prefix: String = "") -> [(name: String, value: String)] {
            switch self {
            case .int(let value): [(prefix, String(value))]
            case .string(let value): [(prefix, value)]
            case .object(let fields):
                fields.flatMap { key, value in value.flattened(prefix.isEmpty ? key : "\(prefix).\(key)") }
            }
        }

        var any: Any {
            switch self {
            case .int(let value): value
            case .string(let value): value
            case .object(let fields): fields.mapValues(\.any)
            }
        }

        var json: Data { (try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys])) ?? Data() }
    }

    /// The developer API's body of a write (3.3–3.6), integers only; nil when the model has none on this route.
    /// `xboost`: the DELTA Pro's current X-Boost (`inv.cfgAcXboost`), sent with its AC write as the newer page does.
    static func developerBody(_ write: EcoFlowWrite, model: EcoFlowModel, serial: String, id: Int, xboost: Int? = nil) -> Body? {
        guard let table = table(model) else { return nil }
        switch write {
        case .output(let output, _): guard table.developer.contains(output) else { return nil }
        case .chargeLimit, .dischargeLimit: guard table.developerLimits else { return nil }
        // No source writes the light on the developer API (8: EcoFlow publishes no RIVER 3 page).
        case .lightMode: return nil
        }
        func module(_ type: Int, _ operation: String, _ params: [String: Body]) -> Body {
            .object(["id": .int(id), "version": .string("1.0"), "sn": .string(serial), "moduleType": .int(type),
                     "operateType": .string(operation), "params": .object(params)])
        }
        func tcp(_ params: [String: Body]) -> Body {
            .object(["sn": .string(serial), "params": .object(params.merging(["cmdSet": .int(32)]) { $1 })])
        }
        func command(_ code: String, _ params: [String: Body]) -> Body {
            .object(["sn": .string(serial), "cmdCode": .string(code), "params": .object(params)])
        }
        switch (table.family, write) {
        case (.delta2, .output(.dc12v, let on)), (.delta2Max, .output(.dc12v, let on)), (.river2, .output(.dc12v, let on)):
            return module(5, "mpptCar", ["enabled": .int(on ? 1 : 0)])
        case (.delta2, .output(.usb, let on)), (.delta2Max, .output(.usb, let on)):
            return module(1, "dcOutCfg", ["enabled": .int(on ? 1 : 0)])
        case (.delta2, .chargeLimit(let value)), (.delta2Max, .chargeLimit(let value)), (.river2, .chargeLimit(let value)):
            return module(2, "upsConfig", ["maxChgSoc": .int(value)])
        case (.delta2, .dischargeLimit(let value)), (.delta2Max, .dischargeLimit(let value)), (.river2, .dischargeLimit(let value)):
            return module(2, "dsgCfg", ["minDsgSoc": .int(value)])
        case (.deltaPro, .output(.ac, let on)):
            var params: [String: Body] = ["id": .int(66), "enabled": .int(on ? 1 : 0)]
            if let xboost { params["xboost"] = .int(xboost) }
            return tcp(params)
        case (.deltaPro, .output(.dc12v, let on)): return tcp(["id": .int(81), "enabled": .int(on ? 1 : 0)])
        case (.deltaPro, .chargeLimit(let value)): return tcp(["id": .int(49), "maxChgSoc": .int(value)])
        case (.deltaPro, .dischargeLimit(let value)): return tcp(["id": .int(51), "minDsgSoc": .int(value)])
        case (.deltaProUltra, .output(.dc12v, let on)): return command("YJ751_PD_DC_SWITCH_SET", ["enable": .int(on ? 1 : 0)])
        case (.deltaProUltra, .chargeLimit(let value)): return command("YJ751_PD_CHG_SOC_MAX_SET", ["maxChgSoc": .int(value)])
        case (.deltaProUltra, .dischargeLimit(let value)): return command("YJ751_PD_DSG_SOC_MIN_SET", ["minDsgSoc": .int(value)])
        case (.powerStream, .chargeLimit(let value)): return command("WN511_SET_BAT_UPPER_PACK", ["upperLimit": .int(value)])
        case (.powerStream, .dischargeLimit(let value)): return command("WN511_SET_BAT_LOWER_PACK", ["lowerLimit": .int(value)])
        default: return nil
        }
    }
}
