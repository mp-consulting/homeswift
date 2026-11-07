import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"; docs/clean-room/SmartThings.md, 3.4 and 13.5): the account is SmartThings', a Browser
// Redirect on the person's own OAuth-In app. The first step asks for its client id and secret, the callback server's
// address and port, and whether the app has the `sse` scope; the next opens SmartThings' page while an HTTPS callback
// server waits for its redirect, or takes the address the browser ended on. The client goes to the vault as the
// account's credentials, the tokens to the plugin's secret file; the block keeps `locationId` and a typed callback
// address or port.
//
// Settings (docs/plugins.md, "Settings"): each device's Accessory Settings are in `_accessories` by its Device Id (the
// SmartThings `deviceId`, `scene:<sceneId>` for a scene); `canonicalSettings` moves the Homebridge shapes there.
extension SmartThingsPlugin {
    public static let accountAuthorization = AuthorizationMethod.browserRedirect

    /// Signed in while the vault holds a refresh token (or a personal access token) SmartThings has not refused.
    public func accountAuthorized() async -> Bool? {
        if await tokens.refusal != nil { return false }
        if let tokens = await tokens.tokens, await self.tokens.refusal == nil { return tokens.refresh_token != nil || tokens.isPersonal }
        if settings.text("oauth_refresh_token") != nil || settings.text("AccessToken") != nil { return true }
        return false
    }

    // MARK: Discovery

    /// The location's devices (the last list when it is under a minute old, else one call) and its scenes.
    public func discover() async throws -> [DiscoveredDevice] {
        await importTokens()
        guard await tokens.isSignedIn else { return [] }
        if listedAt.map({ dependencies.now().timeIntervalSince($0) > 60 }) ?? true {
            if locationNames.isEmpty { await readLocations() }
            do {
                let items = try await api.devices(locationID: locationID)
                listed = items.compactMap(SmartThingsDevice.init)
                listedAt = dependencies.now()
            } catch {
                throw SetupError("SmartThings did not list the devices: \(error)")
            }
            scenes = (try? await api.scenes(locationID: locationID).compactMap(SmartThingsScene.init)) ?? scenes
        }
        await readRooms()
        let found = MatterCopies.find(in: listed, homeswiftIDs: context.hostAccessories.map(\.id))
        var devices: [DiscoveredDevice] = []
        for device in listed where found[device.deviceID] == nil {
            let id = device.deviceID
            let kind = kindOf(device)
            let mappable = kind != "unsupported"
            let byLists = settings.excludedByLists(device, locationNames: locationNames)
            var discovered = DiscoveredDevice(
                deviceID: id, name: device.displayName, model: device.model, isSetUp: mappable && !byLists && !context.isExcluded(id),
                excludedBySettings: byLists || !mappable, kind: kind)
            discovered.isReachable = bindings[id]?.box.status.health != "OFFLINE"
            devices.append(discovered)
            if device.isMatter, loggedOnce.insert("matter:\(id)").inserted {
                logger.info("\(device.displayName) is a Matter device: it may already be in Apple Home through its own Matter pairing. If so, set it Not in Home.")
            }
        }
        for scene in scenes {
            devices.append(DiscoveredDevice(deviceID: "scene:\(scene.id)", name: scene.name, model: "SmartThings scene", isSetUp: !context.isExcluded("scene:\(scene.id)"), kind: "scene"))
        }
        return devices
    }

    /// The room names, read at most once an hour (50 calls an hour allowed, section 4.2).
    func readRooms() async {
        guard let locationID, roomsReadAt.map({ dependencies.now().timeIntervalSince($0) > 3600 }) ?? true else { return }
        roomsReadAt = dependencies.now()
        if let items = try? await api.rooms(locationID: locationID) {
            rooms = Dictionary(items.compactMap { item in item["roomId"]?.stringValue.map { ($0, item["name"]?.stringValue ?? "") } }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// A device's Device Kind (section 7.7): its accessory's, else what a build without side effects would make.
    func kindOf(_ device: SmartThingsDevice) -> String {
        if let binding = bindings[device.deviceID] { return binding.kind }
        if let known = kinds[device.deviceID] { return known }
        if device.isHub { return "unsupported" }
        let status = DeviceStatus()
        let options = deviceOptions(device)
        let kind = build(device, status: status, options: options, signature: "", context: nil)?.kind ?? "unsupported"
        kinds[device.deviceID] = kind
        return kind
    }

    public func deviceKind(of deviceID: String) async -> String? {
        if deviceID.hasPrefix("scene:") { return "scene" }
        if let binding = bindings[deviceID] { return binding.kind }
        return kinds[deviceID]
    }

    // MARK: Authorization

    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        try request.requireAccount("SmartThings devices come with the account: they need no setup of their own")
        if request.state["url"] == nil {
            let clientID = request.answer("client_id") ?? settings.clientID
            let clientSecret = request.secret("client_secret") ?? settings.clientSecret
            let detected = settings.callbackServerExternalAddress ?? dependencies.addresses().first ?? "127.0.0.1"
            guard let clientID, let clientSecret, let sse = request.choice("sse", among: ["yes", "no"]) else {
                return .ask(SetupPrompt(
                    message: "Enter the OAuth-In app you made for SmartThings (a SmartThings Developer plan is needed). Add {redirectURI} to its Redirect URIs, unless you change the callback server's address or port.",
                    values: ["redirectURI": SmartThingsOAuth.redirectURI(address: detected, port: settings.callbackServerPort)],
                    fields: [
                        SetupField("client_id", label: "OAuth Client Id", value: settings.clientID),
                        SetupField("client_secret", label: "OAuth Client Secret", kind: .secret, optional: settings.clientSecret != nil),
                        .choice("sse", label: "My app has the sse scope", options: [
                            SetupOption("yes", label: "Yes", detail: "Updates come at once through SmartThings' event stream."),
                            SetupOption("no", label: "No", detail: "Updates come by polling, once a minute at the most."),
                        ], value: "yes"),
                        SetupField("callbackServerExternalAddress", label: "Callback server address", optional: true),
                        SetupField("callbackServerPort", label: "Callback server port", optional: true),
                    ]))
            }
            let typedAddress = request.answer("callbackServerExternalAddress")
            let typedPort = request.answer("callbackServerPort")
            var port = settings.callbackServerPort
            if let typedPort {
                guard let value = Int(typedPort.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else {
                    throw SetupError("The callback server port must be between 1 and 65535")
                }
                port = value
            }
            let address = typedAddress ?? detected
            let redirectURI = SmartThingsOAuth.redirectURI(address: address, port: port)
            let state = SmartThingsOAuth.makeState()
            let oauth = SmartThingsOAuth(base: settings.baseURL, clientID: clientID, clientSecret: clientSecret, http: dependencies.transport)
            let url = oauth.authorizeURL(redirectURI: redirectURI, state: state, withSSE: sse == "yes")
            await startCallbackServer(PendingAuth(state: state, clientID: clientID, clientSecret: clientSecret, redirectURI: redirectURI, createdAt: dependencies.now()),
                                      address: address, port: port)
            var typed: [String: JSONValue] = [:]
            if let typedAddress { typed["callbackServerExternalAddress"] = .string(typedAddress) }
            if typedPort != nil { typed["callbackServerPort"] = .number(Double(port)) }
            return .ask(redirectPrompt(url), state: [
                "url": .string(url), "oauthState": .string(state), "redirectURI": .string(redirectURI), "settings": .object(typed),
                "client": ["client_id": .string(clientID), "client_secret": .string(clientSecret)], "sse": .string(sse),
            ])
        }
        let client = request.state["client"]?.objectValue ?? [:]
        guard let clientID = client["client_id"]?.stringValue, let clientSecret = client["client_secret"]?.stringValue,
              let expected = request.state["oauthState"]?.stringValue, let redirectURI = request.state["redirectURI"]?.stringValue else {
            throw SetupError("The sign-in ended: start it again")
        }
        if let pasted = request.answer("callbackUrl") {
            let pending = PendingAuth(state: expected, clientID: clientID, clientSecret: clientSecret, redirectURI: redirectURI, createdAt: dependencies.now())
            try await complete(callback: pasted, pending: pending)
        } else {
            switch authResult {
            case .success?: break
            case .failure(let error)?:
                authResult = nil
                throw error
            case nil:
                guard pendingAuth != nil else { throw SetupError("The sign-in ended: start it again") }
                return .ask(redirectPrompt(request.state["url"]?.stringValue ?? ""), state: request.state)
            }
        }
        authResult = nil
        pendingAuth = nil
        await callbackServer.stop()
        if request.state["sse"]?.stringValue == "yes", !(await tokens.grantsSSE) {
            logger.warning("SmartThings did not grant the sse scope: updates come by polling. Add sse to the app's scopes, then sign in again.")
        }
        var settingsOut = request.state["settings"]?.objectValue ?? [:]
        if let location = await tokens.tokens?.location_id { settingsOut["locationId"] = .string(location) }
        // The client and the tokens are in the vault: the block's own keys for them go.
        for key in ["client_id", "client_secret", "oauth_access_token", "oauth_refresh_token", "oauth_expires_in", "AccessToken"] { settingsOut[key] = .null }
        return .done(SetupOutcome(credentials: ["client_id": .string(clientID), "client_secret": .string(clientSecret)], settings: settingsOut))
    }

    private func redirectPrompt(_ url: String) -> SetupPrompt {
        SetupPrompt(
            message: "Sign in on SmartThings' page that opens, pick the location and allow access. The browser warns about this bridge's certificate when it comes back: accept it, or paste the address the browser ended on.",
            fields: [SetupField("callbackUrl", label: "Address the browser ended on", kind: .url, optional: true)], url: url,
            waitSeconds: Int(Self.authorizationWindow.components.seconds), retryAfter: 3)
    }

    private func startCallbackServer(_ pending: PendingAuth, address: String, port: Int) async {
        pendingAuth = pending
        authResult = nil
        do {
            try await callbackServer.start(
                port: port, hostname: address, bindAddress: dependencies.callbackBindAddress,
                certificateDirectory: context.storageDirectory.appendingPathComponent(Self.certificateDirectoryName), lifetime: Self.authorizationWindow
            ) { [weak self] uri in
                guard let self else { return (503, CallbackServer.page(success: false, message: "Homeswift is stopping")) }
                return await self.callbackRequest(uri)
            }
        } catch {
            logger.warning("Could not start the callback server on port \(port): \(error). Paste the address the browser ends on instead.")
        }
    }

    /// The browser, redirected by SmartThings to `/oauth/callback`.
    func callbackRequest(_ uri: String) async -> (status: Int, html: String) {
        guard uri.hasPrefix("/oauth/callback"), let pending = pendingAuth else {
            return (404, CallbackServer.page(success: false, message: "Nothing here"))
        }
        // A reload of the page after the sign-in worked: its code is spent, and the sign-in stays done.
        if case .success? = authResult {
            return (200, CallbackServer.page(success: true, message: "Signed in to SmartThings. You can close this page."))
        }
        do {
            try await complete(callback: "https://localhost" + uri, pending: pending)
            authResult = .success(())
            return (200, CallbackServer.page(success: true, message: "Signed in to SmartThings. You can close this page."))
        } catch let error as SetupError {
            authResult = .failure(error)
            return (200, CallbackServer.page(success: false, message: error.description))
        } catch {
            return (500, CallbackServer.page(success: false, message: "\(error)"))
        }
    }

    /// The redirect's `code` and `state` (section 3.3): a state not ours is refused, a refusal said, the code exchanged.
    func complete(callback: String, pending: PendingAuth) async throws {
        guard let query = URL(string: callback.trimmingCharacters(in: .whitespacesAndNewlines))?.query else {
            throw SetupError("That address has no code and state: paste the whole address the browser ended on")
        }
        let fields = URLEncoding.fields(query)
        guard let state = fields["state"], Secrets.constantTimeEqual(Array(state.utf8), Array(pending.state.utf8)) else {
            throw SetupError("That address is not from this sign-in: start it again")
        }
        if let error = fields["error"] {
            if error == "access_denied" { throw SetupError("Access was refused on SmartThings' page: sign in again and allow it") }
            throw SetupError("SmartThings refused the sign-in: \(error)\(fields["error_description"].map { " (\($0))" } ?? "")")
        }
        guard let code = fields["code"], !code.isEmpty else { throw SetupError("That address has no code: paste the whole address the browser ended on") }
        let oauth = SmartThingsOAuth(base: settings.baseURL, clientID: pending.clientID, clientSecret: pending.clientSecret, http: dependencies.transport)
        let response: TokenResponse
        do {
            response = try await oauth.exchange(code: code, redirectURI: pending.redirectURI)
        } catch let failure as TokenFailure {
            if case .refused(let code, let description, let status) = failure {
                logger.error("SmartThings refused the code: \(code)\(description.map { " (\($0))" } ?? "") (HTTP \(status))")
            }
            throw SetupError("\(failure)")
        }
        var stored = StoredTokens(response, now: dependencies.now(), locationID: nil)
        // The location the person picked: the only one the new token sees (section 3.3).
        let locations = await Self.locations(base: settings.baseURL, accessToken: stored.access_token, http: dependencies.transport)
        if let first = locations.first?["locationId"]?.stringValue { stored.location_id = first }
        for item in locations { if let id = item["locationId"]?.stringValue { locationNames[id] = item["name"]?.stringValue ?? id } }
        do {
            try await tokens.seed(stored)
        } catch {
            throw SetupError("Could not save the SmartThings tokens to the vault: \(error)")
        }
        locationID = stored.location_id ?? locationID
        context.accountAccepted()
    }

    /// `GET locations` with a token just received, before it is the store's.
    static func locations(base: URL, accessToken: String, http: any HTTPSending) async -> [JSONValue] {
        let request = HTTPRequest(url: base.appendingPathComponent("locations"), headers: [
            ("Authorization", "Bearer \(accessToken)"), ("Accept", "application/json"), ("User-Agent", SmartThingsAPI.userAgent),
        ], timeout: .seconds(15))
        guard let response = try? await http.send(request), response.isSuccess, let json = try? JSONValue(data: response.body) else { return [] }
        return json["items"]?.arrayValue ?? []
    }

    // MARK: Settings

    /// The block in its canonical shape (section 2.4): the name and location lists as Excluded devices, the thermostat
    /// mode overrides as Accessory Settings, the client and the tokens moved into the vault once the block is written.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        guard var fields = block.objectValue else { return block }
        // The client to the vault, where it has none of its own.
        let held = context.credentials()?.objectValue ?? [:]
        var client = held
        for key in ["client_id", "client_secret"] where SmartThingsSettings.text(held[key]) == nil {
            if let value = settings.text(key) { client[key] = .string(value) }
        }
        if client != held {
            let context = context, credentials = JSONValue.object(client)
            await context.whenSettingsWritten { try context.saveCredentials(credentials) }
        }
        for key in ["client_id", "client_secret"] where SmartThingsSettings.text(client[key]) != nil { fields.removeValue(forKey: key) }
        // The block's tokens to the secret file, then out of the block.
        let tokenKeys = ["oauth_access_token", "oauth_refresh_token", "oauth_expires_in", "AccessToken"]
        if tokenKeys.contains(where: { fields[$0] != nil }) {
            let plugin = self
            await context.whenSettingsWritten { await plugin.importTokens() }
            for key in tokenKeys { fields.removeValue(forKey: key) }
        }
        return .object(Self.canonical(fields, devices: listed, locationNames: locationNames))
    }

    /// The Homebridge lists as Accessory Settings, by the devices known now; names that match none stay in their list.
    static func canonical(_ input: [String: JSONValue], devices: [SmartThingsDevice], locationNames: [String: String]) -> [String: JSONValue] {
        var fields = input
        guard !devices.isEmpty else { return fields }
        var entries = AccessoryEntries(fields)
        func matching(_ name: String) -> [String] {
            devices.filter { normalizedName($0.label ?? $0.name ?? "") == normalizedName(name) }.map(\.deviceID)
        }
        let shown = (fields["ShowOnlyDevices"]?.arrayValue ?? []).compactMap(\.stringValue)
        if !shown.isEmpty {
            let kept = Set(shown.flatMap(matching))
            for device in devices where !kept.contains(device.deviceID) { entries.exclude(device.deviceID) }
            let left = shown.filter { matching($0).isEmpty }
            if left.isEmpty { fields.removeValue(forKey: "ShowOnlyDevices") } else { fields["ShowOnlyDevices"] = .array(left.map(JSONValue.string)) }
            // With ShowOnlyDevices the ignore list did nothing.
            fields.removeValue(forKey: "IgnoreDevices")
        } else {
            entries.excludeList("IgnoreDevices", in: &fields, resolve: matching)
        }
        entries.excludeList("IgnoreLocations", in: &fields) { name in
            let ids = Set(locationNames.filter { normalizedName($0.value) == normalizedName(name) }.keys)
            return devices.filter { $0.locationID.map(ids.contains) ?? false }.map(\.deviceID)
        }
        if let overrides = fields["thermostatModeOverrides"]?.arrayValue {
            var left: [JSONValue] = []
            for entry in overrides {
                let ids = entry["deviceName"]?.stringValue.map(matching) ?? []
                guard !ids.isEmpty else { left.append(entry); continue }
                for id in ids {
                    if let heat = SmartThingsSettings.text(entry["heatMode"]) { entries.setIfAbsent("heatMode", .string(heat), on: id) }
                    if let cool = SmartThingsSettings.text(entry["coolMode"]) { entries.setIfAbsent("coolMode", .string(cool), on: id) }
                }
            }
            if left.isEmpty { fields.removeValue(forKey: "thermostatModeOverrides") } else { fields["thermostatModeOverrides"] = .array(left) }
        }
        entries.write(into: &fields)
        return fields
    }
}
