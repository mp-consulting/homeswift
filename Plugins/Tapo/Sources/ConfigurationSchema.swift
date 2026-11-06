// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension TapoPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "TapoP100",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "required": true,
        "default": "Tapo Smart Platform",
        "description": "Plugin name as shown in the logs"
      },
      "waitTimeUpdate": {
        "title": "Write Grouping (in milliseconds)",
        "type": "number",
        "required": false,
        "placeholder": 100,
        "minimum": 0,
        "description": "How long a change from HomeKit waits for the ones made with it, so a colour or a slider sends one request."
      },
      "videoProcessor": {
        "title": "Video Processor",
        "type": "string",
        "required": false,
        "placeholder": "ffmpeg",
        "description": "The FFmpeg the cameras' streams go through: a path, or ffmpeg on the path."
      },
      "devices": {
        "title": "Devices",
        "type": "array",
        "description": "Add a Tapo plug, bulb or battery camera by its address on the local network. Once saved, its settings are with its accessory.",
        "items": {
          "title": "Device",
          "type": "object",
          "properties": {
            "name": {
              "title": "Name",
              "type": "string",
              "required": true,
              "description": "The name in HomeKit. With the address, it is what the accessory is known by: changing either makes a new accessory."
            },
            "host": {
              "title": "IP Address",
              "type": "string",
              "required": true,
              "format": "hostname",
              "description": "The device's IP address or host name on the local network."
            },
            "type": {
              "title": "Type",
              "type": "string",
              "required": false,
              "default": "Plug",
              "oneOf": [
                {
                  "title": "Plug (P100, P105)",
                  "enum": [
                    "Plug"
                  ]
                },
                {
                  "title": "Plug with energy monitoring (P110)",
                  "enum": [
                    "PowerPlug"
                  ]
                },
                {
                  "title": "Dimmable bulb (L510E)",
                  "enum": [
                    "Light"
                  ]
                },
                {
                  "title": "White bulb (L520E)",
                  "enum": [
                    "WhiteLight"
                  ]
                },
                {
                  "title": "Colour bulb (L530E)",
                  "enum": [
                    "Colorlight"
                  ]
                },
                {
                  "title": "Battery camera, one lens",
                  "enum": [
                    "Camera"
                  ]
                },
                {
                  "title": "Battery camera, two lenses (C675D)",
                  "enum": [
                    "DualLensCamera"
                  ]
                }
              ],
              "description": "What the device is."
            },
            "resolution": {
              "title": "Camera Stream",
              "type": "string",
              "required": false,
              "default": "HD",
              "oneOf": [
                {
                  "title": "HD: every lens",
                  "enum": [
                    "HD"
                  ]
                },
                {
                  "title": "VGA: one 1280 × 720 stream (a C675D's tele lens)",
                  "enum": [
                    "VGA"
                  ]
                }
              ],
              "description": "Which of a camera's streams HomeKit gets."
            },
            "motion": {
              "title": "Motion Sensor",
              "type": "boolean",
              "required": false,
              "default": true,
              "description": "A camera's Motion Sensor, from the detections the camera reports to the TP-Link cloud: it never wakes the camera."
            },
            "cloudId": {
              "title": "Cloud Id",
              "type": "string",
              "required": false,
              "description": "The camera's id in the TP-Link cloud, when its name, model or MAC address do not find it (the log lists the account's cameras)."
            },
            "presetSwitches": {
              "title": "Preset switches",
              "type": "boolean",
              "required": false,
              "default": true,
              "description": "A \"Go to\" switch per pan and tilt preset of the camera (from the Tapo app), which turns it there, then turns itself off. It moves the camera only while its live view keeps it awake."
            },
            "patrolSwitches": {
              "title": "Patrol switches",
              "type": "boolean",
              "required": false,
              "default": true,
              "description": "Horizontal Patrol and Vertical Patrol switches: the camera sweeps along that axis until the switch is turned off or the camera sleeps. Only while its live view keeps it awake; a sweep keeps the motor running on the battery."
            },
            "standalone": {
              "title": "Standalone",
              "type": "boolean",
              "required": false,
              "default": false,
              "description": "Each lens on a HAP server of its own, added in the Home app on its own, rather than on the bridge. Switching it makes new accessories in the Home app."
            },
            "updateInterval": {
              "title": "Update Interval (in seconds)",
              "type": "number",
              "required": false,
              "placeholder": 10,
              "minimum": 1,
              "description": "How often the device is asked for its state."
            },
            "timeout": {
              "title": "Timeout (in seconds)",
              "type": "number",
              "required": false,
              "placeholder": 2,
              "minimum": 1,
              "description": "How long a request to a device on older firmware waits for its answer."
            }
          }
        }
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "host": {
        "title": "IP Address",
        "type": "string",
        "format": "hostname",
        "description": "The device's IP address or host name on the local network. Changing it keeps the accessory."
      },
      "type": {
        "title": "Type",
        "type": "string",
        "default": "Plug",
        "oneOf": [
          {
            "title": "Plug (P100, P105)",
            "enum": [
              "Plug"
            ]
          },
          {
            "title": "Plug with energy monitoring (P110)",
            "enum": [
              "PowerPlug"
            ]
          },
          {
            "title": "Dimmable bulb (L510E)",
            "enum": [
              "Light"
            ]
          },
          {
            "title": "White bulb (L520E)",
            "enum": [
              "WhiteLight"
            ]
          },
          {
            "title": "Colour bulb (L530E)",
            "enum": [
              "Colorlight"
            ]
          },
          {
            "title": "Battery camera, one lens",
            "enum": [
              "Camera"
            ]
          },
          {
            "title": "Battery camera, two lenses (C675D)",
            "enum": [
              "DualLensCamera"
            ]
          }
        ],
        "description": "What the device is."
      },
      "resolution": {
        "title": "Camera Stream",
        "type": "string",
        "default": "HD",
        "oneOf": [
          {
            "title": "HD: every lens",
            "enum": [
              "HD"
            ]
          },
          {
            "title": "VGA: one 1280 × 720 stream (a C675D's tele lens)",
            "enum": [
              "VGA"
            ]
          }
        ],
        "description": "Which of a camera's streams HomeKit gets."
      },
      "motion": {
        "title": "Motion Sensor",
        "type": "boolean",
        "default": true,
        "description": "A camera's Motion Sensor, from the detections the camera reports to the TP-Link cloud: it never wakes the camera."
      },
      "cloudId": {
        "title": "Cloud Id",
        "type": "string",
        "description": "The camera's id in the TP-Link cloud, when its name, model or MAC address do not find it (the log lists the account's cameras)."
      },
      "presetSwitches": {
        "title": "Preset switches",
        "type": "boolean",
        "default": true,
        "description": "A \"Go to\" switch per pan and tilt preset of the camera (from the Tapo app), which turns it there, then turns itself off. It moves the camera only while its live view keeps it awake."
      },
      "patrolSwitches": {
        "title": "Patrol switches",
        "type": "boolean",
        "default": true,
        "description": "Horizontal Patrol and Vertical Patrol switches: the camera sweeps along that axis until the switch is turned off or the camera sleeps. Only while its live view keeps it awake; a sweep keeps the motor running on the battery."
      },
      "standalone": {
        "title": "Standalone",
        "type": "boolean",
        "default": false,
        "description": "Each lens on a HAP server of its own, added in the Home app on its own, rather than on the bridge. Switching it makes new accessories in the Home app."
      },
      "updateInterval": {
        "title": "Update Interval (in seconds)",
        "type": "number",
        "placeholder": 10,
        "minimum": 1,
        "description": "How often the device is asked for its state."
      },
      "timeout": {
        "title": "Timeout (in seconds)",
        "type": "number",
        "placeholder": 2,
        "minimum": 1,
        "description": "How long a request to a device on older firmware waits for its answer."
      }
    }
  },
  "i18n": {
    "fr": {
      "A \"Go to\" switch per pan and tilt preset of the camera (from the Tapo app), which turns it there, then turns itself off. It moves the camera only while its live view keeps it awake.": "Un interrupteur « Aller à » par position enregistrée de la caméra (depuis l'app Tapo), qui l'y tourne puis s'éteint seul. Il ne bouge la caméra que pendant que sa vue en direct la garde éveillée.",
      "A camera's Motion Sensor, from the detections the camera reports to the TP-Link cloud: it never wakes the camera.": "Le détecteur de mouvement d'une caméra, d'après les détections qu'elle signale au cloud TP-Link : il ne réveille jamais la caméra.",
      "Add a Tapo plug, bulb or battery camera by its address on the local network. Once saved, its settings are with its accessory.": "Ajoutez une prise, une ampoule ou une caméra sur batterie Tapo par son adresse sur le réseau local. Une fois enregistrés, ses réglages sont avec son accessoire.",
      "Battery camera, one lens": "Caméra sur batterie, un objectif",
      "Battery camera, two lenses (C675D)": "Caméra sur batterie, deux objectifs (C675D)",
      "Camera Stream": "Flux de la caméra",
      "Cloud Id": "Identifiant cloud",
      "Colour bulb (L530E)": "Ampoule couleur (L530E)",
      "Device": "Appareil",
      "Devices": "Appareils",
      "Dimmable bulb (L510E)": "Ampoule à intensité variable (L510E)",
      "Each lens on a HAP server of its own, added in the Home app on its own, rather than on the bridge. Switching it makes new accessories in the Home app.": "Chaque objectif sur un serveur HAP à lui, ajouté seul dans l'app Maison, plutôt que sur le pont. Le changer crée de nouveaux accessoires dans l'app Maison.",
      "HD: every lens": "HD : tous les objectifs",
      "Horizontal Patrol and Vertical Patrol switches: the camera sweeps along that axis until the switch is turned off or the camera sleeps. Only while its live view keeps it awake; a sweep keeps the motor running on the battery.": "Des interrupteurs Patrouille horizontale et Patrouille verticale : la caméra balaie cet axe jusqu'à ce que l'interrupteur soit éteint ou qu'elle se mette en veille. Seulement pendant que sa vue en direct la garde éveillée ; un balayage fait tourner le moteur sur la batterie.",
      "How long a change from HomeKit waits for the ones made with it, so a colour or a slider sends one request.": "Le temps qu'un changement venu de HomeKit attend ceux faits en même temps, pour qu'une couleur ou un curseur n'envoie qu'une requête.",
      "How long a request to a device on older firmware waits for its answer.": "Le temps qu'une requête à un appareil au firmware ancien attend sa réponse.",
      "How often the device is asked for its state.": "La fréquence à laquelle l'état de l'appareil est demandé.",
      "IP Address": "Adresse IP",
      "Motion Sensor": "Détecteur de mouvement",
      "Name": "Nom",
      "Patrol switches": "Interrupteurs de patrouille",
      "Plug (P100, P105)": "Prise (P100, P105)",
      "Plug with energy monitoring (P110)": "Prise avec suivi de la consommation (P110)",
      "Plugin name as shown in the logs": "Nom du plugin tel qu'affiché dans les journaux",
      "Preset switches": "Interrupteurs de positions",
      "Standalone": "Autonome",
      "The FFmpeg the cameras' streams go through: a path, or ffmpeg on the path.": "Le FFmpeg par lequel passent les flux des caméras : un chemin, ou ffmpeg dans le PATH.",
      "The camera's id in the TP-Link cloud, when its name, model or MAC address do not find it (the log lists the account's cameras).": "L'identifiant de la caméra dans le cloud TP-Link, quand son nom, son modèle ou son adresse MAC ne la trouvent pas (le journal liste les caméras du compte).",
      "The device's IP address or host name on the local network.": "L'adresse IP ou le nom d'hôte de l'appareil sur le réseau local.",
      "The device's IP address or host name on the local network. Changing it keeps the accessory.": "L'adresse IP ou le nom d'hôte de l'appareil sur le réseau local. La changer garde l'accessoire.",
      "The name in HomeKit. With the address, it is what the accessory is known by: changing either makes a new accessory.": "Le nom dans HomeKit. Avec l'adresse, c'est ce qui identifie l'accessoire : changer l'un ou l'autre crée un nouvel accessoire.",
      "Timeout (in seconds)": "Délai d'attente (en secondes)",
      "Type": "Type",
      "Update Interval (in seconds)": "Intervalle de mise à jour (en secondes)",
      "VGA: one 1280 × 720 stream (a C675D's tele lens)": "VGA : un flux 1280 × 720 (le téléobjectif d'une C675D)",
      "Video Processor": "Processeur vidéo",
      "What the device is.": "Le type d'appareil.",
      "Which of a camera's streams HomeKit gets.": "Le flux de la caméra que reçoit HomeKit.",
      "White bulb (L520E)": "Ampoule blanche (L520E)",
      "Write Grouping (in milliseconds)": "Regroupement des écritures (en millisecondes)"
    },
    "es": {
      "A \"Go to\" switch per pan and tilt preset of the camera (from the Tapo app), which turns it there, then turns itself off. It moves the camera only while its live view keeps it awake.": "Un interruptor «Ir a» por cada posición guardada de la cámara (desde la app Tapo), que la gira hacia ella y luego se apaga solo. Solo mueve la cámara mientras su vista en directo la mantiene despierta.",
      "A camera's Motion Sensor, from the detections the camera reports to the TP-Link cloud: it never wakes the camera.": "El sensor de movimiento de una cámara, a partir de las detecciones que la cámara comunica a la nube de TP-Link: nunca despierta la cámara.",
      "Add a Tapo plug, bulb or battery camera by its address on the local network. Once saved, its settings are with its accessory.": "Añade un enchufe, una bombilla o una cámara de batería Tapo por su dirección en la red local. Una vez guardado, sus ajustes están con su accesorio.",
      "Battery camera, one lens": "Cámara de batería, un objetivo",
      "Battery camera, two lenses (C675D)": "Cámara de batería, dos objetivos (C675D)",
      "Camera Stream": "Flujo de la cámara",
      "Cloud Id": "Id. en la nube",
      "Colour bulb (L530E)": "Bombilla de color (L530E)",
      "Device": "Dispositivo",
      "Devices": "Dispositivos",
      "Dimmable bulb (L510E)": "Bombilla regulable (L510E)",
      "Each lens on a HAP server of its own, added in the Home app on its own, rather than on the bridge. Switching it makes new accessories in the Home app.": "Cada objetivo en un servidor HAP propio, que se añade por separado en la app Casa, en lugar de en el puente. Cambiarlo crea accesorios nuevos en la app Casa.",
      "HD: every lens": "HD: todos los objetivos",
      "Horizontal Patrol and Vertical Patrol switches: the camera sweeps along that axis until the switch is turned off or the camera sleeps. Only while its live view keeps it awake; a sweep keeps the motor running on the battery.": "Interruptores Patrulla horizontal y Patrulla vertical: la cámara recorre ese eje hasta que se apaga el interruptor o la cámara entra en reposo. Solo mientras su vista en directo la mantiene despierta; un recorrido mantiene el motor en marcha con la batería.",
      "How long a change from HomeKit waits for the ones made with it, so a colour or a slider sends one request.": "Cuánto espera un cambio desde HomeKit a los que se hacen con él, para que un color o un control deslizante envíe una sola solicitud.",
      "How long a request to a device on older firmware waits for its answer.": "Cuánto espera una solicitud a un dispositivo con firmware antiguo su respuesta.",
      "How often the device is asked for its state.": "Con qué frecuencia se pide al dispositivo su estado.",
      "IP Address": "Dirección IP",
      "Motion Sensor": "Sensor de movimiento",
      "Name": "Nombre",
      "Patrol switches": "Interruptores de patrulla",
      "Plug (P100, P105)": "Enchufe (P100, P105)",
      "Plug with energy monitoring (P110)": "Enchufe con medición de consumo (P110)",
      "Plugin name as shown in the logs": "Nombre del plugin tal como aparece en los registros",
      "Preset switches": "Interruptores de posiciones",
      "Standalone": "Independiente",
      "The FFmpeg the cameras' streams go through: a path, or ffmpeg on the path.": "El FFmpeg por el que pasan los flujos de las cámaras: una ruta, o ffmpeg en el PATH.",
      "The camera's id in the TP-Link cloud, when its name, model or MAC address do not find it (the log lists the account's cameras).": "El id. de la cámara en la nube de TP-Link, cuando su nombre, su modelo o su dirección MAC no la encuentran (el registro enumera las cámaras de la cuenta).",
      "The device's IP address or host name on the local network.": "La dirección IP o el nombre de host del dispositivo en la red local.",
      "The device's IP address or host name on the local network. Changing it keeps the accessory.": "La dirección IP o el nombre de host del dispositivo en la red local. Cambiarla conserva el accesorio.",
      "The name in HomeKit. With the address, it is what the accessory is known by: changing either makes a new accessory.": "El nombre en HomeKit. Junto con la dirección, es lo que identifica al accesorio: cambiar cualquiera de los dos crea un accesorio nuevo.",
      "Timeout (in seconds)": "Tiempo de espera (en segundos)",
      "Type": "Tipo",
      "Update Interval (in seconds)": "Intervalo de actualización (en segundos)",
      "VGA: one 1280 × 720 stream (a C675D's tele lens)": "VGA: un flujo de 1280 × 720 (el teleobjetivo de una C675D)",
      "Video Processor": "Procesador de vídeo",
      "What the device is.": "Qué es el dispositivo.",
      "Which of a camera's streams HomeKit gets.": "Qué flujo de la cámara recibe HomeKit.",
      "White bulb (L520E)": "Bombilla blanca (L520E)",
      "Write Grouping (in milliseconds)": "Agrupación de escrituras (en milisegundos)"
    },
    "pt": {
      "A \"Go to\" switch per pan and tilt preset of the camera (from the Tapo app), which turns it there, then turns itself off. It moves the camera only while its live view keeps it awake.": "Um interruptor «Ir para» por cada posição guardada da câmara (da app Tapo), que a vira para lá e depois se desliga sozinho. Só move a câmara enquanto a vista em direto a mantém acordada.",
      "A camera's Motion Sensor, from the detections the camera reports to the TP-Link cloud: it never wakes the camera.": "O sensor de movimento de uma câmara, a partir das deteções que a câmara comunica à nuvem da TP-Link: nunca acorda a câmara.",
      "Add a Tapo plug, bulb or battery camera by its address on the local network. Once saved, its settings are with its accessory.": "Adicione uma tomada, lâmpada ou câmara a bateria Tapo pelo seu endereço na rede local. Depois de guardada, as suas definições ficam com o seu acessório.",
      "Battery camera, one lens": "Câmara a bateria, uma lente",
      "Battery camera, two lenses (C675D)": "Câmara a bateria, duas lentes (C675D)",
      "Camera Stream": "Fluxo da câmara",
      "Cloud Id": "Id. na nuvem",
      "Colour bulb (L530E)": "Lâmpada de cor (L530E)",
      "Device": "Dispositivo",
      "Devices": "Dispositivos",
      "Dimmable bulb (L510E)": "Lâmpada regulável (L510E)",
      "Each lens on a HAP server of its own, added in the Home app on its own, rather than on the bridge. Switching it makes new accessories in the Home app.": "Cada lente num servidor HAP próprio, adicionada à parte na app Casa, em vez de na ponte. Mudá-lo cria novos acessórios na app Casa.",
      "HD: every lens": "HD: todas as lentes",
      "Horizontal Patrol and Vertical Patrol switches: the camera sweeps along that axis until the switch is turned off or the camera sleeps. Only while its live view keeps it awake; a sweep keeps the motor running on the battery.": "Interruptores Patrulha horizontal e Patrulha vertical: a câmara percorre esse eixo até o interruptor ser desligado ou a câmara adormecer. Só enquanto a vista em direto a mantém acordada; um percurso mantém o motor a funcionar com a bateria.",
      "How long a change from HomeKit waits for the ones made with it, so a colour or a slider sends one request.": "Quanto tempo uma alteração vinda do HomeKit espera pelas feitas com ela, para que uma cor ou um controlo deslizante envie um só pedido.",
      "How long a request to a device on older firmware waits for its answer.": "Quanto tempo um pedido a um dispositivo com firmware antigo espera pela resposta.",
      "How often the device is asked for its state.": "Com que frequência se pede o estado ao dispositivo.",
      "IP Address": "Endereço IP",
      "Motion Sensor": "Sensor de movimento",
      "Name": "Nome",
      "Patrol switches": "Interruptores de patrulha",
      "Plug (P100, P105)": "Tomada (P100, P105)",
      "Plug with energy monitoring (P110)": "Tomada com medição de consumo (P110)",
      "Plugin name as shown in the logs": "Nome do plugin tal como aparece nos registos",
      "Preset switches": "Interruptores de posições",
      "Standalone": "Autónoma",
      "The FFmpeg the cameras' streams go through: a path, or ffmpeg on the path.": "O FFmpeg por onde passam os fluxos das câmaras: um caminho, ou ffmpeg no PATH.",
      "The camera's id in the TP-Link cloud, when its name, model or MAC address do not find it (the log lists the account's cameras).": "O id. da câmara na nuvem da TP-Link, quando o nome, o modelo ou o endereço MAC não a encontram (o registo lista as câmaras da conta).",
      "The device's IP address or host name on the local network.": "O endereço IP ou o nome de anfitrião do dispositivo na rede local.",
      "The device's IP address or host name on the local network. Changing it keeps the accessory.": "O endereço IP ou o nome de anfitrião do dispositivo na rede local. Mudá-lo mantém o acessório.",
      "The name in HomeKit. With the address, it is what the accessory is known by: changing either makes a new accessory.": "O nome no HomeKit. Com o endereço, é o que identifica o acessório: mudar qualquer um dos dois cria um novo acessório.",
      "Timeout (in seconds)": "Tempo limite (em segundos)",
      "Type": "Tipo",
      "Update Interval (in seconds)": "Intervalo de atualização (em segundos)",
      "VGA: one 1280 × 720 stream (a C675D's tele lens)": "VGA: um fluxo de 1280 × 720 (a teleobjetiva de uma C675D)",
      "Video Processor": "Processador de vídeo",
      "What the device is.": "O que é o dispositivo.",
      "Which of a camera's streams HomeKit gets.": "Que fluxo da câmara o HomeKit recebe.",
      "White bulb (L520E)": "Lâmpada branca (L520E)",
      "Write Grouping (in milliseconds)": "Agrupamento de escritas (em milissegundos)"
    }
  }
}
"""#
}
