import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging

/// A failed Gen 1 HTTP request, worded as the Homebridge plugin logs it.
enum Gen1Error: Error, CustomStringConvertible {
    case wrongCredentials
    case status(Int, String)
    case timeout
    case transport(String)

    var description: String {
        switch self {
        case .wrongCredentials: "Wrong username or password"
        case .status(let code, let body): "Error: \(code)\(body.isEmpty ? "" : " \(body)")"
        case .timeout: "Request timeout"
        case .transport(let message): "Error: \(message)"
        }
    }
}

/// One Gen 1 device: its CoIoT properties, mode, address, settings and the HTTP API that changes it.
actor Gen1Device {
    let model: Gen1Model
    let deviceID: String
    private(set) var host: String
    private(set) var mode: String?
    private(set) var values: [String: JSONValue]
    private(set) var isOnline = false
    /// From `GET /settings`, once loaded.
    private(set) var firmware: String?
    private(set) var hardwareRevision: String?
    private(set) var settingsName: String?
    private(set) var swapped = false
    private var settingsLoaded = false
    /// The address that last answered 401: Basic credentials go there from then on.
    private var challengedHost: String?
    /// Whether a status was heard since the device object was made.
    private(set) var heard = false

    private let http: any HTTPSending
    private let credentials: (username: String, password: String)?
    private let timeout: Duration
    let logger: Logger
    private var observers: [(names: Set<String>, handler: @Sendable ([String: JSONValue]) -> Void)] = []

    nonisolated var key: String { "\(model.id)#\(deviceID)" }
    nonisolated var label: String { "\(model.id) \(deviceID)" }

    init(model: Gen1Model, deviceID: String, host: String, mode: String?, http: any HTTPSending, credentials: (username: String, password: String)?,
         timeout: Duration, logger: Logger, settingsName: String? = nil) {
        self.model = model
        self.deviceID = deviceID
        self.host = host
        self.mode = model.hasModes ? (mode ?? model.defaultMode) : nil
        values = model.initialValues(mode: self.mode)
        self.http = http
        self.credentials = credentials
        self.timeout = timeout
        self.logger = logger
        self.settingsName = settingsName
    }

    /// Calls `handler` with every value whenever one of `names` changed in an update, and once now.
    func observe(_ names: Set<String>, _ handler: @escaping @Sendable ([String: JSONValue]) -> Void) {
        observers.append((names, handler))
        handler(values)
    }

    func removeObservers() { observers.removeAll() }

    func value(_ name: String) -> JSONValue { values[name] ?? .null }

    /// A status from CoIoT: the mode it shows, each mapped property coerced, then the observers of what changed. Answers
    /// whether the mode changed (the accessories are made again then).
    @discardableResult
    func apply(_ status: CoIoTStatus, from address: String) -> (modeChanged: Bool, hostChanged: Bool) {
        let hostChanged = address != host
        if hostChanged {
            logger.debug("Device \(label) changed host to \(address)")
            host = address
        }
        heard = true
        var newMode = mode
        if model.hasModes, status.revision == "1" {
            switch model.family {
            case .relaysOrRoller: newMode = status.ids.contains(113) ? "roller" : "relay"
            case .colorOrWhiteLights: newMode = status.values.filter { $0.id == 171 || $0.id == 181 }.count >= 2 ? "white" : "color"
            default: break
            }
        } else if model.hasModes, let reported = status.values.first(where: { $0.id == 9101 })?.value.stringValue, !reported.isEmpty {
            newMode = reported
        }
        let modeChanged = newMode != mode
        if modeChanged {
            logger.debug("Device \(label) changed mode to \(newMode ?? "none")")
            mode = newMode
            values.merge(model.initialValues(mode: newMode)) { old, _ in old }
        }
        let properties = model.properties(mode: mode)
        var changed: Set<String> = []
        for tuple in status.values {
            guard let property = properties[tuple.id] else { continue }
            let value = property.coerce(tuple.value)
            if values[property.name] != value {
                values[property.name] = value
                changed.insert(property.name)
                logger.trace("\(property.name) of device \(label) changed to \(value)")
            }
        }
        if mode == "roller", status.revision == "1", case .relaysOrRoller = model.family {
            let state = values["relay0"]?.isTruthy == true ? (swapped ? "close" : "open") : values["relay1"]?.isTruthy == true ? (swapped ? "open" : "close") : "stop"
            if values["rollerState"] != .string(state) {
                values["rollerState"] = .string(state)
                changed.insert("rollerState")
            }
        }
        if modeChanged { changed.insert("mode") }
        if !changed.isEmpty {
            for observer in observers where !observer.names.isDisjoint(with: changed) { observer.handler(values) }
        }
        return (modeChanged, hostChanged)
    }

    /// Online or offline (the CoIoT validity ran out). Answers whether it changed.
    func setOnline(_ online: Bool) -> Bool {
        guard online != isOnline else { return false }
        isOnline = online
        logger.debug("Device \(label) \(online ? "came online" : "went offline")")
        return true
    }

    // MARK: HTTP

    /// `GET /settings` once: the firmware's version, the hardware revision, the device's name, a roller's swap.
    func loadSettings() async throws -> Bool {
        guard !settingsLoaded else { return false }
        logger.debug("Loading settings of device \(label)")
        let settings = try await request("settings")
        settingsLoaded = true
        if let fw = settings["fw"]?.stringValue { firmware = Self.version(fw) }
        hardwareRevision = settings["hwinfo"]?["hw_revision"]?.stringValue
        settingsName = settings["name"]?.stringValue?.nonEmpty
        swapped = settings["rollers"]?[0]?["swap"]?.boolValue ?? false
        return true
    }

    /// The first `v` followed by dot-separated digits, without the `v`; else the whole string.
    static func version(_ firmware: String) -> String {
        guard let range = firmware.range(of: #"v\d+(\.\d+)*"#, options: .regularExpression) else { return firmware }
        return String(firmware[range].dropFirst())
    }

    /// `GET http://<host>/<path>?<query>` with the device's credentials; the reply as JSON.
    @discardableResult
    func request(_ path: String, _ query: [(String, String)] = []) async throws -> JSONValue {
        do {
            return try await send(path, query, authenticated: credentials != nil && challengedHost == host)
        } catch Gen1Error.wrongCredentials where credentials != nil && challengedHost != host {
            // Credentials go only to an address that asked for them: one a spoofed CoIoT status pointed at gets none
            // unless it challenges, and none of them before.
            challengedHost = host
            return try await send(path, query, authenticated: true)
        }
    }

    private func send(_ path: String, _ query: [(String, String)], authenticated: Bool) async throws -> JSONValue {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = "/\(path)"
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = components.url else { throw Gen1Error.transport("invalid address \(host)") }
        var request = HTTPRequest(url: url, timeout: timeout)
        request.setHeader("User-Agent", "homeswift")
        if authenticated, let credentials {
            request.setHeader("Authorization", "Basic \(Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString())")
        }
        let response: HomeswiftNetwork.HTTPResponse
        do {
            response = try await http.send(request)
        } catch HTTPClientError.timeout {
            throw Gen1Error.timeout
        } catch {
            throw Gen1Error.transport("\(error)")
        }
        guard response.status != 401 else { throw Gen1Error.wrongCredentials }
        guard response.isSuccess else { throw Gen1Error.status(response.status, logExcerpt(String(decoding: response.body, as: UTF8.self)) ?? "") }
        return (try? JSONValue(data: response.body)) ?? .null
    }

    /// A request for a write, logged as the Homebridge plugin does.
    func set(_ what: String, _ path: String, _ query: [(String, String)]) async throws {
        logger.debug("Setting \(what) of device \(label) to \(query.map { "\($0.0)=\($0.1)" }.joined(separator: "&"))")
        try await request(path, query)
    }

    /// What a failed request logs.
    func describe(_ error: any Error) -> String { "\(error) (device \(label), at \(host))" }

    /// Logs a failed operation: `Failed to set relay0: Request timeout (device SHSW-1 A4CF12, at 10.0.0.5)`.
    func logFailure(_ operation: String, _ error: any Error) { logger.error("\(operation): \(describe(error))") }
}
