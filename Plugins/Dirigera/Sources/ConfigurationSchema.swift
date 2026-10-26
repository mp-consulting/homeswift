// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension DirigeraPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "Dirigera",
  "pluginType": "platform",
  "singular": true,
  "headerDisplay": "IKEA lights, outlets and scenes through a DIRIGERA hub on your network. Pair on the plugin's page: it asks for the action button under the hub.",
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "default": "IKEA DIRIGERA"
      },
      "hubs": {
        "type": "array",
        "title": "DIRIGERA Hubs",
        "items": {
          "title": "Hub",
          "type": "object",
          "properties": {
            "host": {
              "title": "Host / IP",
              "type": "string",
              "required": true,
              "format": "hostname"
            },
            "token": {
              "title": "Authentication Token",
              "type": "string",
              "required": false,
              "description": "Optional: a token from homebridge-dirigera. Pairing on the plugin's page keeps its own in the plugin's folder."
            },
            "name": {
              "title": "Name",
              "type": "string",
              "required": false,
              "minLength": 1
            }
          }
        }
      },
      "transitionMs": {
        "title": "Transition (ms)",
        "type": "integer",
        "minimum": 0,
        "maximum": 10000,
        "default": 100,
        "description": "How long a light takes to reach a new level or colour. 0 changes at once."
      },
      "scenes": {
        "title": "Scenes",
        "type": "boolean",
        "default": true,
        "description": "A switch for each scene of the hub. On triggers it; Off within 30 seconds undoes it."
      },
      "excludeDevices": {
        "title": "Hidden Devices",
        "type": "array",
        "items": { "type": "string" },
        "description": "Device names or ids to leave out of HomeKit."
      },
      "excludeScenes": {
        "title": "Hidden Scenes",
        "type": "array",
        "items": { "type": "string" },
        "description": "Scene names or ids to leave out."
      }
    }
  },
  "layout": [
    "name",
    { "key": "hubs", "type": "array", "items": ["hubs[].host", "hubs[].name", "hubs[].token"] },
    "transitionMs",
    {
      "type": "fieldset",
      "title": "In the Home app",
      "expandable": true,
      "items": ["scenes", "excludeDevices", "excludeScenes"]
    }
  ]
}
"""#
}
