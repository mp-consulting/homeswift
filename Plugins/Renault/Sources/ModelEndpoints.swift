import Foundation

/// The library's short names for the vehicle endpoints (docs/clean-room/Renault.md, 1.2), each with its default path
/// under `<kamereonRoot>/commerce/v1/accounts/<accountId>/kamereon`.
enum Endpoint: String, Sendable, CaseIterable, Codable {
    case batteryStatus = "battery-status"
    case cockpit
    case hvacStatus = "hvac-status"
    case hvacSettings = "hvac-settings"
    case location
    case lockStatus = "lock-status"
    case pressure
    case resState = "res-state"
    case chargeMode = "charge-mode"
    case chargingSettings = "charging-settings"
    case chargeSchedule = "charge-schedule"
    case chargeHistory = "charge-history"
    case charges
    case hvacHistory = "hvac-history"
    case hvacSessions = "hvac-sessions"
    case notificationSettings = "notification-settings"
    case socLevels = "soc-levels"
    case alerts
    case hvacStart = "actions/hvac-start"
    case hvacStop = "actions/hvac-stop"
    case chargeStart = "actions/charge-start"
    case chargeStop = "actions/charge-stop"
    case chargeSetMode = "actions/charge-set-mode"
    case chargeSetSchedule = "actions/charge-set-schedule"
    case hvacSetSchedule = "actions/hvac-set-schedule"
    case hornStart = "actions/horn-start"
    case lightsStart = "actions/lights-start"
    case refreshLocation = "actions/refresh-location"

    var defaultPath: String {
        switch self {
        case .batteryStatus: "/kca/car-adapter/v2/cars/{vin}/battery-status"
        case .socLevels: "/kcm/v1/vehicles/{vin}/ev/soc-levels"
        case .alerts: "/vehicles/{vin}/alerts"
        case .hvacStart, .hvacStop: "/kca/car-adapter/v1/cars/{vin}/actions/hvac-start"
        case .chargeStart, .chargeStop: "/kca/car-adapter/v1/cars/{vin}/actions/charging-start"
        case .chargeSetMode: "/kca/car-adapter/v1/cars/{vin}/actions/charge-mode"
        case .chargeSetSchedule: "/kca/car-adapter/v2/cars/{vin}/actions/charge-schedule"
        case .hvacSetSchedule: "/kca/car-adapter/v2/cars/{vin}/actions/hvac-schedule"
        case .hornStart, .lightsStart: "/kca/car-adapter/v1/cars/{vin}/actions/horn-lights"
        case .refreshLocation: "/kca/car-adapter/v1/cars/{vin}/actions/refresh-location"
        default: "/kca/car-adapter/v1/cars/{vin}/\(rawValue)"
        }
    }
}

/// What a model's endpoint does differently from the default: the request body (4.4, 4.6).
enum EndpointMode: String, Sendable, Equatable {
    case `default`
    /// Climate stop with `"action": "stop"` rather than `"cancel"`.
    case kcaStop = "kca-stop"
    /// kcm `charge/start`, `charge/schedule`: JSON:API bodies.
    case kcm
    /// kcm `charge/pause-resume`: `ChargePauseResume` with `resume` or `pause`.
    case kcmPauseResume = "kcm-pause-resume"
    /// kcm `ev/settings`: the settings document read, its programs turned off, and written back.
    case kcmSettings = "kcm-settings"
}

/// Where an endpoint goes for a model, or that it has none.
enum Resolution: Sendable, Equatable {
    case supported(path: String, mode: EndpointMode)
    case unsupported(reason: String)

    static let `default` = Resolution.supported(path: "", mode: .default)
    static let hvacStopWithStop = Resolution.supported(path: "/kca/car-adapter/v1/cars/{vin}/actions/hvac-start", mode: .kcaStop)
    static let kcmChargeStart = Resolution.supported(path: "/kcm/v1/vehicles/{vin}/charge/start", mode: .kcm)
    static let kcmChargeSchedule = Resolution.supported(path: "/kcm/v1/vehicles/{vin}/charge/schedule", mode: .kcm)
    static let kcmPauseResume = Resolution.supported(path: "/kcm/v1/vehicles/{vin}/charge/pause-resume", mode: .kcmPauseResume)
    static let kcmSettings = Resolution.supported(path: "/kcm/v1/vehicles/{vin}/ev/settings", mode: .kcmSettings)
    static func none(_ reason: String) -> Resolution { .unsupported(reason: reason) }

    var isSupported: Bool { if case .supported = self { true } else { false } }
}

/// The per-model endpoint table (1.3), as data. A model not in it, or a key a model does not list, takes the default
/// (`ModelEndpoints.resolve` says which, once, so the log can warn); `.none` is an endpoint the model refuses, never
/// requested. The other models are given as differences from the Renault 5's row, as the specification lists them.
enum ModelEndpoints {
    typealias Row = [Endpoint: Resolution]

    /// Renault 5 E-Tech (AmpR Small): the car of the plugin's first user.
    static let renault5: Row = [
        .batteryStatus: .default, .cockpit: .default, .hvacStatus: .default, .hvacSettings: .default, .location: .default,
        .socLevels: .default, .alerts: .default, .charges: .default,
        .chargeSchedule: .kcmSettings,
        .hvacStart: .default, .hvacStop: .hvacStopWithStop,
        .chargeStart: .kcmSettings,
        .chargeStop: .none("not supported, use the charger to stop"),
        .hornStart: .default, .lightsStart: .default, .refreshLocation: .default,
        .chargeSetMode: .none("err.func.wired.forbidden"),
        .chargeSetSchedule: .none("err.func.wired.forbidden"),
        .hvacSetSchedule: .none("err.func.wired.forbidden"),
        .chargeMode: .none("forbidden"),
        .chargingSettings: .none("forbidden"),
        .chargeHistory: .none("not-found"),
        .hvacHistory: .none("not-found"), .hvacSessions: .none("not-found"),
        .lockStatus: .none("err.func.wired.notFound"),
        .pressure: .none("notFound"),
        .resState: .none("forbidden"),
        .notificationSettings: .none("err.func.vcps.users-helper.get-notification-settings.error"),
    ]

    static func like(_ row: Row, _ changes: Row = [:], unlisted: [Endpoint] = []) -> Row {
        var result = row.merging(changes) { _, new in new }
        for key in unlisted { result.removeValue(forKey: key) }
        return result
    }

    static let table: [String: Row] = [
        "R5E1VE": renault5,
        // Renault 4 E-Tech.
        "A4E1VE": like(renault5, unlisted: [.hvacStop, .refreshLocation, .alerts, .hvacSettings, .chargingSettings]),
        // Alpine A290: hvac-settings answers errorCode 502000 on every call.
        "A5E1AE": like(renault5, [.hvacSettings: .none("502000"), .alerts: .none("not supported")]),
        // Renault Twingo E-Tech: only its reads are listed; its actions take the defaults.
        "TWE1VE": [
            .batteryStatus: .default, .cockpit: .default, .hvacStatus: .default, .location: .default, .socLevels: .default,
            .chargeSchedule: .kcmSettings,
        ],
        // Dacia Spring MY25.
        "XBG2VE": like(renault5, [.chargeStop: .none("forbidden on kcm pause-resume, invalid-body on default")]),
        // Scenic E-Tech.
        "XCB1SE": like(renault5, unlisted: [.hvacStop]),
        // Megane E-Tech.
        "XCB1VE": like(renault5, [.chargeStart: .kcmChargeStart, .chargeSchedule: .kcmChargeSchedule, .chargingSettings: .default]),
        // Master E-Tech.
        "XDD1VE": like(renault5, [.chargeSetMode: .default], unlisted: [.hvacStop]),
        // ZOE phase 1: no location; power in watts.
        "X101VE": [.location: .none("not supported")],
        // ZOE phase 2.
        "X102VE": [.chargeStart: .default, .chargeStop: .kcmPauseResume, .chargingSettings: .default, .chargeMode: .none("not supported")],
        // Dacia Spring.
        "XBG1VE": [.chargeStart: .kcmPauseResume, .chargeStop: .kcmPauseResume, .hvacStop: .hvacStopWithStop],
    ]

    /// Whether the model reports charging power in watts rather than kilowatts (ZOE phase 1).
    static func reportsWatts(model: String?) -> Bool { model == "X101VE" }

    /// Where `endpoint` goes for `model`, with its path filled in for `vin`; `documented` is false when the default was
    /// taken for a model the table does not have, or a key its row does not list (the log warns once).
    static func resolve(_ endpoint: Endpoint, model: String?, vin: String) -> (resolution: Resolution, documented: Bool) {
        let found = model.flatMap { table[$0]?[endpoint] }
        let documented = model == nil || found != nil
        switch found ?? .default {
        case .unsupported(let reason):
            return (.unsupported(reason: reason), true)
        case .supported(let path, let mode):
            let template = path.isEmpty ? endpoint.defaultPath : path
            return (.supported(path: template.replacingOccurrences(of: "{vin}", with: vin), mode: mode), documented)
        }
    }

    /// Whether the table has a row for `model`.
    static func isKnown(_ model: String?) -> Bool { model.map { table[$0] != nil } ?? true }
}
