// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension HomeAssistantPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "HomeAssistant",
  "pluginType": "platform",
  "singular": false,
  "headerDisplay": "Lights, sensors, climate and more from a Home Assistant server, over its WebSocket API. Set it up from Add accessories with a long-lived access token.",
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "description": "Plugin name as shown in the logs",
        "default": "Home Assistant"
      },
      "url": {
        "title": "Address",
        "type": "string",
        "placeholder": "http://homeassistant.local:8123",
        "description": "The address of Home Assistant, as you open it in a browser. Setup finds it on the network or asks for it."
      },
      "serverId": {
        "title": "Server id",
        "type": "string",
        "description": "The uuid the server announces on the network, kept by Setup."
      },
      "domains": {
        "title": "Domains",
        "type": "array",
        "uniqueItems": true,
        "description": "The kinds of entities shown. All of them when none is ticked.",
        "items": {
          "type": "string",
          "oneOf": [
            {
              "title": "Lights",
              "enum": [
                "light"
              ]
            },
            {
              "title": "Switches",
              "enum": [
                "switch"
              ]
            },
            {
              "title": "Toggle helpers",
              "enum": [
                "input_boolean"
              ]
            },
            {
              "title": "Covers, blinds and garage doors",
              "enum": [
                "cover"
              ]
            },
            {
              "title": "Locks",
              "enum": [
                "lock"
              ]
            },
            {
              "title": "Thermostats and air conditioners",
              "enum": [
                "climate"
              ]
            },
            {
              "title": "Sensors",
              "enum": [
                "sensor"
              ]
            },
            {
              "title": "Binary sensors",
              "enum": [
                "binary_sensor"
              ]
            },
            {
              "title": "Fans",
              "enum": [
                "fan"
              ]
            },
            {
              "title": "Media players (power)",
              "enum": [
                "media_player"
              ]
            },
            {
              "title": "Scenes",
              "enum": [
                "scene"
              ]
            },
            {
              "title": "Scripts",
              "enum": [
                "script"
              ]
            },
            {
              "title": "Buttons",
              "enum": [
                "button"
              ]
            },
            {
              "title": "Button helpers",
              "enum": [
                "input_button"
              ]
            },
            {
              "title": "Valves",
              "enum": [
                "valve"
              ]
            },
            {
              "title": "Alarm panels",
              "enum": [
                "alarm_control_panel"
              ]
            },
            {
              "title": "Humidifiers and dehumidifiers",
              "enum": [
                "humidifier"
              ]
            }
          ]
        }
      },
      "includeEntities": {
        "title": "Include entities",
        "type": "array",
        "description": "Entity ids, or patterns with * such as sensor.*_power, shown even when Home Assistant hides them or files them as configuration or diagnostic.",
        "items": {
          "type": "string",
          "title": "Entity",
          "description": "An entity id or a pattern"
        }
      },
      "excludeEntities": {
        "title": "Exclude entities",
        "type": "array",
        "description": "Entity ids, or patterns with *, left out.",
        "items": {
          "type": "string",
          "title": "Entity",
          "description": "An entity id or a pattern"
        }
      },
      "mirror": {
        "title": "Mirror only",
        "type": "array",
        "description": "Entities shown in this web interface, its scenes and automations but never published to Apple Home, for those Home Assistant's own HomeKit bridge already publishes: entity ids, patterns with *, or all.",
        "items": {
          "type": "string",
          "title": "Entity",
          "description": "An entity id or a pattern"
        }
      },
      "verifyTLS": {
        "title": "Check the certificate",
        "type": "boolean",
        "default": true,
        "description": "Off for an https address with a self-signed certificate: the first certificate seen is trusted, then pinned."
      }
    }
  },
  "accessorySchema": {
    "properties": {}
  },
  "i18n": {
    "fr": {
      "Lights": "Lumières",
      "Switches": "Interrupteurs",
      "Toggle helpers": "Assistants à bascule",
      "Covers, blinds and garage doors": "Volets, stores et portes de garage",
      "Locks": "Serrures",
      "Thermostats and air conditioners": "Thermostats et climatiseurs",
      "Sensors": "Capteurs",
      "Binary sensors": "Capteurs binaires",
      "Fans": "Ventilateurs",
      "Media players (power)": "Lecteurs multimédias (alimentation)",
      "Scenes": "Scènes",
      "Scripts": "Scripts",
      "Buttons": "Boutons",
      "Button helpers": "Assistants bouton",
      "Valves": "Vannes",
      "Alarm panels": "Centrales d’alarme",
      "Humidifiers and dehumidifiers": "Humidificateurs et déshumidificateurs",
      "Name": "Nom",
      "Plugin name as shown in the logs": "Nom du plugin tel qu’il apparaît dans les journaux",
      "Address": "Adresse",
      "The address of Home Assistant, as you open it in a browser. Setup finds it on the network or asks for it.": "L’adresse de Home Assistant, telle que vous l’ouvrez dans un navigateur. La configuration la trouve sur le réseau ou la demande.",
      "Access token": "Jeton d’accès",
      "A long-lived access token, made in Home Assistant under your profile, Security. Setup keeps it in the vault; leave this empty.": "Un jeton d’accès de longue durée, créé dans Home Assistant sous votre profil, Sécurité. La configuration le garde dans le coffre ; laissez ce champ vide.",
      "Server id": "Identifiant du serveur",
      "The uuid the server announces on the network, kept by Setup.": "L’uuid que le serveur annonce sur le réseau, gardé par la configuration.",
      "Domains": "Domaines",
      "The kinds of entities shown. All of them when none is ticked.": "Les types d’entités affichés. Tous quand aucun n’est coché.",
      "Include entities": "Entités incluses",
      "Entity ids, or patterns with * such as sensor.*_power, shown even when Home Assistant hides them or files them as configuration or diagnostic.": "Identifiants d’entités, ou motifs avec * comme sensor.*_power, affichés même quand Home Assistant les masque ou les classe en configuration ou diagnostic.",
      "Entity": "Entité",
      "An entity id or a pattern": "Un identifiant d’entité ou un motif",
      "Exclude entities": "Entités exclues",
      "Entity ids, or patterns with *, left out.": "Identifiants d’entités, ou motifs avec *, laissés de côté.",
      "Mirror only": "Miroir seulement",
      "Entities shown in this web interface, its scenes and automations but never published to Apple Home, for those Home Assistant's own HomeKit bridge already publishes: entity ids, patterns with *, or all.": "Entités affichées dans cette interface web, ses scènes et automatisations mais jamais publiées dans Apple Maison, pour celles que le pont HomeKit de Home Assistant publie déjà : identifiants d’entités, motifs avec *, ou all.",
      "Lock code": "Code des serrures",
      "The code sent with lock and unlock, for locks that ask for one.": "Le code envoyé pour verrouiller et déverrouiller, pour les serrures qui en demandent un.",
      "Alarm code": "Code de l’alarme",
      "The code sent to arm and disarm alarm panels, for those that ask for one.": "Le code envoyé pour armer et désarmer les centrales d’alarme qui en demandent un.",
      "Check the certificate": "Vérifier le certificat",
      "Off for an https address with a self-signed certificate: the first certificate seen is trusted, then pinned.": "Désactivé pour une adresse https avec un certificat auto-signé : le premier certificat vu est accepté, puis épinglé.",
      "Lights, sensors, climate and more from a Home Assistant server, over its WebSocket API. Set it up from Add accessories with a long-lived access token.": "Lumières, capteurs, climatisation et plus depuis un serveur Home Assistant, par son API WebSocket. Configurez-le depuis Ajouter des accessoires avec un jeton d’accès de longue durée."
    },
    "es": {
      "Lights": "Luces",
      "Switches": "Interruptores",
      "Toggle helpers": "Ayudantes de interruptor",
      "Covers, blinds and garage doors": "Persianas, toldos y puertas de garaje",
      "Locks": "Cerraduras",
      "Thermostats and air conditioners": "Termostatos y aires acondicionados",
      "Sensors": "Sensores",
      "Binary sensors": "Sensores binarios",
      "Fans": "Ventiladores",
      "Media players (power)": "Reproductores multimedia (encendido)",
      "Scenes": "Escenas",
      "Scripts": "Scripts",
      "Buttons": "Botones",
      "Button helpers": "Ayudantes de botón",
      "Valves": "Válvulas",
      "Alarm panels": "Paneles de alarma",
      "Humidifiers and dehumidifiers": "Humidificadores y deshumidificadores",
      "Name": "Nombre",
      "Plugin name as shown in the logs": "Nombre del plugin tal como aparece en los registros",
      "Address": "Dirección",
      "The address of Home Assistant, as you open it in a browser. Setup finds it on the network or asks for it.": "La dirección de Home Assistant, tal como la abre en un navegador. La configuración la encuentra en la red o la pide.",
      "Access token": "Token de acceso",
      "A long-lived access token, made in Home Assistant under your profile, Security. Setup keeps it in the vault; leave this empty.": "Un token de acceso de larga duración, creado en Home Assistant en su perfil, Seguridad. La configuración lo guarda en la bóveda; deje este campo vacío.",
      "Server id": "Identificador del servidor",
      "The uuid the server announces on the network, kept by Setup.": "El uuid que el servidor anuncia en la red, guardado por la configuración.",
      "Domains": "Dominios",
      "The kinds of entities shown. All of them when none is ticked.": "Los tipos de entidades mostrados. Todos cuando no se marca ninguno.",
      "Include entities": "Entidades incluidas",
      "Entity ids, or patterns with * such as sensor.*_power, shown even when Home Assistant hides them or files them as configuration or diagnostic.": "Identificadores de entidades, o patrones con * como sensor.*_power, mostrados aunque Home Assistant los oculte o los clasifique como configuración o diagnóstico.",
      "Entity": "Entidad",
      "An entity id or a pattern": "Un identificador de entidad o un patrón",
      "Exclude entities": "Entidades excluidas",
      "Entity ids, or patterns with *, left out.": "Identificadores de entidades, o patrones con *, que se omiten.",
      "Mirror only": "Solo espejo",
      "Entities shown in this web interface, its scenes and automations but never published to Apple Home, for those Home Assistant's own HomeKit bridge already publishes: entity ids, patterns with *, or all.": "Entidades mostradas en esta interfaz web, sus escenas y automatizaciones pero nunca publicadas en Apple Casa, para las que el puente HomeKit de Home Assistant ya publica: identificadores de entidades, patrones con *, o all.",
      "Lock code": "Código de las cerraduras",
      "The code sent with lock and unlock, for locks that ask for one.": "El código enviado al bloquear y desbloquear, para las cerraduras que lo piden.",
      "Alarm code": "Código de la alarma",
      "The code sent to arm and disarm alarm panels, for those that ask for one.": "El código enviado para armar y desarmar los paneles de alarma que lo piden.",
      "Check the certificate": "Comprobar el certificado",
      "Off for an https address with a self-signed certificate: the first certificate seen is trusted, then pinned.": "Desactivado para una dirección https con un certificado autofirmado: se acepta el primer certificado visto y luego se fija.",
      "Lights, sensors, climate and more from a Home Assistant server, over its WebSocket API. Set it up from Add accessories with a long-lived access token.": "Luces, sensores, climatización y más desde un servidor Home Assistant, por su API WebSocket. Configúrelo desde Añadir accesorios con un token de acceso de larga duración."
    },
    "pt": {
      "Lights": "Luzes",
      "Switches": "Interruptores",
      "Toggle helpers": "Auxiliares de alternância",
      "Covers, blinds and garage doors": "Estores, persianas e portões de garagem",
      "Locks": "Fechaduras",
      "Thermostats and air conditioners": "Termóstatos e ares condicionados",
      "Sensors": "Sensores",
      "Binary sensors": "Sensores binários",
      "Fans": "Ventoinhas",
      "Media players (power)": "Leitores multimédia (energia)",
      "Scenes": "Cenas",
      "Scripts": "Scripts",
      "Buttons": "Botões",
      "Button helpers": "Auxiliares de botão",
      "Valves": "Válvulas",
      "Alarm panels": "Painéis de alarme",
      "Humidifiers and dehumidifiers": "Humidificadores e desumidificadores",
      "Name": "Nome",
      "Plugin name as shown in the logs": "Nome do plugin tal como aparece nos registos",
      "Address": "Endereço",
      "The address of Home Assistant, as you open it in a browser. Setup finds it on the network or asks for it.": "O endereço do Home Assistant, tal como o abre num navegador. A configuração encontra-o na rede ou pede-o.",
      "Access token": "Token de acesso",
      "A long-lived access token, made in Home Assistant under your profile, Security. Setup keeps it in the vault; leave this empty.": "Um token de acesso de longa duração, criado no Home Assistant no seu perfil, Segurança. A configuração guarda-o no cofre; deixe este campo vazio.",
      "Server id": "Identificador do servidor",
      "The uuid the server announces on the network, kept by Setup.": "O uuid que o servidor anuncia na rede, guardado pela configuração.",
      "Domains": "Domínios",
      "The kinds of entities shown. All of them when none is ticked.": "Os tipos de entidades mostrados. Todos quando nenhum está assinalado.",
      "Include entities": "Entidades incluídas",
      "Entity ids, or patterns with * such as sensor.*_power, shown even when Home Assistant hides them or files them as configuration or diagnostic.": "Identificadores de entidades, ou padrões com * como sensor.*_power, mostrados mesmo quando o Home Assistant os oculta ou os classifica como configuração ou diagnóstico.",
      "Entity": "Entidade",
      "An entity id or a pattern": "Um identificador de entidade ou um padrão",
      "Exclude entities": "Entidades excluídas",
      "Entity ids, or patterns with *, left out.": "Identificadores de entidades, ou padrões com *, deixados de fora.",
      "Mirror only": "Apenas espelho",
      "Entities shown in this web interface, its scenes and automations but never published to Apple Home, for those Home Assistant's own HomeKit bridge already publishes: entity ids, patterns with *, or all.": "Entidades mostradas nesta interface web, nas suas cenas e automatizações mas nunca publicadas na Apple Casa, para as que a ponte HomeKit do Home Assistant já publica: identificadores de entidades, padrões com *, ou all.",
      "Lock code": "Código das fechaduras",
      "The code sent with lock and unlock, for locks that ask for one.": "O código enviado ao trancar e destrancar, para as fechaduras que o pedem.",
      "Alarm code": "Código do alarme",
      "The code sent to arm and disarm alarm panels, for those that ask for one.": "O código enviado para armar e desarmar os painéis de alarme que o pedem.",
      "Check the certificate": "Verificar o certificado",
      "Off for an https address with a self-signed certificate: the first certificate seen is trusted, then pinned.": "Desativado para um endereço https com um certificado autoassinado: o primeiro certificado visto é aceite e depois fixado.",
      "Lights, sensors, climate and more from a Home Assistant server, over its WebSocket API. Set it up from Add accessories with a long-lived access token.": "Luzes, sensores, climatização e mais a partir de um servidor Home Assistant, pela sua API WebSocket. Configure-o a partir de Adicionar acessórios com um token de acesso de longa duração."
    }
  }
}
"""#
}
