import Foundation
import HomeswiftAI
import HomeswiftMCP
import NIOHTTP1

// The API of the Accessories page's rooms, the Quick Controls, the Scenes page and the Notifications page:
// each route calls the catalog method the MCP tools use too.
//
//   GET    /api/rooms                        rooms with their accessories
//   PUT    /api/rooms                        rooms, hidden, display names, Quick Controls (HomeswiftCatalog.updateLayout)
//   POST   /api/rooms/suggest                the Assistant's rooms and names, to review
//   GET    /api/scenes                        scenes, location, next sunrise and sunset
//   POST   /api/scenes                        a new scene
//   PUT    /api/scenes/location               where sunrise and sunset are computed for
//   PUT    /api/scenes/<id>                   a scene changed
//   DELETE /api/scenes/<id>
//   POST   /api/scenes/<id>/run               {"confirmSecurity": true} once the person agreed to its locks and doors
//   GET    /api/notifications                 settings, secrets as ********
//   PUT    /api/notifications
//   POST   /api/notifications/test            {"channel"?}
//   GET    /api/notifications/push            the VAPID public key and the subscribed browsers
//   POST   /api/notifications/push/subscribe  this browser's PushSubscription.toJSON() and a label
//   POST   /api/notifications/push/unsubscribe {"endpoint"}
//   POST   /api/notifications/push/test       {"endpoint"?}
//   DELETE /api/notifications/push/subscriptions/<id>
extension UIServer {
    func homeAPI(_ route: [String], _ method: HTTPMethod, body: JSONValue, username: String) async throws -> Reply? {
        guard let first = route.first, ["rooms", "scenes", "notifications"].contains(first) else { return nil }
        do {
            return try await homeRoute(route, method, body: body, username: username)
        } catch let error as CatalogError {
            return .error(error.description.hasPrefix("No scene") ? 404 : 400, error.description)
        }
    }

    private func homeRoute(_ route: [String], _ method: HTTPMethod, body: JSONValue, username: String) async throws -> Reply? {
        switch (method, route) {
        case (.GET, ["rooms"]):
            return .json(catalog.layoutJSON())
        case (.PUT, ["rooms"]):
            let result = try catalog.updateLayout(body)
            logger.info("Web UI changed the accessory layout", metadata: ["user": "\(username)"])
            return .json(result)
        case (.POST, ["rooms", "suggest"]):
            guard catalog.host.assistant != nil else { return .error(404, "the Assistant is off: add a HomeswiftAiKit block") }
            do {
                return .json(try await catalog.suggestRooms())
            } catch let error as CatalogError {
                throw error
            } catch {
                return .error(502, "the Assistant did not answer: \(error)")
            }

        case (.GET, ["scenes"]):
            return .json(catalog.scenesJSON())
        case (.POST, ["scenes"]):
            let scene = try catalog.createScene(body)
            logger.info("Web UI created a scene", metadata: ["user": "\(username)", "scene": "\(scene["name"]?.stringValue ?? "")"])
            return .json(scene, status: 201)
        case (.PUT, ["scenes", "location"]):
            return .json(try catalog.setSceneLocation(body))
        case (.PUT, let path) where path.count == 2 && path[0] == "scenes":
            let scene = try catalog.updateScene(id: path[1], body)
            logger.info("Web UI changed a scene", metadata: ["user": "\(username)", "scene": "\(scene["name"]?.stringValue ?? "")"])
            return .json(scene)
        case (.DELETE, let path) where path.count == 2 && path[0] == "scenes":
            try catalog.deleteScene(id: path[1])
            logger.info("Web UI deleted a scene", metadata: ["user": "\(username)", "scene": "\(path[1])"])
            return .json(JSONValue.object([:]))
        case (.POST, let path) where path.count == 3 && path[0] == "scenes" && path[2] == "run":
            // A scene with a lock, a door or an alarm runs them only once the person confirmed on the page, as
            // a card's own control asks before it changes one.
            let confirmed = body["confirmSecurity"]?.boolValue == true
            let scene = catalog.scenesJSON()["scenes"]?.arrayValue?.first { $0["id"]?.stringValue == path[1] }
            guard let scene else { return .error(404, "No scene \(path[1])") }
            if scene["security"]?.boolValue == true, !confirmed {
                return .error(409, "This scene changes a lock, a door or an alarm: confirm to run it")
            }
            let result = try await catalog.runScene(path[1], trigger: .manual, allowSecurity: confirmed)
            logger.info("Web UI ran a scene", metadata: ["user": "\(username)", "scene": "\(scene["name"]?.stringValue ?? "")", "ok": "\(result["ok"]?.boolValue ?? false)"])
            return .json(result)

        case (.GET, ["notifications"]):
            return .json(catalog.notificationSettingsJSON())
        case (.PUT, ["notifications"]):
            let result = try catalog.updateNotificationSettings(body)
            logger.info("Web UI changed the notification settings", metadata: ["user": "\(username)"])
            return .json(result)
        case (.POST, ["notifications", "test"]):
            let channel = body["channel"]?.stringValue.flatMap(NotificationChannel.init(rawValue:))
            return .json(try await catalog.sendTestNotification(channel: channel))
        case (.GET, ["notifications", "push"]):
            return .json(["publicKey": .string(try catalog.webPushPublicKey()), "subscriptions": catalog.notificationSettingsJSON()["subscriptions"] ?? []])
        case (.POST, ["notifications", "push", "subscribe"]):
            let subscription = try catalog.subscribeToPush(body, username: username)
            logger.info("Web UI: a browser subscribed to notifications", metadata: ["user": "\(username)", "label": "\(subscription["label"]?.stringValue ?? "")"])
            return .json(subscription)
        case (.POST, ["notifications", "push", "unsubscribe"]):
            guard let endpoint = body["endpoint"]?.stringValue else { return .error(400, "the endpoint is required") }
            return .json(["removed": .bool(try catalog.unsubscribeFromPush(endpoint: endpoint))])
        case (.POST, ["notifications", "push", "test"]):
            return .json(try await catalog.sendTestNotification(channel: .browser, endpoint: body["endpoint"]?.stringValue))
        case (.DELETE, let path) where path.count == 4 && path[0] == "notifications" && path[1] == "push" && path[2] == "subscriptions":
            guard try catalog.unsubscribeFromPush(id: path[3]) else { return .error(404, "unknown subscription") }
            return .json(["removed": true])
        default:
            return nil
        }
    }
}
