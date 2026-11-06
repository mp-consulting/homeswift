// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension PresencePlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "Presence",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "required": true,
        "default": "Presence",
        "description": "Plugin name as shown in the logs"
      },
      "graceMinutes": {
        "title": "Grace period (minutes)",
        "type": "number",
        "required": false,
        "placeholder": 10,
        "minimum": 1,
        "maximum": 240,
        "description": "How long none of a Person's devices is on the network before they are away. A phone asleep may not answer for a few minutes."
      },
      "interval": {
        "title": "Check every (seconds)",
        "type": "integer",
        "required": false,
        "placeholder": 30,
        "minimum": 10,
        "maximum": 600,
        "description": "How often the devices on the network are checked"
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "devices": {
        "title": "Devices",
        "type": "array",
        "x-kinds": ["person"],
        "items": {
          "title": "MAC address",
          "type": "string",
          "pattern": "^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$"
        },
        "description": "The MAC addresses of the devices this Person carries: home while one of them is on the network. A phone's private Wi-Fi address must be Fixed for this network."
      },
      "user": {
        "title": "Web UI user",
        "type": "string",
        "x-kinds": ["person"],
        "description": "The web UI user this Person is: their pages say when they are home. Empty, none."
      }
    }
  },
  "layout": ["name", "graceMinutes", "interval"],
  "i18n": {
    "fr": {
      "Name": "Nom",
      "Plugin name as shown in the logs": "Nom du plugin tel qu'il apparaît dans le journal",
      "Grace period (minutes)": "Délai de grâce (minutes)",
      "How long none of a Person's devices is on the network before they are away. A phone asleep may not answer for a few minutes.": "Combien de temps aucun appareil d'une Personne n'est sur le réseau avant qu'elle soit absente. Un téléphone en veille peut ne pas répondre pendant quelques minutes.",
      "Check every (seconds)": "Vérifier toutes les (secondes)",
      "How often the devices on the network are checked": "La fréquence à laquelle les appareils du réseau sont vérifiés",
      "Devices": "Appareils",
      "MAC address": "Adresse MAC",
      "The MAC addresses of the devices this Person carries: home while one of them is on the network. A phone's private Wi-Fi address must be Fixed for this network.": "Les adresses MAC des appareils que cette Personne porte sur elle : présente tant que l'un d'eux est sur le réseau. L'adresse Wi-Fi privée d'un téléphone doit être Fixe pour ce réseau.",
      "Web UI user": "Utilisateur de l'interface web",
      "The web UI user this Person is: their pages say when they are home. Empty, none.": "L'utilisateur de l'interface web qu'est cette Personne : ses pages disent quand elle est à la maison. Vide, aucun."
    },
    "es": {
      "Name": "Nombre",
      "Plugin name as shown in the logs": "Nombre del plugin tal como aparece en el registro",
      "Grace period (minutes)": "Periodo de gracia (minutos)",
      "How long none of a Person's devices is on the network before they are away. A phone asleep may not answer for a few minutes.": "Cuánto tiempo ningún dispositivo de una Persona está en la red antes de que esté fuera. Un teléfono en reposo puede no responder durante unos minutos.",
      "Check every (seconds)": "Comprobar cada (segundos)",
      "How often the devices on the network are checked": "Con qué frecuencia se comprueban los dispositivos de la red",
      "Devices": "Dispositivos",
      "MAC address": "Dirección MAC",
      "The MAC addresses of the devices this Person carries: home while one of them is on the network. A phone's private Wi-Fi address must be Fixed for this network.": "Las direcciones MAC de los dispositivos que lleva esta Persona: en casa mientras uno de ellos está en la red. La dirección Wi-Fi privada de un teléfono debe ser Fija para esta red.",
      "Web UI user": "Usuario de la interfaz web",
      "The web UI user this Person is: their pages say when they are home. Empty, none.": "El usuario de la interfaz web que es esta Persona: sus páginas dicen cuándo está en casa. Vacío, ninguno."
    },
    "pt": {
      "Name": "Nome",
      "Plugin name as shown in the logs": "Nome do plugin tal como aparece no registo",
      "Grace period (minutes)": "Período de tolerância (minutos)",
      "How long none of a Person's devices is on the network before they are away. A phone asleep may not answer for a few minutes.": "Quanto tempo nenhum dispositivo de uma Pessoa está na rede antes de ela estar fora. Um telemóvel em repouso pode não responder durante alguns minutos.",
      "Check every (seconds)": "Verificar a cada (segundos)",
      "How often the devices on the network are checked": "Com que frequência os dispositivos da rede são verificados",
      "Devices": "Dispositivos",
      "MAC address": "Endereço MAC",
      "The MAC addresses of the devices this Person carries: home while one of them is on the network. A phone's private Wi-Fi address must be Fixed for this network.": "Os endereços MAC dos dispositivos que esta Pessoa traz consigo: em casa enquanto um deles está na rede. O endereço Wi-Fi privado de um telemóvel tem de ser Fixo para esta rede.",
      "Web UI user": "Utilizador da interface web",
      "The web UI user this Person is: their pages say when they are home. Empty, none.": "O utilizador da interface web que esta Pessoa é: as suas páginas dizem quando está em casa. Vazio, nenhum."
    }
  }
}
"""#
}
