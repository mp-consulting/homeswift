// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension PhilipsHuePlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "PhilipsHue",
  "pluginType": "platform",
  "singular": false,
  "headerDisplay": "Philips Hue lights, scenes and effects through a Hue Bridge on your network (its local API v2). The first start pairs: press the bridge's link button when the log asks.",
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "default": "Philips Hue"
      },
      "host": {
        "title": "Bridge Address",
        "type": "string",
        "description": "The Hue Bridge's IP address or host name. Leave blank to find it on the network."
      },
      "transitionMs": {
        "title": "Transition (ms)",
        "type": "integer",
        "minimum": 0,
        "maximum": 10000,
        "default": 100,
        "description": "How long a light takes to reach a new colour or brightness. 0 changes at once, for fast effects; the Hue app uses about 400."
      },
      "pollingInterval": {
        "title": "Polling Interval (s)",
        "type": "integer",
        "minimum": 1,
        "maximum": 300,
        "default": 2,
        "description": "How often the bridge is asked for changes made elsewhere (the Hue app, a dimmer switch)."
      },
      "scenes": {
        "title": "Scenes",
        "type": "boolean",
        "default": true,
        "description": "A switch for each scene of a room or zone, on one accessory per room or zone. On recalls the scene; it shows on while the scene is active."
      },
      "excludeScenes": {
        "title": "Hidden Scenes",
        "type": "array",
        "items": { "type": "string" },
        "description": "Scene names (or \"Room/Scene\") to leave out."
      },
      "dynamicScenes": {
        "title": "Play Scenes Dynamically",
        "type": "boolean",
        "default": false,
        "description": "Recall scenes with their colours slowly moving through the palette, as the Hue app's play button does."
      },
      "effects": {
        "title": "Effects",
        "type": "boolean",
        "default": true,
        "description": "A switch for each effect a light has (candle, fire, sparkle, prism…)."
      },
      "roomLights": {
        "title": "Room Lights",
        "type": "boolean",
        "default": false,
        "description": "A lightbulb on each room's and zone's accessory: on, off and brightness for all its lights at once, as one command, like the Hue app's room controls."
      },
      "flashSwitch": {
        "title": "Flash Switch",
        "type": "boolean",
        "default": false,
        "description": "A switch on each light that makes it flash for a few seconds (Hue's signaling)."
      },
      "gradientPoints": {
        "title": "Gradient Points",
        "type": "boolean",
        "default": false,
        "description": "On gradient lightstrips and lamps, a light for each colour point, so each part of the strip takes its own colour."
      },
      "excludeLights": {
        "title": "Hidden Lights",
        "type": "array",
        "items": { "type": "string" },
        "description": "Light names or ids to leave out of HomeKit."
      }
    }
  },
  "layout": [
    "name",
    "host",
    "transitionMs",
    {
      "type": "fieldset",
      "title": "Scenes and Effects",
      "expandable": true,
      "items": ["scenes", "roomLights", "dynamicScenes", "excludeScenes", "effects", "flashSwitch", "gradientPoints"]
    },
    {
      "type": "fieldset",
      "title": "Advanced Settings",
      "expandable": true,
      "items": ["pollingInterval", "excludeLights"]
    }
  ]
}
"""#
}
