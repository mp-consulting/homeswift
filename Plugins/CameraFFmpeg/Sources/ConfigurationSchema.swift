// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension CameraFFmpegPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "Camera-ffmpeg",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "description": "Plugin name as shown in the logs",
        "required": true,
        "default": "FFmpeg Cameras"
      },
      "videoProcessor": {
        "title": "Video Processor",
        "type": "string",
        "description": "The FFmpeg executable for every camera: a path, or a name found in PATH. Empty uses ffmpeg.",
        "placeholder": "ffmpeg"
      },
      "mqtt": {
        "title": "MQTT Broker",
        "type": "string",
        "description": "Host name or IP address of the MQTT broker. Empty turns MQTT off."
      },
      "portmqtt": {
        "title": "MQTT Port",
        "type": "integer",
        "description": "The broker's port. Empty uses 1883.",
        "placeholder": 1883,
        "minimum": 1,
        "maximum": 65535
      },
      "tlsmqtt": {
        "title": "Use TLS",
        "type": "boolean",
        "description": "Connect to the broker over TLS (mqtts), checking its certificate."
      },
      "usermqtt": {
        "title": "MQTT Username",
        "type": "string",
        "description": "The username to sign in to the broker with, when it asks for one. Its password is set on Add accessories, and kept in the bridge's vault."
      },
      "porthttp": {
        "title": "HTTP Port",
        "type": "integer",
        "description": "Port of the HTTP API that triggers motion and doorbells: /motion?Camera, /motion/reset?Camera and /doorbell?Camera. Empty turns it off.",
        "minimum": 1,
        "maximum": 65535
      },
      "localhttp": {
        "title": "Localhost Only",
        "type": "boolean",
        "description": "The HTTP API listens on this computer's loopback address only, out of the network's reach."
      },
      "cameras": {
        "title": "Cameras",
        "type": "array",
        "description": "The cameras, each an accessory of its own in the Home app, added with the bridge's set-up code.",
        "items": {
          "title": "Camera",
          "type": "object",
          "properties": {
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The camera's name in HomeKit. It identifies the camera: renaming it here makes a new accessory.",
              "required": true
            },
            "manufacturer": {
              "title": "Manufacturer",
              "type": "string",
              "description": "Shown in the accessory's information. Empty uses Homebridge."
            },
            "model": {
              "title": "Model",
              "type": "string",
              "description": "Shown in the accessory's information. Empty uses Camera FFmpeg."
            },
            "serialNumber": {
              "title": "Serial Number",
              "type": "string",
              "description": "Shown in the accessory's information. Empty uses SerialNumber."
            },
            "firmwareRevision": {
              "title": "Firmware Revision",
              "type": "string",
              "description": "Shown in the accessory's information. Empty uses the bridge's version."
            },
            "motion": {
              "title": "Motion Sensor",
              "type": "boolean",
              "description": "Add a motion sensor, triggered over MQTT, HTTP or its switch."
            },
            "doorbell": {
              "title": "Doorbell",
              "type": "boolean",
              "description": "Add a doorbell, rung over MQTT, HTTP or its switch."
            },
            "switches": {
              "title": "Trigger Switches",
              "type": "boolean",
              "description": "Add switches in HomeKit that trigger the motion sensor and the doorbell."
            },
            "motionTimeout": {
              "title": "Motion Timeout (seconds)",
              "type": "integer",
              "description": "How long motion stays detected after a trigger, and the doorbell switch stays on. 0 keeps motion on until it is reset. Empty uses 1.",
              "placeholder": 1,
              "minimum": 0
            },
            "motionDoorbell": {
              "title": "Motion Rings the Doorbell",
              "type": "boolean",
              "description": "A motion trigger also rings the doorbell."
            },
            "videoConfig": {
              "title": "Video",
              "type": "object",
              "description": "How FFmpeg reads the camera and what it sends to HomeKit.",
              "properties": {
                "source": {
                  "title": "Source",
                  "type": "string",
                  "description": "FFmpeg's input options, such as -i rtsp://user:password@address:554/stream. Options may come before -i (-rtsp_transport tcp -i …).",
                  "required": true
                },
                "stillImageSource": {
                  "title": "Still Image Source",
                  "type": "string",
                  "description": "FFmpeg's input options for snapshots, written as Source. Empty uses Source."
                },
                "returnAudioTarget": {
                  "title": "Two-way Audio Target (experimental)",
                  "type": "string",
                  "description": "FFmpeg's output options for the audio HomeKit sends back to the camera, such as -acodec libfdk_aac -ar 16000 -b:a 24k -ac 1 -f adts udp://address:port. Turns two-way audio on."
                },
                "maxStreams": {
                  "title": "Maximum Streams",
                  "type": "integer",
                  "description": "How many live streams may run at once. Empty uses 2.",
                  "placeholder": 2,
                  "minimum": 1
                },
                "maxWidth": {
                  "title": "Maximum Width",
                  "type": "integer",
                  "description": "The widest stream sent, in pixels. 0 keeps the source's width.",
                  "minimum": 0,
                  "multipleOf": 2
                },
                "maxHeight": {
                  "title": "Maximum Height",
                  "type": "integer",
                  "description": "The tallest stream sent, in pixels. 0 keeps the source's height.",
                  "minimum": 0,
                  "multipleOf": 2
                },
                "maxFPS": {
                  "title": "Maximum Frame Rate",
                  "type": "integer",
                  "description": "The most frames per second sent. 0 keeps the source's frame rate.",
                  "minimum": 0
                },
                "maxBitrate": {
                  "title": "Maximum Bitrate (kbit/s)",
                  "type": "integer",
                  "description": "The highest video bitrate sent. 0 sets none.",
                  "minimum": 0
                },
                "forceMax": {
                  "title": "Force Maximums",
                  "type": "boolean",
                  "description": "Always send the maximums above, even when HomeKit asks for less."
                },
                "vcodec": {
                  "title": "Video Codec",
                  "type": "string",
                  "description": "The FFmpeg video encoder, such as libx264, h264_videotoolbox, h264_v4l2m2m or copy (copy sends the source as it is, without filters). Empty uses libx264.",
                  "placeholder": "libx264"
                },
                "packetSize": {
                  "title": "Packet Size",
                  "type": "integer",
                  "description": "The video packets' size in bytes, a multiple of 188. Empty uses 1316.",
                  "placeholder": 1316,
                  "multipleOf": 188
                },
                "videoFilter": {
                  "title": "Video Filters",
                  "type": "string",
                  "description": "Extra FFmpeg video filters, separated by commas, before the scaling ones. A none among them leaves the scaling out."
                },
                "encoderOptions": {
                  "title": "Encoder Options",
                  "type": "string",
                  "description": "Extra options for the video encoder. Empty uses -preset ultrafast -tune zerolatency with libx264."
                },
                "mapvideo": {
                  "title": "Video Stream",
                  "type": "string",
                  "description": "The FFmpeg stream sent as video (its -map), such as 0:0."
                },
                "mapaudio": {
                  "title": "Audio Stream",
                  "type": "string",
                  "description": "The FFmpeg stream sent as audio (its -map), such as 0:1."
                },
                "audio": {
                  "title": "Audio",
                  "type": "boolean",
                  "description": "Send the camera's audio to HomeKit. Needs an FFmpeg with libfdk_aac."
                },
                "debug": {
                  "title": "Debug Logging",
                  "type": "boolean",
                  "description": "Log FFmpeg's output and the plugin's details for this camera."
                },
                "debugReturn": {
                  "title": "Debug Two-way Audio",
                  "type": "boolean",
                  "description": "Log FFmpeg's output for the two-way audio."
                },
                "recording": {
                  "title": "HomeKit Secure Video",
                  "type": "boolean",
                  "description": "Let a home hub record this camera's events in iCloud."
                },
                "prebuffer": {
                  "title": "Prebuffer",
                  "type": "boolean",
                  "description": "Keep the last seconds of video ready, so recordings start before the event. Only with HomeKit Secure Video; FFmpeg then reads the camera all the time."
                }
              }
            },
            "mqtt": {
              "title": "MQTT Topics",
              "type": "object",
              "description": "The MQTT messages that trigger this camera, with the MQTT Broker set.",
              "properties": {
                "motionTopic": {
                  "title": "Motion Topic",
                  "type": "string",
                  "description": "The topic whose message triggers motion."
                },
                "motionMessage": {
                  "title": "Motion Message",
                  "type": "string",
                  "description": "The exact message that triggers motion. Empty is the camera's name."
                },
                "motionResetTopic": {
                  "title": "Motion Reset Topic",
                  "type": "string",
                  "description": "The topic whose message resets motion."
                },
                "motionResetMessage": {
                  "title": "Motion Reset Message",
                  "type": "string",
                  "description": "The exact message that resets motion. Empty is the camera's name."
                },
                "doorbellTopic": {
                  "title": "Doorbell Topic",
                  "type": "string",
                  "description": "The topic whose message rings the doorbell."
                },
                "doorbellMessage": {
                  "title": "Doorbell Message",
                  "type": "string",
                  "description": "The exact message that rings the doorbell. Empty is the camera's name."
                }
              }
            }
          }
        }
      }
    }
  },
  "accessorySchema": {
    "properties": {}
  },
  "i18n": {
    "fr": {
      "A motion trigger also rings the doorbell.": "Un déclenchement du mouvement fait aussi sonner la sonnette.",
      "Add a doorbell, rung over MQTT, HTTP or its switch.": "Ajouter une sonnette, sonnée par MQTT, HTTP ou son interrupteur.",
      "Add a motion sensor, triggered over MQTT, HTTP or its switch.": "Ajouter un capteur de mouvement, déclenché par MQTT, HTTP ou son interrupteur.",
      "Add switches in HomeKit that trigger the motion sensor and the doorbell.": "Ajouter dans HomeKit des interrupteurs qui déclenchent le capteur de mouvement et la sonnette.",
      "Always send the maximums above, even when HomeKit asks for less.": "Toujours envoyer les maximums ci-dessus, même quand HomeKit demande moins.",
      "Audio": "Audio",
      "Audio Stream": "Flux audio",
      "Camera": "Caméra",
      "Cameras": "Caméras",
      "Connect to the broker over TLS (mqtts), checking its certificate.": "Se connecter au broker en TLS (mqtts), en vérifiant son certificat.",
      "Debug Logging": "Journal de débogage",
      "Debug Two-way Audio": "Déboguer l'audio bidirectionnel",
      "Doorbell": "Sonnette",
      "Doorbell Message": "Message de la sonnette",
      "Doorbell Topic": "Topic de la sonnette",
      "Encoder Options": "Options de l'encodeur",
      "Extra FFmpeg video filters, separated by commas, before the scaling ones. A none among them leaves the scaling out.": "Des filtres vidéo FFmpeg en plus, séparés par des virgules, avant ceux de mise à l'échelle. Un none parmi eux retire la mise à l'échelle.",
      "Extra options for the video encoder. Empty uses -preset ultrafast -tune zerolatency with libx264.": "Des options en plus pour l'encodeur vidéo. Vide, -preset ultrafast -tune zerolatency est utilisé avec libx264.",
      "FFmpeg's input options for snapshots, written as Source. Empty uses Source.": "Les options d'entrée de FFmpeg pour les instantanés, écrites comme Source. Vide, Source est utilisée.",
      "FFmpeg's input options, such as -i rtsp://user:password@address:554/stream. Options may come before -i (-rtsp_transport tcp -i …).": "Les options d'entrée de FFmpeg, comme -i rtsp://user:password@address:554/stream. Des options peuvent précéder -i (-rtsp_transport tcp -i …).",
      "FFmpeg's output options for the audio HomeKit sends back to the camera, such as -acodec libfdk_aac -ar 16000 -b:a 24k -ac 1 -f adts udp://address:port. Turns two-way audio on.": "Les options de sortie de FFmpeg pour l'audio que HomeKit renvoie à la caméra, comme -acodec libfdk_aac -ar 16000 -b:a 24k -ac 1 -f adts udp://address:port. Active l'audio bidirectionnel.",
      "Firmware Revision": "Version du firmware",
      "Force Maximums": "Forcer les maximums",
      "HTTP Port": "Port HTTP",
      "HomeKit Secure Video": "HomeKit Secure Video",
      "Host name or IP address of the MQTT broker. Empty turns MQTT off.": "Nom d'hôte ou adresse IP du broker MQTT. Vide, MQTT est désactivé.",
      "How FFmpeg reads the camera and what it sends to HomeKit.": "Comment FFmpeg lit la caméra et ce qu'il envoie à HomeKit.",
      "How long motion stays detected after a trigger, and the doorbell switch stays on. 0 keeps motion on until it is reset. Empty uses 1.": "Combien de temps le mouvement reste détecté après un déclenchement, et l'interrupteur de la sonnette allumé. 0 garde le mouvement jusqu'à sa fin. Vide, 1 est utilisé.",
      "How many live streams may run at once. Empty uses 2.": "Le nombre de flux en direct simultanés. Vide, 2 est utilisé.",
      "Keep the last seconds of video ready, so recordings start before the event. Only with HomeKit Secure Video; FFmpeg then reads the camera all the time.": "Garder les dernières secondes de vidéo, pour que les enregistrements commencent avant l'événement. Seulement avec HomeKit Secure Video ; FFmpeg lit alors la caméra en permanence.",
      "Let a home hub record this camera's events in iCloud.": "Laisser un concentrateur domestique enregistrer les événements de cette caméra dans iCloud.",
      "Localhost Only": "Localhost uniquement",
      "Log FFmpeg's output and the plugin's details for this camera.": "Journaliser la sortie de FFmpeg et les détails du plugin pour cette caméra.",
      "Log FFmpeg's output for the two-way audio.": "Journaliser la sortie de FFmpeg pour l'audio bidirectionnel.",
      "MQTT Broker": "Broker MQTT",
      "MQTT Port": "Port MQTT",
      "MQTT Topics": "Topics MQTT",
      "MQTT Username": "Nom d'utilisateur MQTT",
      "Manufacturer": "Fabricant",
      "Maximum Bitrate (kbit/s)": "Débit maximum (kbit/s)",
      "Maximum Frame Rate": "Fréquence d'images maximum",
      "Maximum Height": "Hauteur maximum",
      "Maximum Streams": "Flux maximum",
      "Maximum Width": "Largeur maximum",
      "Model": "Modèle",
      "Motion Message": "Message du mouvement",
      "Motion Reset Message": "Message de fin du mouvement",
      "Motion Reset Topic": "Topic de fin du mouvement",
      "Motion Rings the Doorbell": "Le mouvement fait sonner la sonnette",
      "Motion Sensor": "Capteur de mouvement",
      "Motion Timeout (seconds)": "Durée du mouvement (secondes)",
      "Motion Topic": "Topic du mouvement",
      "Name": "Nom",
      "Packet Size": "Taille des paquets",
      "Plugin name as shown in the logs": "Nom du plugin dans les journaux",
      "Port of the HTTP API that triggers motion and doorbells: /motion?Camera, /motion/reset?Camera and /doorbell?Camera. Empty turns it off.": "Port de l'API HTTP qui déclenche les mouvements et les sonnettes : /motion?Caméra, /motion/reset?Caméra et /doorbell?Caméra. Vide, elle est désactivée.",
      "Prebuffer": "Pré-enregistrement",
      "Send the camera's audio to HomeKit. Needs an FFmpeg with libfdk_aac.": "Envoyer l'audio de la caméra à HomeKit. Demande un FFmpeg avec libfdk_aac.",
      "Serial Number": "Numéro de série",
      "Shown in the accessory's information. Empty uses Camera FFmpeg.": "Affiché dans les informations de l'accessoire. Vide, Camera FFmpeg est utilisé.",
      "Shown in the accessory's information. Empty uses Homebridge.": "Affiché dans les informations de l'accessoire. Vide, Homebridge est utilisé.",
      "Shown in the accessory's information. Empty uses SerialNumber.": "Affiché dans les informations de l'accessoire. Vide, SerialNumber est utilisé.",
      "Shown in the accessory's information. Empty uses the bridge's version.": "Affiché dans les informations de l'accessoire. Vide, la version du pont est utilisée.",
      "Source": "Source",
      "Still Image Source": "Source des instantanés",
      "The FFmpeg executable for every camera: a path, or a name found in PATH. Empty uses ffmpeg.": "L'exécutable FFmpeg de toutes les caméras : un chemin, ou un nom trouvé dans PATH. Vide, ffmpeg est utilisé.",
      "The FFmpeg stream sent as audio (its -map), such as 0:1.": "Le flux FFmpeg envoyé comme audio (son -map), comme 0:1.",
      "The FFmpeg stream sent as video (its -map), such as 0:0.": "Le flux FFmpeg envoyé comme vidéo (son -map), comme 0:0.",
      "The FFmpeg video encoder, such as libx264, h264_videotoolbox, h264_v4l2m2m or copy (copy sends the source as it is, without filters). Empty uses libx264.": "L'encodeur vidéo de FFmpeg, comme libx264, h264_videotoolbox, h264_v4l2m2m ou copy (copy envoie la source telle quelle, sans filtres). Vide, libx264 est utilisé.",
      "The HTTP API listens on this computer's loopback address only, out of the network's reach.": "L'API HTTP n'écoute que sur l'adresse de bouclage de cet ordinateur, hors de portée du réseau.",
      "The MQTT messages that trigger this camera, with the MQTT Broker set.": "Les messages MQTT qui déclenchent cette caméra, avec le broker MQTT renseigné.",
      "The broker's port. Empty uses 1883.": "Le port du broker. Vide, 1883 est utilisé.",
      "The camera's name in HomeKit. It identifies the camera: renaming it here makes a new accessory.": "Le nom de la caméra dans HomeKit. Il l'identifie : la renommer ici crée un nouvel accessoire.",
      "The cameras, each an accessory of its own in the Home app, added with the bridge's set-up code.": "Les caméras, chacune un accessoire à part dans l'app Maison, ajouté avec le code de configuration du pont.",
      "The exact message that resets motion. Empty is the camera's name.": "Le message exact qui met fin au mouvement. Vide, c'est le nom de la caméra.",
      "The exact message that rings the doorbell. Empty is the camera's name.": "Le message exact qui fait sonner la sonnette. Vide, c'est le nom de la caméra.",
      "The exact message that triggers motion. Empty is the camera's name.": "Le message exact qui déclenche un mouvement. Vide, c'est le nom de la caméra.",
      "The highest video bitrate sent. 0 sets none.": "Le débit vidéo maximum. 0 n'en fixe aucun.",
      "The most frames per second sent. 0 keeps the source's frame rate.": "Le nombre maximum d'images par seconde. 0 garde celui de la source.",
      "The tallest stream sent, in pixels. 0 keeps the source's height.": "La hauteur maximum du flux, en pixels. 0 garde celle de la source.",
      "The topic whose message resets motion.": "Le topic dont le message met fin au mouvement.",
      "The topic whose message rings the doorbell.": "Le topic dont le message fait sonner la sonnette.",
      "The topic whose message triggers motion.": "Le topic dont le message déclenche un mouvement.",
      "The username to sign in to the broker with, when it asks for one. Its password is set on Add accessories, and kept in the bridge's vault.": "Le nom d'utilisateur pour se connecter au broker, s'il en demande un. Son mot de passe se saisit dans Ajouter des accessoires, et reste dans le coffre du pont.",
      "The video packets' size in bytes, a multiple of 188. Empty uses 1316.": "La taille des paquets vidéo en octets, un multiple de 188. Vide, 1316 est utilisé.",
      "The widest stream sent, in pixels. 0 keeps the source's width.": "La largeur maximum du flux, en pixels. 0 garde celle de la source.",
      "Trigger Switches": "Interrupteurs de déclenchement",
      "Two-way Audio Target (experimental)": "Cible de l'audio bidirectionnel (expérimental)",
      "Use TLS": "Utiliser TLS",
      "Video": "Vidéo",
      "Video Codec": "Codec vidéo",
      "Video Filters": "Filtres vidéo",
      "Video Processor": "Processeur vidéo",
      "Video Stream": "Flux vidéo"
    },
    "es": {
      "A motion trigger also rings the doorbell.": "Una activación del movimiento también hace sonar el timbre.",
      "Add a doorbell, rung over MQTT, HTTP or its switch.": "Añadir un timbre, que suena por MQTT, HTTP o su interruptor.",
      "Add a motion sensor, triggered over MQTT, HTTP or its switch.": "Añadir un sensor de movimiento, activado por MQTT, HTTP o su interruptor.",
      "Add switches in HomeKit that trigger the motion sensor and the doorbell.": "Añadir en HomeKit interruptores que activan el sensor de movimiento y el timbre.",
      "Always send the maximums above, even when HomeKit asks for less.": "Enviar siempre los máximos de arriba, aunque HomeKit pida menos.",
      "Audio": "Audio",
      "Audio Stream": "Pista de audio",
      "Camera": "Cámara",
      "Cameras": "Cámaras",
      "Connect to the broker over TLS (mqtts), checking its certificate.": "Conectarse al broker por TLS (mqtts), comprobando su certificado.",
      "Debug Logging": "Registro de depuración",
      "Debug Two-way Audio": "Depurar el audio bidireccional",
      "Doorbell": "Timbre",
      "Doorbell Message": "Mensaje del timbre",
      "Doorbell Topic": "Tema del timbre",
      "Encoder Options": "Opciones del codificador",
      "Extra FFmpeg video filters, separated by commas, before the scaling ones. A none among them leaves the scaling out.": "Filtros de vídeo de FFmpeg adicionales, separados por comas, antes de los de escalado. Un none entre ellos quita el escalado.",
      "Extra options for the video encoder. Empty uses -preset ultrafast -tune zerolatency with libx264.": "Opciones adicionales para el codificador de vídeo. Vacío, se usa -preset ultrafast -tune zerolatency con libx264.",
      "FFmpeg's input options for snapshots, written as Source. Empty uses Source.": "Las opciones de entrada de FFmpeg para las instantáneas, escritas como Fuente. Vacío, se usa Fuente.",
      "FFmpeg's input options, such as -i rtsp://user:password@address:554/stream. Options may come before -i (-rtsp_transport tcp -i …).": "Las opciones de entrada de FFmpeg, como -i rtsp://user:password@address:554/stream. Puede haber opciones antes de -i (-rtsp_transport tcp -i …).",
      "FFmpeg's output options for the audio HomeKit sends back to the camera, such as -acodec libfdk_aac -ar 16000 -b:a 24k -ac 1 -f adts udp://address:port. Turns two-way audio on.": "Las opciones de salida de FFmpeg para el audio que HomeKit devuelve a la cámara, como -acodec libfdk_aac -ar 16000 -b:a 24k -ac 1 -f adts udp://address:port. Activa el audio bidireccional.",
      "Firmware Revision": "Versión del firmware",
      "Force Maximums": "Forzar los máximos",
      "HTTP Port": "Puerto HTTP",
      "HomeKit Secure Video": "HomeKit Secure Video",
      "Host name or IP address of the MQTT broker. Empty turns MQTT off.": "Nombre de host o dirección IP del broker MQTT. Vacío, MQTT se desactiva.",
      "How FFmpeg reads the camera and what it sends to HomeKit.": "Cómo lee FFmpeg la cámara y qué envía a HomeKit.",
      "How long motion stays detected after a trigger, and the doorbell switch stays on. 0 keeps motion on until it is reset. Empty uses 1.": "Cuánto tiempo sigue detectado el movimiento tras una activación, y encendido el interruptor del timbre. 0 mantiene el movimiento hasta su fin. Vacío, se usa 1.",
      "How many live streams may run at once. Empty uses 2.": "Cuántas transmisiones en directo pueden ir a la vez. Vacío, se usa 2.",
      "Keep the last seconds of video ready, so recordings start before the event. Only with HomeKit Secure Video; FFmpeg then reads the camera all the time.": "Guardar los últimos segundos de vídeo, para que las grabaciones empiecen antes del evento. Solo con HomeKit Secure Video; FFmpeg lee entonces la cámara todo el tiempo.",
      "Let a home hub record this camera's events in iCloud.": "Permitir que un concentrador doméstico grabe los eventos de esta cámara en iCloud.",
      "Localhost Only": "Solo localhost",
      "Log FFmpeg's output and the plugin's details for this camera.": "Registrar la salida de FFmpeg y los detalles del plugin para esta cámara.",
      "Log FFmpeg's output for the two-way audio.": "Registrar la salida de FFmpeg del audio bidireccional.",
      "MQTT Broker": "Broker MQTT",
      "MQTT Port": "Puerto MQTT",
      "MQTT Topics": "Temas de MQTT",
      "MQTT Username": "Nombre de usuario de MQTT",
      "Manufacturer": "Fabricante",
      "Maximum Bitrate (kbit/s)": "Tasa de bits máxima (kbit/s)",
      "Maximum Frame Rate": "Velocidad de fotogramas máxima",
      "Maximum Height": "Altura máxima",
      "Maximum Streams": "Transmisiones máximas",
      "Maximum Width": "Anchura máxima",
      "Model": "Modelo",
      "Motion Message": "Mensaje del movimiento",
      "Motion Reset Message": "Mensaje del fin del movimiento",
      "Motion Reset Topic": "Tema del fin del movimiento",
      "Motion Rings the Doorbell": "El movimiento hace sonar el timbre",
      "Motion Sensor": "Sensor de movimiento",
      "Motion Timeout (seconds)": "Duración del movimiento (segundos)",
      "Motion Topic": "Tema del movimiento",
      "Name": "Nombre",
      "Packet Size": "Tamaño de los paquetes",
      "Plugin name as shown in the logs": "Nombre del plugin en los registros",
      "Port of the HTTP API that triggers motion and doorbells: /motion?Camera, /motion/reset?Camera and /doorbell?Camera. Empty turns it off.": "Puerto de la API HTTP que activa los movimientos y los timbres: /motion?Cámara, /motion/reset?Cámara y /doorbell?Cámara. Vacío, se desactiva.",
      "Prebuffer": "Búfer previo",
      "Send the camera's audio to HomeKit. Needs an FFmpeg with libfdk_aac.": "Enviar el audio de la cámara a HomeKit. Necesita un FFmpeg con libfdk_aac.",
      "Serial Number": "Número de serie",
      "Shown in the accessory's information. Empty uses Camera FFmpeg.": "Se muestra en la información del accesorio. Vacío, se usa Camera FFmpeg.",
      "Shown in the accessory's information. Empty uses Homebridge.": "Se muestra en la información del accesorio. Vacío, se usa Homebridge.",
      "Shown in the accessory's information. Empty uses SerialNumber.": "Se muestra en la información del accesorio. Vacío, se usa SerialNumber.",
      "Shown in the accessory's information. Empty uses the bridge's version.": "Se muestra en la información del accesorio. Vacío, se usa la versión del puente.",
      "Source": "Fuente",
      "Still Image Source": "Fuente de las instantáneas",
      "The FFmpeg executable for every camera: a path, or a name found in PATH. Empty uses ffmpeg.": "El ejecutable de FFmpeg de todas las cámaras: una ruta, o un nombre que esté en PATH. Vacío, se usa ffmpeg.",
      "The FFmpeg stream sent as audio (its -map), such as 0:1.": "La pista de FFmpeg que se envía como audio (su -map), como 0:1.",
      "The FFmpeg stream sent as video (its -map), such as 0:0.": "La pista de FFmpeg que se envía como vídeo (su -map), como 0:0.",
      "The FFmpeg video encoder, such as libx264, h264_videotoolbox, h264_v4l2m2m or copy (copy sends the source as it is, without filters). Empty uses libx264.": "El codificador de vídeo de FFmpeg, como libx264, h264_videotoolbox, h264_v4l2m2m o copy (copy envía la fuente tal cual, sin filtros). Vacío, se usa libx264.",
      "The HTTP API listens on this computer's loopback address only, out of the network's reach.": "La API HTTP solo escucha en la dirección de bucle invertido de este ordenador, fuera del alcance de la red.",
      "The MQTT messages that trigger this camera, with the MQTT Broker set.": "Los mensajes de MQTT que activan esta cámara, con el broker MQTT indicado.",
      "The broker's port. Empty uses 1883.": "El puerto del broker. Vacío, se usa 1883.",
      "The camera's name in HomeKit. It identifies the camera: renaming it here makes a new accessory.": "El nombre de la cámara en HomeKit. La identifica: cambiarlo aquí crea un accesorio nuevo.",
      "The cameras, each an accessory of its own in the Home app, added with the bridge's set-up code.": "Las cámaras, cada una un accesorio aparte en la app Casa, que se añade con el código de configuración del puente.",
      "The exact message that resets motion. Empty is the camera's name.": "El mensaje exacto que pone fin al movimiento. Vacío, es el nombre de la cámara.",
      "The exact message that rings the doorbell. Empty is the camera's name.": "El mensaje exacto que hace sonar el timbre. Vacío, es el nombre de la cámara.",
      "The exact message that triggers motion. Empty is the camera's name.": "El mensaje exacto que activa el movimiento. Vacío, es el nombre de la cámara.",
      "The highest video bitrate sent. 0 sets none.": "La tasa de bits de vídeo máxima. 0 no fija ninguna.",
      "The most frames per second sent. 0 keeps the source's frame rate.": "El máximo de fotogramas por segundo. 0 mantiene los de la fuente.",
      "The tallest stream sent, in pixels. 0 keeps the source's height.": "La altura máxima de la transmisión, en píxeles. 0 mantiene la de la fuente.",
      "The topic whose message resets motion.": "El tema cuyo mensaje pone fin al movimiento.",
      "The topic whose message rings the doorbell.": "El tema cuyo mensaje hace sonar el timbre.",
      "The topic whose message triggers motion.": "El tema cuyo mensaje activa el movimiento.",
      "The username to sign in to the broker with, when it asks for one. Its password is set on Add accessories, and kept in the bridge's vault.": "El nombre de usuario para iniciar sesión en el broker, si lo pide. Su contraseña se introduce en Añadir accesorios y se guarda en la bóveda del puente.",
      "The video packets' size in bytes, a multiple of 188. Empty uses 1316.": "El tamaño de los paquetes de vídeo en bytes, un múltiplo de 188. Vacío, se usa 1316.",
      "The widest stream sent, in pixels. 0 keeps the source's width.": "La anchura máxima de la transmisión, en píxeles. 0 mantiene la de la fuente.",
      "Trigger Switches": "Interruptores de activación",
      "Two-way Audio Target (experimental)": "Destino del audio bidireccional (experimental)",
      "Use TLS": "Usar TLS",
      "Video": "Vídeo",
      "Video Codec": "Códec de vídeo",
      "Video Filters": "Filtros de vídeo",
      "Video Processor": "Procesador de vídeo",
      "Video Stream": "Pista de vídeo"
    },
    "pt": {
      "A motion trigger also rings the doorbell.": "Uma ativação do movimento também faz tocar a campainha.",
      "Add a doorbell, rung over MQTT, HTTP or its switch.": "Adicionar uma campainha, tocada por MQTT, HTTP ou o seu interruptor.",
      "Add a motion sensor, triggered over MQTT, HTTP or its switch.": "Adicionar um sensor de movimento, ativado por MQTT, HTTP ou o seu interruptor.",
      "Add switches in HomeKit that trigger the motion sensor and the doorbell.": "Adicionar no HomeKit interruptores que ativam o sensor de movimento e a campainha.",
      "Always send the maximums above, even when HomeKit asks for less.": "Enviar sempre os máximos acima, mesmo quando o HomeKit pede menos.",
      "Audio": "Áudio",
      "Audio Stream": "Faixa de áudio",
      "Camera": "Câmara",
      "Cameras": "Câmaras",
      "Connect to the broker over TLS (mqtts), checking its certificate.": "Ligar ao broker por TLS (mqtts), verificando o seu certificado.",
      "Debug Logging": "Registo de depuração",
      "Debug Two-way Audio": "Depurar o áudio bidirecional",
      "Doorbell": "Campainha",
      "Doorbell Message": "Mensagem da campainha",
      "Doorbell Topic": "Tópico da campainha",
      "Encoder Options": "Opções do codificador",
      "Extra FFmpeg video filters, separated by commas, before the scaling ones. A none among them leaves the scaling out.": "Filtros de vídeo do FFmpeg adicionais, separados por vírgulas, antes dos de redimensionamento. Um none entre eles retira o redimensionamento.",
      "Extra options for the video encoder. Empty uses -preset ultrafast -tune zerolatency with libx264.": "Opções adicionais para o codificador de vídeo. Vazio, é usado -preset ultrafast -tune zerolatency com o libx264.",
      "FFmpeg's input options for snapshots, written as Source. Empty uses Source.": "As opções de entrada do FFmpeg para as capturas, escritas como Origem. Vazio, é usada a Origem.",
      "FFmpeg's input options, such as -i rtsp://user:password@address:554/stream. Options may come before -i (-rtsp_transport tcp -i …).": "As opções de entrada do FFmpeg, como -i rtsp://user:password@address:554/stream. Pode haver opções antes de -i (-rtsp_transport tcp -i …).",
      "FFmpeg's output options for the audio HomeKit sends back to the camera, such as -acodec libfdk_aac -ar 16000 -b:a 24k -ac 1 -f adts udp://address:port. Turns two-way audio on.": "As opções de saída do FFmpeg para o áudio que o HomeKit devolve à câmara, como -acodec libfdk_aac -ar 16000 -b:a 24k -ac 1 -f adts udp://address:port. Ativa o áudio bidirecional.",
      "Firmware Revision": "Versão do firmware",
      "Force Maximums": "Forçar os máximos",
      "HTTP Port": "Porta HTTP",
      "HomeKit Secure Video": "HomeKit Secure Video",
      "Host name or IP address of the MQTT broker. Empty turns MQTT off.": "Nome de anfitrião ou endereço IP do broker MQTT. Vazio, o MQTT é desativado.",
      "How FFmpeg reads the camera and what it sends to HomeKit.": "Como o FFmpeg lê a câmara e o que envia para o HomeKit.",
      "How long motion stays detected after a trigger, and the doorbell switch stays on. 0 keeps motion on until it is reset. Empty uses 1.": "Quanto tempo o movimento fica detetado após uma ativação, e o interruptor da campainha ligado. 0 mantém o movimento até ao seu fim. Vazio, é usado 1.",
      "How many live streams may run at once. Empty uses 2.": "Quantas transmissões em direto podem decorrer em simultâneo. Vazio, é usado 2.",
      "Keep the last seconds of video ready, so recordings start before the event. Only with HomeKit Secure Video; FFmpeg then reads the camera all the time.": "Guardar os últimos segundos de vídeo, para que as gravações comecem antes do evento. Apenas com HomeKit Secure Video; o FFmpeg lê então a câmara permanentemente.",
      "Let a home hub record this camera's events in iCloud.": "Permitir que um concentrador doméstico grave os eventos desta câmara no iCloud.",
      "Localhost Only": "Apenas localhost",
      "Log FFmpeg's output and the plugin's details for this camera.": "Registar a saída do FFmpeg e os detalhes do plugin para esta câmara.",
      "Log FFmpeg's output for the two-way audio.": "Registar a saída do FFmpeg do áudio bidirecional.",
      "MQTT Broker": "Broker MQTT",
      "MQTT Port": "Porta MQTT",
      "MQTT Topics": "Tópicos MQTT",
      "MQTT Username": "Nome de utilizador MQTT",
      "Manufacturer": "Fabricante",
      "Maximum Bitrate (kbit/s)": "Débito máximo (kbit/s)",
      "Maximum Frame Rate": "Taxa de fotogramas máxima",
      "Maximum Height": "Altura máxima",
      "Maximum Streams": "Transmissões máximas",
      "Maximum Width": "Largura máxima",
      "Model": "Modelo",
      "Motion Message": "Mensagem do movimento",
      "Motion Reset Message": "Mensagem do fim do movimento",
      "Motion Reset Topic": "Tópico do fim do movimento",
      "Motion Rings the Doorbell": "O movimento faz tocar a campainha",
      "Motion Sensor": "Sensor de movimento",
      "Motion Timeout (seconds)": "Duração do movimento (segundos)",
      "Motion Topic": "Tópico do movimento",
      "Name": "Nome",
      "Packet Size": "Tamanho dos pacotes",
      "Plugin name as shown in the logs": "Nome do plugin nos registos",
      "Port of the HTTP API that triggers motion and doorbells: /motion?Camera, /motion/reset?Camera and /doorbell?Camera. Empty turns it off.": "Porta da API HTTP que ativa os movimentos e as campainhas: /motion?Câmara, /motion/reset?Câmara e /doorbell?Câmara. Vazio, é desativada.",
      "Prebuffer": "Pré-gravação",
      "Send the camera's audio to HomeKit. Needs an FFmpeg with libfdk_aac.": "Enviar o áudio da câmara para o HomeKit. Precisa de um FFmpeg com libfdk_aac.",
      "Serial Number": "Número de série",
      "Shown in the accessory's information. Empty uses Camera FFmpeg.": "Mostrado nas informações do acessório. Vazio, é usado Camera FFmpeg.",
      "Shown in the accessory's information. Empty uses Homebridge.": "Mostrado nas informações do acessório. Vazio, é usado Homebridge.",
      "Shown in the accessory's information. Empty uses SerialNumber.": "Mostrado nas informações do acessório. Vazio, é usado SerialNumber.",
      "Shown in the accessory's information. Empty uses the bridge's version.": "Mostrado nas informações do acessório. Vazio, é usada a versão da ponte.",
      "Source": "Origem",
      "Still Image Source": "Origem das capturas",
      "The FFmpeg executable for every camera: a path, or a name found in PATH. Empty uses ffmpeg.": "O executável do FFmpeg de todas as câmaras: um caminho, ou um nome que esteja no PATH. Vazio, é usado o ffmpeg.",
      "The FFmpeg stream sent as audio (its -map), such as 0:1.": "A faixa do FFmpeg enviada como áudio (o seu -map), como 0:1.",
      "The FFmpeg stream sent as video (its -map), such as 0:0.": "A faixa do FFmpeg enviada como vídeo (o seu -map), como 0:0.",
      "The FFmpeg video encoder, such as libx264, h264_videotoolbox, h264_v4l2m2m or copy (copy sends the source as it is, without filters). Empty uses libx264.": "O codificador de vídeo do FFmpeg, como libx264, h264_videotoolbox, h264_v4l2m2m ou copy (copy envia a origem tal como está, sem filtros). Vazio, é usado o libx264.",
      "The HTTP API listens on this computer's loopback address only, out of the network's reach.": "A API HTTP só escuta no endereço de loopback deste computador, fora do alcance da rede.",
      "The MQTT messages that trigger this camera, with the MQTT Broker set.": "As mensagens MQTT que ativam esta câmara, com o broker MQTT indicado.",
      "The broker's port. Empty uses 1883.": "A porta do broker. Vazio, é usada a 1883.",
      "The camera's name in HomeKit. It identifies the camera: renaming it here makes a new accessory.": "O nome da câmara no HomeKit. Identifica-a: mudá-lo aqui cria um acessório novo.",
      "The cameras, each an accessory of its own in the Home app, added with the bridge's set-up code.": "As câmaras, cada uma um acessório à parte na app Casa, adicionado com o código de configuração da ponte.",
      "The exact message that resets motion. Empty is the camera's name.": "A mensagem exata que termina o movimento. Vazia, é o nome da câmara.",
      "The exact message that rings the doorbell. Empty is the camera's name.": "A mensagem exata que faz tocar a campainha. Vazia, é o nome da câmara.",
      "The exact message that triggers motion. Empty is the camera's name.": "A mensagem exata que ativa o movimento. Vazia, é o nome da câmara.",
      "The highest video bitrate sent. 0 sets none.": "O débito de vídeo máximo. 0 não fixa nenhum.",
      "The most frames per second sent. 0 keeps the source's frame rate.": "O máximo de fotogramas por segundo. 0 mantém os da origem.",
      "The tallest stream sent, in pixels. 0 keeps the source's height.": "A altura máxima da transmissão, em píxeis. 0 mantém a da origem.",
      "The topic whose message resets motion.": "O tópico cuja mensagem termina o movimento.",
      "The topic whose message rings the doorbell.": "O tópico cuja mensagem faz tocar a campainha.",
      "The topic whose message triggers motion.": "O tópico cuja mensagem ativa o movimento.",
      "The username to sign in to the broker with, when it asks for one. Its password is set on Add accessories, and kept in the bridge's vault.": "O nome de utilizador para iniciar sessão no broker, se o pedir. A palavra-passe é introduzida em Adicionar acessórios e guardada no cofre da ponte.",
      "The video packets' size in bytes, a multiple of 188. Empty uses 1316.": "O tamanho dos pacotes de vídeo em bytes, um múltiplo de 188. Vazio, é usado 1316.",
      "The widest stream sent, in pixels. 0 keeps the source's width.": "A largura máxima da transmissão, em píxeis. 0 mantém a da origem.",
      "Trigger Switches": "Interruptores de ativação",
      "Two-way Audio Target (experimental)": "Destino do áudio bidirecional (experimental)",
      "Use TLS": "Usar TLS",
      "Video": "Vídeo",
      "Video Codec": "Codec de vídeo",
      "Video Filters": "Filtros de vídeo",
      "Video Processor": "Processador de vídeo",
      "Video Stream": "Faixa de vídeo"
    }
  }
}
"""#
}
