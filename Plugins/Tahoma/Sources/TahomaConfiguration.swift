import Foundation
import HomeswiftAI

extension TahomaPlugin {
    /// homebridge-tahoma's block (docs/clean-room/Tahoma.md, 2.1), so a Homebridge configuration works unchanged. Every
    /// option is optional; the defaults are in code. `preferLocalAPI` is Homeswift's own.
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        /// Which Overkiz server (`somfy_europe` by default) or `local`, in any case, aliases included.
        public var service: String?
        /// Cloud: the account's e-mail or user id. Local: the gateway's PIN (`1234-5678-9012`) or IPv4 address.
        public var user: String?
        /// Cloud: the account's password. Local: the Developer Mode token.
        public var password: String?
        /// Seconds between event fetches when nothing runs; 0 fetches only while a command runs.
        public var pollingPeriod: LooseNumber?
        /// Minutes between full refreshes of every device's states.
        public var refreshPeriod: LooseNumber?
        /// Seconds between event fetches while a command runs.
        public var execPollingPeriod: LooseNumber?
        /// Puts the scenarios (action groups) in HomeKit as switches: `true`, or a list of their names.
        public var exposeScenarios: ScenarioChoice?
        /// uiClasses, widgets, controllable names, labels or protocols left out.
        public var exclude: [String]?
        /// Per-device options by `key` (a uiClass, a widget, a label, a protocol, a deviceURL or the accessory's UUID).
        public var devicesConfig: [JSONValue]?
        /// Logs the debug lines at info level.
        public var debug: Bool?
        /// A base URL every request goes to instead, with `X-Forward-Host` naming the server.
        public var proxy: String?
        /// For a Somfy account with a single gateway: mint a Developer Mode token and talk to the gateway on the local
        /// network, the cloud when it does not answer. True by default.
        public var preferLocalAPI: Bool?
    }

    /// `exposeScenarios`: a boolean, or the names of the scenarios to expose (homebridge-tahoma's README form, which it
    /// did not honour: an array was truthy there, so it exposed every scenario).
    public enum ScenarioChoice: Decodable, Sendable, Equatable {
        case all(Bool)
        case named([String])

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = .all(flag)
            } else if let names = try? container.decode([String].self) {
                self = .named(names)
            } else if let number = try? container.decode(Double.self) {
                self = .all(number != 0)
            } else if let text = try? container.decode(String.self) {
                self = .all(!text.isEmpty && text != "false")
            } else {
                self = .all(false)
            }
        }

        /// Whether a scenario of this label is exposed.
        func exposes(_ label: String) -> Bool {
            switch self {
            case .all(let flag): flag
            case .named(let names): names.contains(label)
            }
        }

        var exposesAny: Bool {
            switch self {
            case .all(let flag): flag
            case .named(let names): !names.isEmpty
            }
        }
    }
}

/// A number, or a numeric string; anything else (or NaN) is nil.
public struct LooseNumber: Decodable, Sendable, Equatable {
    public var value: Double?

    public init(_ value: Double?) { self.value = value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number.isFinite ? number : nil
        } else if let text = try? container.decode(String.self) {
            value = Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        } else {
            value = nil
        }
    }
}

/// The Overkiz servers (2.2): `local`, a gateway's own API, or a cloud by brand and region.
public enum OverkizService: String, Sendable, CaseIterable, Codable {
    case local
    case somfyEurope = "somfy_europe"
    case somfyAustralia = "somfy_australia"
    case somfyNorthAmerica = "somfy_north_america"
    case cozytouch
    case flexom
    case rexel
    case hiKumo = "hi_kumo"

    /// The value of `service`, case aside, or one of its aliases; nil for anything else.
    public init?(configured: String) {
        let value = configured.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "tahoma", "tahoma_switch", "connexoon": self = .somfyEurope
        case "connexoon_rts": self = .somfyAustralia
        default:
            guard let service = OverkizService(rawValue: value) else { return nil }
            self = service
        }
    }

    /// The cloud's host; nil for `local`.
    var host: String? {
        switch self {
        case .local: nil
        case .somfyEurope: "ha101-1.overkiz.com"
        case .somfyAustralia: "ha201-1.overkiz.com"
        case .somfyNorthAmerica: "ha401-1.overkiz.com"
        case .cozytouch: "ha110-1.overkiz.com"
        case .flexom: "ha108-1.overkiz.com"
        case .rexel: "ha112-1.overkiz.com"
        case .hiKumo: "ha117-1.overkiz.com"
        }
    }

    /// Somfy's clouds, whose gateways have a local API a token can be minted for (3.5).
    var isSomfy: Bool { self == .somfyEurope || self == .somfyAustralia || self == .somfyNorthAmerica }

    var title: String {
        switch self {
        case .local: "Somfy TaHoma, Connexoon or Switch on the local network (Developer Mode)"
        case .somfyEurope: "Somfy TaHoma or Connexoon, Europe"
        case .somfyAustralia: "Somfy Connexoon RTS, Oceania"
        case .somfyNorthAmerica: "Somfy TaHoma, North America"
        case .cozytouch: "Atlantic, Thermor or Sauter Cozytouch"
        case .flexom: "Bouygues Flexom"
        case .rexel: "Rexel Energeasy Connect"
        case .hiKumo: "Hitachi Hi Kumo"
        }
    }
}
