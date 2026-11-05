// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension APsystemsECUPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "APsystemsECU",
  "pluginType": "platform",
  "singular": true,
  "customUi": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "default": "APsystems",
        "description": "The instance's name in the logs"
      },
      "ecus": {
        "title": "ECUs",
        "type": "array",
        "description": "The ECUs to read, by address. The ECU has no network announcement: find its address in your router (it often shows as an Espressif device) and give it a fixed one.",
        "items": {
          "title": "ECU",
          "type": "object",
          "properties": {
            "host": {
              "title": "IP address or host name",
              "type": "string",
              "required": true,
              "description": "Where the ECU answers, for example 192.168.1.60."
            },
            "port": {
              "title": "Port",
              "type": "integer",
              "minimum": 1,
              "maximum": 65535,
              "placeholder": 8899,
              "description": "The ECU's local protocol port, 8899 by default."
            },
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The ECU's name until it has one in its accessory settings. Empty, it is named after its model and ECU id."
            }
          }
        }
      },
      "pollInterval": {
        "title": "Poll interval (seconds)",
        "type": "integer",
        "placeholder": 300,
        "minimum": 60,
        "maximum": 3600,
        "description": "Seconds between two readings of each ECU, 60 to 3600 (300 by default). While no inverter is online, the ECU is read every 15 minutes."
      },
      "connectRetries": {
        "title": "Connection attempts",
        "type": "integer",
        "placeholder": 2,
        "minimum": 1,
        "maximum": 10,
        "description": "How many times each request tries to connect before the reading fails, 1 to 10 (2 by default)."
      },
      "inverters": {
        "title": "Inverters as accessories",
        "type": "boolean",
        "default": true,
        "description": "An accessory for each inverter, with its power and temperature. Off, only the ECU's production is shown."
      },
      "meter": {
        "title": "ECU-C meter",
        "type": "boolean",
        "default": true,
        "description": "Reads an ECU-C's current clamps from its local web page, for the grid and home power on the Status page. Some ECU-C firmware no longer answers it: the production is read all the same."
      }
    }
  },
  "accessorySchema": {
    "properties": {}
  },
  "layout": [
    "name",
    "inverters",
    "meter",
    {
      "type": "fieldset",
      "title": "Advanced",
      "expandable": true,
      "expanded": false,
      "items": [
        "pollInterval",
        "connectRetries",
        "ecus"
      ]
    }
  ],
  "i18n": {
    "fr": {
      "Advanced": "Avancé",
      "An accessory for each inverter, with its power and temperature. Off, only the ECU's production is shown.": "Un accessoire pour chaque micro-onduleur, avec sa puissance et sa température. Désactivé, seule la production de l'ECU est affichée.",
      "Connection attempts": "Tentatives de connexion",
      "ECU": "ECU",
      "ECU-C meter": "Compteur de l'ECU-C",
      "ECUs": "ECU",
      "How many times each request tries to connect before the reading fails, 1 to 10 (2 by default).": "Combien de fois chaque requête tente de se connecter avant que la lecture échoue, de 1 à 10 (2 par défaut).",
      "IP address or host name": "Adresse IP ou nom d'hôte",
      "Inverters as accessories": "Micro-onduleurs en accessoires",
      "Name": "Nom",
      "Poll interval (seconds)": "Intervalle d'interrogation (secondes)",
      "Port": "Port",
      "Reads an ECU-C's current clamps from its local web page, for the grid and home power on the Status page. Some ECU-C firmware no longer answers it: the production is read all the same.": "Lit les pinces de courant d'un ECU-C sur sa page web locale, pour la puissance du réseau et de la maison sur la page État. Certains firmwares de l'ECU-C n'y répondent plus : la production est lue quand même.",
      "Seconds between two readings of each ECU, 60 to 3600 (300 by default). While no inverter is online, the ECU is read every 15 minutes.": "Secondes entre deux lectures de chaque ECU, de 60 à 3600 (300 par défaut). Tant qu'aucun micro-onduleur n'est en ligne, l'ECU est lu toutes les 15 minutes.",
      "The ECU's local protocol port, 8899 by default.": "Le port du protocole local de l'ECU, 8899 par défaut.",
      "The ECU's name until it has one in its accessory settings. Empty, it is named after its model and ECU id.": "Le nom de l'ECU tant qu'il n'en a pas dans les réglages de son accessoire. Vide, il porte le nom de son modèle et de son identifiant ECU.",
      "The ECUs to read, by address. The ECU has no network announcement: find its address in your router (it often shows as an Espressif device) and give it a fixed one.": "Les ECU à lire, par adresse. L'ECU ne s'annonce pas sur le réseau : trouvez son adresse dans votre routeur (il apparaît souvent comme un appareil Espressif) et donnez-lui une adresse fixe.",
      "The instance's name in the logs": "Le nom de l'instance dans les journaux",
      "Where the ECU answers, for example 192.168.1.60.": "Là où l'ECU répond, par exemple 192.168.1.60."
    },
    "es": {
      "Advanced": "Avanzado",
      "An accessory for each inverter, with its power and temperature. Off, only the ECU's production is shown.": "Un accesorio por microinversor, con su potencia y su temperatura. Desactivado, solo se muestra la producción de la ECU.",
      "Connection attempts": "Intentos de conexión",
      "ECU": "ECU",
      "ECU-C meter": "Medidor de la ECU-C",
      "ECUs": "ECU",
      "How many times each request tries to connect before the reading fails, 1 to 10 (2 by default).": "Cuántas veces intenta conectarse cada solicitud antes de que la lectura falle, de 1 a 10 (2 por defecto).",
      "IP address or host name": "Dirección IP o nombre de host",
      "Inverters as accessories": "Microinversores como accesorios",
      "Name": "Nombre",
      "Poll interval (seconds)": "Intervalo de consulta (segundos)",
      "Port": "Puerto",
      "Reads an ECU-C's current clamps from its local web page, for the grid and home power on the Status page. Some ECU-C firmware no longer answers it: the production is read all the same.": "Lee las pinzas de corriente de una ECU-C en su página web local, para la potencia de la red y de la casa en la página Estado. Algunos firmwares de la ECU-C ya no responden: la producción se lee igualmente.",
      "Seconds between two readings of each ECU, 60 to 3600 (300 by default). While no inverter is online, the ECU is read every 15 minutes.": "Segundos entre dos lecturas de cada ECU, de 60 a 3600 (300 por defecto). Mientras ningún microinversor está en línea, la ECU se lee cada 15 minutos.",
      "The ECU's local protocol port, 8899 by default.": "El puerto del protocolo local de la ECU, 8899 por defecto.",
      "The ECU's name until it has one in its accessory settings. Empty, it is named after its model and ECU id.": "El nombre de la ECU mientras no tenga uno en los ajustes de su accesorio. Vacío, se nombra por su modelo y su identificador de ECU.",
      "The ECUs to read, by address. The ECU has no network announcement: find its address in your router (it often shows as an Espressif device) and give it a fixed one.": "Las ECU que leer, por dirección. La ECU no se anuncia en la red: busca su dirección en el router (suele aparecer como un dispositivo Espressif) y asígnale una fija.",
      "The instance's name in the logs": "El nombre de la instancia en los registros",
      "Where the ECU answers, for example 192.168.1.60.": "Donde responde la ECU, por ejemplo 192.168.1.60."
    },
    "pt": {
      "Advanced": "Avançado",
      "An accessory for each inverter, with its power and temperature. Off, only the ECU's production is shown.": "Um acessório por microinversor, com a sua potência e temperatura. Desligado, só é mostrada a produção da ECU.",
      "Connection attempts": "Tentativas de ligação",
      "ECU": "ECU",
      "ECU-C meter": "Contador da ECU-C",
      "ECUs": "ECU",
      "How many times each request tries to connect before the reading fails, 1 to 10 (2 by default).": "Quantas vezes cada pedido tenta ligar-se antes de a leitura falhar, de 1 a 10 (2 por omissão).",
      "IP address or host name": "Endereço IP ou nome do anfitrião",
      "Inverters as accessories": "Microinversores como acessórios",
      "Name": "Nome",
      "Poll interval (seconds)": "Intervalo de consulta (segundos)",
      "Port": "Porta",
      "Reads an ECU-C's current clamps from its local web page, for the grid and home power on the Status page. Some ECU-C firmware no longer answers it: the production is read all the same.": "Lê as pinças de corrente de uma ECU-C na sua página web local, para a potência da rede e da casa na página Estado. Alguns firmwares da ECU-C já não respondem: a produção é lida na mesma.",
      "Seconds between two readings of each ECU, 60 to 3600 (300 by default). While no inverter is online, the ECU is read every 15 minutes.": "Segundos entre duas leituras de cada ECU, de 60 a 3600 (300 por omissão). Enquanto nenhum microinversor está online, a ECU é lida a cada 15 minutos.",
      "The ECU's local protocol port, 8899 by default.": "A porta do protocolo local da ECU, 8899 por omissão.",
      "The ECU's name until it has one in its accessory settings. Empty, it is named after its model and ECU id.": "O nome da ECU enquanto não tiver um nas definições do seu acessório. Vazio, recebe o nome do modelo e do identificador da ECU.",
      "The ECUs to read, by address. The ECU has no network announcement: find its address in your router (it often shows as an Espressif device) and give it a fixed one.": "As ECU a ler, por endereço. A ECU não se anuncia na rede: procure o seu endereço no router (aparece muitas vezes como um dispositivo Espressif) e atribua-lhe um fixo.",
      "The instance's name in the logs": "O nome da instância nos registos",
      "Where the ECU answers, for example 192.168.1.60.": "Onde a ECU responde, por exemplo 192.168.1.60."
    }
  }
}
"""#
}
