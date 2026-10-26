// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension UniFiProtectPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "UniFi Protect",
  "pluginType": "platform",
  "headerDisplay": "Full HomeKit support UniFi Protect devices. See the [homebridge-unifi-protect](https://github.com/mp-consulting/homebridge-unifi-protect) developer page for detailed documentation.",
  "footerDisplay": "A working **FFmpeg** installation is required for this plugin to work. For audio support, make sure your version of ffmpeg is compiled with support for the **fdk-aac** codec, or with **libopus** (as the Homeswift container image's ffmpeg-for-homeswift is).",
  "singular": true,
  "customUi": true,

  "schema": {
    "type": "object",
    "properties": {

      "controllers": {
        "type": "array",
        "title": "UniFi Protect Controllers",
        "description": "The UniFi Protect controllers to connect to, each with its address and the local user the plugin signs in with.",

        "items": {
          "type": "object",
          "title": "UniFi Protect Controller",
          "properties": {

            "address": {
              "type": "string",
              "title": "Controller Address",
              "required": true,
              "format": "hostname",
              "placeholder": "e.g. 1.2.3.4",
              "description": "Hostname or IP address of your UniFi Protect controller."
            },

            "doorbellMessages": {
              "type": "array",
              "title": "Doorbell Messages",
              "description": "Extra message presets for this controller's doorbells with a screen. While doorbell messages are enabled, each preset appears as a switch that shows it.",

              "items": {
                "type": "object",
                "title": "Doorbell Message",

                "properties": {

                  "duration": {
                    "type": "integer",
                    "title": "Message Duration (seconds)",
                    "required": false,
                    "minimum": 0,
                    "placeholder": "e.g. 60",
                    "description": "Length of time to display the message on your doorbell. Use 0 to display the message indefinitely. Default: 60."
                  },

                  "message": {
                    "type": "string",
                    "title": "Message Name",
                    "required": false,
                    "maxLength": 30,
                    "placeholder": "e.g. I'll be there soon.",
                    "description": "Message to display on your doorbell. Default: None."
                  }
                }
              }
            },

            "mqttTopic": {
              "type": "string",
              "title": "MQTT Base Topic",
              "required": false,
              "placeholder": "e.g. unifi/protect",
              "description": "The base MQTT topic to publish to. Default: unifi/protect."
            },

            "mqttVerifyTls": {
              "type": "boolean",
              "title": "Verify MQTT Broker TLS Certificate",
              "required": false,
              "default": true,
              "description": "Validate the MQTT broker's TLS certificate when connecting over mqtts:// or ssl://. Only disable this if your broker uses a self-signed certificate. Default: enabled."
            },

            "mqttUrl": {
              "type": "string",
              "title": "MQTT Broker URL",
              "required": false,
              "format": "uri",
              "placeholder": "e.g. mqtt://1.2.3.4",
              "description": "URL for the MQTT broker you'd like to publish event messages to. Default: None."
            },

            "name": {
              "type": "string",
              "title": "Controller Name",
              "required": false,
              "placeholder": "e.g. UNVR",
              "description": "Name for this UniFi Protect controller to be used for logging purposes. Default: Defined by the controller."
            },

            "overrideAddress": {

              "type": "string",
              "title": "Override Controller Address",
              "required": false,
              "description": "Override the address used when livestreaming. This is useful in VPN and remote scenarios where you want to override the address of the UniFi Protect controller. Warning: due to the way stacked Protect controller installations work, this option is unavailable for those configurations."
            },

            "cameraOverrides": {

              "type": "array",
              "title": "Third-Party Camera URL Overrides",
              "required": false,
              "description": "Per-camera RTSP and snapshot URL overrides for ONVIF and other third-party cameras adopted into UniFi Protect. The Protect controller often does not relay these cameras' streams reliably; supply the camera's own URLs here to bypass the controller. Only applied to cameras the controller has flagged as third-party.",
              "items": {

                "type": "object",
                "title": "Camera Override",
                "properties": {

                  "mac": {

                    "type": "string",
                    "title": "Camera MAC Address",
                    "required": true,
                    "placeholder": "e.g. F6:24:49:03:A5:B3",
                    "description": "MAC address of the third-party camera as reported by the Protect controller. Comparison is case- and separator-insensitive."
                  },

                  "rtspUrl": {

                    "type": "string",
                    "title": "Direct RTSP / RTSPS URL",
                    "required": false,
                    "placeholder": "e.g. rtsp://user:pass@192.168.1.50:8554/stream",
                    "description": "Full RTSP or RTSPS URL pointing directly at the camera's own RTSP server, bypassing the Protect controller. Credentials may be embedded."
                  },

                  "snapshotUrl": {

                    "type": "string",
                    "title": "Direct Snapshot URL",
                    "required": false,
                    "placeholder": "e.g. http://192.168.1.50:8080/snapshot",
                    "description": "Full HTTP or HTTPS URL pointing at the camera's snapshot endpoint. Credentials may be embedded. Self-signed certificates are accepted."
                  },

                  "onvifPort": {

                    "type": "integer",
                    "title": "ONVIF Port",
                    "required": false,
                    "minimum": 1,
                    "maximum": 65535,
                    "description": "ONVIF service port remembered for the discovery panel. Leave empty to let the panel try common defaults."
                  },

                  "onvifUsername": {

                    "type": "string",
                    "title": "ONVIF Username",
                    "required": false,
                    "description": "Username remembered for the ONVIF discovery panel. Stored in plaintext alongside the controller credentials."
                  },

                  "onvifPassword": {

                    "type": "string", "x-schema-form": { "type": "password" },
                    "title": "ONVIF Password",
                    "required": false,
                    "description": "Password remembered for the ONVIF discovery panel. Stored in plaintext alongside the controller credentials."
                  },

                  "onvifServicePath": {

                    "type": "string",
                    "title": "ONVIF Service Path",
                    "required": false,
                    "placeholder": "/onvif/device_service",
                    "description": "Optional ONVIF device service path remembered for the discovery panel. Defaults to /onvif/device_service when blank."
                  }
                }
              }
            },

            "password": {
              "type": "string", "x-schema-form": { "type": "password" },
              "title": "Controller Password",
              "required": true,
              "placeholder": "e.g. unifi-protect-password",
              "description": "UniFi Protect password for this controller's local user."
            },

            "playlistAddress": {
              "type": "string",
              "title": "M3U Playlist Bind Address",
              "required": false,
              "placeholder": "e.g. 127.0.0.1",
              "description": "Local IP address the M3U playlist service (Nvr.Service.Playlist feature option) listens on. Default: all interfaces."
            },

            "playlistToken": {
              "type": "string", "x-schema-form": { "type": "password" },
              "title": "M3U Playlist Access Token",
              "required": false,
              "placeholder": "e.g. a-long-random-string",
              "description": "When set, clients must request the M3U playlist with ?token=<value> in the URL. Without a token, anyone who can reach the playlist port can retrieve your camera stream URLs."
            },

            "username": {
              "type": "string",
              "title": "Controller Username",
              "required": true,
              "placeholder": "e.g. some-unifi-protect-user",
              "description": "UniFi Protect username for this controller. Create a local user for Homeswift on the controller, with the Full Management role so the plugin can turn on RTSP streams and change device settings."
            },

            "verifyTls": {
              "type": "boolean",
              "title": "Verify TLS Certificate",
              "required": false,
              "description": "Validate the controller's TLS certificate against trusted certificate authorities when connecting. Leave this disabled unless your controller uses a certificate signed by a trusted certificate authority - UniFi controllers use self-signed certificates by default. When disabled, the controller's certificate is pinned the first time the plugin connects, and connections presenting a different certificate are refused. Default: disabled."
            }
          }
        }
      },

      "debug": {

        "type": "boolean",
        "title": "Debug Logging",
        "required": false,
        "description": "Enable debug logging for this plugin. This creates a large volume of log output and should only be used when troubleshooting. Default: false."
      },

      "name": {

        "type": "string",
        "title": "Plugin Name",
        "required": true,
        "default": "UniFi Protect",
        "description": "Name to use for logging purposes. Default: UniFi Protect."
      },

      "options": {

        "type": "array",
        "title": "Feature Options",
        "description": "Feature options that turn plugin features on or off, everywhere or for one controller or device, such as Disable.Device. The feature options tab edits them for you.",

        "items": {
          "type": "string",
          "title": "Feature Option",
          "required": false,
          "description": "One option per entry. The plugin's page sets them for you; the README lists them all.",
          "placeholder": "e.g. Disable.Device"
        }
      },

      "ringDelay": {

        "type": "integer",
        "title": "Doorbell Ring Delay (seconds)",
        "required": false,
        "minimum": 0,
        "maximum": 60,
        "placeholder": "e.g. 5",
        "description": "Delay between doorbell rings. Setting this to a non-zero value will prevent multiple rings of a doorbell over the specified duration. Default: 0."
      },

      "verboseFfmpeg": {

        "type": "boolean",
        "title": "Verbose FFmpeg Logging",
        "required": false,
        "description": "Enable additional logging for FFmpeg. This will create additional logging when video streams are running. Default: false."
      },

      "videoProcessor": {

        "type": "string",
        "title": "FFmpeg Location",
        "required": false,
        "placeholder": "e.g. /usr/local/bin/ffmpeg",
        "description": "Path to the FFmpeg executable. Most users should not use this setting. Default: the first ffmpeg found in PATH."
      }
    }
  },

  "layout": [
    "name",
    {
      "type": "section",
      "title": "UniFi Protect Controllers",
      "expandable": true,
      "expanded": false,
      "items": [
        {
          "key": "controllers",
          "type": "array",
          "name": " ",
          "description": "Provide the IP address and login details of your UniFi Protect controllers.",
          "orderable": false,
          "buttonText": "Add UniFi Protect Controller",
          "items": [
            "controllers[].address",
            "controllers[].username",
            "controllers[].password",

            {
              "key": "controllers[]",
              "type": "section",
              "title": "Doorbell Message Presets",
              "expandable": true,
              "expanded": false,
              "items": [

                {
                  "key": "controllers[].doorbellMessages",
                  "type": "array",
                  "name": " ",
                  "description": "Create additional message presets to display on your UniFi Protect Doorbell.",
                  "orderable": false,
                  "buttonText": "Add Doorbell Message",
                  "items": [
                    "controllers[].doorbellMessages[].message",
                    "controllers[].doorbellMessages[].duration"
                  ]
                }
              ]
            },

            {
              "key": "controllers[]",
              "type": "section",
              "title": "Optional Settings",
              "expandable": true,
              "expanded": false,
              "items": [
                {
                  "description": "These settings are optional. The defaults work well for almost everyone.",
                  "items": [
                    "controllers[].name",
                    "controllers[].overrideAddress",
                    "controllers[].verifyTls",
                    "controllers[].playlistAddress",
                    "controllers[].playlistToken"
                  ]
                }
              ]
            },
            {
              "key": "controllers[]",
              "type": "section",
              "title": "MQTT Settings",
              "expandable": true,
              "expanded": false,
              "items": [
                {
                  "description": "MQTT support will only be enabled if an MQTT broker URL is specified below.",
                  "items": [
                    "controllers[].mqttUrl",
                    "controllers[].mqttTopic",
                    "controllers[].mqttVerifyTls"
                  ]
                }
              ]
            }
          ]
        }
      ]
    },

    {
      "type": "section",
      "title": "Plugin Feature Options (Optional)",
      "expandable": true,
      "expanded": false,
      "items": [
        {
          "key": "options",
          "type": "array",
          "name": " ",
          "description": "Use the feature options webUI tab above instead of manually configuring feature options here.",
          "orderable": true,
          "buttonText": "Add Feature Option",
          "items": [
            "options[]"
          ]
        }
      ]
    },

    {
      "type": "section",
      "title": "Additional Settings (Optional)",
      "expandable": true,
      "expanded": false,
      "items": [
        {
          "description": "These settings should be rarely used or needed by most people. Use these with caution.",
          "items": [
            "name",
            "videoProcessor",
            "verboseFfmpeg",
            "ringDelay",
            "debug"
          ]
        }
      ]
    }
  ],

  "i18n": {
    "fr": {
      "e.g. I'll be there soon.": "Par ex. J'arrive tout de suite.",
      "One option per entry. The plugin's page sets them for you; the README lists them all.": "Une option par entrée. La page du plugin les règle pour vous ; le README les liste toutes.",
      "Additional Settings (Optional)": "Réglages supplémentaires (facultatif)",
      "Camera MAC Address": "Adresse MAC de la caméra",
      "Camera Override": "Remplacement de caméra",
      "Controller Address": "Adresse du contrôleur",
      "Controller Name": "Nom du contrôleur",
      "Controller Password": "Mot de passe du contrôleur",
      "Controller Username": "Nom d'utilisateur du contrôleur",
      "Debug Logging": "Journal de débogage",
      "Delay between doorbell rings. Setting this to a non-zero value will prevent multiple rings of a doorbell over the specified duration. Default: 0.": "Délai entre les sonneries d'une sonnette. Une valeur non nulle ignore les sonneries répétées d'une sonnette pendant cette durée. Par défaut : 0.",
      "Direct RTSP / RTSPS URL": "URL RTSP / RTSPS directe",
      "Direct Snapshot URL": "URL de capture directe",
      "Doorbell Message": "Message de sonnette",
      "Doorbell Message Presets": "Messages prédéfinis de la sonnette",
      "Doorbell Messages": "Messages de la sonnette",
      "Doorbell Ring Delay (seconds)": "Délai entre sonneries (secondes)",
      "Enable additional logging for FFmpeg. This will create additional logging when video streams are running. Default: false.": "Active un journal plus détaillé pour FFmpeg, qui écrit davantage pendant la diffusion des flux vidéo. Par défaut : désactivé.",
      "Enable debug logging for this plugin. This creates a large volume of log output and should only be used when troubleshooting. Default: false.": "Active le journal de débogage de ce plugin. Il produit un grand volume de messages et ne doit servir qu'au dépannage. Par défaut : désactivé.",
      "Extra message presets for this controller's doorbells with a screen. While doorbell messages are enabled, each preset appears as a switch that shows it.": "Messages prédéfinis supplémentaires pour les sonnettes à écran de ce contrôleur. Quand les messages de sonnette sont activés, chaque message apparaît comme un interrupteur qui l'affiche.",
      "FFmpeg Location": "Emplacement de FFmpeg",
      "Feature Option": "Option de fonction",
      "Feature Options": "Options des fonctions",
      "Feature options that turn plugin features on or off, everywhere or for one controller or device, such as Disable.Device. The feature options tab edits them for you.": "Options qui activent ou désactivent des fonctions du plugin, partout ou pour un contrôleur ou un appareil, comme Disable.Device. L'onglet des options des fonctions les modifie pour vous.",
      "Full HTTP or HTTPS URL pointing at the camera's snapshot endpoint. Credentials may be embedded. Self-signed certificates are accepted.": "URL HTTP ou HTTPS complète du point d'accès de capture de la caméra. Elle peut contenir des identifiants. Les certificats autosignés sont acceptés.",
      "Full RTSP or RTSPS URL pointing directly at the camera's own RTSP server, bypassing the Protect controller. Credentials may be embedded.": "URL RTSP ou RTSPS complète qui pointe directement vers le serveur RTSP de la caméra, sans passer par le contrôleur Protect. Elle peut contenir des identifiants.",
      "Hostname or IP address of your UniFi Protect controller.": "Nom d'hôte ou adresse IP de votre contrôleur UniFi Protect.",
      "Length of time to display the message on your doorbell. Use 0 to display the message indefinitely. Default: 60.": "Durée d'affichage du message sur votre sonnette. 0 l'affiche indéfiniment. Par défaut : 60.",
      "Local IP address the M3U playlist service (Nvr.Service.Playlist feature option) listens on. Default: all interfaces.": "Adresse IP locale sur laquelle écoute le service de liste de lecture M3U (option de fonction Nvr.Service.Playlist). Par défaut : toutes les interfaces.",
      "M3U Playlist Access Token": "Jeton d'accès à la liste de lecture M3U",
      "M3U Playlist Bind Address": "Adresse d'écoute de la liste de lecture M3U",
      "MAC address of the third-party camera as reported by the Protect controller. Comparison is case- and separator-insensitive.": "Adresse MAC de la caméra tierce telle que l'indique le contrôleur Protect. La comparaison ignore la casse et les séparateurs.",
      "MQTT Base Topic": "Sujet MQTT de base",
      "MQTT Broker URL": "URL du broker MQTT",
      "MQTT Settings": "Réglages MQTT",
      "Message Duration (seconds)": "Durée du message (secondes)",
      "Message Name": "Nom du message",
      "Message to display on your doorbell. Default: None.": "Message à afficher sur votre sonnette. Par défaut : aucun.",
      "Name for this UniFi Protect controller to be used for logging purposes. Default: Defined by the controller.": "Nom de ce contrôleur UniFi Protect utilisé dans le journal. Par défaut : celui que donne le contrôleur.",
      "Name to use for logging purposes. Default: UniFi Protect.": "Nom utilisé dans le journal. Par défaut : UniFi Protect.",
      "ONVIF Password": "Mot de passe ONVIF",
      "ONVIF Port": "Port ONVIF",
      "ONVIF Service Path": "Chemin du service ONVIF",
      "ONVIF Username": "Nom d'utilisateur ONVIF",
      "ONVIF service port remembered for the discovery panel. Leave empty to let the panel try common defaults.": "Port du service ONVIF mémorisé pour le panneau de découverte. Laissez vide pour que le panneau essaie les valeurs courantes.",
      "Optional ONVIF device service path remembered for the discovery panel. Defaults to /onvif/device_service when blank.": "Chemin facultatif du service de l'appareil ONVIF, mémorisé pour le panneau de découverte. Vide, c'est /onvif/device_service.",
      "Optional Settings": "Réglages facultatifs",
      "Override Controller Address": "Adresse de remplacement du contrôleur",
      "Override the address used when livestreaming. This is useful in VPN and remote scenarios where you want to override the address of the UniFi Protect controller. Warning: due to the way stacked Protect controller installations work, this option is unavailable for those configurations.": "Remplace l'adresse utilisée pour la diffusion en direct. Utile avec un VPN ou à distance, pour remplacer l'adresse du contrôleur UniFi Protect. Attention : en raison du fonctionnement des installations Protect empilées, cette option n'est pas disponible pour celles-ci.",
      "Password remembered for the ONVIF discovery panel. Stored in plaintext alongside the controller credentials.": "Mot de passe mémorisé pour le panneau de découverte ONVIF. Enregistré en clair avec les identifiants du contrôleur.",
      "Path to the FFmpeg executable. Most users should not use this setting. Default: the first ffmpeg found in PATH.": "Chemin de l'exécutable FFmpeg. La plupart des utilisateurs n'ont pas besoin de ce réglage. Par défaut : le premier ffmpeg trouvé dans le PATH.",
      "Per-camera RTSP and snapshot URL overrides for ONVIF and other third-party cameras adopted into UniFi Protect. The Protect controller often does not relay these cameras' streams reliably; supply the camera's own URLs here to bypass the controller. Only applied to cameras the controller has flagged as third-party.": "URL RTSP et de capture propres à chaque caméra, pour les caméras ONVIF et autres caméras tierces adoptées dans UniFi Protect. Le contrôleur Protect relaie souvent mal les flux de ces caméras ; indiquez ici les URL de la caméra elle-même pour contourner le contrôleur. Appliqué seulement aux caméras que le contrôleur signale comme tierces.",
      "Plugin Feature Options (Optional)": "Options des fonctions du plugin (facultatif)",
      "Plugin Name": "Nom du plugin",
      "The UniFi Protect controllers to connect to, each with its address and the local user the plugin signs in with.": "Les contrôleurs UniFi Protect auxquels se connecter, chacun avec son adresse et l'utilisateur local avec lequel le plugin se connecte.",
      "The base MQTT topic to publish to. Default: unifi/protect.": "Le sujet MQTT de base sur lequel publier. Par défaut : unifi/protect.",
      "Third-Party Camera URL Overrides": "URL de remplacement des caméras tierces",
      "URL for the MQTT broker you'd like to publish event messages to. Default: None.": "URL du broker MQTT auquel publier les messages d'événement. Par défaut : aucune.",
      "UniFi Protect Controller": "Contrôleur UniFi Protect",
      "UniFi Protect Controllers": "Contrôleurs UniFi Protect",
      "UniFi Protect password for this controller's local user.": "Mot de passe UniFi Protect de l'utilisateur local de ce contrôleur.",
      "UniFi Protect username for this controller. Create a local user for Homeswift on the controller, with the Full Management role so the plugin can turn on RTSP streams and change device settings.": "Nom d'utilisateur UniFi Protect pour ce contrôleur. Créez sur le contrôleur un utilisateur local pour Homeswift, avec le rôle Full Management, pour que le plugin puisse activer les flux RTSP et modifier les réglages des appareils.",
      "Username remembered for the ONVIF discovery panel. Stored in plaintext alongside the controller credentials.": "Nom d'utilisateur mémorisé pour le panneau de découverte ONVIF. Enregistré en clair avec les identifiants du contrôleur.",
      "Validate the MQTT broker's TLS certificate when connecting over mqtts:// or ssl://. Only disable this if your broker uses a self-signed certificate. Default: enabled.": "Vérifie le certificat TLS du broker MQTT lors des connexions en mqtts:// ou ssl://. Ne désactivez cette option que si votre broker utilise un certificat autosigné. Par défaut : activé.",
      "Validate the controller's TLS certificate against trusted certificate authorities when connecting. Leave this disabled unless your controller uses a certificate signed by a trusted certificate authority - UniFi controllers use self-signed certificates by default. When disabled, the controller's certificate is pinned the first time the plugin connects, and connections presenting a different certificate are refused. Default: disabled.": "Vérifie le certificat TLS du contrôleur auprès d'autorités de certification de confiance lors de la connexion. Laissez cette option désactivée, sauf si votre contrôleur utilise un certificat signé par une autorité de certification de confiance : les contrôleurs UniFi utilisent par défaut des certificats autosignés. Désactivée, le certificat du contrôleur est épinglé à la première connexion du plugin, et les connexions qui présentent un autre certificat sont refusées. Par défaut : désactivé.",
      "Verbose FFmpeg Logging": "Journal FFmpeg détaillé",
      "Verify MQTT Broker TLS Certificate": "Vérifier le certificat TLS du broker MQTT",
      "Verify TLS Certificate": "Vérifier le certificat TLS",
      "When set, clients must request the M3U playlist with ?token=<value> in the URL. Without a token, anyone who can reach the playlist port can retrieve your camera stream URLs.": "Si défini, les clients doivent demander la liste de lecture M3U avec ?token=<value> dans l'URL. Sans jeton, quiconque atteint le port de la liste de lecture peut obtenir les URL des flux de vos caméras."
    },
    "es": {
      "e.g. I'll be there soon.": "Por ejemplo: Ahora mismo voy.",
      "One option per entry. The plugin's page sets them for you; the README lists them all.": "Una opción por entrada. La página del plugin las ajusta por ti; el README las enumera todas.",
      "Additional Settings (Optional)": "Ajustes adicionales (opcional)",
      "Camera MAC Address": "Dirección MAC de la cámara",
      "Camera Override": "Sustitución de cámara",
      "Controller Address": "Dirección del controlador",
      "Controller Name": "Nombre del controlador",
      "Controller Password": "Contraseña del controlador",
      "Controller Username": "Nombre de usuario del controlador",
      "Debug Logging": "Registro de depuración",
      "Delay between doorbell rings. Setting this to a non-zero value will prevent multiple rings of a doorbell over the specified duration. Default: 0.": "Tiempo entre llamadas de un timbre. Un valor distinto de cero ignora las llamadas repetidas de un timbre durante ese tiempo. Por defecto: 0.",
      "Direct RTSP / RTSPS URL": "URL RTSP / RTSPS directa",
      "Direct Snapshot URL": "URL de instantánea directa",
      "Doorbell Message": "Mensaje del timbre",
      "Doorbell Message Presets": "Mensajes predefinidos del timbre",
      "Doorbell Messages": "Mensajes del timbre",
      "Doorbell Ring Delay (seconds)": "Retardo entre llamadas del timbre (segundos)",
      "Enable additional logging for FFmpeg. This will create additional logging when video streams are running. Default: false.": "Activa un registro más detallado de FFmpeg, que escribe más mientras se reproducen flujos de vídeo. Por defecto: desactivado.",
      "Enable debug logging for this plugin. This creates a large volume of log output and should only be used when troubleshooting. Default: false.": "Activa el registro de depuración de este plugin. Genera un gran volumen de mensajes y solo debe usarse para resolver problemas. Por defecto: desactivado.",
      "Extra message presets for this controller's doorbells with a screen. While doorbell messages are enabled, each preset appears as a switch that shows it.": "Mensajes predefinidos adicionales para los timbres con pantalla de este controlador. Si los mensajes del timbre están activados, cada mensaje aparece como un interruptor que lo muestra.",
      "FFmpeg Location": "Ubicación de FFmpeg",
      "Feature Option": "Opción de función",
      "Feature Options": "Opciones de funciones",
      "Feature options that turn plugin features on or off, everywhere or for one controller or device, such as Disable.Device. The feature options tab edits them for you.": "Opciones que activan o desactivan funciones del plugin, en todas partes o para un controlador o dispositivo, como Disable.Device. La pestaña de opciones de funciones las edita por ti.",
      "Full HTTP or HTTPS URL pointing at the camera's snapshot endpoint. Credentials may be embedded. Self-signed certificates are accepted.": "URL HTTP o HTTPS completa del punto de acceso de instantáneas de la cámara. Puede incluir credenciales. Se aceptan certificados autofirmados.",
      "Full RTSP or RTSPS URL pointing directly at the camera's own RTSP server, bypassing the Protect controller. Credentials may be embedded.": "URL RTSP o RTSPS completa que apunta directamente al servidor RTSP de la cámara, sin pasar por el controlador Protect. Puede incluir credenciales.",
      "Hostname or IP address of your UniFi Protect controller.": "Nombre de host o dirección IP de tu controlador UniFi Protect.",
      "Length of time to display the message on your doorbell. Use 0 to display the message indefinitely. Default: 60.": "Tiempo que se muestra el mensaje en tu timbre. Usa 0 para mostrarlo indefinidamente. Por defecto: 60.",
      "Local IP address the M3U playlist service (Nvr.Service.Playlist feature option) listens on. Default: all interfaces.": "Dirección IP local en la que escucha el servicio de lista de reproducción M3U (opción de función Nvr.Service.Playlist). Por defecto: todas las interfaces.",
      "M3U Playlist Access Token": "Token de acceso a la lista de reproducción M3U",
      "M3U Playlist Bind Address": "Dirección de escucha de la lista de reproducción M3U",
      "MAC address of the third-party camera as reported by the Protect controller. Comparison is case- and separator-insensitive.": "Dirección MAC de la cámara de terceros tal como la indica el controlador Protect. La comparación no distingue mayúsculas ni separadores.",
      "MQTT Base Topic": "Tema MQTT base",
      "MQTT Broker URL": "URL del broker MQTT",
      "MQTT Settings": "Ajustes de MQTT",
      "Message Duration (seconds)": "Duración del mensaje (segundos)",
      "Message Name": "Nombre del mensaje",
      "Message to display on your doorbell. Default: None.": "Mensaje que se muestra en tu timbre. Por defecto: ninguno.",
      "Name for this UniFi Protect controller to be used for logging purposes. Default: Defined by the controller.": "Nombre de este controlador UniFi Protect que se usa en el registro. Por defecto: el que indica el controlador.",
      "Name to use for logging purposes. Default: UniFi Protect.": "Nombre que se usa en el registro. Por defecto: UniFi Protect.",
      "ONVIF Password": "Contraseña ONVIF",
      "ONVIF Port": "Puerto ONVIF",
      "ONVIF Service Path": "Ruta del servicio ONVIF",
      "ONVIF Username": "Nombre de usuario ONVIF",
      "ONVIF service port remembered for the discovery panel. Leave empty to let the panel try common defaults.": "Puerto del servicio ONVIF que se recuerda para el panel de detección. Déjalo vacío para que el panel pruebe los valores habituales.",
      "Optional ONVIF device service path remembered for the discovery panel. Defaults to /onvif/device_service when blank.": "Ruta opcional del servicio del dispositivo ONVIF que se recuerda para el panel de detección. Si está vacía, es /onvif/device_service.",
      "Optional Settings": "Ajustes opcionales",
      "Override Controller Address": "Dirección alternativa del controlador",
      "Override the address used when livestreaming. This is useful in VPN and remote scenarios where you want to override the address of the UniFi Protect controller. Warning: due to the way stacked Protect controller installations work, this option is unavailable for those configurations.": "Sustituye la dirección que se usa para la transmisión en directo. Útil con VPN o en acceso remoto, para sustituir la dirección del controlador UniFi Protect. Aviso: por cómo funcionan las instalaciones de Protect apiladas, esta opción no está disponible en ellas.",
      "Password remembered for the ONVIF discovery panel. Stored in plaintext alongside the controller credentials.": "Contraseña que se recuerda para el panel de detección ONVIF. Se guarda en texto plano junto a las credenciales del controlador.",
      "Path to the FFmpeg executable. Most users should not use this setting. Default: the first ffmpeg found in PATH.": "Ruta del ejecutable de FFmpeg. La mayoría de usuarios no necesita este ajuste. Por defecto: el primer ffmpeg que se encuentre en el PATH.",
      "Per-camera RTSP and snapshot URL overrides for ONVIF and other third-party cameras adopted into UniFi Protect. The Protect controller often does not relay these cameras' streams reliably; supply the camera's own URLs here to bypass the controller. Only applied to cameras the controller has flagged as third-party.": "URL RTSP y de instantánea propias de cada cámara, para cámaras ONVIF y otras cámaras de terceros adoptadas en UniFi Protect. El controlador Protect a menudo no retransmite bien los flujos de estas cámaras; indica aquí las URL de la propia cámara para evitar el controlador. Solo se aplica a las cámaras que el controlador marca como de terceros.",
      "Plugin Feature Options (Optional)": "Opciones de funciones del plugin (opcional)",
      "Plugin Name": "Nombre del plugin",
      "The UniFi Protect controllers to connect to, each with its address and the local user the plugin signs in with.": "Los controladores UniFi Protect a los que conectarse, cada uno con su dirección y el usuario local con el que el plugin inicia sesión.",
      "The base MQTT topic to publish to. Default: unifi/protect.": "El tema MQTT base en el que publicar. Por defecto: unifi/protect.",
      "Third-Party Camera URL Overrides": "URL alternativas de cámaras de terceros",
      "URL for the MQTT broker you'd like to publish event messages to. Default: None.": "URL del broker MQTT en el que quieres publicar los mensajes de eventos. Por defecto: ninguna.",
      "UniFi Protect Controller": "Controlador UniFi Protect",
      "UniFi Protect Controllers": "Controladores UniFi Protect",
      "UniFi Protect password for this controller's local user.": "Contraseña de UniFi Protect del usuario local de este controlador.",
      "UniFi Protect username for this controller. Create a local user for Homeswift on the controller, with the Full Management role so the plugin can turn on RTSP streams and change device settings.": "Nombre de usuario de UniFi Protect para este controlador. Crea en el controlador un usuario local para Homeswift, con el rol Full Management, para que el plugin pueda activar los flujos RTSP y cambiar los ajustes de los dispositivos.",
      "Username remembered for the ONVIF discovery panel. Stored in plaintext alongside the controller credentials.": "Nombre de usuario que se recuerda para el panel de detección ONVIF. Se guarda en texto plano junto a las credenciales del controlador.",
      "Validate the MQTT broker's TLS certificate when connecting over mqtts:// or ssl://. Only disable this if your broker uses a self-signed certificate. Default: enabled.": "Valida el certificado TLS del broker MQTT al conectarse por mqtts:// o ssl://. Desactívalo solo si tu broker usa un certificado autofirmado. Por defecto: activado.",
      "Validate the controller's TLS certificate against trusted certificate authorities when connecting. Leave this disabled unless your controller uses a certificate signed by a trusted certificate authority - UniFi controllers use self-signed certificates by default. When disabled, the controller's certificate is pinned the first time the plugin connects, and connections presenting a different certificate are refused. Default: disabled.": "Valida el certificado TLS del controlador con autoridades de certificación de confianza al conectarse. Déjalo desactivado salvo que tu controlador use un certificado firmado por una autoridad de certificación de confianza: los controladores UniFi usan certificados autofirmados por defecto. Desactivado, el certificado del controlador se fija la primera vez que el plugin se conecta y se rechazan las conexiones que presenten otro certificado. Por defecto: desactivado.",
      "Verbose FFmpeg Logging": "Registro detallado de FFmpeg",
      "Verify MQTT Broker TLS Certificate": "Verificar el certificado TLS del broker MQTT",
      "Verify TLS Certificate": "Verificar el certificado TLS",
      "When set, clients must request the M3U playlist with ?token=<value> in the URL. Without a token, anyone who can reach the playlist port can retrieve your camera stream URLs.": "Si se indica, los clientes deben pedir la lista de reproducción M3U con ?token=<value> en la URL. Sin token, cualquiera que llegue al puerto de la lista puede obtener las URL de los flujos de tus cámaras."
    },
    "pt": {
      "e.g. I'll be there soon.": "Por exemplo: Já vou.",
      "One option per entry. The plugin's page sets them for you; the README lists them all.": "Uma opção por entrada. A página do plugin define-as por si; o README lista-as todas.",
      "Additional Settings (Optional)": "Definições adicionais (opcional)",
      "Camera MAC Address": "Endereço MAC da câmara",
      "Camera Override": "Substituição de câmara",
      "Controller Address": "Endereço do controlador",
      "Controller Name": "Nome do controlador",
      "Controller Password": "Palavra-passe do controlador",
      "Controller Username": "Nome de utilizador do controlador",
      "Debug Logging": "Registo de depuração",
      "Delay between doorbell rings. Setting this to a non-zero value will prevent multiple rings of a doorbell over the specified duration. Default: 0.": "Intervalo entre toques de uma campainha. Um valor diferente de zero ignora os toques repetidos de uma campainha durante esse tempo. Predefinição: 0.",
      "Direct RTSP / RTSPS URL": "URL RTSP / RTSPS direto",
      "Direct Snapshot URL": "URL de instantâneo direto",
      "Doorbell Message": "Mensagem da campainha",
      "Doorbell Message Presets": "Mensagens predefinidas da campainha",
      "Doorbell Messages": "Mensagens da campainha",
      "Doorbell Ring Delay (seconds)": "Intervalo entre toques da campainha (segundos)",
      "Enable additional logging for FFmpeg. This will create additional logging when video streams are running. Default: false.": "Ativa um registo mais detalhado do FFmpeg, que escreve mais enquanto há transmissões de vídeo. Predefinição: desativado.",
      "Enable debug logging for this plugin. This creates a large volume of log output and should only be used when troubleshooting. Default: false.": "Ativa o registo de depuração deste plugin. Gera um grande volume de mensagens e só deve ser usado para resolver problemas. Predefinição: desativado.",
      "Extra message presets for this controller's doorbells with a screen. While doorbell messages are enabled, each preset appears as a switch that shows it.": "Mensagens predefinidas adicionais para as campainhas com ecrã deste controlador. Com as mensagens da campainha ativadas, cada mensagem aparece como um interruptor que a mostra.",
      "FFmpeg Location": "Localização do FFmpeg",
      "Feature Option": "Opção de funcionalidade",
      "Feature Options": "Opções de funcionalidades",
      "Feature options that turn plugin features on or off, everywhere or for one controller or device, such as Disable.Device. The feature options tab edits them for you.": "Opções que ativam ou desativam funcionalidades do plugin, em todo o lado ou para um controlador ou dispositivo, como Disable.Device. O separador de opções de funcionalidades edita-as automaticamente.",
      "Full HTTP or HTTPS URL pointing at the camera's snapshot endpoint. Credentials may be embedded. Self-signed certificates are accepted.": "URL HTTP ou HTTPS completo do ponto de acesso de instantâneos da câmara. Pode incluir credenciais. São aceites certificados autoassinados.",
      "Full RTSP or RTSPS URL pointing directly at the camera's own RTSP server, bypassing the Protect controller. Credentials may be embedded.": "URL RTSP ou RTSPS completo que aponta diretamente para o servidor RTSP da câmara, sem passar pelo controlador Protect. Pode incluir credenciais.",
      "Hostname or IP address of your UniFi Protect controller.": "Nome de anfitrião ou endereço IP do controlador UniFi Protect.",
      "Length of time to display the message on your doorbell. Use 0 to display the message indefinitely. Default: 60.": "Tempo durante o qual a mensagem é apresentada na campainha. Com 0, é apresentada indefinidamente. Predefinição: 60.",
      "Local IP address the M3U playlist service (Nvr.Service.Playlist feature option) listens on. Default: all interfaces.": "Endereço IP local em que o serviço de lista de reprodução M3U (opção de funcionalidade Nvr.Service.Playlist) escuta. Predefinição: todas as interfaces.",
      "M3U Playlist Access Token": "Token de acesso à lista de reprodução M3U",
      "M3U Playlist Bind Address": "Endereço de escuta da lista de reprodução M3U",
      "MAC address of the third-party camera as reported by the Protect controller. Comparison is case- and separator-insensitive.": "Endereço MAC da câmara de terceiros tal como o controlador Protect o indica. A comparação ignora maiúsculas e separadores.",
      "MQTT Base Topic": "Tópico MQTT base",
      "MQTT Broker URL": "URL do broker MQTT",
      "MQTT Settings": "Definições de MQTT",
      "Message Duration (seconds)": "Duração da mensagem (segundos)",
      "Message Name": "Nome da mensagem",
      "Message to display on your doorbell. Default: None.": "Mensagem a apresentar na campainha. Predefinição: nenhuma.",
      "Name for this UniFi Protect controller to be used for logging purposes. Default: Defined by the controller.": "Nome deste controlador UniFi Protect usado no registo. Predefinição: o indicado pelo controlador.",
      "Name to use for logging purposes. Default: UniFi Protect.": "Nome usado no registo. Predefinição: UniFi Protect.",
      "ONVIF Password": "Palavra-passe ONVIF",
      "ONVIF Port": "Porta ONVIF",
      "ONVIF Service Path": "Caminho do serviço ONVIF",
      "ONVIF Username": "Nome de utilizador ONVIF",
      "ONVIF service port remembered for the discovery panel. Leave empty to let the panel try common defaults.": "Porta do serviço ONVIF memorizada para o painel de deteção. Deixe vazio para o painel experimentar os valores habituais.",
      "Optional ONVIF device service path remembered for the discovery panel. Defaults to /onvif/device_service when blank.": "Caminho opcional do serviço do dispositivo ONVIF, memorizado para o painel de deteção. Vazio, é /onvif/device_service.",
      "Optional Settings": "Definições opcionais",
      "Override Controller Address": "Endereço alternativo do controlador",
      "Override the address used when livestreaming. This is useful in VPN and remote scenarios where you want to override the address of the UniFi Protect controller. Warning: due to the way stacked Protect controller installations work, this option is unavailable for those configurations.": "Substitui o endereço usado na transmissão em direto. Útil com VPN ou em acesso remoto, para substituir o endereço do controlador UniFi Protect. Aviso: devido ao funcionamento das instalações Protect empilhadas, esta opção não está disponível nelas.",
      "Password remembered for the ONVIF discovery panel. Stored in plaintext alongside the controller credentials.": "Palavra-passe memorizada para o painel de deteção ONVIF. Guardada em texto simples junto das credenciais do controlador.",
      "Path to the FFmpeg executable. Most users should not use this setting. Default: the first ffmpeg found in PATH.": "Caminho do executável do FFmpeg. A maioria dos utilizadores não precisa desta definição. Predefinição: o primeiro ffmpeg encontrado no PATH.",
      "Per-camera RTSP and snapshot URL overrides for ONVIF and other third-party cameras adopted into UniFi Protect. The Protect controller often does not relay these cameras' streams reliably; supply the camera's own URLs here to bypass the controller. Only applied to cameras the controller has flagged as third-party.": "URL RTSP e de instantâneo próprios de cada câmara, para câmaras ONVIF e outras câmaras de terceiros adotadas no UniFi Protect. O controlador Protect muitas vezes não retransmite bem as transmissões destas câmaras; indique aqui os URL da própria câmara para contornar o controlador. Só se aplica às câmaras que o controlador assinala como de terceiros.",
      "Plugin Feature Options (Optional)": "Opções de funcionalidades do plugin (opcional)",
      "Plugin Name": "Nome do plugin",
      "The UniFi Protect controllers to connect to, each with its address and the local user the plugin signs in with.": "Os controladores UniFi Protect a que ligar, cada um com o seu endereço e o utilizador local com que o plugin inicia sessão.",
      "The base MQTT topic to publish to. Default: unifi/protect.": "O tópico MQTT base em que publicar. Predefinição: unifi/protect.",
      "Third-Party Camera URL Overrides": "URL alternativos de câmaras de terceiros",
      "URL for the MQTT broker you'd like to publish event messages to. Default: None.": "URL do broker MQTT em que publicar as mensagens de eventos. Predefinição: nenhum.",
      "UniFi Protect Controller": "Controlador UniFi Protect",
      "UniFi Protect Controllers": "Controladores UniFi Protect",
      "UniFi Protect password for this controller's local user.": "Palavra-passe UniFi Protect do utilizador local deste controlador.",
      "UniFi Protect username for this controller. Create a local user for Homeswift on the controller, with the Full Management role so the plugin can turn on RTSP streams and change device settings.": "Nome de utilizador UniFi Protect deste controlador. Crie no controlador um utilizador local para o Homeswift, com a função Full Management, para que o plugin possa ativar as transmissões RTSP e alterar as definições dos dispositivos.",
      "Username remembered for the ONVIF discovery panel. Stored in plaintext alongside the controller credentials.": "Nome de utilizador memorizado para o painel de deteção ONVIF. Guardado em texto simples junto das credenciais do controlador.",
      "Validate the MQTT broker's TLS certificate when connecting over mqtts:// or ssl://. Only disable this if your broker uses a self-signed certificate. Default: enabled.": "Valida o certificado TLS do broker MQTT nas ligações por mqtts:// ou ssl://. Desative apenas se o broker usar um certificado autoassinado. Predefinição: ativado.",
      "Validate the controller's TLS certificate against trusted certificate authorities when connecting. Leave this disabled unless your controller uses a certificate signed by a trusted certificate authority - UniFi controllers use self-signed certificates by default. When disabled, the controller's certificate is pinned the first time the plugin connects, and connections presenting a different certificate are refused. Default: disabled.": "Valida o certificado TLS do controlador junto de autoridades de certificação de confiança ao ligar. Deixe desativado, a menos que o controlador use um certificado assinado por uma autoridade de certificação de confiança: os controladores UniFi usam certificados autoassinados por omissão. Desativado, o certificado do controlador é fixado na primeira ligação do plugin, e as ligações que apresentem outro certificado são recusadas. Predefinição: desativado.",
      "Verbose FFmpeg Logging": "Registo detalhado do FFmpeg",
      "Verify MQTT Broker TLS Certificate": "Verificar o certificado TLS do broker MQTT",
      "Verify TLS Certificate": "Verificar o certificado TLS",
      "When set, clients must request the M3U playlist with ?token=<value> in the URL. Without a token, anyone who can reach the playlist port can retrieve your camera stream URLs.": "Quando definido, os clientes têm de pedir a lista de reprodução M3U com ?token=<value> no URL. Sem token, qualquer pessoa que chegue à porta da lista pode obter os URL das transmissões das câmaras."
    }
  }
}
"""#
}
