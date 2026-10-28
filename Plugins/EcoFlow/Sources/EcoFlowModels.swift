import Foundation

/// The EcoFlow models the plugin reads, known by the first characters of their serial number, and where each reading
/// is on each route.
///
/// A device's readings are one flat map of numbers, whichever route they come from:
/// - the developer API's quota keys, as its REST quota and its MQTT pushes send them (`powGetPvSum`, `pd.wattsInSum`,
///   `20_1.batSoc`);
/// - the EcoFlow app's JSON quotas, for the older devices, with the same names (`pd.soc`, `bms_bmsStatus.inWatts`);
/// - the EcoFlow app's protobuf messages, each field as `<cmdFunc>_<cmdId>.<field>`, a nested field's numbers joined by
///   dots (`32_2.1.15`).
///
/// The models checked on a real device are marked `tested` on that route. The others were mapped from what open-source
/// projects found by reading the devices (README.md, "Models"): they are shown as untested on the plugin's page.
struct EcoFlowModel: Sendable, Equatable {
    /// The two routes the plugin reads devices from.
    enum Route: Sendable, Hashable {
        case developer, app
    }

    /// How the EcoFlow app's stream speaks to the model: protobuf messages, or JSON quotas (the older devices). The
    /// read request is sent in the same form.
    enum Format: Sendable, Equatable {
        case protobuf, json
    }

    /// Where each reading is: the first of a reading's keys the device reports is the one read. A key's value is
    /// multiplied by its `scales` entry (a device that reports tenths of a watt, or a battery whose power is positive
    /// while discharging). Without a solar key, the solar is the panels' sum; without a battery key, the battery's
    /// power is what comes in less what goes out.
    struct Keys: Sendable, Equatable {
        var stateOfCharge: [String] = []
        var solar: [String] = []
        var home: [String] = []
        var grid: [String] = []
        var battery: [String] = []
        var input: [String] = []
        var output: [String] = []
        var acIn: [String] = []
        var acOut: [String] = []
        var usbA: [String] = []
        var usbC: [String] = []
        /// A STREAM's grid connection port and its two sockets; its panel inputs, PV1 first.
        var ac: [String] = []
        var ac1: [String] = []
        var ac2: [String] = []
        var panels: [String] = []
        /// The device's estimate of the minutes to a full battery and to an empty one.
        var timeToFull: [String] = []
        var timeToEmpty: [String] = []
        var scales: [String: Double] = [:]

        /// Every key read: the app's route keeps only these of a device's readings.
        var all: Set<String> {
            Set([stateOfCharge, solar, home, grid, battery, input, output, acIn, acOut, usbA, usbC, ac, ac1, ac2, panels,
                 timeToFull, timeToEmpty].joined())
        }
    }

    let name: String
    let prefixes: [String]
    let kind: EcoFlowDevice.Kind
    /// How the app's stream speaks to the model; its keys there, and on the developer API. nil: the route does not read it.
    let format: Format
    let app: Keys?
    let developer: Keys?
    /// The routes on which the model was checked on a real device against the EcoFlow app's screens.
    let tested: Set<Route>

    func keys(on route: Route) -> Keys? {
        route == .app ? app : developer
    }

    /// The model whose prefix starts the serial number; the longest prefix wins.
    static func model(serial: String) -> EcoFlowModel? {
        for length in prefixLengths {
            if let prefix = String(serial.utf8.prefix(length)), prefix.utf8.count == length, let model = byPrefix[prefix] { return model }
        }
        return nil
    }

    /// Each prefix's model, and the prefixes' lengths, longest first: a lookup reads the index once per length.
    private static let byPrefix: [String: EcoFlowModel] = all.reduce(into: [:]) { index, model in
        for prefix in model.prefixes where index[prefix] == nil { index[prefix] = model }
    }
    private static let prefixLengths = Set(all.flatMap(\.prefixes).map(\.utf8.count)).sorted(by: >)

    /// EcoFlow devices with no battery of their own for HomeKit's Battery service, or none the plugin can read: they
    /// are left out, and the log says so once.
    static let leftOut: [(name: String, prefixes: [String])] = [
        ("Smart Plug", ["HW52"]),
        ("Smart Plug (Shelly)", ["SM2A"]),
        ("Smart Meter (Shelly Pro 3EM)", ["SM3A"]),
        ("Ecotracker", ["0151"]),
        ("STREAM Microinverter", ["BK01", "BK02", "N011"]),
        ("Smart Meter", ["BK21"]),
        ("Smart Generator", ["DGEB", "G371", "G351"]),
        ("Alternator Charger", ["F371", "F372", "DC01"]),
        ("WAVE", ["KT21", "AC71"]),
        ("PowerPulse", ["C101", "C201", "C376"]),
        ("Smart Home Panel", ["SP10"]),
    ]

    /// A serial number in the log: its model's four characters alone.
    static func masked(_ serial: String) -> String { "\(serial.prefix(4))…" }

    /// The model or left-out device the serial number names, for the log.
    static func describe(serial: String) -> String {
        if let model = model(serial: serial) { return model.name }
        if let other = leftOut.first(where: { $0.prefixes.contains { serial.hasPrefix($0) } }) { return other.name }
        return "an unknown model"
    }

    // MARK: - The keys of each family

    /// The status message most of the recent models send (254/21, `DisplayPropertyUpload`): its field numbers are the
    /// same on every model. The precise state of charge is in the battery's message (32/2, field 1 then 15), the
    /// system's in the status message (262), and the battery pack's whole percentage in the pack's message (32/50, 6);
    /// field 270 of the status message is the charge limit. The outputs come negative, and are read as their size.
    /// The minutes to full and to empty are 269 and 268 (the battery's message has them too, as 12 and 13).
    static let display = Keys(
        stateOfCharge: ["32_2.1.15", "254_21.262", "32_50.6"],
        input: ["254_21.3"], output: ["254_21.4"], acIn: ["254_21.54"], acOut: ["254_21.368"],
        usbA: ["254_21.9"], usbC: ["254_21.11"],
        timeToFull: ["254_21.269", "32_2.1.12"], timeToEmpty: ["254_21.268", "32_2.1.13"])

    /// A power bank's status message: the totals and the percentage.
    static let powerBank = Keys(stateOfCharge: ["254_21.262"], input: ["254_21.3"], output: ["254_21.4"],
                                timeToFull: ["254_21.269"], timeToEmpty: ["254_21.268"])

    /// The same models on the developer API: the status message's fields under their names.
    static let displayDeveloper = Keys(
        stateOfCharge: ["cmsBattSoc"], input: ["powInSumW"], output: ["powOutSumW"], acIn: ["powGetAcIn"],
        acOut: ["powGetAcOut", "powGetAc"], timeToFull: ["cmsChgRemTime"], timeToEmpty: ["cmsDsgRemTime"])

    /// A STREAM on the app's stream: the status message (254/21) has the system's flows, the battery pack's message
    /// (32/50) this unit's own percentage (25, precise; 6, whole). The status message's field 6 is the backup state, and
    /// its 262 the system's percentage, reported by the system's main unit only (an AC Pro reads 0 there). This unit's
    /// minutes to full and to empty are 255 and 254, the system's 269 and 268.
    static let streamApp = Keys(
        stateOfCharge: ["32_50.25", "32_50.6"],
        solar: ["254_21.517"], home: ["254_21.516"], grid: ["254_21.515"], battery: ["254_21.518"],
        ac: ["254_21.616"], ac1: ["254_21.1210"], ac2: ["254_21.1211"],
        panels: ["254_21.361", "254_21.70", "254_21.996", "254_21.997"],
        timeToFull: ["254_21.255", "254_21.269"], timeToEmpty: ["254_21.254", "254_21.268"])

    /// A STREAM on the developer API: `f32ShowSoc` is this unit's percentage as the app shows it (the MQTT pushes);
    /// the REST quota has the system's `cmsBattSoc` alone.
    static let streamDeveloper = Keys(
        stateOfCharge: ["f32ShowSoc", "cmsBattSoc"],
        solar: ["powGetPvSum"], home: ["powGetSysLoad"], grid: ["powGetSysGrid"], battery: ["powGetBpCms"],
        ac: ["gridConnectionPower"], ac1: ["powGetSchuko1"], ac2: ["powGetSchuko2"],
        panels: ["powGetPv", "powGetPv2", "powGetPv3", "powGetPv4"],
        timeToFull: ["bmsChgRemTime", "cmsChgRemTime"], timeToEmpty: ["bmsDsgRemTime", "cmsDsgRemTime"])

    /// The older portable stations' JSON quotas, the same on the app's stream and the developer API: the display's
    /// percentage (`lcdShowSoc`, the overall one with extra batteries), the totals, the inverter's AC and the solar
    /// charger. A DELTA Pro or a DELTA Max reports its solar in tenths of a watt.
    static func json(solarInTenths: Bool = false) -> Keys {
        var keys = Keys(
            stateOfCharge: ["bms_emsStatus.f32LcdShowSoc", "bms_emsStatus.lcdShowSoc", "ems.f32LcdShowSoc", "ems.lcdShowSoc",
                            "pd.soc", "bms_bmsStatus.f32ShowSoc", "bms_bmsStatus.soc", "bmsMaster.soc"],
            solar: ["mppt.inWatts"],
            input: ["pd.wattsInSum", "bms_bmsStatus.inWatts"], output: ["pd.wattsOutSum", "bms_bmsStatus.outWatts"],
            acIn: ["inv.inputWatts"], acOut: ["inv.outputWatts"],
            timeToFull: ["bms_emsStatus.chgRemainTime", "ems.chgRemainTime"],
            timeToEmpty: ["bms_emsStatus.dsgRemainTime", "ems.dsgRemainTime"])
        if solarInTenths { keys.scales["mppt.inWatts"] = 0.1 }
        return keys
    }

    /// A PowerStream microinverter: its heartbeat (20/1, `20_1.` on the developer API) in tenths of a watt: the panels
    /// (19, 24), the battery's percentage (31) and power (29, positive while the battery supplies the inverter) and the
    /// inverter's output to the home (38). It has no grid reading; its solar is its panels'.
    static func powerStream(pv1: String, pv2: String, soc: String, battery: String, home: String) -> Keys {
        Keys(stateOfCharge: [soc], home: [home], battery: [battery], panels: [pv1, pv2],
             scales: [pv1: 0.1, pv2: 0.1, battery: -0.1, home: 0.1])
    }

    // MARK: - The models

    static let all: [EcoFlowModel] = [
        // STREAM: checked on an Ultra and an AC Pro, on both routes.
        EcoFlowModel(name: "STREAM Ultra", prefixes: ["BK11", "ES11"], kind: .stream, format: .protobuf,
                     app: streamApp, developer: streamDeveloper, tested: [.app, .developer]),
        EcoFlowModel(name: "STREAM AC Pro", prefixes: ["BK31"], kind: .stream, format: .protobuf,
                     app: streamApp, developer: streamDeveloper, tested: [.app, .developer]),
        EcoFlowModel(name: "STREAM Ultra X", prefixes: ["BK61"], kind: .stream, format: .protobuf,
                     app: streamApp, developer: streamDeveloper, tested: []),
        EcoFlowModel(name: "STREAM Pro", prefixes: ["BK12"], kind: .stream, format: .protobuf,
                     app: streamApp, developer: streamDeveloper, tested: []),
        EcoFlowModel(name: "STREAM Max", prefixes: ["BK41"], kind: .stream, format: .protobuf,
                     app: streamApp, developer: streamDeveloper, tested: []),
        EcoFlowModel(name: "STREAM AC", prefixes: ["BK51"], kind: .stream, format: .protobuf,
                     app: streamApp, developer: streamDeveloper, tested: []),

        // The status message's portable stations: the RIVER 3 and RIVER 3 Plus checked on the app's stream.
        EcoFlowModel(name: "RIVER 3", prefixes: ["R651", "R653", "R654", "R655"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: [.app]),
        EcoFlowModel(name: "RIVER 3 Plus", prefixes: ["R631", "R634", "R635"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: [.app]),
        EcoFlowModel(name: "DELTA 3", prefixes: ["P231"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: []),
        EcoFlowModel(name: "DELTA 3 Plus", prefixes: ["P351"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: []),
        EcoFlowModel(name: "DELTA 3 Classic", prefixes: ["P321", "P322"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: []),
        EcoFlowModel(name: "DELTA 3 Air", prefixes: ["PR11", "PR12", "PR21"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: []),
        EcoFlowModel(name: "DELTA 3 Max", prefixes: ["D3N1"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: []),
        EcoFlowModel(name: "DELTA 3 Max Plus", prefixes: ["D3M1"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: []),
        EcoFlowModel(name: "DELTA 3 Ultra", prefixes: ["D751"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: []),
        EcoFlowModel(name: "DELTA 3 Ultra Plus", prefixes: ["D511"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: []),
        EcoFlowModel(name: "DELTA Pro 3", prefixes: ["MR51", "MR54"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: []),
        EcoFlowModel(name: "DELTA Pro Ultra X", prefixes: ["P101"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: []),
        EcoFlowModel(name: "GLACIER Classic", prefixes: ["RF45"], kind: .portable, format: .protobuf,
                     app: display, developer: displayDeveloper, tested: []),

        // Power banks: the status message without AC, and no battery message: the percentage is 262 (a RAPID Pro X read
        // 5.31 there while charging from 4.85 % in the app; its field 5 stays at 100). The RAPID Pro X checked on the
        // app's stream.
        EcoFlowModel(name: "RAPID Pro X", prefixes: ["P513"], kind: .powerBank, format: .protobuf,
                     app: powerBank, developer: nil, tested: [.app]),
        EcoFlowModel(name: "RAPID Pro", prefixes: ["P521"], kind: .powerBank, format: .protobuf,
                     app: powerBank, developer: nil, tested: []),

        // The older portable stations, in JSON on both routes.
        EcoFlowModel(name: "DELTA 2", prefixes: ["R331", "R335"], kind: .portable, format: .json,
                     app: json(), developer: json(), tested: []),
        EcoFlowModel(name: "DELTA 2 Max", prefixes: ["R351", "R354"], kind: .portable, format: .json,
                     app: json(), developer: json(), tested: []),
        EcoFlowModel(name: "DELTA 2 Plus", prefixes: ["D361", "D365"], kind: .portable, format: .json,
                     app: json(), developer: json(), tested: []),
        EcoFlowModel(name: "RIVER 2", prefixes: ["R601", "R603"], kind: .portable, format: .json,
                     app: json(), developer: json(), tested: []),
        EcoFlowModel(name: "RIVER 2 Max", prefixes: ["R611", "R613"], kind: .portable, format: .json,
                     app: json(), developer: json(), tested: []),
        EcoFlowModel(name: "RIVER 2 Pro", prefixes: ["R621", "R623"], kind: .portable, format: .json,
                     app: json(), developer: json(), tested: []),
        EcoFlowModel(name: "DELTA Pro", prefixes: ["DCA", "DCK", "DCE", "DCC", "DCU", "DCT", "DCG", "DCS", "DCF", "DCJ", "R511"],
                     kind: .portable, format: .json, app: json(solarInTenths: true), developer: json(solarInTenths: true), tested: []),
        EcoFlowModel(name: "DELTA Max", prefixes: ["DAEB"], kind: .portable, format: .json,
                     app: json(solarInTenths: true), developer: json(solarInTenths: true), tested: []),
        EcoFlowModel(name: "DELTA Mini", prefixes: ["DBAB"], kind: .portable, format: .json,
                     app: json(solarInTenths: true), developer: json(solarInTenths: true), tested: []),
        EcoFlowModel(name: "GLACIER", prefixes: ["BX11"], kind: .portable, format: .json,
                     app: json(), developer: json(), tested: []),

        // DELTA Pro Ultra: its own message on the app's stream, which is not mapped; the developer API documents it.
        EcoFlowModel(name: "DELTA Pro Ultra", prefixes: ["Y711"], kind: .portable, format: .protobuf, app: nil,
                     developer: Keys(stateOfCharge: ["hs_yj751_pd_appshow_addr.soc"],
                                     input: ["hs_yj751_pd_appshow_addr.wattsInSum"], output: ["hs_yj751_pd_appshow_addr.wattsOutSum"]),
                     tested: []),

        // Home systems: solar, home, grid and battery.
        EcoFlowModel(name: "PowerStream", prefixes: ["HW51"], kind: .home, format: .protobuf,
                     app: powerStream(pv1: "20_1.19", pv2: "20_1.24", soc: "20_1.31", battery: "20_1.29", home: "20_1.38"),
                     developer: powerStream(pv1: "20_1.pv1InputWatts", pv2: "20_1.pv2InputWatts", soc: "20_1.batSoc",
                                            battery: "20_1.batInputWatts", home: "20_1.invOutputWatts"),
                     tested: []),
        // PowerOcean: its energy flows (96/33), the battery positive while charging.
        EcoFlowModel(name: "PowerOcean", prefixes: ["HJ31", "HJ37"], kind: .home, format: .protobuf,
                     app: Keys(stateOfCharge: ["96_33.5"], solar: ["96_33.3"], home: ["96_33.1"], grid: ["96_33.2"], battery: ["96_33.4"]),
                     developer: Keys(stateOfCharge: ["bpSoc"], solar: ["mpptPwr"], home: ["sysLoadPwr"], grid: ["sysGridPwr"], battery: ["bpPwr"]),
                     tested: []),
        EcoFlowModel(name: "PowerOcean Fit", prefixes: ["HC31"], kind: .home, format: .protobuf,
                     app: Keys(stateOfCharge: ["96_33.7"], solar: ["96_33.4"], home: ["96_33.8"], grid: ["96_33.1"], battery: ["96_33.3"]),
                     developer: nil, tested: []),
        // Smart Home Panel 3: the status message's system flows, as a STREAM's.
        EcoFlowModel(name: "Smart Home Panel 3", prefixes: ["HR62", "HR63", "HR6C"], kind: .home, format: .protobuf,
                     app: Keys(stateOfCharge: ["254_21.262"], solar: ["254_21.517"], home: ["254_21.516"], grid: ["254_21.515"],
                               battery: ["254_21.518"]),
                     developer: nil, tested: []),
        // Smart Home Panel 2: the developer API documents its backup batteries' percentage, the grid and the circuits'
        // load; its messages on the app's stream are not mapped.
        EcoFlowModel(name: "Smart Home Panel 2", prefixes: ["HD31", "SH20"], kind: .home, format: .protobuf, app: nil,
                     developer: Keys(stateOfCharge: ["backupIncreInfo.backupBatPer"], home: ["wattInfo.allHallWatt"],
                                     grid: ["wattInfo.gridWatt"]),
                     tested: []),
    ]
}
