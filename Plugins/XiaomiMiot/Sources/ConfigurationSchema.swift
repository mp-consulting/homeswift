// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension XiaomiMiotPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "miot",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "description": "Names this instance in the log and in its data directory.",
        "type": "string",
        "default": "Xiaomi",
        "required": true
      },
      "micloud": {
        "title": "Xiaomi account",
        "description": "The cloud region, used to sign in and to list the account's devices. Setup signs in, and keeps the account in the vault; it is optional.",
        "type": "object",
        "properties": {
          "country": {
            "title": "Region",
            "description": "The Xiaomi cloud region of the account, as the Mi Home app shows it.",
            "type": "string",
            "default": "cn",
            "oneOf": [
              {
                "title": "Mainland China",
                "enum": [
                  "cn"
                ]
              },
              {
                "title": "Europe",
                "enum": [
                  "de"
                ]
              },
              {
                "title": "United States",
                "enum": [
                  "us"
                ]
              },
              {
                "title": "Russia",
                "enum": [
                  "ru"
                ]
              },
              {
                "title": "Taiwan",
                "enum": [
                  "tw"
                ]
              },
              {
                "title": "Singapore",
                "enum": [
                  "sg"
                ]
              },
              {
                "title": "India",
                "enum": [
                  "in"
                ]
              },
              {
                "title": "i2",
                "enum": [
                  "i2"
                ]
              }
            ]
          },
          "timeout": {
            "title": "Cloud timeout (ms)",
            "description": "How long a cloud request may take, in milliseconds: 2000 at least.",
            "type": "integer",
            "minimum": 2000,
            "default": 5000
          },
          "forceMiCloud": {
            "title": "Force the Xiaomi cloud",
            "description": "homebridge-miot's option to reach devices through the cloud. Not supported yet: devices stay on the local network, and the log says so.",
            "type": "boolean",
            "default": false
          }
        }
      },
      "pollingInterval": {
        "title": "Polling interval (seconds)",
        "description": "How often the device is asked for its state, in seconds: 15 by default. Values from 500 are read as milliseconds.",
        "type": "number",
        "minimum": 1
      },
      "pm25Breakpoints": {
        "title": "PM2.5 limits",
        "description": "Four increasing PM2.5 values (µg/m³) that end Excellent, Good, Fair and Inferior air; above the last is Poor. 7, 15, 30, 55 by default.",
        "type": "array",
        "minItems": 4,
        "maxItems": 4,
        "items": {
          "type": "integer",
          "title": "Limit",
          "description": "µg/m³"
        }
      },
      "co2AbnormalThreshold": {
        "title": "CO2 alarm level (ppm)",
        "description": "Carbon dioxide above this level (ppm) is abnormal: 1000 by default.",
        "type": "number",
        "minimum": 0,
        "default": 1000
      },
      "devices": {
        "title": "Devices (homebridge-miot)",
        "description": "homebridge-miot's list, read as it is with its tokens. Each entry with a did moves to that device's settings with the next settings write, its token to the vault.",
        "type": "array",
        "items": {
          "type": "object",
          "title": "Device",
          "properties": {
            "name": {
              "title": "Name",
              "description": "The accessory's name.",
              "type": "string"
            },
            "ip": {
              "title": "IP address",
              "description": "The device's address on the local network.",
              "type": "string"
            },
            "deviceId": {
              "title": "Device id (did)",
              "description": "The Xiaomi device id. Learned from the device when left out.",
              "type": "string"
            },
            "model": {
              "title": "Model",
              "description": "The device's model, such as zhimi.airpurifier.ma4. Asked from the device when left out.",
              "type": "string"
            }
          }
        }
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "ip": {
        "title": "IP address",
        "description": "Where the device answers on the local network. Updated when the device is seen at another address.",
        "type": "string"
      },
      "model": {
        "title": "Model",
        "description": "The device's model, such as yeelink.light.colorc: it chooses the spec. Asked from the device when empty.",
        "type": "string"
      },
      "pollingInterval": {
        "title": "Polling interval (seconds)",
        "description": "How often the device is asked for its state, in seconds: 15 by default. Values from 500 are read as milliseconds.",
        "type": "number",
        "minimum": 1,
        "x-default": "pollingInterval"
      },
      "propertyChunkSize": {
        "title": "Properties per request",
        "description": "How many properties one request reads, 1 to 14: lower it for a device that fails with 14.",
        "type": "integer",
        "minimum": 1,
        "maximum": 14
      },
      "deviceEnabled": {
        "title": "Polled",
        "description": "Off keeps the accessory without ever asking the device.",
        "type": "boolean",
        "default": true
      },
      "micloud": {
        "title": "Xiaomi account",
        "description": "This device's cloud options, over the plugin's.",
        "type": "object",
        "properties": {
          "country": {
            "title": "Region",
            "description": "The Xiaomi cloud region of the account, as the Mi Home app shows it.",
            "type": "string",
            "default": "cn",
            "oneOf": [
              {
                "title": "Mainland China",
                "enum": [
                  "cn"
                ]
              },
              {
                "title": "Europe",
                "enum": [
                  "de"
                ]
              },
              {
                "title": "United States",
                "enum": [
                  "us"
                ]
              },
              {
                "title": "Russia",
                "enum": [
                  "ru"
                ]
              },
              {
                "title": "Taiwan",
                "enum": [
                  "tw"
                ]
              },
              {
                "title": "Singapore",
                "enum": [
                  "sg"
                ]
              },
              {
                "title": "India",
                "enum": [
                  "in"
                ]
              },
              {
                "title": "i2",
                "enum": [
                  "i2"
                ]
              }
            ]
          },
          "timeout": {
            "title": "Cloud timeout (ms)",
            "description": "How long a cloud request may take, in milliseconds: 2000 at least.",
            "type": "integer",
            "minimum": 2000,
            "default": 5000
          },
          "forceMiCloud": {
            "title": "Force the Xiaomi cloud",
            "description": "homebridge-miot's option to reach devices through the cloud. Not supported yet: devices stay on the local network, and the log says so.",
            "type": "boolean",
            "default": false
          }
        }
      },
      "customAccessory": {
        "title": "Only extra controls",
        "description": "Leaves out what the spec maps on its own: the accessory has only the controls below.",
        "type": "boolean",
        "default": false
      },
      "onlyMainService": {
        "title": "Main service only",
        "description": "Leaves out the sensors, battery and filter beside the main service; extra controls still show.",
        "type": "boolean",
        "default": false
      },
      "buzzerControl": {
        "title": "Buzzer switch",
        "description": "A switch for the device's buzzer.",
        "type": "boolean",
        "default": false
      },
      "ledControl": {
        "title": "LED control",
        "description": "A switch, a slider or one switch per level for the device's indicator light.",
        "type": "boolean",
        "default": false
      },
      "childLockControl": {
        "title": "Child lock",
        "description": "The child lock as Lock Physical Controls on the main service.",
        "type": "boolean",
        "default": true,
        "x-kinds": [
          "fan",
          "airPurifier",
          "humidifier",
          "dehumidifier",
          "heater",
          "airConditioner"
        ]
      },
      "modeControl": {
        "title": "Mode switches",
        "description": "One switch per mode, on only while the device is.",
        "type": "boolean",
        "default": false
      },
      "screenControl": {
        "title": "Screen control",
        "description": "A switch for the screen, or one per brightness.",
        "type": "boolean",
        "default": false,
        "x-kinds": [
          "airPurifier",
          "humidifier"
        ]
      },
      "fanLevelControl": {
        "title": "Fan level switches",
        "description": "One switch per fan level; an air purifier's apply in its Favorite mode.",
        "type": "boolean",
        "default": false,
        "x-kinds": [
          "fan",
          "airPurifier",
          "humidifier",
          "dehumidifier",
          "airConditioner",
          "ceilingFan"
        ]
      },
      "swingControl": {
        "title": "Swing switches",
        "description": "Horizontal and vertical swing switches.",
        "type": "boolean",
        "default": false,
        "x-kinds": [
          "fan",
          "airConditioner"
        ]
      },
      "moveControl": {
        "title": "Move buttons",
        "description": "Buttons that turn the fan left, right, up or down one step.",
        "type": "boolean",
        "default": false,
        "x-kinds": [
          "fan"
        ]
      },
      "ioniserControl": {
        "title": "Ioniser switch",
        "description": "A switch for the ioniser, on only while the device is.",
        "type": "boolean",
        "default": false,
        "x-kinds": [
          "fan",
          "airPurifier"
        ]
      },
      "offDelayControl": {
        "title": "Off delay",
        "description": "A slider for the time before the device turns off, when the spec gives its unit.",
        "type": "boolean",
        "default": false,
        "x-kinds": [
          "fan",
          "heater",
          "outlet",
          "ceilingFan"
        ]
      },
      "heaterControl": {
        "title": "Heater switch",
        "description": "homebridge-miot's fresh air system option: read and kept, not used yet.",
        "type": "boolean",
        "default": false,
        "x-kinds": [
          "other"
        ]
      },
      "heatLevelControl": {
        "title": "Heat level switches",
        "description": "homebridge-miot's fresh air system option: read and kept, not used yet.",
        "type": "boolean",
        "default": false,
        "x-kinds": [
          "other"
        ]
      },
      "motorControl": {
        "title": "Motor buttons",
        "description": "One button per motor command (open, close, pause).",
        "type": "boolean",
        "default": false,
        "x-kinds": [
          "curtain"
        ]
      },
      "horizontalAngleButtons": {
        "title": "Horizontal angle buttons",
        "description": "Angles (1 to 360) each with a switch that sets it and turns the swing on. true in config.json gives the spec's angles.",
        "type": "array",
        "items": {
          "type": "integer",
          "minimum": 1,
          "maximum": 360,
          "title": "Angle",
          "description": "Degrees"
        },
        "x-kinds": [
          "fan"
        ]
      },
      "verticalAngleButtons": {
        "title": "Vertical angle buttons",
        "description": "Angles (1 to 360) each with a switch that sets it and turns the swing on. true in config.json gives the spec's angles.",
        "type": "array",
        "items": {
          "type": "integer",
          "minimum": 1,
          "maximum": 360,
          "title": "Angle",
          "description": "Degrees"
        },
        "x-kinds": [
          "fan"
        ]
      },
      "showTemperature": {
        "title": "Temperature sensor",
        "description": "Shows the outlet's temperature when its spec has one.",
        "type": "boolean",
        "default": true,
        "x-kinds": [
          "outlet"
        ]
      },
      "suppressAutoServiceCreation": {
        "title": "Sensors left out",
        "description": "Automatic sensors to leave out of the accessory.",
        "type": "array",
        "uniqueItems": true,
        "items": {
          "type": "string",
          "title": "Sensor",
          "oneOf": [
            {
              "title": "Temperature",
              "enum": [
                "temperature"
              ]
            },
            {
              "title": "Humidity",
              "enum": [
                "relativeHumidity"
              ]
            },
            {
              "title": "Light level",
              "enum": [
                "illumination"
              ]
            }
          ]
        }
      },
      "pm25Breakpoints": {
        "title": "PM2.5 limits",
        "description": "Four increasing PM2.5 values (µg/m³) that end Excellent, Good, Fair and Inferior air; above the last is Poor. 7, 15, 30, 55 by default.",
        "type": "array",
        "minItems": 4,
        "maxItems": 4,
        "items": {
          "type": "integer",
          "title": "Limit",
          "description": "µg/m³"
        },
        "x-kinds": [
          "airPurifier",
          "airMonitor"
        ]
      },
      "co2AbnormalThreshold": {
        "title": "CO2 alarm level (ppm)",
        "description": "Carbon dioxide above this level (ppm) is abnormal: 1000 by default.",
        "type": "number",
        "minimum": 0,
        "default": 1000,
        "x-kinds": [
          "airMonitor"
        ]
      },
      "foodAmount": {
        "title": "Food amount",
        "description": "homebridge-miot's pet feeder option: read and kept, not used yet.",
        "type": "integer",
        "minimum": 1,
        "x-kinds": [
          "other"
        ]
      },
      "actionButtons": {
        "title": "Action buttons",
        "description": "Buttons that run actions of the spec, by name (filter:reset-filter-life) or id (4.1). The plugin's page lists them; true in config.json makes one per action.",
        "type": "array",
        "items": {
          "type": "object",
          "title": "Action button",
          "properties": {
            "action": {
              "title": "Action",
              "description": "The action's name or id.",
              "type": "string"
            },
            "name": {
              "title": "Name",
              "description": "The button's name.",
              "type": "string"
            },
            "params": {
              "title": "Parameters",
              "description": "The action's in values, in order.",
              "type": "array",
              "items": {
                "title": "Value",
                "description": "A value"
              }
            }
          }
        }
      },
      "methodButtons": {
        "title": "Method buttons",
        "description": "Buttons that send a raw miIO method (find_me); the answer goes to the log.",
        "type": "array",
        "items": {
          "type": "object",
          "title": "Method button",
          "properties": {
            "method": {
              "title": "Method",
              "description": "The miIO method.",
              "type": "string"
            },
            "name": {
              "title": "Name",
              "description": "The button's name.",
              "type": "string"
            },
            "params": {
              "title": "Parameters",
              "description": "The method's parameters.",
              "type": "array",
              "items": {
                "title": "Value",
                "description": "A value"
              }
            }
          }
        }
      },
      "propertyControl": {
        "title": "Property controls",
        "description": "Controls for properties of the spec, by name (fan:anion) or id (2.7): a switch, a slider or one switch per value.",
        "type": "array",
        "items": {
          "type": "object",
          "title": "Property control",
          "properties": {
            "property": {
              "title": "Property",
              "description": "The property's name or id.",
              "type": "string"
            },
            "name": {
              "title": "Name",
              "description": "The control's name.",
              "type": "string"
            },
            "value": {
              "title": "Value",
              "description": "A value to set: the control is then a switch on while the property has it."
            },
            "linkedProperty": {
              "title": "Linked property",
              "description": "Another property that must be on, or have the linked value, for the control to read on.",
              "type": "string"
            },
            "linkedPropertyValue": {
              "title": "Linked value",
              "description": "The linked property's value."
            },
            "config": {
              "title": "Shown as",
              "description": "For a range: {\"type\": \"fan\"} shows a fan's speed instead of a light's brightness.",
              "type": "object"
            }
          }
        }
      },
      "propertyMonitor": {
        "title": "Property monitors",
        "description": "Sensors for properties of the spec: an occupancy sensor while a comparison holds, else a temperature or light sensor showing the value.",
        "type": "array",
        "items": {
          "type": "object",
          "title": "Property monitor",
          "properties": {
            "property": {
              "title": "Property",
              "description": "The property's name or id.",
              "type": "string"
            },
            "name": {
              "title": "Name",
              "description": "The sensor's name.",
              "type": "string"
            },
            "value": {
              "title": "Value",
              "description": "The value to compare with."
            },
            "valueOperator": {
              "title": "Comparison",
              "description": "How the property compares with the value.",
              "type": "string",
              "default": "equal",
              "oneOf": [
                {
                  "title": "Equal",
                  "enum": [
                    "equal"
                  ]
                },
                {
                  "title": "Less",
                  "enum": [
                    "less"
                  ]
                },
                {
                  "title": "Greater",
                  "enum": [
                    "greater"
                  ]
                },
                {
                  "title": "Less or equal",
                  "enum": [
                    "lessOrEqual"
                  ]
                },
                {
                  "title": "Greater or equal",
                  "enum": [
                    "greaterOrEqual"
                  ]
                },
                {
                  "title": "Contained in a list",
                  "enum": [
                    "contains"
                  ]
                }
              ]
            },
            "linkedProperty": {
              "title": "Linked property",
              "description": "Another property that must be on, or have the linked value, for the sensor to be active.",
              "type": "string"
            },
            "linkedPropertyValue": {
              "title": "Linked value",
              "description": "The linked property's value."
            }
          }
        }
      }
    }
  },
  "layout": [
    "name",
    {
      "type": "fieldset",
      "title": "Xiaomi account",
      "expandable": true,
      "items": [
        "micloud.country",
        "micloud.timeout",
        "micloud.forceMiCloud"
      ]
    },
    {
      "type": "fieldset",
      "title": "Defaults for every device",
      "expandable": true,
      "items": [
        "pollingInterval",
        "pm25Breakpoints",
        "co2AbnormalThreshold"
      ]
    }
  ],
  "i18n": {
    "fr": {
      "A slider for the time before the device turns off, when the spec gives its unit.": "Un curseur pour le délai avant l’arrêt de l’appareil, quand la spécification donne son unité.",
      "A switch for the device's buzzer.": "Un interrupteur pour le bip de l’appareil.",
      "A switch for the ioniser, on only while the device is.": "Un interrupteur pour l’ioniseur, actif seulement quand l’appareil l’est.",
      "A switch for the screen, or one per brightness.": "Un interrupteur pour l’écran, ou un par luminosité.",
      "A switch, a slider or one switch per level for the device's indicator light.": "Un interrupteur, un curseur ou un interrupteur par niveau pour le voyant de l’appareil.",
      "A value": "Une valeur",
      "A value to set: the control is then a switch on while the property has it.": "Une valeur à régler : la commande est alors un interrupteur actif tant que la propriété l’a.",
      "Action": "Action",
      "Action button": "Bouton d’action",
      "Action buttons": "Boutons d’action",
      "Angle": "Angle",
      "Angles (1 to 360) each with a switch that sets it and turns the swing on. true in config.json gives the spec's angles.": "Des angles (de 1 à 360) avec chacun un interrupteur qui le règle et lance l’oscillation. true dans config.json donne les angles de la spécification.",
      "Another property that must be on, or have the linked value, for the control to read on.": "Une autre propriété qui doit être active, ou avoir la valeur liée, pour que la commande soit active.",
      "Another property that must be on, or have the linked value, for the sensor to be active.": "Une autre propriété qui doit être active, ou avoir la valeur liée, pour que le capteur soit actif.",
      "Automatic sensors to leave out of the accessory.": "Les capteurs automatiques à laisser hors de l’accessoire.",
      "Buttons that run actions of the spec, by name (filter:reset-filter-life) or id (4.1). The plugin's page lists them; true in config.json makes one per action.": "Des boutons qui lancent des actions de la spécification, par nom (filter:reset-filter-life) ou id (4.1). La page du plugin les liste ; true dans config.json en fait un par action.",
      "Buttons that send a raw miIO method (find_me); the answer goes to the log.": "Des boutons qui envoient une méthode miIO brute (find_me) ; la réponse va dans le journal.",
      "Buttons that turn the fan left, right, up or down one step.": "Des boutons qui tournent le ventilateur d’un cran à gauche, à droite, en haut ou en bas.",
      "Buzzer switch": "Interrupteur du bip",
      "CO2 alarm level (ppm)": "Seuil d’alerte CO2 (ppm)",
      "Carbon dioxide above this level (ppm) is abnormal: 1000 by default.": "Au-delà de ce taux (ppm), le dioxyde de carbone est anormal : 1000 par défaut.",
      "Child lock": "Sécurité enfants",
      "Cloud timeout (ms)": "Délai du cloud (ms)",
      "Comparison": "Comparaison",
      "Contained in a list": "Contenue dans une liste",
      "Controls for properties of the spec, by name (fan:anion) or id (2.7): a switch, a slider or one switch per value.": "Des commandes pour des propriétés de la spécification, par nom (fan:anion) ou id (2.7) : un interrupteur, un curseur ou un interrupteur par valeur.",
      "Defaults for every device": "Valeurs par défaut des appareils",
      "Degrees": "Degrés",
      "Device": "Appareil",
      "Device id (did)": "Id de l’appareil (did)",
      "Devices (homebridge-miot)": "Appareils (homebridge-miot)",
      "Equal": "Égale",
      "Europe": "Europe",
      "Fan level switches": "Interrupteurs de vitesse",
      "Food amount": "Quantité de nourriture",
      "For a range: {\"type\": \"fan\"} shows a fan's speed instead of a light's brightness.": "Pour une plage : {\"type\": \"fan\"} affiche la vitesse d’un ventilateur au lieu de la luminosité d’une lampe.",
      "Force the Xiaomi cloud": "Forcer le cloud Xiaomi",
      "Four increasing PM2.5 values (µg/m³) that end Excellent, Good, Fair and Inferior air; above the last is Poor. 7, 15, 30, 55 by default.": "Quatre valeurs de PM2,5 croissantes (µg/m³) qui terminent un air Excellent, Bon, Moyen et Médiocre ; au-delà de la dernière, il est Mauvais. 7, 15, 30, 55 par défaut.",
      "Greater": "Supérieure",
      "Greater or equal": "Supérieure ou égale",
      "Heat level switches": "Interrupteurs de niveau de chauffage",
      "Heater switch": "Interrupteur de chauffage",
      "Horizontal and vertical swing switches.": "Des interrupteurs d’oscillation horizontale et verticale.",
      "Horizontal angle buttons": "Boutons d’angle horizontal",
      "How long a cloud request may take, in milliseconds: 2000 at least.": "Durée maximale d’une requête au cloud, en millisecondes : 2000 au moins.",
      "How many properties one request reads, 1 to 14: lower it for a device that fails with 14.": "Combien de propriétés une requête lit, de 1 à 14 : baissez-le pour un appareil qui échoue avec 14.",
      "How often the device is asked for its state, in seconds: 15 by default. Values from 500 are read as milliseconds.": "Fréquence à laquelle l’appareil est interrogé, en secondes : 15 par défaut. Les valeurs à partir de 500 sont lues en millisecondes.",
      "How the property compares with the value.": "Comment la propriété se compare à la valeur.",
      "Humidity": "Humidité",
      "IP address": "Adresse IP",
      "India": "Inde",
      "Ioniser switch": "Interrupteur de l’ioniseur",
      "LED control": "Commande du voyant",
      "Leaves out the sensors, battery and filter beside the main service; extra controls still show.": "Laisse de côté les capteurs, la batterie et le filtre à côté du service principal ; les commandes supplémentaires restent.",
      "Leaves out what the spec maps on its own: the accessory has only the controls below.": "Laisse de côté ce que la spécification associe d’elle-même : l’accessoire n’a que les commandes ci-dessous.",
      "Less": "Inférieure",
      "Less or equal": "Inférieure ou égale",
      "Light level": "Luminosité",
      "Limit": "Seuil",
      "Linked property": "Propriété liée",
      "Linked value": "Valeur liée",
      "Main service only": "Service principal seulement",
      "Mainland China": "Chine continentale",
      "Method": "Méthode",
      "Method button": "Bouton de méthode",
      "Method buttons": "Boutons de méthode",
      "Mode switches": "Interrupteurs de mode",
      "Model": "Modèle",
      "Motor buttons": "Boutons du moteur",
      "Move buttons": "Boutons de déplacement",
      "Name": "Nom",
      "Names this instance in the log and in its data directory.": "Nomme cette instance dans le journal et dans son dossier de données.",
      "Off delay": "Arrêt différé",
      "Off keeps the accessory without ever asking the device.": "Désactivé, l’accessoire reste sans que l’appareil soit jamais interrogé.",
      "One button per motor command (open, close, pause).": "Un bouton par commande du moteur (ouvrir, fermer, pause).",
      "One switch per fan level; an air purifier's apply in its Favorite mode.": "Un interrupteur par vitesse ; ceux d’un purificateur d’air s’appliquent dans son mode Favori.",
      "One switch per mode, on only while the device is.": "Un interrupteur par mode, actif seulement quand l’appareil l’est.",
      "Only extra controls": "Commandes supplémentaires seulement",
      "PM2.5 limits": "Seuils PM2,5",
      "Parameters": "Paramètres",
      "Polled": "Interrogé",
      "Polling interval (seconds)": "Intervalle d’interrogation (secondes)",
      "Properties per request": "Propriétés par requête",
      "Property": "Propriété",
      "Property control": "Commande de propriété",
      "Property controls": "Commandes de propriété",
      "Property monitor": "Suivi de propriété",
      "Property monitors": "Suivis de propriété",
      "Region": "Région",
      "Russia": "Russie",
      "Screen control": "Commande de l’écran",
      "Sensor": "Capteur",
      "Sensors for properties of the spec: an occupancy sensor while a comparison holds, else a temperature or light sensor showing the value.": "Des capteurs pour des propriétés de la spécification : un capteur de présence tant qu’une comparaison est vraie, sinon un capteur de température ou de luminosité qui affiche la valeur.",
      "Sensors left out": "Capteurs omis",
      "Shown as": "Affichée comme",
      "Shows the outlet's temperature when its spec has one.": "Affiche la température de la prise quand sa spécification en a une.",
      "Singapore": "Singapour",
      "Swing switches": "Interrupteurs d’oscillation",
      "Taiwan": "Taïwan",
      "Temperature": "Température",
      "Temperature sensor": "Capteur de température",
      "The Xiaomi cloud region of the account, as the Mi Home app shows it.": "La région du cloud Xiaomi du compte, telle que l’app Mi Home l’affiche.",
      "The Xiaomi device id. Learned from the device when left out.": "L’id de l’appareil Xiaomi. Appris de l’appareil s’il est omis.",
      "The accessory's name.": "Le nom de l’accessoire.",
      "The action's in values, in order.": "Les valeurs d’entrée de l’action, dans l’ordre.",
      "The action's name or id.": "Le nom ou l’id de l’action.",
      "The button's name.": "Le nom du bouton.",
      "The child lock as Lock Physical Controls on the main service.": "La sécurité enfants comme verrouillage des commandes physiques sur le service principal.",
      "The cloud region, used to sign in and to list the account's devices. Setup signs in, and keeps the account in the vault; it is optional.": "La région du cloud, utilisée pour se connecter et lister les appareils du compte. La configuration se connecte ; le compte est facultatif.",
      "The control's name.": "Le nom de la commande.",
      "The device's address on the local network.": "L’adresse de l’appareil sur le réseau local.",
      "The device's model, such as yeelink.light.colorc: it chooses the spec. Asked from the device when empty.": "Le modèle de l’appareil, comme yeelink.light.colorc : il choisit la spécification. Demandé à l’appareil s’il est vide.",
      "The device's model, such as zhimi.airpurifier.ma4. Asked from the device when left out.": "Le modèle de l’appareil, comme zhimi.airpurifier.ma4. Demandé à l’appareil s’il est omis.",
      "The linked property's value.": "La valeur de la propriété liée.",
      "The method's parameters.": "Les paramètres de la méthode.",
      "The miIO method.": "La méthode miIO.",
      "The property's name or id.": "Le nom ou l’id de la propriété.",
      "The sensor's name.": "Le nom du capteur.",
      "The value to compare with.": "La valeur à comparer.",
      "This device's cloud options, over the plugin's.": "Les options de cloud de cet appareil, au-dessus de celles du plugin.",
      "United States": "États-Unis",
      "Value": "Valeur",
      "Vertical angle buttons": "Boutons d’angle vertical",
      "Where the device answers on the local network. Updated when the device is seen at another address.": "Où l’appareil répond sur le réseau local. Mise à jour quand l’appareil est vu à une autre adresse.",
      "Xiaomi account": "Compte Xiaomi",
      "homebridge-miot's fresh air system option: read and kept, not used yet.": "L’option de homebridge-miot pour les systèmes d’air frais : lue et gardée, pas encore utilisée.",
      "homebridge-miot's list, read as it is with its tokens. Each entry with a did moves to that device's settings with the next settings write, its token to the vault.": "La liste de homebridge-miot, lue telle quelle avec ses jetons. Chaque entrée avec un did passe dans les réglages de son appareil au prochain enregistrement, son jeton dans le coffre.",
      "homebridge-miot's option to reach devices through the cloud. Not supported yet: devices stay on the local network, and the log says so.": "L’option de homebridge-miot pour joindre les appareils par le cloud. Pas encore prise en charge : les appareils restent sur le réseau local, et le journal l’indique.",
      "homebridge-miot's pet feeder option: read and kept, not used yet.": "L’option de homebridge-miot pour les distributeurs de nourriture : lue et gardée, pas encore utilisée.",
      "i2": "i2",
      "µg/m³": "µg/m³"
    },
    "es": {
      "A slider for the time before the device turns off, when the spec gives its unit.": "Un deslizador para el tiempo antes de que el dispositivo se apague, cuando la especificación da su unidad.",
      "A switch for the device's buzzer.": "Un interruptor para el pitido del dispositivo.",
      "A switch for the ioniser, on only while the device is.": "Un interruptor para el ionizador, activo solo cuando el dispositivo lo está.",
      "A switch for the screen, or one per brightness.": "Un interruptor para la pantalla, o uno por brillo.",
      "A switch, a slider or one switch per level for the device's indicator light.": "Un interruptor, un deslizador o un interruptor por nivel para la luz indicadora del dispositivo.",
      "A value": "Un valor",
      "A value to set: the control is then a switch on while the property has it.": "Un valor que fijar: el control es entonces un interruptor activo mientras la propiedad lo tenga.",
      "Action": "Acción",
      "Action button": "Botón de acción",
      "Action buttons": "Botones de acción",
      "Angle": "Ángulo",
      "Angles (1 to 360) each with a switch that sets it and turns the swing on. true in config.json gives the spec's angles.": "Ángulos (de 1 a 360), cada uno con un interruptor que lo fija y activa la oscilación. true en config.json da los ángulos de la especificación.",
      "Another property that must be on, or have the linked value, for the control to read on.": "Otra propiedad que debe estar activa, o tener el valor vinculado, para que el control esté activo.",
      "Another property that must be on, or have the linked value, for the sensor to be active.": "Otra propiedad que debe estar activa, o tener el valor vinculado, para que el sensor esté activo.",
      "Automatic sensors to leave out of the accessory.": "Los sensores automáticos que se dejan fuera del accesorio.",
      "Buttons that run actions of the spec, by name (filter:reset-filter-life) or id (4.1). The plugin's page lists them; true in config.json makes one per action.": "Botones que ejecutan acciones de la especificación, por nombre (filter:reset-filter-life) o id (4.1). La página del plugin las lista; true en config.json crea uno por acción.",
      "Buttons that send a raw miIO method (find_me); the answer goes to the log.": "Botones que envían un método miIO en bruto (find_me); la respuesta va al registro.",
      "Buttons that turn the fan left, right, up or down one step.": "Botones que giran el ventilador un paso a la izquierda, a la derecha, arriba o abajo.",
      "Buzzer switch": "Interruptor del pitido",
      "CO2 alarm level (ppm)": "Nivel de alarma de CO2 (ppm)",
      "Carbon dioxide above this level (ppm) is abnormal: 1000 by default.": "Por encima de este nivel (ppm) el dióxido de carbono es anormal: 1000 por defecto.",
      "Child lock": "Bloqueo infantil",
      "Cloud timeout (ms)": "Tiempo de espera de la nube (ms)",
      "Comparison": "Comparación",
      "Contained in a list": "Contenido en una lista",
      "Controls for properties of the spec, by name (fan:anion) or id (2.7): a switch, a slider or one switch per value.": "Controles para propiedades de la especificación, por nombre (fan:anion) o id (2.7): un interruptor, un deslizador o un interruptor por valor.",
      "Defaults for every device": "Valores por defecto de los dispositivos",
      "Degrees": "Grados",
      "Device": "Dispositivo",
      "Device id (did)": "Id del dispositivo (did)",
      "Devices (homebridge-miot)": "Dispositivos (homebridge-miot)",
      "Equal": "Igual",
      "Europe": "Europa",
      "Fan level switches": "Interruptores de nivel de ventilador",
      "Food amount": "Cantidad de comida",
      "For a range: {\"type\": \"fan\"} shows a fan's speed instead of a light's brightness.": "Para un rango: {\"type\": \"fan\"} muestra la velocidad de un ventilador en lugar del brillo de una luz.",
      "Force the Xiaomi cloud": "Forzar la nube de Xiaomi",
      "Four increasing PM2.5 values (µg/m³) that end Excellent, Good, Fair and Inferior air; above the last is Poor. 7, 15, 30, 55 by default.": "Cuatro valores de PM2,5 crecientes (µg/m³) que cierran un aire Excelente, Bueno, Regular e Inferior; por encima del último es Malo. 7, 15, 30, 55 por defecto.",
      "Greater": "Mayor",
      "Greater or equal": "Mayor o igual",
      "Heat level switches": "Interruptores de nivel de calor",
      "Heater switch": "Interruptor de calefacción",
      "Horizontal and vertical swing switches.": "Interruptores de oscilación horizontal y vertical.",
      "Horizontal angle buttons": "Botones de ángulo horizontal",
      "How long a cloud request may take, in milliseconds: 2000 at least.": "Lo que puede durar una petición a la nube, en milisegundos: 2000 como mínimo.",
      "How many properties one request reads, 1 to 14: lower it for a device that fails with 14.": "Cuántas propiedades lee una petición, de 1 a 14: bájalo para un dispositivo que falla con 14.",
      "How often the device is asked for its state, in seconds: 15 by default. Values from 500 are read as milliseconds.": "Cada cuánto se pregunta al dispositivo por su estado, en segundos: 15 por defecto. Los valores desde 500 se leen como milisegundos.",
      "How the property compares with the value.": "Cómo se compara la propiedad con el valor.",
      "Humidity": "Humedad",
      "IP address": "Dirección IP",
      "India": "India",
      "Ioniser switch": "Interruptor del ionizador",
      "LED control": "Control del LED",
      "Leaves out the sensors, battery and filter beside the main service; extra controls still show.": "Deja fuera los sensores, la batería y el filtro junto al servicio principal; los controles adicionales siguen.",
      "Leaves out what the spec maps on its own: the accessory has only the controls below.": "Deja fuera lo que la especificación asocia por sí misma: el accesorio solo tiene los controles de abajo.",
      "Less": "Menor",
      "Less or equal": "Menor o igual",
      "Light level": "Nivel de luz",
      "Limit": "Límite",
      "Linked property": "Propiedad vinculada",
      "Linked value": "Valor vinculado",
      "Main service only": "Solo el servicio principal",
      "Mainland China": "China continental",
      "Method": "Método",
      "Method button": "Botón de método",
      "Method buttons": "Botones de método",
      "Mode switches": "Interruptores de modo",
      "Model": "Modelo",
      "Motor buttons": "Botones del motor",
      "Move buttons": "Botones de movimiento",
      "Name": "Nombre",
      "Names this instance in the log and in its data directory.": "Nombra esta instancia en el registro y en su carpeta de datos.",
      "Off delay": "Apagado diferido",
      "Off keeps the accessory without ever asking the device.": "Desactivado, el accesorio se queda sin preguntar nunca al dispositivo.",
      "One button per motor command (open, close, pause).": "Un botón por orden del motor (abrir, cerrar, pausa).",
      "One switch per fan level; an air purifier's apply in its Favorite mode.": "Un interruptor por nivel; los de un purificador de aire se aplican en su modo Favorito.",
      "One switch per mode, on only while the device is.": "Un interruptor por modo, activo solo cuando el dispositivo lo está.",
      "Only extra controls": "Solo controles adicionales",
      "PM2.5 limits": "Límites de PM2,5",
      "Parameters": "Parámetros",
      "Polled": "Consultado",
      "Polling interval (seconds)": "Intervalo de consulta (segundos)",
      "Properties per request": "Propiedades por petición",
      "Property": "Propiedad",
      "Property control": "Control de propiedad",
      "Property controls": "Controles de propiedad",
      "Property monitor": "Monitor de propiedad",
      "Property monitors": "Monitores de propiedad",
      "Region": "Región",
      "Russia": "Rusia",
      "Screen control": "Control de la pantalla",
      "Sensor": "Sensor",
      "Sensors for properties of the spec: an occupancy sensor while a comparison holds, else a temperature or light sensor showing the value.": "Sensores para propiedades de la especificación: un sensor de ocupación mientras se cumple una comparación, si no un sensor de temperatura o de luz con el valor.",
      "Sensors left out": "Sensores omitidos",
      "Shown as": "Mostrado como",
      "Shows the outlet's temperature when its spec has one.": "Muestra la temperatura del enchufe cuando su especificación la tiene.",
      "Singapore": "Singapur",
      "Swing switches": "Interruptores de oscilación",
      "Taiwan": "Taiwán",
      "Temperature": "Temperatura",
      "Temperature sensor": "Sensor de temperatura",
      "The Xiaomi cloud region of the account, as the Mi Home app shows it.": "La región de la nube de Xiaomi de la cuenta, como la muestra la app Mi Home.",
      "The Xiaomi device id. Learned from the device when left out.": "El id del dispositivo de Xiaomi. Se aprende del dispositivo si falta.",
      "The accessory's name.": "El nombre del accesorio.",
      "The action's in values, in order.": "Los valores de entrada de la acción, en orden.",
      "The action's name or id.": "El nombre o el id de la acción.",
      "The button's name.": "El nombre del botón.",
      "The child lock as Lock Physical Controls on the main service.": "El bloqueo infantil como bloqueo de controles físicos en el servicio principal.",
      "The cloud region, used to sign in and to list the account's devices. Setup signs in, and keeps the account in the vault; it is optional.": "La región de la nube, para iniciar sesión y listar los dispositivos de la cuenta. La configuración inicia sesión y guarda la cuenta en la caja fuerte; es opcional.",
      "The control's name.": "El nombre del control.",
      "The device's address on the local network.": "La dirección del dispositivo en la red local.",
      "The device's model, such as yeelink.light.colorc: it chooses the spec. Asked from the device when empty.": "El modelo del dispositivo, como yeelink.light.colorc: elige la especificación. Se pregunta al dispositivo si está vacío.",
      "The device's model, such as zhimi.airpurifier.ma4. Asked from the device when left out.": "El modelo del dispositivo, como zhimi.airpurifier.ma4. Se pregunta al dispositivo si falta.",
      "The linked property's value.": "El valor de la propiedad vinculada.",
      "The method's parameters.": "Los parámetros del método.",
      "The miIO method.": "El método miIO.",
      "The property's name or id.": "El nombre o el id de la propiedad.",
      "The sensor's name.": "El nombre del sensor.",
      "The value to compare with.": "El valor con el que comparar.",
      "This device's cloud options, over the plugin's.": "Las opciones de nube de este dispositivo, por encima de las del plugin.",
      "United States": "Estados Unidos",
      "Value": "Valor",
      "Vertical angle buttons": "Botones de ángulo vertical",
      "Where the device answers on the local network. Updated when the device is seen at another address.": "Dónde responde el dispositivo en la red local. Se actualiza cuando el dispositivo aparece en otra dirección.",
      "Xiaomi account": "Cuenta de Xiaomi",
      "homebridge-miot's fresh air system option: read and kept, not used yet.": "La opción de homebridge-miot para sistemas de aire fresco: se lee y se guarda, aún no se usa.",
      "homebridge-miot's list, read as it is with its tokens. Each entry with a did moves to that device's settings with the next settings write, its token to the vault.": "La lista de homebridge-miot, leída tal cual con sus tokens. Cada entrada con un did pasa a los ajustes de su dispositivo al guardar los ajustes, y su token a la caja fuerte.",
      "homebridge-miot's option to reach devices through the cloud. Not supported yet: devices stay on the local network, and the log says so.": "La opción de homebridge-miot para llegar a los dispositivos por la nube. Aún no es compatible: los dispositivos siguen en la red local, y el registro lo indica.",
      "homebridge-miot's pet feeder option: read and kept, not used yet.": "La opción de homebridge-miot para comederos: se lee y se guarda, aún no se usa.",
      "i2": "i2",
      "µg/m³": "µg/m³"
    },
    "pt": {
      "A slider for the time before the device turns off, when the spec gives its unit.": "Um cursor para o tempo até o dispositivo desligar, quando a especificação dá a unidade.",
      "A switch for the device's buzzer.": "Um interruptor para o sinal sonoro do dispositivo.",
      "A switch for the ioniser, on only while the device is.": "Um interruptor para o ionizador, ativo só enquanto o dispositivo o está.",
      "A switch for the screen, or one per brightness.": "Um interruptor para o ecrã, ou um por brilho.",
      "A switch, a slider or one switch per level for the device's indicator light.": "Um interruptor, um cursor ou um interruptor por nível para a luz indicadora do dispositivo.",
      "A value": "Um valor",
      "A value to set: the control is then a switch on while the property has it.": "Um valor a definir: o controlo é então um interruptor ativo enquanto a propriedade o tiver.",
      "Action": "Ação",
      "Action button": "Botão de ação",
      "Action buttons": "Botões de ação",
      "Angle": "Ângulo",
      "Angles (1 to 360) each with a switch that sets it and turns the swing on. true in config.json gives the spec's angles.": "Ângulos (de 1 a 360), cada um com um interruptor que o define e liga a oscilação. true em config.json dá os ângulos da especificação.",
      "Another property that must be on, or have the linked value, for the control to read on.": "Outra propriedade que deve estar ativa, ou ter o valor ligado, para o controlo estar ativo.",
      "Another property that must be on, or have the linked value, for the sensor to be active.": "Outra propriedade que deve estar ativa, ou ter o valor ligado, para o sensor estar ativo.",
      "Automatic sensors to leave out of the accessory.": "Os sensores automáticos a deixar fora do acessório.",
      "Buttons that run actions of the spec, by name (filter:reset-filter-life) or id (4.1). The plugin's page lists them; true in config.json makes one per action.": "Botões que executam ações da especificação, por nome (filter:reset-filter-life) ou id (4.1). A página do plugin lista-as; true em config.json cria um por ação.",
      "Buttons that send a raw miIO method (find_me); the answer goes to the log.": "Botões que enviam um método miIO em bruto (find_me); a resposta vai para o registo.",
      "Buttons that turn the fan left, right, up or down one step.": "Botões que rodam a ventoinha um passo para a esquerda, direita, cima ou baixo.",
      "Buzzer switch": "Interruptor do sinal sonoro",
      "CO2 alarm level (ppm)": "Nível de alarme de CO2 (ppm)",
      "Carbon dioxide above this level (ppm) is abnormal: 1000 by default.": "Acima deste nível (ppm) o dióxido de carbono é anormal: 1000 por omissão.",
      "Child lock": "Bloqueio infantil",
      "Cloud timeout (ms)": "Tempo limite da nuvem (ms)",
      "Comparison": "Comparação",
      "Contained in a list": "Contido numa lista",
      "Controls for properties of the spec, by name (fan:anion) or id (2.7): a switch, a slider or one switch per value.": "Controlos para propriedades da especificação, por nome (fan:anion) ou id (2.7): um interruptor, um cursor ou um interruptor por valor.",
      "Defaults for every device": "Valores por omissão dos dispositivos",
      "Degrees": "Graus",
      "Device": "Dispositivo",
      "Device id (did)": "Id do dispositivo (did)",
      "Devices (homebridge-miot)": "Dispositivos (homebridge-miot)",
      "Equal": "Igual",
      "Europe": "Europa",
      "Fan level switches": "Interruptores de nível de ventilação",
      "Food amount": "Quantidade de comida",
      "For a range: {\"type\": \"fan\"} shows a fan's speed instead of a light's brightness.": "Para um intervalo: {\"type\": \"fan\"} mostra a velocidade de uma ventoinha em vez do brilho de uma luz.",
      "Force the Xiaomi cloud": "Forçar a nuvem Xiaomi",
      "Four increasing PM2.5 values (µg/m³) that end Excellent, Good, Fair and Inferior air; above the last is Poor. 7, 15, 30, 55 by default.": "Quatro valores de PM2,5 crescentes (µg/m³) que terminam um ar Excelente, Bom, Razoável e Inferior; acima do último é Mau. 7, 15, 30, 55 por omissão.",
      "Greater": "Maior",
      "Greater or equal": "Maior ou igual",
      "Heat level switches": "Interruptores de nível de calor",
      "Heater switch": "Interruptor de aquecimento",
      "Horizontal and vertical swing switches.": "Interruptores de oscilação horizontal e vertical.",
      "Horizontal angle buttons": "Botões de ângulo horizontal",
      "How long a cloud request may take, in milliseconds: 2000 at least.": "Quanto pode durar um pedido à nuvem, em milissegundos: 2000 no mínimo.",
      "How many properties one request reads, 1 to 14: lower it for a device that fails with 14.": "Quantas propriedades um pedido lê, de 1 a 14: baixe-o para um dispositivo que falha com 14.",
      "How often the device is asked for its state, in seconds: 15 by default. Values from 500 are read as milliseconds.": "Com que frequência o dispositivo é consultado, em segundos: 15 por omissão. Os valores a partir de 500 são lidos como milissegundos.",
      "How the property compares with the value.": "Como a propriedade se compara com o valor.",
      "Humidity": "Humidade",
      "IP address": "Endereço IP",
      "India": "Índia",
      "Ioniser switch": "Interruptor do ionizador",
      "LED control": "Controlo do LED",
      "Leaves out the sensors, battery and filter beside the main service; extra controls still show.": "Deixa de fora os sensores, a bateria e o filtro junto ao serviço principal; os controlos adicionais continuam.",
      "Leaves out what the spec maps on its own: the accessory has only the controls below.": "Deixa de fora o que a especificação associa por si: o acessório só tem os controlos abaixo.",
      "Less": "Menor",
      "Less or equal": "Menor ou igual",
      "Light level": "Nível de luz",
      "Limit": "Limite",
      "Linked property": "Propriedade ligada",
      "Linked value": "Valor ligado",
      "Main service only": "Só o serviço principal",
      "Mainland China": "China continental",
      "Method": "Método",
      "Method button": "Botão de método",
      "Method buttons": "Botões de método",
      "Mode switches": "Interruptores de modo",
      "Model": "Modelo",
      "Motor buttons": "Botões do motor",
      "Move buttons": "Botões de movimento",
      "Name": "Nome",
      "Names this instance in the log and in its data directory.": "Dá nome a esta instância no registo e na sua pasta de dados.",
      "Off delay": "Desligar diferido",
      "Off keeps the accessory without ever asking the device.": "Desativado, o acessório fica sem nunca consultar o dispositivo.",
      "One button per motor command (open, close, pause).": "Um botão por comando do motor (abrir, fechar, pausa).",
      "One switch per fan level; an air purifier's apply in its Favorite mode.": "Um interruptor por nível; os de um purificador de ar aplicam-se no modo Favorito.",
      "One switch per mode, on only while the device is.": "Um interruptor por modo, ativo só enquanto o dispositivo o está.",
      "Only extra controls": "Só controlos adicionais",
      "PM2.5 limits": "Limites de PM2,5",
      "Parameters": "Parâmetros",
      "Polled": "Consultado",
      "Polling interval (seconds)": "Intervalo de consulta (segundos)",
      "Properties per request": "Propriedades por pedido",
      "Property": "Propriedade",
      "Property control": "Controlo de propriedade",
      "Property controls": "Controlos de propriedade",
      "Property monitor": "Monitor de propriedade",
      "Property monitors": "Monitores de propriedade",
      "Region": "Região",
      "Russia": "Rússia",
      "Screen control": "Controlo do ecrã",
      "Sensor": "Sensor",
      "Sensors for properties of the spec: an occupancy sensor while a comparison holds, else a temperature or light sensor showing the value.": "Sensores para propriedades da especificação: um sensor de ocupação enquanto uma comparação se verifica, senão um sensor de temperatura ou de luz com o valor.",
      "Sensors left out": "Sensores omitidos",
      "Shown as": "Mostrado como",
      "Shows the outlet's temperature when its spec has one.": "Mostra a temperatura da tomada quando a especificação a tem.",
      "Singapore": "Singapura",
      "Swing switches": "Interruptores de oscilação",
      "Taiwan": "Taiwan",
      "Temperature": "Temperatura",
      "Temperature sensor": "Sensor de temperatura",
      "The Xiaomi cloud region of the account, as the Mi Home app shows it.": "A região da nuvem Xiaomi da conta, tal como a app Mi Home a mostra.",
      "The Xiaomi device id. Learned from the device when left out.": "O id do dispositivo Xiaomi. Aprendido do dispositivo quando falta.",
      "The accessory's name.": "O nome do acessório.",
      "The action's in values, in order.": "Os valores de entrada da ação, por ordem.",
      "The action's name or id.": "O nome ou o id da ação.",
      "The button's name.": "O nome do botão.",
      "The child lock as Lock Physical Controls on the main service.": "O bloqueio infantil como bloqueio dos controlos físicos no serviço principal.",
      "The cloud region, used to sign in and to list the account's devices. Setup signs in, and keeps the account in the vault; it is optional.": "A região da nuvem, usada para iniciar sessão e listar os dispositivos da conta. A configuração inicia sessão e guarda a conta no cofre; é opcional.",
      "The control's name.": "O nome do controlo.",
      "The device's address on the local network.": "O endereço do dispositivo na rede local.",
      "The device's model, such as yeelink.light.colorc: it chooses the spec. Asked from the device when empty.": "O modelo do dispositivo, como yeelink.light.colorc: escolhe a especificação. Perguntado ao dispositivo quando está vazio.",
      "The device's model, such as zhimi.airpurifier.ma4. Asked from the device when left out.": "O modelo do dispositivo, como zhimi.airpurifier.ma4. Perguntado ao dispositivo quando falta.",
      "The linked property's value.": "O valor da propriedade ligada.",
      "The method's parameters.": "Os parâmetros do método.",
      "The miIO method.": "O método miIO.",
      "The property's name or id.": "O nome ou o id da propriedade.",
      "The sensor's name.": "O nome do sensor.",
      "The value to compare with.": "O valor a comparar.",
      "This device's cloud options, over the plugin's.": "As opções de nuvem deste dispositivo, acima das do plugin.",
      "United States": "Estados Unidos",
      "Value": "Valor",
      "Vertical angle buttons": "Botões de ângulo vertical",
      "Where the device answers on the local network. Updated when the device is seen at another address.": "Onde o dispositivo responde na rede local. Atualizado quando o dispositivo aparece noutro endereço.",
      "Xiaomi account": "Conta Xiaomi",
      "homebridge-miot's fresh air system option: read and kept, not used yet.": "A opção do homebridge-miot para sistemas de ar fresco: lida e guardada, ainda não usada.",
      "homebridge-miot's list, read as it is with its tokens. Each entry with a did moves to that device's settings with the next settings write, its token to the vault.": "A lista do homebridge-miot, lida tal como está com os tokens. Cada entrada com um did passa para as definições do seu dispositivo na próxima gravação, e o token para o cofre.",
      "homebridge-miot's option to reach devices through the cloud. Not supported yet: devices stay on the local network, and the log says so.": "A opção do homebridge-miot para chegar aos dispositivos pela nuvem. Ainda não é suportada: os dispositivos ficam na rede local, e o registo indica-o.",
      "homebridge-miot's pet feeder option: read and kept, not used yet.": "A opção do homebridge-miot para comedouros: lida e guardada, ainda não usada.",
      "i2": "i2",
      "µg/m³": "µg/m³"
    }
  }
}
"""#
}
