// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension WeatherPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "Weather",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "required": true,
        "default": "Weather",
        "description": "This block's name, shown in the logs and in the web UI."
      }
    }
  },
  "accessorySchema": {
    "properties": {}
  },
  "i18n": {
    "fr": {
      "Name": "Nom",
      "This block's name, shown in the logs and in the web UI.": "Le nom de ce bloc, affiché dans les journaux et l'interface web."
    },
    "es": {
      "Name": "Nombre",
      "This block's name, shown in the logs and in the web UI.": "El nombre de este bloque, que se muestra en los registros y en la interfaz web."
    },
    "pt": {
      "Name": "Nome",
      "This block's name, shown in the logs and in the web UI.": "O nome deste bloco, mostrado nos registos e na interface web."
    }
  }
}
"""#
}
