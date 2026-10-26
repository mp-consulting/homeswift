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
              "type": "string", "x-schema-form": { "type": "password" },
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
        "title": "Transition",
        "type": "integer",
        "default": 100,
        "description": "How long a light takes to reach a new level or colour: the plugin page's speed scale. Extreme changes at once.",
        "oneOf": [
          { "title": "Very slow · 2000 ms", "enum": [2000] },
          { "title": "Very slow · 1500 ms", "enum": [1500] },
          { "title": "Slow · 1000 ms", "enum": [1000] },
          { "title": "Slow · 800 ms", "enum": [800] },
          { "title": "Medium · 600 ms", "enum": [600] },
          { "title": "Medium · 400 ms", "enum": [400] },
          { "title": "Medium · 300 ms", "enum": [300] },
          { "title": "Fast · 200 ms", "enum": [200] },
          { "title": "Fast · 100 ms", "enum": [100] },
          { "title": "Very fast · 60 ms", "enum": [60] },
          { "title": "Very fast · 30 ms", "enum": [30] },
          { "title": "Extreme · at once", "enum": [0] }
        ]
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
