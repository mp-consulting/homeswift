// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension LGThinQPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "LGThinQ",
  "pluginType": "platform",
  "singular": true,
  "customUi": true,
  "strictValidation": false,
  "schema": {
    "name": {
      "title": "Name",
      "description": "The name of this platform in the log.",
      "type": "string",
      "required": true,
      "default": "LG ThinQ"
    },
    "auth_mode": {
      "title": "Auth Mode",
      "description": "How the plugin signs in: with the LG account's email and password, or with a refresh token. A refresh token, when there is one, is used first.",
      "type": "string",
      "default": "account",
      "oneOf": [
        {
          "title": "LG Account",
          "enum": [
            "account"
          ]
        },
        {
          "title": "Token",
          "enum": [
            "token"
          ]
        }
      ]
    },
    "username": {
      "title": "Username",
      "description": "The LG account's email, when signing in with the account.",
      "type": "string",
      "condition": {
        "functionBody": "return model.auth_mode === 'account';"
      }
    },
    "password": {
      "title": "Password",
      "description": "The LG account's password, when signing in with the account.",
      "type": "string",
      "condition": {
        "functionBody": "return model.auth_mode === 'account';"
      }
    },
    "refresh_token": {
      "title": "Refresh Token",
      "description": "The LG account's refresh token. The plugin's page gets one when you sign in there.",
      "type": "string",
      "condition": {
        "functionBody": "return model.auth_mode === 'token';"
      }
    },
    "country": {
      "title": "Country",
      "description": "The account's country, as a two-letter code such as US or FR.",
      "type": "string",
      "default": "US",
      "required": true
    },
    "language": {
      "title": "Language",
      "description": "The account's language, as a language tag such as en-US or fr-FR.",
      "type": "string",
      "default": "en-US",
      "required": true
    },
    "thinq1": {
      "title": "Enable ThinQ1 Support?",
      "description": "Also adds the account's older ThinQ1 devices, which are polled.",
      "type": "boolean",
      "default": false
    },
    "refresh_interval": {
      "title": "Refresh interval (in second)",
      "description": "Seconds between polls of ThinQ1 devices.",
      "type": "number",
      "default": 60,
      "condition": {
        "functionBody": "return !!model.thinq1;"
      }
    },
    "devices": {
      "title": "Devices",
      "description": "The devices to add, each by its ID. Leave it empty to add every device of the account.",
      "type": "array",
      "items": {
        "type": "object",
        "title": "Device",
        "properties": {
          "id": {
            "title": "Device ID",
            "description": "The device's ID in the LG account.",
            "type": "string",
            "required": true
          },
          "name": {
            "title": "Device Name",
            "description": "A name to recognise the device. Dishwashers, ovens and microwaves also take it as their accessory's name.",
            "type": "string"
          },
          "type": {
            "title": "Device Type",
            "description": "The kind of appliance, as LG reports it. The plugin's page fills it in.",
            "type": "string",
            "oneOf": [
              {
                "title": "Air conditioner",
                "enum": [
                  "AC"
                ]
              },
              {
                "title": "Washer",
                "enum": [
                  "WASHER"
                ]
              },
              {
                "title": "Washer (newer models)",
                "enum": [
                  "WASHER_NEW"
                ]
              },
              {
                "title": "WashTower",
                "enum": [
                  "WASH_TOWER"
                ]
              },
              {
                "title": "Dryer",
                "enum": [
                  "DRYER"
                ]
              },
              {
                "title": "Refrigerator",
                "enum": [
                  "REFRIGERATOR"
                ]
              },
              {
                "title": "Dishwasher",
                "enum": [
                  "DISHWASHER"
                ]
              },
              {
                "title": "Air purifier",
                "enum": [
                  "AIR_PURIFIER"
                ]
              },
              {
                "title": "Dehumidifier",
                "enum": [
                  "DEHUMIDIFIER"
                ]
              },
              {
                "title": "AeroTower",
                "enum": [
                  "AERO_TOWER"
                ]
              },
              {
                "title": "Oven",
                "enum": [
                  "OVEN"
                ]
              },
              {
                "title": "Range",
                "enum": [
                  "RANGE"
                ]
              },
              {
                "title": "Cooktop",
                "enum": [
                  "COOKTOP"
                ]
              }
            ],
            "condition": {
              "functionBody": "return false;"
            }
          },
          "serial_number": {
            "title": "Serial Number (optional)",
            "description": "The serial number shown in the Home app. Empty uses the one LG reports.",
            "type": "string"
          },
          "dishwasher_trigger": {
            "title": "Enable program finished trigger?",
            "description": "Adds a Program Finished occupancy sensor that turns on when a program ends.",
            "type": "boolean"
          },
          "washer_tub_clean": {
            "title": "Enable Tub Clean Event",
            "description": "Adds a Tub Clean Coach sensor that turns on from 30 cycles, when the tub needs cleaning.",
            "type": "boolean"
          },
          "washer_trigger": {
            "title": "Enable program finished trigger?",
            "description": "Adds a Program Finished occupancy sensor that stays on for ten minutes when a program ends.",
            "type": "boolean"
          },
          "washer_door_lock": {
            "title": "Enable door lock status",
            "description": "Shows the door lock as a lock in the Home app, on ThinQ2 washers and dryers.",
            "type": "boolean"
          },
          "ac_air_quality": {
            "title": "Enable Air Quality",
            "description": "Adds an air quality sensor, on units that have one.",
            "type": "boolean"
          },
          "ac_mode": {
            "title": "AC Mode (Heating or Cooling or Both)",
            "description": "The modes the Home app offers: heating, cooling or both.",
            "type": "string",
            "oneOf": [
              {
                "title": "Both Heating and Cooling mode",
                "enum": [
                  "BOTH"
                ]
              },
              {
                "title": "Cooling mode only",
                "enum": [
                  "COOLING"
                ]
              },
              {
                "title": "Heating mode only",
                "enum": [
                  "HEATING"
                ]
              }
            ]
          },
          "ac_swing_mode": {
            "title": "Swing Mode (vertical or horizontal)",
            "description": "The axes swing turns on and off: vertical, horizontal or both.",
            "type": "string",
            "oneOf": [
              {
                "title": "Both vertical and horizontal swing",
                "enum": [
                  "BOTH"
                ]
              },
              {
                "title": "Vertical swing only",
                "enum": [
                  "VERTICAL"
                ]
              },
              {
                "title": "Horizontal swing only",
                "enum": [
                  "HORIZONTAL"
                ]
              }
            ]
          },
          "ac_temperature_sensor": {
            "title": "Current temperature as sensor",
            "description": "Adds the current temperature as a separate sensor.",
            "type": "boolean"
          },
          "ac_humidity_sensor": {
            "title": "Enable humidity sensor",
            "description": "Adds the current humidity as a separate sensor.",
            "type": "boolean"
          },
          "ac_led_control": {
            "title": "Enable led panel control",
            "description": "Shows the unit's display light as a light in the Home app.",
            "type": "boolean"
          },
          "ac_fan_control": {
            "title": "Enable separate fan control",
            "description": "Adds a separate fan with automatic and manual speed and swing.",
            "type": "boolean"
          },
          "ac_jet_control": {
            "title": "Enable separate jet control",
            "description": "Adds a Jet Mode switch, on models that have it.",
            "type": "boolean"
          },
          "ac_buttons": {
            "title": "Customize AC buttons",
            "description": "Switches that each select one of the unit's operation modes, by LG's mode number (op_mode).",
            "type": "array",
            "items": {
              "type": "object",
              "title": "Button",
              "properties": {
                "name": {
                  "title": "Name",
                  "description": "The switch's name in the Home app.",
                  "type": "string"
                },
                "op_mode": {
                  "title": "Operation mode",
                  "description": "LG's number for the operation mode the switch selects; the switch is on while the unit is in that mode.",
                  "type": "integer"
                }
              }
            }
          },
          "ac_energy_save": {
            "title": "Energy save as switch",
            "description": "Adds an energy saving switch, on models that have it.",
            "type": "boolean",
            "default": true
          },
          "ac_air_clean": {
            "title": "Air purify as switch",
            "description": "Adds an air purifying switch, on models that have it.",
            "type": "boolean",
            "default": true
          },
          "ac_temperature_unit": {
            "title": "Temperature Unit",
            "description": "The air conditioner's temperature scale. In Fahrenheit, temperatures follow its own Fahrenheit table.",
            "type": "string",
            "oneOf": [
              {
                "title": "Celsius",
                "enum": [
                  "C"
                ]
              },
              {
                "title": "Fahrenheit",
                "enum": [
                  "F"
                ]
              }
            ]
          },
          "ref_express_freezer": {
            "title": "Express Freezer / Ice Plus",
            "description": "Adds an Express Freezer (Ice Plus) switch, on models that have it.",
            "type": "boolean"
          },
          "ref_express_fridge": {
            "title": "Express Fridge",
            "description": "Adds an Express Fridge switch, on models that have it.",
            "type": "boolean"
          },
          "ref_eco_friendly": {
            "title": "Eco Friendly",
            "description": "Adds an Eco Friendly switch, on models that have it.",
            "type": "boolean"
          },
          "air_fast_mode": {
            "title": "Air Fast Mode",
            "description": "Adds an Air Fast switch.",
            "type": "boolean"
          }
        }
      }
    }
  },
  "layout": [
    "name",
    "auth_mode",
    {
      "type": "flex",
      "flex-flow": "row wrap",
      "items": [
        "username",
        {
          "key": "password",
          "type": "password"
        }
      ]
    },
    "refresh_token",
    {
      "type": "flex",
      "flex-flow": "row wrap",
      "items": [
        "country",
        "language"
      ]
    },
    "thinq1",
    "refresh_interval",
    {
      "key": "devices",
      "type": "tabarray",
      "title": "{{ value.name || 'new device' }}",
      "items": [
        "devices[].name",
        "devices[].id",
        "devices[].type",
        "devices[].serial_number",
        {
          "key": "devices[]",
          "type": "fieldset",
          "title": "{{ value.title }}",
          "items": [
            {
              "type": "fieldset",
              "title": "Air purifier specific settings",
              "description": "Configure air purifier device settings.",
              "expandable": true,
              "expanded": false,
              "items": [
                "devices[].air_fast_mode"
              ],
              "condition": {
                "functionBody": "return model.devices && model.devices[arrayIndices] && ['AIR_PURIFIER', 'AERO_TOWER'].includes(model.devices[arrayIndices].type);"
              }
            },
            {
              "type": "fieldset",
              "title": "Washer / Dryer specific settings",
              "description": "Configure washer/dryer device settings.",
              "expandable": true,
              "expanded": false,
              "items": [
                "devices[].washer_trigger",
                "devices[].washer_tub_clean",
                "devices[].washer_door_lock"
              ],
              "condition": {
                "functionBody": "return model.devices && model.devices[arrayIndices] && ['WASHER','WASHER_NEW', 'WASH_TOWER', 'DRYER', 'WASH_TOWER_2'].includes(model.devices[arrayIndices].type);"
              }
            },
            {
              "type": "fieldset",
              "title": "Air conditioner specific settings",
              "description": "Configure AC device settings.",
              "expandable": true,
              "expanded": false,
              "items": [
                "devices[].ac_air_quality",
                "devices[].ac_mode",
                "devices[].ac_swing_mode",
                "devices[].ac_temperature_sensor",
                "devices[].ac_humidity_sensor",
                "devices[].ac_fan_control",
                "devices[].ac_jet_control",
                "devices[].ac_energy_save",
                "devices[].ac_air_clean",
                "devices[].ac_temperature_unit",
                {
                  "key": "devices[].ac_buttons",
                  "title": "AC buttons",
                  "description": "Configure AC buttons. For details check README.",
                  "type": "array",
                  "buttonText": "Add button",
                  "items": [
                    "devices[].ac_buttons[].name",
                    "devices[].ac_buttons[].op_mode"
                  ]
                }
              ],
              "condition": {
                "functionBody": "return model.devices && model.devices[arrayIndices] && ['AC'].includes(model.devices[arrayIndices].type);"
              }
            },
            {
              "type": "fieldset",
              "title": "Refrigerator specific settings",
              "description": "Configure refrigerator device settings.",
              "expandable": true,
              "expanded": false,
              "items": [
                "devices[].ref_express_freezer",
                "devices[].ref_express_fridge",
                "devices[].ref_eco_friendly"
              ],
              "condition": {
                "functionBody": "return model.devices && model.devices[arrayIndices] && ['REFRIGERATOR'].includes(model.devices[arrayIndices].type);"
              }
            },
            {
              "type": "fieldset",
              "title": "Dishwasher specific settings",
              "description": "Configure dishwasher device settings.",
              "expandable": true,
              "expanded": false,
              "items": [
                "devices[].dishwasher_trigger"
              ],
              "condition": {
                "functionBody": "return model.devices && model.devices[arrayIndices] && ['DISHWASHER'].includes(model.devices[arrayIndices].type);"
              }
            }
          ]
        }
      ]
    }
  ],
  "i18n": {
    "fr": {
      "A name to recognise the device. Dishwashers, ovens and microwaves also take it as their accessory's name.": "Un nom pour reconnaître l'appareil. Les lave-vaisselle, fours et micro-ondes le prennent aussi comme nom d'accessoire.",
      "AC Mode (Heating or Cooling or Both)": "Mode du climatiseur (chauffage, refroidissement ou les deux)",
      "AC buttons": "Boutons du climatiseur",
      "Adds a Jet Mode switch, on models that have it.": "Ajoute un interrupteur Jet Mode, sur les modèles qui l'ont.",
      "Adds a Program Finished occupancy sensor that stays on for ten minutes when a program ends.": "Ajoute un capteur de présence Programme terminé qui reste actif dix minutes à la fin d'un programme.",
      "Adds a Program Finished occupancy sensor that turns on when a program ends.": "Ajoute un capteur de présence Programme terminé qui s'active à la fin d'un programme.",
      "Adds a Tub Clean Coach sensor that turns on from 30 cycles, when the tub needs cleaning.": "Ajoute un capteur Tub Clean Coach qui s'active à partir de 30 cycles, quand la cuve doit être nettoyée.",
      "Adds a separate fan with automatic and manual speed and swing.": "Ajoute un ventilateur distinct avec vitesse automatique ou manuelle et oscillation.",
      "Adds an Air Fast switch.": "Ajoute un interrupteur Air Fast.",
      "Adds an Eco Friendly switch, on models that have it.": "Ajoute un interrupteur Mode éco, sur les modèles qui l'ont.",
      "Adds an Express Freezer (Ice Plus) switch, on models that have it.": "Ajoute un interrupteur Congélation express (Ice Plus), sur les modèles qui l'ont.",
      "Adds an Express Fridge switch, on models that have it.": "Ajoute un interrupteur Réfrigération express, sur les modèles qui l'ont.",
      "Adds an air purifying switch, on models that have it.": "Ajoute un interrupteur de purification de l'air, sur les modèles qui l'ont.",
      "Adds an air quality sensor, on units that have one.": "Ajoute un capteur de qualité de l'air, sur les appareils qui en ont un.",
      "Adds an energy saving switch, on models that have it.": "Ajoute un interrupteur d'économie d'énergie, sur les modèles qui l'ont.",
      "Adds the current humidity as a separate sensor.": "Ajoute l'humidité actuelle comme capteur distinct.",
      "Adds the current temperature as a separate sensor.": "Ajoute la température actuelle comme capteur distinct.",
      "AeroTower": "AeroTower",
      "Air Fast Mode": "Mode Air Fast",
      "Air conditioner": "Climatiseur",
      "Air conditioner specific settings": "Réglages du climatiseur",
      "Air purifier": "Purificateur d'air",
      "Air purifier specific settings": "Réglages du purificateur d'air",
      "Air purify as switch": "Purification de l'air comme interrupteur",
      "Also adds the account's older ThinQ1 devices, which are polled.": "Ajoute aussi les anciens appareils ThinQ1 du compte, qui sont interrogés régulièrement.",
      "Auth Mode": "Mode d'authentification",
      "Both Heating and Cooling mode": "Chauffage et refroidissement",
      "Both vertical and horizontal swing": "Oscillation verticale et horizontale",
      "Button": "Bouton",
      "Celsius": "Celsius",
      "Cooktop": "Plaque de cuisson",
      "Cooling mode only": "Refroidissement uniquement",
      "Country": "Pays",
      "Current temperature as sensor": "Température actuelle comme capteur",
      "Customize AC buttons": "Personnaliser les boutons du climatiseur",
      "Dehumidifier": "Déshumidificateur",
      "Device": "Appareil",
      "Device ID": "Identifiant de l'appareil",
      "Device Name": "Nom de l'appareil",
      "Device Type": "Type d'appareil",
      "Devices": "Appareils",
      "Dishwasher": "Lave-vaisselle",
      "Dishwasher specific settings": "Réglages du lave-vaisselle",
      "Dryer": "Sèche-linge",
      "Eco Friendly": "Mode éco",
      "Enable Air Quality": "Activer la qualité de l'air",
      "Enable ThinQ1 Support?": "Activer la prise en charge de ThinQ1 ?",
      "Enable Tub Clean Event": "Activer l'alerte de nettoyage de la cuve",
      "Enable door lock status": "Activer l'état du verrouillage de la porte",
      "Enable humidity sensor": "Activer le capteur d'humidité",
      "Enable led panel control": "Activer la commande du panneau LED",
      "Enable program finished trigger?": "Activer le déclencheur de fin de programme ?",
      "Enable separate fan control": "Activer la commande séparée du ventilateur",
      "Enable separate jet control": "Activer la commande séparée du mode Jet",
      "Energy save as switch": "Économie d'énergie comme interrupteur",
      "Express Freezer / Ice Plus": "Congélation express / Ice Plus",
      "Express Fridge": "Réfrigération express",
      "Fahrenheit": "Fahrenheit",
      "Heating mode only": "Chauffage uniquement",
      "Horizontal swing only": "Oscillation horizontale uniquement",
      "How the plugin signs in: with the LG account's email and password, or with a refresh token. A refresh token, when there is one, is used first.": "Comment le plugin se connecte : avec l'adresse e-mail et le mot de passe du compte LG, ou avec un jeton d'actualisation. Un jeton d'actualisation, s'il y en a un, passe en premier.",
      "LG Account": "Compte LG",
      "LG's number for the operation mode the switch selects; the switch is on while the unit is in that mode.": "Le numéro LG du mode de fonctionnement que l'interrupteur choisit ; l'interrupteur est activé tant que l'appareil est dans ce mode.",
      "Language": "Langue",
      "Name": "Nom",
      "Operation mode": "Mode de fonctionnement",
      "Oven": "Four",
      "Password": "Mot de passe",
      "Range": "Cuisinière",
      "Refresh Token": "Jeton d'actualisation",
      "Refresh interval (in second)": "Intervalle d'actualisation (en secondes)",
      "Refrigerator": "Réfrigérateur",
      "Refrigerator specific settings": "Réglages du réfrigérateur",
      "Seconds between polls of ThinQ1 devices.": "Secondes entre deux interrogations des appareils ThinQ1.",
      "Serial Number (optional)": "Numéro de série (facultatif)",
      "Shows the door lock as a lock in the Home app, on ThinQ2 washers and dryers.": "Affiche le verrouillage de la porte comme une serrure dans l'app Maison, sur les lave-linge et sèche-linge ThinQ2.",
      "Shows the unit's display light as a light in the Home app.": "Affiche l'éclairage de l'écran de l'appareil comme une lampe dans l'app Maison.",
      "Swing Mode (vertical or horizontal)": "Oscillation (verticale ou horizontale)",
      "Switches that each select one of the unit's operation modes, by LG's mode number (op_mode).": "Des interrupteurs qui choisissent chacun un mode de fonctionnement de l'appareil, par le numéro de mode de LG (op_mode).",
      "Temperature Unit": "Unité de température",
      "The LG account's email, when signing in with the account.": "L'adresse e-mail du compte LG, pour se connecter avec le compte.",
      "The LG account's password, when signing in with the account.": "Le mot de passe du compte LG, pour se connecter avec le compte.",
      "The LG account's refresh token. The plugin's page gets one when you sign in there.": "Le jeton d'actualisation du compte LG. La page du plugin en obtient un quand vous vous y connectez.",
      "The account's country, as a two-letter code such as US or FR.": "Le pays du compte, en code à deux lettres comme US ou FR.",
      "The account's language, as a language tag such as en-US or fr-FR.": "La langue du compte, en balise de langue comme en-US ou fr-FR.",
      "The air conditioner's temperature scale. In Fahrenheit, temperatures follow its own Fahrenheit table.": "L'échelle de température du climatiseur. En Fahrenheit, les températures suivent sa propre table Fahrenheit.",
      "The axes swing turns on and off: vertical, horizontal or both.": "Les axes sur lesquels l'oscillation s'active et se désactive : vertical, horizontal ou les deux.",
      "The device's ID in the LG account.": "L'identifiant de l'appareil dans le compte LG.",
      "The devices to add, each by its ID. Leave it empty to add every device of the account.": "Les appareils à ajouter, chacun par son identifiant. Laissez vide pour ajouter tous les appareils du compte.",
      "The kind of appliance, as LG reports it. The plugin's page fills it in.": "Le type d'appareil, tel que LG l'indique. La page du plugin le remplit.",
      "The modes the Home app offers: heating, cooling or both.": "Les modes que propose l'app Maison : chauffage, refroidissement ou les deux.",
      "The name of this platform in the log.": "Le nom de cette plateforme dans le journal.",
      "The serial number shown in the Home app. Empty uses the one LG reports.": "Le numéro de série affiché dans l'app Maison. Vide, celui que LG indique est utilisé.",
      "The switch's name in the Home app.": "Le nom de l'interrupteur dans l'app Maison.",
      "Token": "Jeton",
      "Username": "Nom d'utilisateur",
      "Vertical swing only": "Oscillation verticale uniquement",
      "WashTower": "WashTower",
      "Washer": "Lave-linge",
      "Washer (newer models)": "Lave-linge (modèles récents)",
      "Washer / Dryer specific settings": "Réglages du lave-linge / sèche-linge",
      "{{ value.name || 'new device' }}": "{{ value.name || 'nouvel appareil' }}",
      "{{ value.title }}": "{{ value.title }}"
    },
    "es": {
      "A name to recognise the device. Dishwashers, ovens and microwaves also take it as their accessory's name.": "Un nombre para reconocer el dispositivo. Los lavavajillas, hornos y microondas también lo usan como nombre de su accesorio.",
      "AC Mode (Heating or Cooling or Both)": "Modo del aire acondicionado (calefacción, refrigeración o ambos)",
      "AC buttons": "Botones del aire acondicionado",
      "Adds a Jet Mode switch, on models that have it.": "Añade un interruptor Jet Mode, en los modelos que lo tienen.",
      "Adds a Program Finished occupancy sensor that stays on for ten minutes when a program ends.": "Añade un sensor de presencia Programa terminado que se queda activo diez minutos al acabar un programa.",
      "Adds a Program Finished occupancy sensor that turns on when a program ends.": "Añade un sensor de presencia Programa terminado que se activa al acabar un programa.",
      "Adds a Tub Clean Coach sensor that turns on from 30 cycles, when the tub needs cleaning.": "Añade un sensor Tub Clean Coach que se activa a partir de 30 ciclos, cuando el tambor necesita limpieza.",
      "Adds a separate fan with automatic and manual speed and swing.": "Añade un ventilador aparte con velocidad automática o manual y oscilación.",
      "Adds an Air Fast switch.": "Añade un interruptor Air Fast.",
      "Adds an Eco Friendly switch, on models that have it.": "Añade un interruptor de modo eco, en los modelos que lo tienen.",
      "Adds an Express Freezer (Ice Plus) switch, on models that have it.": "Añade un interruptor de congelación exprés (Ice Plus), en los modelos que lo tienen.",
      "Adds an Express Fridge switch, on models that have it.": "Añade un interruptor de refrigeración exprés, en los modelos que lo tienen.",
      "Adds an air purifying switch, on models that have it.": "Añade un interruptor de purificación del aire, en los modelos que lo tienen.",
      "Adds an air quality sensor, on units that have one.": "Añade un sensor de calidad del aire, en los equipos que lo tienen.",
      "Adds an energy saving switch, on models that have it.": "Añade un interruptor de ahorro de energía, en los modelos que lo tienen.",
      "Adds the current humidity as a separate sensor.": "Añade la humedad actual como un sensor aparte.",
      "Adds the current temperature as a separate sensor.": "Añade la temperatura actual como un sensor aparte.",
      "AeroTower": "AeroTower",
      "Air Fast Mode": "Modo Air Fast",
      "Air conditioner": "Aire acondicionado",
      "Air conditioner specific settings": "Ajustes del aire acondicionado",
      "Air purifier": "Purificador de aire",
      "Air purifier specific settings": "Ajustes del purificador de aire",
      "Air purify as switch": "Purificación del aire como interruptor",
      "Also adds the account's older ThinQ1 devices, which are polled.": "Añade también los dispositivos ThinQ1 antiguos de la cuenta, que se consultan periódicamente.",
      "Auth Mode": "Modo de autenticación",
      "Both Heating and Cooling mode": "Calefacción y refrigeración",
      "Both vertical and horizontal swing": "Oscilación vertical y horizontal",
      "Button": "Botón",
      "Celsius": "Celsius",
      "Cooktop": "Placa de cocción",
      "Cooling mode only": "Solo refrigeración",
      "Country": "País",
      "Current temperature as sensor": "Temperatura actual como sensor",
      "Customize AC buttons": "Personalizar los botones del aire acondicionado",
      "Dehumidifier": "Deshumidificador",
      "Device": "Dispositivo",
      "Device ID": "ID del dispositivo",
      "Device Name": "Nombre del dispositivo",
      "Device Type": "Tipo de dispositivo",
      "Devices": "Dispositivos",
      "Dishwasher": "Lavavajillas",
      "Dishwasher specific settings": "Ajustes del lavavajillas",
      "Dryer": "Secadora",
      "Eco Friendly": "Modo eco",
      "Enable Air Quality": "Activar la calidad del aire",
      "Enable ThinQ1 Support?": "¿Activar la compatibilidad con ThinQ1?",
      "Enable Tub Clean Event": "Activar el aviso de limpieza del tambor",
      "Enable door lock status": "Activar el estado del bloqueo de la puerta",
      "Enable humidity sensor": "Activar el sensor de humedad",
      "Enable led panel control": "Activar el control del panel LED",
      "Enable program finished trigger?": "¿Activar el aviso de programa terminado?",
      "Enable separate fan control": "Activar el control aparte del ventilador",
      "Enable separate jet control": "Activar el control aparte del modo Jet",
      "Energy save as switch": "Ahorro de energía como interruptor",
      "Express Freezer / Ice Plus": "Congelación exprés / Ice Plus",
      "Express Fridge": "Refrigeración exprés",
      "Fahrenheit": "Fahrenheit",
      "Heating mode only": "Solo calefacción",
      "Horizontal swing only": "Solo oscilación horizontal",
      "How the plugin signs in: with the LG account's email and password, or with a refresh token. A refresh token, when there is one, is used first.": "Cómo inicia sesión el plugin: con el correo y la contraseña de la cuenta LG, o con un token de actualización. Si hay un token de actualización, se usa primero.",
      "LG Account": "Cuenta LG",
      "LG's number for the operation mode the switch selects; the switch is on while the unit is in that mode.": "El número de LG del modo de funcionamiento que elige el interruptor; el interruptor está activado mientras el equipo está en ese modo.",
      "Language": "Idioma",
      "Name": "Nombre",
      "Operation mode": "Modo de funcionamiento",
      "Oven": "Horno",
      "Password": "Contraseña",
      "Range": "Cocina",
      "Refresh Token": "Token de actualización",
      "Refresh interval (in second)": "Intervalo de actualización (en segundos)",
      "Refrigerator": "Frigorífico",
      "Refrigerator specific settings": "Ajustes del frigorífico",
      "Seconds between polls of ThinQ1 devices.": "Segundos entre consultas a los dispositivos ThinQ1.",
      "Serial Number (optional)": "Número de serie (opcional)",
      "Shows the door lock as a lock in the Home app, on ThinQ2 washers and dryers.": "Muestra el bloqueo de la puerta como una cerradura en la app Casa, en lavadoras y secadoras ThinQ2.",
      "Shows the unit's display light as a light in the Home app.": "Muestra la luz de la pantalla del equipo como una luz en la app Casa.",
      "Swing Mode (vertical or horizontal)": "Oscilación (vertical u horizontal)",
      "Switches that each select one of the unit's operation modes, by LG's mode number (op_mode).": "Interruptores que eligen cada uno un modo de funcionamiento del equipo, por el número de modo de LG (op_mode).",
      "Temperature Unit": "Unidad de temperatura",
      "The LG account's email, when signing in with the account.": "El correo de la cuenta LG, para iniciar sesión con la cuenta.",
      "The LG account's password, when signing in with the account.": "La contraseña de la cuenta LG, para iniciar sesión con la cuenta.",
      "The LG account's refresh token. The plugin's page gets one when you sign in there.": "El token de actualización de la cuenta LG. La página del plugin obtiene uno cuando inicias sesión en ella.",
      "The account's country, as a two-letter code such as US or FR.": "El país de la cuenta, como código de dos letras, por ejemplo US o FR.",
      "The account's language, as a language tag such as en-US or fr-FR.": "El idioma de la cuenta, como etiqueta de idioma, por ejemplo en-US o fr-FR.",
      "The air conditioner's temperature scale. In Fahrenheit, temperatures follow its own Fahrenheit table.": "La escala de temperatura del aire acondicionado. En Fahrenheit, las temperaturas siguen su propia tabla Fahrenheit.",
      "The axes swing turns on and off: vertical, horizontal or both.": "Los ejes en los que se activa y desactiva la oscilación: vertical, horizontal o ambos.",
      "The device's ID in the LG account.": "El ID del dispositivo en la cuenta LG.",
      "The devices to add, each by its ID. Leave it empty to add every device of the account.": "Los dispositivos que añadir, cada uno por su ID. Déjalo vacío para añadir todos los dispositivos de la cuenta.",
      "The kind of appliance, as LG reports it. The plugin's page fills it in.": "El tipo de aparato, tal como lo indica LG. La página del plugin lo rellena.",
      "The modes the Home app offers: heating, cooling or both.": "Los modos que ofrece la app Casa: calefacción, refrigeración o ambos.",
      "The name of this platform in the log.": "El nombre de esta plataforma en el registro.",
      "The serial number shown in the Home app. Empty uses the one LG reports.": "El número de serie que muestra la app Casa. Vacío, se usa el que indica LG.",
      "The switch's name in the Home app.": "El nombre del interruptor en la app Casa.",
      "Token": "Token",
      "Username": "Nombre de usuario",
      "Vertical swing only": "Solo oscilación vertical",
      "WashTower": "WashTower",
      "Washer": "Lavadora",
      "Washer (newer models)": "Lavadora (modelos recientes)",
      "Washer / Dryer specific settings": "Ajustes de la lavadora / secadora",
      "{{ value.name || 'new device' }}": "{{ value.name || 'nuevo dispositivo' }}",
      "{{ value.title }}": "{{ value.title }}"
    },
    "pt": {
      "A name to recognise the device. Dishwashers, ovens and microwaves also take it as their accessory's name.": "Um nome para reconhecer o dispositivo. As máquinas de lavar loiça, os fornos e os micro-ondas também o usam como nome do acessório.",
      "AC Mode (Heating or Cooling or Both)": "Modo do ar condicionado (aquecimento, arrefecimento ou ambos)",
      "AC buttons": "Botões do ar condicionado",
      "Adds a Jet Mode switch, on models that have it.": "Adiciona um interruptor Jet Mode, nos modelos que o têm.",
      "Adds a Program Finished occupancy sensor that stays on for ten minutes when a program ends.": "Adiciona um sensor de ocupação Programa terminado que fica ativo dez minutos quando um programa termina.",
      "Adds a Program Finished occupancy sensor that turns on when a program ends.": "Adiciona um sensor de ocupação Programa terminado que se ativa quando um programa termina.",
      "Adds a Tub Clean Coach sensor that turns on from 30 cycles, when the tub needs cleaning.": "Adiciona um sensor Tub Clean Coach que se ativa a partir de 30 ciclos, quando o tambor precisa de limpeza.",
      "Adds a separate fan with automatic and manual speed and swing.": "Adiciona uma ventoinha à parte com velocidade automática ou manual e oscilação.",
      "Adds an Air Fast switch.": "Adiciona um interruptor Air Fast.",
      "Adds an Eco Friendly switch, on models that have it.": "Adiciona um interruptor de modo eco, nos modelos que o têm.",
      "Adds an Express Freezer (Ice Plus) switch, on models that have it.": "Adiciona um interruptor de congelação rápida (Ice Plus), nos modelos que o têm.",
      "Adds an Express Fridge switch, on models that have it.": "Adiciona um interruptor de refrigeração rápida, nos modelos que o têm.",
      "Adds an air purifying switch, on models that have it.": "Adiciona um interruptor de purificação do ar, nos modelos que o têm.",
      "Adds an air quality sensor, on units that have one.": "Adiciona um sensor de qualidade do ar, nas unidades que o têm.",
      "Adds an energy saving switch, on models that have it.": "Adiciona um interruptor de poupança de energia, nos modelos que o têm.",
      "Adds the current humidity as a separate sensor.": "Adiciona a humidade atual como um sensor à parte.",
      "Adds the current temperature as a separate sensor.": "Adiciona a temperatura atual como um sensor à parte.",
      "AeroTower": "AeroTower",
      "Air Fast Mode": "Modo Air Fast",
      "Air conditioner": "Ar condicionado",
      "Air conditioner specific settings": "Definições do ar condicionado",
      "Air purifier": "Purificador de ar",
      "Air purifier specific settings": "Definições do purificador de ar",
      "Air purify as switch": "Purificação do ar como interruptor",
      "Also adds the account's older ThinQ1 devices, which are polled.": "Adiciona também os dispositivos ThinQ1 antigos da conta, que são consultados periodicamente.",
      "Auth Mode": "Modo de autenticação",
      "Both Heating and Cooling mode": "Aquecimento e arrefecimento",
      "Both vertical and horizontal swing": "Oscilação vertical e horizontal",
      "Button": "Botão",
      "Celsius": "Celsius",
      "Cooktop": "Placa de cozinha",
      "Cooling mode only": "Apenas arrefecimento",
      "Country": "País",
      "Current temperature as sensor": "Temperatura atual como sensor",
      "Customize AC buttons": "Personalizar os botões do ar condicionado",
      "Dehumidifier": "Desumidificador",
      "Device": "Dispositivo",
      "Device ID": "ID do dispositivo",
      "Device Name": "Nome do dispositivo",
      "Device Type": "Tipo de dispositivo",
      "Devices": "Dispositivos",
      "Dishwasher": "Máquina de lavar loiça",
      "Dishwasher specific settings": "Definições da máquina de lavar loiça",
      "Dryer": "Máquina de secar roupa",
      "Eco Friendly": "Modo eco",
      "Enable Air Quality": "Ativar a qualidade do ar",
      "Enable ThinQ1 Support?": "Ativar o suporte de ThinQ1?",
      "Enable Tub Clean Event": "Ativar o aviso de limpeza do tambor",
      "Enable door lock status": "Ativar o estado do bloqueio da porta",
      "Enable humidity sensor": "Ativar o sensor de humidade",
      "Enable led panel control": "Ativar o controlo do painel LED",
      "Enable program finished trigger?": "Ativar o aviso de programa terminado?",
      "Enable separate fan control": "Ativar o controlo separado da ventoinha",
      "Enable separate jet control": "Ativar o controlo separado do modo Jet",
      "Energy save as switch": "Poupança de energia como interruptor",
      "Express Freezer / Ice Plus": "Congelação rápida / Ice Plus",
      "Express Fridge": "Refrigeração rápida",
      "Fahrenheit": "Fahrenheit",
      "Heating mode only": "Apenas aquecimento",
      "Horizontal swing only": "Apenas oscilação horizontal",
      "How the plugin signs in: with the LG account's email and password, or with a refresh token. A refresh token, when there is one, is used first.": "Como o plugin inicia sessão: com o e-mail e a palavra-passe da conta LG, ou com um token de atualização. Se existir um token de atualização, é usado primeiro.",
      "LG Account": "Conta LG",
      "LG's number for the operation mode the switch selects; the switch is on while the unit is in that mode.": "O número da LG do modo de funcionamento que o interruptor escolhe; o interruptor fica ativo enquanto a unidade está nesse modo.",
      "Language": "Idioma",
      "Name": "Nome",
      "Operation mode": "Modo de funcionamento",
      "Oven": "Forno",
      "Password": "Palavra-passe",
      "Range": "Fogão",
      "Refresh Token": "Token de atualização",
      "Refresh interval (in second)": "Intervalo de atualização (em segundos)",
      "Refrigerator": "Frigorífico",
      "Refrigerator specific settings": "Definições do frigorífico",
      "Seconds between polls of ThinQ1 devices.": "Segundos entre consultas aos dispositivos ThinQ1.",
      "Serial Number (optional)": "Número de série (opcional)",
      "Shows the door lock as a lock in the Home app, on ThinQ2 washers and dryers.": "Mostra o bloqueio da porta como uma fechadura na app Casa, nas máquinas de lavar e de secar roupa ThinQ2.",
      "Shows the unit's display light as a light in the Home app.": "Mostra a luz do ecrã da unidade como uma luz na app Casa.",
      "Swing Mode (vertical or horizontal)": "Oscilação (vertical ou horizontal)",
      "Switches that each select one of the unit's operation modes, by LG's mode number (op_mode).": "Interruptores que escolhem cada um modo de funcionamento da unidade, pelo número de modo da LG (op_mode).",
      "Temperature Unit": "Unidade de temperatura",
      "The LG account's email, when signing in with the account.": "O e-mail da conta LG, para iniciar sessão com a conta.",
      "The LG account's password, when signing in with the account.": "A palavra-passe da conta LG, para iniciar sessão com a conta.",
      "The LG account's refresh token. The plugin's page gets one when you sign in there.": "O token de atualização da conta LG. A página do plugin obtém um ao iniciar sessão nela.",
      "The account's country, as a two-letter code such as US or FR.": "O país da conta, como código de duas letras, por exemplo US ou FR.",
      "The account's language, as a language tag such as en-US or fr-FR.": "O idioma da conta, como etiqueta de idioma, por exemplo en-US ou fr-FR.",
      "The air conditioner's temperature scale. In Fahrenheit, temperatures follow its own Fahrenheit table.": "A escala de temperatura do ar condicionado. Em Fahrenheit, as temperaturas seguem a sua própria tabela Fahrenheit.",
      "The axes swing turns on and off: vertical, horizontal or both.": "Os eixos em que a oscilação se ativa e desativa: vertical, horizontal ou ambos.",
      "The device's ID in the LG account.": "O ID do dispositivo na conta LG.",
      "The devices to add, each by its ID. Leave it empty to add every device of the account.": "Os dispositivos a adicionar, cada um pelo seu ID. Vazio, são adicionados todos os dispositivos da conta.",
      "The kind of appliance, as LG reports it. The plugin's page fills it in.": "O tipo de aparelho, tal como a LG o indica. A página do plugin preenche-o.",
      "The modes the Home app offers: heating, cooling or both.": "Os modos que a app Casa oferece: aquecimento, arrefecimento ou ambos.",
      "The name of this platform in the log.": "O nome desta plataforma no registo.",
      "The serial number shown in the Home app. Empty uses the one LG reports.": "O número de série mostrado na app Casa. Vazio, é usado o que a LG indica.",
      "The switch's name in the Home app.": "O nome do interruptor na app Casa.",
      "Token": "Token",
      "Username": "Nome de utilizador",
      "Vertical swing only": "Apenas oscilação vertical",
      "WashTower": "WashTower",
      "Washer": "Máquina de lavar roupa",
      "Washer (newer models)": "Máquina de lavar roupa (modelos recentes)",
      "Washer / Dryer specific settings": "Definições da máquina de lavar / secar roupa",
      "{{ value.name || 'new device' }}": "{{ value.name || 'novo dispositivo' }}",
      "{{ value.title }}": "{{ value.title }}"
    }
  }
}
"""#
}
