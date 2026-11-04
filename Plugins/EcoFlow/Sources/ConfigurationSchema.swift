// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension EcoFlowPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "EcoFlow",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "required": true,
        "default": "EcoFlow",
        "description": "Name shown in the logs"
      },
      "route": {
        "title": "Route",
        "type": "string",
        "required": false,
        "default": "both",
        "oneOf": [
          {
            "title": "Both",
            "enum": [
              "both"
            ]
          },
          {
            "title": "Developer API",
            "enum": [
              "developer"
            ]
          },
          {
            "title": "EcoFlow app",
            "enum": [
              "app"
            ]
          }
        ],
        "description": "Which EcoFlow service the plugin reads. Developer API: the documented one, with keys from developer.ecoflow.com. EcoFlow app: your EcoFlow account's sign-in, unofficial. Both: either, or both together"
      },
      "email": {
        "title": "Email",
        "type": "string",
        "required": false,
        "description": "As you sign in to the EcoFlow app. Its password is kept in the vault: Set up again changes it",
        "x-schema-form": {
          "condition": "model.route !== 'developer'",
          "requiredWhen": "model.route === 'app'"
        }
      },
      "importHistory": {
        "title": "Import the energy history",
        "type": "boolean",
        "required": false,
        "default": true,
        "description": "Each hour's solar production, home use, battery and grid since your system was set up, from the EcoFlow cloud, in the Status page's month and year views",
        "x-schema-form": {
          "condition": "model.route !== 'developer'"
        }
      },
      "region": {
        "title": "Region",
        "type": "string",
        "required": false,
        "default": "us",
        "oneOf": [
          {
            "title": "United States",
            "enum": [
              "us"
            ]
          },
          {
            "title": "Europe",
            "enum": [
              "eu"
            ]
          }
        ],
        "description": "The region your developer account was created in",
        "x-schema-form": {
          "condition": "model.route !== 'app'"
        }
      },
      "pollingInterval": {
        "title": "Interval (seconds)",
        "type": "integer",
        "required": false,
        "placeholder": 60,
        "minimum": 30,
        "description": "Seconds between reads of the developer API's REST values: 60 by default, 30 at least. MQTT values are live whatever this is",
        "x-schema-form": {
          "condition": "model.route !== 'app'"
        }
      }
    }
  },
  "i18n": {
    "fr": {
      "Name": "Nom",
      "Name shown in the logs": "Nom affiché dans les journaux",
      "Region": "Région",
      "The region your developer account was created in": "La région dans laquelle votre compte développeur a été créé",
      "United States": "États-Unis",
      "Europe": "Europe",
      "Route": "Accès",
      "Developer API": "API développeur",
      "EcoFlow app": "Application EcoFlow",
      "Email": "E-mail",
      "Both": "Les deux",
      "Import the energy history": "Importer l’historique d’énergie",
      "EcoFlow account": "Compte EcoFlow",
      "Which EcoFlow service the plugin reads. Developer API: the documented one, with keys from developer.ecoflow.com. EcoFlow app: your EcoFlow account's sign-in, unofficial. Both: either, or both together": "Le service EcoFlow que lit le plugin. API développeur : le service documenté, avec des clés de developer.ecoflow.com. Application EcoFlow : la connexion de votre compte EcoFlow, non officielle. Les deux : l'un ou l'autre, ou les deux ensemble",
      "Seconds between reads of the developer API's REST values: 60 by default, 30 at least. MQTT values are live whatever this is": "Secondes entre deux lectures des valeurs REST de l'API développeur : 60 par défaut, 30 au minimum. Les valeurs MQTT sont en direct quelle que soit cette valeur",
      "Interval (seconds)": "Intervalle (secondes)",
      "Each hour's solar production, home use, battery and grid since your system was set up, from the EcoFlow cloud, in the Status page's month and year views": "La production solaire, la consommation de la maison, la batterie et le réseau heure par heure depuis l'installation de votre système, depuis le cloud EcoFlow, dans les vues mois et année de la page État",
      "As you sign in to the EcoFlow app. Its password is kept in the vault: Set up again changes it": "Comme vous vous connectez à l'app EcoFlow. Son mot de passe est gardé dans le coffre : Configurer à nouveau le change"
    },
    "es": {
      "Name": "Nombre",
      "Name shown in the logs": "Nombre que aparece en los registros",
      "Region": "Región",
      "The region your developer account was created in": "La región en la que se creó tu cuenta de desarrollador",
      "United States": "Estados Unidos",
      "Europe": "Europa",
      "Route": "Ruta",
      "Developer API": "API para desarrolladores",
      "EcoFlow app": "App de EcoFlow",
      "Email": "Correo electrónico",
      "Both": "Ambas",
      "Import the energy history": "Importar el historial de energía",
      "EcoFlow account": "Cuenta EcoFlow",
      "Which EcoFlow service the plugin reads. Developer API: the documented one, with keys from developer.ecoflow.com. EcoFlow app: your EcoFlow account's sign-in, unofficial. Both: either, or both together": "El servicio de EcoFlow que lee el plugin. API para desarrolladores: el documentado, con claves de developer.ecoflow.com. App de EcoFlow: el inicio de sesión de tu cuenta EcoFlow, no oficial. Ambas: uno u otro, o los dos juntos",
      "Seconds between reads of the developer API's REST values: 60 by default, 30 at least. MQTT values are live whatever this is": "Segundos entre lecturas de los valores REST de la API para desarrolladores: 60 por defecto, 30 como mínimo. Los valores MQTT son en directo sea cual sea este valor",
      "Interval (seconds)": "Intervalo (segundos)",
      "Each hour's solar production, home use, battery and grid since your system was set up, from the EcoFlow cloud, in the Status page's month and year views": "La producción solar, el consumo de la casa, la batería y la red hora a hora desde que se instaló tu sistema, desde la nube de EcoFlow, en las vistas de mes y año de la página Estado",
      "As you sign in to the EcoFlow app. Its password is kept in the vault: Set up again changes it": "Como inicias sesión en la app EcoFlow. Su contraseña se guarda en el almacén: Configurar de nuevo la cambia"
    },
    "pt": {
      "Name": "Nome",
      "Name shown in the logs": "Nome mostrado nos registos",
      "Region": "Região",
      "The region your developer account was created in": "A região em que a sua conta de programador foi criada",
      "United States": "Estados Unidos",
      "Europe": "Europa",
      "Route": "Via",
      "Developer API": "API para programadores",
      "EcoFlow app": "Aplicação EcoFlow",
      "Email": "Email",
      "Both": "Ambas",
      "Import the energy history": "Importar o histórico de energia",
      "EcoFlow account": "Conta EcoFlow",
      "Which EcoFlow service the plugin reads. Developer API: the documented one, with keys from developer.ecoflow.com. EcoFlow app: your EcoFlow account's sign-in, unofficial. Both: either, or both together": "O serviço EcoFlow que o plugin lê. API para programadores: o documentado, com chaves de developer.ecoflow.com. Aplicação EcoFlow: o início de sessão da sua conta EcoFlow, não oficial. Ambas: um ou outro, ou os dois juntos",
      "Seconds between reads of the developer API's REST values: 60 by default, 30 at least. MQTT values are live whatever this is": "Segundos entre leituras dos valores REST da API para programadores: 60 por omissão, 30 no mínimo. Os valores MQTT são em direto, seja qual for este valor",
      "Interval (seconds)": "Intervalo (segundos)",
      "Each hour's solar production, home use, battery and grid since your system was set up, from the EcoFlow cloud, in the Status page's month and year views": "A produção solar, o consumo da casa, a bateria e a rede hora a hora desde a instalação do seu sistema, a partir da nuvem EcoFlow, nas vistas de mês e ano da página Estado",
      "As you sign in to the EcoFlow app. Its password is kept in the vault: Set up again changes it": "Como inicia sessão na app EcoFlow. A palavra-passe fica guardada no cofre: Configurar novamente altera-a"
    }
  },
  "layout": [
    {
      "type": "div",
      "items": [
        "name",
        "route"
      ]
    },
    {
      "type": "fieldset",
      "title": "EcoFlow account",
      "icon": "user",
      "condition": "model.route !== 'developer'",
      "items": [
        "email",
        "importHistory"
      ]
    },
    {
      "type": "fieldset",
      "title": "Developer API",
      "icon": "key",
      "condition": "model.route !== 'app'",
      "items": [
        "region",
        "pollingInterval"
      ]
    }
  ]
}
"""#
}
