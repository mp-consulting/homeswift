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
        "description": "What a switch is in the Home app. By default, a Binary Switch is an outlet when it measures energy, else a switch; a Multilevel Switch is a light, or a fan for a fan controller. A Multilevel Switch shows as a light or a fan.",
        "oneOf": [
          { "title": "Switch", "enum": ["switch"] },
          { "title": "Outlet", "enum": ["outlet"] },
          { "title": "Light", "enum": ["lightbulb"] },
          { "title": "Fan", "enum": ["fan"] }
        ],
        "x-kinds": ["switch", "light", "fan"]
      }
    }
  },
  "i18n": {
    "fr": {
      "Fan": "Ventilateur",
      "IP address or host name": "Adresse IP ou nom d'hôte",
      "Light": "Lumière",
      "Name": "Nom",
      "Outlet": "Prise",
      "Port": "Port",
      "Show as": "Afficher comme",
      "Switch": "Interrupteur",
      "The instance's name in the logs": "Le nom de l'instance dans les journaux",
      "What a switch is in the Home app. By default, a Binary Switch is an outlet when it measures energy, else a switch; a Multilevel Switch is a light, or a fan for a fan controller. A Multilevel Switch shows as a light or a fan.": "Ce qu'est un interrupteur dans l'app Maison. Par défaut, un Binary Switch est une prise quand il mesure l'énergie, sinon un interrupteur ; un Multilevel Switch est une lumière, ou un ventilateur pour un variateur de ventilateur. Un Multilevel Switch s'affiche comme une lumière ou un ventilateur.",
      "Where zwave-js-server answers, for example 192.168.1.20.": "Où zwave-js-server répond, par exemple 192.168.1.20.",
      "zwave-js-server's WebSocket port, 3000 by default.": "Le port WebSocket de zwave-js-server, 3000 par défaut."
    },
    "es": {
      "Fan": "Ventilador",
      "IP address or host name": "Dirección IP o nombre de host",
      "Light": "Luz",
      "Name": "Nombre",
      "Outlet": "Enchufe",
      "Port": "Puerto",
      "Show as": "Mostrar como",
      "Switch": "Interruptor",
      "The instance's name in the logs": "El nombre de la instancia en los registros",
      "What a switch is in the Home app. By default, a Binary Switch is an outlet when it measures energy, else a switch; a Multilevel Switch is a light, or a fan for a fan controller. A Multilevel Switch shows as a light or a fan.": "Lo que es un interruptor en la app Casa. Por defecto, un Binary Switch es un enchufe cuando mide la energía, si no un interruptor; un Multilevel Switch es una luz, o un ventilador para un regulador de ventilador. Un Multilevel Switch se muestra como una luz o un ventilador.",
      "Where zwave-js-server answers, for example 192.168.1.20.": "Donde responde zwave-js-server, por ejemplo 192.168.1.20.",
      "zwave-js-server's WebSocket port, 3000 by default.": "El puerto WebSocket de zwave-js-server, 3000 por defecto."
    },
    "pt": {
      "Fan": "Ventoinha",
      "IP address or host name": "Endereço IP ou nome do host",
      "Light": "Luz",
      "Name": "Nome",
      "Outlet": "Tomada",
      "Port": "Porta",
      "Show as": "Mostrar como",
      "Switch": "Interruptor",
      "The instance's name in the logs": "O nome da instância nos registos",
      "What a switch is in the Home app. By default, a Binary Switch is an outlet when it measures energy, else a switch; a Multilevel Switch is a light, or a fan for a fan controller. A Multilevel Switch shows as a light or a fan.": "O que um interruptor é na app Casa. Por omissão, um Binary Switch é uma tomada quando mede a energia, senão um interruptor; um Multilevel Switch é uma luz, ou uma ventoinha para um regulador de ventoinha. Um Multilevel Switch mostra-se como uma luz ou uma ventoinha.",
      "Where zwave-js-server answers, for example 192.168.1.20.": "Onde o zwave-js-server responde, por exemplo 192.168.1.20.",
      "zwave-js-server's WebSocket port, 3000 by default.": "A porta WebSocket do zwave-js-server, 3000 por omissão."
    }
  }
}
"""#
}
