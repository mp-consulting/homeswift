import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Testing
@testable import HomeswiftMCP

/// A Notify Step's buttons: ntfy's actions and Telegram's keyboard, a token that works once, a lock that only the
/// signed-in confirmation page sets, the chat a Telegram press must come from, and buttons that expire.
@Suite(.timeLimit(.minutes(1)))
struct NotificationActionTests {
    func environment(_ channels: JSONValue) async throws -> (MCPTestEnvironment, RecordingSender) {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        let sender = RecordingSender()
        environment.catalog.home.http = sender
        environment.catalog.setUIAddress("http://192.168.1.5:8581")
        _ = try environment.catalog.updateNotificationSettings(["channels": channels])
        return (environment, sender)
    }

    let buttons: JSONValue = [
        ["label": "Turn it off", "type": "set", "id": "Devices:lamp", "characteristic": "On", "value": false],
        ["label": "Lock the door", "type": "set", "id": "Devices:lock", "characteristic": "Lock Target State", "value": 1],
        ["label": "See the scenes", "type": "open", "path": "/scenes"],
    ]

    func run(_ environment: MCPTestEnvironment) async throws {
        _ = try environment.catalog.saveAutomation(["name": "Door left open", "triggers": [["type": "time", "at": "22:00"]],
            "steps": [["type": "notify", "title": "Front door", "message": "The lamp is still on.", "buttons": buttons]]])
        _ = try await environment.catalog.runAutomation("Door left open")
    }

    @Test func ntfyGetsActionsAndATokenWorksOnce() async throws {
        let (environment, sender) = try await environment(["ntfy": ["enabled": true, "server": "https://ntfy.example.com", "topic": "home"]])
        defer { Task { await environment.stop() } }
        try await run(environment)
        let request = try #require(sender.requests.last)
        #expect(request.url.absoluteString == "https://ntfy.example.com")
        let body = try JSONValue(data: request.body ?? Data())
        #expect(body["topic"] == "home")
        let actions = body["actions"]?.arrayValue ?? []
        #expect(actions.map { $0["action"]?.stringValue } == ["http", "view", "view"])
        let act = try #require(actions.first?["url"]?.stringValue)
        #expect(act.hasPrefix("http://192.168.1.5:8581/notify/act/"))
        // The lock's button opens the confirmation page; the tap too.
        let confirm = try #require(body["click"]?.stringValue)
        #expect(confirm.hasPrefix("http://192.168.1.5:8581/notify/"))
        #expect(actions[1]["url"]?.stringValue == confirm)
        #expect(actions[2]["url"] == "http://192.168.1.5:8581/scenes")

        let token = String(act.split(separator: "/").last!)
        _ = try await environment.catalog.pressNotificationToken(token)
        #expect(environment.written.contains { $0.0 == "lamp.on" && $0.1 == .bool(false) })
        await #expect(throws: CatalogError.self) { try await environment.catalog.pressNotificationToken(token) }
        await #expect(throws: CatalogError.self) { try await environment.catalog.pressNotificationToken("not-a-token") }
    }

    @Test func aLockIsSetOnlyOnTheConfirmationPage() async throws {
        let (environment, _) = try await environment(["ntfy": ["enabled": true, "server": "https://ntfy.example.com", "topic": "home"]])
        defer { Task { await environment.stop() } }
        try await run(environment)
        let (id, lockToken) = try #require(environment.catalog.home.notificationActions.withLockedValue { $0.first.map { ($0.key, $0.value.buttons[1].token) } })
        // Its token never acts, even if it leaked.
        await #expect(throws: CatalogError.self) { try await environment.catalog.pressNotificationToken(lockToken) }
        let page = try environment.catalog.notificationActionsJSON(id)
        #expect(page["buttons"]?[1]?["security"] == true)
        #expect(page["buttons"]?[1]?["state"] == "ready")
        await #expect(throws: CatalogError.self) { try await environment.catalog.pressNotificationButton(id, index: 1, by: "ann", confirmSecurity: false) }
        _ = try await environment.catalog.pressNotificationButton(id, index: 1, by: "ann", confirmSecurity: true)
        #expect(environment.written.contains { $0.0 == "lock.target" && $0.1 == .int(1) })
        #expect(try environment.catalog.notificationActionsJSON(id)["buttons"]?[1]?["state"] == "used")
    }

    @Test func telegramGetsAKeyboardAndOnlyItsChatPresses() async throws {
        let (environment, sender) = try await environment(["telegram": ["enabled": true, "botToken": "123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ012345", "chatId": "42"]])
        defer { Task { await environment.stop() } }
        try await run(environment)
        let sent = try #require(sender.requests.first { $0.url.path.hasSuffix("/sendMessage") })
        let rows = try JSONValue(data: sent.body ?? Data())["reply_markup"]?["inline_keyboard"]?.arrayValue ?? []
        #expect(rows.count == 3)
        let data = try #require(rows[0][0]?["callback_data"]?.stringValue)
        #expect(data.hasPrefix("hs:"))
        #expect(rows[1][0]?["url"]?.stringValue?.contains("/notify/") == true)
        let press = { (chat: Int) -> JSONValue in ["update_id": 1, "callback_query": ["id": "q1", "data": .string(data), "message": ["message_id": 7, "chat": ["id": .number(Double(chat))]]]] }
        await environment.catalog.handleTelegramUpdate(press(99))
        #expect(!environment.written.contains { $0.0 == "lamp.on" })
        await environment.catalog.handleTelegramUpdate(press(42))
        #expect(environment.written.contains { $0.0 == "lamp.on" && $0.1 == .bool(false) })
        #expect(sender.requests.contains { $0.url.path.hasSuffix("/answerCallbackQuery") })
        environment.catalog.stopAutomations()
    }

    @Test func buttonsExpireAfterAQuarterOfAnHour() async throws {
        let (environment, _) = try await environment(["ntfy": ["enabled": true, "server": "https://ntfy.example.com", "topic": "home"]])
        defer { Task { await environment.stop() } }
        try await run(environment)
        let (id, token) = try #require(environment.catalog.home.notificationActions.withLockedValue { $0.first.map { ($0.key, $0.value.buttons[0].token) } })
        environment.catalog.home.notificationActions.withLockedValue { $0[id]?.created = Date().addingTimeInterval(-16 * 60) }
        await #expect(throws: CatalogError.self) { try await environment.catalog.pressNotificationToken(token) }
        #expect(try environment.catalog.notificationActionsJSON(id)["buttons"]?[0]?["state"] == "expired")
    }

    @Test func refusesBadButtons() throws {
        let environment = try MCPTestEnvironment()
        let step = { (buttons: JSONValue) -> JSONValue in ["name": "Bad", "triggers": [["type": "time", "at": "07:00"]], "steps": [["type": "notify", "message": "Hi", "buttons": buttons]]] }
        #expect(throws: CatalogError.self) { try environment.catalog.saveAutomation(step([["label": "", "type": "open", "path": "/"]])) }
        #expect(throws: CatalogError.self) { try environment.catalog.saveAutomation(step([["label": "Away", "type": "open", "path": "https://example.com"]])) }
        #expect(throws: CatalogError.self) { try environment.catalog.saveAutomation(step([["label": "x", "type": "call"]])) }
        let four: JSONValue = .array((0..<4).map { _ in ["label": "Open", "type": "open", "path": "/"] })
        #expect(throws: CatalogError.self) { try environment.catalog.saveAutomation(step(four)) }
    }
}
