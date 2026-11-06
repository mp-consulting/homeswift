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
      },
      "server": {
        "title": "Open-Meteo server",
        "type": "string",
        "placeholder": "https://api.open-meteo.com",
        "description": "A self-hosted Open-Meteo, such as http://192.168.1.5:8080. Leave it empty for open-meteo.com."
      }
    }
  },
  "accessorySchema": {
    "properties": {}
  },
  "i18n": {
    "fr": {
      "Name": "Nom",
      "This block's name, shown in the logs and in the web UI.": "Le nom de ce bloc, affiché dans les journaux et l'interface web.",
      "Open-Meteo server": "Serveur Open-Meteo",
      "A self-hosted Open-Meteo, such as http://192.168.1.5:8080. Leave it empty for open-meteo.com.": "Un Open-Meteo hébergé chez vous, comme http://192.168.1.5:8080. Laissez vide pour open-meteo.com."
    },
    "es": {
      "Name": "Nombre",
      "This block's name, shown in the logs and in the web UI.": "El nombre de este bloque, que se muestra en los registros y en la interfaz web.",
      "Open-Meteo server": "Servidor Open-Meteo",
      "A self-hosted Open-Meteo, such as http://192.168.1.5:8080. Leave it empty for open-meteo.com.": "Un Open-Meteo alojado por ti, como http://192.168.1.5:8080. Déjalo vacío para open-meteo.com."
    },
    "pt": {
      "Name": "Nome",
      "This block's name, shown in the logs and in the web UI.": "O nome deste bloco, mostrado nos registos e na interface web.",
      "Open-Meteo server": "Servidor Open-Meteo",
      "A self-hosted Open-Meteo, such as http://192.168.1.5:8080. Leave it empty for open-meteo.com.": "Um Open-Meteo alojado por si, como http://192.168.1.5:8080. Deixe vazio para open-meteo.com."
    }
  }
}
"""#
}
