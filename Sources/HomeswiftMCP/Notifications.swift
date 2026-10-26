import Crypto
import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

// Notifications, ported from Glass UI (notifications.service.ts, notification-channels.ts, web-push.service.ts):
// the channels (a webhook, ntfy, Pushover, Telegram, Web Push to the browsers that subscribed), which events
// go out, and a dispatcher with Glass UI's limits: an event about the same thing at most once per 15 minutes,
// 12 notifications an hour, 5 tests a minute. Kept in notifications.json next to config.json, owner-only;
// the API gives the secrets back as ******** and never shows the Web Push keys. The file is not config.json, so
// neither get_config nor the Assistant ever reads it.

public enum NotificationEvent: String, CaseIterable, Sendable, Codable {
    /// Glass UI's homebridgeUp: homeswift started (not after a restart it did itself).
    case bridgeStarted
    /// homebridgeDown: homeswift stops (not for a restart).
    case bridgeStopped
    /// childBridgeCrashLoop: a plugin logged an error (a plugin that did not start says so at error level).
    case pluginError
    /// An accessory has answered No Response for 5 minutes while its plugin is not paused.
    case accessoryOffline
    /// An automation ran a scene and some of its actions failed.
    case sceneFailed
    /// The daily instance backup (the web UI's Settings › Backups) failed.
    case backupFailed
    /// The daily instance backup was saved; every day, so it waits to be turned on.
    case backupSucceeded
    /// dailyDigest: the Assistant's digest of the day, at `dailyDigestTime`.
    case dailyDigest
    case test

    /// What the settings page calls it.
    var label: String {
        switch self {
        case .bridgeStarted: "Homeswift started"
        case .bridgeStopped: "Homeswift stopped"
        case .pluginError: "A plugin reported an error"
        case .accessoryOffline: "An accessory stopped responding"
        case .sceneFailed: "An automation failed"
        case .backupFailed: "The scheduled backup failed"
        case .backupSucceeded: "The scheduled backup was saved"
        case .dailyDigest: "Daily digest from the Assistant"
        case .test: "Test"
        }
    }

    static let configurable: [NotificationEvent] = allCases.filter { $0 != .test }
    /// On unless turned off; the digest uses the Assistant's quota and a successful backup comes every day, so
    /// they wait to be turned on.
    var onByDefault: Bool { self != .dailyDigest && self != .backupSucceeded }
}

public enum NotificationChannel: String, CaseIterable, Sendable {
    case webhook, ntfy, pushover, telegram, browser
}

public struct NotificationSettings: Codable, Sendable, Equatable {
    public struct Webhook: Codable, Sendable, Equatable {
        public var enabled = false
        public var url = ""
        public var auth = "none"
        public var username = ""
        public var password = ""
        public var token = ""
        public var headers: [String: String] = [:]
        public init() {}
        enum CodingKeys: String, CodingKey { case enabled, url, auth, username, password, token, headers }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
            auth = try c.decodeIfPresent(String.self, forKey: .auth) ?? "none"
            username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
            password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
            token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
            headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        }
        var authorization: String? {
            switch auth {
            case "bearer": "Bearer \(token)"
            case "basic": "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
            default: nil
            }
        }
    }
    public struct Ntfy: Codable, Sendable, Equatable { public var enabled = false; public var server = "https://ntfy.sh"; public var topic = ""; public var token = "" }
    public struct Pushover: Codable, Sendable, Equatable { public var enabled = false; public var userKey = ""; public var appToken = "" }
    public struct Telegram: Codable, Sendable, Equatable { public var enabled = false; public var botToken = ""; public var chatId = "" }
    public struct Browser: Codable, Sendable, Equatable { public var enabled = false }
    public struct Channels: Codable, Sendable, Equatable {
        public var webhook = Webhook(), ntfy = Ntfy(), pushover = Pushover(), telegram = Telegram(), browser = Browser()
    }

    public var channels = Channels()
    /// Events turned on or off; missing ones take their default.
    public var events: [String: Bool] = [:]
    /// When the daily digest goes, HH:mm local time.
    public var dailyDigestTime = "08:00"
    /// Generated the first time a browser asks; never shown.
    public var webPushKeys: WebPush.Keys?
    public var subscriptions: [WebPush.Subscription] = []

    public init() {}

    public func isOn(_ event: NotificationEvent) -> Bool { events[event.rawValue] ?? event.onByDefault }

    func isEnabled(_ channel: NotificationChannel) -> Bool {
        switch channel {
        case .webhook: channels.webhook.enabled
        case .ntfy: channels.ntfy.enabled
        case .pushover: channels.pushover.enabled
        case .telegram: channels.telegram.enabled
        case .browser: channels.browser.enabled
        }
    }

    func isConfigured(_ channel: NotificationChannel) -> Bool {
        switch channel {
        case .webhook: !channels.webhook.url.isEmpty
        case .ntfy: !channels.ntfy.server.isEmpty && !channels.ntfy.topic.isEmpty
        case .pushover: !channels.pushover.userKey.isEmpty && !channels.pushover.appToken.isEmpty
        case .telegram: !channels.telegram.botToken.isEmpty && !channels.telegram.chatId.isEmpty
        case .browser: true
        }
    }

    /// Every secret the settings hold, to scrub from error texts (a failed request's URL can carry one).
    var secrets: [String] {
        let webhook = channels.webhook
        let authorization: String = webhook.authorization ?? ""
        let credentials: String = authorization.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        var values: [String] = [webhook.url, webhook.username, webhook.password, webhook.token, authorization, credentials]
        values += [channels.ntfy.token, channels.pushover.userKey, channels.pushover.appToken, channels.telegram.botToken]
        values += Array(webhook.headers.values)
        // Shorter values would scrub ordinary characters out of the error text ("HTTP 401" with a header "1").
        return values.filter { $0.count >= 4 }
    }

    /// The fields never sent back in clear, by channel.
    static let secretFields: [NotificationChannel: Set<String>] = [.webhook: ["url", "username", "password", "token"], .ntfy: ["token"], .pushover: ["userKey", "appToken"], .telegram: ["botToken"]]
    public static let placeholder = "********"
}

public struct NotificationMessage: Sendable {
    public var event: NotificationEvent
    public var title: String
    public var message: String
    /// Higher priority for outages (ntfy, Pushover, Web Push).
    public var urgent = false
    /// The web UI page it is about, for channels that can open it.
    public var path: String?
}

enum NotificationRules {
    static let cooldown: TimeInterval = 15 * 60
    static let maxPerHour = 12
    static let maxTestsPerMinute = 5
    static let offlineGrace: TimeInterval = 5 * 60
    static let pushBodyMax = 1000
    /// The VAPID `sub` push services may write to; HOMESWIFT_WEB_PUSH_SUBJECT (mailto: or https:) replaces it.
    static var subject: String {
        let value = ProcessInfo.processInfo.environment["HOMESWIFT_WEB_PUSH_SUBJECT"] ?? ""
        return value.hasPrefix("mailto:") || value.hasPrefix("https://") ? value : "mailto:homeswift@users.noreply.github.com"
    }

    /// Text cut to `max` characters (or UTF-8 bytes), ending with an ellipsis when it was cut.
    static func truncate(_ text: String, _ max: Int, bytes: Bool = false) -> String {
        let size = { (value: String) in bytes ? value.utf8.count : value.count }
        guard size(text) > max else { return text }
        var out = ""
        for character in text {
            if size(out) + size(String(character)) > max - size("…") { break }
            out.append(character)
        }
        return out.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func isHTTPURL(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return false }
        return !text.contains(where: \.isWhitespace)
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) == text.startIndex..<text.endIndex
    }
}

extension HomeswiftCatalog {
    // MARK: Settings

    /// The settings as a page may see them: each stored secret as ********, the events with their labels, the
    /// browsers that subscribed (without their keys).
    public func notificationSettingsJSON() -> JSONValue {
        let settings = home.notifications.value
        guard var channels = (try? JSONValue(encoding: settings.channels))?.objectValue else { return .null }
        for (channel, fields) in NotificationSettings.secretFields {
            guard var object = channels[channel.rawValue]?.objectValue else { continue }
            for field in fields { object[field] = .string((object[field]?.stringValue ?? "").isEmpty ? "" : NotificationSettings.placeholder) }
            if channel == .webhook {
                object["headers"] = .object(settings.channels.webhook.headers.mapValues { .string($0.isEmpty ? "" : NotificationSettings.placeholder) })
            }
            channels[channel.rawValue] = .object(object)
        }
        return [
            "channels": .object(channels),
            "events": .array(NotificationEvent.configurable.map { ["name": .string($0.rawValue), "label": .string($0.label), "enabled": .bool(settings.isOn($0))] }),
            "dailyDigestTime": .string(settings.dailyDigestTime),
            "subscriptions": .array(settings.subscriptions.map(Self.subscriptionJSON)),
            "assistant": .bool(host.assistant != nil),
        ]
    }

    static func subscriptionJSON(_ subscription: WebPush.Subscription) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(subscription.id), "label": .string(subscription.label), "createdAt": .string(subscription.createdAt),
                                           "service": .string(URL(string: subscription.endpoint)?.host ?? "")]
        if let username = subscription.username { object["username"] = .string(username) }
        return .object(object)
    }

    /// Replaces the settings given: `channels` (a secret sent back as ******** keeps the stored one, an empty
    /// string clears it), `events` (an object of booleans, or the list `notificationSettingsJSON` gives),
    /// `dailyDigestTime`. A channel turned on must be complete.
    public func updateNotificationSettings(_ body: JSONValue) throws -> JSONValue {
        try home.notifications.update { settings in
            var channels = (try JSONValue(encoding: settings.channels)).objectValue ?? [:]
            for channel in NotificationChannel.allCases {
                guard let given = body["channels"]?[channel.rawValue]?.objectValue, var target = channels[channel.rawValue]?.objectValue else { continue }
                for (field, value) in given where target[field] != nil {
                    if channel == .webhook, field == "headers" {
                        guard let headers = value.objectValue else { throw CatalogError("Webhook headers must be an object") }
                        var replacement: [String: JSONValue] = [:]
                        for (name, raw) in headers {
                            guard let text = raw.stringValue else { throw CatalogError("Webhook header values must be text") }
                            if text == NotificationSettings.placeholder {
                                guard let saved = settings.channels.webhook.headers.first(where: { $0.key.lowercased() == name.lowercased() })?.value else {
                                    throw CatalogError("Enter a value for the new webhook header")
                                }
                                replacement[name] = .string(saved)
                            } else { replacement[name] = .string(text) }
                        }
                        target[field] = .object(replacement)
                        continue
                    }
                    if let flag = value.boolValue { target[field] = .bool(flag); continue }
                    guard let text = value.stringValue else { continue }
                    if NotificationSettings.secretFields[channel]?.contains(field) == true, text == NotificationSettings.placeholder { continue }
                    target[field] = .string(channel == .webhook && ["username", "password", "token"].contains(field) ? text : text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                channels[channel.rawValue] = .object(target)
            }
            let next = try JSONValue.object(channels).decode(NotificationSettings.Channels.self)
            try Self.validate(next)
            settings.channels = next
            if let events = body["events"]?.objectValue {
                for (name, value) in events where NotificationEvent(rawValue: name) != nil && name != "test" { if let flag = value.boolValue { settings.events[name] = flag } }
            } else if let events = body["events"]?.arrayValue {
                for event in events { if let name = event["name"]?.stringValue, NotificationEvent(rawValue: name) != nil, let flag = event["enabled"]?.boolValue { settings.events[name] = flag } }
            }
            if let time = body["dailyDigestTime"]?.stringValue {
                guard SceneRules.isTime(time) else { throw CatalogError("The digest time must be HH:mm") }
                settings.dailyDigestTime = time
            }
            for channel in NotificationChannel.allCases where settings.isEnabled(channel) && !settings.isConfigured(channel) {
                throw CatalogError("The \(channel.rawValue) channel is on but not fully set up")
            }
        }
        return notificationSettingsJSON()
    }

    static func validate(_ channels: NotificationSettings.Channels) throws {
        let fail = { (message: String) in CatalogError(message) }
        if !channels.webhook.url.isEmpty, !NotificationRules.isHTTPURL(channels.webhook.url) { throw fail("The webhook URL must be an http(s) URL") }
        let hook = channels.webhook
        guard ["none", "basic", "bearer"].contains(hook.auth) else { throw fail("Invalid webhook authentication") }
        if hook.auth == "basic", hook.username.contains(":") { throw fail("The Basic auth username cannot contain a colon") }
        if hook.enabled && ((hook.auth == "bearer" && hook.token.isEmpty) || (hook.auth == "basic" && (hook.username.isEmpty || hook.password.isEmpty))) {
            throw fail("Complete the webhook authentication fields")
        }
        if hook.auth == "bearer", !hook.token.isEmpty, !NotificationRules.matches(hook.token, #"[A-Za-z0-9._~+/=-]+"#) { throw fail("Invalid webhook bearer token") }
        guard hook.headers.count <= 32 else { throw fail("Use at most 32 webhook headers") }
        var names = Set<String>()
        let reserved: Set<String> = ["host", "content-length", "content-type", "connection", "transfer-encoding", "trailer", "te", "upgrade", "expect", "proxy-authorization"]
        for (name, value) in hook.headers {
            guard NotificationRules.matches(name, #"[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}"#), names.insert(name.lowercased()).inserted,
                  !reserved.contains(name.lowercased()), !(hook.auth != "none" && name.lowercased() == "authorization") else {
                throw fail("Invalid, duplicate or reserved webhook header name")
            }
            guard value.utf8.count <= 4096, value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) else {
                throw fail("Webhook header values must be single-line ASCII text, up to 4096 bytes")
            }
        }
        if !channels.ntfy.server.isEmpty, !NotificationRules.isHTTPURL(channels.ntfy.server) { throw fail("The ntfy server must be an http(s) URL") }
        if !channels.ntfy.topic.isEmpty, !NotificationRules.matches(channels.ntfy.topic, #"[\w-]{1,64}"#) { throw fail("The ntfy topic may only use letters, numbers, - and _ (up to 64)") }
        if !channels.ntfy.token.isEmpty, !NotificationRules.matches(channels.ntfy.token, #"[\w.-]{1,256}"#) { throw fail("Invalid ntfy access token") }
        if !channels.pushover.userKey.isEmpty, !NotificationRules.matches(channels.pushover.userKey, #"\w{1,64}"#) { throw fail("Invalid Pushover user key") }
        if !channels.pushover.appToken.isEmpty, !NotificationRules.matches(channels.pushover.appToken, #"\w{1,64}"#) { throw fail("Invalid Pushover application token") }
        if !channels.telegram.botToken.isEmpty, !NotificationRules.matches(channels.telegram.botToken, #"\d{1,20}:[\w-]{20,100}"#) { throw fail("Invalid Telegram bot token") }
        if !channels.telegram.chatId.isEmpty, !NotificationRules.matches(channels.telegram.chatId, #"-?\d{1,20}|@\w{4,64}"#) { throw fail("Invalid Telegram chat id") }
    }

    // MARK: Web Push

    /// The VAPID public key browsers subscribe with, made (and kept) the first time it is asked for.
    public func webPushPublicKey() throws -> String {
        if let keys = home.notifications.value.webPushKeys, keys.isValid { return keys.publicKey }
        return try home.notifications.update { settings in
            if let keys = settings.webPushKeys, keys.isValid { return keys.publicKey }
            let keys = WebPush.Keys.generate()
            settings.webPushKeys = keys
            // New keys make every subscription made with the old ones useless.
            settings.subscriptions = []
            logger.info("Made the VAPID keys for browser notifications")
            return keys.publicKey
        }
    }

    /// Adds (or refreshes) a browser's subscription, `PushSubscription.toJSON()` with a `label`.
    public func subscribeToPush(_ body: JSONValue, username: String?) throws -> JSONValue {
        guard let endpoint = body["endpoint"]?.stringValue, endpoint.count <= 2048, let url = URL(string: endpoint), url.scheme == "https", url.host?.isEmpty == false, url.user == nil else {
            throw CatalogError("The push endpoint must be an https URL")
        }
        // The bridge posts to the endpoint: only the browsers' push services, so a user cannot point it at a LAN address.
        guard let host = url.host?.lowercased(), url.port == nil || url.port == 443, WebPush.isPushService(host) else {
            throw CatalogError("The push endpoint is not a known browser push service")
        }
        guard let p256dh = body["keys"]?["p256dh"]?.stringValue, let auth = body["keys"]?["auth"]?.stringValue,
              WebPush.data(base64url: p256dh)?.count == 65, WebPush.data(base64url: auth)?.count == 16 else { throw CatalogError("Invalid push subscription keys") }
        let label = String((body["label"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty ?? url.host ?? "browser").prefix(100))
        _ = try webPushPublicKey()
        let id = String(SHA256Hex.of(endpoint).prefix(16))
        let subscription = WebPush.Subscription(id: id, endpoint: endpoint, p256dh: p256dh, auth: auth, label: label, username: username, createdAt: SceneRules.now())
        try home.notifications.update { settings in
            settings.subscriptions.removeAll { $0.endpoint == endpoint }
            guard settings.subscriptions.count < 20 else { throw CatalogError("At most 20 devices can receive browser notifications") }
            guard settings.subscriptions.count(where: { $0.username == username }) < 5 else {
                throw CatalogError("At most 5 devices per user can receive browser notifications")
            }
            settings.subscriptions.append(subscription)
        }
        return Self.subscriptionJSON(subscription)
    }

    /// Removes a subscription by its endpoint (this browser) or its id (any).
    public func unsubscribeFromPush(endpoint: String? = nil, id: String? = nil) throws -> Bool {
        try home.notifications.update { settings in
            let before = settings.subscriptions.count
            settings.subscriptions.removeAll { (endpoint != nil && $0.endpoint == endpoint) || (id != nil && $0.id == id) }
            return settings.subscriptions.count != before
        }
    }

    /// Sends to every subscribed browser (or the one with this endpoint); how many it reached. Forgets the ones
    /// the push service no longer knows.
    func sendPush(_ message: NotificationMessage, endpoint: String? = nil) async throws -> Int {
        let settings = home.notifications.value
        let targets = settings.subscriptions.filter { endpoint == nil || $0.endpoint == endpoint }
        guard let keys = settings.webPushKeys, keys.isValid, !targets.isEmpty else { throw CatalogError(endpoint != nil ? "This browser is not subscribed" : "No browser is subscribed") }
        let payload: JSONValue = [
            "title": .string("\(instanceName): \(message.title)"), "body": .string(NotificationRules.truncate(message.message, NotificationRules.pushBodyMax)),
            "tag": .string(message.event.rawValue), "path": .string(WebPush.localPath(message.path)), "urgent": .bool(message.urgent),
        ]
        let http = home.http
        var gone: [String] = [], errors: [String] = []
        var sent = 0
        for target in targets {
            do {
                try await WebPush.send(payload.encoded(), to: target, keys: keys, subject: NotificationRules.subject, urgent: message.urgent, http: http)
                sent += 1
            } catch is WebPush.Gone {
                gone.append(target.endpoint)
            } catch {
                errors.append("\(target.label): \(error)")
            }
        }
        if !gone.isEmpty {
            logger.info("Removed \(gone.count) browser notification subscription(s) the push service no longer knows")
            try? home.notifications.update { $0.subscriptions.removeAll { gone.contains($0.endpoint) } }
        }
        guard sent > 0 else { throw CatalogError(errors.isEmpty ? "Every subscribed browser has unsubscribed" : errors.joined(separator: "; ")) }
        return sent
    }

    // MARK: Sending

    var instanceName: String { host.mainBridge.name }

    /// Sends one message on one channel; throws what went wrong, its secrets scrubbed by the caller.
    func send(_ message: NotificationMessage, on channel: NotificationChannel, settings: NotificationSettings) async throws {
        let title = "\(instanceName): \(message.title)"
        let http = home.http
        func post(_ url: String, headers: [(String, String)], body: Data) async throws {
            guard let target = URL(string: url) else { throw CatalogError("invalid URL") }
            let response = try await http.send(HTTPRequest(method: "POST", url: target, headers: headers.map { (name: $0.0, value: $0.1) }, body: body))
            // The body may echo the request, a token with it: the status only.
            guard (200..<300).contains(response.status) else { throw CatalogError("HTTP \(response.status)") }
        }
        switch channel {
        case .webhook:
            let body: JSONValue = ["event": .string(message.event.rawValue), "title": .string(title), "message": .string(message.message),
                                   "instance": .string(instanceName), "timestamp": .string(SceneRules.now())]
            let hook = settings.channels.webhook
            var headers = [("Content-Type", "application/json")] + hook.headers.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            if let authorization = hook.authorization { headers.append(("Authorization", authorization)) }
            try await post(hook.url, headers: headers, body: body.encoded())
        case .ntfy:
            let ntfy = settings.channels.ntfy
            // Header values must be Latin-1: anything else in the title becomes ?.
            var headers = [("Title", String(title.map { $0.isASCII && !$0.isNewline ? $0 : "?" })), ("Priority", message.urgent ? "high" : "default"), ("Tags", "homeswift")]
            if !ntfy.token.isEmpty { headers.append(("Authorization", "Bearer \(ntfy.token)")) }
            let server = ntfy.server.hasSuffix("/") ? String(ntfy.server.dropLast()) : ntfy.server
            try await post("\(server)/\(ntfy.topic)", headers: headers, body: Data(NotificationRules.truncate(message.message, 4096, bytes: true).utf8))
        case .pushover:
            let fields = [
                ("token", settings.channels.pushover.appToken), ("user", settings.channels.pushover.userKey), ("title", NotificationRules.truncate(title, 250)),
                ("message", NotificationRules.truncate(message.message, 1024)), ("priority", message.urgent ? "1" : "0"),
            ]
            let form = URLEncoding.form(fields)
            try await post("https://api.pushover.net/1/messages.json", headers: [("Content-Type", "application/x-www-form-urlencoded")], body: Data(form.utf8))
        case .telegram:
            let body: JSONValue = ["chat_id": .string(settings.channels.telegram.chatId), "text": .string(NotificationRules.truncate("\(title)\n\(message.message)", 4096)),
                                   "disable_web_page_preview": true]
            try await post("https://api.telegram.org/bot\(settings.channels.telegram.botToken)/sendMessage", headers: [("Content-Type", "application/json")], body: body.encoded())
        case .browser:
            _ = try await sendPush(message)
        }
    }

    /// Sends to the channels given, or every one that is on and set up; the result per channel.
    func sendAll(_ message: NotificationMessage, only: [NotificationChannel]? = nil) async -> [JSONValue] {
        let settings = home.notifications.value
        let targets = NotificationChannel.allCases.filter { (only?.contains($0) ?? settings.isEnabled($0)) && settings.isConfigured($0) }
        var results: [JSONValue] = []
        await withTaskGroup(of: JSONValue.self) { group in
            for channel in targets {
                group.addTask {
                    do {
                        try await self.send(message, on: channel, settings: settings)
                        return ["channel": .string(channel.rawValue), "ok": true]
                    } catch {
                        var text = "\(error)"
                        for secret in settings.secrets { text = text.replacingOccurrences(of: secret, with: NotificationSettings.placeholder) }
                        text = String(Redaction.redactText(text).prefix(300))
                        self.logger.warning("Could not send the \(message.event.rawValue) notification to \(channel.rawValue): \(text)")
                        return ["channel": .string(channel.rawValue), "ok": false, "error": .string(text)]
                    }
                }
            }
            for await result in group { results.append(result) }
        }
        return results.sorted { ($0["channel"]?.stringValue ?? "") < ($1["channel"]?.stringValue ?? "") }
    }

    /// Sends an event to every channel that is on, when the event is on and the limits allow: the same event
    /// about the same thing at most once per 15 minutes, 12 notifications an hour. nil when nothing went out.
    @discardableResult
    public func notify(_ event: NotificationEvent, title: String, message: String, urgent: Bool = false, path: String? = nil, subject: String = "", now: Date = Date()) async -> [JSONValue]? {
        let settings = home.notifications.value
        guard settings.isOn(event), NotificationChannel.allCases.contains(where: { settings.isEnabled($0) && settings.isConfigured($0) }) else { return nil }
        let key = "\(event.rawValue):\(subject)"
        let allowed = home.dispatch.withLockedValue { state -> Bool in
            if let last = state.lastSent[key], now.timeIntervalSince(last) < NotificationRules.cooldown { return false }
            state.sent = state.sent.filter { now.timeIntervalSince($0) < 3600 }
            guard state.sent.count < NotificationRules.maxPerHour else { return false }
            state.lastSent[key] = now
            state.sent.append(now)
            return true
        }
        guard allowed else {
            logger.debug("Notification \(key) held back by its limits")
            return nil
        }
        return await sendAll(NotificationMessage(event: event, title: title, message: message, urgent: urgent, path: path))
    }

    /// "Send test": to one channel, or every one that is on, whatever the events. 5 a minute.
    public func sendTestNotification(channel: NotificationChannel? = nil, endpoint: String? = nil, now: Date = Date()) async throws -> JSONValue {
        let allowed = home.dispatch.withLockedValue { state -> Bool in
            state.tests = state.tests.filter { now.timeIntervalSince($0) < 60 }
            guard state.tests.count < NotificationRules.maxTestsPerMinute else { return false }
            state.tests.append(now)
            return true
        }
        guard allowed else { throw CatalogError("Too many test notifications: try again in a minute") }
        let message = NotificationMessage(event: .test, title: "Test notification", message: "Notifications from Homeswift are working.", path: "/notifications")
        if channel == .browser, let endpoint {
            do {
                _ = try await sendPush(message, endpoint: endpoint)
                return ["results": [["channel": "browser", "ok": true]]]
            } catch {
                return ["results": [["channel": "browser", "ok": false, "error": .string("\(error)")]]]
            }
        }
        let settings = home.notifications.value
        let only = channel.map { [$0] } ?? NotificationChannel.allCases.filter(settings.isEnabled)
        guard only.contains(where: settings.isConfigured) else { throw CatalogError("No channel is set up to send to") }
        return ["results": .array(await sendAll(message, only: only))]
    }

    // MARK: Sources

    /// The checks a minute: accessories that stopped answering, the digest's time.
    func checkNotificationSources(now: Date, calendar: Calendar = .current) async {
        let settings = home.notifications.value
        // Accessories answering No Response, their plugin not paused, for 5 minutes.
        let unavailable = located().filter { $0.accessory.isUnavailable && $0.platform?.paused != true }
        let due = home.dispatch.withLockedValue { state -> [Located] in
            let ids = Set(unavailable.map(\.accessory.id))
            state.offline = state.offline.filter { ids.contains($0.key) }
            var due: [Located] = []
            for located in unavailable {
                let id = located.accessory.id
                let entry = state.offline[id] ?? (now, false)
                if !entry.notified, now.timeIntervalSince(entry.since) >= NotificationRules.offlineGrace {
                    state.offline[id] = (entry.since, true)
                    due.append(located)
                } else {
                    state.offline[id] = entry
                }
            }
            return due
        }
        for located in due {
            await notify(.accessoryOffline, title: "\(located.layout?.name ?? located.accessory.name) is not responding",
                         message: "\(located.accessory.name)\(located.platform.map { " (\($0.name))" } ?? "") has answered No Response for 5 minutes.",
                         path: "/accessories", subject: located.accessory.id, now: now)
        }
        // The daily digest, once a day at its time.
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let day = DailyDigestInput.today(now, timeZone: calendar.timeZone)
        if settings.isOn(.dailyDigest), time == settings.dailyDigestTime, home.dispatch.withLockedValue({ $0.digestDay }) != day, let assistant = host.assistant {
            home.dispatch.withLockedValue { $0.digestDay = day }
            // get_daily_digest's input, whose lines go through `safe` (a confirmation code is a warning line).
            var input = digestInput(now: now)
            input.date = day
            do {
                let digest = try await assistant.dailyDigest(input).text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !digest.isEmpty { await notify(.dailyDigest, title: "Daily digest", message: digest, subject: day, now: now) }
            } catch {
                logger.warning("Could not make the daily digest notification: \(error)")
            }
        }
    }

    /// A log line at error level from a plugin: one notification per plugin per 15 minutes.
    func logLineForNotifications(_ line: LogBuffer.Line) {
        guard line.level >= .error, !line.label.hasPrefix("homeswift.notifications") else { return }
        let catalog = self
        Task {
            await catalog.notify(.pluginError, title: "\(line.label): error", message: Self.safe(line.text), path: "/logs?level=error", subject: line.label, now: line.date)
        }
    }

    // MARK: Starting and stopping

    /// Starts the automations (a check every minute, characteristic triggers) and the notification sources
    /// (error lines, accessories offline, the digest), and says the bridge started unless `restarted` (a restart
    /// homeswift made itself). `stopHome` ends them.
    public func startHome(restarted: Bool = false) {
        guard home.running.withLockedValue({ $0 == nil }) else { return }
        seedWatchedValues()
        let catalog = self
        let ticker = Task {
            while !Task.isCancelled {
                let now = Date()
                let next = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60
                try? await Task.sleep(for: .seconds(next - now.timeIntervalSinceReferenceDate + 0.2))
                guard !Task.isCancelled else { break }
                await catalog.tick(Date())
            }
        }
        let changes = host.observeChanges { accessory, characteristic, value in catalog.characteristicChanged(accessory, characteristic, value) }
        let lines = logs.observe { line in catalog.logLineForNotifications(line) }
        home.running.withLockedValue { $0 = RunningHome(ticker: ticker, observations: [changes, lines]) }
        if !restarted {
            Task { await catalog.notify(.bridgeStarted, title: "Homeswift started", message: "Homeswift \(PluginHost.version) is running with \(catalog.located().count) accessories.", path: "/status") }
        }
    }

    /// The work of one minute, once per minute even when the wake-up is late.
    func tick(_ now: Date) async {
        let minute = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        let fresh = home.dispatch.withLockedValue { state -> Bool in
            guard state.lastTick != minute else { return false }
            state.lastTick = minute
            return true
        }
        guard fresh else { return }
        await runDueScenes(at: minute)
        await home.naturalLighting.tick(self, at: now)
        await checkNotificationSources(now: now)
    }

    /// Stops what `startHome` started; says the bridge stopped unless `restarting`, waiting for the channels
    /// (each request gives up after 10 seconds).
    public func stopHome(restarting: Bool = false) async {
        guard let running = home.running.withLockedValue({ state -> RunningHome? in defer { state = nil }; return state }) else { return }
        running.ticker.cancel()
        running.observations.forEach { $0.cancel() }
        guard !restarting else { return }
        await notify(.bridgeStopped, title: "Homeswift stopped", message: "Homeswift is shutting down; its accessories show No Response until it is back.", urgent: true)
    }

    // MARK: Tools

    var notificationTools: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "send_test_notification", title: "Send test notification",
                description: "Sends a test message through Homeswift's notification channels (webhook, ntfy, Pushover, Telegram, browser) to check they work. "
                    + "Without channel it goes to every enabled channel. Returns the result per channel. At most 5 a minute. The channels are set up on the web UI's Notifications page.",
                inputSchema: ["type": "object", "properties": ["channel": ["type": "string", "enum": .array(NotificationChannel.allCases.map { .string($0.rawValue) }), "description": "Only this channel"]]],
                outputSchema: Output.object(["results": ["type": "array"]], required: ["results"]),
                scope: .admin
            ) { call in
                .json(try await catalog.sendTestNotification(channel: call.optionalString("channel").flatMap(NotificationChannel.init(rawValue:))))
            },
        ]
    }
}

/// The hex SHA-256 of a text: a subscription's id from its endpoint.
enum SHA256Hex {
    static func of(_ text: String) -> String {
        Crypto.SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
