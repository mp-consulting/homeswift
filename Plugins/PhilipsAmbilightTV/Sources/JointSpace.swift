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
    /// The menu's Ambilight brightness node on the models first tested: only a fallback, because node ids differ
    /// between models and firmware. The TV's own menu structure is read first (`AmbilightMenuNodes`).
    static let ambilightBrightnessNode = 2131230769
    static let ambilightBrightnessRange = 0...10
    /// The menu nodes' contexts: the same on every model, unlike the node ids they map to.
    static let ambilightStyleContext = "ambilight_style"
    static let ambilightOffContext = "ambilight_off"
    static let ambilightBrightnessContext = "ambilight_brightness"
    /// The menu structure is a large document: more time than a plain read.
    static let menuStructureTimeout: Duration = .seconds(5)
    /// After a failed structure read, the next one waits this long rather than slowing every poll.
    static let menuStructureRetry: Duration = .seconds(300)
    /// Missed menu reads in a row after which the menu stops deciding Ambilight's on/off.
    static let menuStateMaxMisses = 3

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

    /// This TV's node ids for the Ambilight entries of its settings menu, found by their contexts; nil for an
    /// entry the TV does not have.
    struct AmbilightMenuNodes: Sendable, Equatable {
        /// The style list, whose active entry tells on from off.
        var style: Int?
        /// The style list's Off entry.
        var off: Int?
        var brightness: Int?
    }

    /// Ambilight as a poll reads it: on or off, and the configuration when it adds detail (the mode, a colour).
    struct AmbilightReading: Sendable, Equatable {
        var on: Bool
        var configuration: AmbilightConfiguration?
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
    /// The TV turned a pairing step down with an HTTP status; 401 at the grant is a wrong PIN.
    case pairingRefused(status: Int)

    var description: String {
        switch self {
        case .unreachable(let detail): "the TV did not answer: \(detail)"
        case .connectionRefused(let port): "the TV refuses connections on port \(port)"
        case .httpStatus(let status): "the TV answered HTTP \(status)"
        case .unauthorized: "the TV refused the credentials: pair it again"
        case .invalidResponse(let detail): "unexpected answer from the TV: \(detail)"
        case .certificateMismatch(let expected, let observed): "the TV's certificate (\(observed)) is not the pinned one (\(expected))"
        case .pairingRefused(let status): Self.pairingMessages[status] ?? "the TV answered HTTP \(status)"
        }
    }

    /// What the Homebridge plugin says for each status a pairing step can get (its `ERROR_MESSAGES`).
    static let pairingMessages: [Int: String] = [
        401: "Invalid PIN code. Please check the PIN on your TV screen and try again.",
        403: "Access denied. The TV rejected the pairing request.",
        404: "Pairing endpoint not found. Your TV may not support this pairing method.",
        408: "Request timeout. The TV took too long to respond.",
        500: "TV internal error. Please try again.",
        503: "TV is temporarily unavailable. Please try again later.",
    ]
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
    /// Tries plain HTTP before HTTPS for this client, HTTPS still the fallback. The `notifychange`
    /// long-poll uses it: sets that serve `notifychange` on 1925 keep the channel off the TLS connector,
    /// whose patched SSL read loop can spin forever and wedge the whole API (docs/jointspace-api.md).
    /// A payload naming resources the plain connector does not serve still returns the ones it does.
    private let preferPlain: Bool
    private var lastRequestEnded: ContinuousClock.Instant?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Launch intents the TV reported for its apps, so launches use the right activity.
    private var intents: [String: JointSpace.Intent] = [:]
    /// The Ambilight menu nodes, once read from the menu structure.
    private var menuNodes: JointSpace.AmbilightMenuNodes?
    /// The structure read in progress, shared by concurrent callers.
    private var menuNodesRequest: Task<JointSpace.AmbilightMenuNodes?, Never>?
    /// No structure read before this, after a failed one.
    private var menuStructureRetryAt: ContinuousClock.Instant?
    private let menuStructureRetry: Duration
    /// The style list and its Off entry, while this TV's menu reports Ambilight's on/off.
    private var menuState: (style: Int, off: Int)?
    /// Missed menu reads in a row while `menuState` is set.
    private var menuStateMisses = 0
    let logger: Logger
    /// Between the end of one request and the start of the next (`JointSpace.gapBetweenRequests`).
    private let gap: Duration

    init(
        ip: String, username: String, password: String, certificateFingerprint: String?, transports: any JointSpaceTransportFactory, logger: Logger,
        gap: Duration = JointSpace.gapBetweenRequests, preferPlain: Bool = false, menuStructureRetry: Duration = JointSpace.menuStructureRetry
    ) {
        self.gap = gap
        self.menuStructureRetry = menuStructureRetry
        self.preferPlain = preferPlain
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

    /// The foreground app's package and activity, for adding it as a custom app.
    func currentIntent() async throws -> (packageName: String, className: String?)? {
        struct Activity: Decodable {
            struct Component: Decodable { var packageName: String?; var className: String? }
            var component: Component?
        }
        let activity: Activity = try await get("activities/current")
        guard let package = activity.component?.packageName, !package.isEmpty else { return nil }
        return (package, activity.component?.className?.nonEmpty)
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

    /// Off through the style menu's Off entry on a TV whose menu reports on/off, as the TV's Ambilight button
    /// does; else (or when the TV refuses it) through the style, then the power switch for sets that reject
    /// the style. On those TVs a style OFF darkens the LEDs but leaves the menu on its last style, which the
    /// next poll would read back as on. Only nodes already known: switching off never waits on the menu.
    func setAmbilightOff() async throws {
        if let menuState, (try? await updateMenuSetting(menuState.style, ["activenode_id": menuState.off])) != nil { return }
        do {
            try await setAmbilightStyle("OFF")
        } catch {
            try await setAmbilightPower(false)
        }
    }

    /// The menu's brightness, 0 to 10, on the node this TV reports (the long-known one when it reports none).
    func setAmbilightBrightness(_ level: Int) async throws {
        let clamped = min(max(level, JointSpace.ambilightBrightnessRange.lowerBound), JointSpace.ambilightBrightnessRange.upperBound)
        let node = await ambilightMenuNodes()?.brightness ?? JointSpace.ambilightBrightnessNode
        try await updateMenuSetting(node, ["value": clamped])
    }

    /// Ambilight's state for a poll; nil when nothing should be applied this time.
    ///
    /// Some models (the 2024 Google TV OLEDs, a 77OLED848/12) answer OFF from `ambilight/currentconfiguration`
    /// and `ambilight/power` however Ambilight is lit. Where the settings menu answers, it decides on or off,
    /// and the configuration is read only while it is on. When such a TV's menu misses a read, nothing is
    /// applied: the endpoints it is known to get wrong would flip the tile.
    func ambilightState() async -> JointSpace.AmbilightReading? {
        let menuOn = await ambilightMenuState()
        if menuOn == false { return .init(on: false) }
        if menuOn == nil, hasAmbilightMenuState { return nil }
        let configuration = try? await ambilightConfiguration()
        let configurationOn = configuration.map { $0.style != "OFF" } ?? false
        if menuOn == true { return .init(on: true, configuration: configurationOn ? configuration : nil) }
        if let configuration { return .init(on: configurationOn, configuration: configuration) }
        guard let power = try? await ambilightPower() else { return nil }
        return .init(on: power)
    }

    /// Whether Ambilight is on by the TV's settings menu, or nil when the TV has no such entries or did not
    /// answer: the style list's active entry is its Off entry exactly when Ambilight is off.
    func ambilightMenuState() async -> Bool? {
        guard let nodes = await ambilightMenuNodes(), let style = nodes.style, let off = nodes.off else { return nil }
        let answer: JSONPayload? = try? await post("menuitems/settings/current", ["nodes": [["nodeid": style]]], reading: JSONPayload.self)
        guard let active = answer?["values"]?.first?["value"]?["data"]?["activenode_id"]?.nodeID else {
            if menuState != nil {
                menuStateMisses += 1
                if menuStateMisses >= JointSpace.menuStateMaxMisses {
                    logger.debug("The Ambilight menu missed \(JointSpace.menuStateMaxMisses) reads in a row: back to the Ambilight endpoints")
                    menuState = nil
                    menuStateMisses = 0
                }
            }
            return nil
        }
        menuState = (style, off)
        menuStateMisses = 0
        return active != off
    }

    /// True while this TV's settings menu reports Ambilight's on/off.
    var hasAmbilightMenuState: Bool { menuState != nil }

    /// This TV's Ambilight menu nodes, read from its menu structure once. A failed read is tried again, but
    /// not before `menuStructureRetry`.
    func ambilightMenuNodes() async -> JointSpace.AmbilightMenuNodes? {
        if let menuNodes { return menuNodes }
        if let menuStructureRetryAt, ContinuousClock.now < menuStructureRetryAt { return nil }
        if let menuNodesRequest { return await menuNodesRequest.value }
        let request = Task { await self.readAmbilightMenuNodes() }
        menuNodesRequest = request
        let nodes = await request.value
        menuNodesRequest = nil
        return nodes
    }

    private func readAmbilightMenuNodes() async -> JointSpace.AmbilightMenuNodes? {
        let structure: JSONPayload
        do {
            structure = try await get("menuitems/settings/structure", timeout: JointSpace.menuStructureTimeout)
        } catch is CancellationError {
            return nil
        } catch {
            menuStructureRetryAt = .now + menuStructureRetry
            return nil
        }
        let style = structure.menuNode(context: JointSpace.ambilightStyleContext)
        let nodes = JointSpace.AmbilightMenuNodes(
            style: style?.menuNodeID, off: style?.menuNode(context: JointSpace.ambilightOffContext)?.menuNodeID,
            brightness: structure.menuNode(context: JointSpace.ambilightBrightnessContext)?.menuNodeID)
        logger.debug("Ambilight menu nodes: style \(nodes.style.map(String.init) ?? "-"), off \(nodes.off.map(String.init) ?? "-"), brightness \(nodes.brightness.map(String.init) ?? "-")")
        menuNodes = nodes
        return nodes
    }

    private func updateMenuSetting(_ node: Int, _ data: [String: Int]) async throws {
        struct Value: Encodable {
            var Nodeid: Int
            var data: [String: Int]
        }
        try await post("menuitems/settings/update", ["values": [["value": Value(Nodeid: node, data: data)]]])
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

    /// A POST whose answer is read: the menu's current values.
    func post<T: Decodable>(_ path: String, _ body: some Encodable, reading: T.Type, timeout: Duration = JointSpace.postTimeout) async throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let response = try await send(method: "POST", path: path, body: try encoder.encode(body), timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw JointSpaceError.invalidResponse("\(path): \(error)")
        }
    }

    /// A long request outside the gap and queue of the others: the long-poll client's `notifychange`.
    func longPost(_ path: String, _ body: some Encodable, timeout: Duration) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try await request(method: "POST", path: path, body: try encoder.encode(body), timeout: timeout).body
    }

    /// One request at a time, `gap` after the previous one.
    private func send(method: String, path: String, body: Data?, timeout: Duration) async throws -> HTTPResponse {
        await acquire()
        defer { release() }
        if let ended = lastRequestEnded {
            let wait = ended + gap - ContinuousClock.now
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
        } else if preferPlain {
            schemes = ["http", "https"]
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
                // Only a refused port means the set does not serve this scheme; a TV that is asleep or away
                // stays out of reach either way, and an answer of any kind ends the probing. Falling
                // through to the next candidate covers both orders: HTTPS-then-plain, and the plain-first
                // order `preferPlain` uses for the long-poll.
                if case .connectionRefused = error, candidate != schemes.last { continue }
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

extension JSONPayload {
    /// The first node of a menu (sub)tree with this context, depth first: a node's own context, then its
    /// children (an object's in key order, an array's in order).
    func menuNode(context: String) -> JSONPayload? {
        switch self {
        case .object(let object):
            if object["context"]?.stringValue == context { return self }
            for key in object.keys.sorted() {
                if let hit = object[key]?.menuNode(context: context) { return hit }
            }
            return nil
        case .array(let array):
            for element in array {
                if let hit = element.menuNode(context: context) { return hit }
            }
            return nil
        default:
            return nil
        }
    }

    /// A menu node's `node_id`.
    var menuNodeID: Int? { self["node_id"]?.nodeID }

    /// A node id: a whole number, or a string of digits as some firmware sends it.
    var nodeID: Int? {
        switch self {
        case .number(let value) where value.rounded() == value && abs(value) < 1e15: Int(value)
        case .string(let value) where !value.isEmpty && value.allSatisfy({ $0.isASCII && $0.isWholeNumber }): Int(value)
        default: nil
        }
    }

    /// An array's first element.
    var first: JSONPayload? {
        if case .array(let array) = self { return array.first }
        return nil
    }
}
