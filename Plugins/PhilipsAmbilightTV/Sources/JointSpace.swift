import Foundation
import HomeswiftNetwork
import Logging

// The JointSpace API, version 6, of Philips Android TVs: JSON over HTTPS on port 1926 (a self-signed
// certificate, pinned once known) with HTTP Digest authentication, or plain HTTP on port 1925 on sets that
// never answer on 1926. docs/philips-tv-api.md of the Homebridge plugin lists the endpoints.

enum JointSpace {
    static let securePort = 1926
    static let plainPort = 1925
    static let version = 6
    static let getTimeout: Duration = .seconds(2)
    static let postTimeout: Duration = .seconds(3)
    /// The TV copes badly with requests on top of each other.
    static let gapBetweenRequests: Duration = .milliseconds(100)

    static let watchTVURI = "content://android.media.tv/channel"
    static let homeURI = "virtual:home"
    static let hdmiPassthroughPrefix = "content://android.media.tv/passthrough/com.mediatek.tvinput%2F.hdmi.HDMIInputService%2F"
    /// HDMI 1 to 4, in order.
    static let hdmiSources: [(id: String, name: String)] = (1...4).map { ("\(hdmiPassthroughPrefix)HW\($0 + 4)", "HDMI \($0)") }
    static let sourceSelectAction = "org.droidtv.playtv.SELECTURI"
    static let playTVComponent = Intent.Component(packageName: "org.droidtv.playtv", className: "org.droidtv.playtv.PlayTvActivity")
    static let mainAction = "android.intent.action.MAIN"
    static let defaultChannelList = "allcab"
    static let ambilightBrightnessNode = 2131230769
    static let ambilightBrightnessRange = 0...10

    struct Intent: Codable, Sendable, Equatable {
        struct Component: Codable, Sendable, Equatable {
            var packageName: String
            var className: String
        }

        var component: Component
        var action: String
        var extras: [String: String]?
    }

    struct Volume: Codable, Sendable, Equatable {
        var current: Int?
        var min: Int?
        var max: Int?
        var muted: Bool?
    }

    struct Application: Codable, Sendable, Equatable {
        var id: String?
        var label: String?
        var intent: Intent?
        var order: Int?
        var type: String?

        var packageName: String? { intent?.component.packageName }
    }

    /// `ambilight/currentconfiguration`, read and written.
    struct AmbilightConfiguration: Codable, Sendable, Equatable {
        struct Color: Codable, Sendable, Equatable {
            /// 0 to 255 each.
            var hue: Int
            var saturation: Int
            var brightness: Int
        }

        struct ColorSettings: Codable, Sendable, Equatable {
            var color: Color
            var colorDelta: Color
            var speed: Int
        }

        var styleName: String
        var isExpert: Bool?
        var menuSetting: String?
        var algorithm: String?
        var speed: Int?
        var colorSettings: ColorSettings?

        /// The style in upper case, as the plugin compares it.
        var style: String { styleName.uppercased() }
    }

    struct SystemInformation: Codable, Sendable, Equatable {
        var name: String?
        var model_encrypted: String?
        var serialnumber_encrypted: String?
        var softwareversion: String?
        var os_type: String?
        var api_version: APIVersion?

        struct APIVersion: Codable, Sendable, Equatable {
            var Major: Int?
            var Minor: Int?
            var Patch: Int?
        }
    }

    /// `network/devices`: the TV's own interfaces, with their MAC addresses.
    struct NetworkDevice: Codable, Sendable, Equatable {
        var id: String?
        var mac: String?
        var ip: String?
        var type: String?
        var wake_on_lan: String?

        enum CodingKeys: String, CodingKey { case id, mac, ip, type, wake_on_lan = "wake-on-lan" }
    }
}

extension JointSpace.NetworkDevice {
    /// Field by field: a set that sends one of them as a number or a boolean still gives its MAC address.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        mac = try? container.decodeIfPresent(String.self, forKey: .mac)
        ip = try? container.decodeIfPresent(String.self, forKey: .ip)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        wake_on_lan = try? container.decodeIfPresent(String.self, forKey: .wake_on_lan)
    }
}

enum JointSpaceError: Error, CustomStringConvertible, Equatable {
    case unreachable(String)
    /// Nothing listens on the port: a set without HTTPS, on 1926.
    case connectionRefused(port: Int)
    case httpStatus(Int)
    case unauthorized
    case invalidResponse(String)
    case certificateMismatch(expected: String, observed: String)

    var description: String {
        switch self {
        case .unreachable(let detail): "the TV did not answer: \(detail)"
        case .connectionRefused(let port): "the TV refuses connections on port \(port)"
        case .httpStatus(let status): "the TV answered HTTP \(status)"
        case .unauthorized: "the TV refused the credentials: pair it again"
        case .invalidResponse(let detail): "unexpected answer from the TV: \(detail)"
        case .certificateMismatch(let expected, let observed): "the TV's certificate (\(observed)) is not the pinned one (\(expected))"
        }
    }
}

/// Reaches a TV: the real client over the network, or a fake TV in tests. A fresh transport per TLS mode,
/// because the pin can change (recorded at pairing, confirmed on first use).
protocol JointSpaceTransportFactory: Sendable {
    func makeTransport(tls: HTTPClient.TLS) -> any HTTPSending
}

struct NetworkTransportFactory: JointSpaceTransportFactory {
    func makeTransport(tls: HTTPClient.TLS) -> any HTTPSending { HTTPClient(tls: tls) }
}

/// One TV's API: requests one at a time, a small gap between them, the Digest challenge remembered, the
/// scheme that works remembered. Every failure is a `JointSpaceError`.
///
/// Transport policy: HTTPS, with the configured certificate pinned; without one, the certificate of the
/// first answer is pinned for the rest of the run (and the log says to configure it). Plain HTTP is tried
/// only when nothing listens on the HTTPS port (sets from before HTTPS), and never once HTTPS has answered.
actor JointSpaceClient {
    let ip: String
    let username: String
    private let password: String
    /// SHA-256 of the TV's certificate from the configuration; nil pins the first certificate seen.
    let certificateFingerprint: String?
    private let transports: any JointSpaceTransportFactory
    private var transport: any HTTPSending
    /// The certificate every connection must present: the configured one, or the first one seen.
    private(set) var pinnedFingerprint: String?
    private var digest: DigestAuthentication
    /// `https` or `http`, once one answered.
    private var scheme: String?
    /// True once HTTPS has answered: plain HTTP is never tried after that.
    private var secureAnswered = false
    private var lastRequestEnded: ContinuousClock.Instant?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Launch intents the TV reported for its apps, so launches use the right activity.
    private var intents: [String: JointSpace.Intent] = [:]
    let logger: Logger

    init(ip: String, username: String, password: String, certificateFingerprint: String?, transports: any JointSpaceTransportFactory, logger: Logger) {
        self.ip = ip
        self.username = username
        self.password = password
        self.certificateFingerprint = certificateFingerprint
        self.transports = transports
        pinnedFingerprint = certificateFingerprint
        transport = transports.makeTransport(tls: certificateFingerprint.map { .pinned($0) } ?? .any)
        digest = DigestAuthentication(username: username, password: password)
        self.logger = logger
    }

    // MARK: Power

    func powerState() async throws -> Bool {
        struct Power: Decodable { var powerstate: String? }
        let power: Power = try await get("powerstate")
        guard let state = power.powerstate else { throw JointSpaceError.invalidResponse("powerstate without a state") }
        return state == "On"
    }

    func setPower(on: Bool) async throws {
        try await post("powerstate", ["powerstate": on ? "On" : "Standby"])
    }

    // MARK: Volume and keys

    func volume() async throws -> JointSpace.Volume {
        try await get("audio/volume")
    }

    func setMuted(_ muted: Bool) async throws {
        try await post("audio/volume", ["muted": muted])
    }

    func sendKey(_ key: String) async throws {
        try await post("input/key", ["key": key])
    }

    // MARK: Activities

    /// The package in the foreground, or nil when the TV names none.
    func currentActivity() async throws -> String? {
        struct Activity: Decodable {
            struct Component: Decodable { var packageName: String? }
            var component: Component?
        }
        let activity: Activity = try await get("activities/current")
        return activity.component?.packageName
    }

    func applications() async throws -> [JointSpace.Application] {
        struct List: Decodable { var applications: [JointSpace.Application]? }
        let list: List = try await get("applications", timeout: .seconds(5))
        let applications = list.applications ?? []
        for application in applications {
            if let intent = application.intent, !intent.component.className.isEmpty, !intent.action.isEmpty {
                intents[intent.component.packageName] = JointSpace.Intent(component: intent.component, action: intent.action)
            }
        }
        return applications
    }

    /// Launches an app. The activity comes from the configuration, else from what the TV reported for the
    /// package, else the usual `<package>.MainActivity`, refreshed from the TV once when that is rejected.
    /// Returns the activity the TV accepted, so a failure can name the one it rejected.
    @discardableResult
    func launchApplication(_ packageName: String, className: String? = nil, action: String? = nil) async throws -> String {
        if let className {
            let intent = JointSpace.Intent(component: .init(packageName: packageName, className: className), action: action ?? JointSpace.mainAction)
            try await launch(intent)
            return className
        }
        if let known = intents[packageName] {
            try await launch(known)
            return known.component.className
        }
        let guessed = JointSpace.Intent(component: .init(packageName: packageName, className: "\(packageName).MainActivity"), action: JointSpace.mainAction)
        do {
            try await launch(guessed)
            return guessed.component.className
        } catch {
            _ = try? await applications()
            guard let learned = intents[packageName] else { throw error }
            try await launch(learned)
            return learned.component.className
        }
    }

    func launch(_ intent: JointSpace.Intent) async throws {
        try await post("activities/launch", ["intent": intent])
    }

    /// Selects a source by URI (the tuner, an HDMI input).
    func setSource(_ uri: String) async throws {
        try await launch(JointSpace.Intent(component: JointSpace.playTVComponent, action: JointSpace.sourceSelectAction, extras: ["uri": uri]))
    }

    /// The tuner: the source URI first, the WatchTV key when the TV rejects it (a key reaches whatever
    /// app is in front, which may swallow it).
    func launchWatchTV() async throws {
        do {
            try await setSource(JointSpace.watchTVURI)
        } catch {
            try await sendKey("WatchTV")
        }
    }

    func launchHome() async throws {
        try await sendKey("Home")
    }

    func setChannel(_ ccid: Int, list: String = JointSpace.defaultChannelList) async throws {
        struct Body: Encodable {
            struct Channel: Encodable { var ccid: Int }
            struct List: Encodable { var id: String }
            var channel: Channel
            var channelList: List
        }
        try await post("activities/tv", Body(channel: .init(ccid: ccid), channelList: .init(id: list)))
    }

    // MARK: Ambilight

    func ambilightPower() async throws -> Bool {
        struct Power: Decodable { var power: String? }
        let power: Power = try await get("ambilight/power")
        return power.power == "On"
    }

    func setAmbilightPower(_ on: Bool) async throws {
        try await post("ambilight/power", ["power": on ? "On" : "Off"])
    }

    func ambilightConfiguration() async throws -> JointSpace.AmbilightConfiguration {
        try await get("ambilight/currentconfiguration")
    }

    func setAmbilightStyle(_ style: String, algorithm: String? = nil) async throws {
        try await post("ambilight/currentconfiguration", JointSpace.AmbilightConfiguration(styleName: style, isExpert: false, menuSetting: algorithm))
    }

    /// A fixed colour (`FOLLOW_COLOR`), each component 0 to 255.
    func setAmbilightColor(_ color: JointSpace.AmbilightConfiguration.Color) async throws {
        try await post("ambilight/currentconfiguration", JointSpace.AmbilightConfiguration(
            styleName: "FOLLOW_COLOR", isExpert: true, algorithm: "MANUAL_HUE", speed: 0,
            colorSettings: .init(color: color, colorDelta: .init(hue: 0, saturation: 0, brightness: 0), speed: 0)))
    }

    /// Off through the style, then through the power switch for sets that reject the style.
    func setAmbilightOff() async throws {
        do {
            try await setAmbilightStyle("OFF")
        } catch {
            try await setAmbilightPower(false)
        }
    }

    /// The menu's brightness, 0 to 10.
    func setAmbilightBrightness(_ level: Int) async throws {
        struct Body: Encodable {
            struct Entry: Encodable {
                struct Value: Encodable {
                    struct DataValue: Encodable { var value: Int }
                    var Nodeid: Int
                    var data: DataValue
                }
                var value: Value
            }
            var values: [Entry]
        }
        let clamped = min(max(level, JointSpace.ambilightBrightnessRange.lowerBound), JointSpace.ambilightBrightnessRange.upperBound)
        try await post("menuitems/settings/update", Body(values: [.init(value: .init(Nodeid: JointSpace.ambilightBrightnessNode, data: .init(value: clamped)))]))
    }

    func hueLampPower() async throws -> Bool {
        struct Power: Decodable { var power: String? }
        let power: Power = try await get("HueLamp/power")
        return power.power == "On"
    }

    func setHueLampPower(_ on: Bool) async throws {
        try await post("HueLamp/power", ["power": on ? "On" : "Off"])
    }

    // MARK: System

    func system() async throws -> JointSpace.SystemInformation {
        try await get("system")
    }

    func networkDevices() async throws -> [JointSpace.NetworkDevice] {
        try await get("network/devices")
    }

    // MARK: Requests

    func get<T: Decodable>(_ path: String, timeout: Duration = JointSpace.getTimeout) async throws -> T {
        let response = try await send(method: "GET", path: path, body: nil, timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw JointSpaceError.invalidResponse("\(path): \(error)")
        }
    }

    func post(_ path: String, _ body: some Encodable, timeout: Duration = JointSpace.postTimeout) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        _ = try await send(method: "POST", path: path, body: try encoder.encode(body), timeout: timeout)
    }

    /// A long request outside the gap and queue of the others: the long-poll client's `notifychange`.
    func longPost(_ path: String, _ body: some Encodable, timeout: Duration) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try await request(method: "POST", path: path, body: try encoder.encode(body), timeout: timeout).body
    }

    /// One request at a time, `gapBetweenRequests` after the previous one.
    private func send(method: String, path: String, body: Data?, timeout: Duration) async throws -> HTTPResponse {
        await acquire()
        defer { release() }
        if let ended = lastRequestEnded {
            let wait = ended + JointSpace.gapBetweenRequests - ContinuousClock.now
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        defer { lastRequestEnded = .now }
        return try await request(method: method, path: path, body: body, timeout: timeout)
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// The request over the scheme that works, answering one Digest challenge. HTTPS first; plain HTTP only
    /// when the TV refuses connections on the HTTPS port, nothing is pinned and HTTPS never answered. The
    /// password never reaches the log.
    private func request(method: String, path: String, body: Data?, timeout: Duration) async throws -> HTTPResponse {
        let schemes: [String]
        if let scheme {
            schemes = [scheme]
        } else if pinnedFingerprint != nil || secureAnswered {
            schemes = ["https"]
        } else {
            schemes = ["https", "http"]
        }
        var lastError: any Error = JointSpaceError.unreachable("no scheme to try")
        for candidate in schemes {
            do {
                let response = try await request(scheme: candidate, method: method, path: path, body: body, timeout: timeout)
                if candidate == "https" {
                    secureAnswered = true
                    pinOnFirstUse(response)
                }
                if scheme == nil {
                    scheme = candidate
                    logger.debug("The TV answers over \(candidate)")
                }
                return response
            } catch let error as JointSpaceError {
                lastError = error
                // Only a refused HTTPS port means a set without HTTPS; a TV that is asleep or away stays
                // out of reach over plain HTTP too, and an answer of any kind ends the probing.
                if case .connectionRefused = error, candidate == "https" { continue }
                break
            }
        }
        if scheme != nil {
            // The known scheme stopped answering: probe again next time, with a fresh challenge.
            scheme = nil
            digest.clear()
        }
        throw lastError
    }

    /// Without a configured fingerprint, the first certificate seen is the one every later connection
    /// must present, and the log says which value to configure.
    private func pinOnFirstUse(_ response: HTTPResponse) {
        guard pinnedFingerprint == nil, let fingerprint = response.certificateFingerprint else { return }
        pinnedFingerprint = fingerprint
        transport = transports.makeTransport(tls: .pinned(fingerprint))
        logger.warning("The TV's certificate is not in the configuration; pinned for this run. Add \"certFingerprint\": \"\(fingerprint)\" to the TV's entry.")
    }

    private func request(scheme: String, method: String, path: String, body: Data?, timeout: Duration) async throws -> HTTPResponse {
        let port = scheme == "https" ? JointSpace.securePort : JointSpace.plainPort
        let uri = "/\(JointSpace.version)/\(path)"
        guard let url = URL(string: "\(scheme)://\(ip):\(port)\(uri)") else { throw JointSpaceError.unreachable("bad URL for \(ip)") }
        var request = HTTPRequest(method: method, url: url, body: body, timeout: timeout)
        if body != nil { request.setHeader("Content-Type", "application/json") }
        if let authorization = digest.authorization(method: method, uri: uri) {
            request.setHeader("Authorization", authorization)
        }
        var response = try await perform(request)
        if response.status == 401 {
            guard let challenge = response.header("WWW-Authenticate"), digest.accept(challenge: challenge),
                  let authorization = digest.authorization(method: method, uri: uri) else {
                digest.clear()
                throw JointSpaceError.unauthorized
            }
            request.setHeader("Authorization", authorization)
            response = try await perform(request)
            if response.status == 401 {
                digest.clear()
                throw JointSpaceError.unauthorized
            }
        }
        guard response.isSuccess else { throw JointSpaceError.httpStatus(response.status) }
        return response
    }

    private func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as HTTPClientError {
            switch error {
            case .certificateMismatch(let expected, let observed):
                throw JointSpaceError.certificateMismatch(expected: expected, observed: observed)
            case .cannotConnect(_, let port, let code, _) where code == ECONNREFUSED:
                throw JointSpaceError.connectionRefused(port: port)
            default:
                throw JointSpaceError.unreachable(error.description)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JointSpaceError.unreachable("\(error)")
        }
    }
}
