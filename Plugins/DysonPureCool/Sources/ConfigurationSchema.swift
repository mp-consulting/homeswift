// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension DysonPureCoolPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "DysonPureCool",
  "pluginType": "platform",
  "singular": true,
  "customUi": true,
  "headerDisplay": "Dyson Pure Cool, Hot+Cool, Humidify+Cool and Big+Quiet devices, over their local connection. Add them on Add accessories, which signs in to your Dyson account.",
  "footerDisplay": "For help, see the [README](https://github.com/homebridge/homebridge-dyson-pure-cool#readme)",
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "default": "Dyson Pure Cool",
        "description": "Name of the platform in the bridge's log"
      },
      "countryCode": {
        "title": "Country Code",
        "type": "string",
        "default": "US",
        "description": "Your Dyson account's country. Setup sets it when it signs in.",
        "oneOf": [
          {
            "title": "United States",
            "enum": [
              "US"
            ]
          },
          {
            "title": "United Kingdom",
            "enum": [
              "GB"
            ]
          },
          {
            "title": "Germany",
            "enum": [
              "DE"
            ]
          },
          {
            "title": "France",
            "enum": [
              "FR"
            ]
          },
          {
            "title": "Italy",
            "enum": [
              "IT"
            ]
          },
          {
            "title": "Spain",
            "enum": [
              "ES"
            ]
          },
          {
            "title": "Netherlands",
            "enum": [
              "NL"
            ]
          },
          {
            "title": "Belgium",
            "enum": [
              "BE"
            ]
          },
          {
            "title": "Austria",
            "enum": [
              "AT"
            ]
          },
          {
            "title": "Switzerland",
            "enum": [
              "CH"
            ]
          },
          {
            "title": "Australia",
            "enum": [
              "AU"
            ]
          },
          {
            "title": "New Zealand",
            "enum": [
              "NZ"
            ]
          },
          {
            "title": "Canada",
            "enum": [
              "CA"
            ]
          },
          {
            "title": "Ireland",
            "enum": [
              "IE"
            ]
          },
          {
            "title": "Sweden",
            "enum": [
              "SE"
            ]
          },
          {
            "title": "Norway",
            "enum": [
              "NO"
            ]
          },
          {
            "title": "Denmark",
            "enum": [
              "DK"
            ]
          },
          {
            "title": "Finland",
            "enum": [
              "FI"
            ]
          },
          {
            "title": "Japan",
            "enum": [
              "JP"
            ]
          },
          {
            "title": "Singapore",
            "enum": [
              "SG"
            ]
          },
          {
            "title": "Hong Kong",
            "enum": [
              "HK"
            ]
          },
          {
            "title": "China",
            "enum": [
              "CN"
            ]
          }
        ]
      },
      "pollingInterval": {
        "title": "Polling Interval",
        "type": "integer",
        "default": 60,
        "minimum": 10,
        "maximum": 300,
        "description": "How often to ask each device for its state, in seconds (10 to 300)"
      },
      "discoveryTimeout": {
        "title": "Discovery Timeout",
        "type": "number",
        "default": 10,
        "description": "Seconds to look for devices on the network over mDNS (default 10; a value over 60 is read as milliseconds)"
      },
      "enableTemperature": {
        "title": "Enable Temperature Sensor",
        "type": "boolean",
        "default": true,
        "description": "Show temperature readings in HomeKit. A device's own setting overrides it"
      },
      "enableHumidity": {
        "title": "Enable Humidity Sensor",
        "type": "boolean",
        "default": true,
        "description": "Show humidity readings in HomeKit. A device's own setting overrides it"
      },
      "enableAirQuality": {
        "title": "Enable Air Quality Sensor",
        "type": "boolean",
        "default": true,
        "description": "Show air quality sensor (PM2.5, PM10, VOC, NO2) in HomeKit. A device's own setting overrides it"
      },
      "enableNightMode": {
        "title": "Enable Night Mode Switch",
        "type": "boolean",
        "default": true,
        "description": "Add a switch to control night mode. A device's own setting overrides it"
      },
      "enableAutoMode": {
        "title": "Enable Auto Mode Switch",
        "type": "boolean",
        "default": true,
        "description": "Kept for the settings page: the air purifier's Auto/Manual control is always shown, so it has no effect"
      },
      "enableContinuousMonitoring": {
        "title": "Enable Continuous Monitoring Switch",
        "type": "boolean",
        "default": false,
        "description": "Show continuous monitoring toggle switch in HomeKit. A device's own setting overrides it"
      },
      "enableJetFocus": {
        "title": "Enable Jet Focus Switch",
        "type": "boolean",
        "default": true,
        "description": "Show jet focus (front airflow) toggle switch in HomeKit. A device's own setting overrides it"
      },
      "enableHeater": {
        "title": "Enable Heater (HP Models)",
        "type": "boolean",
        "default": true,
        "description": "Show heater/thermostat control for Hot+Cool models. A device's own setting overrides it"
      },
      "enableHumidifier": {
        "title": "Enable Humidifier (PH Models)",
        "type": "boolean",
        "default": true,
        "description": "Show humidifier control for Humidify+Cool models. A device's own setting overrides it"
      },
      "enableFilterStatus": {
        "title": "Enable Filter Status",
        "type": "boolean",
        "default": false,
        "description": "Show filter life remaining indicator. A device's own setting overrides it"
      },
      "isSingleAccessoryModeEnabled": {
        "title": "Single Accessory Mode",
        "type": "boolean",
        "default": false,
        "description": "Kept for compatibility with the Homebridge plugin, which never implemented it: it has no effect"
      },
      "isSingleSensorAccessoryModeEnabled": {
        "title": "Single Sensor Accessory Mode",
        "type": "boolean",
        "default": false,
        "description": "Kept for compatibility with the Homebridge plugin, which never implemented it: it has no effect"
      }
    },
    "required": [
      "name"
    ]
  },
  "accessorySchema": {
    "properties": {
      "productType": {
        "title": "Product Type",
        "type": "string",
        "description": "The Dyson model. Setup fills it in from the Dyson account.",
        "oneOf": [
          {
            "title": "TP02 - Pure Cool Link Tower",
            "enum": [
              "475"
            ]
          },
          {
            "title": "TP04 - Pure Cool Tower",
            "enum": [
              "438"
            ]
          },
          {
            "title": "TP07 - Purifier Cool",
            "enum": [
              "438E"
            ]
          },
          {
            "title": "TP09 - Pure Cool Formaldehyde",
            "enum": [
              "438K"
            ]
          },
          {
            "title": "TP11 - Purifier Cool",
            "enum": [
              "438M"
            ]
          },
          {
            "title": "DP01 - Pure Cool Link Desk",
            "enum": [
              "469"
            ]
          },
          {
            "title": "DP04 - Pure Cool Desk",
            "enum": [
              "520"
            ]
          },
          {
            "title": "HP02 - Pure Hot+Cool Link",
            "enum": [
              "455"
            ]
          },
          {
            "title": "HP04 - Pure Hot+Cool",
            "enum": [
              "527"
            ]
          },
          {
            "title": "PH05 - Purifier Humidify+Cool De-Nox",
            "enum": [
              "358K"
            ]
          },
          {
            "title": "HP07 - Pure Hot+Cool",
            "enum": [
              "527E"
            ]
          },
          {
            "title": "HP09 - Pure Hot+Cool Formaldehyde",
            "enum": [
              "527K"
            ]
          },
          {
            "title": "HP1/HP11 - Purifier Hot+Cool",
            "enum": [
              "527M"
            ]
          },
          {
            "title": "PH01 - Purifier Humidify+Cool",
            "enum": [
              "358"
            ]
          },
          {
            "title": "PH02 - Purifier Humidify+Cool",
            "enum": [
              "520E"
            ]
          },
          {
            "title": "PH03 - Purifier Humidify+Cool",
            "enum": [
              "358H"
            ]
          },
          {
            "title": "PH03 - Purifier Humidify+Cool",
            "enum": [
              "358J"
            ]
          },
          {
            "title": "PH03/PH04 - Purifier Humidify+Cool Formaldehyde",
            "enum": [
              "358E"
            ]
          },
          {
            "title": "PH04 - Purifier Humidify+Cool Formaldehyde",
            "enum": [
              "520F"
            ]
          },
          {
            "title": "BP02 - Purifier Big+Quiet",
            "enum": [
              "664"
            ]
          },
          {
            "title": "BP03 - Purifier Big+Quiet Formaldehyde",
            "enum": [
              "664B"
            ]
          },
          {
            "title": "BP04 - Purifier Big+Quiet Formaldehyde",
            "enum": [
              "664E"
            ]
          },
          {
            "title": "BP06 - Purifier Big+Quiet",
            "enum": [
              "664F"
            ]
          },
          {
            "title": "CF1 - Dyson Cool",
            "enum": [
              "739"
            ]
          }
        ]
      },
      "ipAddress": {
        "title": "IP Address (Optional)",
        "type": "string",
        "format": "ipv4",
        "description": "Static IP address (leave empty for auto-discovery)"
      },
      "firmwareVersion": {
        "title": "Firmware Version",
        "type": "string",
        "description": "Firmware version reported by the Dyson cloud, shown as the accessory's firmware in HomeKit (set by Setup)"
      },
      "temperatureOffset": {
        "title": "Temperature Offset",
        "type": "number",
        "default": 0,
        "minimum": -10,
        "maximum": 10,
        "description": "Adjust temperature reading by this amount in Celsius"
      },
      "humidityOffset": {
        "title": "Humidity Offset",
        "type": "integer",
        "default": 0,
        "minimum": -20,
        "maximum": 20,
        "description": "Adjust humidity reading by this many percentage points"
      },
      "useFahrenheit": {
        "title": "Use Fahrenheit",
        "type": "boolean",
        "default": false,
        "description": "Show temperatures in Fahrenheit in the log (HomeKit always receives Celsius)"
      },
      "enableTemperature": {
        "title": "Enable Temperature Sensor",
        "type": "boolean",
        "description": "Shows this device's temperature sensor in the Home app",
        "x-default": "enableTemperature"
      },
      "enableHumidity": {
        "title": "Enable Humidity Sensor",
        "type": "boolean",
        "description": "Shows this device's humidity sensor in the Home app",
        "x-default": "enableHumidity"
      },
      "enableAirQuality": {
        "title": "Enable Air Quality Sensor",
        "type": "boolean",
        "description": "Shows this device's air quality sensor in the Home app",
        "x-default": "enableAirQuality"
      },
      "enableNightMode": {
        "title": "Enable Night Mode Switch",
        "type": "boolean",
        "description": "Shows this device's night mode switch in the Home app",
        "x-default": "enableNightMode"
      },
      "enableJetFocus": {
        "title": "Enable Jet Focus Switch",
        "type": "boolean",
        "description": "Shows this device's jet focus switch, on models that have one",
        "x-default": "enableJetFocus"
      },
      "enableContinuousMonitoring": {
        "title": "Enable Continuous Monitoring Switch",
        "type": "boolean",
        "description": "Show continuous monitoring switch to keep sensors active when device is off",
        "x-default": "enableContinuousMonitoring"
      },
      "enableFilterStatus": {
        "title": "Enable Filter Status",
        "type": "boolean",
        "description": "Shows this device's filter life remaining",
        "x-default": "enableFilterStatus"
      },
      "enableHeater": {
        "title": "Enable Heater (HP Models)",
        "type": "boolean",
        "description": "Shows the heater or thermostat control of this Hot+Cool device",
        "x-kinds": [
          "heater"
        ],
        "x-default": "enableHeater"
      },
      "heatingServiceType": {
        "title": "Heating Service Type",
        "type": "string",
        "default": "thermostat",
        "description": "Which HomeKit service to use for heating control",
        "oneOf": [
          {
            "title": "Thermostat (Recommended)",
            "enum": [
              "thermostat"
            ]
          },
          {
            "title": "Heater Cooler",
            "enum": [
              "heater-cooler"
            ]
          },
          {
            "title": "Both",
            "enum": [
              "both"
            ]
          }
        ],
        "x-kinds": [
          "heater"
        ]
      },
      "enableHumidifier": {
        "title": "Enable Humidifier (PH Models)",
        "type": "boolean",
        "description": "Shows the humidifier control of this Humidify+Cool device",
        "x-kinds": [
          "humidifier"
        ],
        "x-default": "enableHumidifier"
      },
      "fullRangeHumidity": {
        "title": "Full Range Humidity",
        "type": "boolean",
        "default": false,
        "description": "Let the humidifier's target humidity range from 0 to 100% (default: 30 to 70%)",
        "x-kinds": [
          "humidifier"
        ]
      },
      "enableAutoModeWhenActivating": {
        "title": "Enable Auto Mode on Activation",
        "type": "boolean",
        "default": false,
        "description": "Automatically enable auto mode when turning device on"
      },
      "enableOscillationWhenActivating": {
        "title": "Enable Oscillation on Activation",
        "type": "boolean",
        "default": false,
        "description": "Automatically enable oscillation when turning device on"
      },
      "enableNightModeWhenActivating": {
        "title": "Enable Night Mode on Activation",
        "type": "boolean",
        "default": false,
        "description": "Automatically enable night mode when turning device on"
      }
    }
  },
  "layout": [
    "name",
    {
      "type": "fieldset",
      "title": "Sensor Options",
      "expandable": true,
      "expanded": false,
      "items": [
        "enableTemperature",
        "enableHumidity",
        "enableAirQuality"
      ]
    },
    {
      "type": "fieldset",
      "title": "Additional Controls",
      "expandable": true,
      "expanded": false,
      "items": [
        "enableNightMode",
        "enableAutoMode",
        "enableContinuousMonitoring",
        "enableJetFocus",
        "enableHeater",
        "enableHumidifier",
        "enableFilterStatus"
      ]
    },
    {
      "type": "fieldset",
      "title": "Display Mode",
      "expandable": true,
      "expanded": false,
      "items": [
        "isSingleAccessoryModeEnabled",
        "isSingleSensorAccessoryModeEnabled"
      ]
    },
    {
      "type": "fieldset",
      "title": "Advanced Settings",
      "expandable": true,
      "expanded": false,
      "items": [
        "countryCode",
        "pollingInterval",
        "discoveryTimeout"
      ]
    }
  ],
  "i18n": {
    "fr": {
      "Add a switch to control night mode. A device's own setting overrides it": "Ajoute un interrupteur qui commande le mode nuit. Le réglage propre à un appareil l'emporte",
      "Additional Controls": "Commandes supplémentaires",
      "Adjust humidity reading by this many percentage points": "Corrige l'humidité lue de ce nombre de points de pourcentage",
      "Adjust temperature reading by this amount in Celsius": "Corrige la température lue de cette valeur, en degrés Celsius",
      "Advanced Settings": "Réglages avancés",
      "Australia": "Australie",
      "Austria": "Autriche",
      "Automatically enable auto mode when turning device on": "Active le mode auto à chaque allumage de l'appareil",
      "Automatically enable night mode when turning device on": "Active le mode nuit à chaque allumage de l'appareil",
      "Automatically enable oscillation when turning device on": "Active l'oscillation à chaque allumage de l'appareil",
      "BP02 - Purifier Big+Quiet": "BP02 - Purifier Big+Quiet",
      "BP03 - Purifier Big+Quiet Formaldehyde": "BP03 - Purifier Big+Quiet Formaldehyde",
      "BP04 - Purifier Big+Quiet Formaldehyde": "BP04 - Purifier Big+Quiet Formaldehyde",
      "BP06 - Purifier Big+Quiet": "BP06 - Purifier Big+Quiet",
      "Belgium": "Belgique",
      "Both": "Les deux",
      "CF1 - Dyson Cool": "CF1 - Dyson Cool",
      "Canada": "Canada",
      "China": "Chine",
      "Country Code": "Code pays",
      "DP01 - Pure Cool Link Desk": "DP01 - Pure Cool Link Desk",
      "DP04 - Pure Cool Desk": "DP04 - Pure Cool Desk",
      "Denmark": "Danemark",
      "Discovery Timeout": "Durée de découverte",
      "Display Mode": "Mode d'affichage",
      "Enable Air Quality Sensor": "Capteur de qualité de l'air",
      "Enable Auto Mode Switch": "Interrupteur du mode auto",
      "Enable Auto Mode on Activation": "Mode auto à l'allumage",
      "Enable Continuous Monitoring Switch": "Interrupteur de surveillance continue",
      "Enable Filter Status": "État du filtre",
      "Enable Heater (HP Models)": "Chauffage (modèles HP)",
      "Enable Humidifier (PH Models)": "Humidificateur (modèles PH)",
      "Enable Humidity Sensor": "Capteur d'humidité",
      "Enable Jet Focus Switch": "Interrupteur Jet Focus",
      "Enable Night Mode Switch": "Interrupteur du mode nuit",
      "Enable Night Mode on Activation": "Mode nuit à l'allumage",
      "Enable Oscillation on Activation": "Oscillation à l'allumage",
      "Enable Temperature Sensor": "Capteur de température",
      "Finland": "Finlande",
      "Firmware Version": "Version du firmware",
      "Firmware version reported by the Dyson cloud, shown as the accessory's firmware in HomeKit (set by Setup)": "Version du firmware indiquée par le cloud Dyson, affichée comme firmware de l'accessoire dans HomeKit (renseignée par Setup)",
      "France": "France",
      "Full Range Humidity": "Plage d'humidité complète",
      "Germany": "Allemagne",
      "HP02 - Pure Hot+Cool Link": "HP02 - Pure Hot+Cool Link",
      "HP04 - Pure Hot+Cool": "HP04 - Pure Hot+Cool",
      "HP07 - Pure Hot+Cool": "HP07 - Pure Hot+Cool",
      "HP09 - Pure Hot+Cool Formaldehyde": "HP09 - Pure Hot+Cool Formaldehyde",
      "HP1/HP11 - Purifier Hot+Cool": "HP1/HP11 - Purifier Hot+Cool",
      "Heater Cooler": "Chauffage/climatisation",
      "Heating Service Type": "Type de service de chauffage",
      "Hong Kong": "Hong Kong",
      "How often to ask each device for its state, in seconds (10 to 300)": "Fréquence à laquelle chaque appareil est interrogé sur son état, en secondes (de 10 à 300)",
      "Humidity Offset": "Correction d'humidité",
      "IP Address (Optional)": "Adresse IP (facultatif)",
      "Ireland": "Irlande",
      "Italy": "Italie",
      "Japan": "Japon",
      "Kept for compatibility with the Homebridge plugin, which never implemented it: it has no effect": "Conservé pour la compatibilité avec le plugin Homebridge, qui ne l'a jamais mis en œuvre : il n'a aucun effet",
      "Kept for the settings page: the air purifier's Auto/Manual control is always shown, so it has no effect": "Conservé pour la page de réglages : la commande Auto/Manuel du purificateur d'air est toujours affichée, ce réglage n'a donc aucun effet",
      "Let the humidifier's target humidity range from 0 to 100% (default: 30 to 70%)": "Permet de régler l'humidité cible de l'humidificateur de 0 à 100 % (par défaut : de 30 à 70 %)",
      "Name": "Nom",
      "Name of the platform in the bridge's log": "Nom de la plateforme dans le journal du pont",
      "Netherlands": "Pays-Bas",
      "New Zealand": "Nouvelle-Zélande",
      "Norway": "Norvège",
      "PH01 - Purifier Humidify+Cool": "PH01 - Purifier Humidify+Cool",
      "PH02 - Purifier Humidify+Cool": "PH02 - Purifier Humidify+Cool",
      "PH03 - Purifier Humidify+Cool": "PH03 - Purifier Humidify+Cool",
      "PH03/PH04 - Purifier Humidify+Cool Formaldehyde": "PH03/PH04 - Purifier Humidify+Cool Formaldehyde",
      "PH04 - Purifier Humidify+Cool Formaldehyde": "PH04 - Purifier Humidify+Cool Formaldehyde",
      "PH05 - Purifier Humidify+Cool De-Nox": "PH05 - Purifier Humidify+Cool De-Nox",
      "Polling Interval": "Intervalle d'interrogation",
      "Product Type": "Type de produit",
      "Seconds to look for devices on the network over mDNS (default 10; a value over 60 is read as milliseconds)": "Secondes passées à chercher les appareils sur le réseau par mDNS (10 par défaut ; une valeur au-delà de 60 est lue en millisecondes)",
      "Sensor Options": "Options des capteurs",
      "Show air quality sensor (PM2.5, PM10, VOC, NO2) in HomeKit. A device's own setting overrides it": "Affiche le capteur de qualité de l'air (PM2.5, PM10, COV, NO2) dans HomeKit. Le réglage propre à un appareil l'emporte",
      "Show continuous monitoring switch to keep sensors active when device is off": "Affiche un interrupteur de surveillance continue, qui garde les capteurs actifs quand l'appareil est éteint",
      "Show continuous monitoring toggle switch in HomeKit. A device's own setting overrides it": "Affiche l'interrupteur de surveillance continue dans HomeKit. Le réglage propre à un appareil l'emporte",
      "Show filter life remaining indicator. A device's own setting overrides it": "Affiche la durée de vie restante du filtre. Le réglage propre à un appareil l'emporte",
      "Show heater/thermostat control for Hot+Cool models. A device's own setting overrides it": "Affiche la commande de chauffage ou de thermostat des modèles Hot+Cool. Le réglage propre à un appareil l'emporte",
      "Show humidifier control for Humidify+Cool models. A device's own setting overrides it": "Affiche la commande de l'humidificateur des modèles Humidify+Cool. Le réglage propre à un appareil l'emporte",
      "Show humidity readings in HomeKit. A device's own setting overrides it": "Affiche l'humidité dans HomeKit. Le réglage propre à un appareil l'emporte",
      "Show jet focus (front airflow) toggle switch in HomeKit. A device's own setting overrides it": "Affiche l'interrupteur Jet Focus (flux d'air vers l'avant) dans HomeKit. Le réglage propre à un appareil l'emporte",
      "Show temperature readings in HomeKit. A device's own setting overrides it": "Affiche la température dans HomeKit. Le réglage propre à un appareil l'emporte",
      "Show temperatures in Fahrenheit in the log (HomeKit always receives Celsius)": "Affiche les températures en Fahrenheit dans le journal (HomeKit reçoit toujours des degrés Celsius)",
      "Shows the heater or thermostat control of this Hot+Cool device": "Affiche la commande de chauffage ou de thermostat de cet appareil Hot+Cool",
      "Shows the humidifier control of this Humidify+Cool device": "Affiche la commande de l'humidificateur de cet appareil Humidify+Cool",
      "Shows this device's air quality sensor in the Home app": "Affiche le capteur de qualité de l'air de cet appareil dans l'app Maison",
      "Shows this device's filter life remaining": "Affiche la durée de vie restante du filtre de cet appareil",
      "Shows this device's humidity sensor in the Home app": "Affiche le capteur d'humidité de cet appareil dans l'app Maison",
      "Shows this device's jet focus switch, on models that have one": "Affiche l'interrupteur Jet Focus de cet appareil, sur les modèles qui en ont un",
      "Shows this device's night mode switch in the Home app": "Affiche l'interrupteur du mode nuit de cet appareil dans l'app Maison",
      "Shows this device's temperature sensor in the Home app": "Affiche le capteur de température de cet appareil dans l'app Maison",
      "Singapore": "Singapour",
      "Single Accessory Mode": "Mode accessoire unique",
      "Single Sensor Accessory Mode": "Mode accessoire capteur unique",
      "Spain": "Espagne",
      "Static IP address (leave empty for auto-discovery)": "Adresse IP fixe (laissez vide pour la découverte automatique)",
      "Sweden": "Suède",
      "Switzerland": "Suisse",
      "TP02 - Pure Cool Link Tower": "TP02 - Pure Cool Link Tower",
      "TP04 - Pure Cool Tower": "TP04 - Pure Cool Tower",
      "TP07 - Purifier Cool": "TP07 - Purifier Cool",
      "TP09 - Pure Cool Formaldehyde": "TP09 - Pure Cool Formaldehyde",
      "TP11 - Purifier Cool": "TP11 - Purifier Cool",
      "Temperature Offset": "Correction de température",
      "The Dyson model. Setup fills it in from the Dyson account.": "Le modèle Dyson. Setup le renseigne depuis le compte Dyson.",
      "Thermostat (Recommended)": "Thermostat (recommandé)",
      "United Kingdom": "Royaume-Uni",
      "United States": "États-Unis",
      "Use Fahrenheit": "Utiliser les degrés Fahrenheit",
      "Which HomeKit service to use for heating control": "Le service HomeKit qui commande le chauffage",
      "Your Dyson account's country. Setup sets it when it signs in.": "Le pays de votre compte Dyson. Setup le règle quand il se connecte."
    },
    "es": {
      "Add a switch to control night mode. A device's own setting overrides it": "Añade un interruptor que controla el modo nocturno. El ajuste propio de un dispositivo tiene prioridad",
      "Additional Controls": "Controles adicionales",
      "Adjust humidity reading by this many percentage points": "Corrige la humedad leída en este número de puntos porcentuales",
      "Adjust temperature reading by this amount in Celsius": "Corrige la temperatura leída en este valor, en grados Celsius",
      "Advanced Settings": "Ajustes avanzados",
      "Australia": "Australia",
      "Austria": "Austria",
      "Automatically enable auto mode when turning device on": "Activa el modo automático cada vez que se enciende el dispositivo",
      "Automatically enable night mode when turning device on": "Activa el modo nocturno cada vez que se enciende el dispositivo",
      "Automatically enable oscillation when turning device on": "Activa la oscilación cada vez que se enciende el dispositivo",
      "BP02 - Purifier Big+Quiet": "BP02 - Purifier Big+Quiet",
      "BP03 - Purifier Big+Quiet Formaldehyde": "BP03 - Purifier Big+Quiet Formaldehyde",
      "BP04 - Purifier Big+Quiet Formaldehyde": "BP04 - Purifier Big+Quiet Formaldehyde",
      "BP06 - Purifier Big+Quiet": "BP06 - Purifier Big+Quiet",
      "Belgium": "Bélgica",
      "Both": "Ambos",
      "CF1 - Dyson Cool": "CF1 - Dyson Cool",
      "Canada": "Canadá",
      "China": "China",
      "Country Code": "Código de país",
      "DP01 - Pure Cool Link Desk": "DP01 - Pure Cool Link Desk",
      "DP04 - Pure Cool Desk": "DP04 - Pure Cool Desk",
      "Denmark": "Dinamarca",
      "Discovery Timeout": "Tiempo de descubrimiento",
      "Display Mode": "Modo de visualización",
      "Enable Air Quality Sensor": "Sensor de calidad del aire",
      "Enable Auto Mode Switch": "Interruptor del modo automático",
      "Enable Auto Mode on Activation": "Modo automático al encender",
      "Enable Continuous Monitoring Switch": "Interruptor de monitorización continua",
      "Enable Filter Status": "Estado del filtro",
      "Enable Heater (HP Models)": "Calefacción (modelos HP)",
      "Enable Humidifier (PH Models)": "Humidificador (modelos PH)",
      "Enable Humidity Sensor": "Sensor de humedad",
      "Enable Jet Focus Switch": "Interruptor Jet Focus",
      "Enable Night Mode Switch": "Interruptor del modo nocturno",
      "Enable Night Mode on Activation": "Modo nocturno al encender",
      "Enable Oscillation on Activation": "Oscilación al encender",
      "Enable Temperature Sensor": "Sensor de temperatura",
      "Finland": "Finlandia",
      "Firmware Version": "Versión del firmware",
      "Firmware version reported by the Dyson cloud, shown as the accessory's firmware in HomeKit (set by Setup)": "Versión del firmware que indica la nube de Dyson, mostrada como firmware del accesorio en HomeKit (la rellena Setup)",
      "France": "Francia",
      "Full Range Humidity": "Rango de humedad completo",
      "Germany": "Alemania",
      "HP02 - Pure Hot+Cool Link": "HP02 - Pure Hot+Cool Link",
      "HP04 - Pure Hot+Cool": "HP04 - Pure Hot+Cool",
      "HP07 - Pure Hot+Cool": "HP07 - Pure Hot+Cool",
      "HP09 - Pure Hot+Cool Formaldehyde": "HP09 - Pure Hot+Cool Formaldehyde",
      "HP1/HP11 - Purifier Hot+Cool": "HP1/HP11 - Purifier Hot+Cool",
      "Heater Cooler": "Calefactor/enfriador",
      "Heating Service Type": "Tipo de servicio de calefacción",
      "Hong Kong": "Hong Kong",
      "How often to ask each device for its state, in seconds (10 to 300)": "Cada cuánto se pide su estado a cada dispositivo, en segundos (de 10 a 300)",
      "Humidity Offset": "Corrección de humedad",
      "IP Address (Optional)": "Dirección IP (opcional)",
      "Ireland": "Irlanda",
      "Italy": "Italia",
      "Japan": "Japón",
      "Kept for compatibility with the Homebridge plugin, which never implemented it: it has no effect": "Se conserva por compatibilidad con el plugin de Homebridge, que nunca lo implementó: no tiene ningún efecto",
      "Kept for the settings page: the air purifier's Auto/Manual control is always shown, so it has no effect": "Se conserva para la página de ajustes: el control Automático/Manual del purificador de aire siempre se muestra, así que no tiene ningún efecto",
      "Let the humidifier's target humidity range from 0 to 100% (default: 30 to 70%)": "Permite ajustar la humedad objetivo del humidificador de 0 a 100 % (por omisión: de 30 a 70 %)",
      "Name": "Nombre",
      "Name of the platform in the bridge's log": "Nombre de la plataforma en el registro del puente",
      "Netherlands": "Países Bajos",
      "New Zealand": "Nueva Zelanda",
      "Norway": "Noruega",
      "PH01 - Purifier Humidify+Cool": "PH01 - Purifier Humidify+Cool",
      "PH02 - Purifier Humidify+Cool": "PH02 - Purifier Humidify+Cool",
      "PH03 - Purifier Humidify+Cool": "PH03 - Purifier Humidify+Cool",
      "PH03/PH04 - Purifier Humidify+Cool Formaldehyde": "PH03/PH04 - Purifier Humidify+Cool Formaldehyde",
      "PH04 - Purifier Humidify+Cool Formaldehyde": "PH04 - Purifier Humidify+Cool Formaldehyde",
      "PH05 - Purifier Humidify+Cool De-Nox": "PH05 - Purifier Humidify+Cool De-Nox",
      "Polling Interval": "Intervalo de consulta",
      "Product Type": "Tipo de producto",
      "Seconds to look for devices on the network over mDNS (default 10; a value over 60 is read as milliseconds)": "Segundos para buscar dispositivos en la red por mDNS (10 por defecto; un valor superior a 60 se lee en milisegundos)",
      "Sensor Options": "Opciones de sensores",
      "Show air quality sensor (PM2.5, PM10, VOC, NO2) in HomeKit. A device's own setting overrides it": "Muestra el sensor de calidad del aire (PM2.5, PM10, COV, NO2) en HomeKit. El ajuste propio de un dispositivo tiene prioridad",
      "Show continuous monitoring switch to keep sensors active when device is off": "Muestra un interruptor de monitorización continua, que mantiene los sensores activos con el dispositivo apagado",
      "Show continuous monitoring toggle switch in HomeKit. A device's own setting overrides it": "Muestra el interruptor de monitorización continua en HomeKit. El ajuste propio de un dispositivo tiene prioridad",
      "Show filter life remaining indicator. A device's own setting overrides it": "Muestra la vida restante del filtro. El ajuste propio de un dispositivo tiene prioridad",
      "Show heater/thermostat control for Hot+Cool models. A device's own setting overrides it": "Muestra el control de calefacción o termostato de los modelos Hot+Cool. El ajuste propio de un dispositivo tiene prioridad",
      "Show humidifier control for Humidify+Cool models. A device's own setting overrides it": "Muestra el control del humidificador de los modelos Humidify+Cool. El ajuste propio de un dispositivo tiene prioridad",
      "Show humidity readings in HomeKit. A device's own setting overrides it": "Muestra la humedad en HomeKit. El ajuste propio de un dispositivo tiene prioridad",
      "Show jet focus (front airflow) toggle switch in HomeKit. A device's own setting overrides it": "Muestra el interruptor Jet Focus (flujo de aire frontal) en HomeKit. El ajuste propio de un dispositivo tiene prioridad",
      "Show temperature readings in HomeKit. A device's own setting overrides it": "Muestra la temperatura en HomeKit. El ajuste propio de un dispositivo tiene prioridad",
      "Show temperatures in Fahrenheit in the log (HomeKit always receives Celsius)": "Muestra las temperaturas en Fahrenheit en el registro (HomeKit siempre recibe grados Celsius)",
      "Shows the heater or thermostat control of this Hot+Cool device": "Muestra el control de calefacción o de termostato de este dispositivo Hot+Cool",
      "Shows the humidifier control of this Humidify+Cool device": "Muestra el control del humidificador de este dispositivo Humidify+Cool",
      "Shows this device's air quality sensor in the Home app": "Muestra el sensor de calidad del aire de este dispositivo en la app Casa",
      "Shows this device's filter life remaining": "Muestra la vida restante del filtro de este dispositivo",
      "Shows this device's humidity sensor in the Home app": "Muestra el sensor de humedad de este dispositivo en la app Casa",
      "Shows this device's jet focus switch, on models that have one": "Muestra el interruptor Jet Focus de este dispositivo, en los modelos que lo tienen",
      "Shows this device's night mode switch in the Home app": "Muestra el interruptor del modo nocturno de este dispositivo en la app Casa",
      "Shows this device's temperature sensor in the Home app": "Muestra el sensor de temperatura de este dispositivo en la app Casa",
      "Singapore": "Singapur",
      "Single Accessory Mode": "Modo de accesorio único",
      "Single Sensor Accessory Mode": "Modo de accesorio de sensor único",
      "Spain": "España",
      "Static IP address (leave empty for auto-discovery)": "Dirección IP fija (déjala vacía para la detección automática)",
      "Sweden": "Suecia",
      "Switzerland": "Suiza",
      "TP02 - Pure Cool Link Tower": "TP02 - Pure Cool Link Tower",
      "TP04 - Pure Cool Tower": "TP04 - Pure Cool Tower",
      "TP07 - Purifier Cool": "TP07 - Purifier Cool",
      "TP09 - Pure Cool Formaldehyde": "TP09 - Pure Cool Formaldehyde",
      "TP11 - Purifier Cool": "TP11 - Purifier Cool",
      "Temperature Offset": "Corrección de temperatura",
      "The Dyson model. Setup fills it in from the Dyson account.": "El modelo de Dyson. Setup lo rellena desde la cuenta de Dyson.",
      "Thermostat (Recommended)": "Termostato (recomendado)",
      "United Kingdom": "Reino Unido",
      "United States": "Estados Unidos",
      "Use Fahrenheit": "Usar Fahrenheit",
      "Which HomeKit service to use for heating control": "El servicio de HomeKit que controla la calefacción",
      "Your Dyson account's country. Setup sets it when it signs in.": "El país de tu cuenta de Dyson. Setup lo ajusta al iniciar sesión."
    },
    "pt": {
      "Add a switch to control night mode. A device's own setting overrides it": "Adiciona um interruptor que controla o modo noturno. A definição própria de um dispositivo tem prioridade",
      "Additional Controls": "Controlos adicionais",
      "Adjust humidity reading by this many percentage points": "Corrige a humidade lida neste número de pontos percentuais",
      "Adjust temperature reading by this amount in Celsius": "Corrige a temperatura lida neste valor, em graus Celsius",
      "Advanced Settings": "Definições avançadas",
      "Australia": "Austrália",
      "Austria": "Áustria",
      "Automatically enable auto mode when turning device on": "Ativa o modo automático sempre que o dispositivo é ligado",
      "Automatically enable night mode when turning device on": "Ativa o modo noturno sempre que o dispositivo é ligado",
      "Automatically enable oscillation when turning device on": "Ativa a oscilação sempre que o dispositivo é ligado",
      "BP02 - Purifier Big+Quiet": "BP02 - Purifier Big+Quiet",
      "BP03 - Purifier Big+Quiet Formaldehyde": "BP03 - Purifier Big+Quiet Formaldehyde",
      "BP04 - Purifier Big+Quiet Formaldehyde": "BP04 - Purifier Big+Quiet Formaldehyde",
      "BP06 - Purifier Big+Quiet": "BP06 - Purifier Big+Quiet",
      "Belgium": "Bélgica",
      "Both": "Ambos",
      "CF1 - Dyson Cool": "CF1 - Dyson Cool",
      "Canada": "Canadá",
      "China": "China",
      "Country Code": "Código do país",
      "DP01 - Pure Cool Link Desk": "DP01 - Pure Cool Link Desk",
      "DP04 - Pure Cool Desk": "DP04 - Pure Cool Desk",
      "Denmark": "Dinamarca",
      "Discovery Timeout": "Tempo de descoberta",
      "Display Mode": "Modo de apresentação",
      "Enable Air Quality Sensor": "Sensor de qualidade do ar",
      "Enable Auto Mode Switch": "Interruptor do modo automático",
      "Enable Auto Mode on Activation": "Modo automático ao ligar",
      "Enable Continuous Monitoring Switch": "Interruptor de monitorização contínua",
      "Enable Filter Status": "Estado do filtro",
      "Enable Heater (HP Models)": "Aquecimento (modelos HP)",
      "Enable Humidifier (PH Models)": "Humidificador (modelos PH)",
      "Enable Humidity Sensor": "Sensor de humidade",
      "Enable Jet Focus Switch": "Interruptor Jet Focus",
      "Enable Night Mode Switch": "Interruptor do modo noturno",
      "Enable Night Mode on Activation": "Modo noturno ao ligar",
      "Enable Oscillation on Activation": "Oscilação ao ligar",
      "Enable Temperature Sensor": "Sensor de temperatura",
      "Finland": "Finlândia",
      "Firmware Version": "Versão do firmware",
      "Firmware version reported by the Dyson cloud, shown as the accessory's firmware in HomeKit (set by Setup)": "Versão do firmware indicada pela nuvem Dyson, mostrada como firmware do acessório no HomeKit (preenchida pelo Setup)",
      "France": "França",
      "Full Range Humidity": "Intervalo de humidade completo",
      "Germany": "Alemanha",
      "HP02 - Pure Hot+Cool Link": "HP02 - Pure Hot+Cool Link",
      "HP04 - Pure Hot+Cool": "HP04 - Pure Hot+Cool",
      "HP07 - Pure Hot+Cool": "HP07 - Pure Hot+Cool",
      "HP09 - Pure Hot+Cool Formaldehyde": "HP09 - Pure Hot+Cool Formaldehyde",
      "HP1/HP11 - Purifier Hot+Cool": "HP1/HP11 - Purifier Hot+Cool",
      "Heater Cooler": "Aquecedor/arrefecedor",
      "Heating Service Type": "Tipo de serviço de aquecimento",
      "Hong Kong": "Hong Kong",
      "How often to ask each device for its state, in seconds (10 to 300)": "Frequência com que se pede o estado a cada dispositivo, em segundos (de 10 a 300)",
      "Humidity Offset": "Correção de humidade",
      "IP Address (Optional)": "Endereço IP (opcional)",
      "Ireland": "Irlanda",
      "Italy": "Itália",
      "Japan": "Japão",
      "Kept for compatibility with the Homebridge plugin, which never implemented it: it has no effect": "Mantido por compatibilidade com o plugin Homebridge, que nunca o implementou: não tem qualquer efeito",
      "Kept for the settings page: the air purifier's Auto/Manual control is always shown, so it has no effect": "Mantido para a página de definições: o controlo Automático/Manual do purificador de ar é sempre apresentado, pelo que não tem qualquer efeito",
      "Let the humidifier's target humidity range from 0 to 100% (default: 30 to 70%)": "Permite ajustar a humidade pretendida do humidificador de 0 a 100% (por omissão: de 30 a 70%)",
      "Name": "Nome",
      "Name of the platform in the bridge's log": "Nome da plataforma no registo da ponte",
      "Netherlands": "Países Baixos",
      "New Zealand": "Nova Zelândia",
      "Norway": "Noruega",
      "PH01 - Purifier Humidify+Cool": "PH01 - Purifier Humidify+Cool",
      "PH02 - Purifier Humidify+Cool": "PH02 - Purifier Humidify+Cool",
      "PH03 - Purifier Humidify+Cool": "PH03 - Purifier Humidify+Cool",
      "PH03/PH04 - Purifier Humidify+Cool Formaldehyde": "PH03/PH04 - Purifier Humidify+Cool Formaldehyde",
      "PH04 - Purifier Humidify+Cool Formaldehyde": "PH04 - Purifier Humidify+Cool Formaldehyde",
      "PH05 - Purifier Humidify+Cool De-Nox": "PH05 - Purifier Humidify+Cool De-Nox",
      "Polling Interval": "Intervalo de consulta",
      "Product Type": "Tipo de produto",
      "Seconds to look for devices on the network over mDNS (default 10; a value over 60 is read as milliseconds)": "Segundos a procurar dispositivos na rede por mDNS (10 por predefinição; um valor acima de 60 é lido em milissegundos)",
      "Sensor Options": "Opções dos sensores",
      "Show air quality sensor (PM2.5, PM10, VOC, NO2) in HomeKit. A device's own setting overrides it": "Mostra o sensor de qualidade do ar (PM2.5, PM10, COV, NO2) no HomeKit. A definição própria de um dispositivo tem prioridade",
      "Show continuous monitoring switch to keep sensors active when device is off": "Mostra um interruptor de monitorização contínua, que mantém os sensores ativos com o dispositivo desligado",
      "Show continuous monitoring toggle switch in HomeKit. A device's own setting overrides it": "Mostra o interruptor de monitorização contínua no HomeKit. A definição própria de um dispositivo tem prioridade",
      "Show filter life remaining indicator. A device's own setting overrides it": "Mostra a vida útil restante do filtro. A definição própria de um dispositivo tem prioridade",
      "Show heater/thermostat control for Hot+Cool models. A device's own setting overrides it": "Mostra o controlo de aquecimento ou termóstato dos modelos Hot+Cool. A definição própria de um dispositivo tem prioridade",
      "Show humidifier control for Humidify+Cool models. A device's own setting overrides it": "Mostra o controlo do humidificador dos modelos Humidify+Cool. A definição própria de um dispositivo tem prioridade",
      "Show humidity readings in HomeKit. A device's own setting overrides it": "Mostra a humidade no HomeKit. A definição própria de um dispositivo tem prioridade",
      "Show jet focus (front airflow) toggle switch in HomeKit. A device's own setting overrides it": "Mostra o interruptor Jet Focus (fluxo de ar frontal) no HomeKit. A definição própria de um dispositivo tem prioridade",
      "Show temperature readings in HomeKit. A device's own setting overrides it": "Mostra a temperatura no HomeKit. A definição própria de um dispositivo tem prioridade",
      "Show temperatures in Fahrenheit in the log (HomeKit always receives Celsius)": "Mostra as temperaturas em Fahrenheit no registo (o HomeKit recebe sempre graus Celsius)",
      "Shows the heater or thermostat control of this Hot+Cool device": "Mostra o controlo de aquecimento ou de termóstato deste dispositivo Hot+Cool",
      "Shows the humidifier control of this Humidify+Cool device": "Mostra o controlo do humidificador deste dispositivo Humidify+Cool",
      "Shows this device's air quality sensor in the Home app": "Mostra o sensor de qualidade do ar deste dispositivo na app Casa",
      "Shows this device's filter life remaining": "Mostra a vida restante do filtro deste dispositivo",
      "Shows this device's humidity sensor in the Home app": "Mostra o sensor de humidade deste dispositivo na app Casa",
      "Shows this device's jet focus switch, on models that have one": "Mostra o interruptor Jet Focus deste dispositivo, nos modelos que o têm",
      "Shows this device's night mode switch in the Home app": "Mostra o interruptor do modo noturno deste dispositivo na app Casa",
      "Shows this device's temperature sensor in the Home app": "Mostra o sensor de temperatura deste dispositivo na app Casa",
      "Singapore": "Singapura",
      "Single Accessory Mode": "Modo de acessório único",
      "Single Sensor Accessory Mode": "Modo de acessório de sensor único",
      "Spain": "Espanha",
      "Static IP address (leave empty for auto-discovery)": "Endereço IP fixo (deixar vazio para a deteção automática)",
      "Sweden": "Suécia",
      "Switzerland": "Suíça",
      "TP02 - Pure Cool Link Tower": "TP02 - Pure Cool Link Tower",
      "TP04 - Pure Cool Tower": "TP04 - Pure Cool Tower",
      "TP07 - Purifier Cool": "TP07 - Purifier Cool",
      "TP09 - Pure Cool Formaldehyde": "TP09 - Pure Cool Formaldehyde",
      "TP11 - Purifier Cool": "TP11 - Purifier Cool",
      "Temperature Offset": "Correção de temperatura",
      "The Dyson model. Setup fills it in from the Dyson account.": "O modelo Dyson. O Setup preenche-o a partir da conta Dyson.",
      "Thermostat (Recommended)": "Termóstato (recomendado)",
      "United Kingdom": "Reino Unido",
      "United States": "Estados Unidos",
      "Use Fahrenheit": "Usar Fahrenheit",
      "Which HomeKit service to use for heating control": "O serviço HomeKit que controla o aquecimento",
      "Your Dyson account's country. Setup sets it when it signs in.": "O país da sua conta Dyson. O Setup define-o quando inicia sessão."
    }
  }
}
"""#
}
