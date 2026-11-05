import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

/// One Kamereon account of the person (3.5).
struct KamereonAccount: Sendable, Equatable {
    var id: String
    var type: String?
}

/// A vehicle of an account, from its link and details (3.7). The VIN is personal data: logged masked only.
struct VehicleInfo: Codable, Sendable, Equatable {
    var vin: String
    var registrationNumber: String?
    var brand: String?
    var modelCode: String?
    var modelLabel: String?
    var energyCode: String?
    var engineEnergyType: String?

    /// `ELEC`, `ELECX` or `PHEV` (`engineEnergyType`, else `energy.code`) (1.4).
    var usesElectricity: Bool {
        guard let energy = (engineEnergyType ?? energyCode)?.uppercased() else { return false }
        return ["ELEC", "ELECX", "PHEV"].contains(energy)
    }

    /// The registration plate, else the model's label ("Renault 5"), else the brand.
    var displayName: String {
        if let plate = registrationNumber?.trimmingCharacters(in: .whitespaces), !plate.isEmpty { return String(plate.prefix(32)) }
        return modelName ?? manufacturer
    }

    var modelName: String? { modelLabel.map(Self.capitalised).flatMap { $0.isEmpty ? nil : $0 } }
    var manufacturer: String { brand.map(Self.capitalised).flatMap { $0.isEmpty ? nil : $0 } ?? "Renault" }

    /// `RENAULT 5` → `Renault 5`.
    static func capitalised(_ text: String) -> String {
        String(text.prefix(48)).lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// From a link's `vehicleDetails` (or the details' own answer); nil without a usable VIN.
    init?(details: JSONValue, vin fallback: String? = nil) {
        guard let vin = Self.cleanVIN(details["vin"]?.stringValue ?? fallback) else { return nil }
        self.vin = vin
        registrationNumber = details["registrationNumber"]?.stringValue
        brand = details["brand"]?["label"]?.stringValue
        modelCode = details["model"]?["code"]?.stringValue
        modelLabel = details["model"]?["label"]?.stringValue
        energyCode = details["energy"]?["code"]?.stringValue
        engineEnergyType = details["engineEnergyType"]?.stringValue
    }

    init(vin: String, registrationNumber: String? = nil, brand: String? = nil, modelCode: String? = nil, modelLabel: String? = nil, energyCode: String? = nil) {
        self.vin = vin
        self.registrationNumber = registrationNumber
        self.brand = brand
        self.modelCode = modelCode
        self.modelLabel = modelLabel
        self.energyCode = energyCode
    }

    /// A VIN as the cloud sent it, kept only when it is letters and digits (it goes in paths and accessory ids).
    static func cleanVIN(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).uppercased(), (5...32).contains(text.count),
            text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return text
    }
}

/// Renault's connected-car API (4): the request shape and the order its answers are read in. It knows nothing of the
/// quota or the session; `RenaultSession` sends through it.
enum Kamereon {
    /// The request for `path` under the root, with the country and the three headers every request carries.
    static func request(method: String, path: String, body: JSONValue? = nil, servers: RenaultServers, jwt: String, timeout: Duration) -> HTTPRequest {
        let address = "\(servers.kamereonRoot)\(path)?\(URLEncoding.query([("country", servers.country)]))"
        return HTTPRequest(
            method: method, url: URL(string: address) ?? URL(string: servers.kamereonRoot)!,
            headers: [("Content-type", "application/vnd.api+json"), ("apikey", servers.kamereonKey), ("x-gigya-id_token", jwt)],
            body: body?.encoded(), timeout: timeout)
    }

    /// 4.2: an array is wrapped under `data`; not an object is the HTTP error, else invalid JSON; an `errors` entry
    /// wins over the status; then the status.
    static func check(_ response: HTTPResponse) throws -> JSONValue {
        let trimmed = response.body.drop { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        let first = trimmed.first
        guard first == UInt8(ascii: "[") || first == UInt8(ascii: "{") else {
            guard response.isSuccess else { throw failure(response.status) }
            throw RenaultError.invalidJSON
        }
        guard let json = try? JSONValue(data: Data(trimmed)) else { throw RenaultError.invalidJSON }
        if first == UInt8(ascii: "{"), let error = json["errors"]?.arrayValue?.first {
            let code = error["errorCode"]?.stringValue ?? error["errorCode"]?.intValue.map(String.init) ?? ""
            throw RenaultError.kamereon(KamereonError(
                code: String(code.prefix(80)), detail: KamereonError.detail(of: error["errorMessage"]?.stringValue ?? ""), status: response.status))
        }
        guard response.isSuccess else { throw failure(response.status) }
        return first == UInt8(ascii: "[") ? ["data": json] : json
    }

    /// An HTTP error without a Kamereon entry; a 404 counts as one (4.7: the car does not have the endpoint).
    private static func failure(_ status: Int) -> RenaultError {
        status == 404 ? .kamereon(KamereonError(code: "", detail: "", status: 404)) : .http(status: status)
    }

    /// A kca answer's `data.attributes`, empty when missing (8.10); a kcm answer is the object itself.
    static func attributes(_ json: JSONValue, plain: Bool) -> JSONValue {
        if plain { return json }
        return json["data"]?["attributes"] ?? [:]
    }

    static func accountPath(_ accountID: String) -> String {
        "/commerce/v1/accounts/\(URLEncoding.rfc3986(accountID))"
    }

    static func vehiclePath(_ accountID: String, _ endpointPath: String) -> String {
        "\(accountPath(accountID))/kamereon\(endpointPath)"
    }

    static func accounts(_ json: JSONValue) -> [KamereonAccount] {
        (json["accounts"]?.arrayValue ?? []).prefix(50).compactMap { entry in
            guard let id = entry["accountId"]?.stringValue, !id.isEmpty else { return nil }
            return KamereonAccount(id: id, type: entry["accountType"]?.stringValue)
        }
    }
}

// MARK: Readings (4.3)

/// `chargingStatus`, compared by value with a tolerance (JSON gives `0`, `0.0` or `1`).
enum ChargingStatus {
    static func normalised(_ value: Double?) -> Double? {
        guard let value = value?.finite else { return nil }
        return (value * 10).rounded() / 10
    }

    static let names: [Double: String] = [
        0.0: "not in charge", 0.1: "waiting for a planned charge", 0.2: "charge ended", 0.3: "waiting for current charge",
        0.4: "energy flap opened", 1.0: "charge in progress", -1.0: "charge error", -1.1: "unavailable", -1.3: "V2G charging, waiting",
        -1.4: "V2L connected", -1.5: "V2G discharging", -1.6: "V2G charging, normal",
    ]

    /// The values that mean "plugged in" when `plugStatus` is absent (5.1).
    static let pluggedIn: Set<Double> = [1.0, 0.3, 0.2, -1.6, -1.3, -1.5, 0.1]
}

struct BatteryStatus: Sendable, Equatable {
    var level: Int?
    var autonomy: Int?
    var plugStatus: Int?
    var chargingStatus: Double?
    /// Kilowatts (watts on a ZOE phase 1, converted).
    var powerKW: Double?
    /// Minutes to a full charge, as the car estimates them.
    var remainingMinutes: Int?
    /// °C, older cars only.
    var temperature: Double?

    init(attributes json: JSONValue, reportsWatts: Bool = false) {
        level = json["batteryLevel"]?.doubleValue.flatMap { Int(saturating: $0, in: 0...100) }
        autonomy = json["batteryAutonomy"]?.doubleValue.flatMap { Int(saturating: $0, in: 0...2000) }
        remainingMinutes = json["chargingRemainingTime"]?.doubleValue.flatMap { Int(saturating: $0, in: 0...10_000) }
        temperature = json["batteryTemperature"]?.doubleValue?.finite.flatMap(HvacStatus.plausible)
        plugStatus = json["plugStatus"]?.saturatingIntValue
        chargingStatus = ChargingStatus.normalised(json["chargingStatus"]?.doubleValue)
        powerKW = json["chargingInstantaneousPower"]?.doubleValue?.finite.map { reportsWatts ? $0 / 1000 : $0 }
    }

    init(level: Int? = nil, plugStatus: Int? = nil, chargingStatus: Double? = nil) {
        self.level = level
        self.plugStatus = plugStatus
        self.chargingStatus = chargingStatus
    }

    /// HomeKit's Charging State: charging at 1.0 and -1.6 (5.2).
    var isCharging: Bool? {
        guard let chargingStatus else { return nil }
        return chargingStatus == 1.0 || chargingStatus == -1.6
    }

    /// Plugged in: `plugStatus` 1, unplugged at 0; an error or unknown plug is nil. Without `plugStatus`, the charging
    /// statuses of a plugged car (5.1).
    var isPluggedIn: Bool? {
        switch plugStatus {
        case 1: return true
        case 0: return false
        case .some: return nil
        case nil: return chargingStatus.map { ChargingStatus.pluggedIn.contains($0) }
        }
    }

    var isUnplugged: Bool { plugStatus == 0 }

    /// The charging power in whole watts.
    var watts: Int? { powerKW.flatMap { Int(saturating: $0 * 1000, in: 0...100_000) } }
}

struct HvacStatus: Sendable, Equatable {
    var isOn: Bool?
    var externalTemperature: Double?
    var internalTemperature: Double?

    init(attributes json: JSONValue) {
        isOn = json["hvacStatus"]?.stringValue.map { $0.lowercased() == "on" }
        externalTemperature = json["externalTemperature"]?.doubleValue?.finite.flatMap(Self.plausible)
        internalTemperature = json["internalTemperature"]?.doubleValue?.finite.flatMap(Self.plausible)
    }

    init(isOn: Bool?) { self.isOn = isOn }

    /// HomeKit's Current Temperature range.
    static func plausible(_ value: Double) -> Double? { (-60...100).contains(value) ? value : nil }
}

struct SocLevels: Sendable, Equatable {
    var minimum: Int?
    var target: Int?

    init(attributes json: JSONValue) {
        minimum = json["socMin"]?.doubleValue.flatMap { Int(saturating: $0, in: 0...100) }
        target = json["socTarget"]?.doubleValue.flatMap { Int(saturating: $0, in: 0...100) }
    }

    init(minimum: Int?, target: Int?) {
        self.minimum = minimum
        self.target = target
    }

    /// The limits the API takes (4.4): the minimum 15 to 45 and the target 55 to 100, in steps of 5.
    static let minimumRange = 15...45
    static let targetRange = 55...100

    static func isValid(minimum: Int) -> Bool { minimumRange.contains(minimum) && minimum % 5 == 0 }
    static func isValid(target: Int) -> Bool { targetRange.contains(target) && target % 5 == 0 }
}

struct LockStatus: Sendable, Equatable {
    var locked: Bool?
    /// Driver, passenger, rear left, rear right, hatch: true when open.
    var openings: [String: Bool]

    static let openingNames = ["Driver", "Passenger", "RearLeft", "RearRight", "Hatch"]

    init(attributes json: JSONValue) {
        locked = json["lockStatus"]?.stringValue.map { $0.lowercased() == "locked" }
        let keys: [(String, String, String)] = [
            ("Driver", "doorStatusDriver", "statusDoorDriver"), ("Passenger", "doorStatusPassenger", "statusDoorPassenger"),
            ("RearLeft", "doorStatusRearLeft", "statusDoorRearLeft"), ("RearRight", "doorStatusRearRight", "statusDoorRearRight"),
            ("Hatch", "hatchStatus", "statusDoorTailGate"),
        ]
        var openings: [String: Bool] = [:]
        for (name, first, alias) in keys {
            if let value = (json[first] ?? json[alias])?.stringValue { openings[name] = value.lowercased() == "open" }
        }
        self.openings = openings
    }
}
