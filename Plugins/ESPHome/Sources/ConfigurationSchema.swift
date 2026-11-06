// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension ESPHomePlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "esphome",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "required": true,
        "default": "ESPHome",
        "description": "Plugin name as shown in the logs"
      },
      "devices": {
        "title": "Devices",
        "type": "array",
        "description": "ESPHome devices by address, for those mDNS does not reach. Set up a device in Add accessories to give its encryption key.",
        "items": {
          "type": "object",
          "title": "Device",
          "properties": {
            "host": {
              "title": "Host",
              "type": "string",
              "required": true,
              "description": "Host name or IP address, such as my_esp.local or 192.168.1.40"
            },
            "port": {
              "title": "Port",
              "type": "integer",
              "minimum": 1,
              "maximum": 65535,
              "placeholder": 6053,
              "description": "The native API's port; 6053 by default"
            },
            "retryAfter": {
              "title": "Retry after (milliseconds)",
              "type": "integer",
              "minimum": 1000,
              "description": "The longest wait between attempts to reach a device that does not answer, at most one minute; 90000 by default"
            }
          }
        }
      },
      "discover": {
        "title": "Discover devices",
        "type": "boolean",
        "default": false,
        "description": "Look for ESPHome devices with mDNS at start and connect to each one found"
      },
      "discoveryTimeout": {
        "title": "Discovery timeout (milliseconds)",
        "type": "integer",
        "minimum": 0,
        "placeholder": 5000,
        "description": "How long the mDNS search lasts at start; 5000 by default"
      },
      "retryAfter": {
        "title": "Retry after (milliseconds)",
        "type": "integer",
        "minimum": 1000,
        "placeholder": 90000,
        "description": "The longest wait between attempts to reach a device that does not answer, at most one minute; 90000 by default"
      },
      "blacklist": {
        "title": "Blacklist",
        "type": "array",
        "items": {
          "type": "string"
        },
        "description": "Entity names to leave out, exactly as ESPHome names them"
      },
      "bluetooth": {
        "title": "Bluetooth sensors",
        "type": "boolean",
        "default": true,
        "description": "Listen to the Bluetooth LE advertisements ESPHome's Bluetooth proxies hear, for the sensors set up in Add accessories"
      },
      "bluetoothTimeout": {
        "title": "Bluetooth timeout (minutes)",
        "type": "integer",
        "minimum": 1,
        "placeholder": 30,
        "description": "Minutes without an advertisement before a Bluetooth sensor shows No Response; 30 by default"
      },
      "debug": {
        "title": "Debug",
        "type": "boolean",
        "default": false,
        "description": "Log each device's entities and the ones left out at the info level"
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "host": {
        "title": "Host",
        "type": "string",
        "description": "The device's host name or IP address",
        "x-kinds": [
          "device"
        ]
      },
      "port": {
        "title": "Port",
        "type": "integer",
        "minimum": 1,
        "maximum": 65535,
        "description": "The native API's port; 6053 by default",
        "x-kinds": [
          "device"
        ]
      },
      "retryAfter": {
        "title": "Retry after (milliseconds)",
        "type": "integer",
        "minimum": 1000,
        "description": "The longest wait between attempts to reach this device; empty takes the plugin's setting",
        "x-default": "retryAfter",
        "x-kinds": [
          "device"
        ]
      },
      "format": {
        "title": "Advertisement format",
        "type": "string",
        "description": "How the Bluetooth sensor's advertisements are read; Setup finds it",
        "oneOf": [
          {
            "title": "BTHome",
            "enum": [
              "bthome"
            ]
          },
          {
            "title": "Xiaomi MiBeacon",
            "enum": [
              "xiaomi"
            ]
          },
          {
            "title": "Govee",
            "enum": [
              "govee"
            ]
          }
        ],
        "x-kinds": [
          "sensor"
        ]
      }
    }
  },
  "i18n": {
    "fr": {
      "Name": "Nom",
      "Plugin name as shown in the logs": "Nom du plugin tel qu'affiché dans les journaux",
      "Device": "Appareil",
      "Devices": "Appareils",
      "ESPHome devices by address, for those mDNS does not reach. Set up a device in Add accessories to give its encryption key.": "Appareils ESPHome par adresse, pour ceux que mDNS n'atteint pas. Configurez un appareil dans Ajouter des accessoires pour donner sa clé de chiffrement.",
      "Host": "Hôte",
      "Host name or IP address, such as my_esp.local or 192.168.1.40": "Nom d'hôte ou adresse IP, comme my_esp.local ou 192.168.1.40",
      "Port": "Port",
      "The native API's port; 6053 by default": "Le port de l'API native ; 6053 par défaut",
      "Retry after (milliseconds)": "Nouvel essai après (millisecondes)",
      "The longest wait between attempts to reach a device that does not answer, at most one minute; 90000 by default": "L'attente la plus longue entre deux tentatives de joindre un appareil qui ne répond pas, une minute au plus ; 90000 par défaut",
      "The longest wait between attempts to reach this device; empty takes the plugin's setting": "L'attente la plus longue entre deux tentatives de joindre cet appareil ; vide reprend le réglage du plugin",
      "Discover devices": "Découvrir les appareils",
      "Look for ESPHome devices with mDNS at start and connect to each one found": "Chercher les appareils ESPHome avec mDNS au démarrage et se connecter à chacun",
      "Discovery timeout (milliseconds)": "Durée de la découverte (millisecondes)",
      "How long the mDNS search lasts at start; 5000 by default": "Durée de la recherche mDNS au démarrage ; 5000 par défaut",
      "Blacklist": "Liste d'exclusion",
      "Entity names to leave out, exactly as ESPHome names them": "Noms d'entités à laisser de côté, exactement comme ESPHome les nomme",
      "Debug": "Débogage",
      "Log each device's entities and the ones left out at the info level": "Journaliser au niveau info les entités de chaque appareil et celles laissées de côté",
      "The device's host name or IP address": "Le nom d'hôte ou l'adresse IP de l'appareil",
      "Bluetooth sensors": "Capteurs Bluetooth",
      "Listen to the Bluetooth LE advertisements ESPHome's Bluetooth proxies hear, for the sensors set up in Add accessories": "Écouter les annonces Bluetooth LE que reçoivent les proxys Bluetooth d'ESPHome, pour les capteurs configurés dans Ajouter des accessoires",
      "Bluetooth timeout (minutes)": "Délai Bluetooth (minutes)",
      "Minutes without an advertisement before a Bluetooth sensor shows No Response; 30 by default": "Minutes sans annonce avant qu'un capteur Bluetooth s'affiche Ne répond pas ; 30 par défaut",
      "Advertisement format": "Format des annonces",
      "How the Bluetooth sensor's advertisements are read; Setup finds it": "Comment les annonces du capteur Bluetooth sont lues ; la configuration le trouve",
      "BTHome": "BTHome",
      "Xiaomi MiBeacon": "Xiaomi MiBeacon",
      "Govee": "Govee"
    },
    "es": {
      "Name": "Nombre",
      "Plugin name as shown in the logs": "Nombre del plugin tal como aparece en los registros",
      "Device": "Dispositivo",
      "Devices": "Dispositivos",
      "ESPHome devices by address, for those mDNS does not reach. Set up a device in Add accessories to give its encryption key.": "Dispositivos ESPHome por dirección, para los que mDNS no alcanza. Configure un dispositivo en Añadir accesorios para dar su clave de cifrado.",
      "Host": "Host",
      "Host name or IP address, such as my_esp.local or 192.168.1.40": "Nombre de host o dirección IP, como my_esp.local o 192.168.1.40",
      "Port": "Puerto",
      "The native API's port; 6053 by default": "El puerto de la API nativa; 6053 por defecto",
      "Retry after (milliseconds)": "Reintentar tras (milisegundos)",
      "The longest wait between attempts to reach a device that does not answer, at most one minute; 90000 by default": "La espera más larga entre intentos de alcanzar un dispositivo que no responde, como máximo un minuto; 90000 por defecto",
      "The longest wait between attempts to reach this device; empty takes the plugin's setting": "La espera más larga entre intentos de alcanzar este dispositivo; vacío toma el ajuste del plugin",
      "Discover devices": "Descubrir dispositivos",
      "Look for ESPHome devices with mDNS at start and connect to each one found": "Buscar dispositivos ESPHome con mDNS al inicio y conectarse a cada uno",
      "Discovery timeout (milliseconds)": "Duración de la búsqueda (milisegundos)",
      "How long the mDNS search lasts at start; 5000 by default": "Cuánto dura la búsqueda mDNS al inicio; 5000 por defecto",
      "Blacklist": "Lista de exclusión",
      "Entity names to leave out, exactly as ESPHome names them": "Nombres de entidades que se dejan fuera, exactamente como ESPHome los nombra",
      "Debug": "Depuración",
      "Log each device's entities and the ones left out at the info level": "Registrar en el nivel info las entidades de cada dispositivo y las que se dejan fuera",
      "The device's host name or IP address": "El nombre de host o la dirección IP del dispositivo",
      "Bluetooth sensors": "Sensores Bluetooth",
      "Listen to the Bluetooth LE advertisements ESPHome's Bluetooth proxies hear, for the sensors set up in Add accessories": "Escuchar los anuncios Bluetooth LE que reciben los proxies Bluetooth de ESPHome, para los sensores configurados en Añadir accesorios",
      "Bluetooth timeout (minutes)": "Tiempo de espera Bluetooth (minutos)",
      "Minutes without an advertisement before a Bluetooth sensor shows No Response; 30 by default": "Minutos sin anuncios antes de que un sensor Bluetooth aparezca como Sin respuesta; 30 por defecto",
      "Advertisement format": "Formato de los anuncios",
      "How the Bluetooth sensor's advertisements are read; Setup finds it": "Cómo se leen los anuncios del sensor Bluetooth; la configuración lo encuentra",
      "BTHome": "BTHome",
      "Xiaomi MiBeacon": "Xiaomi MiBeacon",
      "Govee": "Govee"
    },
    "pt": {
      "Name": "Nome",
      "Plugin name as shown in the logs": "Nome do plugin tal como aparece nos registos",
      "Device": "Dispositivo",
      "Devices": "Dispositivos",
      "ESPHome devices by address, for those mDNS does not reach. Set up a device in Add accessories to give its encryption key.": "Dispositivos ESPHome por endereço, para os que o mDNS não alcança. Configure um dispositivo em Adicionar acessórios para indicar a sua chave de encriptação.",
      "Host": "Host",
      "Host name or IP address, such as my_esp.local or 192.168.1.40": "Nome do host ou endereço IP, como my_esp.local ou 192.168.1.40",
      "Port": "Porta",
      "The native API's port; 6053 by default": "A porta da API nativa; 6053 por predefinição",
      "Retry after (milliseconds)": "Tentar de novo após (milissegundos)",
      "The longest wait between attempts to reach a device that does not answer, at most one minute; 90000 by default": "A espera mais longa entre tentativas de alcançar um dispositivo que não responde, no máximo um minuto; 90000 por predefinição",
      "The longest wait between attempts to reach this device; empty takes the plugin's setting": "A espera mais longa entre tentativas de alcançar este dispositivo; vazio usa a definição do plugin",
      "Discover devices": "Descobrir dispositivos",
      "Look for ESPHome devices with mDNS at start and connect to each one found": "Procurar dispositivos ESPHome com mDNS no arranque e ligar a cada um",
      "Discovery timeout (milliseconds)": "Duração da descoberta (milissegundos)",
      "How long the mDNS search lasts at start; 5000 by default": "Quanto dura a procura mDNS no arranque; 5000 por predefinição",
      "Blacklist": "Lista de exclusão",
      "Entity names to leave out, exactly as ESPHome names them": "Nomes de entidades a deixar de fora, exatamente como o ESPHome os nomeia",
      "Debug": "Depuração",
      "Log each device's entities and the ones left out at the info level": "Registar no nível info as entidades de cada dispositivo e as que ficam de fora",
      "The device's host name or IP address": "O nome do host ou o endereço IP do dispositivo",
      "Bluetooth sensors": "Sensores Bluetooth",
      "Listen to the Bluetooth LE advertisements ESPHome's Bluetooth proxies hear, for the sensors set up in Add accessories": "Ouvir os anúncios Bluetooth LE que os proxies Bluetooth do ESPHome recebem, para os sensores configurados em Adicionar acessórios",
      "Bluetooth timeout (minutes)": "Tempo limite Bluetooth (minutos)",
      "Minutes without an advertisement before a Bluetooth sensor shows No Response; 30 by default": "Minutos sem anúncios antes de um sensor Bluetooth aparecer como Sem resposta; 30 por predefinição",
      "Advertisement format": "Formato dos anúncios",
      "How the Bluetooth sensor's advertisements are read; Setup finds it": "Como são lidos os anúncios do sensor Bluetooth; a configuração encontra-o",
      "BTHome": "BTHome",
      "Xiaomi MiBeacon": "Xiaomi MiBeacon",
      "Govee": "Govee"
    }
  }
}
"""#
}
