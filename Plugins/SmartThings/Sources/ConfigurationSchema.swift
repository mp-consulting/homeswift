// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension SmartThingsPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "HomeBridgeSmartThings",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "description": "Plugin name as displayed in the log",
        "default": "SmartThings",
        "required": true
      },
      "client_id": {
        "title": "OAuth Client Id",
        "type": "string",
        "description": "The client id of your own SmartThings OAuth-In app. Setup keeps it in the vault."
      },
      "locationId": {
        "title": "Location",
        "type": "string",
        "description": "The SmartThings location the sign-in was granted for; Setup writes it."
      },
      "BaseURL": {
        "title": "API address",
        "type": "string",
        "description": "SmartThings' API: https://api.smartthings.com/v1/, or https://api.samsungiotcloud.cn/v1/ in China. Another address is refused.",
        "default": "https://api.smartthings.com/v1/"
      },
      "callbackServerExternalAddress": {
        "title": "Callback server address",
        "type": "string",
        "description": "This bridge's address in the redirect URI https://<address>:<port>/oauth/callback, which the browser reaches after signing in; this host's network address by default."
      },
      "callbackServerPort": {
        "title": "Callback server port",
        "type": "integer",
        "description": "The port of the sign-in's HTTPS callback server, part of the redirect URI.",
        "default": 8583,
        "minimum": 1,
        "maximum": 65535
      },
      "PollSwitchesAndLightsSeconds": {
        "title": "Poll switches and lights (seconds)",
        "type": "integer",
        "description": "Without SmartThings' event stream the plugin reads every device in one call per period: the smallest Poll setting, at least 60 seconds (300 when none is set). 0 everywhere reads only every 30 minutes.",
        "minimum": 0,
        "placeholder": 10
      },
      "PollSensorsSeconds": {
        "title": "Poll sensors (seconds)",
        "type": "integer",
        "description": "Without SmartThings' event stream the plugin reads every device in one call per period: the smallest Poll setting, at least 60 seconds (300 when none is set). 0 everywhere reads only every 30 minutes.",
        "minimum": 0,
        "placeholder": 5
      },
      "PollLocksSeconds": {
        "title": "Poll locks (seconds)",
        "type": "integer",
        "description": "Without SmartThings' event stream the plugin reads every device in one call per period: the smallest Poll setting, at least 60 seconds (300 when none is set). 0 everywhere reads only every 30 minutes.",
        "minimum": 0,
        "placeholder": 10
      },
      "PollDoorsSeconds": {
        "title": "Poll garage doors (seconds)",
        "type": "integer",
        "description": "Without SmartThings' event stream the plugin reads every device in one call per period: the smallest Poll setting, at least 60 seconds (300 when none is set). 0 everywhere reads only every 30 minutes.",
        "minimum": 0,
        "placeholder": 10
      },
      "PollSecuritySystemsSeconds": {
        "title": "Poll security systems (seconds)",
        "type": "integer",
        "description": "Without SmartThings' event stream the plugin reads every device in one call per period: the smallest Poll setting, at least 60 seconds (300 when none is set). 0 everywhere reads only every 30 minutes.",
        "minimum": 0,
        "placeholder": 15
      },
      "PollTelevisionsSeconds": {
        "title": "Poll TVs (seconds)",
        "type": "integer",
        "description": "Without SmartThings' event stream the plugin reads every device in one call per period: the smallest Poll setting, at least 60 seconds (300 when none is set). 0 everywhere reads only every 30 minutes.",
        "minimum": 0,
        "placeholder": 15
      },
      "PollWindowShadesSeconds": {
        "title": "Poll window coverings (seconds)",
        "type": "integer",
        "description": "Without SmartThings' event stream the plugin reads every device in one call per period: the smallest Poll setting, at least 60 seconds (300 when none is set). 0 everywhere reads only every 30 minutes.",
        "minimum": 0,
        "placeholder": 20
      },
      "PollEnergySeconds": {
        "title": "Poll energy (seconds)",
        "type": "integer",
        "description": "Without SmartThings' event stream the plugin reads every device in one call per period: the smallest Poll setting, at least 60 seconds (300 when none is set). 0 everywhere reads only every 30 minutes.",
        "minimum": 0,
        "placeholder": 30
      },
      "IgnoreDevices": {
        "title": "Ignored devices",
        "type": "array",
        "description": "Device names left out. The bridge moves them to the devices' Excluded setting.",
        "items": {
          "type": "string"
        }
      },
      "ShowOnlyDevices": {
        "title": "Only these devices",
        "type": "array",
        "description": "When it has names, only these devices are shown and Ignored devices does nothing; the bridge moves the others to Excluded.",
        "items": {
          "type": "string"
        }
      },
      "IgnoreLocations": {
        "title": "Ignored locations",
        "type": "array",
        "description": "Location names whose devices are left out.",
        "items": {
          "type": "string"
        }
      },
      "thermostatModeOverrides": {
        "title": "Thermostat mode overrides",
        "type": "array",
        "description": "The modes some thermostats take for Heat and Cool, by name; the bridge moves them to each thermostat's settings.",
        "items": {
          "type": "object",
          "title": "Thermostat",
          "properties": {
            "deviceName": {
              "title": "Device name",
              "type": "string",
              "description": "The thermostat's name in SmartThings."
            },
            "heatMode": {
              "title": "Heat mode",
              "type": "string",
              "description": "The thermostat mode sent for Heat (heat by default)."
            },
            "coolMode": {
              "title": "Cool mode",
              "type": "string",
              "description": "The thermostat mode sent for Cool (cool by default)."
            }
          }
        }
      },
      "ExposeEnergyMonitoring": {
        "title": "Eve energy characteristics",
        "type": "boolean",
        "description": "Shows power, energy and voltage in the Eve app on switches and outlets that measure them. Their energy is a Homeswift Meter either way.",
        "default": false
      },
      "ExposeEnergyAsOutlet": {
        "title": "Metering switches as outlets",
        "type": "boolean",
        "description": "Shows switches that measure energy as outlets.",
        "default": false
      },
      "ExposeRobotVacuum": {
        "title": "Robot vacuum switch",
        "type": "boolean",
        "description": "A switch that starts a robot vacuum and sends it home.",
        "default": true
      },
      "removeLegacySwitchForLaundry": {
        "title": "No power switch on laundry",
        "type": "boolean",
        "description": "Leaves out the power switch of washers, dryers and dishwashers; one SmartThings can start remotely gets a Start switch instead.",
        "default": false
      },
      "ExposeMultiZoneRefrigerator": {
        "title": "Fridge compartments from the driver state",
        "type": "boolean",
        "description": "Reads a compartment's temperature from Samsung's driver state when SmartThings has none for it.",
        "default": false
      },
      "ExposeZigbangSmartDoorlock": {
        "title": "Zigbang smart door lock",
        "type": "boolean",
        "description": "A lock for Zigbang door locks, which SmartThings can unlock but not lock.",
        "default": false
      },
      "ExposeHumiditySensorForAirConditioners": {
        "title": "Humidity sensor on air conditioners",
        "type": "boolean",
        "description": "Adds a humidity sensor to air conditioners that report humidity.",
        "default": false
      },
      "ExposeACDisplayLight": {
        "title": "Air conditioner display light",
        "type": "boolean",
        "description": "A lightbulb for the display light of Samsung air conditioners.",
        "default": false
      },
      "OptionalModeForAirConditioners": {
        "title": "Air conditioner optional mode",
        "type": "string",
        "description": "Switches for a Samsung air conditioner's optional mode.",
        "default": "None",
        "oneOf": [
          {
            "enum": [
              "None"
            ],
            "title": "None"
          },
          {
            "enum": [
              "Sleep"
            ],
            "title": "Sleep"
          },
          {
            "enum": [
              "Speed"
            ],
            "title": "Speed"
          },
          {
            "enum": [
              "WindFree"
            ],
            "title": "WindFree"
          },
          {
            "enum": [
              "WindFreeSleep"
            ],
            "title": "WindFree Sleep"
          },
          {
            "enum": [
              "Speed and Windfree"
            ],
            "title": "Speed and WindFree"
          }
        ]
      },
      "enableTelevisionService": {
        "title": "TVs as televisions",
        "type": "boolean",
        "description": "Shows TVs as Television accessories with their inputs and remote; off, a TV is a switch.",
        "default": true
      },
      "publishTVsAsExternal": {
        "title": "Publish TVs on their own",
        "type": "boolean",
        "description": "Publishes each TV as an accessory of its own, added in the Home app with the bridge's setup code; off, it stays on the bridge.",
        "default": true
      },
      "registerVolumeSlider": {
        "title": "TV volume slider",
        "type": "boolean",
        "description": "Adds a lightbulb named after the TV and Volume, whose brightness is the TV's volume.",
        "default": false
      },
      "tvApps": {
        "title": "TV apps",
        "type": "array",
        "description": "Apps added to each Samsung TV's inputs.",
        "uniqueItems": true,
        "items": {
          "type": "string",
          "oneOf": [
            {
              "enum": [
                "3201907018807"
              ],
              "title": "Netflix"
            },
            {
              "enum": [
                "3201910019365"
              ],
              "title": "Prime Video"
            },
            {
              "enum": [
                "3201512006785"
              ],
              "title": "Prime Video (older TVs)"
            },
            {
              "enum": [
                "111299001912"
              ],
              "title": "YouTube"
            },
            {
              "enum": [
                "3201611010983"
              ],
              "title": "YouTube Kids"
            },
            {
              "enum": [
                "3201606009684"
              ],
              "title": "Spotify"
            },
            {
              "enum": [
                "3201901017640"
              ],
              "title": "Disney+"
            },
            {
              "enum": [
                "3201601007625"
              ],
              "title": "Hulu"
            },
            {
              "enum": [
                "3201710014981"
              ],
              "title": "Paramount+"
            },
            {
              "enum": [
                "3201807016597"
              ],
              "title": "Apple TV"
            },
            {
              "enum": [
                "3202006020991"
              ],
              "title": "Peacock TV"
            },
            {
              "enum": [
                "3201710015037"
              ],
              "title": "Gallery"
            },
            {
              "enum": [
                "3202301029760"
              ],
              "title": "HBO Max"
            },
            {
              "enum": [
                "111477000821"
              ],
              "title": "Shahid"
            },
            {
              "enum": [
                "3201608010191"
              ],
              "title": "Deezer"
            },
            {
              "enum": [
                "3201806016390"
              ],
              "title": "DAZN"
            },
            {
              "enum": [
                "3201708014618"
              ],
              "title": "ESPN"
            },
            {
              "enum": [
                "3202410037239"
              ],
              "title": "BeIN Sports"
            },
            {
              "enum": [
                "3201908019041"
              ],
              "title": "Apple Music"
            }
          ]
        }
      },
      "oauth_expires_in": {
        "title": "OAuth token lifetime",
        "type": "integer",
        "description": "Written by homebridge-smartthings-oauth's wizard: the bridge moves it into the vault with its next settings write."
      },
      "server_url": {
        "title": "Webhook server address",
        "type": "string",
        "description": "Kept from homebridge-smartthings; has no effect in Homeswift."
      },
      "webhook_port": {
        "title": "Webhook port",
        "type": "integer",
        "description": "Kept from homebridge-smartthings; has no effect in Homeswift."
      },
      "selectedCapabilities": {
        "title": "Webhook capabilities",
        "type": "array",
        "description": "Kept from homebridge-smartthings; has no effect in Homeswift.",
        "items": {
          "type": "string"
        }
      },
      "GarageDoorMaxPoll": {
        "title": "Garage door polls",
        "type": "integer",
        "description": "Kept from homebridge-smartthings; has no effect in Homeswift."
      },
      "ExposeContactSensorForWashers": {
        "title": "Washer activity sensor",
        "type": "boolean",
        "description": "Kept from homebridge-smartthings; has no effect in Homeswift."
      },
      "ExposeContactSensorForDryers": {
        "title": "Dryer activity sensor",
        "type": "boolean",
        "description": "Kept from homebridge-smartthings; has no effect in Homeswift."
      },
      "ExposeContactSensorForDishwashers": {
        "title": "Dishwasher activity sensor",
        "type": "boolean",
        "description": "Kept from homebridge-smartthings; has no effect in Homeswift."
      },
      "removeLegacySwitchForTV": {
        "title": "Remove the TV switch",
        "type": "boolean",
        "description": "Kept from homebridge-smartthings; has no effect in Homeswift."
      },
      "frameTvDevices": {
        "title": "Frame TVs",
        "type": "array",
        "description": "Kept from homebridge-smartthings; has no effect in Homeswift.",
        "items": {
          "type": "object"
        }
      },
      "UnregisterAll": {
        "title": "Unregister all",
        "type": "boolean",
        "description": "Kept from homebridge-smartthings; has no effect in Homeswift."
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "heatMode": {
        "title": "Heat mode",
        "type": "string",
        "description": "The thermostat mode sent for Heat (heat by default).",
        "x-kinds": [
          "thermostat"
        ]
      },
      "coolMode": {
        "title": "Cool mode",
        "type": "string",
        "description": "The thermostat mode sent for Cool (cool by default).",
        "x-kinds": [
          "thermostat"
        ]
      },
      "optionalMode": {
        "title": "Optional mode",
        "type": "string",
        "description": "Switches for the air conditioner's optional mode.",
        "oneOf": [
          {
            "enum": [
              "None"
            ],
            "title": "None"
          },
          {
            "enum": [
              "Sleep"
            ],
            "title": "Sleep"
          },
          {
            "enum": [
              "Speed"
            ],
            "title": "Speed"
          },
          {
            "enum": [
              "WindFree"
            ],
            "title": "WindFree"
          },
          {
            "enum": [
              "WindFreeSleep"
            ],
            "title": "WindFree Sleep"
          },
          {
            "enum": [
              "Speed and Windfree"
            ],
            "title": "Speed and WindFree"
          }
        ],
        "x-kinds": [
          "airConditioner"
        ],
        "x-default": "OptionalModeForAirConditioners"
      },
      "exposeHumidity": {
        "title": "Humidity sensor",
        "type": "boolean",
        "description": "Adds the air conditioner's humidity sensor.",
        "x-kinds": [
          "airConditioner"
        ],
        "x-default": "ExposeHumiditySensorForAirConditioners"
      },
      "displayLight": {
        "title": "Display light",
        "type": "boolean",
        "description": "A lightbulb for the air conditioner's display light.",
        "x-kinds": [
          "airConditioner"
        ],
        "x-default": "ExposeACDisplayLight"
      },
      "outlet": {
        "title": "Show as an outlet",
        "type": "boolean",
        "description": "Shows the switch as an outlet when it measures energy.",
        "x-kinds": [
          "switch",
          "outlet"
        ],
        "x-default": "ExposeEnergyAsOutlet"
      },
      "hiddenInputs": {
        "title": "Hidden inputs",
        "type": "array",
        "description": "TV inputs left out of the Home app's list, by their SmartThings id (HDMI1, dtv, an app's id).",
        "items": {
          "type": "string"
        },
        "x-kinds": [
          "television"
        ]
      }
    }
  },
  "layout": [
    "name",
    {
      "type": "fieldset",
      "title": "Account",
      "expandable": false,
      "items": [
        "client_id",
        "locationId",
        "BaseURL"
      ]
    },
    {
      "type": "fieldset",
      "title": "Sign-in callback",
      "expandable": true,
      "expanded": false,
      "items": [
        "callbackServerExternalAddress",
        "callbackServerPort"
      ]
    },
    {
      "type": "fieldset",
      "title": "Polling",
      "expandable": true,
      "expanded": false,
      "items": [
        "PollSwitchesAndLightsSeconds",
        "PollSensorsSeconds",
        "PollLocksSeconds",
        "PollDoorsSeconds",
        "PollSecuritySystemsSeconds",
        "PollTelevisionsSeconds",
        "PollWindowShadesSeconds",
        "PollEnergySeconds"
      ]
    },
    {
      "type": "fieldset",
      "title": "Devices",
      "expandable": true,
      "expanded": false,
      "items": [
        "IgnoreDevices",
        "ShowOnlyDevices",
        "IgnoreLocations",
        "thermostatModeOverrides",
        "ExposeEnergyMonitoring",
        "ExposeEnergyAsOutlet",
        "ExposeRobotVacuum",
        "removeLegacySwitchForLaundry",
        "ExposeMultiZoneRefrigerator",
        "ExposeZigbangSmartDoorlock"
      ]
    },
    {
      "type": "fieldset",
      "title": "Air conditioners",
      "expandable": true,
      "expanded": false,
      "items": [
        "ExposeHumiditySensorForAirConditioners",
        "ExposeACDisplayLight",
        "OptionalModeForAirConditioners"
      ]
    },
    {
      "type": "fieldset",
      "title": "TVs",
      "expandable": true,
      "expanded": false,
      "items": [
        "enableTelevisionService",
        "publishTVsAsExternal",
        "registerVolumeSlider",
        "tvApps"
      ]
    },
    {
      "type": "fieldset",
      "title": "From Homebridge",
      "expandable": true,
      "expanded": false,
      "items": [
        "oauth_expires_in",
        "server_url",
        "webhook_port",
        "selectedCapabilities",
        "GarageDoorMaxPoll",
        "ExposeContactSensorForWashers",
        "ExposeContactSensorForDryers",
        "ExposeContactSensorForDishwashers",
        "removeLegacySwitchForTV",
        "frameTvDevices",
        "UnregisterAll"
      ]
    }
  ],
  "i18n": {
    "fr": {
      "A lightbulb for the air conditioner's display light.": "Une ampoule pour le voyant du climatiseur.",
      "A lightbulb for the display light of Samsung air conditioners.": "Une ampoule pour le voyant de l'écran des climatiseurs Samsung.",
      "A lock for Zigbang door locks, which SmartThings can unlock but not lock.": "Une serrure pour les serrures Zigbang, que SmartThings peut déverrouiller mais pas verrouiller.",
      "A switch that starts a robot vacuum and sends it home.": "Un interrupteur qui lance un aspirateur robot et le renvoie à sa base.",
      "API address": "Adresse de l'API",
      "Account": "Compte",
      "Adds a humidity sensor to air conditioners that report humidity.": "Ajoute un capteur d'humidité aux climatiseurs qui la mesurent.",
      "Adds a lightbulb named after the TV and Volume, whose brightness is the TV's volume.": "Ajoute une ampoule au nom du téléviseur suivi de Volume, dont la luminosité est le volume du téléviseur.",
      "Adds the air conditioner's humidity sensor.": "Ajoute le capteur d'humidité du climatiseur.",
      "Air conditioner display light": "Voyant des climatiseurs",
      "Air conditioner optional mode": "Mode optionnel des climatiseurs",
      "Air conditioners": "Climatiseurs",
      "Apple Music": "Apple Music",
      "Apple TV": "Apple TV",
      "Apps added to each Samsung TV's inputs.": "Apps ajoutées aux entrées de chaque téléviseur Samsung.",
      "BeIN Sports": "BeIN Sports",
      "Callback server address": "Adresse du serveur de rappel",
      "Callback server port": "Port du serveur de rappel",
      "Cool mode": "Mode refroidissement",
      "DAZN": "DAZN",
      "Deezer": "Deezer",
      "Device name": "Nom de l'appareil",
      "Device names left out. The bridge moves them to the devices' Excluded setting.": "Noms d'appareils laissés de côté. Le pont les reporte dans le réglage Exclu des appareils.",
      "Devices": "Appareils",
      "Dishwasher activity sensor": "Capteur d'activité du lave-vaisselle",
      "Disney+": "Disney+",
      "Display light": "Voyant",
      "Dryer activity sensor": "Capteur d'activité du sèche-linge",
      "ESPN": "ESPN",
      "Eve energy characteristics": "Caractéristiques d'énergie Eve",
      "Frame TVs": "Téléviseurs Frame",
      "Fridge compartments from the driver state": "Compartiments du réfrigérateur selon l'état du pilote",
      "From Homebridge": "Depuis Homebridge",
      "Gallery": "Gallery",
      "Garage door polls": "Lectures des portes de garage",
      "HBO Max": "HBO Max",
      "Heat mode": "Mode chauffage",
      "Hidden inputs": "Entrées masquées",
      "Hulu": "Hulu",
      "Humidity sensor": "Capteur d'humidité",
      "Humidity sensor on air conditioners": "Capteur d'humidité sur les climatiseurs",
      "Ignored devices": "Appareils ignorés",
      "Ignored locations": "Lieux ignorés",
      "Kept from homebridge-smartthings; has no effect in Homeswift.": "Repris de homebridge-smartthings ; sans effet dans Homeswift.",
      "Leaves out the power switch of washers, dryers and dishwashers; one SmartThings can start remotely gets a Start switch instead.": "Laisse de côté l'interrupteur d'alimentation des lave-linge, sèche-linge et lave-vaisselle ; celui que SmartThings peut lancer à distance reçoit un interrupteur Démarrer à la place.",
      "Location": "Lieu",
      "Location names whose devices are left out.": "Noms de lieux dont les appareils sont laissés de côté.",
      "Metering switches as outlets": "Interrupteurs mesurés en prises",
      "Name": "Nom",
      "Netflix": "Netflix",
      "No power switch on laundry": "Pas d'interrupteur d'alimentation sur le linge",
      "None": "Aucun",
      "OAuth Client Id": "OAuth Client Id",
      "OAuth token lifetime": "Durée de vie du jeton OAuth",
      "Only these devices": "Seulement ces appareils",
      "Optional mode": "Mode optionnel",
      "Paramount+": "Paramount+",
      "Peacock TV": "Peacock TV",
      "Plugin name as displayed in the log": "Nom du plugin tel qu'il apparaît dans le journal",
      "Poll TVs (seconds)": "Lecture des téléviseurs (secondes)",
      "Poll energy (seconds)": "Lecture de l'énergie (secondes)",
      "Poll garage doors (seconds)": "Lecture des portes de garage (secondes)",
      "Poll locks (seconds)": "Lecture des serrures (secondes)",
      "Poll security systems (seconds)": "Lecture des systèmes de sécurité (secondes)",
      "Poll sensors (seconds)": "Lecture des capteurs (secondes)",
      "Poll switches and lights (seconds)": "Lecture des interrupteurs et lampes (secondes)",
      "Poll window coverings (seconds)": "Lecture des stores (secondes)",
      "Polling": "Lecture périodique",
      "Prime Video": "Prime Video",
      "Prime Video (older TVs)": "Prime Video (anciens téléviseurs)",
      "Publish TVs on their own": "Publier les téléviseurs à part",
      "Publishes each TV as an accessory of its own, added in the Home app with the bridge's setup code; off, it stays on the bridge.": "Publie chaque téléviseur comme accessoire à part, à ajouter dans l'app Maison avec le code de configuration du pont ; désactivé, il reste sur le pont.",
      "Reads a compartment's temperature from Samsung's driver state when SmartThings has none for it.": "Lit la température d'un compartiment dans l'état du pilote de Samsung quand SmartThings n'en a pas.",
      "Remove the TV switch": "Retirer l'interrupteur des téléviseurs",
      "Robot vacuum switch": "Interrupteur d'aspirateur robot",
      "Shahid": "Shahid",
      "Show as an outlet": "Afficher en prise",
      "Shows TVs as Television accessories with their inputs and remote; off, a TV is a switch.": "Affiche les téléviseurs comme accessoires Téléviseur avec leurs entrées et leur télécommande ; désactivé, un téléviseur est un interrupteur.",
      "Shows power, energy and voltage in the Eve app on switches and outlets that measure them. Their energy is a Homeswift Meter either way.": "Affiche la puissance, l'énergie et la tension dans l'app Eve sur les interrupteurs et prises qui les mesurent. Leur énergie est un compteur Homeswift dans tous les cas.",
      "Shows switches that measure energy as outlets.": "Affiche en prises les interrupteurs qui mesurent l'énergie.",
      "Shows the switch as an outlet when it measures energy.": "Affiche l'interrupteur en prise quand il mesure l'énergie.",
      "Sign-in callback": "Rappel de connexion",
      "Sleep": "Sommeil",
      "SmartThings' API: https://api.smartthings.com/v1/, or https://api.samsungiotcloud.cn/v1/ in China. Another address is refused.": "L'API de SmartThings : https://api.smartthings.com/v1/, ou https://api.samsungiotcloud.cn/v1/ en Chine. Toute autre adresse est refusée.",
      "Speed": "Rapide",
      "Speed and WindFree": "Rapide et WindFree",
      "Spotify": "Spotify",
      "Switches for a Samsung air conditioner's optional mode.": "Des interrupteurs pour le mode optionnel d'un climatiseur Samsung.",
      "Switches for the air conditioner's optional mode.": "Des interrupteurs pour le mode optionnel du climatiseur.",
      "TV apps": "Apps des téléviseurs",
      "TV inputs left out of the Home app's list, by their SmartThings id (HDMI1, dtv, an app's id).": "Entrées du téléviseur masquées dans la liste de l'app Maison, par leur identifiant SmartThings (HDMI1, dtv, l'identifiant d'une app).",
      "TV volume slider": "Curseur de volume des téléviseurs",
      "TVs": "Téléviseurs",
      "TVs as televisions": "Téléviseurs en téléviseurs",
      "The SmartThings location the sign-in was granted for; Setup writes it.": "Le lieu SmartThings pour lequel la connexion a été accordée ; la configuration l'écrit.",
      "The client id of your own SmartThings OAuth-In app. Setup keeps it in the vault.": "L'identifiant client de votre propre app OAuth-In SmartThings. La configuration le garde dans le coffre.",
      "The modes some thermostats take for Heat and Cool, by name; the bridge moves them to each thermostat's settings.": "Les modes que certains thermostats prennent pour Chauffer et Refroidir, par nom ; le pont les reporte dans les réglages de chaque thermostat.",
      "The port of the sign-in's HTTPS callback server, part of the redirect URI.": "Le port du serveur de rappel HTTPS de la connexion, qui fait partie de l'URI de redirection.",
      "The thermostat mode sent for Cool (cool by default).": "Le mode de thermostat envoyé pour Refroidir (cool par défaut).",
      "The thermostat mode sent for Heat (heat by default).": "Le mode de thermostat envoyé pour Chauffer (heat par défaut).",
      "The thermostat's name in SmartThings.": "Le nom du thermostat dans SmartThings.",
      "Thermostat": "Thermostat",
      "Thermostat mode overrides": "Modes de thermostat remplacés",
      "This bridge's address in the redirect URI https://<address>:<port>/oauth/callback, which the browser reaches after signing in; this host's network address by default.": "L'adresse de ce pont dans l'URI de redirection https://<address>:<port>/oauth/callback, que le navigateur atteint après la connexion ; l'adresse réseau de cet hôte par défaut.",
      "Unregister all": "Tout désinscrire",
      "Washer activity sensor": "Capteur d'activité du lave-linge",
      "Webhook capabilities": "Capacités des webhooks",
      "Webhook port": "Port du webhook",
      "Webhook server address": "Adresse du serveur webhook",
      "When it has names, only these devices are shown and Ignored devices does nothing; the bridge moves the others to Excluded.": "Quand elle a des noms, seuls ces appareils sont affichés et Appareils ignorés ne fait rien ; le pont reporte les autres en Exclu.",
      "WindFree": "WindFree",
      "WindFree Sleep": "WindFree Sommeil",
      "Without SmartThings' event stream the plugin reads every device in one call per period: the smallest Poll setting, at least 60 seconds (300 when none is set). 0 everywhere reads only every 30 minutes.": "Sans le flux d'événements de SmartThings, le plugin lit tous les appareils en un appel par période : le plus petit réglage Poll, 60 secondes au moins (300 si aucun n'est réglé). 0 partout ne lit que toutes les 30 minutes.",
      "Written by homebridge-smartthings-oauth's wizard: the bridge moves it into the vault with its next settings write.": "Écrit par l'assistant de homebridge-smartthings-oauth : le pont le déplace dans le coffre lors de sa prochaine écriture des réglages.",
      "YouTube": "YouTube",
      "YouTube Kids": "YouTube Kids",
      "Zigbang smart door lock": "Serrure connectée Zigbang"
    },
    "es": {
      "A lightbulb for the air conditioner's display light.": "Una bombilla para la luz del panel del aire acondicionado.",
      "A lightbulb for the display light of Samsung air conditioners.": "Una bombilla para la luz del panel de los aires acondicionados Samsung.",
      "A lock for Zigbang door locks, which SmartThings can unlock but not lock.": "Una cerradura para las cerraduras Zigbang, que SmartThings puede abrir pero no cerrar.",
      "A switch that starts a robot vacuum and sends it home.": "Un interruptor que pone en marcha un robot aspirador y lo envía a su base.",
      "API address": "Dirección de la API",
      "Account": "Cuenta",
      "Adds a humidity sensor to air conditioners that report humidity.": "Añade un sensor de humedad a los aires acondicionados que la miden.",
      "Adds a lightbulb named after the TV and Volume, whose brightness is the TV's volume.": "Añade una bombilla con el nombre del televisor y Volume, cuyo brillo es el volumen del televisor.",
      "Adds the air conditioner's humidity sensor.": "Añade el sensor de humedad del aire acondicionado.",
      "Air conditioner display light": "Luz del panel de los aires acondicionados",
      "Air conditioner optional mode": "Modo opcional de los aires acondicionados",
      "Air conditioners": "Aires acondicionados",
      "Apple Music": "Apple Music",
      "Apple TV": "Apple TV",
      "Apps added to each Samsung TV's inputs.": "Apps añadidas a las entradas de cada televisor Samsung.",
      "BeIN Sports": "BeIN Sports",
      "Callback server address": "Dirección del servidor de retorno",
      "Callback server port": "Puerto del servidor de retorno",
      "Cool mode": "Modo frío",
      "DAZN": "DAZN",
      "Deezer": "Deezer",
      "Device name": "Nombre del dispositivo",
      "Device names left out. The bridge moves them to the devices' Excluded setting.": "Nombres de dispositivos que se omiten. El puente los pasa al ajuste Excluido de los dispositivos.",
      "Devices": "Dispositivos",
      "Dishwasher activity sensor": "Sensor de actividad del lavavajillas",
      "Disney+": "Disney+",
      "Display light": "Luz del panel",
      "Dryer activity sensor": "Sensor de actividad de la secadora",
      "ESPN": "ESPN",
      "Eve energy characteristics": "Características de energía de Eve",
      "Frame TVs": "Televisores Frame",
      "Fridge compartments from the driver state": "Compartimentos del frigorífico desde el estado del controlador",
      "From Homebridge": "Desde Homebridge",
      "Gallery": "Gallery",
      "Garage door polls": "Lecturas de puertas de garaje",
      "HBO Max": "HBO Max",
      "Heat mode": "Modo calor",
      "Hidden inputs": "Entradas ocultas",
      "Hulu": "Hulu",
      "Humidity sensor": "Sensor de humedad",
      "Humidity sensor on air conditioners": "Sensor de humedad en los aires acondicionados",
      "Ignored devices": "Dispositivos ignorados",
      "Ignored locations": "Ubicaciones ignoradas",
      "Kept from homebridge-smartthings; has no effect in Homeswift.": "Heredado de homebridge-smartthings; no tiene efecto en Homeswift.",
      "Leaves out the power switch of washers, dryers and dishwashers; one SmartThings can start remotely gets a Start switch instead.": "Omite el interruptor de encendido de lavadoras, secadoras y lavavajillas; el que SmartThings puede poner en marcha a distancia recibe un interruptor Iniciar en su lugar.",
      "Location": "Ubicación",
      "Location names whose devices are left out.": "Nombres de ubicaciones cuyos dispositivos se omiten.",
      "Metering switches as outlets": "Interruptores con medición como enchufes",
      "Name": "Nombre",
      "Netflix": "Netflix",
      "No power switch on laundry": "Sin interruptor de encendido en la colada",
      "None": "Ninguno",
      "OAuth Client Id": "OAuth Client Id",
      "OAuth token lifetime": "Duración del token OAuth",
      "Only these devices": "Solo estos dispositivos",
      "Optional mode": "Modo opcional",
      "Paramount+": "Paramount+",
      "Peacock TV": "Peacock TV",
      "Plugin name as displayed in the log": "Nombre del plugin tal como aparece en el registro",
      "Poll TVs (seconds)": "Lectura de televisores (segundos)",
      "Poll energy (seconds)": "Lectura de energía (segundos)",
      "Poll garage doors (seconds)": "Lectura de puertas de garaje (segundos)",
      "Poll locks (seconds)": "Lectura de cerraduras (segundos)",
      "Poll security systems (seconds)": "Lectura de sistemas de seguridad (segundos)",
      "Poll sensors (seconds)": "Lectura de sensores (segundos)",
      "Poll switches and lights (seconds)": "Lectura de interruptores y luces (segundos)",
      "Poll window coverings (seconds)": "Lectura de persianas (segundos)",
      "Polling": "Lectura periódica",
      "Prime Video": "Prime Video",
      "Prime Video (older TVs)": "Prime Video (televisores antiguos)",
      "Publish TVs on their own": "Publicar los televisores por separado",
      "Publishes each TV as an accessory of its own, added in the Home app with the bridge's setup code; off, it stays on the bridge.": "Publica cada televisor como un accesorio aparte, que se añade en la app Casa con el código de configuración del puente; desactivado, se queda en el puente.",
      "Reads a compartment's temperature from Samsung's driver state when SmartThings has none for it.": "Lee la temperatura de un compartimento en el estado del controlador de Samsung cuando SmartThings no la tiene.",
      "Remove the TV switch": "Quitar el interruptor de los televisores",
      "Robot vacuum switch": "Interruptor del robot aspirador",
      "Shahid": "Shahid",
      "Show as an outlet": "Mostrar como enchufe",
      "Shows TVs as Television accessories with their inputs and remote; off, a TV is a switch.": "Muestra los televisores como accesorios Televisor con sus entradas y su mando; desactivado, un televisor es un interruptor.",
      "Shows power, energy and voltage in the Eve app on switches and outlets that measure them. Their energy is a Homeswift Meter either way.": "Muestra la potencia, la energía y la tensión en la app Eve en los interruptores y enchufes que las miden. Su energía es un medidor de Homeswift en cualquier caso.",
      "Shows switches that measure energy as outlets.": "Muestra como enchufes los interruptores que miden energía.",
      "Shows the switch as an outlet when it measures energy.": "Muestra el interruptor como enchufe cuando mide energía.",
      "Sign-in callback": "Retorno del inicio de sesión",
      "Sleep": "Sueño",
      "SmartThings' API: https://api.smartthings.com/v1/, or https://api.samsungiotcloud.cn/v1/ in China. Another address is refused.": "La API de SmartThings: https://api.smartthings.com/v1/, o https://api.samsungiotcloud.cn/v1/ en China. Cualquier otra dirección se rechaza.",
      "Speed": "Rápido",
      "Speed and WindFree": "Rápido y WindFree",
      "Spotify": "Spotify",
      "Switches for a Samsung air conditioner's optional mode.": "Interruptores para el modo opcional de un aire acondicionado Samsung.",
      "Switches for the air conditioner's optional mode.": "Interruptores para el modo opcional del aire acondicionado.",
      "TV apps": "Apps de los televisores",
      "TV inputs left out of the Home app's list, by their SmartThings id (HDMI1, dtv, an app's id).": "Entradas del televisor ocultas en la lista de la app Casa, por su id de SmartThings (HDMI1, dtv, el id de una app).",
      "TV volume slider": "Control deslizante de volumen de los televisores",
      "TVs": "Televisores",
      "TVs as televisions": "Televisores como televisores",
      "The SmartThings location the sign-in was granted for; Setup writes it.": "La ubicación de SmartThings para la que se concedió el inicio de sesión; la configuración la escribe.",
      "The client id of your own SmartThings OAuth-In app. Setup keeps it in the vault.": "El id de cliente de tu propia app OAuth-In de SmartThings. La configuración lo guarda en la bóveda.",
      "The modes some thermostats take for Heat and Cool, by name; the bridge moves them to each thermostat's settings.": "Los modos que algunos termostatos usan para Calor y Frío, por nombre; el puente los pasa a los ajustes de cada termostato.",
      "The port of the sign-in's HTTPS callback server, part of the redirect URI.": "El puerto del servidor de retorno HTTPS del inicio de sesión, parte de la URI de redirección.",
      "The thermostat mode sent for Cool (cool by default).": "El modo de termostato enviado para Frío (cool por defecto).",
      "The thermostat mode sent for Heat (heat by default).": "El modo de termostato enviado para Calor (heat por defecto).",
      "The thermostat's name in SmartThings.": "El nombre del termostato en SmartThings.",
      "Thermostat": "Termostato",
      "Thermostat mode overrides": "Modos de termostato sustituidos",
      "This bridge's address in the redirect URI https://<address>:<port>/oauth/callback, which the browser reaches after signing in; this host's network address by default.": "La dirección de este puente en la URI de redirección https://<address>:<port>/oauth/callback, a la que llega el navegador tras iniciar sesión; la dirección de red de este equipo por defecto.",
      "Unregister all": "Anular todos los registros",
      "Washer activity sensor": "Sensor de actividad de la lavadora",
      "Webhook capabilities": "Capacidades de los webhooks",
      "Webhook port": "Puerto del webhook",
      "Webhook server address": "Dirección del servidor webhook",
      "When it has names, only these devices are shown and Ignored devices does nothing; the bridge moves the others to Excluded.": "Cuando tiene nombres, solo se muestran estos dispositivos y Dispositivos ignorados no hace nada; el puente pasa los demás a Excluido.",
      "WindFree": "WindFree",
      "WindFree Sleep": "WindFree Sueño",
      "Without SmartThings' event stream the plugin reads every device in one call per period: the smallest Poll setting, at least 60 seconds (300 when none is set). 0 everywhere reads only every 30 minutes.": "Sin el flujo de eventos de SmartThings, el plugin lee todos los dispositivos en una llamada por periodo: el menor ajuste Poll, 60 segundos como mínimo (300 si no hay ninguno). 0 en todos solo lee cada 30 minutos.",
      "Written by homebridge-smartthings-oauth's wizard: the bridge moves it into the vault with its next settings write.": "Escrito por el asistente de homebridge-smartthings-oauth: el puente lo traslada a la bóveda en su próxima escritura de ajustes.",
      "YouTube": "YouTube",
      "YouTube Kids": "YouTube Kids",
      "Zigbang smart door lock": "Cerradura inteligente Zigbang"
    },
    "pt": {
      "A lightbulb for the air conditioner's display light.": "Uma lâmpada para a luz do painel do ar condicionado.",
      "A lightbulb for the display light of Samsung air conditioners.": "Uma lâmpada para a luz do painel dos ares condicionados Samsung.",
      "A lock for Zigbang door locks, which SmartThings can unlock but not lock.": "Uma fechadura para as fechaduras Zigbang, que o SmartThings pode destrancar mas não trancar.",
      "A switch that starts a robot vacuum and sends it home.": "Um interruptor que põe um robô aspirador a funcionar e o manda para a base.",
      "API address": "Endereço da API",
      "Account": "Conta",
      "Adds a humidity sensor to air conditioners that report humidity.": "Acrescenta um sensor de humidade aos ares condicionados que a medem.",
      "Adds a lightbulb named after the TV and Volume, whose brightness is the TV's volume.": "Acrescenta uma lâmpada com o nome do televisor e Volume, cujo brilho é o volume do televisor.",
      "Adds the air conditioner's humidity sensor.": "Acrescenta o sensor de humidade do ar condicionado.",
      "Air conditioner display light": "Luz do painel dos ares condicionados",
      "Air conditioner optional mode": "Modo opcional dos ares condicionados",
      "Air conditioners": "Ares condicionados",
      "Apple Music": "Apple Music",
      "Apple TV": "Apple TV",
      "Apps added to each Samsung TV's inputs.": "Apps acrescentadas às entradas de cada televisor Samsung.",
      "BeIN Sports": "BeIN Sports",
      "Callback server address": "Endereço do servidor de retorno",
      "Callback server port": "Porta do servidor de retorno",
      "Cool mode": "Modo arrefecimento",
      "DAZN": "DAZN",
      "Deezer": "Deezer",
      "Device name": "Nome do dispositivo",
      "Device names left out. The bridge moves them to the devices' Excluded setting.": "Nomes de dispositivos deixados de fora. A ponte passa-os para a definição Excluído dos dispositivos.",
      "Devices": "Dispositivos",
      "Dishwasher activity sensor": "Sensor de atividade da máquina de lavar loiça",
      "Disney+": "Disney+",
      "Display light": "Luz do painel",
      "Dryer activity sensor": "Sensor de atividade da máquina de secar",
      "ESPN": "ESPN",
      "Eve energy characteristics": "Características de energia da Eve",
      "Frame TVs": "Televisores Frame",
      "Fridge compartments from the driver state": "Compartimentos do frigorífico a partir do estado do controlador",
      "From Homebridge": "Do Homebridge",
      "Gallery": "Gallery",
      "Garage door polls": "Leituras de portas de garagem",
      "HBO Max": "HBO Max",
      "Heat mode": "Modo aquecimento",
      "Hidden inputs": "Entradas ocultas",
      "Hulu": "Hulu",
      "Humidity sensor": "Sensor de humidade",
      "Humidity sensor on air conditioners": "Sensor de humidade nos ares condicionados",
      "Ignored devices": "Dispositivos ignorados",
      "Ignored locations": "Localizações ignoradas",
      "Kept from homebridge-smartthings; has no effect in Homeswift.": "Herdado do homebridge-smartthings; não tem efeito no Homeswift.",
      "Leaves out the power switch of washers, dryers and dishwashers; one SmartThings can start remotely gets a Start switch instead.": "Deixa de fora o interruptor de energia das máquinas de lavar roupa, secar e lavar loiça; a que o SmartThings pode iniciar à distância recebe um interruptor Iniciar.",
      "Location": "Localização",
      "Location names whose devices are left out.": "Nomes de localizações cujos dispositivos ficam de fora.",
      "Metering switches as outlets": "Interruptores com medição como tomadas",
      "Name": "Nome",
      "Netflix": "Netflix",
      "No power switch on laundry": "Sem interruptor de energia na roupa",
      "None": "Nenhum",
      "OAuth Client Id": "OAuth Client Id",
      "OAuth token lifetime": "Duração do token OAuth",
      "Only these devices": "Só estes dispositivos",
      "Optional mode": "Modo opcional",
      "Paramount+": "Paramount+",
      "Peacock TV": "Peacock TV",
      "Plugin name as displayed in the log": "Nome do plugin tal como aparece no registo",
      "Poll TVs (seconds)": "Leitura de televisores (segundos)",
      "Poll energy (seconds)": "Leitura de energia (segundos)",
      "Poll garage doors (seconds)": "Leitura de portas de garagem (segundos)",
      "Poll locks (seconds)": "Leitura de fechaduras (segundos)",
      "Poll security systems (seconds)": "Leitura de sistemas de segurança (segundos)",
      "Poll sensors (seconds)": "Leitura de sensores (segundos)",
      "Poll switches and lights (seconds)": "Leitura de interruptores e luzes (segundos)",
      "Poll window coverings (seconds)": "Leitura de estores (segundos)",
      "Polling": "Leitura periódica",
      "Prime Video": "Prime Video",
      "Prime Video (older TVs)": "Prime Video (televisores antigos)",
      "Publish TVs on their own": "Publicar os televisores à parte",
      "Publishes each TV as an accessory of its own, added in the Home app with the bridge's setup code; off, it stays on the bridge.": "Publica cada televisor como um acessório à parte, adicionado na app Casa com o código de configuração da ponte; desativado, fica na ponte.",
      "Reads a compartment's temperature from Samsung's driver state when SmartThings has none for it.": "Lê a temperatura de um compartimento no estado do controlador da Samsung quando o SmartThings não a tem.",
      "Remove the TV switch": "Remover o interruptor dos televisores",
      "Robot vacuum switch": "Interruptor do robô aspirador",
      "Shahid": "Shahid",
      "Show as an outlet": "Mostrar como tomada",
      "Shows TVs as Television accessories with their inputs and remote; off, a TV is a switch.": "Mostra os televisores como acessórios Televisor com as suas entradas e comando; desativado, um televisor é um interruptor.",
      "Shows power, energy and voltage in the Eve app on switches and outlets that measure them. Their energy is a Homeswift Meter either way.": "Mostra a potência, a energia e a tensão na app Eve nos interruptores e tomadas que as medem. A sua energia é um contador do Homeswift em qualquer caso.",
      "Shows switches that measure energy as outlets.": "Mostra como tomadas os interruptores que medem energia.",
      "Shows the switch as an outlet when it measures energy.": "Mostra o interruptor como tomada quando mede energia.",
      "Sign-in callback": "Retorno do início de sessão",
      "Sleep": "Sono",
      "SmartThings' API: https://api.smartthings.com/v1/, or https://api.samsungiotcloud.cn/v1/ in China. Another address is refused.": "A API do SmartThings: https://api.smartthings.com/v1/, ou https://api.samsungiotcloud.cn/v1/ na China. Qualquer outro endereço é recusado.",
      "Speed": "Rápido",
      "Speed and WindFree": "Rápido e WindFree",
      "Spotify": "Spotify",
      "Switches for a Samsung air conditioner's optional mode.": "Interruptores para o modo opcional de um ar condicionado Samsung.",
      "Switches for the air conditioner's optional mode.": "Interruptores para o modo opcional do ar condicionado.",
      "TV apps": "Apps dos televisores",
      "TV inputs left out of the Home app's list, by their SmartThings id (HDMI1, dtv, an app's id).": "Entradas do televisor ocultas na lista da app Casa, pelo seu id do SmartThings (HDMI1, dtv, o id de uma app).",
      "TV volume slider": "Controlo de volume dos televisores",
      "TVs": "Televisores",
      "TVs as televisions": "Televisores como televisores",
      "The SmartThings location the sign-in was granted for; Setup writes it.": "A localização do SmartThings para a qual a sessão foi concedida; a configuração escreve-a.",
      "The client id of your own SmartThings OAuth-In app. Setup keeps it in the vault.": "O id de cliente da sua própria app OAuth-In do SmartThings. A configuração guarda-o no cofre.",
      "The modes some thermostats take for Heat and Cool, by name; the bridge moves them to each thermostat's settings.": "Os modos que alguns termóstatos usam para Aquecer e Arrefecer, por nome; a ponte passa-os para as definições de cada termóstato.",
      "The port of the sign-in's HTTPS callback server, part of the redirect URI.": "A porta do servidor de retorno HTTPS do início de sessão, parte do URI de redirecionamento.",
      "The thermostat mode sent for Cool (cool by default).": "O modo de termóstato enviado para Arrefecer (cool por omissão).",
      "The thermostat mode sent for Heat (heat by default).": "O modo de termóstato enviado para Aquecer (heat por omissão).",
      "The thermostat's name in SmartThings.": "O nome do termóstato no SmartThings.",
      "Thermostat": "Termóstato",
      "Thermostat mode overrides": "Modos de termóstato substituídos",
      "This bridge's address in the redirect URI https://<address>:<port>/oauth/callback, which the browser reaches after signing in; this host's network address by default.": "O endereço desta ponte no URI de redirecionamento https://<address>:<port>/oauth/callback, a que o navegador chega depois de iniciar sessão; o endereço de rede deste anfitrião por omissão.",
      "Unregister all": "Anular todos os registos",
      "Washer activity sensor": "Sensor de atividade da máquina de lavar",
      "Webhook capabilities": "Capacidades dos webhooks",
      "Webhook port": "Porta do webhook",
      "Webhook server address": "Endereço do servidor webhook",
      "When it has names, only these devices are shown and Ignored devices does nothing; the bridge moves the others to Excluded.": "Quando tem nomes, só estes dispositivos são mostrados e Dispositivos ignorados não faz nada; a ponte passa os outros para Excluído.",
      "WindFree": "WindFree",
      "WindFree Sleep": "WindFree Sono",
      "Without SmartThings' event stream the plugin reads every device in one call per period: the smallest Poll setting, at least 60 seconds (300 when none is set). 0 everywhere reads only every 30 minutes.": "Sem o fluxo de eventos do SmartThings, o plugin lê todos os dispositivos numa chamada por período: a menor definição Poll, 60 segundos no mínimo (300 se nenhuma estiver definida). 0 em todas só lê a cada 30 minutos.",
      "Written by homebridge-smartthings-oauth's wizard: the bridge moves it into the vault with its next settings write.": "Escrito pelo assistente do homebridge-smartthings-oauth: a ponte move-o para o cofre na sua próxima escrita de definições.",
      "YouTube": "YouTube",
      "YouTube Kids": "YouTube Kids",
      "Zigbang smart door lock": "Fechadura inteligente Zigbang"
    }
  }
}
"""#
}
