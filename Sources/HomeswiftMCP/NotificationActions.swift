import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers

// Actionable notifications: an Automation's Notify Step carries up to three buttons, each applying a Scene, setting a
// value or opening a page of the web UI. A notification with buttons gets a confirmation page (`/notify/<id>`, behind
// sign-in) listing them, and each button a single-use token valid `NotificationActionRules.lifetime`.
//
// Delivered as ntfy actions (an `http` POST to `/notify/act/<token>`, or a `view` of a page), Telegram inline keyboards
// (a callback the bridge reads with getUpdates while a token waits, from the configured chat only; a link for a page),
// and Web Push `actions` where the browser shows them (Chromium); on iOS and Safari, and on channels without buttons
// (Pushover, a webhook), a tap opens the confirmation page. A button that would act on a lock, a garage door or an alarm
// never acts from a notification: it opens the confirmation page, where a signed-in person confirms it. Built-in
// events keep a single tap that opens the page they are about.

/// One button of a Notify Step.
public struct NotificationButton: Codable, Sendable, Equatable {
    public var label: String
    /// `scene`, `set` or `open`.
    public var type: String
    public var scene: String?
    public var id: String?
    public var service: String?
    public var characteristic: String?
    public var value: JSONValue?
    /// `open`: a page of the web UI (`/scenes`, `/accessories`).
    public var path: String?

    public init(label: String, type: String) {
        self.label = label
        self.type = type
    }
}

/// A button as one notification carries it: its token, and whether it acts from the notification itself.
struct PendingButton: Sendable {
    var button: NotificationButton
    var token: String
    /// It sets a lock, a garage door or an alarm: only the signed-in confirmation page runs it.
    var security: Bool
    var used = false
}

/// A notification with buttons, while its tokens last.
struct PendingNotification: Sendable {
    var id: String
    var title: String
    var message: String
    var automation: String
    var created: Date
    var buttons: [PendingButton]

    /// Its buttons still work: within `NotificationActionRules.lifetime` of its sending.
    func isLive(at now: Date = Date()) -> Bool { now.timeIntervalSince(created) < NotificationActionRules.lifetime }
}

/// A button as a channel draws it: its label, and where it leads.
struct DeliveredButton: Sendable {
    var label: String
    /// Acts at once (an http action, a Telegram callback, a Web Push action), with this token.
    var token: String?
    /// The page it opens instead, relative to the web UI (the confirmation page, or `open`'s page).
    var path: String?
}

enum NotificationActionRules {
    static let maxButtons = 3
    static let lifetime: TimeInterval = 15 * 60

    static func button(_ value: JSONValue, index: Int, label prefix: String) throws -> NotificationButton {
        let label = "\(prefix), button \(index + 1)"
        guard let object = value.objectValue, let type = object["type"]?.stringValue, ["scene", "set", "open"].contains(type) else {
            throw CatalogError("\(label): the type must be scene, set or open")
        }
        let text = object["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, text.count <= 40 else { throw CatalogError("\(label): the label is 1 to 40 characters") }
        var button = NotificationButton(label: text, type: type)
        switch type {
        case "scene":
            button.scene = try SceneRules.string(object, "scene", label, max: 512)
        case "set":
            button.id = try SceneRules.string(object, "id", label)
            button.service = object["service"]?.stringValue?.nonEmpty
            button.characteristic = try SceneRules.string(object, "characteristic", label, max: 64)
            guard SceneRules.isValue(object["value"]) else { throw CatalogError("\(label): the value must be a boolean, a number or a short text") }
            button.value = object["value"]
        default:
            let path = object["path"]?.stringValue ?? "/"
            guard WebPush.localPath(path) == path, path.count <= 200 else { throw CatalogError("\(label): the page is a path of the web UI, such as /scenes") }
            button.path = path
        }
        return button
    }
}

extension HomeswiftCatalog {
    /// The web UI's address for the links of notifications: the Notifications page's, else the one the web UI
    /// started on (`home.uiAddress`); nil when neither is known, and then only Web Push and Telegram callbacks act.
    var notificationAddress: String? {
        if let address = home.notifications.value.address?.nonEmpty { return address.hasSuffix("/") ? String(address.dropLast()) : address }
        return home.uiAddress.withLockedValue { $0 }
    }

    /// The web UI's address, set by the web UI as it starts.
    public func setUIAddress(_ address: String?) {
        home.uiAddress.withLockedValue { $0 = address }
    }

    /// How to find a user's chosen Language (nil for automatic), set by the web UI as it starts.
    public func setUserLanguages(_ lookup: @escaping @Sendable (String) -> String?) {
        home.userLanguages.withLockedValue { $0 = lookup }
    }

    /// The Language a user's account chose; nil for automatic, or without the web UI.
    func userLanguage(_ user: String) -> String? {
        home.userLanguages.withLockedValue { $0 }?(user)
    }

    /// Sends an Automation's message with its buttons: each gets a token, the notification a confirmation page.
    func notifyWithButtons(_ buttons: [NotificationButton], title: String, message: String, automation: Automation) async -> [JSONValue]? {
        guard !buttons.isEmpty else {
            return await notify(.automationMessage, title: .literal(title), message: .literal(message), path: "/automations", subject: "\(automation.id):\(UUID().uuidString)")
        }
        let pending = withLookup { () -> PendingNotification in
            PendingNotification(id: Secrets.randomToken(), title: title, message: message, automation: automation.name, created: Date(),
                                buttons: buttons.map { PendingButton(button: $0, token: Secrets.randomToken(), security: buttonTouchesSecurity($0)) })
        }
        home.notificationActions.withLockedValue { actions in
            actions = actions.filter { $0.value.isLive() }
            actions[pending.id] = pending
        }
        let confirm = "/notify/\(pending.id)"
        let delivered = pending.buttons.map { button -> DeliveredButton in
            if button.button.type == "open" { return DeliveredButton(label: button.button.label, path: button.button.path) }
            // A lock, a door or an alarm: never from the notification.
            if button.security { return DeliveredButton(label: button.button.label, path: confirm) }
            return DeliveredButton(label: button.button.label, token: button.token)
        }
        var note = NotificationMessage(event: .automationMessage, title: .literal(title), message: .literal(message), path: confirm)
        note.buttons = delivered
        let sent = await notify(note, subject: "\(automation.id):\(pending.id)")
        // Nothing went out (the event off, no channel, the limit): its buttons go too.
        if sent?.contains(where: { $0["ok"] == true }) != true { home.notificationActions.withLockedValue { _ = $0.removeValue(forKey: pending.id) } }
        // Telegram's presses are read only while a message it got has a button waiting.
        if sent?.contains(where: { $0["channel"] == "telegram" && $0["ok"] == true }) == true, delivered.contains(where: { $0.token != nil }) { startTelegramPoller() }
        return sent
    }

    /// The Steps' rule (`touchesSecurity(scene:id:service:characteristic:)`): only a signed-in person confirms one that does.
    func buttonTouchesSecurity(_ button: NotificationButton) -> Bool {
        button.type != "open" && touchesSecurity(scene: button.scene, id: button.id, service: button.service, characteristic: button.characteristic)
    }

    // MARK: Acting

    /// What a notification's confirmation page shows: its words and each button, whether it is still there to press.
    public func notificationActionsJSON(_ id: String) throws -> JSONValue {
        guard let pending = home.notificationActions.withLockedValue({ $0[id] }) else { throw CatalogError("This notification's buttons are gone: they last 15 minutes", notFound: true) }
        let expired = !pending.isLive()
        return [
            "title": .string(pending.title), "message": .string(pending.message), "automation": .string(pending.automation),
            "expires": .string(Timestamp.iso8601(pending.created.addingTimeInterval(NotificationActionRules.lifetime))),
            "buttons": .array(pending.buttons.enumerated().map { index, button in
                var object: [String: JSONValue] = ["index": .number(Double(index)), "label": .string(button.button.label), "type": .string(button.button.type),
                                                   "security": .bool(button.security), "state": .string(button.used ? "used" : expired ? "expired" : "ready")]
                if let path = button.button.path { object["path"] = .string(path) }
                return .object(object)
            }),
        ]
    }

    /// A button pressed on the confirmation page by a signed-in person, who confirmed a lock, a door or an alarm there.
    public func pressNotificationButton(_ id: String, index: Int, by user: String, confirmSecurity: Bool) async throws -> JSONValue {
        let claimed = try claim(id: id) { pending in
            guard pending.buttons.indices.contains(index) else { throw CatalogError("No such button", notFound: true) }
            if pending.buttons[index].security, !confirmSecurity { throw CatalogError("This button changes a lock, a door or an alarm: confirm it") }
            return index
        }
        return try await ChangeSource.user(user).run { try await perform(claimed.button, allowSecurity: claimed.security && confirmSecurity) }
    }

    /// A button pressed in a notification (an ntfy http action, a Web Push action): its token is its only credential,
    /// once, within 15 minutes; never a lock, a door or an alarm.
    public func pressNotificationToken(_ token: String) async throws -> JSONValue {
        // One scan finds the notification and the button the token is.
        let wanted = Array(token.utf8)
        let found = home.notificationActions.withLockedValue { actions -> (id: String, index: Int)? in
            for (id, pending) in actions {
                if let index = pending.buttons.firstIndex(where: { Secrets.constantTimeEqual(Array($0.token.utf8), wanted) }) { return (id, index) }
            }
            return nil
        }
        guard let found else { throw CatalogError("This button is gone: a button lasts 15 minutes and works once", notFound: true) }
        let claimed = try claim(id: found.id) { pending in
            let index = found.index
            guard pending.buttons.indices.contains(index) else { throw CatalogError("No such button", notFound: true) }
            guard !pending.buttons[index].security else { throw CatalogError("This button changes a lock, a door or an alarm: open the notification to confirm it") }
            return index
        }
        return try await ChangeSource.automation(claimed.automation).run { try await perform(claimed.button, allowSecurity: false) }
    }

    /// Marks a button used, once, if its notification is still there and fresh.
    private func claim(id: String, _ pick: (PendingNotification) throws -> Int) throws -> (button: NotificationButton, security: Bool, automation: String) {
        try home.notificationActions.withLockedValue { actions in
            guard var pending = actions[id] else { throw CatalogError("This notification's buttons are gone: they last 15 minutes", notFound: true) }
            guard pending.isLive() else { throw CatalogError("This button has expired: buttons last 15 minutes", notFound: true) }
            let index = try pick(pending)
            guard !pending.buttons[index].used else { throw CatalogError("This button was already used") }
            pending.buttons[index].used = true
            actions[id] = pending
            return (pending.buttons[index].button, pending.buttons[index].security, pending.automation)
        }
    }

    private func perform(_ button: NotificationButton, allowSecurity: Bool) async throws -> JSONValue {
        switch button.type {
        case "scene":
            guard let id = button.scene else { throw CatalogError("No scene") }
            // Run as an Automation's Step: the press keeps its own Change Source (the person, or the Automation).
            guard let scene = home.scenes.value.scenes.first(where: { $0.id == id }) else { throw CatalogError("The scene is gone", notFound: true) }
            let answer = try await run(scene, trigger: .automation, allowSecurity: allowSecurity)
            return ["done": .string(button.label), "ok": answer["ok"] ?? true]
        case "set":
            guard let found = find(id: button.id ?? "") else { throw CatalogError("The accessory is gone") }
            _ = try await write(found, service: button.service, characteristic: button.characteristic ?? "", value: button.value ?? .null, allowSecurity: allowSecurity)
            return ["done": .string(button.label), "ok": true]
        default:
            return ["done": .string(button.label), "ok": true, "path": .string(button.path ?? "/")]
        }
    }

    // MARK: Telegram

    /// Reads the bot's button presses while a Telegram button waits (getUpdates, long polling), one poller at a time.
    func startTelegramPoller() {
        let catalog = self
        home.telegramPoller.withLockedValue { poller in
            guard poller == nil else { return }
            poller = Task {
                defer { catalog.home.telegramPoller.withLockedValue { $0 = nil } }
                var offset: Int?
                var failures = 0
                while !Task.isCancelled, catalog.hasLiveTokens {
                    let settings = catalog.home.notifications.value.channels.telegram
                    guard settings.enabled, !settings.botToken.isEmpty else { return }
                    var query = "timeout=25&allowed_updates=%5B%22callback_query%22%5D"
                    if let offset { query += "&offset=\(offset)" }
                    do {
                        let response = try await catalog.telegram("getUpdates", query: query, timeout: .seconds(35))
                        guard response.status == 200, let body = try? JSONValue(data: response.body) else { throw CatalogError("HTTP \(response.status)") }
                        failures = 0
                        for update in body["result"]?.arrayValue ?? [] {
                            if let id = update["update_id"]?.intValue { offset = id + 1 }
                            await catalog.handleTelegramUpdate(update)
                        }
                    } catch {
                        failures += 1
                        if failures == 1 { catalog.logger.warning("Could not read the Telegram bot's button presses: \(catalog.scrubbed("\(error)"))") }
                        try? await Task.sleep(for: Self.telegramBackoff.delay(attempt: failures - 1))
                    }
                }
            }
        }
    }

    /// Between two failed reads of the bot's presses: 2 s, doubling, at most 30 s.
    static let telegramBackoff = Backoff(initial: .seconds(2), maximum: .seconds(30), jitter: .proportional(0.2))

    var hasLiveTokens: Bool {
        home.notificationActions.withLockedValue { actions in
            actions.values.contains { $0.isLive() && $0.buttons.contains { !$0.used && !$0.security } }
        }
    }

    /// A button pressed under a message the bot sent: from the configured chat only. Answers the press and takes the
    /// keyboard off the message.
    func handleTelegramUpdate(_ update: JSONValue) async {
        guard let query = update["callback_query"], let queryID = query["id"]?.stringValue, let data = query["data"]?.stringValue, data.hasPrefix("hs:") else { return }
        let settings = home.notifications.value.channels.telegram
        let chat = query["message"]?["chat"]?["id"].map { $0.intValue.map(String.init) ?? $0.stringValue ?? "" } ?? ""
        let chatName = query["message"]?["chat"]?["username"]?.stringValue.map { "@" + $0 }
        var answer: String
        if chat == settings.chatId || chatName == settings.chatId {
            do {
                answer = "✓ " + (try await pressNotificationToken(String(data.dropFirst(3)))["done"]?.stringValue ?? "")
            } catch {
                answer = (error as? CatalogError)?.message ?? "\(error)"
            }
        } else {
            answer = "Not from this chat"
        }
        _ = try? await telegram("answerCallbackQuery", body: ["callback_query_id": .string(queryID), "text": .string(String(answer.prefix(190)))])
        if let message = query["message"]?["message_id"], let chatID = query["message"]?["chat"]?["id"] {
            _ = try? await telegram("editMessageReplyMarkup", body: ["chat_id": chatID, "message_id": message, "reply_markup": ["inline_keyboard": []]])
        }
    }

    /// A call to the Bot API: `body` POSTed as JSON, else a GET with `query`.
    func telegram(_ method: String, query: String = "", body: JSONValue? = nil, timeout: Duration = .seconds(10)) async throws -> HomeswiftNetwork.HTTPResponse {
        let token = home.notifications.value.channels.telegram.botToken
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)\(query.isEmpty ? "" : "?" + query)") else { throw CatalogError("invalid Telegram request") }
        return try await home.http.send(HomeswiftNetwork.HTTPRequest(method: body == nil ? "GET" : "POST", url: url, headers: body == nil ? [] : [(name: "Content-Type", value: "application/json")],
                                                    body: body?.encoded(), timeout: timeout))
    }

    /// An error's text with every secret of the notification settings masked, as the channels' errors are.
    func scrubbed(_ text: String) -> String {
        var text = text
        for secret in home.notifications.value.secrets { text = text.replacingOccurrences(of: secret, with: NotificationSettings.placeholder) }
        return String(Redaction.redactText(text).prefix(300))
    }
}
