import Foundation
import NIOConcurrencyHelpers

@testable import HomeswiftNetwork
@testable import HomeswiftPhilipsAmbilightTV

/// A Philips TV's JointSpace API in memory: HTTPS on 1926 only, Digest authentication, the endpoints the
/// plugin uses, a notification queue for `notifychange`, and a record of what the plugin sent.
actor FakeTV: HTTPSending {
    static let fingerprint = String(repeating: "ab", count: 32)
    static let realm = "XTV"
    static let nonce = "7f3c1b"

    var username = "user1"
    var password = "secret"
    var reachable = true
    var power = "Standby"
    var volume = (current: 12, muted: false)
    var ambilight = JointSpace.AmbilightConfiguration(styleName: "OFF", isExpert: false)
    var ambilightPower = false
    var hueLamp = false
    var currentApp = "com.google.android.tvlauncher"
    var applications: [JointSpace.Application] = [
        .init(id: "netflix", label: "Netflix", intent: .init(component: .init(packageName: "com.netflix.ninja", className: "com.netflix.ninja.MainActivity"), action: "android.intent.action.MAIN")),
        .init(id: "youtube", label: "YouTube", intent: .init(component: .init(packageName: "com.google.android.youtube.tv", className: "com.google.android.apps.youtube.tv.activity.ShellActivity"), action: "android.intent.action.MAIN")),
        .init(id: "settings", label: "Settings", intent: .init(component: .init(packageName: "com.android.tv.settings", className: "x"), action: "android.intent.action.MAIN")),
        .init(id: "disney", label: "Disney+", intent: .init(component: .init(packageName: "com.disney.disneyplus", className: "com.bamtechmedia.dominguez.main.MainActivity"), action: "android.intent.action.MAIN")),
    ]
    /// nil: the TV answers 404, as sets without the endpoint do.
    var networkDevices: [[String: String]]? = [["id": "wifi0", "mac": "aa:bb:cc:dd:ee:ff", "ip": "192.168.1.20", "type": "wifi", "wake-on-lan": "Enabled"]]
    var menuBrightness: Int?
    var pin = "1234"
    /// nil: a wrong PIN gets a 200 with INVALID_PIN; a status: the grant is answered with it.
    var wrongPINStatus: Int?
    var authKey = "key-from-tv"
    var pairingTimestamp = 42

    private(set) var launches: [JointSpace.Intent] = []
    private(set) var keys: [String] = []
    private(set) var channels: [Int] = []
    private(set) var ambilightWrites: [JointSpace.AmbilightConfiguration] = []
    private(set) var requests: [(method: String, path: String)] = []
    private(set) var challenges = 0
    /// Device ids the TV paired with, and their auth keys: accepted like the configured credentials.
    private(set) var paired: [String: String] = [:]
    private var notifications: [[String: JSONPayload]] = []

    func set(power: String) { self.power = power }
    func set(reachable: Bool) { self.reachable = reachable }
    func set(networkDevices: [[String: String]]?) { self.networkDevices = networkDevices }
    func set(currentApp: String) { self.currentApp = currentApp }
    func set(muted: Bool) { volume.muted = muted }
    func set(ambilight: JointSpace.AmbilightConfiguration) { self.ambilight = ambilight }
    func set(applications: [JointSpace.Application]) { self.applications = applications }
    func set(hueLamp: Bool) { self.hueLamp = hueLamp }
    func set(wrongPINStatus: Int?) { self.wrongPINStatus = wrongPINStatus }
    func clearLaunches() { launches.removeAll() }

    /// Queues a notification for the next `notifychange`.
    func notify(_ payload: [String: JSONPayload]) { notifications.append(payload) }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard reachable else { throw HTTPClientError.timeout }
        guard request.url.scheme == "https", request.url.port == JointSpace.securePort else { throw HTTPClientError.connectionClosed }
        let uri = request.url.path
        let path = String(uri.dropFirst("/\(JointSpace.version)/".count))
        requests.append((request.method, path))
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        if path == "pair/request" {
            return json(["auth_key": authKey, "timestamp": pairingTimestamp, "timeout": 60, "error_id": "SUCCESS"])
        }
        var accepted = [username: password]
        for (id, key) in paired { accepted[id] = key }
        if path == "pair/grant", let id = (body["device"] as? [String: Any])?["id"] as? String { accepted[id] = authKey }
        guard let authorization = request.header("Authorization"), accepted.contains(where: { Self.digestIsValid(authorization, method: request.method, uri: uri, username: $0.key, password: $0.value) }) else {
            challenges += 1
            return HTTPResponse(status: 401, headers: [("WWW-Authenticate", "Digest realm=\"\(Self.realm)\", nonce=\"\(Self.nonce)\", qop=\"auth\"")], certificateFingerprint: Self.fingerprint)
        }
        if path == "pair/grant" {
            let auth = body["auth"] as? [String: Any] ?? [:]
            guard auth["pin"] as? String == pin, auth["auth_signature"] as? String == JointSpacePairing.signature(timestamp: pairingTimestamp, pin: pin) else {
                if let wrongPINStatus { return HTTPResponse(status: wrongPINStatus, certificateFingerprint: Self.fingerprint) }
                return json(["error_id": "INVALID_PIN", "error_text": "Invalid pin"])
            }
            if let id = (body["device"] as? [String: Any])?["id"] as? String { paired[id] = authKey }
            return json(["error_id": "SUCCESS"])
        }

        switch (request.method, path) {
        case ("GET", "powerstate"): return json(["powerstate": power])
        case ("POST", "powerstate"):
            if let state = body["powerstate"] as? String { power = state }
            return ok()
        case ("GET", "audio/volume"): return json(["current": volume.current, "min": 0, "max": 60, "muted": volume.muted])
        case ("POST", "audio/volume"):
            if let muted = body["muted"] as? Bool { volume.muted = muted }
            return ok()
        case ("POST", "input/key"):
            keys.append(body["key"] as? String ?? "?")
            return ok()
        case ("GET", "activities/current"): return json(["component": ["packageName": currentApp, "className": "x"]])
        case ("POST", "activities/launch"):
            guard let data = request.body, let wrapper = try? JSONDecoder().decode([String: JointSpace.Intent].self, from: data), let intent = wrapper["intent"] else { return HTTPResponse(status: 400) }
            // The TV rejects an activity it does not know.
            if intent.component.packageName == "com.disney.disneyplus", intent.component.className.hasSuffix(".MainActivity") { return HTTPResponse(status: 400) }
            launches.append(intent)
            if intent.action == JointSpace.sourceSelectAction {
                currentApp = Inputs.playTVPackage
            } else {
                currentApp = intent.component.packageName
            }
            return ok()
        case ("POST", "activities/tv"):
            channels.append((body["channel"] as? [String: Any])?["ccid"] as? Int ?? -1)
            return ok()
        case ("GET", "applications"):
            return HTTPResponse(status: 200, body: try JSONEncoder().encode(["applications": applications]), certificateFingerprint: Self.fingerprint)
        case ("GET", "ambilight/power"): return json(["power": ambilightPower ? "On" : "Off"])
        case ("POST", "ambilight/power"):
            ambilightPower = body["power"] as? String == "On"
            if !ambilightPower { ambilight = .init(styleName: "OFF") }
            return ok()
        case ("GET", "ambilight/currentconfiguration"):
            return HTTPResponse(status: 200, body: try JSONEncoder().encode(ambilight), certificateFingerprint: Self.fingerprint)
        case ("POST", "ambilight/currentconfiguration"):
            guard let data = request.body, let configuration = try? JSONDecoder().decode(JointSpace.AmbilightConfiguration.self, from: data) else { return HTTPResponse(status: 400) }
            ambilightWrites.append(configuration)
            ambilight = configuration
            ambilightPower = configuration.style != "OFF"
            return ok()
        case ("POST", "menuitems/settings/update"):
            menuBrightness = (((body["values"] as? [[String: Any]])?.first?["value"] as? [String: Any])?["data"] as? [String: Any])?["value"] as? Int
            return ok()
        case ("GET", "HueLamp/power"): return json(["power": hueLamp ? "On" : "Off"])
        case ("POST", "HueLamp/power"):
            hueLamp = body["power"] as? String == "On"
            return ok()
        case ("GET", "system"): return json(["name": "Fake TV", "softwareversion": "TPM191E_R.101.001.030.001"])
        case ("GET", "network/devices"):
            guard let networkDevices else { return HTTPResponse(status: 404, certificateFingerprint: Self.fingerprint) }
            return json(networkDevices)
        case ("POST", "notifychange"):
            // Held open until a notification is queued, for a while.
            for _ in 0..<40 {
                if !notifications.isEmpty { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard !notifications.isEmpty else { return json([:]) }
            let payload = notifications.removeFirst()
            return HTTPResponse(status: 200, body: try JSONEncoder().encode(payload), certificateFingerprint: Self.fingerprint)
        default:
            return HTTPResponse(status: 404, certificateFingerprint: Self.fingerprint)
        }
    }

    private func ok() -> HTTPResponse { json([:]) }

    private func json(_ object: Any) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: try! JSONSerialization.data(withJSONObject: object), certificateFingerprint: Self.fingerprint)
    }

    /// Checks a Digest header the way the TV would.
    static func digestIsValid(_ header: String, method: String, uri: String, username: String, password: String) -> Bool {
        var parameters: [String: String] = [:]
        for part in header.dropFirst("Digest ".count).split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            if pair.count == 2 { parameters[pair[0]] = pair[1] }
        }
        guard parameters["username"] == username, parameters["realm"] == realm, parameters["nonce"] == nonce, parameters["uri"] == uri,
              let nc = parameters["nc"], let cnonce = parameters["cnonce"], parameters["qop"] == "auth" else { return false }
        let ha1 = DigestAuthentication.md5("\(username):\(realm):\(password)")
        let ha2 = DigestAuthentication.md5("\(method):\(uri)")
        return parameters["response"] == DigestAuthentication.md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
    }
}

/// Hands the plugin the fake TV, refusing a pin that is not the TV's certificate as the real client would.
struct FakeTransports: JointSpaceTransportFactory {
    let tv: FakeTV

    func makeTransport(tls: HTTPClient.TLS) -> any HTTPSending { PinChecking(tv: tv, tls: tls) }

    struct PinChecking: HTTPSending {
        let tv: FakeTV
        let tls: HTTPClient.TLS

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            if case .pinned(let expected) = tls, HTTPClient.normalizeFingerprint(expected) != FakeTV.fingerprint, request.url.scheme == "https" {
                throw HTTPClientError.certificateMismatch(expected: HTTPClient.normalizeFingerprint(expected), observed: FakeTV.fingerprint)
            }
            return try await tv.send(request)
        }
    }
}

/// A TV reduced to its transport behaviour per scheme, for the policy tests: HTTPS answers with a certificate,
/// refuses, or hangs; HTTP answers or refuses. Every answer is `{"powerstate":"On"}`, no Digest challenge.
actor SchemeFakeTV {
    /// nil: nothing listens on 1926.
    var httpsFingerprint: String? = FakeTV.fingerprint
    var httpsTimesOut = false
    var httpAnswers = true
    private(set) var schemes: [String] = []

    func set(httpsFingerprint: String?) { self.httpsFingerprint = httpsFingerprint }
    func set(httpsTimesOut: Bool) { self.httpsTimesOut = httpsTimesOut }
    func set(httpAnswers: Bool) { self.httpAnswers = httpAnswers }

    func send(_ request: HTTPRequest, tls: HTTPClient.TLS) async throws -> HTTPResponse {
        let scheme = request.url.scheme ?? "?"
        schemes.append(scheme)
        if scheme == "https" {
            if httpsTimesOut { throw HTTPClientError.timeout }
            guard let fingerprint = httpsFingerprint else { throw HTTPClientError.cannotConnect(host: "tv", port: JointSpace.securePort, code: ECONNREFUSED, reason: "connection refused") }
            if case .pinned(let expected) = tls, HTTPClient.normalizeFingerprint(expected) != fingerprint {
                throw HTTPClientError.certificateMismatch(expected: HTTPClient.normalizeFingerprint(expected), observed: fingerprint)
            }
            return HTTPResponse(status: 200, body: Data(#"{"powerstate":"On"}"#.utf8), certificateFingerprint: fingerprint)
        }
        guard httpAnswers else { throw HTTPClientError.cannotConnect(host: "tv", port: JointSpace.plainPort, code: ECONNREFUSED, reason: "connection refused") }
        return HTTPResponse(status: 200, body: Data(#"{"powerstate":"On"}"#.utf8))
    }
}

struct SchemeFakeTransports: JointSpaceTransportFactory {
    let tv: SchemeFakeTV

    func makeTransport(tls: HTTPClient.TLS) -> any HTTPSending { Transport(tv: tv, tls: tls) }

    struct Transport: HTTPSending {
        let tv: SchemeFakeTV
        let tls: HTTPClient.TLS
        func send(_ request: HTTPRequest) async throws -> HTTPResponse { try await tv.send(request, tls: tls) }
    }
}
