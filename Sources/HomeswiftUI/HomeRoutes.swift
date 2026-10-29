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
//   GET    /api/scenes                        scenes, the plugins' hubs' scenes, location, next sunrise and sunset
//   POST   /api/scenes                        a new scene
//   POST   /api/scenes/targets            {"ids"}: the hubs that could keep a scene of these lights
//   POST   /api/scenes/hub                {"hub", "name", "actions"}: a new scene kept on that hub
//   PUT    /api/scenes/<id>/hub           {"name"?, "fromCurrent"?}: a hub's scene renamed, or its lights kept as they are
//   PUT    /api/scenes/location               where sunrise and sunset are computed for
//   PUT    /api/scenes/<id>                   a scene changed
//   DELETE /api/scenes/<id>                   a hub's scene too, from its hub
//   POST   /api/scenes/<id>/run               {"confirmSecurity": true} once the person agreed to its locks and doors; a
//                                             plugin scene's id (`<platform>:<instance>:<hub id>`) recalls it
//   GET    /api/scenes/<id>/picture?v=<version> the picture a person gave a scene (Homeswift's or a hub's), as an image
//   PUT    /api/scenes/<id>/picture           {"data": a JPEG, PNG or WebP data: URL}; answers its version
//   DELETE /api/scenes/<id>/picture
//   GET    /api/scenes/templates              the templates, the plans tried that can be stopped, whether the Assistant writes
//   POST   /api/scenes/try                    {"template" | "description" | "plan", "room" | "ids"}: runs it now, unsaved
//   GET    /api/notifications                 settings, secrets as ********
//   PUT    /api/notifications
//   POST   /api/notifications/test            {"channel"?}
//   GET    /api/notifications/push            the VAPID public key and the subscribed browsers
//   POST   /api/notifications/push/subscribe  this browser's PushSubscription.toJSON() and a label
//   POST   /api/notifications/push/unsubscribe {"endpoint"}
//   POST   /api/notifications/push/test       {"endpoint"?}
//   DELETE /api/notifications/push/subscriptions/<id>
extension UIServer {
    func homeAPI(_ route: [String], _ method: HTTPMethod, body: JSONValue, username: String, language: String? = nil) async throws -> Reply? {
        guard let first = route.first, ["rooms", "scenes", "notifications"].contains(first) else { return nil }
        do {
            return try await homeRoute(route, method, body: body, username: username, language: language)
        } catch let error as CatalogError {
            return .error(error.description.hasPrefix("No scene") || error.description.hasPrefix("No hub scene") ? 404 : 400, error.description)
        } catch let error as JSONGenerationError {
            return .error(502, "the Assistant did not answer with a scene: \(error.message)")
        }
    }

    private func homeRoute(_ route: [String], _ method: HTTPMethod, body: JSONValue, username: String, language: String?) async throws -> Reply? {
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
                return .json(try await catalog.suggestRooms(language: language))
            } catch let error as CatalogError {
                throw error
            } catch {
                return .error(502, "the Assistant did not answer: \(error)")
            }

        case (.GET, ["scenes"]):
            return .json(await catalog.allScenesJSON())
        case (.GET, ["scenes", "templates"]):
            return .json(catalog.sceneTemplatesJSON())
        case (.POST, ["scenes", "try"]):
            guard body["description"] == nil || catalog.host.assistant != nil else { return .error(404, "the Assistant is off: add a HomeswiftAiKit block, or pick a template") }
            let result = try await catalog.tryScene(body, language: language)
            logger.info("Web UI tried a scene", metadata: ["user": "\(username)", "scene": "\(result["name"]?.stringValue ?? "")"])
            return .json(result)
        case (.POST, ["scenes"]):
            let scene = try catalog.createScene(body)
            logger.info("Web UI created a scene", metadata: ["user": "\(username)", "scene": "\(scene["name"]?.stringValue ?? "")"])
            return .json(scene, status: 201)
        case (.POST, ["scenes", "targets"]):
            let ids = body["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return .json(["targets": .array(await catalog.hubTargets(accessoryIDs: ids))])
        case (.POST, ["scenes", "hub"]):
            guard let hub = body["hub"]?.stringValue, let name = body["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                return .error(400, "a hub and a name are required")
            }
            let result = try await catalog.saveHubScene(["actions": body["actions"] ?? []], name: name, hub: hub, dryRun: false)
            logger.info("Web UI saved a scene to a hub", metadata: ["user": "\(username)", "scene": "\(name)", "hub": "\(hub)"])
            return .json(result, status: 201)
        case (.PUT, let path) where path.count == 3 && path[0] == "scenes" && path[2] == "hub":
            let result = try await catalog.updateHubScene(path[1], name: body["name"]?.stringValue, plan: nil, fromCurrent: body["fromCurrent"]?.boolValue == true, dryRun: false)
            logger.info("Web UI changed a hub's scene", metadata: ["user": "\(username)", "scene": "\(path[1])"])
            return .json(result)
        case (.PUT, ["scenes", "location"]):
            return .json(try catalog.setSceneLocation(body))
        case (.PUT, let path) where path.count == 2 && path[0] == "scenes":
            let scene = try catalog.updateScene(id: path[1], body)
            logger.info("Web UI changed a scene", metadata: ["user": "\(username)", "scene": "\(scene["name"]?.stringValue ?? "")"])
            return .json(scene)
        case (.DELETE, let path) where path.count == 2 && path[0] == "scenes":
            guard catalog.savedScene(path[1]) != nil else {
                // A hub's scene: the page asked the person first.
                let removed = try await catalog.deleteHubScene(path[1])
                logger.notice("Web UI removed a scene from its hub", metadata: ["user": "\(username)", "scene": "\(removed["name"]?.stringValue ?? "")"])
                return .json(removed)
            }
            try catalog.deleteScene(id: path[1])
            logger.info("Web UI deleted a scene", metadata: ["user": "\(username)", "scene": "\(path[1])"])
            return .json(JSONValue.object([:]))
        case (.POST, let path) where path.count == 3 && path[0] == "scenes" && path[2] == "run":
            // A scene with a lock, a door or an alarm runs them only once the person confirmed on the page, as
            // a card's own control asks before it changes one.
            let confirmed = body["confirmSecurity"]?.boolValue == true
            guard let scene = catalog.savedScene(path[1]) else {
                // A scene of a plugin's hub: no lock, door or alarm in it.
                let result = try await catalog.runScene(path[1], trigger: .manual)
                logger.info("Web UI recalled a scene", metadata: ["user": "\(username)", "scene": "\(result["name"]?.stringValue ?? "")"])
                return .json(result)
            }
            if scene.security, !confirmed {
                return .error(409, "This scene changes a lock, a door or an alarm: confirm to run it")
            }
            let result = try await catalog.runScene(path[1], trigger: .manual, allowSecurity: confirmed)
            logger.info("Web UI ran a scene", metadata: ["user": "\(username)", "scene": "\(scene.name)", "ok": "\(result["ok"]?.boolValue ?? false)"])
            return .json(result)

        case (.GET, let path) where path.count == 3 && path[0] == "scenes" && path[2] == "picture":
            guard let picture = catalog.scenePicture(path[1]) else { return .error(404, "no picture for that scene") }
            // The page asks for it by version (`?v=`), so a browser keeps it until it changes.
            return .data(status: 200, contentType: picture.type, body: picture.data, headers: ["Cache-Control": "private, max-age=31536000, immutable"])
        case (.PUT, let path) where path.count == 3 && path[0] == "scenes" && path[2] == "picture":
            guard let data = body["data"]?.stringValue else { return .error(400, "a picture is required") }
            let result = try await catalog.setScenePicture(path[1], dataURL: data)
            logger.info("Web UI gave a scene a picture", metadata: ["user": "\(username)", "scene": "\(path[1])"])
            return .json(result)
        case (.DELETE, let path) where path.count == 3 && path[0] == "scenes" && path[2] == "picture":
            try await catalog.removeScenePicture(path[1])
            logger.info("Web UI removed a scene's picture", metadata: ["user": "\(username)", "scene": "\(path[1])"])
            return .json(JSONValue.object([:]))
        case (.POST, let path) where path.count == 3 && path[0] == "scenes" && path[2] == "stop":
            let result = try await catalog.stopScene(path[1], allowSecurity: body["confirmSecurity"]?.boolValue == true)
            logger.info("Web UI stopped a scene", metadata: ["user": "\(username)", "scene": "\(path[1])"])
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
