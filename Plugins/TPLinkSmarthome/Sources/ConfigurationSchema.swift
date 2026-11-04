// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension TPLinkSmarthomePlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "TplinkSmarthome",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "required": true,
        "default": "TplinkSmarthome",
        "description": "Plugin name as shown in the logs"
      },
      "pollingInterval": {
        "title": "Polling Interval (seconds)",
        "type": "integer",
        "placeholder": 10,
        "minimum": 1,
        "description": "Seconds between discovery broadcasts. Each one is also the state poll: every reply updates its device."
      },
      "emeterPollingInterval": {
        "title": "Energy Polling Interval (seconds)",
        "type": "integer",
        "placeholder": 20,
        "description": "Seconds between energy readings of the devices that meter it. 0 reads only when HomeKit asks."
      },
      "addCustomCharacteristics": {
        "title": "Energy Characteristics",
        "type": "boolean",
        "default": true,
        "description": "Show volts, amperes, watts and kWh in the Eve app for the devices that meter energy."
      },
      "inUseThreshold": {
        "title": "In Use Threshold (watts)",
        "type": "number",
        "placeholder": 0,
        "minimum": 0,
        "description": "A metering outlet shows In Use above this power."
      },
      "switchModels": {
        "title": "Switch Models",
        "type": "array",
        "description": "Models shown as a switch rather than an outlet (part of the model name). Empty takes HS200 and HS210.",
        "items": {
          "type": "string",
          "title": "Model"
        }
      },
      "deviceTypes": {
        "title": "Device Types",
        "type": "array",
        "uniqueItems": true,
        "description": "The kinds of device to add. None selected adds both.",
        "items": {
          "type": "string",
          "oneOf": [
            {
              "title": "Plugs and switches",
              "enum": [
                "plug"
              ]
            },
            {
              "title": "Bulbs and light strips",
              "enum": [
                "bulb"
              ]
            }
          ]
        }
      },
      "macAddresses": {
        "title": "Allowed MAC Addresses",
        "type": "array",
        "description": "Only add the devices whose MAC matches one of these patterns (* and ? allowed). Empty adds every device.",
        "items": {
          "type": "string",
          "title": "MAC pattern"
        }
      },
      "excludeMacAddresses": {
        "title": "Excluded MAC Addresses",
        "type": "array",
        "description": "Leave out the devices whose MAC matches one of these patterns (* and ? allowed).",
        "items": {
          "type": "string",
          "title": "MAC pattern"
        }
      },
      "devices": {
        "title": "Devices by Address",
        "type": "array",
        "description": "Devices the broadcast does not reach: each also gets the discovery packet at its address. They need a fixed IP address.",
        "items": {
          "type": "object",
          "title": "Device",
          "properties": {
            "host": {
              "title": "Host",
              "type": "string",
              "required": true,
              "description": "The device's IP address or host name"
            },
            "port": {
              "title": "Port",
              "type": "integer",
              "placeholder": 9999,
              "minimum": 1,
              "maximum": 65535,
              "description": "The port the discovery packet goes to; 9999 by default"
            }
          }
        }
      },
      "broadcast": {
        "title": "Broadcast Address",
        "type": "string",
        "format": "ipv4",
        "placeholder": "255.255.255.255",
        "description": "Where the discovery broadcast goes, such as a subnet's broadcast address."
      },
      "discoveryPort": {
        "title": "Discovery Port",
        "type": "integer",
        "placeholder": 0,
        "minimum": 0,
        "maximum": 65535,
        "description": "The local UDP port discovery listens on. 0 lets the system choose."
      },
      "devicesUseDiscoveryPort": {
        "title": "Commands to the Discovery Port",
        "type": "boolean",
        "default": false,
        "description": "Send each device its commands at the port its discovery reply came from rather than 9999, for port forwarding."
      },
      "transport": {
        "title": "Transport",
        "type": "string",
        "description": "How commands reach the devices. Discovery always uses UDP.",
        "oneOf": [
          {
            "title": "TCP",
            "enum": [
              "tcp"
            ]
          },
          {
            "title": "UDP",
            "enum": [
              "udp"
            ]
          }
        ]
      },
      "timeout": {
        "title": "Timeout (seconds)",
        "type": "integer",
        "placeholder": 15,
        "minimum": 0,
        "description": "Seconds a command may take. 0 waits as long as the connection lasts."
      },
      "waitTimeUpdate": {
        "title": "Write Window (milliseconds)",
        "type": "integer",
        "placeholder": 100,
        "minimum": 0,
        "description": "HomeKit's changes to a device within this time are sent as one command."
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "inUseThreshold": {
        "title": "In Use Threshold (watts)",
        "type": "number",
        "minimum": 0,
        "x-kinds": [
          "outlet"
        ],
        "x-default": "inUseThreshold",
        "description": "This outlet shows In Use above this power. Empty takes the plugin's setting."
      }
    }
  },
  "layout": [
    "name",
    "pollingInterval",
    "emeterPollingInterval",
    "addCustomCharacteristics",
    "inUseThreshold",
    "switchModels",
    "deviceTypes",
    {
      "type": "fieldset",
      "title": "Devices",
      "expandable": true,
      "expanded": false,
      "items": [
        "macAddresses",
        "excludeMacAddresses",
        "devices"
      ]
    },
    {
      "type": "fieldset",
      "title": "Advanced",
      "expandable": true,
      "expanded": false,
      "items": [
        "broadcast",
        "discoveryPort",
        "devicesUseDiscoveryPort",
        "transport",
        "timeout",
        "waitTimeUpdate"
      ]
    }
  ],
  "i18n": {
    "fr": {
      "A metering outlet shows In Use above this power.": "Une prise qui mesure l'énergie est en cours d'utilisation au-dessus de cette puissance.",
      "Advanced": "Avancé",
      "Allowed MAC Addresses": "Adresses MAC autorisées",
      "Broadcast Address": "Adresse de diffusion",
      "Bulbs and light strips": "Ampoules et rubans lumineux",
      "Commands to the Discovery Port": "Commandes vers le port de découverte",
      "Device": "Appareil",
      "Device Types": "Types d'appareils",
      "Devices": "Appareils",
      "Devices by Address": "Appareils par adresse",
      "Devices the broadcast does not reach: each also gets the discovery packet at its address. They need a fixed IP address.": "Appareils que la diffusion n'atteint pas : chacun reçoit aussi le paquet de découverte à son adresse. Il leur faut une adresse IP fixe.",
      "Discovery Port": "Port de découverte",
      "Energy Characteristics": "Caractéristiques d'énergie",
      "Energy Polling Interval (seconds)": "Intervalle de lecture de l'énergie (secondes)",
      "Excluded MAC Addresses": "Adresses MAC exclues",
      "HomeKit's changes to a device within this time are sent as one command.": "Les changements de HomeKit sur un appareil dans ce délai partent en une seule commande.",
      "Host": "Hôte",
      "How commands reach the devices. Discovery always uses UDP.": "Comment les commandes parviennent aux appareils. La découverte utilise toujours UDP.",
      "In Use Threshold (watts)": "Seuil d'utilisation (watts)",
      "Leave out the devices whose MAC matches one of these patterns (* and ? allowed).": "Laisse de côté les appareils dont l'adresse MAC correspond à l'un de ces motifs (* et ? acceptés).",
      "MAC pattern": "Motif d'adresse MAC",
      "Model": "Modèle",
      "Models shown as a switch rather than an outlet (part of the model name). Empty takes HS200 and HS210.": "Modèles affichés comme un interrupteur plutôt qu'une prise (une partie du nom du modèle). Vide prend HS200 et HS210.",
      "Name": "Nom",
      "Only add the devices whose MAC matches one of these patterns (* and ? allowed). Empty adds every device.": "N'ajoute que les appareils dont l'adresse MAC correspond à l'un de ces motifs (* et ? acceptés). Vide ajoute tous les appareils.",
      "Plugin name as shown in the logs": "Nom du plugin tel qu'il apparaît dans le journal",
      "Plugs and switches": "Prises et interrupteurs",
      "Polling Interval (seconds)": "Intervalle d'interrogation (secondes)",
      "Port": "Port",
      "Seconds a command may take. 0 waits as long as the connection lasts.": "Secondes que peut prendre une commande. 0 attend tant que dure la connexion.",
      "Seconds between discovery broadcasts. Each one is also the state poll: every reply updates its device.": "Secondes entre deux diffusions de découverte. Chacune sert aussi à relever l'état : chaque réponse met son appareil à jour.",
      "Seconds between energy readings of the devices that meter it. 0 reads only when HomeKit asks.": "Secondes entre deux lectures de l'énergie des appareils qui la mesurent. 0 ne lit que lorsque HomeKit la demande.",
      "Send each device its commands at the port its discovery reply came from rather than 9999, for port forwarding.": "Envoie ses commandes à chaque appareil sur le port d'où vient sa réponse de découverte plutôt que 9999, pour une redirection de port.",
      "Show volts, amperes, watts and kWh in the Eve app for the devices that meter energy.": "Affiche les volts, ampères, watts et kWh dans l'app Eve pour les appareils qui mesurent l'énergie.",
      "Switch Models": "Modèles d'interrupteur",
      "TCP": "TCP",
      "The device's IP address or host name": "L'adresse IP ou le nom d'hôte de l'appareil",
      "The kinds of device to add. None selected adds both.": "Les sortes d'appareils à ajouter. Aucune sélection ajoute les deux.",
      "The local UDP port discovery listens on. 0 lets the system choose.": "Le port UDP local où écoute la découverte. 0 laisse le système choisir.",
      "The port the discovery packet goes to; 9999 by default": "Le port où va le paquet de découverte ; 9999 par défaut",
      "This outlet shows In Use above this power. Empty takes the plugin's setting.": "Cette prise est en cours d'utilisation au-dessus de cette puissance. Vide prend le réglage du plugin.",
      "Timeout (seconds)": "Délai d'attente (secondes)",
      "Transport": "Transport",
      "UDP": "UDP",
      "Where the discovery broadcast goes, such as a subnet's broadcast address.": "Où va la diffusion de découverte, par exemple l'adresse de diffusion d'un sous-réseau.",
      "Write Window (milliseconds)": "Fenêtre d'écriture (millisecondes)"
    },
    "es": {
      "A metering outlet shows In Use above this power.": "Un enchufe que mide la energía está en uso por encima de esta potencia.",
      "Advanced": "Avanzado",
      "Allowed MAC Addresses": "Direcciones MAC permitidas",
      "Broadcast Address": "Dirección de difusión",
      "Bulbs and light strips": "Bombillas y tiras de luz",
      "Commands to the Discovery Port": "Órdenes al puerto de descubrimiento",
      "Device": "Dispositivo",
      "Device Types": "Tipos de dispositivos",
      "Devices": "Dispositivos",
      "Devices by Address": "Dispositivos por dirección",
      "Devices the broadcast does not reach: each also gets the discovery packet at its address. They need a fixed IP address.": "Dispositivos que la difusión no alcanza: cada uno recibe también el paquete de descubrimiento en su dirección. Necesitan una dirección IP fija.",
      "Discovery Port": "Puerto de descubrimiento",
      "Energy Characteristics": "Características de energía",
      "Energy Polling Interval (seconds)": "Intervalo de lectura de energía (segundos)",
      "Excluded MAC Addresses": "Direcciones MAC excluidas",
      "HomeKit's changes to a device within this time are sent as one command.": "Los cambios de HomeKit en un dispositivo dentro de este tiempo se envían como una sola orden.",
      "Host": "Host",
      "How commands reach the devices. Discovery always uses UDP.": "Cómo llegan las órdenes a los dispositivos. El descubrimiento siempre usa UDP.",
      "In Use Threshold (watts)": "Umbral de uso (vatios)",
      "Leave out the devices whose MAC matches one of these patterns (* and ? allowed).": "Deja fuera los dispositivos cuya MAC coincide con uno de estos patrones (se admiten * y ?).",
      "MAC pattern": "Patrón de MAC",
      "Model": "Modelo",
      "Models shown as a switch rather than an outlet (part of the model name). Empty takes HS200 and HS210.": "Modelos mostrados como interruptor en lugar de enchufe (parte del nombre del modelo). Vacío toma HS200 y HS210.",
      "Name": "Nombre",
      "Only add the devices whose MAC matches one of these patterns (* and ? allowed). Empty adds every device.": "Solo añade los dispositivos cuya MAC coincide con uno de estos patrones (se admiten * y ?). Vacío añade todos los dispositivos.",
      "Plugin name as shown in the logs": "Nombre del plugin tal como aparece en el registro",
      "Plugs and switches": "Enchufes e interruptores",
      "Polling Interval (seconds)": "Intervalo de sondeo (segundos)",
      "Port": "Puerto",
      "Seconds a command may take. 0 waits as long as the connection lasts.": "Segundos que puede tardar una orden. 0 espera mientras dure la conexión.",
      "Seconds between discovery broadcasts. Each one is also the state poll: every reply updates its device.": "Segundos entre dos difusiones de descubrimiento. Cada una sirve también para leer el estado: cada respuesta actualiza su dispositivo.",
      "Seconds between energy readings of the devices that meter it. 0 reads only when HomeKit asks.": "Segundos entre dos lecturas de energía de los dispositivos que la miden. 0 solo lee cuando HomeKit la pide.",
      "Send each device its commands at the port its discovery reply came from rather than 9999, for port forwarding.": "Envía sus órdenes a cada dispositivo al puerto del que vino su respuesta de descubrimiento en lugar del 9999, para una redirección de puertos.",
      "Show volts, amperes, watts and kWh in the Eve app for the devices that meter energy.": "Muestra voltios, amperios, vatios y kWh en la app Eve para los dispositivos que miden la energía.",
      "Switch Models": "Modelos de interruptor",
      "TCP": "TCP",
      "The device's IP address or host name": "La dirección IP o el nombre de host del dispositivo",
      "The kinds of device to add. None selected adds both.": "Los tipos de dispositivo que añadir. Sin selección se añaden ambos.",
      "The local UDP port discovery listens on. 0 lets the system choose.": "El puerto UDP local en el que escucha el descubrimiento. 0 deja elegir al sistema.",
      "The port the discovery packet goes to; 9999 by default": "El puerto al que va el paquete de descubrimiento; 9999 por defecto",
      "This outlet shows In Use above this power. Empty takes the plugin's setting.": "Este enchufe está en uso por encima de esta potencia. Vacío toma el ajuste del plugin.",
      "Timeout (seconds)": "Tiempo de espera (segundos)",
      "Transport": "Transporte",
      "UDP": "UDP",
      "Where the discovery broadcast goes, such as a subnet's broadcast address.": "Adónde va la difusión de descubrimiento, por ejemplo la dirección de difusión de una subred.",
      "Write Window (milliseconds)": "Ventana de escritura (milisegundos)"
    },
    "pt": {
      "A metering outlet shows In Use above this power.": "Uma tomada que mede a energia está em utilização acima desta potência.",
      "Advanced": "Avançado",
      "Allowed MAC Addresses": "Endereços MAC permitidos",
      "Broadcast Address": "Endereço de difusão",
      "Bulbs and light strips": "Lâmpadas e fitas de luz",
      "Commands to the Discovery Port": "Comandos para a porta de descoberta",
      "Device": "Dispositivo",
      "Device Types": "Tipos de dispositivos",
      "Devices": "Dispositivos",
      "Devices by Address": "Dispositivos por endereço",
      "Devices the broadcast does not reach: each also gets the discovery packet at its address. They need a fixed IP address.": "Dispositivos que a difusão não alcança: cada um recebe também o pacote de descoberta no seu endereço. Precisam de um endereço IP fixo.",
      "Discovery Port": "Porta de descoberta",
      "Energy Characteristics": "Características de energia",
      "Energy Polling Interval (seconds)": "Intervalo de leitura de energia (segundos)",
      "Excluded MAC Addresses": "Endereços MAC excluídos",
      "HomeKit's changes to a device within this time are sent as one command.": "As alterações do HomeKit a um dispositivo dentro deste tempo são enviadas como um só comando.",
      "Host": "Anfitrião",
      "How commands reach the devices. Discovery always uses UDP.": "Como os comandos chegam aos dispositivos. A descoberta usa sempre UDP.",
      "In Use Threshold (watts)": "Limiar de utilização (watts)",
      "Leave out the devices whose MAC matches one of these patterns (* and ? allowed).": "Deixa de fora os dispositivos cujo MAC corresponde a um destes padrões (* e ? aceites).",
      "MAC pattern": "Padrão de MAC",
      "Model": "Modelo",
      "Models shown as a switch rather than an outlet (part of the model name). Empty takes HS200 and HS210.": "Modelos mostrados como interruptor em vez de tomada (parte do nome do modelo). Vazio usa HS200 e HS210.",
      "Name": "Nome",
      "Only add the devices whose MAC matches one of these patterns (* and ? allowed). Empty adds every device.": "Só adiciona os dispositivos cujo MAC corresponde a um destes padrões (* e ? aceites). Vazio adiciona todos os dispositivos.",
      "Plugin name as shown in the logs": "Nome do plugin tal como aparece no registo",
      "Plugs and switches": "Tomadas e interruptores",
      "Polling Interval (seconds)": "Intervalo de consulta (segundos)",
      "Port": "Porta",
      "Seconds a command may take. 0 waits as long as the connection lasts.": "Segundos que um comando pode demorar. 0 espera enquanto durar a ligação.",
      "Seconds between discovery broadcasts. Each one is also the state poll: every reply updates its device.": "Segundos entre duas difusões de descoberta. Cada uma serve também para ler o estado: cada resposta atualiza o seu dispositivo.",
      "Seconds between energy readings of the devices that meter it. 0 reads only when HomeKit asks.": "Segundos entre duas leituras de energia dos dispositivos que a medem. 0 só lê quando o HomeKit a pede.",
      "Send each device its commands at the port its discovery reply came from rather than 9999, for port forwarding.": "Envia os comandos a cada dispositivo na porta de onde veio a sua resposta de descoberta em vez da 9999, para um reencaminhamento de portas.",
      "Show volts, amperes, watts and kWh in the Eve app for the devices that meter energy.": "Mostra volts, amperes, watts e kWh na app Eve para os dispositivos que medem a energia.",
      "Switch Models": "Modelos de interruptor",
      "TCP": "TCP",
      "The device's IP address or host name": "O endereço IP ou o nome de anfitrião do dispositivo",
      "The kinds of device to add. None selected adds both.": "Os tipos de dispositivo a adicionar. Sem seleção, adiciona ambos.",
      "The local UDP port discovery listens on. 0 lets the system choose.": "A porta UDP local onde a descoberta escuta. 0 deixa o sistema escolher.",
      "The port the discovery packet goes to; 9999 by default": "A porta para onde vai o pacote de descoberta; 9999 por omissão",
      "This outlet shows In Use above this power. Empty takes the plugin's setting.": "Esta tomada está em utilização acima desta potência. Vazio usa a definição do plugin.",
      "Timeout (seconds)": "Tempo limite (segundos)",
      "Transport": "Transporte",
      "UDP": "UDP",
      "Where the discovery broadcast goes, such as a subnet's broadcast address.": "Para onde vai a difusão de descoberta, por exemplo o endereço de difusão de uma sub-rede.",
      "Write Window (milliseconds)": "Janela de escrita (milissegundos)"
    }
  }
}
"""#
}
