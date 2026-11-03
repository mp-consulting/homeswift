// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension EWeLinkPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "eWeLink",
  "pluginType": "platform",
  "singular": true,
  "customUi": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "description": "The name of this platform in the log.",
        "type": "string",
        "default": "eWeLink",
        "required": true
      },
      "countryCode": {
        "title": "Country Code",
        "description": "The account's country dial code (+1 for the US, +44 for the UK, +86 for China): it picks the eWeLink API region.",
        "type": "string",
        "default": "+1"
      },
      "mode": {
        "title": "Connection Mode",
        "description": "How the plugin reaches devices. Auto tries the local network first, then the cloud.",
        "type": "string",
        "default": "auto",
        "oneOf": [
          { "title": "Auto (LAN + Cloud)", "enum": ["auto"] },
          { "title": "LAN Only", "enum": ["lan"] },
          { "title": "Cloud Only", "enum": ["wan"] }
        ]
      },
      "debug": {
        "title": "Debug Mode",
        "description": "Accessories write their debug lines to the log.",
        "type": "boolean",
        "default": false
      },
      "disableDeviceLogging": {
        "title": "Disable Device Logging",
        "description": "Leaves each device's state changes out of the log.",
        "type": "boolean",
        "default": false
      },
      "offlineAsOff": {
        "title": "Show Offline Devices as Off",
        "description": "Offline devices read as off in the Home app instead of \"No Response\".",
        "type": "boolean",
        "default": false
      },
      "outlineInLog": {
        "title": "Outline Messages in Log",
        "description": "Kept for the Homebridge plugin; it has no effect here.",
        "type": "boolean",
        "default": true
      },
      "groups": {
        "title": "Device Groups",
        "description": "Kept for the Homebridge plugin; it has no effect here: eWeLink's own groups come from the account.",
        "type": "array",
        "items": {
          "type": "object",
          "title": "Group",
          "properties": {
            "type": {
              "title": "Group Type",
              "description": "The accessory the group would appear as. Groups have no effect here.",
              "type": "string",
              "required": true,
              "oneOf": [
                { "title": "Blind", "enum": ["blind"] },
                { "title": "Garage Door", "enum": ["garage"] },
                { "title": "Lock", "enum": ["lock"] },
                { "title": "Valve", "enum": ["valve"] }
              ]
            },
            "deviceIds": {
              "title": "Device IDs",
              "description": "The devices in the group. Groups have no effect here.",
              "type": "array",
              "items": { "type": "string" }
            },
            "label": {
              "title": "Group Label",
              "description": "A name for the group. Groups have no effect here.",
              "type": "string"
            },
            "operationTime": {
              "title": "Operation Time (seconds)",
              "description": "Seconds for a full open or close. Groups have no effect here.",
              "type": "integer"
            }
          }
        }
      },
      "bridgeSensors": {
        "title": "RF Bridge Sensors",
        "description": "Settings for the RF sub-devices an RF Bridge learned, each by its full device ID.",
        "type": "array",
        "items": {
          "type": "object",
          "title": "RF sub-device",
          "properties": {
            "fullDeviceId": {
              "title": "Sensor Device ID",
              "description": "The sub-device's full ID: the RF Bridge's device ID, SW and the sub-device's number, such as 1000ab23cdSW2.",
              "type": "string",
              "required": true,
              "minLength": 13,
              "maxLength": 15
            },
            "label": {
              "title": "Label",
              "description": "A name to recognise this entry; it has no effect on the device.",
              "type": "string"
            },
            "deviceType": {
              "title": "Sensor Type",
              "description": "Kept for the Homebridge plugin; it has no effect here.",
              "type": "string",
              "default": "button",
              "oneOf": [
                { "title": "Button", "enum": ["button"] },
                { "title": "Water Sensor", "enum": ["water"] },
                { "title": "Fire Sensor", "enum": ["fire"] },
                { "title": "Smoke Sensor", "enum": ["smoke"] },
                { "title": "CO Sensor", "enum": ["co"] },
                { "title": "Motion Sensor", "enum": ["motion"] },
                { "title": "Contact Sensor", "enum": ["contact"] },
                { "title": "Doorbell", "enum": ["doorbell"] },
                { "title": "Curtain", "enum": ["curtain"] }
              ]
            },
            "curtainType": {
              "title": "Curtain Type",
              "description": "The curtain remote's buttons. The curtain appears as its buttons in the Home app whichever is chosen.",
              "type": "string",
              "default": "oneButton",
              "condition": {
                "functionBody": "return model.bridgeSensors && model.bridgeSensors[arrayIndices] && model.bridgeSensors[arrayIndices].deviceType === 'curtain';"
              },
              "oneOf": [
                { "title": "One Button", "enum": ["oneButton"] },
                { "title": "Two Buttons", "enum": ["twoButtons"] },
                { "title": "Three Buttons", "enum": ["threeButtons"] }
              ]
            },
            "operationTime": {
              "title": "Operation Time (Up, seconds)",
              "description": "Kept for the Homebridge plugin; it has no effect here.",
              "type": "integer",
              "default": 100,
              "minimum": 0,
              "maximum": 300,
              "condition": {
                "functionBody": "return model.bridgeSensors && model.bridgeSensors[arrayIndices] && model.bridgeSensors[arrayIndices].deviceType === 'curtain';"
              }
            },
            "operationTimeDown": {
              "title": "Operation Time (Down, seconds)",
              "description": "Kept for the Homebridge plugin; it has no effect here.",
              "type": "integer",
              "default": 100,
              "minimum": 0,
              "maximum": 300,
              "condition": {
                "functionBody": "return model.bridgeSensors && model.bridgeSensors[arrayIndices] && model.bridgeSensors[arrayIndices].deviceType === 'curtain';"
              }
            },
            "sensorTimeLength": {
              "title": "Sensor Active Time (seconds)",
              "description": "Kept for the Homebridge plugin; it has no effect here.",
              "type": "integer",
              "default": 60,
              "minimum": 1,
              "maximum": 300,
              "condition": {
                "functionBody": "return model.bridgeSensors && model.bridgeSensors[arrayIndices] && ['motion', 'smoke', 'co', 'water', 'fire'].includes(model.bridgeSensors[arrayIndices].deviceType);"
              }
            },
            "sensorTimeDifference": {
              "title": "Sensor Time Difference (seconds)",
              "description": "Kept for the Homebridge plugin; it has no effect here.",
              "type": "integer",
              "default": 60,
              "minimum": 1,
              "maximum": 300
            },
            "sensorWebHook": {
              "title": "Sensor Webhook URL",
              "description": "Kept for the Homebridge plugin; it has no effect here.",
              "type": "string"
            }
          }
        }
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "showAs": {
        "title": "Show As",
        "type": "string",
        "default": "default",
        "description": "The accessory the device appears as in the Home app: a switch's simulations (a valve, a lock, a garage door, a sensor, a heater following another device's temperature…), a cover for a multi-channel device, a thermostat or climate device for a TH10/TH16, a fan for a dimmer.",
        "oneOf": [
          { "title": "Default", "enum": ["default"] },
          { "title": "Outlet", "enum": ["outlet"], "x-kinds": ["single", "multi"] },
          { "title": "Switch", "enum": ["switch"], "x-kinds": ["single"] },
          { "title": "Valve", "enum": ["valve"], "x-kinds": ["single", "multi"] },
          { "title": "Tap", "enum": ["tap"], "x-kinds": ["single"] },
          { "title": "Lock", "enum": ["lock"], "x-kinds": ["single", "multi"] },
          { "title": "Garage Door", "enum": ["garage"], "x-kinds": ["single", "multi"] },
          { "title": "Gate", "enum": ["gate"], "x-kinds": ["single", "multi"] },
          { "title": "Blind", "enum": ["blind"], "x-kinds": ["multi"] },
          { "title": "Door", "enum": ["door"], "x-kinds": ["multi"] },
          { "title": "Window", "enum": ["window"], "x-kinds": ["multi"] },
          { "title": "Sensor", "enum": ["sensor"], "x-kinds": ["single"] },
          { "title": "Leak Sensor", "enum": ["sensor_leak"], "x-kinds": ["single"] },
          { "title": "Programmable Button", "enum": ["p_button"], "x-kinds": ["single"] },
          { "title": "Doorbell", "enum": ["doorbell"], "x-kinds": ["single"] },
          { "title": "Purifier", "enum": ["purifier"], "x-kinds": ["single"] },
          { "title": "Television", "enum": ["tv"], "x-kinds": ["single"] },
          { "title": "Heater", "enum": ["heater"], "x-kinds": ["single", "thermostat"] },
          { "title": "Cooler", "enum": ["cooler"], "x-kinds": ["single", "thermostat"] },
          { "title": "Thermostat", "enum": ["thermostat"], "x-kinds": ["thermostat"] },
          { "title": "Humidifier", "enum": ["humidifier"], "x-kinds": ["thermostat"] },
          { "title": "Dehumidifier", "enum": ["dehumidifier"], "x-kinds": ["thermostat"] },
          { "title": "Fan", "enum": ["fan"], "x-kinds": ["light"] }
        ],
        "x-kinds": ["single", "multi", "thermostat", "light"]
      },
      "disableDeviceLogging": {
        "title": "Disable Device Logging",
        "type": "boolean",
        "description": "Leaves this device's state changes out of the log. Empty takes the plugin's setting.",
        "x-default": "disableDeviceLogging"
      },
      "hideChannels": {
        "title": "Hide Channels",
        "description": "Channels to hide from the Home app, by number (1, 2...; 0 is the master switch) or full ID (1000abcdefSW1), separated by commas.",
        "type": "string",
        "x-kinds": ["multi"]
      },
      "inchChannels": {
        "title": "Inching Channels",
        "type": "boolean",
        "description": "The channels are inching switches: the master switch stays out of the Home app.",
        "x-kinds": ["multi"]
      },
      "operationTime": {
        "title": "Operation Time Up (seconds)",
        "type": "number",
        "minimum": 0,
        "description": "Seconds a cover takes to open fully, when the device is shown as a blind, a door or a window. Empty: 10.",
        "x-kinds": ["multi"]
      },
      "operationTimeDown": {
        "title": "Operation Time Down (seconds)",
        "type": "number",
        "minimum": 0,
        "description": "Seconds a cover takes to close fully. Empty: the opening time.",
        "x-kinds": ["multi"]
      },
      "tempSource": {
        "title": "Temperature Source",
        "type": "string",
        "description": "The device ID of the sensor whose temperature a switch shown as a heater or a cooler follows.",
        "x-kinds": ["single", "multi"]
      },
      "sensorType": {
        "title": "Sensor Type",
        "type": "string",
        "description": "For a switch shown as a sensor: motion, leak (water), smoke (fire), co, co2, contact or occupancy.",
        "x-kinds": ["single", "multi"]
      },
      "type": {
        "title": "Simulation Type",
        "type": "string",
        "description": "The kind of a simulation that has several, such as a lock's.",
        "x-kinds": ["single", "multi"]
      },
      "disableTimer": {
        "title": "Disable Timer",
        "type": "boolean",
        "description": "No auto-off timer on a switch shown as a valve or a tap.",
        "x-kinds": ["single", "multi"]
      },
      "isInched": {
        "title": "Inching Switch",
        "type": "boolean",
        "description": "The switch is an inching one: it always gets on, and the Home app shows it toggled.",
        "x-kinds": ["single", "outlet"]
      },
      "inUsePowerThreshold": {
        "title": "In Use Power Threshold (W)",
        "type": "number",
        "minimum": 0,
        "description": "The watts above which an outlet with power monitoring is in use.",
        "x-kinds": ["single", "outlet"]
      },
      "lowBattThreshold": {
        "title": "Low Battery Threshold (%)",
        "type": "number",
        "minimum": 0,
        "maximum": 100,
        "description": "For a switch shown as a leak sensor: the battery level below which the Home app shows the battery as low.",
        "x-kinds": ["single"]
      },
      "offset": {
        "title": "Temperature Offset",
        "type": "number",
        "description": "Degrees added to an air conditioner's or a panel's temperature, or the factor it is multiplied by with Offset Factor.",
        "x-kinds": ["air_conditioner", "panel"]
      },
      "offsetFactor": {
        "title": "Offset Factor",
        "type": "boolean",
        "description": "The temperature offset multiplies the reading instead of being added to it.",
        "x-kinds": ["air_conditioner", "panel", "thermostat"]
      },
      "tempOffset": {
        "title": "Temperature Offset",
        "description": "Degrees added to the temperature the device reports; a negative value lowers it.",
        "type": "number",
        "x-kinds": ["thermostat", "sensor"]
      },
      "humidityOffset": {
        "title": "Humidity Offset",
        "description": "Percentage points added to the humidity the device reports; a negative value lowers it.",
        "type": "number",
        "x-kinds": ["thermostat", "sensor"]
      },
      "humidityOffsetFactor": {
        "title": "Humidity Offset Factor",
        "type": "boolean",
        "description": "The humidity offset multiplies the reading instead of being added to it.",
        "x-kinds": ["thermostat"]
      },
      "minTarget": {
        "title": "Minimum Target (°C)",
        "type": "number",
        "description": "The lowest target a TH10/TH16 simulation takes. Empty: 10.",
        "x-kinds": ["thermostat"]
      },
      "maxTarget": {
        "title": "Maximum Target (°C)",
        "type": "number",
        "description": "The highest target a TH10/TH16 simulation takes. Empty: 30.",
        "x-kinds": ["thermostat"]
      },
      "targetTempThreshold": {
        "title": "Target Threshold (°C)",
        "type": "number",
        "minimum": 0,
        "description": "How far under the target a TH10/TH16 heater starts. Empty: 0.5 for a heater, 0 for a cooler.",
        "x-kinds": ["thermostat"]
      },
      "showHeatCool": {
        "title": "Heat and Cool",
        "type": "boolean",
        "description": "A TH10/TH16 shown as a thermostat offers off, heat and cool instead of off and auto.",
        "x-kinds": ["thermostat"]
      },
      "brightnessStep": {
        "title": "Brightness Step",
        "description": "The step of the speed slider, 1 to 100, when a dimmer is shown as a fan.",
        "type": "integer",
        "minimum": 1,
        "maximum": 100,
        "x-kinds": ["light"]
      },
      "adaptiveLightingShift": {
        "title": "Adaptive Lighting Shift",
        "description": "Mireds added to each Adaptive Lighting update, so the light looks warmer; -1 leaves Adaptive Lighting off for this light.",
        "type": "integer",
        "minimum": -1,
        "x-kinds": ["light"]
      },
      "deviceModel": {
        "title": "Device Model",
        "type": "string",
        "description": "offlineAsOff: a dimmer shown as a fan reads as off while it is offline.",
        "x-kinds": ["light"]
      },
      "hideLight": {
        "title": "Hide Light",
        "description": "Hides the fan's built-in light from the Home app.",
        "type": "boolean",
        "x-kinds": ["fan"]
      },
      "hideTemp": {
        "title": "Hide Temperature",
        "description": "Hides the temperature reading from the Home app.",
        "type": "boolean",
        "x-kinds": ["sensor"]
      },
      "hideHumidity": {
        "title": "Hide Humidity",
        "description": "Hides the humidity reading from the Home app.",
        "type": "boolean",
        "x-kinds": ["sensor"]
      },
      "hideSwitch": {
        "title": "Hide Switch",
        "type": "boolean",
        "description": "Hides a sensor's own switch from the Home app.",
        "x-kinds": ["sensor"]
      },
      "lowBattery": {
        "title": "Low Battery Threshold",
        "description": "The battery level, in percent, below which the Home app shows the battery as low.",
        "type": "integer",
        "minimum": 0,
        "maximum": 100,
        "x-kinds": ["sensor"]
      },
      "subdevices": {
        "title": "Sub-devices",
        "type": "array",
        "description": "Settings of the remotes and sensors an RF Bridge learned, by index or by label.",
        "items": {
          "title": "Sub-device",
          "type": "object",
          "properties": {
            "index": {
              "title": "Index",
              "type": "integer",
              "minimum": 0,
              "description": "The sub-device's button index, from 0."
            },
            "label": {
              "title": "Label",
              "type": "string",
              "description": "The sub-device's name in eWeLink, for a cover's times."
            },
            "showAs": {
              "title": "Show As",
              "type": "string",
              "description": "What a sensor sub-device is: motion, contact, water, smoke, co, co2, occupancy, button or doorbell."
            },
            "resetTime": {
              "title": "Reset Time (seconds)",
              "type": "number",
              "minimum": 0,
              "description": "Seconds a sensor stays triggered."
            },
            "operationTime": {
              "title": "Operation Time Up (seconds)",
              "type": "number",
              "minimum": 0,
              "description": "Seconds a cover takes to open fully, when the device is shown as a blind, a door or a window. Empty: 10."
            },
            "operationTimeDown": {
              "title": "Operation Time Down (seconds)",
              "type": "number",
              "minimum": 0,
              "description": "Seconds a cover takes to close fully. Empty: the opening time."
            }
          }
        },
        "x-kinds": ["rf_bridge"]
      }
    }
  },
  "layout": [
    "name",
    { "type": "fieldset", "title": "Connection Settings", "items": ["countryCode", "mode"] },
    {
      "type": "fieldset",
      "title": "General Settings",
      "expandable": true,
      "items": ["debug", "disableDeviceLogging", "offlineAsOff", "outlineInLog"]
    },
    {
      "type": "fieldset",
      "title": "Device Groups",
      "expandable": true,
      "items": [
        {
          "key": "groups",
          "type": "array",
          "expandable": true,
          "buttonText": "Add Group"
        }
      ]
    },
    {
      "key": "bridgeSensors",
      "title": "RF Subdevices",
      "description": "Optional settings for RF Bridge subdevices to expose different sensor types).",
      "expandable": true,
      "add": "Add RF Subdevices",
      "type": "array",
      "items": [
        {
          "type": "fieldset",
          "items": [
            "bridgeSensors[].label",
            "bridgeSensors[].fullDeviceId",
            "bridgeSensors[].deviceType",
            "bridgeSensors[].curtainType",
            "bridgeSensors[].operationTime",
            "bridgeSensors[].operationTimeDown",
            "bridgeSensors[].sensorTimeLength",
            "bridgeSensors[].sensorTimeDifference",
            "bridgeSensors[].sensorWebHook"
          ]
        }
      ]
    }
  ],
  "i18n": {
    "fr": {
      "A TH10/TH16 shown as a thermostat offers off, heat and cool instead of off and auto.": "Un TH10/TH16 affiché comme thermostat propose arrêt, chauffage et refroidissement au lieu d'arrêt et automatique.",
      "A name for the group. Groups have no effect here.": "Un nom pour le groupe. Les groupes sont sans effet ici.",
      "A name to recognise this entry; it has no effect on the device.": "Un nom pour reconnaître cette entrée ; sans effet sur l'appareil.",
      "Accessories write their debug lines to the log.": "Les accessoires écrivent leurs lignes de débogage dans le journal.",
      "Adaptive Lighting Shift": "Décalage de l'éclairage adaptatif",
      "Auto (LAN + Cloud)": "Auto (LAN + cloud)",
      "Blind": "Store",
      "Brightness Step": "Pas de luminosité",
      "Button": "Bouton",
      "CO Sensor": "Détecteur de CO",
      "Channels to hide from the Home app, by number (1, 2...; 0 is the master switch) or full ID (1000abcdefSW1), separated by commas.": "Les canaux à masquer dans l'app Maison, par numéro (1, 2... ; 0 est l'interrupteur principal) ou par identifiant complet (1000abcdefSW1), séparés par des virgules.",
      "Cloud Only": "Cloud uniquement",
      "Connection Mode": "Mode de connexion",
      "Connection Settings": "Connexion",
      "Contact Sensor": "Capteur de contact",
      "Cooler": "Climatiseur",
      "Country Code": "Indicatif du pays",
      "Curtain": "Rideau",
      "Curtain Type": "Type de rideau",
      "Debug Mode": "Mode débogage",
      "Default": "Par défaut",
      "Degrees added to an air conditioner's or a panel's temperature, or the factor it is multiplied by with Offset Factor.": "Les degrés ajoutés à la température d'un climatiseur ou d'un panneau, ou le facteur qui la multiplie avec Facteur de décalage.",
      "Degrees added to the temperature the device reports; a negative value lowers it.": "Degrés ajoutés à la température que l'appareil indique ; une valeur négative la baisse.",
      "Dehumidifier": "Déshumidificateur",
      "Device Groups": "Groupes d'appareils",
      "Device IDs": "Identifiants d'appareils",
      "Device Model": "Modèle de l'appareil",
      "Disable Device Logging": "Désactiver le journal des appareils",
      "Disable Timer": "Désactiver la minuterie",
      "Door": "Porte",
      "Doorbell": "Sonnette",
      "Fan": "Ventilateur",
      "Fire Sensor": "Détecteur d'incendie",
      "For a switch shown as a leak sensor: the battery level below which the Home app shows the battery as low.": "Pour un interrupteur affiché comme détecteur de fuite : le niveau de batterie sous lequel l'app Maison l'affiche comme faible.",
      "For a switch shown as a sensor: motion, leak (water), smoke (fire), co, co2, contact or occupancy.": "Pour un interrupteur affiché comme capteur : motion, leak (water), smoke (fire), co, co2, contact ou occupancy.",
      "Garage Door": "Porte de garage",
      "Gate": "Portail",
      "General Settings": "Général",
      "Group": "Groupe",
      "Group Label": "Libellé du groupe",
      "Group Type": "Type de groupe",
      "Heat and Cool": "Chauffage et refroidissement",
      "Heater": "Chauffage",
      "Hide Channels": "Masquer des canaux",
      "Hide Humidity": "Masquer l'humidité",
      "Hide Light": "Masquer la lampe",
      "Hide Switch": "Masquer l'interrupteur",
      "Hide Temperature": "Masquer la température",
      "Hides a sensor's own switch from the Home app.": "Masque l'interrupteur propre d'un capteur dans l'app Maison.",
      "Hides the fan's built-in light from the Home app.": "Masque la lampe intégrée du ventilateur dans l'app Maison.",
      "Hides the humidity reading from the Home app.": "Masque l'humidité dans l'app Maison.",
      "Hides the temperature reading from the Home app.": "Masque la température dans l'app Maison.",
      "How far under the target a TH10/TH16 heater starts. Empty: 0.5 for a heater, 0 for a cooler.": "À quelle distance sous la consigne un radiateur TH10/TH16 démarre. Vide : 0,5 pour un radiateur, 0 pour un climatiseur.",
      "How the plugin reaches devices. Auto tries the local network first, then the cloud.": "Comment le plugin joint les appareils. Auto essaie d'abord le réseau local, puis le cloud.",
      "Humidifier": "Humidificateur",
      "Humidity Offset": "Correction d'humidité",
      "Humidity Offset Factor": "Facteur de décalage d'humidité",
      "In Use Power Threshold (W)": "Seuil de puissance en cours d'utilisation (W)",
      "Inching Channels": "Canaux à impulsion",
      "Inching Switch": "Interrupteur à impulsion",
      "Index": "Index",
      "Kept for the Homebridge plugin; it has no effect here.": "Conservé pour le plugin Homebridge ; sans effet ici.",
      "Kept for the Homebridge plugin; it has no effect here: eWeLink's own groups come from the account.": "Conservé pour le plugin Homebridge ; sans effet ici : les groupes eWeLink viennent du compte.",
      "LAN Only": "LAN uniquement",
      "Label": "Libellé",
      "Leak Sensor": "Détecteur de fuite",
      "Leaves each device's state changes out of the log.": "N'inscrit pas les changements d'état de chaque appareil dans le journal.",
      "Leaves this device's state changes out of the log. Empty takes the plugin's setting.": "Laisse les changements d'état de cet appareil hors du journal. Vide reprend le réglage du plugin.",
      "Lock": "Serrure",
      "Low Battery Threshold": "Seuil de batterie faible",
      "Low Battery Threshold (%)": "Seuil de batterie faible (%)",
      "Maximum Target (°C)": "Consigne maximale (°C)",
      "Minimum Target (°C)": "Consigne minimale (°C)",
      "Mireds added to each Adaptive Lighting update, so the light looks warmer; -1 leaves Adaptive Lighting off for this light.": "Mireds ajoutés à chaque mise à jour de l'Éclairage adaptatif, pour une lumière plus chaude ; -1 laisse l'Éclairage adaptatif désactivé pour cette lampe.",
      "Motion Sensor": "Détecteur de mouvement",
      "Name": "Nom",
      "No auto-off timer on a switch shown as a valve or a tap.": "Pas de minuterie d'arrêt automatique sur un interrupteur affiché comme vanne ou robinet.",
      "Offline devices read as off in the Home app instead of \"No Response\".": "Les appareils hors ligne apparaissent éteints dans l'app Maison au lieu de « Pas de réponse ».",
      "Offset Factor": "Facteur de décalage",
      "One Button": "Un bouton",
      "Operation Time (Down, seconds)": "Durée de descente (secondes)",
      "Operation Time (Up, seconds)": "Durée de montée (secondes)",
      "Operation Time (seconds)": "Durée de manœuvre (secondes)",
      "Operation Time Down (seconds)": "Durée de fermeture (secondes)",
      "Operation Time Up (seconds)": "Durée d'ouverture (secondes)",
      "Outlet": "Prise",
      "Outline Messages in Log": "Encadrer les messages du journal",
      "Percentage points added to the humidity the device reports; a negative value lowers it.": "Points de pourcentage ajoutés à l'humidité que l'appareil indique ; une valeur négative la baisse.",
      "Programmable Button": "Bouton programmable",
      "Purifier": "Purificateur",
      "RF Bridge Sensors": "Capteurs RF Bridge",
      "RF Subdevices": "Sous-appareils RF",
      "RF sub-device": "Sous-appareil RF",
      "Reset Time (seconds)": "Délai de réinitialisation (secondes)",
      "Seconds a cover takes to close fully. Empty: the opening time.": "Les secondes qu'un volet met à se fermer entièrement. Vide : la durée d'ouverture.",
      "Seconds a cover takes to open fully, when the device is shown as a blind, a door or a window. Empty: 10.": "Les secondes qu'un volet met à s'ouvrir entièrement, quand l'appareil apparaît comme un volet, une porte ou une fenêtre. Vide : 10.",
      "Seconds a sensor stays triggered.": "Les secondes pendant lesquelles un capteur reste déclenché.",
      "Seconds for a full open or close. Groups have no effect here.": "Secondes pour une ouverture ou une fermeture complète. Les groupes sont sans effet ici.",
      "Sensor": "Capteur",
      "Sensor Active Time (seconds)": "Durée d'activation du capteur (secondes)",
      "Sensor Device ID": "Identifiant du capteur",
      "Sensor Time Difference (seconds)": "Écart de temps du capteur (secondes)",
      "Sensor Type": "Type de capteur",
      "Sensor Webhook URL": "URL du webhook du capteur",
      "Settings for the RF sub-devices an RF Bridge learned, each by its full device ID.": "Réglages des sous-appareils RF appris par un RF Bridge, chacun par son identifiant complet.",
      "Settings of the remotes and sensors an RF Bridge learned, by index or by label.": "Les réglages des télécommandes et capteurs qu'un RF Bridge a appris, par index ou par libellé.",
      "Show As": "Afficher comme",
      "Show Offline Devices as Off": "Afficher les appareils hors ligne comme éteints",
      "Simulation Type": "Type de simulation",
      "Smoke Sensor": "Détecteur de fumée",
      "Sub-device": "Sous-appareil",
      "Sub-devices": "Sous-appareils",
      "Switch": "Interrupteur",
      "Tap": "Robinet",
      "Target Threshold (°C)": "Seuil de consigne (°C)",
      "Television": "Télévision",
      "Temperature Offset": "Correction de température",
      "Temperature Source": "Source de température",
      "The accessory the device appears as in the Home app: a switch's simulations (a valve, a lock, a garage door, a sensor, a heater following another device's temperature…), a cover for a multi-channel device, a thermostat or climate device for a TH10/TH16, a fan for a dimmer.": "L'accessoire sous lequel l'appareil apparaît dans l'app Maison : les simulations d'un interrupteur (une vanne, une serrure, une porte de garage, un capteur, un radiateur suivant la température d'un autre appareil…), un volet pour un appareil à plusieurs canaux, un thermostat ou un appareil de climat pour un TH10/TH16, un ventilateur pour un variateur.",
      "The accessory the group would appear as. Groups have no effect here.": "L'accessoire sous lequel le groupe apparaîtrait. Les groupes sont sans effet ici.",
      "The account's country dial code (+1 for the US, +44 for the UK, +86 for China): it picks the eWeLink API region.": "L'indicatif téléphonique du pays du compte (+1 pour les États-Unis, +44 pour le Royaume-Uni, +86 pour la Chine) : il choisit la région de l'API eWeLink.",
      "The battery level, in percent, below which the Home app shows the battery as low.": "Le niveau de batterie, en pourcentage, sous lequel l'app Maison indique une batterie faible.",
      "The channels are inching switches: the master switch stays out of the Home app.": "Les canaux sont des interrupteurs à impulsion : l'interrupteur principal reste hors de l'app Maison.",
      "The curtain remote's buttons. The curtain appears as its buttons in the Home app whichever is chosen.": "Les boutons de la télécommande du rideau. Le rideau apparaît dans l'app Maison sous forme de boutons, quel que soit le choix.",
      "The device ID of the sensor whose temperature a switch shown as a heater or a cooler follows.": "L'identifiant de l'appareil dont la température suit un interrupteur affiché comme radiateur ou climatiseur.",
      "The devices in the group. Groups have no effect here.": "Les appareils du groupe. Les groupes sont sans effet ici.",
      "The highest target a TH10/TH16 simulation takes. Empty: 30.": "La consigne la plus haute d'une simulation TH10/TH16. Vide : 30.",
      "The humidity offset multiplies the reading instead of being added to it.": "Le décalage d'humidité multiplie la mesure au lieu de s'y ajouter.",
      "The kind of a simulation that has several, such as a lock's.": "Le genre d'une simulation qui en a plusieurs, comme celle d'une serrure.",
      "The lowest target a TH10/TH16 simulation takes. Empty: 10.": "La consigne la plus basse d'une simulation TH10/TH16. Vide : 10.",
      "The name of this platform in the log.": "Le nom de cette plateforme dans le journal.",
      "The step of the speed slider, 1 to 100, when a dimmer is shown as a fan.": "Le pas du curseur de vitesse, de 1 à 100, quand un variateur est affiché comme ventilateur.",
      "The sub-device's button index, from 0.": "L'index du bouton du sous-appareil, à partir de 0.",
      "The sub-device's full ID: the RF Bridge's device ID, SW and the sub-device's number, such as 1000ab23cdSW2.": "L'identifiant complet du sous-appareil : l'identifiant du RF Bridge, SW et le numéro du sous-appareil, par exemple 1000ab23cdSW2.",
      "The sub-device's name in eWeLink, for a cover's times.": "Le nom du sous-appareil dans eWeLink, pour les durées d'un volet.",
      "The switch is an inching one: it always gets on, and the Home app shows it toggled.": "L'interrupteur est à impulsion : il reçoit toujours marche, et l'app Maison l'affiche basculé.",
      "The temperature offset multiplies the reading instead of being added to it.": "Le décalage de température multiplie la mesure au lieu de s'y ajouter.",
      "The watts above which an outlet with power monitoring is in use.": "Les watts au-delà desquels une prise qui mesure sa puissance est en cours d'utilisation.",
      "Thermostat": "Thermostat",
      "Three Buttons": "Trois boutons",
      "Two Buttons": "Deux boutons",
      "Valve": "Vanne",
      "Water Sensor": "Détecteur d'eau",
      "What a sensor sub-device is: motion, contact, water, smoke, co, co2, occupancy, button or doorbell.": "Ce qu'est un sous-appareil capteur : motion, contact, water, smoke, co, co2, occupancy, button ou doorbell.",
      "Window": "Fenêtre",
      "offlineAsOff: a dimmer shown as a fan reads as off while it is offline.": "offlineAsOff : un variateur affiché comme ventilateur est éteint tant qu'il est hors ligne."
    },
    "es": {
      "A TH10/TH16 shown as a thermostat offers off, heat and cool instead of off and auto.": "Un TH10/TH16 mostrado como termostato ofrece apagado, calor y frío en lugar de apagado y automático.",
      "A name for the group. Groups have no effect here.": "Un nombre para el grupo. Los grupos no tienen efecto aquí.",
      "A name to recognise this entry; it has no effect on the device.": "Un nombre para reconocer esta entrada; no afecta al dispositivo.",
      "Accessories write their debug lines to the log.": "Los accesorios escriben sus líneas de depuración en el registro.",
      "Adaptive Lighting Shift": "Desfase de la iluminación adaptativa",
      "Auto (LAN + Cloud)": "Automático (LAN + nube)",
      "Blind": "Persiana",
      "Brightness Step": "Paso de brillo",
      "Button": "Botón",
      "CO Sensor": "Sensor de CO",
      "Channels to hide from the Home app, by number (1, 2...; 0 is the master switch) or full ID (1000abcdefSW1), separated by commas.": "Los canales que ocultar en la app Casa, por número (1, 2...; 0 es el interruptor principal) o por ID completo (1000abcdefSW1), separados por comas.",
      "Cloud Only": "Solo nube",
      "Connection Mode": "Modo de conexión",
      "Connection Settings": "Conexión",
      "Contact Sensor": "Sensor de contacto",
      "Cooler": "Enfriador",
      "Country Code": "Prefijo del país",
      "Curtain": "Cortina",
      "Curtain Type": "Tipo de cortina",
      "Debug Mode": "Modo de depuración",
      "Default": "Predeterminado",
      "Degrees added to an air conditioner's or a panel's temperature, or the factor it is multiplied by with Offset Factor.": "Los grados que se suman a la temperatura de un aire acondicionado o de un panel, o el factor que la multiplica con Factor de desfase.",
      "Degrees added to the temperature the device reports; a negative value lowers it.": "Grados que se suman a la temperatura que indica el dispositivo; un valor negativo la baja.",
      "Dehumidifier": "Deshumidificador",
      "Device Groups": "Grupos de dispositivos",
      "Device IDs": "IDs de dispositivos",
      "Device Model": "Modelo del dispositivo",
      "Disable Device Logging": "Desactivar el registro de dispositivos",
      "Disable Timer": "Desactivar el temporizador",
      "Door": "Puerta",
      "Doorbell": "Timbre",
      "Fan": "Ventilador",
      "Fire Sensor": "Sensor de incendio",
      "For a switch shown as a leak sensor: the battery level below which the Home app shows the battery as low.": "Para un interruptor mostrado como sensor de fugas: el nivel de batería por debajo del cual la app Casa la muestra como baja.",
      "For a switch shown as a sensor: motion, leak (water), smoke (fire), co, co2, contact or occupancy.": "Para un interruptor mostrado como sensor: motion, leak (water), smoke (fire), co, co2, contact u occupancy.",
      "Garage Door": "Puerta de garaje",
      "Gate": "Portón",
      "General Settings": "General",
      "Group": "Grupo",
      "Group Label": "Etiqueta del grupo",
      "Group Type": "Tipo de grupo",
      "Heat and Cool": "Calor y frío",
      "Heater": "Calefactor",
      "Hide Channels": "Ocultar canales",
      "Hide Humidity": "Ocultar la humedad",
      "Hide Light": "Ocultar la luz",
      "Hide Switch": "Ocultar el interruptor",
      "Hide Temperature": "Ocultar la temperatura",
      "Hides a sensor's own switch from the Home app.": "Oculta el interruptor propio de un sensor en la app Casa.",
      "Hides the fan's built-in light from the Home app.": "Oculta la luz integrada del ventilador en la app Casa.",
      "Hides the humidity reading from the Home app.": "Oculta la humedad en la app Casa.",
      "Hides the temperature reading from the Home app.": "Oculta la temperatura en la app Casa.",
      "How far under the target a TH10/TH16 heater starts. Empty: 0.5 for a heater, 0 for a cooler.": "A qué distancia por debajo del objetivo arranca un calefactor TH10/TH16. Vacío: 0,5 para un calefactor, 0 para un enfriador.",
      "How the plugin reaches devices. Auto tries the local network first, then the cloud.": "Cómo llega el plugin a los dispositivos. Automático prueba primero la red local y luego la nube.",
      "Humidifier": "Humidificador",
      "Humidity Offset": "Ajuste de humedad",
      "Humidity Offset Factor": "Factor de desfase de humedad",
      "In Use Power Threshold (W)": "Umbral de potencia en uso (W)",
      "Inching Channels": "Canales por impulsos",
      "Inching Switch": "Interruptor por impulsos",
      "Index": "Índice",
      "Kept for the Homebridge plugin; it has no effect here.": "Se conserva por el plugin de Homebridge; aquí no tiene efecto.",
      "Kept for the Homebridge plugin; it has no effect here: eWeLink's own groups come from the account.": "Se conserva por el plugin de Homebridge; aquí no tiene efecto: los grupos de eWeLink llegan de la cuenta.",
      "LAN Only": "Solo LAN",
      "Label": "Etiqueta",
      "Leak Sensor": "Sensor de fugas",
      "Leaves each device's state changes out of the log.": "Deja fuera del registro los cambios de estado de cada dispositivo.",
      "Leaves this device's state changes out of the log. Empty takes the plugin's setting.": "Deja los cambios de estado de este dispositivo fuera del registro. Vacío toma el ajuste del plugin.",
      "Lock": "Cerradura",
      "Low Battery Threshold": "Umbral de batería baja",
      "Low Battery Threshold (%)": "Umbral de batería baja (%)",
      "Maximum Target (°C)": "Objetivo máximo (°C)",
      "Minimum Target (°C)": "Objetivo mínimo (°C)",
      "Mireds added to each Adaptive Lighting update, so the light looks warmer; -1 leaves Adaptive Lighting off for this light.": "Mireds que se suman a cada actualización de la Iluminación adaptativa, para una luz más cálida; -1 deja la Iluminación adaptativa desactivada en esta luz.",
      "Motion Sensor": "Sensor de movimiento",
      "Name": "Nombre",
      "No auto-off timer on a switch shown as a valve or a tap.": "Sin temporizador de apagado automático en un interruptor mostrado como válvula o grifo.",
      "Offline devices read as off in the Home app instead of \"No Response\".": "Los dispositivos sin conexión aparecen apagados en la app Casa en lugar de «Sin respuesta».",
      "Offset Factor": "Factor de desfase",
      "One Button": "Un botón",
      "Operation Time (Down, seconds)": "Tiempo de bajada (segundos)",
      "Operation Time (Up, seconds)": "Tiempo de subida (segundos)",
      "Operation Time (seconds)": "Tiempo de maniobra (segundos)",
      "Operation Time Down (seconds)": "Tiempo de bajada (segundos)",
      "Operation Time Up (seconds)": "Tiempo de subida (segundos)",
      "Outlet": "Enchufe",
      "Outline Messages in Log": "Enmarcar los mensajes del registro",
      "Percentage points added to the humidity the device reports; a negative value lowers it.": "Puntos porcentuales que se suman a la humedad que indica el dispositivo; un valor negativo la baja.",
      "Programmable Button": "Botón programable",
      "Purifier": "Purificador",
      "RF Bridge Sensors": "Sensores RF Bridge",
      "RF Subdevices": "Subdispositivos RF",
      "RF sub-device": "Subdispositivo RF",
      "Reset Time (seconds)": "Tiempo de reinicio (segundos)",
      "Seconds a cover takes to close fully. Empty: the opening time.": "Los segundos que tarda una persiana en cerrarse del todo. Vacío: el tiempo de subida.",
      "Seconds a cover takes to open fully, when the device is shown as a blind, a door or a window. Empty: 10.": "Los segundos que tarda una persiana en abrirse del todo, cuando el dispositivo aparece como persiana, puerta o ventana. Vacío: 10.",
      "Seconds a sensor stays triggered.": "Los segundos que un sensor permanece activado.",
      "Seconds for a full open or close. Groups have no effect here.": "Segundos para abrir o cerrar del todo. Los grupos no tienen efecto aquí.",
      "Sensor": "Sensor",
      "Sensor Active Time (seconds)": "Tiempo activo del sensor (segundos)",
      "Sensor Device ID": "ID del sensor",
      "Sensor Time Difference (seconds)": "Diferencia de tiempo del sensor (segundos)",
      "Sensor Type": "Tipo de sensor",
      "Sensor Webhook URL": "URL del webhook del sensor",
      "Settings for the RF sub-devices an RF Bridge learned, each by its full device ID.": "Ajustes de los subdispositivos RF que aprendió un RF Bridge, cada uno por su ID completo.",
      "Settings of the remotes and sensors an RF Bridge learned, by index or by label.": "Los ajustes de los mandos y sensores que aprendió un RF Bridge, por índice o por etiqueta.",
      "Show As": "Mostrar como",
      "Show Offline Devices as Off": "Mostrar los dispositivos sin conexión como apagados",
      "Simulation Type": "Tipo de simulación",
      "Smoke Sensor": "Sensor de humo",
      "Sub-device": "Subdispositivo",
      "Sub-devices": "Subdispositivos",
      "Switch": "Interruptor",
      "Tap": "Grifo",
      "Target Threshold (°C)": "Umbral del objetivo (°C)",
      "Television": "Televisor",
      "Temperature Offset": "Ajuste de temperatura",
      "Temperature Source": "Fuente de temperatura",
      "The accessory the device appears as in the Home app: a switch's simulations (a valve, a lock, a garage door, a sensor, a heater following another device's temperature…), a cover for a multi-channel device, a thermostat or climate device for a TH10/TH16, a fan for a dimmer.": "El accesorio con el que aparece el dispositivo en la app Casa: las simulaciones de un interruptor (una válvula, una cerradura, una puerta de garaje, un sensor, un calefactor que sigue la temperatura de otro dispositivo…), una persiana para un dispositivo de varios canales, un termostato o un aparato de clima para un TH10/TH16, un ventilador para un regulador.",
      "The accessory the group would appear as. Groups have no effect here.": "El accesorio con el que aparecería el grupo. Los grupos no tienen efecto aquí.",
      "The account's country dial code (+1 for the US, +44 for the UK, +86 for China): it picks the eWeLink API region.": "El prefijo telefónico del país de la cuenta (+1 para EE. UU., +44 para el Reino Unido, +86 para China): elige la región de la API de eWeLink.",
      "The battery level, in percent, below which the Home app shows the battery as low.": "El nivel de batería, en porcentaje, por debajo del cual la app Casa muestra la batería baja.",
      "The channels are inching switches: the master switch stays out of the Home app.": "Los canales son interruptores por impulsos: el interruptor principal queda fuera de la app Casa.",
      "The curtain remote's buttons. The curtain appears as its buttons in the Home app whichever is chosen.": "Los botones del mando de la cortina. La cortina aparece en la app Casa como sus botones, elijas lo que elijas.",
      "The device ID of the sensor whose temperature a switch shown as a heater or a cooler follows.": "El ID del sensor cuya temperatura sigue un interruptor mostrado como calefactor o enfriador.",
      "The devices in the group. Groups have no effect here.": "Los dispositivos del grupo. Los grupos no tienen efecto aquí.",
      "The highest target a TH10/TH16 simulation takes. Empty: 30.": "El objetivo más alto de una simulación TH10/TH16. Vacío: 30.",
      "The humidity offset multiplies the reading instead of being added to it.": "El desfase de humedad multiplica la lectura en lugar de sumarse a ella.",
      "The kind of a simulation that has several, such as a lock's.": "El tipo de una simulación que tiene varios, como la de una cerradura.",
      "The lowest target a TH10/TH16 simulation takes. Empty: 10.": "El objetivo más bajo de una simulación TH10/TH16. Vacío: 10.",
      "The name of this platform in the log.": "El nombre de esta plataforma en el registro.",
      "The step of the speed slider, 1 to 100, when a dimmer is shown as a fan.": "El paso del control de velocidad, de 1 a 100, cuando un regulador se muestra como ventilador.",
      "The sub-device's button index, from 0.": "El índice del botón del subdispositivo, desde 0.",
      "The sub-device's full ID: the RF Bridge's device ID, SW and the sub-device's number, such as 1000ab23cdSW2.": "El ID completo del subdispositivo: el ID del RF Bridge, SW y el número del subdispositivo, por ejemplo 1000ab23cdSW2.",
      "The sub-device's name in eWeLink, for a cover's times.": "El nombre del subdispositivo en eWeLink, para los tiempos de una persiana.",
      "The switch is an inching one: it always gets on, and the Home app shows it toggled.": "El interruptor es por impulsos: siempre recibe encendido y la app Casa lo muestra alternado.",
      "The temperature offset multiplies the reading instead of being added to it.": "El desfase de temperatura multiplica la lectura en lugar de sumarse a ella.",
      "The watts above which an outlet with power monitoring is in use.": "Los vatios por encima de los cuales un enchufe con medición de potencia está en uso.",
      "Thermostat": "Termostato",
      "Three Buttons": "Tres botones",
      "Two Buttons": "Dos botones",
      "Valve": "Válvula",
      "Water Sensor": "Sensor de agua",
      "What a sensor sub-device is: motion, contact, water, smoke, co, co2, occupancy, button or doorbell.": "Qué es un subdispositivo sensor: motion, contact, water, smoke, co, co2, occupancy, button o doorbell.",
      "Window": "Ventana",
      "offlineAsOff: a dimmer shown as a fan reads as off while it is offline.": "offlineAsOff: un regulador mostrado como ventilador figura apagado mientras está sin conexión."
    },
    "pt": {
      "A TH10/TH16 shown as a thermostat offers off, heat and cool instead of off and auto.": "Um TH10/TH16 mostrado como termóstato oferece desligado, aquecer e arrefecer em vez de desligado e automático.",
      "A name for the group. Groups have no effect here.": "Um nome para o grupo. Os grupos não têm efeito aqui.",
      "A name to recognise this entry; it has no effect on the device.": "Um nome para reconhecer esta entrada; não afeta o dispositivo.",
      "Accessories write their debug lines to the log.": "Os acessórios escrevem as suas linhas de depuração no registo.",
      "Adaptive Lighting Shift": "Desvio da iluminação adaptativa",
      "Auto (LAN + Cloud)": "Automático (LAN + nuvem)",
      "Blind": "Estore",
      "Brightness Step": "Passo de brilho",
      "Button": "Botão",
      "CO Sensor": "Sensor de CO",
      "Channels to hide from the Home app, by number (1, 2...; 0 is the master switch) or full ID (1000abcdefSW1), separated by commas.": "Os canais a ocultar na app Casa, por número (1, 2...; 0 é o interruptor principal) ou por ID completo (1000abcdefSW1), separados por vírgulas.",
      "Cloud Only": "Apenas nuvem",
      "Connection Mode": "Modo de ligação",
      "Connection Settings": "Ligação",
      "Contact Sensor": "Sensor de contacto",
      "Cooler": "Arrefecedor",
      "Country Code": "Indicativo do país",
      "Curtain": "Cortina",
      "Curtain Type": "Tipo de cortina",
      "Debug Mode": "Modo de depuração",
      "Default": "Predefinido",
      "Degrees added to an air conditioner's or a panel's temperature, or the factor it is multiplied by with Offset Factor.": "Os graus somados à temperatura de um ar condicionado ou de um painel, ou o fator que a multiplica com Fator de desvio.",
      "Degrees added to the temperature the device reports; a negative value lowers it.": "Graus somados à temperatura que o dispositivo indica; um valor negativo baixa-a.",
      "Dehumidifier": "Desumidificador",
      "Device Groups": "Grupos de dispositivos",
      "Device IDs": "IDs de dispositivos",
      "Device Model": "Modelo do dispositivo",
      "Disable Device Logging": "Desativar o registo dos dispositivos",
      "Disable Timer": "Desativar o temporizador",
      "Door": "Porta",
      "Doorbell": "Campainha",
      "Fan": "Ventoinha",
      "Fire Sensor": "Sensor de incêndio",
      "For a switch shown as a leak sensor: the battery level below which the Home app shows the battery as low.": "Para um interruptor mostrado como sensor de fugas: o nível de bateria abaixo do qual a app Casa a mostra como fraca.",
      "For a switch shown as a sensor: motion, leak (water), smoke (fire), co, co2, contact or occupancy.": "Para um interruptor mostrado como sensor: motion, leak (water), smoke (fire), co, co2, contact ou occupancy.",
      "Garage Door": "Porta de garagem",
      "Gate": "Portão",
      "General Settings": "Geral",
      "Group": "Grupo",
      "Group Label": "Etiqueta do grupo",
      "Group Type": "Tipo de grupo",
      "Heat and Cool": "Aquecer e arrefecer",
      "Heater": "Aquecedor",
      "Hide Channels": "Ocultar canais",
      "Hide Humidity": "Ocultar a humidade",
      "Hide Light": "Ocultar a luz",
      "Hide Switch": "Ocultar o interruptor",
      "Hide Temperature": "Ocultar a temperatura",
      "Hides a sensor's own switch from the Home app.": "Oculta o interruptor próprio de um sensor na app Casa.",
      "Hides the fan's built-in light from the Home app.": "Oculta a luz integrada da ventoinha na app Casa.",
      "Hides the humidity reading from the Home app.": "Oculta a humidade na app Casa.",
      "Hides the temperature reading from the Home app.": "Oculta a temperatura na app Casa.",
      "How far under the target a TH10/TH16 heater starts. Empty: 0.5 for a heater, 0 for a cooler.": "A que distância abaixo do alvo arranca um aquecedor TH10/TH16. Vazio: 0,5 para um aquecedor, 0 para um arrefecedor.",
      "How the plugin reaches devices. Auto tries the local network first, then the cloud.": "Como o plugin chega aos dispositivos. Automático tenta primeiro a rede local e depois a nuvem.",
      "Humidifier": "Humidificador",
      "Humidity Offset": "Correção de humidade",
      "Humidity Offset Factor": "Fator de desvio de humidade",
      "In Use Power Threshold (W)": "Limiar de potência em utilização (W)",
      "Inching Channels": "Canais por impulso",
      "Inching Switch": "Interruptor por impulso",
      "Index": "Índice",
      "Kept for the Homebridge plugin; it has no effect here.": "Mantido pelo plugin Homebridge; aqui não tem efeito.",
      "Kept for the Homebridge plugin; it has no effect here: eWeLink's own groups come from the account.": "Mantido pelo plugin Homebridge; aqui não tem efeito: os grupos eWeLink vêm da conta.",
      "LAN Only": "Apenas LAN",
      "Label": "Etiqueta",
      "Leak Sensor": "Sensor de fugas",
      "Leaves each device's state changes out of the log.": "Deixa fora do registo as mudanças de estado de cada dispositivo.",
      "Leaves this device's state changes out of the log. Empty takes the plugin's setting.": "Deixa as mudanças de estado deste dispositivo fora do registo. Vazio usa a definição do plugin.",
      "Lock": "Fechadura",
      "Low Battery Threshold": "Limiar de bateria fraca",
      "Low Battery Threshold (%)": "Limiar de bateria fraca (%)",
      "Maximum Target (°C)": "Alvo máximo (°C)",
      "Minimum Target (°C)": "Alvo mínimo (°C)",
      "Mireds added to each Adaptive Lighting update, so the light looks warmer; -1 leaves Adaptive Lighting off for this light.": "Mireds somados a cada atualização da Iluminação adaptativa, para uma luz mais quente; -1 deixa a Iluminação adaptativa desligada nesta luz.",
      "Motion Sensor": "Sensor de movimento",
      "Name": "Nome",
      "No auto-off timer on a switch shown as a valve or a tap.": "Sem temporizador de desligar automático num interruptor mostrado como válvula ou torneira.",
      "Offline devices read as off in the Home app instead of \"No Response\".": "Os dispositivos offline aparecem desligados na app Casa em vez de «Sem resposta».",
      "Offset Factor": "Fator de desvio",
      "One Button": "Um botão",
      "Operation Time (Down, seconds)": "Tempo de descida (segundos)",
      "Operation Time (Up, seconds)": "Tempo de subida (segundos)",
      "Operation Time (seconds)": "Tempo de manobra (segundos)",
      "Operation Time Down (seconds)": "Tempo de descida (segundos)",
      "Operation Time Up (seconds)": "Tempo de subida (segundos)",
      "Outlet": "Tomada",
      "Outline Messages in Log": "Destacar as mensagens no registo",
      "Percentage points added to the humidity the device reports; a negative value lowers it.": "Pontos percentuais somados à humidade que o dispositivo indica; um valor negativo baixa-a.",
      "Programmable Button": "Botão programável",
      "Purifier": "Purificador",
      "RF Bridge Sensors": "Sensores RF Bridge",
      "RF Subdevices": "Subdispositivos RF",
      "RF sub-device": "Subdispositivo RF",
      "Reset Time (seconds)": "Tempo de reposição (segundos)",
      "Seconds a cover takes to close fully. Empty: the opening time.": "Os segundos que um estore demora a fechar por completo. Vazio: o tempo de subida.",
      "Seconds a cover takes to open fully, when the device is shown as a blind, a door or a window. Empty: 10.": "Os segundos que um estore demora a abrir por completo, quando o dispositivo aparece como estore, porta ou janela. Vazio: 10.",
      "Seconds a sensor stays triggered.": "Os segundos que um sensor permanece ativado.",
      "Seconds for a full open or close. Groups have no effect here.": "Segundos para abrir ou fechar por completo. Os grupos não têm efeito aqui.",
      "Sensor": "Sensor",
      "Sensor Active Time (seconds)": "Tempo ativo do sensor (segundos)",
      "Sensor Device ID": "ID do sensor",
      "Sensor Time Difference (seconds)": "Diferença de tempo do sensor (segundos)",
      "Sensor Type": "Tipo de sensor",
      "Sensor Webhook URL": "URL do webhook do sensor",
      "Settings for the RF sub-devices an RF Bridge learned, each by its full device ID.": "Definições dos subdispositivos RF que um RF Bridge aprendeu, cada um pelo seu ID completo.",
      "Settings of the remotes and sensors an RF Bridge learned, by index or by label.": "As definições dos comandos e sensores que um RF Bridge aprendeu, por índice ou por etiqueta.",
      "Show As": "Mostrar como",
      "Show Offline Devices as Off": "Mostrar os dispositivos offline como desligados",
      "Simulation Type": "Tipo de simulação",
      "Smoke Sensor": "Sensor de fumo",
      "Sub-device": "Subdispositivo",
      "Sub-devices": "Subdispositivos",
      "Switch": "Interruptor",
      "Tap": "Torneira",
      "Target Threshold (°C)": "Limiar do alvo (°C)",
      "Television": "Televisão",
      "Temperature Offset": "Correção de temperatura",
      "Temperature Source": "Fonte de temperatura",
      "The accessory the device appears as in the Home app: a switch's simulations (a valve, a lock, a garage door, a sensor, a heater following another device's temperature…), a cover for a multi-channel device, a thermostat or climate device for a TH10/TH16, a fan for a dimmer.": "O acessório com que o dispositivo aparece na app Casa: as simulações de um interruptor (uma válvula, uma fechadura, uma porta de garagem, um sensor, um aquecedor que segue a temperatura de outro dispositivo…), um estore para um dispositivo de vários canais, um termóstato ou um aparelho de clima para um TH10/TH16, uma ventoinha para um regulador.",
      "The accessory the group would appear as. Groups have no effect here.": "O acessório com que o grupo apareceria. Os grupos não têm efeito aqui.",
      "The account's country dial code (+1 for the US, +44 for the UK, +86 for China): it picks the eWeLink API region.": "O indicativo telefónico do país da conta (+1 para os EUA, +44 para o Reino Unido, +86 para a China): escolhe a região da API eWeLink.",
      "The battery level, in percent, below which the Home app shows the battery as low.": "O nível de bateria, em percentagem, abaixo do qual a app Casa mostra a bateria fraca.",
      "The channels are inching switches: the master switch stays out of the Home app.": "Os canais são interruptores por impulso: o interruptor principal fica fora da app Casa.",
      "The curtain remote's buttons. The curtain appears as its buttons in the Home app whichever is chosen.": "Os botões do comando da cortina. A cortina aparece na app Casa como os seus botões, seja qual for a escolha.",
      "The device ID of the sensor whose temperature a switch shown as a heater or a cooler follows.": "O ID do sensor cuja temperatura segue um interruptor mostrado como aquecedor ou arrefecedor.",
      "The devices in the group. Groups have no effect here.": "Os dispositivos do grupo. Os grupos não têm efeito aqui.",
      "The highest target a TH10/TH16 simulation takes. Empty: 30.": "O alvo mais alto de uma simulação TH10/TH16. Vazio: 30.",
      "The humidity offset multiplies the reading instead of being added to it.": "O desvio de humidade multiplica a leitura em vez de lhe ser somado.",
      "The kind of a simulation that has several, such as a lock's.": "O tipo de uma simulação que tem vários, como a de uma fechadura.",
      "The lowest target a TH10/TH16 simulation takes. Empty: 10.": "O alvo mais baixo de uma simulação TH10/TH16. Vazio: 10.",
      "The name of this platform in the log.": "O nome desta plataforma no registo.",
      "The step of the speed slider, 1 to 100, when a dimmer is shown as a fan.": "O passo do controlo de velocidade, de 1 a 100, quando um regulador é mostrado como ventoinha.",
      "The sub-device's button index, from 0.": "O índice do botão do subdispositivo, a partir de 0.",
      "The sub-device's full ID: the RF Bridge's device ID, SW and the sub-device's number, such as 1000ab23cdSW2.": "O ID completo do subdispositivo: o ID do RF Bridge, SW e o número do subdispositivo, por exemplo 1000ab23cdSW2.",
      "The sub-device's name in eWeLink, for a cover's times.": "O nome do subdispositivo no eWeLink, para os tempos de um estore.",
      "The switch is an inching one: it always gets on, and the Home app shows it toggled.": "O interruptor é por impulso: recebe sempre ligado e a app Casa mostra-o alternado.",
      "The temperature offset multiplies the reading instead of being added to it.": "O desvio de temperatura multiplica a leitura em vez de lhe ser somado.",
      "The watts above which an outlet with power monitoring is in use.": "Os watts acima dos quais uma tomada com medição de potência está em utilização.",
      "Thermostat": "Termóstato",
      "Three Buttons": "Três botões",
      "Two Buttons": "Dois botões",
      "Valve": "Válvula",
      "Water Sensor": "Sensor de água",
      "What a sensor sub-device is: motion, contact, water, smoke, co, co2, occupancy, button or doorbell.": "O que é um subdispositivo sensor: motion, contact, water, smoke, co, co2, occupancy, button ou doorbell.",
      "Window": "Janela",
      "offlineAsOff: a dimmer shown as a fan reads as off while it is offline.": "offlineAsOff: um regulador mostrado como ventoinha aparece desligado enquanto está offline."
    }
  }
}
"""#
}
