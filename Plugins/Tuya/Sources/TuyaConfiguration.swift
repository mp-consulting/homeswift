import Foundation
import HomeswiftAI
import HomeswiftPlugin

/// The `TuyaPlatform` block, as homebridge-tuya-platform reads it: everything under `options`.
public struct TuyaConfiguration: Decodable, Sendable {
    public var name: String?
    public var options: Options?
    /// `options` as written, so Setup can merge into it without losing the keys it does not set.
    public var optionsJSON: JSONValue?

    public struct Options: Decodable, Sendable {
        /// `"1"` a Custom project, `"2"` a Smart Home project (the app account linked to a cloud project). The numbers
        /// 1 and 2 are read too.
        public var projectType: String?
        public var accessId: String?
        /// The project's Access Secret. Not a secret-named key: Setup keeps it in the vault, and a block's moves there.
        public var accessKey: String?
        public var endpoint: String?
        public var countryCode: Int?
        public var username: String?
        public var password: String?
        public var appSchema: String?
        public var homeWhitelist: [Int]?
        public var deviceOverrides: [DeviceOverride]?
        public var debug: Bool?
        public var debugLevel: String?

        enum CodingKeys: String, CodingKey {
            case projectType, accessId, accessKey, endpoint, countryCode, username, password, appSchema, homeWhitelist, deviceOverrides, debug,
                 debugLevel
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            projectType = Self.lenientString(try container.decodeIfPresent(JSONValue.self, forKey: .projectType))
            accessId = try container.decodeIfPresent(String.self, forKey: .accessId)
            accessKey = try container.decodeIfPresent(String.self, forKey: .accessKey)
            endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
            countryCode = Self.lenientString(try container.decodeIfPresent(JSONValue.self, forKey: .countryCode)).flatMap { Int($0) }
            username = try container.decodeIfPresent(String.self, forKey: .username)
            password = try container.decodeIfPresent(String.self, forKey: .password)
            appSchema = try container.decodeIfPresent(String.self, forKey: .appSchema)
            homeWhitelist = (try container.decodeIfPresent([JSONValue].self, forKey: .homeWhitelist))?.compactMap { Self.lenientString($0).flatMap { Int($0) } }
            deviceOverrides = try container.decodeIfPresent([DeviceOverride].self, forKey: .deviceOverrides)
            debug = try container.decodeIfPresent(Bool.self, forKey: .debug)
            debugLevel = try container.decodeIfPresent(String.self, forKey: .debugLevel)
        }

        init() {}

        /// A string, or a whole number as its digits.
        static func lenientString(_ value: JSONValue?) -> String? {
            switch value {
            case .string(let text): text.trimmingCharacters(in: .whitespaces)
            case .number(let number) where number.rounded() == number && abs(number) < 1e15: String(Int64(number))
            default: nil
            }
        }
    }

    /// One element of `deviceOverrides`: a device id or uuid, a product id, a scene id, or `global`.
    public struct DeviceOverride: Decodable, Sendable {
        public var id: String
        public var category: String?
        public var unbridged: Bool?
        public var adaptiveLighting: Bool?
        public var schema: [SchemaOverride]?
    }

    /// One element of an override's `schema`: a DP renamed, retyped, converted or hidden.
    public struct SchemaOverride: Decodable, Sendable {
        /// The code the device reports.
        public var code: String
        /// The code the accessories ask for instead.
        public var newCode: String?
        public var type: String?
        public var property: JSONValue?
        public var onGet: String?
        public var onSet: String?
        public var hidden: Bool?

        enum CodingKeys: String, CodingKey { case code, newCode, type, property, onGet, onSet, hidden, oldCode }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let code = try container.decodeIfPresent(String.self, forKey: .code) ?? ""
            // The older shape: `oldCode` the device's, `code` the one asked for.
            if let oldCode = try container.decodeIfPresent(String.self, forKey: .oldCode), !oldCode.isEmpty {
                self.code = oldCode
                newCode = code.isEmpty ? nil : code
            } else {
                self.code = code
                newCode = try container.decodeIfPresent(String.self, forKey: .newCode).flatMap { $0.isEmpty ? nil : $0 }
            }
            type = try container.decodeIfPresent(String.self, forKey: .type).flatMap { $0.isEmpty ? nil : $0 }
            property = try container.decodeIfPresent(JSONValue.self, forKey: .property).flatMap { $0.objectValue?.isEmpty == false ? $0 : nil }
            onGet = try container.decodeIfPresent(String.self, forKey: .onGet).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            onSet = try container.decodeIfPresent(String.self, forKey: .onSet).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
        }

        init(code: String, newCode: String? = nil, type: String? = nil, property: JSONValue? = nil, onGet: String? = nil, onSet: String? = nil,
             hidden: Bool? = nil) {
            self.code = code
            self.newCode = newCode
            self.type = type
            self.property = property
            self.onGet = onGet
            self.onSet = onSet
            self.hidden = hidden
        }

        /// The code this element answers to.
        var requestedCode: String { newCode ?? code }
    }

    enum CodingKeys: String, CodingKey { case name, options }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        options = try container.decodeIfPresent(Options.self, forKey: .options)
        optionsJSON = try container.decodeIfPresent(JSONValue.self, forKey: .options)
    }

    init(options: Options?) {
        self.options = options
    }
}

/// The two kinds of cloud project.
enum TuyaProjectType: String, Sendable {
    case custom = "1"
    case smartHome = "2"
}

/// The options checked and with their defaults, the account's secrets from the vault in place of the block's.
struct TuyaSettings: Sendable {
    var projectType: TuyaProjectType
    var accessID: String
    var accessKey: String
    /// The endpoint's host: Custom's, or Smart Home's own or the country's.
    var endpointHost: String
    var countryCode: Int
    var username: String
    var password: String
    var appSchema: String
    var homeWhitelist: [Int]?
    var overrides: [TuyaConfiguration.DeviceOverride]
    var debug: Bool
    var debugLevel: String

    /// The block's options checked as homebridge-tuya-platform checks them: the problems, or the settings.
    static func validate(_ options: TuyaConfiguration.Options?, credentials: TuyaAccountCredentials?) -> Result<TuyaSettings, TuyaConfigurationError> {
        guard let options else { return .failure(TuyaConfigurationError(["The plugin is not configured: the block has no options"])) }
        var problems: [String] = []
        let type = options.projectType.flatMap(TuyaProjectType.init(rawValue:))
        if type == nil { problems.append("options.projectType must be \"1\" (Custom) or \"2\" (Smart Home)") }
        let accessID = options.accessId?.trimmingCharacters(in: .whitespaces) ?? ""
        let accessKey = (credentials?.accessKey).flatMap { $0.isEmpty ? nil : $0 } ?? options.accessKey?.trimmingCharacters(in: .whitespaces) ?? ""
        if accessID.isEmpty { problems.append("options.accessId is required") }
        if accessKey.isEmpty { problems.append("options.accessKey is required (Setup keeps it in the vault)") }
        var endpointHost = ""
        if let endpoint = options.endpoint?.trimmingCharacters(in: .whitespaces), !endpoint.isEmpty {
            if let host = Self.host(of: endpoint) { endpointHost = host } else { problems.append("options.endpoint must be a URL") }
        }
        let password = (credentials?.password).flatMap { $0.isEmpty ? nil : $0 } ?? options.password ?? ""
        var countryCode = 0
        if type == .custom, endpointHost.isEmpty { problems.append("options.endpoint is required for a Custom project") }
        if type == .smartHome {
            if let code = options.countryCode, code >= 1 { countryCode = code } else { problems.append("options.countryCode must be a whole number from 1") }
            if options.username?.isEmpty ?? true { problems.append("options.username is required for a Smart Home project") }
            if password.isEmpty { problems.append("options.password is required for a Smart Home project (Setup keeps it in the vault)") }
            if endpointHost.isEmpty, countryCode >= 1 { endpointHost = TuyaRegion.host(countryCode: countryCode) }
        }
        let overrides = options.deviceOverrides ?? []
        var seen = Set<String>()
        for item in overrides {
            if !seen.insert(item.id).inserted { problems.append("options.deviceOverrides: the id \(item.id) is there twice") }
            var codes = Set<String>()
            for element in item.schema ?? [] where !codes.insert(element.code).inserted {
                problems.append("options.deviceOverrides: \(item.id) overrides the code \(element.code) twice")
            }
        }
        guard problems.isEmpty, let type else { return .failure(TuyaConfigurationError(problems)) }
        return .success(TuyaSettings(
            projectType: type, accessID: accessID, accessKey: accessKey, endpointHost: endpointHost, countryCode: countryCode,
            username: options.username ?? "", password: password, appSchema: options.appSchema.flatMap { $0.isEmpty ? nil : $0 } ?? "tuyaSmart",
            homeWhitelist: options.homeWhitelist, overrides: overrides, debug: options.debug ?? false, debugLevel: options.debugLevel ?? ""))
    }

    /// The host of an endpoint URL (`https://openapi.tuyaeu.com` or the host alone); the path and scheme are ignored.
    static func host(of endpoint: String) -> String? {
        let text = endpoint.contains("://") ? endpoint : "https://" + endpoint
        guard let host = URLComponents(string: text)?.host, !host.isEmpty, host.contains(".") else { return nil }
        return host
    }

    /// The override for a device (its id or uuid, then its product id, then `global`): exactly one applies.
    func override(id: String, uuid: String?, productID: String?) -> TuyaConfiguration.DeviceOverride? {
        overrides.first { $0.id == id || ($0.id == uuid && uuid?.isEmpty == false) }
            ?? overrides.first { $0.id == productID && productID?.isEmpty == false }
            ?? overrides.first { $0.id == "global" }
    }

    /// Debug logs for the HTTP API, as `debugLevel` asks.
    var debugAPI: Bool { debug && (debugLevel.isEmpty || debugLevel.contains("api")) }
    /// Debug logs for one device.
    func debugDevice(_ id: String) -> Bool { debug && (debugLevel.isEmpty || debugLevel.contains(id)) }
}

struct TuyaConfigurationError: Error, CustomStringConvertible {
    let problems: [String]
    init(_ problems: [String]) { self.problems = problems }
    var description: String { problems.joined(separator: "; ") }
}

/// What the vault keeps for the instance's account.
struct TuyaAccountCredentials: Codable, Sendable, Equatable {
    var accessKey: String?
    var password: String?

    var isEmpty: Bool { (accessKey ?? "").isEmpty && (password ?? "").isEmpty }
}

/// Tuya's data centres, and the one a Smart Home account's country uses.
enum TuyaRegion {
    static let america = "openapi.tuyaus.com"
    static let americaEast = "openapi-ueaz.tuyaus.com"
    static let china = "openapi.tuyacn.com"
    static let europe = "openapi.tuyaeu.com"
    static let europeWest = "openapi-weaz.tuyaeu.com"
    static let india = "openapi.tuyain.com"

    /// The data centres, for Setup's menu.
    static let all: [(host: String, label: String)] = [
        (america, "America"), (americaEast, "America East"), (china, "China"), (europe, "Europe"), (europeWest, "Europe West"), (india, "India"),
    ]

    static func host(countryCode: Int) -> String {
        if countryCode == 86 { return china }
        if countryCode == 91 { return india }
        if europeCodes.contains(countryCode) { return europe }
        return america
    }

    /// The calling codes whose accounts live in Europe; every code not here, China's or India's is America's.
    static let europeCodes: Set<Int> = {
        var codes: Set<Int> = [
            7, 20, 27, 30, 31, 32, 33, 34, 36, 39, 40, 41, 43, 44, 45, 46, 47, 48, 49, 61, 65, 90, 92, 93, 94, 212, 213, 216, 218, 248, 291, 297,
            298, 299, 385, 386, 387, 389, 420, 421, 423, 501, 590, 592, 596, 673, 676, 679, 680, 681, 685, 687, 688, 689, 691, 692, 855, 856, 880,
            960, 961, 962, 964, 965, 966, 967, 968, 992, 993, 994, 995, 996, 998, 1242, 1246, 1264, 1268, 1284, 1340, 1345, 1441, 1473, 1649,
            1664, 1670, 1671, 1684, 1758, 1767, 1784, 1868, 1869, 1876,
        ]
        for range in [220...238, 240...244, 250...258, 260...269, 350...359, 370...382, 503...509, 971...977] { codes.formUnion(range) }
        return codes
    }()
}
