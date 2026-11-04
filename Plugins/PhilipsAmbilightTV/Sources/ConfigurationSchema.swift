// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension PhilipsAmbilightTVPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "PhilipsAmbilightTV",
  "pluginType": "platform",
  "singular": true,
  "strictValidation": false,
  "customUi": true,
  "schema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "required": true,
        "default": "Philips Ambilight TV",
        "description": "Plugin name as displayed in the log."
      },
      "devices": {
        "title": "TVs to Find by Address",
        "type": "array",
        "description": "TVs Add accessories does not find on the network (another subnet, Bonjour blocked): each one's name and IP address, and its MAC address if you know it. Setup pairs it there and keeps it in its own settings.",
        "items": {
          "type": "object",
          "title": "TV",
          "properties": {
            "name": {
              "title": "TV Name",
              "type": "string",
              "default": "My Philips TV",
              "description": "The name of the TV as it will appear in HomeKit."
            },
            "ip": {
              "title": "IP Address",
              "type": "string",
              "format": "ipv4",
              "placeholder": "192.168.1.100",
              "description": "The IP address of the TV on the local network."
            },
            "mac": {
              "title": "MAC Address",
              "type": "string",
              "pattern": "^([A-Fa-f0-9]{2}[:-]){5}[A-Fa-f0-9]{2}$",
              "placeholder": "AA:BB:CC:DD:EE:FF",
              "description": "The MAC address of the TV (required for Wake-on-LAN)."
            }
          },
          "required": [
            "ip"
          ]
        }
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "ip": {
        "title": "IP Address",
        "type": "string",
        "format": "ipv4",
        "placeholder": "192.168.1.100",
        "description": "The IP address of the TV on the local network."
      },
      "pollingInterval": {
        "title": "Polling Interval (ms)",
        "type": "integer",
        "default": 10000,
        "minimum": 1000,
        "maximum": 60000,
        "description": "How often to poll the TV for state updates (in milliseconds)."
      },
      "wakeOnLanEnabled": {
        "title": "Wake-on-LAN",
        "type": "boolean",
        "default": true,
        "description": "Enable Wake-on-LAN to turn on the TV from standby."
      },
      "ambilightMode": {
        "title": "Ambilight Mode",
        "type": "string",
        "default": "FOLLOW_VIDEO/NATURAL",
        "description": "The ambilight mode to activate when turning on via HomeKit.",
        "oneOf": [
          {
            "title": "Follow Video - Standard",
            "enum": [
              "FOLLOW_VIDEO/STANDARD"
            ]
          },
          {
            "title": "Follow Video - Natural",
            "enum": [
              "FOLLOW_VIDEO/NATURAL"
            ]
          },
          {
            "title": "Follow Video - Vivid",
            "enum": [
              "FOLLOW_VIDEO/VIVID"
            ]
          },
          {
            "title": "Follow Video - Game",
            "enum": [
              "FOLLOW_VIDEO/GAME"
            ]
          },
          {
            "title": "Follow Video - Comfort",
            "enum": [
              "FOLLOW_VIDEO/COMFORT"
            ]
          },
          {
            "title": "Follow Video - Relax",
            "enum": [
              "FOLLOW_VIDEO/RELAX"
            ]
          },
          {
            "title": "Follow Video - Football",
            "enum": [
              "FOLLOW_VIDEO/FOOTBALL"
            ]
          },
          {
            "title": "Follow Audio - Energy Brightness",
            "enum": [
              "FOLLOW_AUDIO/ENERGY_ADAPTIVE_BRIGHTNESS"
            ]
          },
          {
            "title": "Follow Audio - Energy Colors",
            "enum": [
              "FOLLOW_AUDIO/ENERGY_ADAPTIVE_COLORS"
            ]
          },
          {
            "title": "Follow Audio - VU Meter",
            "enum": [
              "FOLLOW_AUDIO/VU_METER"
            ]
          },
          {
            "title": "Follow Audio - Spectrum",
            "enum": [
              "FOLLOW_AUDIO/SPECTRUM_ANALYZER"
            ]
          },
          {
            "title": "Follow Audio - Party",
            "enum": [
              "FOLLOW_AUDIO/PARTY"
            ]
          },
          {
            "title": "Lounge Light",
            "enum": [
              "Lounge light"
            ]
          }
        ]
      },
      "ambilightOnStart": {
        "title": "Start Ambilight when TV turns on",
        "type": "boolean",
        "default": false,
        "description": "Automatically turn Ambilight on (in the mode above) whenever the TV powers on."
      },
      "infoButtonKey": {
        "title": "Info Button Key",
        "type": "string",
        "default": "Source",
        "description": "The TV key that the HomeKit remote's information button sends.",
        "oneOf": [
          {
            "title": "Source (input picker)",
            "enum": [
              "Source"
            ]
          },
          {
            "title": "Info (program details)",
            "enum": [
              "Info"
            ]
          },
          {
            "title": "Options (context menu)",
            "enum": [
              "Options"
            ]
          },
          {
            "title": "Find (search)",
            "enum": [
              "Find"
            ]
          }
        ]
      },
      "backButtonKey": {
        "title": "Back Button Key",
        "type": "string",
        "default": "Back",
        "description": "The TV key that the HomeKit remote's back button sends.",
        "oneOf": [
          {
            "title": "Back",
            "enum": [
              "Back"
            ]
          },
          {
            "title": "Home",
            "enum": [
              "Home"
            ]
          },
          {
            "title": "Source (input picker)",
            "enum": [
              "Source"
            ]
          },
          {
            "title": "Options (context menu)",
            "enum": [
              "Options"
            ]
          }
        ]
      },
      "playPauseButtonKey": {
        "title": "Play/Pause Button Key",
        "type": "string",
        "default": "PlayPause",
        "description": "The TV key that the HomeKit remote's play/pause button sends.",
        "oneOf": [
          {
            "title": "Play/Pause",
            "enum": [
              "PlayPause"
            ]
          },
          {
            "title": "Home",
            "enum": [
              "Home"
            ]
          },
          {
            "title": "Source (input picker)",
            "enum": [
              "Source"
            ]
          },
          {
            "title": "Online (smart TV portal)",
            "enum": [
              "Online"
            ]
          }
        ]
      },
      "inputs": {
        "title": "Custom Input Sources",
        "type": "array",
        "description": "Custom input sources to display in HomeKit. If not specified, apps will be fetched from the TV.",
        "items": {
          "type": "object",
          "title": "Input",
          "required": [
            "name",
            "type",
            "identifier"
          ],
          "properties": {
            "name": {
              "title": "Name",
              "type": "string",
              "description": "The display name for this input source."
            },
            "type": {
              "title": "Type",
              "type": "string",
              "oneOf": [
                {
                  "title": "App",
                  "enum": [
                    "app"
                  ]
                },
                {
                  "title": "Source",
                  "enum": [
                    "source"
                  ]
                },
                {
                  "title": "Channel",
                  "enum": [
                    "channel"
                  ]
                }
              ],
              "description": "The type of input source."
            },
            "identifier": {
              "title": "Identifier",
              "type": "string",
              "description": "The app package name, source ID, or channel number."
            },
            "displayOrder": {
              "title": "Display Order",
              "type": "integer",
              "minimum": 0,
              "description": "The order in which this input appears in HomeKit."
            }
          }
        }
      },
      "sourceSwitches": {
        "title": "Source Switches",
        "type": "boolean",
        "default": false,
        "description": "Expose each input source as a separate Switch accessory for use in HomeKit automations and scenes."
      },
      "ambilightHueSwitch": {
        "title": "Ambilight + Hue Switch",
        "type": "boolean",
        "default": false,
        "description": "Expose the Ambilight + Hue integration (Philips Hue lamps following Ambilight) as a separate Switch, toggleable independently of the main Ambilight controls."
      },
      "customApps": {
        "title": "Custom Apps",
        "type": "array",
        "description": "Apps the TV does not report via its app list (e.g. sideloaded apps). Added in addition to auto-discovered apps. Tip: open the app on your TV and use \"Detect from TV\" to fill these in automatically.",
        "items": {
          "type": "object",
          "title": "App",
          "properties": {
            "name": {
              "title": "Name",
              "type": "string",
              "description": "Display name shown in HomeKit."
            },
            "packageName": {
              "title": "Package Name",
              "type": "string",
              "description": "Android package name, e.g. com.ug.eon.android.tv"
            },
            "className": {
              "title": "Launch Activity",
              "type": "string",
              "description": "Launch activity class name. Required for reliable launching."
            },
            "action": {
              "title": "Intent Action",
              "type": "string",
              "description": "Intent action (defaults to android.intent.action.MAIN)."
            }
          },
          "required": [
            "name",
            "packageName"
          ]
        }
      },
      "customButtons": {
        "title": "Custom Buttons",
        "type": "array",
        "description": "Switches that send a single remote key when turned on, then turn themselves back off. Useful with apps on the TV (e.g. Button Mapper) that remap a key to an action the TV's API doesn't offer, such as the power menu.",
        "items": {
          "type": "object",
          "title": "Button",
          "properties": {
            "name": {
              "title": "Name",
              "type": "string",
              "description": "Display name shown in HomeKit."
            },
            "key": {
              "title": "Remote Key",
              "type": "string",
              "oneOf": [
                {
                  "title": "Standby",
                  "enum": [
                    "Standby"
                  ]
                },
                {
                  "title": "Back",
                  "enum": [
                    "Back"
                  ]
                },
                {
                  "title": "Find (search)",
                  "enum": [
                    "Find"
                  ]
                },
                {
                  "title": "Red",
                  "enum": [
                    "RedColour"
                  ]
                },
                {
                  "title": "Green",
                  "enum": [
                    "GreenColour"
                  ]
                },
                {
                  "title": "Yellow",
                  "enum": [
                    "YellowColour"
                  ]
                },
                {
                  "title": "Blue",
                  "enum": [
                    "BlueColour"
                  ]
                },
                {
                  "title": "Home",
                  "enum": [
                    "Home"
                  ]
                },
                {
                  "title": "Volume Up",
                  "enum": [
                    "VolumeUp"
                  ]
                },
                {
                  "title": "Volume Down",
                  "enum": [
                    "VolumeDown"
                  ]
                },
                {
                  "title": "Mute",
                  "enum": [
                    "Mute"
                  ]
                },
                {
                  "title": "Options (context menu)",
                  "enum": [
                    "Options"
                  ]
                },
                {
                  "title": "Dot",
                  "enum": [
                    "Dot"
                  ]
                },
                {
                  "title": "Digit 0",
                  "enum": [
                    "Digit0"
                  ]
                },
                {
                  "title": "Digit 1",
                  "enum": [
                    "Digit1"
                  ]
                },
                {
                  "title": "Digit 2",
                  "enum": [
                    "Digit2"
                  ]
                },
                {
                  "title": "Digit 3",
                  "enum": [
                    "Digit3"
                  ]
                },
                {
                  "title": "Digit 4",
                  "enum": [
                    "Digit4"
                  ]
                },
                {
                  "title": "Digit 5",
                  "enum": [
                    "Digit5"
                  ]
                },
                {
                  "title": "Digit 6",
                  "enum": [
                    "Digit6"
                  ]
                },
                {
                  "title": "Digit 7",
                  "enum": [
                    "Digit7"
                  ]
                },
                {
                  "title": "Digit 8",
                  "enum": [
                    "Digit8"
                  ]
                },
                {
                  "title": "Digit 9",
                  "enum": [
                    "Digit9"
                  ]
                },
                {
                  "title": "Info (program details)",
                  "enum": [
                    "Info"
                  ]
                },
                {
                  "title": "Cursor Up",
                  "enum": [
                    "CursorUp"
                  ]
                },
                {
                  "title": "Cursor Down",
                  "enum": [
                    "CursorDown"
                  ]
                },
                {
                  "title": "Cursor Left",
                  "enum": [
                    "CursorLeft"
                  ]
                },
                {
                  "title": "Cursor Right",
                  "enum": [
                    "CursorRight"
                  ]
                },
                {
                  "title": "Confirm (OK)",
                  "enum": [
                    "Confirm"
                  ]
                },
                {
                  "title": "Next",
                  "enum": [
                    "Next"
                  ]
                },
                {
                  "title": "Previous",
                  "enum": [
                    "Previous"
                  ]
                },
                {
                  "title": "Adjust",
                  "enum": [
                    "Adjust"
                  ]
                },
                {
                  "title": "Watch TV",
                  "enum": [
                    "WatchTV"
                  ]
                },
                {
                  "title": "View Mode",
                  "enum": [
                    "Viewmode"
                  ]
                },
                {
                  "title": "Teletext",
                  "enum": [
                    "Teletext"
                  ]
                },
                {
                  "title": "Subtitles",
                  "enum": [
                    "Subtitle"
                  ]
                },
                {
                  "title": "Channel Up",
                  "enum": [
                    "ChannelStepUp"
                  ]
                },
                {
                  "title": "Channel Down",
                  "enum": [
                    "ChannelStepDown"
                  ]
                },
                {
                  "title": "Source (input picker)",
                  "enum": [
                    "Source"
                  ]
                },
                {
                  "title": "Ambilight On/Off",
                  "enum": [
                    "AmbilightOnOff"
                  ]
                },
                {
                  "title": "Play/Pause",
                  "enum": [
                    "PlayPause"
                  ]
                },
                {
                  "title": "Pause",
                  "enum": [
                    "Pause"
                  ]
                },
                {
                  "title": "Fast Forward",
                  "enum": [
                    "FastForward"
                  ]
                },
                {
                  "title": "Stop",
                  "enum": [
                    "Stop"
                  ]
                },
                {
                  "title": "Rewind",
                  "enum": [
                    "Rewind"
                  ]
                },
                {
                  "title": "Record",
                  "enum": [
                    "Record"
                  ]
                },
                {
                  "title": "Online (smart TV portal)",
                  "enum": [
                    "Online"
                  ]
                }
              ],
              "description": "The remote key sent when the switch is turned on. Each key can be used by one button only."
            }
          },
          "required": [
            "name",
            "key"
          ]
        }
      },
      "stateSensors": {
        "title": "State Sensors",
        "type": "array",
        "uniqueItems": true,
        "description": "Expose TV states as MotionSensor services for HomeKit automations. Motion is detected when the state is active.",
        "items": {
          "type": "string",
          "oneOf": [
            {
              "title": "Power (TV On/Off)",
              "enum": [
                "power"
              ]
            },
            {
              "title": "Ambilight (Active/Inactive)",
              "enum": [
                "ambilight"
              ]
            },
            {
              "title": "Muted (Yes/No)",
              "enum": [
                "mute"
              ]
            }
          ]
        }
      },
      "sources": {
        "title": "Source Configuration",
        "type": "array",
        "description": "Order, visibility and names of the inputs in the Home app's input wheel. The plugin's page shows the TV's inputs in that order, with their IDs.",
        "items": {
          "type": "object",
          "title": "Source",
          "properties": {
            "id": {
              "title": "Source ID",
              "type": "string",
              "description": "The unique identifier for this source."
            },
            "order": {
              "title": "Display Order",
              "type": "integer",
              "minimum": 0,
              "description": "The order in which this source appears in HomeKit."
            },
            "visible": {
              "title": "Visible",
              "type": "boolean",
              "default": true,
              "description": "Whether this source is visible in HomeKit."
            },
            "customName": {
              "title": "Custom Name",
              "type": "string",
              "description": "Optional custom name to display instead of the default."
            }
          }
        }
      }
    }
  },
  "layout": [
    "name",
    "devices"
  ],
  "i18n": {
    "fr": {
      "Adjust": "Ajuster",
      "Ambilight (Active/Inactive)": "Ambilight (actif ou inactif)",
      "Ambilight + Hue Switch": "Interrupteur Ambilight + Hue",
      "Ambilight Mode": "Mode Ambilight",
      "Ambilight On/Off": "Ambilight marche/arrêt",
      "Android package name, e.g. com.ug.eon.android.tv": "Nom du paquet Android, par exemple com.ug.eon.android.tv",
      "App": "App",
      "Apps the TV does not report via its app list (e.g. sideloaded apps). Added in addition to auto-discovered apps. Tip: open the app on your TV and use \"Detect from TV\" to fill these in automatically.": "Apps que le téléviseur ne signale pas dans sa liste d'apps (par exemple des apps installées manuellement). Elles s'ajoutent aux apps découvertes automatiquement. Astuce : ouvrez l'app sur votre téléviseur et utilisez « Détecter sur le téléviseur » pour remplir ces champs automatiquement.",
      "Automatically turn Ambilight on (in the mode above) whenever the TV powers on.": "Allume automatiquement Ambilight (dans le mode ci-dessus) chaque fois que le téléviseur s'allume.",
      "Back": "Retour",
      "Back Button Key": "Touche du bouton Retour",
      "Blue": "Bleu",
      "Button": "Bouton",
      "Channel": "Chaîne",
      "Channel Down": "Chaîne précédente",
      "Channel Up": "Chaîne suivante",
      "Confirm (OK)": "Confirmer (OK)",
      "Cursor Down": "Curseur bas",
      "Cursor Left": "Curseur gauche",
      "Cursor Right": "Curseur droite",
      "Cursor Up": "Curseur haut",
      "Custom Apps": "Apps personnalisées",
      "Custom Buttons": "Boutons personnalisés",
      "Custom Input Sources": "Sources d'entrée personnalisées",
      "Custom Name": "Nom personnalisé",
      "Custom input sources to display in HomeKit. If not specified, apps will be fetched from the TV.": "Sources d'entrée personnalisées à afficher dans HomeKit. Sans elles, les apps sont récupérées sur le téléviseur.",
      "Digit 0": "Chiffre 0",
      "Digit 1": "Chiffre 1",
      "Digit 2": "Chiffre 2",
      "Digit 3": "Chiffre 3",
      "Digit 4": "Chiffre 4",
      "Digit 5": "Chiffre 5",
      "Digit 6": "Chiffre 6",
      "Digit 7": "Chiffre 7",
      "Digit 8": "Chiffre 8",
      "Digit 9": "Chiffre 9",
      "Display Order": "Ordre d'affichage",
      "Display name shown in HomeKit.": "Nom affiché dans HomeKit.",
      "Dot": "Point",
      "Enable Wake-on-LAN to turn on the TV from standby.": "Active Wake-on-LAN pour allumer le téléviseur depuis la veille.",
      "Expose TV states as MotionSensor services for HomeKit automations. Motion is detected when the state is active.": "Présente des états du téléviseur comme services MotionSensor pour les automatisations HomeKit. Un mouvement est détecté quand l'état est actif.",
      "Expose each input source as a separate Switch accessory for use in HomeKit automations and scenes.": "Présente chaque source d'entrée comme un accessoire interrupteur distinct, pour les automatisations et les scènes HomeKit.",
      "Expose the Ambilight + Hue integration (Philips Hue lamps following Ambilight) as a separate Switch, toggleable independently of the main Ambilight controls.": "Présente l'intégration Ambilight + Hue (des lampes Philips Hue qui suivent Ambilight) comme un interrupteur distinct, utilisable indépendamment des commandes Ambilight principales.",
      "Fast Forward": "Avance rapide",
      "Find (search)": "Rechercher",
      "Follow Audio - Energy Brightness": "Suivre l'audio - Luminosité énergique",
      "Follow Audio - Energy Colors": "Suivre l'audio - Couleurs énergiques",
      "Follow Audio - Party": "Suivre l'audio - Fête",
      "Follow Audio - Spectrum": "Suivre l'audio - Spectre",
      "Follow Audio - VU Meter": "Suivre l'audio - Vumètre",
      "Follow Video - Comfort": "Suivre la vidéo - Confort",
      "Follow Video - Football": "Suivre la vidéo - Football",
      "Follow Video - Game": "Suivre la vidéo - Jeu",
      "Follow Video - Natural": "Suivre la vidéo - Naturel",
      "Follow Video - Relax": "Suivre la vidéo - Détente",
      "Follow Video - Standard": "Suivre la vidéo - Standard",
      "Follow Video - Vivid": "Suivre la vidéo - Vif",
      "Green": "Vert",
      "Home": "Accueil",
      "How often to poll the TV for state updates (in milliseconds).": "Fréquence à laquelle l'état du téléviseur est interrogé (en millisecondes).",
      "IP Address": "Adresse IP",
      "Identifier": "Identifiant",
      "Info (program details)": "Info (détails du programme)",
      "Info Button Key": "Touche du bouton Info",
      "Input": "Entrée",
      "Intent Action": "Action de l'intent",
      "Intent action (defaults to android.intent.action.MAIN).": "Action de l'intent (android.intent.action.MAIN par défaut).",
      "Launch Activity": "Activité de lancement",
      "Launch activity class name. Required for reliable launching.": "Nom de la classe de l'activité de lancement. Nécessaire pour un lancement fiable.",
      "Lounge Light": "Lounge Light",
      "MAC Address": "Adresse MAC",
      "Mute": "Muet",
      "Muted (Yes/No)": "Son coupé (oui ou non)",
      "Name": "Nom",
      "Next": "Suivant",
      "Online (smart TV portal)": "Online (portail Smart TV)",
      "Optional custom name to display instead of the default.": "Nom personnalisé facultatif, affiché à la place du nom par défaut.",
      "Options (context menu)": "Options (menu contextuel)",
      "Order, visibility and names of the inputs in the Home app's input wheel. The plugin's page shows the TV's inputs in that order, with their IDs.": "Ordre, visibilité et noms des entrées dans la roue des entrées de l'app Maison. La page du plugin montre les entrées du téléviseur dans cet ordre, avec leurs identifiants.",
      "Package Name": "Nom du paquet",
      "Pause": "Pause",
      "Play/Pause": "Lecture/Pause",
      "Play/Pause Button Key": "Touche du bouton Lecture/Pause",
      "Plugin name as displayed in the log.": "Nom du plugin tel qu'il apparaît dans le journal.",
      "Polling Interval (ms)": "Intervalle d'interrogation (ms)",
      "Power (TV On/Off)": "Alimentation (téléviseur allumé ou éteint)",
      "Previous": "Précédent",
      "Record": "Enregistrer",
      "Red": "Rouge",
      "Remote Key": "Touche de la télécommande",
      "Rewind": "Retour rapide",
      "Source": "Source",
      "Source (input picker)": "Source (choix de l'entrée)",
      "Source Configuration": "Configuration des sources",
      "Source ID": "Identifiant de la source",
      "Source Switches": "Interrupteurs de source",
      "Standby": "Veille",
      "Start Ambilight when TV turns on": "Lancer Ambilight à l'allumage du téléviseur",
      "State Sensors": "Capteurs d'état",
      "Stop": "Arrêt",
      "Subtitles": "Sous-titres",
      "Switches that send a single remote key when turned on, then turn themselves back off. Useful with apps on the TV (e.g. Button Mapper) that remap a key to an action the TV's API doesn't offer, such as the power menu.": "Interrupteurs qui envoient une touche de télécommande quand on les allume, puis s'éteignent d'eux-mêmes. Utile avec les apps du téléviseur (par exemple Button Mapper) qui associent une touche à une action que l'API du téléviseur n'offre pas, comme le menu d'alimentation.",
      "TV": "Téléviseur",
      "TV Name": "Nom du téléviseur",
      "TVs Add accessories does not find on the network (another subnet, Bonjour blocked): each one's name and IP address, and its MAC address if you know it. Setup pairs it there and keeps it in its own settings.": "Les téléviseurs qu'Ajouter des accessoires ne trouve pas sur le réseau (autre sous-réseau, Bonjour bloqué) : le nom et l'adresse IP de chacun, et son adresse MAC si vous la connaissez. Setup l'y appaire et le garde dans ses propres réglages.",
      "TVs to Find by Address": "Téléviseurs à trouver par leur adresse",
      "Teletext": "Télétexte",
      "The IP address of the TV on the local network.": "L'adresse IP du téléviseur sur le réseau local.",
      "The MAC address of the TV (required for Wake-on-LAN).": "L'adresse MAC du téléviseur (nécessaire pour Wake-on-LAN).",
      "The TV key that the HomeKit remote's back button sends.": "La touche du téléviseur qu'envoie le bouton Retour de la télécommande HomeKit.",
      "The TV key that the HomeKit remote's information button sends.": "La touche du téléviseur qu'envoie le bouton d'information de la télécommande HomeKit.",
      "The TV key that the HomeKit remote's play/pause button sends.": "La touche du téléviseur qu'envoie le bouton lecture/pause de la télécommande HomeKit.",
      "The ambilight mode to activate when turning on via HomeKit.": "Le mode Ambilight à activer lors de l'allumage depuis HomeKit.",
      "The app package name, source ID, or channel number.": "Le nom du paquet de l'app, l'identifiant de la source ou le numéro de la chaîne.",
      "The display name for this input source.": "Le nom affiché de cette source d'entrée.",
      "The name of the TV as it will appear in HomeKit.": "Le nom du téléviseur tel qu'il apparaîtra dans HomeKit.",
      "The order in which this input appears in HomeKit.": "L'ordre dans lequel cette entrée apparaît dans HomeKit.",
      "The order in which this source appears in HomeKit.": "L'ordre dans lequel cette source apparaît dans HomeKit.",
      "The remote key sent when the switch is turned on. Each key can be used by one button only.": "La touche de télécommande envoyée quand l'interrupteur est allumé. Chaque touche ne peut servir qu'à un seul bouton.",
      "The type of input source.": "Le type de source d'entrée.",
      "The unique identifier for this source.": "L'identifiant unique de cette source.",
      "Type": "Type",
      "View Mode": "Mode d'affichage",
      "Visible": "Visible",
      "Volume Down": "Baisser le volume",
      "Volume Up": "Monter le volume",
      "Wake-on-LAN": "Wake-on-LAN",
      "Watch TV": "Regarder la TV",
      "Whether this source is visible in HomeKit.": "Indique si cette source est visible dans HomeKit.",
      "Yellow": "Jaune"
    },
    "es": {
      "Adjust": "Ajustar",
      "Ambilight (Active/Inactive)": "Ambilight (activo o inactivo)",
      "Ambilight + Hue Switch": "Interruptor Ambilight + Hue",
      "Ambilight Mode": "Modo Ambilight",
      "Ambilight On/Off": "Ambilight encendido/apagado",
      "Android package name, e.g. com.ug.eon.android.tv": "Nombre del paquete Android, por ejemplo com.ug.eon.android.tv",
      "App": "App",
      "Apps the TV does not report via its app list (e.g. sideloaded apps). Added in addition to auto-discovered apps. Tip: open the app on your TV and use \"Detect from TV\" to fill these in automatically.": "Apps que el televisor no indica en su lista de apps (por ejemplo, apps instaladas manualmente). Se añaden a las apps descubiertas automáticamente. Consejo: abre la app en tu televisor y usa «Detectar en el televisor» para rellenar estos campos automáticamente.",
      "Automatically turn Ambilight on (in the mode above) whenever the TV powers on.": "Enciende Ambilight automáticamente (en el modo de arriba) cada vez que el televisor se enciende.",
      "Back": "Atrás",
      "Back Button Key": "Tecla del botón Atrás",
      "Blue": "Azul",
      "Button": "Botón",
      "Channel": "Canal",
      "Channel Down": "Canal anterior",
      "Channel Up": "Canal siguiente",
      "Confirm (OK)": "Confirmar (OK)",
      "Cursor Down": "Cursor abajo",
      "Cursor Left": "Cursor izquierda",
      "Cursor Right": "Cursor derecha",
      "Cursor Up": "Cursor arriba",
      "Custom Apps": "Apps personalizadas",
      "Custom Buttons": "Botones personalizados",
      "Custom Input Sources": "Fuentes de entrada personalizadas",
      "Custom Name": "Nombre personalizado",
      "Custom input sources to display in HomeKit. If not specified, apps will be fetched from the TV.": "Fuentes de entrada personalizadas que se muestran en HomeKit. Si no indicas ninguna, las apps se obtienen del televisor.",
      "Digit 0": "Dígito 0",
      "Digit 1": "Dígito 1",
      "Digit 2": "Dígito 2",
      "Digit 3": "Dígito 3",
      "Digit 4": "Dígito 4",
      "Digit 5": "Dígito 5",
      "Digit 6": "Dígito 6",
      "Digit 7": "Dígito 7",
      "Digit 8": "Dígito 8",
      "Digit 9": "Dígito 9",
      "Display Order": "Orden de visualización",
      "Display name shown in HomeKit.": "Nombre que se muestra en HomeKit.",
      "Dot": "Punto",
      "Enable Wake-on-LAN to turn on the TV from standby.": "Activa Wake-on-LAN para encender el televisor desde el modo de espera.",
      "Expose TV states as MotionSensor services for HomeKit automations. Motion is detected when the state is active.": "Muestra estados del televisor como servicios MotionSensor para las automatizaciones de HomeKit. Se detecta movimiento cuando el estado está activo.",
      "Expose each input source as a separate Switch accessory for use in HomeKit automations and scenes.": "Muestra cada fuente de entrada como un accesorio interruptor independiente, para las automatizaciones y escenas de HomeKit.",
      "Expose the Ambilight + Hue integration (Philips Hue lamps following Ambilight) as a separate Switch, toggleable independently of the main Ambilight controls.": "Muestra la integración Ambilight + Hue (luces Philips Hue que siguen a Ambilight) como un interruptor independiente, que se activa por separado de los controles principales de Ambilight.",
      "Fast Forward": "Avance rápido",
      "Find (search)": "Buscar",
      "Follow Audio - Energy Brightness": "Seguir audio - Brillo enérgico",
      "Follow Audio - Energy Colors": "Seguir audio - Colores enérgicos",
      "Follow Audio - Party": "Seguir audio - Fiesta",
      "Follow Audio - Spectrum": "Seguir audio - Espectro",
      "Follow Audio - VU Meter": "Seguir audio - Vúmetro",
      "Follow Video - Comfort": "Seguir vídeo - Confort",
      "Follow Video - Football": "Seguir vídeo - Fútbol",
      "Follow Video - Game": "Seguir vídeo - Juego",
      "Follow Video - Natural": "Seguir vídeo - Natural",
      "Follow Video - Relax": "Seguir vídeo - Relax",
      "Follow Video - Standard": "Seguir vídeo - Estándar",
      "Follow Video - Vivid": "Seguir vídeo - Intenso",
      "Green": "Verde",
      "Home": "Inicio",
      "How often to poll the TV for state updates (in milliseconds).": "Cada cuánto se consulta el estado del televisor (en milisegundos).",
      "IP Address": "Dirección IP",
      "Identifier": "Identificador",
      "Info (program details)": "Info (detalles del programa)",
      "Info Button Key": "Tecla del botón Info",
      "Input": "Entrada",
      "Intent Action": "Acción del intent",
      "Intent action (defaults to android.intent.action.MAIN).": "Acción del intent (android.intent.action.MAIN por defecto).",
      "Launch Activity": "Actividad de inicio",
      "Launch activity class name. Required for reliable launching.": "Nombre de la clase de la actividad de inicio. Necesario para que la app se abra de forma fiable.",
      "Lounge Light": "Lounge Light",
      "MAC Address": "Dirección MAC",
      "Mute": "Silencio",
      "Muted (Yes/No)": "Silenciado (sí o no)",
      "Name": "Nombre",
      "Next": "Siguiente",
      "Online (smart TV portal)": "Online (portal Smart TV)",
      "Optional custom name to display instead of the default.": "Nombre personalizado opcional que se muestra en lugar del predeterminado.",
      "Options (context menu)": "Opciones (menú contextual)",
      "Order, visibility and names of the inputs in the Home app's input wheel. The plugin's page shows the TV's inputs in that order, with their IDs.": "Orden, visibilidad y nombres de las entradas en la rueda de entradas de la app Casa. La página del plugin muestra las entradas del televisor en ese orden, con sus identificadores.",
      "Package Name": "Nombre del paquete",
      "Pause": "Pausa",
      "Play/Pause": "Reproducir/Pausa",
      "Play/Pause Button Key": "Tecla del botón Reproducir/Pausa",
      "Plugin name as displayed in the log.": "Nombre del plugin tal como aparece en el registro.",
      "Polling Interval (ms)": "Intervalo de consulta (ms)",
      "Power (TV On/Off)": "Encendido (televisor encendido o apagado)",
      "Previous": "Anterior",
      "Record": "Grabar",
      "Red": "Rojo",
      "Remote Key": "Tecla del mando",
      "Rewind": "Retroceso rápido",
      "Source": "Fuente",
      "Source (input picker)": "Fuente (selector de entrada)",
      "Source Configuration": "Configuración de fuentes",
      "Source ID": "ID de la fuente",
      "Source Switches": "Interruptores de fuente",
      "Standby": "En espera",
      "Start Ambilight when TV turns on": "Iniciar Ambilight al encender el televisor",
      "State Sensors": "Sensores de estado",
      "Stop": "Detener",
      "Subtitles": "Subtítulos",
      "Switches that send a single remote key when turned on, then turn themselves back off. Useful with apps on the TV (e.g. Button Mapper) that remap a key to an action the TV's API doesn't offer, such as the power menu.": "Interruptores que envían una tecla del mando al encenderse y luego se apagan solos. Útil con apps del televisor (por ejemplo, Button Mapper) que asignan a una tecla una acción que la API del televisor no ofrece, como el menú de encendido.",
      "TV": "Televisor",
      "TV Name": "Nombre del televisor",
      "TVs Add accessories does not find on the network (another subnet, Bonjour blocked): each one's name and IP address, and its MAC address if you know it. Setup pairs it there and keeps it in its own settings.": "Los televisores que Añadir accesorios no encuentra en la red (otra subred, Bonjour bloqueado): el nombre y la dirección IP de cada uno, y su dirección MAC si la conoces. Setup lo empareja allí y lo guarda en sus propios ajustes.",
      "TVs to Find by Address": "Televisores que buscar por su dirección",
      "Teletext": "Teletexto",
      "The IP address of the TV on the local network.": "La dirección IP del televisor en la red local.",
      "The MAC address of the TV (required for Wake-on-LAN).": "La dirección MAC del televisor (necesaria para Wake-on-LAN).",
      "The TV key that the HomeKit remote's back button sends.": "La tecla del televisor que envía el botón Atrás del mando de HomeKit.",
      "The TV key that the HomeKit remote's information button sends.": "La tecla del televisor que envía el botón de información del mando de HomeKit.",
      "The TV key that the HomeKit remote's play/pause button sends.": "La tecla del televisor que envía el botón de reproducir/pausa del mando de HomeKit.",
      "The ambilight mode to activate when turning on via HomeKit.": "El modo Ambilight que se activa al encenderlo desde HomeKit.",
      "The app package name, source ID, or channel number.": "El nombre del paquete de la app, el ID de la fuente o el número del canal.",
      "The display name for this input source.": "El nombre que se muestra para esta fuente de entrada.",
      "The name of the TV as it will appear in HomeKit.": "El nombre del televisor tal como aparecerá en HomeKit.",
      "The order in which this input appears in HomeKit.": "El orden en que esta entrada aparece en HomeKit.",
      "The order in which this source appears in HomeKit.": "El orden en que esta fuente aparece en HomeKit.",
      "The remote key sent when the switch is turned on. Each key can be used by one button only.": "La tecla del mando que se envía al encender el interruptor. Cada tecla solo puede usarla un botón.",
      "The type of input source.": "El tipo de fuente de entrada.",
      "The unique identifier for this source.": "El identificador único de esta fuente.",
      "Type": "Tipo",
      "View Mode": "Modo de visualización",
      "Visible": "Visible",
      "Volume Down": "Bajar volumen",
      "Volume Up": "Subir volumen",
      "Wake-on-LAN": "Wake-on-LAN",
      "Watch TV": "Ver TV",
      "Whether this source is visible in HomeKit.": "Si esta fuente es visible en HomeKit.",
      "Yellow": "Amarillo"
    },
    "pt": {
      "Adjust": "Ajustar",
      "Ambilight (Active/Inactive)": "Ambilight (ativo ou inativo)",
      "Ambilight + Hue Switch": "Interruptor Ambilight + Hue",
      "Ambilight Mode": "Modo Ambilight",
      "Ambilight On/Off": "Ambilight ligar/desligar",
      "Android package name, e.g. com.ug.eon.android.tv": "Nome do pacote Android, por exemplo com.ug.eon.android.tv",
      "App": "App",
      "Apps the TV does not report via its app list (e.g. sideloaded apps). Added in addition to auto-discovered apps. Tip: open the app on your TV and use \"Detect from TV\" to fill these in automatically.": "Apps que o televisor não indica na sua lista de apps (por exemplo, apps instaladas manualmente). São adicionadas às apps descobertas automaticamente. Sugestão: abra a app no televisor e utilize «Detetar no televisor» para preencher estes campos automaticamente.",
      "Automatically turn Ambilight on (in the mode above) whenever the TV powers on.": "Liga o Ambilight automaticamente (no modo acima) sempre que o televisor é ligado.",
      "Back": "Voltar",
      "Back Button Key": "Tecla do botão Voltar",
      "Blue": "Azul",
      "Button": "Botão",
      "Channel": "Canal",
      "Channel Down": "Canal anterior",
      "Channel Up": "Canal seguinte",
      "Confirm (OK)": "Confirmar (OK)",
      "Cursor Down": "Cursor para baixo",
      "Cursor Left": "Cursor para a esquerda",
      "Cursor Right": "Cursor para a direita",
      "Cursor Up": "Cursor para cima",
      "Custom Apps": "Apps personalizadas",
      "Custom Buttons": "Botões personalizados",
      "Custom Input Sources": "Fontes de entrada personalizadas",
      "Custom Name": "Nome personalizado",
      "Custom input sources to display in HomeKit. If not specified, apps will be fetched from the TV.": "Fontes de entrada personalizadas a apresentar no HomeKit. Sem nenhuma, as apps são obtidas do televisor.",
      "Digit 0": "Dígito 0",
      "Digit 1": "Dígito 1",
      "Digit 2": "Dígito 2",
      "Digit 3": "Dígito 3",
      "Digit 4": "Dígito 4",
      "Digit 5": "Dígito 5",
      "Digit 6": "Dígito 6",
      "Digit 7": "Dígito 7",
      "Digit 8": "Dígito 8",
      "Digit 9": "Dígito 9",
      "Display Order": "Ordem de apresentação",
      "Display name shown in HomeKit.": "Nome apresentado no HomeKit.",
      "Dot": "Ponto",
      "Enable Wake-on-LAN to turn on the TV from standby.": "Ativa o Wake-on-LAN para ligar o televisor a partir do modo de espera.",
      "Expose TV states as MotionSensor services for HomeKit automations. Motion is detected when the state is active.": "Apresenta estados do televisor como serviços MotionSensor para as automatizações do HomeKit. É detetado movimento quando o estado está ativo.",
      "Expose each input source as a separate Switch accessory for use in HomeKit automations and scenes.": "Apresenta cada fonte de entrada como um acessório interruptor separado, para as automatizações e cenas do HomeKit.",
      "Expose the Ambilight + Hue integration (Philips Hue lamps following Ambilight) as a separate Switch, toggleable independently of the main Ambilight controls.": "Apresenta a integração Ambilight + Hue (lâmpadas Philips Hue que seguem o Ambilight) como um interruptor separado, que se liga e desliga independentemente dos controlos principais do Ambilight.",
      "Fast Forward": "Avanço rápido",
      "Find (search)": "Pesquisar",
      "Follow Audio - Energy Brightness": "Seguir áudio - Brilho enérgico",
      "Follow Audio - Energy Colors": "Seguir áudio - Cores enérgicas",
      "Follow Audio - Party": "Seguir áudio - Festa",
      "Follow Audio - Spectrum": "Seguir áudio - Espectro",
      "Follow Audio - VU Meter": "Seguir áudio - Vu-metro",
      "Follow Video - Comfort": "Seguir vídeo - Conforto",
      "Follow Video - Football": "Seguir vídeo - Futebol",
      "Follow Video - Game": "Seguir vídeo - Jogo",
      "Follow Video - Natural": "Seguir vídeo - Natural",
      "Follow Video - Relax": "Seguir vídeo - Relaxar",
      "Follow Video - Standard": "Seguir vídeo - Padrão",
      "Follow Video - Vivid": "Seguir vídeo - Vívido",
      "Green": "Verde",
      "Home": "Início",
      "How often to poll the TV for state updates (in milliseconds).": "Frequência com que o estado do televisor é consultado (em milissegundos).",
      "IP Address": "Endereço IP",
      "Identifier": "Identificador",
      "Info (program details)": "Info (detalhes do programa)",
      "Info Button Key": "Tecla do botão Info",
      "Input": "Entrada",
      "Intent Action": "Ação do intent",
      "Intent action (defaults to android.intent.action.MAIN).": "Ação do intent (android.intent.action.MAIN por omissão).",
      "Launch Activity": "Atividade de arranque",
      "Launch activity class name. Required for reliable launching.": "Nome da classe da atividade de arranque. Necessário para um arranque fiável.",
      "Lounge Light": "Lounge Light",
      "MAC Address": "Endereço MAC",
      "Mute": "Sem som",
      "Muted (Yes/No)": "Sem som (sim ou não)",
      "Name": "Nome",
      "Next": "Seguinte",
      "Online (smart TV portal)": "Online (portal Smart TV)",
      "Optional custom name to display instead of the default.": "Nome personalizado opcional, apresentado em vez do predefinido.",
      "Options (context menu)": "Opções (menu de contexto)",
      "Order, visibility and names of the inputs in the Home app's input wheel. The plugin's page shows the TV's inputs in that order, with their IDs.": "Ordem, visibilidade e nomes das entradas na roda de entradas da app Casa. A página do plugin mostra as entradas do televisor nessa ordem, com os seus identificadores.",
      "Package Name": "Nome do pacote",
      "Pause": "Pausa",
      "Play/Pause": "Reproduzir/Pausa",
      "Play/Pause Button Key": "Tecla do botão Reproduzir/Pausa",
      "Plugin name as displayed in the log.": "Nome do plugin tal como aparece no registo.",
      "Polling Interval (ms)": "Intervalo de consulta (ms)",
      "Power (TV On/Off)": "Energia (televisor ligado ou desligado)",
      "Previous": "Anterior",
      "Record": "Gravar",
      "Red": "Vermelho",
      "Remote Key": "Tecla do comando",
      "Rewind": "Retrocesso rápido",
      "Source": "Fonte",
      "Source (input picker)": "Fonte (seletor de entrada)",
      "Source Configuration": "Configuração das fontes",
      "Source ID": "ID da fonte",
      "Source Switches": "Interruptores de fonte",
      "Standby": "Modo de espera",
      "Start Ambilight when TV turns on": "Iniciar o Ambilight quando o televisor liga",
      "State Sensors": "Sensores de estado",
      "Stop": "Parar",
      "Subtitles": "Legendas",
      "Switches that send a single remote key when turned on, then turn themselves back off. Useful with apps on the TV (e.g. Button Mapper) that remap a key to an action the TV's API doesn't offer, such as the power menu.": "Interruptores que enviam uma tecla do comando quando são ligados e depois se desligam sozinhos. Útil com apps do televisor (por exemplo, Button Mapper) que associam a uma tecla uma ação que a API do televisor não oferece, como o menu de energia.",
      "TV": "Televisor",
      "TV Name": "Nome do televisor",
      "TVs Add accessories does not find on the network (another subnet, Bonjour blocked): each one's name and IP address, and its MAC address if you know it. Setup pairs it there and keeps it in its own settings.": "Os televisores que Adicionar acessórios não encontra na rede (outra sub-rede, Bonjour bloqueado): o nome e o endereço IP de cada um, e o endereço MAC se o souber. O Setup emparelha-o aí e guarda-o nas suas próprias definições.",
      "TVs to Find by Address": "Televisores a encontrar pelo endereço",
      "Teletext": "Teletexto",
      "The IP address of the TV on the local network.": "O endereço IP do televisor na rede local.",
      "The MAC address of the TV (required for Wake-on-LAN).": "O endereço MAC do televisor (necessário para o Wake-on-LAN).",
      "The TV key that the HomeKit remote's back button sends.": "A tecla do televisor que o botão Voltar do comando do HomeKit envia.",
      "The TV key that the HomeKit remote's information button sends.": "A tecla do televisor que o botão de informação do comando do HomeKit envia.",
      "The TV key that the HomeKit remote's play/pause button sends.": "A tecla do televisor que o botão de reproduzir/pausa do comando do HomeKit envia.",
      "The ambilight mode to activate when turning on via HomeKit.": "O modo Ambilight a ativar quando é ligado a partir do HomeKit.",
      "The app package name, source ID, or channel number.": "O nome do pacote da app, o ID da fonte ou o número do canal.",
      "The display name for this input source.": "O nome apresentado desta fonte de entrada.",
      "The name of the TV as it will appear in HomeKit.": "O nome do televisor tal como aparecerá no HomeKit.",
      "The order in which this input appears in HomeKit.": "A ordem pela qual esta entrada aparece no HomeKit.",
      "The order in which this source appears in HomeKit.": "A ordem pela qual esta fonte aparece no HomeKit.",
      "The remote key sent when the switch is turned on. Each key can be used by one button only.": "A tecla do comando enviada quando o interruptor é ligado. Cada tecla só pode ser usada por um botão.",
      "The type of input source.": "O tipo de fonte de entrada.",
      "The unique identifier for this source.": "O identificador único desta fonte.",
      "Type": "Tipo",
      "View Mode": "Modo de visualização",
      "Visible": "Visível",
      "Volume Down": "Diminuir volume",
      "Volume Up": "Aumentar volume",
      "Wake-on-LAN": "Wake-on-LAN",
      "Watch TV": "Ver TV",
      "Whether this source is visible in HomeKit.": "Se esta fonte é visível no HomeKit.",
      "Yellow": "Amarelo"
    }
  }
}
"""#
}
