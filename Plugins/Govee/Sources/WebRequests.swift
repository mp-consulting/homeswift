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

    /// The plugin page's requests (from `homebridge-ui/server.js`): `discover`, `cached-devices`, `clear-cache`,
    /// `scenes`, `diys` and `scene-icons`, plus `devices`, the instance's devices and how it reaches them. All use the
    /// instance's own login (the vault's, or config.json's): Setup signs in, so no password comes from the page.
    /// `Web/` is the page, which writes no settings: those are the Settings page's.
    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch request.path {
        case "devices":
            return PluginWebResponse(["devices": .array(await deviceStatus()), "signedIn": .bool(account != nil || accountLogin() != nil)])
        case "discover":
            return await discover()
        case "cached-devices", "get-cached-devices":
            return PluginWebResponse(["devices": .array(cachedDevices())])
        case "clear-cache":
            return PluginWebResponse(clearCache())
        case "scenes":
            return await scenes(request.body)
        case "diys":
            return await diys(request.body)
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
                "list": .string(DeviceConfigKey(model: device.model).rawValue), "kind": .string("\(category)"),
                "lan": .string(device.transports.label(device.transports.hasLAN, device.transports.useLAN)),
                "aws": .string(device.transports.label(device.transports.hasAWS, device.transports.useAWS)),
                "ble": .string(device.transports.label(device.transports.hasBLE, device.transports.useBLE)),
            ]
            if let date = device.lastUpdate { entry["lastUpdate"] = .number((date.timeIntervalSince1970 * 1000).rounded()) }
            // A light's scenes from its settings, by `<kind>:<sceneId>`, for the page's Scene Library.
            let scenes = (deviceSettings[device.id]?["scenes"]?.arrayValue ?? []).compactMap { scene -> JSONValue? in
                guard let id = scene["sceneId"].flatMap(Configuration.integer) else { return nil }
                return .string("\(scene["kind"]?.stringValue ?? "scene"):\(id)")
            }
            if !scenes.isEmpty { entry["scenes"] = .array(scenes) }
            list.append(.object(entry))
        }
        return list
    }

    // MARK: Account

    /// Logs in with the instance's login, reusing the last token while the username and password stay the same.
    private func authenticate(_ login: AccountLogin) async throws -> (api: GoveeAPI, token: String) {
        let key = Secrets.hex(SHA256.hash(data: Data("\(login.username)\u{0}\(login.password)".utf8)))
        let api = GoveeAPI(transport: dependencies.http, clientId: GoveeAPI.clientId(username: login.username))
        if let session = pageSession, session.key == key { return (api, session.token) }
        let answer = try await api.login(username: login.username, password: login.password, code: login.code)
        pageSession = (key, answer.token)
        return (api, answer.token)
    }

    /// No login: nothing in the vault, nor in config.json.
    struct MissingCredentials: Error, CustomStringConvertible {
        var description: String
        static let none = MissingCredentials(description: "Sign in to your Govee account on Add accessories first.")
    }

    /// The instance's login (its account's token, or else the vault's or config.json's username and password):
    /// the page and the Assistant read the account's devices and scenes without being handed the password.
    private func session() async throws -> (api: GoveeAPI, token: String) {
        if let account, let token = await account.token { return (account.api, token) }
        guard let login = accountLogin() else { throw MissingCredentials.none }
        return try await authenticate(login)
    }

    private func discover() async -> PluginWebResponse {
        do {
            let (api, token) = try await session()
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
        } catch let error as MissingCredentials {
            return .error(400, error.description)
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

    /// The devices found at the last start, each with whether it is on the bridge (`onBridge`) and left out (`excluded`:
    /// Excluded, or by the block's own `ignoreDevice` or `ignoreMatter`).
    private func cachedDevices() -> [JSONValue] {
        (discovered.isEmpty ? discoveredFile.load() ?? [] : discovered).map { item in
            guard var entry = item.objectValue, let id = entry["deviceId"]?.stringValue else { return item }
            entry["onBridge"] = .bool(devices[id] != nil)
            entry["excluded"] = .bool(isIgnored(id, model: entry["model"]?.stringValue))
            entry["kind"] = .string(Self.kind(ofModel: entry["model"]?.stringValue))
            return .object(entry)
        }
    }

    /// Forgets the kept token, the IoT certificate, the discovered devices and the devices' state.
    private func clearCache() -> JSONValue {
        var errors: [String] = []
        let directory = context.storageDirectory
        for name in ["discovered-devices.json", "device-state.json"] {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url) } catch { errors.append("Failed to clear cache: \(error.localizedDescription)") }
        }
        // The token and the certificate, in the vault; a password Setup kept stays.
        CredentialStore.clear(context)
        let credentialsCleared = CredentialStore.stored(context)?.credentials == nil
        pageSession = nil
        // What the running instance holds in memory goes too, or the next change (a light's address) would
        // write the devices' state back, and the page would still list the discovered devices.
        for key in store.values.keys { store.removeValue(forKey: key) }
        try? store.flush()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("device-state.json"))
        discovered = []
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
        return GoveeContent.DeviceRef(sku: sku, device: device, goodsType: Configuration.integer(body["goodsType"]))
    }

    /// The device's scene library from Govee, or the bundled one when Govee cannot be reached or there is no
    /// login; the answer says which.
    private func scenes(_ body: JSONValue) async -> PluginWebResponse {
        guard let ref = deviceRef(body) else { return .error(400, "A device ID and model are required to load scenes.") }
        do {
            let (api, token) = try await session()
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
            let (api, token) = try await session()
            let entries = try await GoveeContent.diyEffects(api: api, token: token, ref: ref)
            return PluginWebResponse(["diys": .array(entries.map(GoveeContent.json))])
        } catch {
            return .error((error as? GoveeAPIError).map(Self.status) ?? 500, "\(error)")
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
