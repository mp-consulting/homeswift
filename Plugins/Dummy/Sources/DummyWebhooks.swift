import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

/// A webhook's answer: JSON, or the HTML page that lists the webhooks.
struct WebhookReply: Sendable, Equatable {
    var status: Int
    var contentType: String
    var body: String

    static func json(_ status: Int, _ value: JSONValue) -> WebhookReply {
        WebhookReply(status: status, contentType: "application/json; charset=utf-8", body: value.text())
    }

    static func error(_ message: String) -> WebhookReply { .json(400, ["error": .string(message)]) }
}

/// What a webhook characteristic takes: a number in a range, or one of a list of values.
enum WebhookValues: Sendable, Equatable {
    case range(Double, Double)
    case list([JSONValue], labels: [String]?)

    var example: String {
        switch self {
        case .range(let low, _): javaScriptNumber(low)
        case .list(let values, _): values.first.map(Self.text) ?? ""
        }
    }

    var summary: String {
        switch self {
        case .range(let low, let high): "\(javaScriptNumber(low)) - \(javaScriptNumber(high))"
        case .list(let values, let labels): labels?.joined(separator: ", ") ?? values.map(Self.text).joined(separator: ", ")
        }
    }

    static func text(_ value: JSONValue) -> String {
        if let bool = value.boolValue { return bool ? "true" : "false" }
        if let number = value.doubleValue { return javaScriptNumber(number) }
        return value.stringValue ?? value.text()
    }
}

/// The webhooks (spec 9): `?id=…&get=…`, `set=…&value=…`, `sync=…&value=…` (no commands run), `command=…` (an older name of
/// `set`) and, with no parameters at all, a page listing them.
extension DummyEngine {
    static let binaryValues = WebhookValues.list([.bool(true), .bool(false)], labels: nil)

    /// The characteristics a webhook can read and write on an accessory, in the order the page lists them.
    func webhookCharacteristics(_ device: DummyDevice) -> [(String, WebhookValues)] {
        let config = device.config
        func temperatures(_ low: Double, _ high: Double) -> WebhookValues {
            .range(device.shownTemperature(low), device.shownTemperature(high))
        }
        switch config.type {
        case .switch, .outlet, .valve: return [("On", Self.binaryValues)]
        case .lightbulb: return [("On", Self.binaryValues), ("Brightness", .range(0, 100))]
        case .lock: return [("LockTargetState", .list([0, 1], labels: nil))]
        case .door, .window, .windowCovering: return [("TargetPosition", .range(0, 100))]
        case .garageDoor: return [("TargetDoorState", .list([0, 1], labels: nil))]
        case .humidifier: return [("On", Self.binaryValues), ("CurrentRelativeHumidity", .range(0, 100)), ("TargetRelativeHumidity", .range(0, 100))]
        case .humiditySensor: return [("CurrentRelativeHumidity", .range(0, 100))]
        case .temperatureSensor: return [("CurrentTemperature", config.fahrenheit ? .range(-454, 212) : .range(-270, 100))]
        case .thermostat:
            let current = config.validStates.filter { $0 != 3 }
            return [
                ("CurrentHeatingCoolingState", .list(current.map { .number(Double($0)) }, labels: current.map { "\($0) (\(DummyDevice.modeNames[$0]))" })),
                ("TargetHeatingCoolingState", .list(config.validStates.map { .number(Double($0)) }, labels: config.validStates.map { "\($0) (\(DummyDevice.modeNames[$0]))" })),
                ("CurrentTemperature", temperatures(config.minimumTemperature, config.maximumTemperature)),
                ("TargetTemperature", temperatures(config.minimumTemperature, config.maximumTemperature)),
            ]
        case .motionSensor: return [("MotionDetected", Self.binaryValues)]
        case .button: return [("ProgrammableSwitchEvent", .list([0, 1, 2], labels: ["0 (single)", "1 (double)", "2 (long)"]))]
        default: return [(config.type.sensorKey, .list([1, 0], labels: nil))]
        }
    }

    /// The accessories that answer webhooks, for the log at launch.
    func registerWebhooks() -> Bool {
        var any = false
        for identifier in order {
            guard let device = devices[identifier], device.config.enableWebhook else { continue }
            any = true
            for (characteristic, _) in webhookCharacteristics(device) {
                info(device, "\(device.name) adding webhook with id `\(identifier)` and command `\(characteristic)`")
            }
        }
        return any
    }

    /// `"true"`, `"false"` and numbers in text become JSON values; other text stays text.
    static func parse(_ value: JSONValue) -> JSONValue {
        guard let text = value.stringValue else { return value }
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let number = Double(trimmed), number.isFinite { return .number(number) }
        return value
    }

    func webhook(_ parameters: [String: JSONValue]) -> WebhookReply {
        if parameters.isEmpty { return WebhookReply(status: 200, contentType: "text/html; charset=utf-8", body: webhookPage()) }
        if verbose { debug("Webhook request: \(JSONValue.object(parameters).text())") }
        guard let id = parameters["id"]?.stringValue ?? parameters["id"].map(WebhookValues.text) else {
            return .error("Request is missing id")
        }
        func failure(_ message: String) -> WebhookReply {
            logger.error("\(message)")
            return .error(message)
        }
        if let get = parameters["get"].map(WebhookValues.text) {
            guard let device = devices[id], device.config.enableWebhook else { return failure("No accessory has a webhook with id `\(id)`") }
            guard webhookCharacteristics(device).contains(where: { $0.0 == get }) else {
                return failure("\(device.name) has no webhook for the `\(get)` characteristic")
            }
            return .json(200, webhookValue(device, get).map { ["value": $0] } ?? [:])
        }
        let chosen = (parameters["set"] ?? parameters["sync"] ?? parameters["command"]).map(WebhookValues.text)
        guard let characteristic = chosen else { return failure("Request with id `\(id)` is missing a get or set command") }
        guard let value = parameters["value"].map(Self.parse) else { return .error("`set` requests require a `value`") }
        guard let device = devices[id], device.config.enableWebhook else { return failure("No accessory has a webhook with id `\(id)`") }
        guard let values = webhookCharacteristics(device).first(where: { $0.0 == characteristic })?.1 else {
            return failure("\(device.name) has no webhook for the `\(characteristic)` characteristic")
        }
        switch values {
        case .range(let low, let high):
            guard let number = value.doubleValue, number >= low, number <= high else {
                return failure("The \(characteristic) characteristic expects a number value between \(javaScriptNumber(low)) and \(javaScriptNumber(high))")
            }
        case .list(let allowed, _):
            guard allowed.contains(value) else {
                return failure("Valid values for the \(characteristic) characteristic command are: \(values.summary)")
            }
        }
        let isSync = parameters["sync"].map(WebhookValues.text) == characteristic
        let message = applyWebhook(device, characteristic, value, source: isSync ? .sync : .webhook)
        return .json(200, ["success": .string(message)])
    }

    func webhookValue(_ device: DummyDevice, _ characteristic: String) -> JSONValue? {
        switch characteristic {
        case "On": return .bool(device.primary == 1)
        case "Brightness": return .number(Double(device.fadeValue ?? device.brightness))
        case "LockTargetState", "TargetPosition", "TargetDoorState": return .number(Double(device.primary))
        case "CurrentRelativeHumidity":
            if device.config.family == .humidifier { return .number(device.currentHumidityExplicit ? device.currentHumidity : device.targetHumidity) }
            return .number(device.value)
        case "TargetRelativeHumidity": return .number(device.targetHumidity)
        case "CurrentTemperature":
            return .number(device.shownTemperature(device.config.family == .thermostat ? device.currentTemperature : device.value))
        case "TargetTemperature": return .number(device.shownTemperature(device.targetTemperature))
        case "CurrentHeatingCoolingState": return .number(Double(device.currentMode))
        case "TargetHeatingCoolingState": return .number(Double(device.targetMode))
        case "MotionDetected": return .bool(device.primary == 1)
        case "ProgrammableSwitchEvent": return nil
        default: return .number(Double(device.primary))
        }
    }

    /// Applies a checked webhook value and answers what the log says.
    func applyWebhook(_ device: DummyDevice, _ characteristic: String, _ value: JSONValue, source: ChangeSource) -> String {
        let number = value.doubleValue ?? (value.boolValue == true ? 1 : 0)
        func celsius(_ shown: Double) -> Double { device.config.fahrenheit ? Temperature.celsius(fahrenheit: shown) : shown }
        switch characteristic {
        case "On", "MotionDetected":
            setPrimary(device, value.boolValue == true ? 1 : 0, source: source)
            return device.stateMessage
        case "Brightness":
            setBrightness(device, Int(saturating: number.rounded(), in: 0...100) ?? 0, source: .webhook)
            return "\(device.name) brightness is \(device.brightness)%"
        case "TargetPosition":
            setPrimary(device, number == 0 ? 0 : 100, source: source)
            return device.stateMessage
        case "LockTargetState", "TargetDoorState":
            setPrimary(device, number == 0 ? 0 : 1, source: source)
            return device.stateMessage
        case "CurrentRelativeHumidity":
            if device.config.family == .humidifier {
                setCurrentHumidity(device, number, source: source)
                return "\(device.name) humidity is \(javaScriptNumber(number))%"
            }
            setSensorValue(device, number, source: source)
            return device.stateMessage
        case "TargetRelativeHumidity":
            setTargetHumidity(device, number, source: source)
            return "\(device.name) humidity set to \(javaScriptNumber(number))%"
        case "CurrentTemperature":
            if device.config.family == .thermostat {
                setCurrentTemperature(device, celsius(number), explicit: true)
                return "\(device.name) is \(device.temperatureText(device.currentTemperature))"
            }
            setSensorValue(device, celsius(number), source: source)
            return device.stateMessage
        case "TargetTemperature":
            setTargetTemperature(device, celsius(number), source: source)
            return "\(device.name) set to \(javaScriptNumber(number))°\(device.config.fahrenheit ? "F" : "C")"
        case "CurrentHeatingCoolingState":
            let mode = Int(saturating: number) ?? 0
            setCurrentMode(device, mode, source: source)
            return "\(device.name) is \(DummyDevice.modeNames[min(max(mode, 0), 3)])"
        case "TargetHeatingCoolingState":
            let mode = Int(saturating: number) ?? 0
            setTargetMode(device, mode, source: source)
            return "\(device.name) set to \(DummyDevice.modeNames[min(max(mode, 0), 3)])"
        case "ProgrammableSwitchEvent":
            let press = Int(saturating: number) ?? 0
            self.press(device, press)
            return device.pressMessage(press)
        default:
            setPrimary(device, number == 0 ? 0 : 1, source: source)
            return device.stateMessage
        }
    }

    func webhookPage() -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        }
        var rows = ""
        for identifier in order {
            guard let device = devices[identifier], device.config.enableWebhook else { continue }
            for (characteristic, values) in webhookCharacteristics(device) {
                let link = "?id=\(URLEncoding.rfc3986(identifier))&command=\(URLEncoding.rfc3986(characteristic))&value=\(URLEncoding.rfc3986(values.example))"
                rows += "<tr><td>\(escape(device.name))</td><td>\(escape(identifier))</td><td>\(escape(characteristic))</td><td>\(escape(values.summary))</td>"
                rows += "<td><a href=\"\(escape(link))\">\(escape(link))</a></td></tr>\n"
            }
        }
        return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Available Webhooks</title>
            <style>body{font-family:-apple-system,system-ui,sans-serif;margin:16px}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:6px 8px;text-align:left;word-break:break-all}</style>
            </head><body><h1>Available Webhooks</h1>
            <table><thead><tr><th>Name</th><th>ID</th><th>Command</th><th>Values</th><th>Example</th></tr></thead><tbody>
            \(rows)</tbody></table></body></html>
            """
    }
}
