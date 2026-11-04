// THIS FILE IS GENERATED from ../config.gen1.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension ShellyPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "Shelly",
  "pluginType": "platform",
  "singular": true,
  "headerDisplay": "Shelly Gen 1 devices, heard on the network over CoIoT. Plus, Pro, Gen3 and Gen4 devices are the ShellyNG platform's.",
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "description": "The platform's name in the logs.",
        "type": "string",
        "required": true,
        "default": "Shelly"
      },
      "networkInterface": {
        "title": "Network interface",
        "description": "The interface name (eth0) or a local IPv4 address to listen for devices on; empty for the default one.",
        "type": "string"
      },
      "requestTimeout": {
        "title": "Request timeout",
        "description": "Milliseconds to wait for a device's answer.",
        "type": "integer",
        "minimum": 100,
        "default": 10000
      },
      "staleTimeout": {
        "title": "Stale timeout",
        "description": "Milliseconds a device may stay offline before its accessories are removed; 0 keeps them.",
        "type": "integer",
        "minimum": 0,
        "default": 0
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "type": {
        "title": "Show as",
        "description": "The kind of accessory a relay, or a Shelly 2 or 2.5 in roller mode, is in HomeKit.",
        "type": "string",
        "x-kinds": ["relay"],
        "oneOf": [
          { "title": "Switch", "enum": ["switch"] },
          { "title": "Outlet", "enum": ["outlet"] },
          { "title": "Valve", "enum": ["valve"] },
          { "title": "Contact sensor", "enum": ["contactSensor"] },
          { "title": "Motion sensor", "enum": ["motionSensor"] },
          { "title": "Occupancy sensor", "enum": ["occupancySensor"] },
          { "title": "Window covering (roller mode)", "enum": ["windowCovering"] },
          { "title": "Window (roller mode)", "enum": ["window"] },
          { "title": "Door (roller mode)", "enum": ["door"] },
          { "title": "Garage door (roller mode)", "enum": ["garageDoorOpener"] }
        ]
      },
      "colorMode": {
        "title": "Colour channels",
        "description": "Whether the white channel follows the colour.",
        "type": "string",
        "x-kinds": ["colorLight"],
        "oneOf": [{ "title": "Red, green, blue and white", "enum": ["rgbw"] }, { "title": "Red, green and blue", "enum": ["rgb"] }]
      },
      "accessories": {
        "title": "Channels",
        "description": "Options of each relay or channel in turn, over the device's own.",
        "type": "array",
        "x-kinds": ["relay", "light", "colorLight"],
        "items": {
          "title": "Channel",
          "type": "object",
          "x-rowTitle": ["name", "type"],
          "properties": {
            "name": { "title": "Channel name", "description": "The name of this relay's or channel's accessory.", "type": "string" },
            "type": { "title": "Channel type", "description": "The kind of accessory this relay is: switch, outlet, valve, contactSensor, motionSensor or occupancySensor.", "type": "string" },
            "colorMode": { "title": "Channel colour channels", "description": "rgbw or rgb, for a colour light.", "type": "string" }
          }
        }
      }
    }
  },
  "i18n": {
    "fr": {
      "Shelly Gen 1 devices, heard on the network over CoIoT. Plus, Pro, Gen3 and Gen4 devices are the ShellyNG platform's.": "Les appareils Shelly Gen 1, entendus sur le réseau par CoIoT. Les appareils Plus, Pro, Gen3 et Gen4 relèvent de la plateforme ShellyNG.",
      "Name": "Nom",
      "The platform's name in the logs.": "Le nom de la plateforme dans le journal.",
      "Network interface": "Interface réseau",
      "The interface name (eth0) or a local IPv4 address to listen for devices on; empty for the default one.": "Le nom de l'interface (eth0) ou une adresse IPv4 locale où écouter les appareils ; vide pour celle par défaut.",
      "Request timeout": "Délai d'une requête",
      "Milliseconds to wait for a device's answer.": "Millisecondes d'attente de la réponse d'un appareil.",
      "Stale timeout": "Délai d'oubli",
      "Milliseconds a device may stay offline before its accessories are removed; 0 keeps them.": "Millisecondes pendant lesquelles un appareil peut rester hors ligne avant que ses accessoires soient retirés ; 0 les garde.",
      "Show as": "Afficher comme",
      "The kind of accessory a relay, or a Shelly 2 or 2.5 in roller mode, is in HomeKit.": "Le genre d'accessoire qu'est un relais, ou un Shelly 2 ou 2.5 en mode volet, dans HomeKit.",
      "Switch": "Interrupteur",
      "Outlet": "Prise",
      "Valve": "Vanne",
      "Contact sensor": "Capteur de contact",
      "Motion sensor": "Détecteur de mouvement",
      "Occupancy sensor": "Détecteur de présence",
      "Window covering (roller mode)": "Store (mode volet)",
      "Window (roller mode)": "Fenêtre (mode volet)",
      "Door (roller mode)": "Porte (mode volet)",
      "Garage door (roller mode)": "Porte de garage (mode volet)",
      "Colour channels": "Canaux de couleur",
      "Whether the white channel follows the colour.": "Si le canal blanc suit la couleur.",
      "Red, green, blue and white": "Rouge, vert, bleu et blanc",
      "Red, green and blue": "Rouge, vert et bleu",
      "Channels": "Canaux",
      "Channel": "Canal",
      "Options of each relay or channel in turn, over the device's own.": "Les options de chaque relais ou canal à son tour, par-dessus celles de l'appareil.",
      "Channel name": "Nom du canal",
      "The name of this relay's or channel's accessory.": "Le nom de l'accessoire de ce relais ou canal.",
      "Channel type": "Type du canal",
      "The kind of accessory this relay is: switch, outlet, valve, contactSensor, motionSensor or occupancySensor.": "Le genre d'accessoire qu'est ce relais : switch, outlet, valve, contactSensor, motionSensor ou occupancySensor.",
      "Channel colour channels": "Canaux de couleur du canal",
      "rgbw or rgb, for a colour light.": "rgbw ou rgb, pour une lumière de couleur."
    },
    "es": {
      "Shelly Gen 1 devices, heard on the network over CoIoT. Plus, Pro, Gen3 and Gen4 devices are the ShellyNG platform's.": "Los dispositivos Shelly Gen 1, escuchados en la red por CoIoT. Los dispositivos Plus, Pro, Gen3 y Gen4 son de la plataforma ShellyNG.",
      "Name": "Nombre",
      "The platform's name in the logs.": "El nombre de la plataforma en el registro.",
      "Network interface": "Interfaz de red",
      "The interface name (eth0) or a local IPv4 address to listen for devices on; empty for the default one.": "El nombre de la interfaz (eth0) o una dirección IPv4 local donde escuchar los dispositivos; vacío para la predeterminada.",
      "Request timeout": "Tiempo de espera de una solicitud",
      "Milliseconds to wait for a device's answer.": "Milisegundos de espera de la respuesta de un dispositivo.",
      "Stale timeout": "Tiempo de olvido",
      "Milliseconds a device may stay offline before its accessories are removed; 0 keeps them.": "Milisegundos que un dispositivo puede estar sin conexión antes de que se quiten sus accesorios; 0 los conserva.",
      "Show as": "Mostrar como",
      "The kind of accessory a relay, or a Shelly 2 or 2.5 in roller mode, is in HomeKit.": "El tipo de accesorio que es un relé, o un Shelly 2 o 2.5 en modo persiana, en HomeKit.",
      "Switch": "Interruptor",
      "Outlet": "Enchufe",
      "Valve": "Válvula",
      "Contact sensor": "Sensor de contacto",
      "Motion sensor": "Sensor de movimiento",
      "Occupancy sensor": "Sensor de presencia",
      "Window covering (roller mode)": "Estor (modo persiana)",
      "Window (roller mode)": "Ventana (modo persiana)",
      "Door (roller mode)": "Puerta (modo persiana)",
      "Garage door (roller mode)": "Puerta de garaje (modo persiana)",
      "Colour channels": "Canales de color",
      "Whether the white channel follows the colour.": "Si el canal blanco sigue al color.",
      "Red, green, blue and white": "Rojo, verde, azul y blanco",
      "Red, green and blue": "Rojo, verde y azul",
      "Channels": "Canales",
      "Channel": "Canal",
      "Options of each relay or channel in turn, over the device's own.": "Las opciones de cada relé o canal por orden, sobre las del dispositivo.",
      "Channel name": "Nombre del canal",
      "The name of this relay's or channel's accessory.": "El nombre del accesorio de este relé o canal.",
      "Channel type": "Tipo del canal",
      "The kind of accessory this relay is: switch, outlet, valve, contactSensor, motionSensor or occupancySensor.": "El tipo de accesorio que es este relé: switch, outlet, valve, contactSensor, motionSensor u occupancySensor.",
      "Channel colour channels": "Canales de color del canal",
      "rgbw or rgb, for a colour light.": "rgbw o rgb, para una luz de color."
    },
    "pt": {
      "Shelly Gen 1 devices, heard on the network over CoIoT. Plus, Pro, Gen3 and Gen4 devices are the ShellyNG platform's.": "Os dispositivos Shelly Gen 1, ouvidos na rede por CoIoT. Os dispositivos Plus, Pro, Gen3 e Gen4 são da plataforma ShellyNG.",
      "Name": "Nome",
      "The platform's name in the logs.": "O nome da plataforma no registo.",
      "Network interface": "Interface de rede",
      "The interface name (eth0) or a local IPv4 address to listen for devices on; empty for the default one.": "O nome da interface (eth0) ou um endereço IPv4 local onde ouvir os dispositivos; vazio para a predefinida.",
      "Request timeout": "Tempo limite de um pedido",
      "Milliseconds to wait for a device's answer.": "Milissegundos de espera pela resposta de um dispositivo.",
      "Stale timeout": "Tempo de esquecimento",
      "Milliseconds a device may stay offline before its accessories are removed; 0 keeps them.": "Milissegundos que um dispositivo pode ficar offline antes de os seus acessórios serem removidos; 0 mantém-nos.",
      "Show as": "Mostrar como",
      "The kind of accessory a relay, or a Shelly 2 or 2.5 in roller mode, is in HomeKit.": "O tipo de acessório que um relé, ou um Shelly 2 ou 2.5 em modo estore, é no HomeKit.",
      "Switch": "Interruptor",
      "Outlet": "Tomada",
      "Valve": "Válvula",
      "Contact sensor": "Sensor de contacto",
      "Motion sensor": "Sensor de movimento",
      "Occupancy sensor": "Sensor de presença",
      "Window covering (roller mode)": "Estore de rolo (modo estore)",
      "Window (roller mode)": "Janela (modo estore)",
      "Door (roller mode)": "Porta (modo estore)",
      "Garage door (roller mode)": "Portão de garagem (modo estore)",
      "Colour channels": "Canais de cor",
      "Whether the white channel follows the colour.": "Se o canal branco acompanha a cor.",
      "Red, green, blue and white": "Vermelho, verde, azul e branco",
      "Red, green and blue": "Vermelho, verde e azul",
      "Channels": "Canais",
      "Channel": "Canal",
      "Options of each relay or channel in turn, over the device's own.": "As opções de cada relé ou canal por ordem, sobre as do dispositivo.",
      "Channel name": "Nome do canal",
      "The name of this relay's or channel's accessory.": "O nome do acessório deste relé ou canal.",
      "Channel type": "Tipo do canal",
      "The kind of accessory this relay is: switch, outlet, valve, contactSensor, motionSensor or occupancySensor.": "O tipo de acessório que este relé é: switch, outlet, valve, contactSensor, motionSensor ou occupancySensor.",
      "Channel colour channels": "Canais de cor do canal",
      "rgbw or rgb, for a colour light.": "rgbw ou rgb, para uma luz de cor."
    }
  }
}
"""#
}
