import Foundation
import HomeswiftAI
import HomeswiftMCP
import NIOHTTP1

// Settings, for administrators, as the MCP tools `get_settings` and `update_settings` read and write them (Settings.swift
// in HomeswiftMCP); secrets show as the placeholder, which a write that keeps it keeps.
//
//   GET    /api/settings/accessories/<accessoryId>           its Accessory Settings and their fields (`?instance=` a block's
//                                                            name, for an accessory not on the bridge whose platform has several)
//   PATCH  /api/settings/accessories/<accessoryId>           {settings…}: merged, null clears a key (`?instance=` too)
//   PATCH  /api/settings/accessories                         {"<accessoryId>": {settings…}, …}: several in one write (`?instance=` too)
//   DELETE /api/settings/accessories/<accessoryId>           Forget: its Authorization and Accessory Settings dropped (`?instance=` too)
//   GET    /api/settings/plugins/<platform>/<name>            its Plugin Settings, its schema and accessorySchema
//   PATCH  /api/settings/plugins/<platform>/<name>            {settings…}: merged, null clears a key
extension UIServer {
    func settingsRoute(_ route: [String], _ method: HTTPMethod, body: JSONValue, query: [String: String] = [:], username: String) async throws -> Reply? {
        let instance = query["instance"].flatMap { $0.isEmpty ? nil : $0 }
        do {
            switch (method, route.first, route.count) {
            case (.GET, "accessories", 2):
                return .json(Redaction.redactSecrets(try await catalog.accessorySettingsJSON(accessoryID: route[1], instance: instance)))
            case (.PATCH, "accessories", 2):
                guard let settings = body.objectValue else { return .error(400, "the settings must be a JSON object") }
                let result = try await catalog.updateAccessorySettings([(route[1], settings)], instance: instance, by: .person, who: "web UI \(username)")
                logger.info("Web UI changed an accessory's settings", metadata: ["user": "\(username)", "accessory": "\(route[1])"])
                noteConfigChange(by: username)
                return .json(Redaction.redactSecrets(result))
            case (.DELETE, "accessories", 2):
                let result = try await catalog.forgetDevice(accessoryID: route[1], instance: instance, by: .person)
                logger.info("Web UI forgot a device", metadata: ["user": "\(username)", "accessory": "\(route[1])"])
                noteConfigChange(by: username)
                return .json(result)
            case (.PATCH, "accessories", 1):
                guard let byID = body.objectValue, !byID.isEmpty else { return .error(400, "send the settings by accessory id") }
                let changes = try byID.sorted { $0.key < $1.key }.map { id, value -> (accessoryID: String, settings: [String: JSONValue]) in
                    guard let settings = value.objectValue else { throw CatalogError("the settings of \(id) must be an object") }
                    return (id, settings)
                }
                let result = try await catalog.updateAccessorySettings(changes, instance: instance, by: .person, who: "web UI \(username)")
                logger.info("Web UI changed accessories' settings", metadata: ["user": "\(username)", "accessories": "\(changes.count)"])
                noteConfigChange(by: username)
                return .json(Redaction.redactSecrets(result))
            case (.GET, "plugins", 3):
                return .json(Redaction.redactSecrets(try catalog.pluginSettingsJSON(platform: route[1], instance: route[2])))
            case (.PATCH, "plugins", 3):
                guard let settings = body.objectValue else { return .error(400, "the settings must be a JSON object") }
                let result = try await catalog.updatePluginSettings(platform: route[1], instance: route[2], settings: settings, by: .person)
                noteConfigChange(by: username)
                return .json(result)
            default:
                return nil
            }
        } catch let error as CatalogError {
            return .error(error.notFound ? 404 : 400, error.description)
        }
    }
}
