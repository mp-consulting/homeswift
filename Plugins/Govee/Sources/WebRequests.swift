import Crypto
import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

extension GoveePlugin {
    /// Scene icons are proxied from Govee's asset CDN and web app only.
    static let iconHosts: Set<String> = ["d1f2504ijhdyjw.cloudfront.net", "app.govee.com"]
    static let iconTimeout: Duration = .seconds(10)
    static let iconMaximumBytes = 512 * 1024
    static let iconBatchSize = 60
    static let iconCacheSize = 800

    /// The settings page's requests (`homebridge-ui/server.js`): `discover`, `test-login`, `cached-devices`,
    /// `clear-cache`, `scenes`, `diys`, `device-capabilities` and `scene-icons`, plus `devices`, the instance's
    /// devices and how it reaches them. `Web/` is the page.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch request.path {
        case "devices":
            return PluginWebResponse(["devices": .array(await deviceStatus())])
        case "discover":
            return await discover(request.body)
        case "test-login":
            return await testLogin(request.body)
        case "cached-devices", "get-cached-devices":
            return PluginWebResponse(["devices": .array(cachedDevices())])
        case "clear-cache":
            return PluginWebResponse(clearCache())
        case "scenes":
            return await scenes(request.body)
        case "diys":
            return await diys(request.body)
        case "device-capabilities":
            return await capabilities(request.body)
        case "scene-icons":
            return PluginWebResponse(["icons": .object(await sceneIcons(request.body["urls"]?.arrayValue?.compactMap(\.stringValue) ?? []))])
        default:
            return .error(404, "nothing at \(request.method) \(request.path)")
        }
    }

    /// The instance's devices: what they are, how they are reached, when they last reported.
    private func deviceStatus() async -> [JSONValue] {
        var list: [JSONValue] = []
        for device in devices.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let category = await device.handler.category
            var entry: [String: JSONValue] = [
                "deviceId": .string(device.id), "name": .string(device.name), "model": .string(device.model),
                "list": .string(DeviceConfigKey(model: device.model).rawValue), "kind": .string("\(category)"), "external": .bool(device.external),
                "lan": .string(device.transports.label(device.transports.hasLAN, device.transports.useLAN)),
                "aws": .string(device.transports.label(device.transports.hasAWS, device.transports.useAWS)),
                "ble": .string(device.transports.label(device.transports.hasBLE, device.transports.useBLE)),
            ]
            if let date = device.lastUpdate { entry["lastUpdate"] = .number((date.timeIntervalSince1970 * 1000).rounded()) }
            list.append(.object(entry))
        }
        return list
    }

    // MARK: Account

    private struct PageCredentials {
        var username: String
        var password: String
        var code: String?
    }

    private func credentials(_ body: JSONValue) -> PageCredentials? {
        guard let username = body["username"]?.stringValue?.trimmingCharacters(in: .whitespaces), !username.isEmpty,
            let password = body["password"]?.stringValue, !password.isEmpty
        else { return nil }
        let code = body["code"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
        return PageCredentials(username: username, password: password, code: code)
    }

    private func api(for username: String) -> GoveeAPI {
        GoveeAPI(transport: dependencies.http, clientId: GoveeAPI.clientId(username: username))
    }

    /// Logs in for the page, reusing the last login while the same username and password are entered.
    private func authenticate(_ credentials: PageCredentials) async throws -> (api: GoveeAPI, token: String) {
        let key = Secrets.hex(SHA256.hash(data: Data("\(credentials.username)\u{0}\(credentials.password)".utf8)))
        let api = api(for: credentials.username)
        if let session = pageSession, session.key == key { return (api, session.token) }
        let login = try await api.login(username: credentials.username, password: credentials.password, code: credentials.code, audience: .settingsPage)
        pageSession = (key, login.token)
        return (api, login.token)
    }

    private func discover(_ body: JSONValue) async -> PluginWebResponse {
        guard let credentials = credentials(body) else { return .error(400, "Username and password are required") }
        do {
            let (api, token) = try await authenticate(credentials)
            let list = try await api.devices(token: token)
            let devices: [JSONValue] = list.map { device in
                var entry: [String: JSONValue] = [
                    "deviceId": device["device"] ?? .null, "deviceName": device["deviceName"] ?? .null, "model": device["sku"] ?? .null,
                ]
                for key in ["goodsType", "pactType", "pactCode", "versionSoft", "versionHard"] { entry[key] = device[key] ?? .null }
                entry["deviceType"] = .string(DeviceConfigKey(model: device["sku"]?.stringValue).rawValue)
                return .object(entry)
            }
            return PluginWebResponse(["devices": .array(devices)])
        } catch let error as GoveeAPIError {
            return .error(Self.status(error), error.description)
        } catch {
            return .error(500, "\(error)")
        }
    }

    private static func status(_ error: GoveeAPIError) -> Int {
        switch error {
        case .unauthorized(let status), .httpStatus(let status, _): status
        default: 500
        }
    }

    private func testLogin(_ body: JSONValue) async -> PluginWebResponse {
        guard let credentials = credentials(body) else { return .error(400, "Username and password are required") }
        do {
            let login = try await api(for: credentials.username).login(
                username: credentials.username, password: credentials.password, code: credentials.code, audience: .settingsPage)
            return PluginWebResponse(["success": true, "message": .string("Login successful. Account ID: \(login.accountId)")])
        } catch let error as GoveeAPIError {
            // A new-device challenge is not a failure: a code was just emailed, and the page asks for it.
            var required = false
            var invalid = false
            if case .twoFactorRequired = error { required = true }
            if case .twoFactorInvalid = error { invalid = true }
            return PluginWebResponse(["success": false, "twoFactorRequired": .bool(required), "twoFactorInvalid": .bool(invalid), "message": .string(error.description)])
        } catch {
            return PluginWebResponse(["success": false, "twoFactorRequired": false, "twoFactorInvalid": false, "message": .string("\(error)")])
        }
    }

    private func cachedDevices() -> [JSONValue] {
        discovered.isEmpty ? discoveredFile.load() ?? [] : discovered
    }

    /// Forgets the kept login, the IoT certificate, the discovered devices and the devices' state.
    private func clearCache() -> JSONValue {
        var errors: [String] = []
        let directory = context.storageDirectory
        for name in ["credentials.json", "discovered-devices.json", "device-state.json"] {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url) } catch { errors.append("Failed to clear cache: \(error.localizedDescription)") }
        }
        var credentialsCleared = true
        let certificate = directory.appendingPathComponent("govee.pfx")
        if FileManager.default.fileExists(atPath: certificate.path) {
            do { try FileManager.default.removeItem(at: certificate) } catch {
                credentialsCleared = false
                errors.append("Failed to clear credentials: \(error.localizedDescription)")
            }
        }
        pageSession = nil
        if errors.isEmpty {
            return [
                "success": true, "cacheCleared": true, "credentialsCleared": .bool(credentialsCleared), "errors": [],
                "message": "Cache cleared successfully. Please restart Homeswift to apply changes.",
            ]
        }
        return [
            "success": false, "cacheCleared": false, "credentialsCleared": .bool(credentialsCleared), "errors": .array(errors.map(JSONValue.string)),
            "message": .string("Cache partially cleared. Errors: \(errors.joined(separator: ", "))"),
        ]
    }

    // MARK: Scenes

    private func deviceRef(_ body: JSONValue) -> GoveeContent.DeviceRef? {
        let sku = (body["model"]?.stringValue ?? "").uppercased()
        guard !sku.isEmpty, let device = body["deviceId"]?.stringValue, !device.isEmpty else { return nil }
        return GoveeContent.DeviceRef(
            sku: sku, device: device, goodsType: Configuration.integer(body["goodsType"]), versionSoft: body["versionSoft"]?.stringValue,
            versionHard: body["versionHard"]?.stringValue, pactType: Configuration.integer(body["pactType"]), pactCode: Configuration.integer(body["pactCode"]))
    }

    /// The device's scene library from Govee, or the bundled one when Govee cannot be reached or there is no
    /// login; the answer says which.
    private func scenes(_ body: JSONValue) async -> PluginWebResponse {
        guard let ref = deviceRef(body) else { return .error(400, "A device ID and model are required to load scenes.") }
        do {
            guard let credentials = credentials(body) else { throw GoveeAPIError.message("Enter your Govee credentials in the Settings tab first.") }
            let (api, token) = try await authenticate(credentials)
            return PluginWebResponse(GoveeContent.json(try await GoveeContent.sceneLibrary(api: api, token: token, ref: ref)))
        } catch {
            guard let offline = SceneCatalogue.library(sku: ref.sku, device: ref.device) else {
                return .error((error as? GoveeAPIError).map(Self.status) ?? 500, "\(error)")
            }
            var json = GoveeContent.json(offline)
            if case .object(var object) = json {
                object["warning"] = .string("\(error)")
                json = .object(object)
            }
            return PluginWebResponse(json)
        }
    }

    /// The account's DIY effects for the device: cloud only.
    private func diys(_ body: JSONValue) async -> PluginWebResponse {
        guard let ref = deviceRef(body) else { return .error(400, "A device ID and model are required to load DIY effects.") }
        do {
            guard let credentials = credentials(body) else { throw GoveeAPIError.message("Enter your Govee credentials in the Settings tab first.") }
            let (api, token) = try await authenticate(credentials)
            let entries = try await GoveeContent.diyEffects(api: api, token: token, ref: ref)
            return PluginWebResponse(["diys": .array(entries.map(GoveeContent.json))])
        } catch {
            return .error((error as? GoveeAPIError).map(Self.status) ?? 500, "\(error)")
        }
    }

    /// The modes the device has; `modes: null` when unknown, which the page takes as "show everything".
    private func capabilities(_ body: JSONValue) async -> PluginWebResponse {
        guard let ref = deviceRef(body) else { return .error(400, "A device ID and model are required.") }
        do {
            guard let credentials = credentials(body) else { throw GoveeAPIError.message("no credentials") }
            let (api, token) = try await authenticate(credentials)
            let support = try await GoveeContent.functionSupport(api: api, token: token, ref: ref)
            return PluginWebResponse([
                "modes": support.modes.isEmpty ? .null : .array(support.modes.map(JSONValue.string)), "modeIds": .array(support.modeIds.map { .number(Double($0)) }),
            ])
        } catch {
            return PluginWebResponse(["modes": .null, "modeIds": []])
        }
    }

    /// Scene icons as data URIs, so the browser never reaches Govee's CDN. A batch of 60 at most; icons that
    /// fail are left out.
    func sceneIcons(_ urls: [String]) async -> [String: JSONValue] {
        var unique: [String] = []
        for url in urls where !unique.contains(url) {
            unique.append(url)
            if unique.count == Self.iconBatchSize { break }
        }
        var icons: [String: JSONValue] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for url in unique {
                if let cached = iconCache[url] {
                    icons[url] = .string(cached)
                    continue
                }
                let transport = dependencies.icons
                group.addTask { (url, await Self.fetchIcon(url, transport: transport)) }
            }
            for await (url, icon) in group {
                guard let icon else { continue }
                icons[url] = .string(icon)
                if iconCache.count > Self.iconCacheSize { iconCache.removeAll() }
                iconCache[url] = icon
            }
        }
        return icons
    }

    /// One icon from Govee's hosts, over HTTPS, without following redirects, at most 512 KB.
    static func fetchIcon(_ url: String, transport: any HTTPSending) async -> String? {
        guard let parsed = URL(string: url), parsed.scheme == "https", let host = parsed.host, iconHosts.contains(host) else { return nil }
        guard let response = try? await transport.send(HTTPRequest(url: parsed, timeout: iconTimeout)), response.isSuccess,
            response.body.count <= iconMaximumBytes
        else { return nil }
        let type = response.header("Content-Type") ?? "image/png"
        guard type.hasPrefix("image/") else { return nil }
        return "data:\(type);base64,\(response.body.base64EncodedString())"
    }
}
