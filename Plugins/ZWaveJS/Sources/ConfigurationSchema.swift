// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension ZWaveJSPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "ZWaveJS",
  "pluginType": "platform",
  "singular": false,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "default": "Z-Wave JS",
        "description": "The instance's name in the logs"
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "host": {
        "title": "IP address or host name",
        "type": "string",
        "description": "Where zwave-js-server answers, for example 192.168.1.20.",
        "x-kinds": ["server"]
      },
      "port": {
        "title": "Port",
        "type": "integer",
        "minimum": 1,
        "maximum": 65535,
        "placeholder": 3000,
        "description": "zwave-js-server's WebSocket port, 3000 by default.",
        "x-kinds": ["server"]
      },
      "showAs": {
        "title": "Show as",
        "type": "string",
        "description": "What a Binary Switch is in the Home app. By default, an outlet when it measures energy, else a switch.",
        "oneOf": [
          { "title": "Switch", "enum": ["switch"] },
          { "title": "Outlet", "enum": ["outlet"] },
          { "title": "Light", "enum": ["lightbulb"] }
        ],
        "x-kinds": ["switch"]
      }
    }
  },
  "i18n": {
    "fr": {
      "IP address or host name": "Adresse IP ou nom d'hôte",
      "Light": "Lumière",
      "Name": "Nom",
      "Outlet": "Prise",
      "Port": "Port",
      "Show as": "Afficher comme",
      "Switch": "Interrupteur",
      "The instance's name in the logs": "Le nom de l'instance dans les journaux",
      "What a Binary Switch is in the Home app. By default, an outlet when it measures energy, else a switch.": "Ce qu'est un Binary Switch dans l'app Maison. Par défaut, une prise quand il mesure l'énergie, sinon un interrupteur.",
      "Where zwave-js-server answers, for example 192.168.1.20.": "Où zwave-js-server répond, par exemple 192.168.1.20.",
      "zwave-js-server's WebSocket port, 3000 by default.": "Le port WebSocket de zwave-js-server, 3000 par défaut."
    },
    "es": {
      "IP address or host name": "Dirección IP o nombre de host",
      "Light": "Luz",
      "Name": "Nombre",
      "Outlet": "Enchufe",
      "Port": "Puerto",
      "Show as": "Mostrar como",
      "Switch": "Interruptor",
      "The instance's name in the logs": "El nombre de la instancia en los registros",
      "What a Binary Switch is in the Home app. By default, an outlet when it measures energy, else a switch.": "Lo que es un Binary Switch en la app Casa. Por defecto, un enchufe cuando mide la energía, si no un interruptor.",
      "Where zwave-js-server answers, for example 192.168.1.20.": "Donde responde zwave-js-server, por ejemplo 192.168.1.20.",
      "zwave-js-server's WebSocket port, 3000 by default.": "El puerto WebSocket de zwave-js-server, 3000 por defecto."
    },
    "pt": {
      "IP address or host name": "Endereço IP ou nome do host",
      "Light": "Luz",
      "Name": "Nome",
      "Outlet": "Tomada",
      "Port": "Porta",
      "Show as": "Mostrar como",
      "Switch": "Interruptor",
      "The instance's name in the logs": "O nome da instância nos registos",
      "What a Binary Switch is in the Home app. By default, an outlet when it measures energy, else a switch.": "O que um Binary Switch é na app Casa. Por omissão, uma tomada quando mede a energia, senão um interruptor.",
      "Where zwave-js-server answers, for example 192.168.1.20.": "Onde o zwave-js-server responde, por exemplo 192.168.1.20.",
      "zwave-js-server's WebSocket port, 3000 by default.": "A porta WebSocket do zwave-js-server, 3000 por omissão."
    }
  }
}
"""#
}
