// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension DirigeraPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "Dirigera",
  "pluginType": "platform",
  "singular": true,
  "headerDisplay": "IKEA lights, outlets and scenes through a DIRIGERA hub on your network. Pair on the plugin's page: it asks for the action button under the hub.",
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "default": "IKEA DIRIGERA",
        "description": "This block's name, shown in the logs and in the web UI."
      },
      "hubs": {
        "type": "array",
        "title": "DIRIGERA Hubs",
        "description": "The hubs to use, by address. A hub paired on the plugin's page is used too, without an entry here.",
        "items": {
          "title": "Hub",
          "type": "object",
          "properties": {
            "host": {
              "title": "Host / IP",
              "type": "string",
              "required": true,
              "format": "hostname",
              "description": "The hub's IP address or host name."
            },
            "token": {
              "title": "Authentication Token",
              "type": "string", "x-schema-form": { "type": "password" },
              "required": false,
              "description": "Optional: a token from homebridge-dirigera. Pairing on the plugin's page keeps its own in the plugin's folder."
            },
            "name": {
              "title": "Name",
              "type": "string",
              "required": false,
              "minLength": 1,
              "description": "Names the hub's scenes accessory, \"<name> Scenes\". Without it: \"IKEA Scenes\"."
            }
          }
        }
      },
      "transitionMs": {
        "title": "Transition",
        "type": "integer",
        "default": 100,
        "description": "How long a light takes to reach a new level or colour: the plugin page's speed scale. Extreme changes at once.",
        "oneOf": [
          { "title": "Very slow · 2000 ms", "enum": [2000] },
          { "title": "Very slow · 1500 ms", "enum": [1500] },
          { "title": "Slow · 1000 ms", "enum": [1000] },
          { "title": "Slow · 800 ms", "enum": [800] },
          { "title": "Medium · 600 ms", "enum": [600] },
          { "title": "Medium · 400 ms", "enum": [400] },
          { "title": "Medium · 300 ms", "enum": [300] },
          { "title": "Fast · 200 ms", "enum": [200] },
          { "title": "Fast · 100 ms", "enum": [100] },
          { "title": "Very fast · 60 ms", "enum": [60] },
          { "title": "Very fast · 30 ms", "enum": [30] },
          { "title": "Extreme · at once", "enum": [0] }
        ]
      },
      "scenes": {
        "title": "Scenes",
        "type": "boolean",
        "default": true,
        "description": "A switch for each scene of the hub. On triggers it; Off within 30 seconds undoes it."
      },
      "excludeDevices": {
        "title": "Hidden Devices",
        "type": "array",
        "items": { "type": "string" },
        "description": "Device names or ids to leave out of HomeKit."
      },
      "excludeScenes": {
        "title": "Hidden Scenes",
        "type": "array",
        "items": { "type": "string" },
        "description": "Scene names or ids to leave out."
      }
    }
  },
  "layout": [
    "name",
    { "key": "hubs", "type": "array", "items": ["hubs[].host", "hubs[].name", "hubs[].token"] },
    "transitionMs",
    {
      "type": "fieldset",
      "title": "In the Home app",
      "expandable": true,
      "items": ["scenes", "excludeDevices", "excludeScenes"]
    }
  ],
  "i18n": {
    "fr": {
      "A switch for each scene of the hub. On triggers it; Off within 30 seconds undoes it.": "Un interrupteur par scène du hub. L'allumer la lance ; l'éteindre dans les 30 secondes l'annule.",
      "Authentication Token": "Jeton d'authentification",
      "Device names or ids to leave out of HomeKit.": "Les noms ou identifiants des appareils à laisser hors de HomeKit.",
      "DIRIGERA Hubs": "Hubs DIRIGERA",
      "Extreme · at once": "Extrême · immédiat",
      "Fast · 100 ms": "Rapide · 100 ms",
      "Fast · 200 ms": "Rapide · 200 ms",
      "Hidden Devices": "Appareils masqués",
      "Hidden Scenes": "Scènes masquées",
      "Host / IP": "Hôte / IP",
      "How long a light takes to reach a new level or colour: the plugin page's speed scale. Extreme changes at once.": "Le temps que met une lampe pour atteindre un nouveau niveau ou une nouvelle couleur : l'échelle de vitesse de la page du plugin. Extrême change aussitôt.",
      "Hub": "Hub",
      "In the Home app": "Dans l'app Maison",
      "Medium · 300 ms": "Moyenne · 300 ms",
      "Medium · 400 ms": "Moyenne · 400 ms",
      "Medium · 600 ms": "Moyenne · 600 ms",
      "Name": "Nom",
      "Names the hub's scenes accessory, \"<name> Scenes\". Without it: \"IKEA Scenes\".": "Nomme l'accessoire des scènes du hub, « <name> Scenes ». Sans nom : « IKEA Scenes ».",
      "Optional: a token from homebridge-dirigera. Pairing on the plugin's page keeps its own in the plugin's folder.": "Facultatif : un jeton de homebridge-dirigera. Le jumelage sur la page du plugin garde le sien dans le dossier du plugin.",
      "Scene names or ids to leave out.": "Les noms ou identifiants des scènes à laisser de côté.",
      "Scenes": "Scènes",
      "Slow · 1000 ms": "Lente · 1000 ms",
      "Slow · 800 ms": "Lente · 800 ms",
      "The hub's IP address or host name.": "L'adresse IP ou le nom d'hôte du hub.",
      "The hubs to use, by address. A hub paired on the plugin's page is used too, without an entry here.": "Les hubs à utiliser, par adresse. Un hub jumelé sur la page du plugin est aussi utilisé, sans entrée ici.",
      "This block's name, shown in the logs and in the web UI.": "Le nom de ce bloc, affiché dans les journaux et l'interface web.",
      "Transition": "Transition",
      "Very fast · 30 ms": "Très rapide · 30 ms",
      "Very fast · 60 ms": "Très rapide · 60 ms",
      "Very slow · 1500 ms": "Très lente · 1500 ms",
      "Very slow · 2000 ms": "Très lente · 2000 ms"
    },
    "es": {
      "A switch for each scene of the hub. On triggers it; Off within 30 seconds undoes it.": "Un interruptor por escena del hub. Encenderlo la activa; apagarlo antes de 30 segundos la deshace.",
      "Authentication Token": "Token de autenticación",
      "Device names or ids to leave out of HomeKit.": "Nombres o ids de los dispositivos que se dejan fuera de HomeKit.",
      "DIRIGERA Hubs": "Hubs DIRIGERA",
      "Extreme · at once": "Extrema · al instante",
      "Fast · 100 ms": "Rápida · 100 ms",
      "Fast · 200 ms": "Rápida · 200 ms",
      "Hidden Devices": "Dispositivos ocultos",
      "Hidden Scenes": "Escenas ocultas",
      "Host / IP": "Host / IP",
      "How long a light takes to reach a new level or colour: the plugin page's speed scale. Extreme changes at once.": "Lo que tarda una luz en llegar a un nuevo nivel o color: la escala de velocidad de la página del plugin. Extrema cambia al instante.",
      "Hub": "Hub",
      "In the Home app": "En la app Casa",
      "Medium · 300 ms": "Media · 300 ms",
      "Medium · 400 ms": "Media · 400 ms",
      "Medium · 600 ms": "Media · 600 ms",
      "Name": "Nombre",
      "Names the hub's scenes accessory, \"<name> Scenes\". Without it: \"IKEA Scenes\".": "Da nombre al accesorio de escenas del hub, \"<name> Scenes\". Sin él: \"IKEA Scenes\".",
      "Optional: a token from homebridge-dirigera. Pairing on the plugin's page keeps its own in the plugin's folder.": "Opcional: un token de homebridge-dirigera. Al emparejar en la página del plugin, este guarda el suyo en su carpeta.",
      "Scene names or ids to leave out.": "Nombres o ids de las escenas que se dejan fuera.",
      "Scenes": "Escenas",
      "Slow · 1000 ms": "Lenta · 1000 ms",
      "Slow · 800 ms": "Lenta · 800 ms",
      "The hub's IP address or host name.": "La dirección IP o el nombre de host del hub.",
      "The hubs to use, by address. A hub paired on the plugin's page is used too, without an entry here.": "Los hubs que se usan, por dirección. Un hub emparejado en la página del plugin también se usa, sin entrada aquí.",
      "This block's name, shown in the logs and in the web UI.": "El nombre de este bloque, que se muestra en los registros y en la interfaz web.",
      "Transition": "Transición",
      "Very fast · 30 ms": "Muy rápida · 30 ms",
      "Very fast · 60 ms": "Muy rápida · 60 ms",
      "Very slow · 1500 ms": "Muy lenta · 1500 ms",
      "Very slow · 2000 ms": "Muy lenta · 2000 ms"
    },
    "pt": {
      "A switch for each scene of the hub. On triggers it; Off within 30 seconds undoes it.": "Um interruptor por cena do hub. Ligá-lo ativa-a; desligá-lo nos 30 segundos seguintes anula-a.",
      "Authentication Token": "Token de autenticação",
      "Device names or ids to leave out of HomeKit.": "Nomes ou ids dos dispositivos a deixar fora do HomeKit.",
      "DIRIGERA Hubs": "Hubs DIRIGERA",
      "Extreme · at once": "Extrema · de imediato",
      "Fast · 100 ms": "Rápida · 100 ms",
      "Fast · 200 ms": "Rápida · 200 ms",
      "Hidden Devices": "Dispositivos ocultos",
      "Hidden Scenes": "Cenas ocultas",
      "Host / IP": "Anfitrião / IP",
      "How long a light takes to reach a new level or colour: the plugin page's speed scale. Extreme changes at once.": "O tempo que uma luz demora a chegar a um novo nível ou cor: a escala de velocidade da página do plugin. Extrema muda de imediato.",
      "Hub": "Hub",
      "In the Home app": "Na app Casa",
      "Medium · 300 ms": "Média · 300 ms",
      "Medium · 400 ms": "Média · 400 ms",
      "Medium · 600 ms": "Média · 600 ms",
      "Name": "Nome",
      "Names the hub's scenes accessory, \"<name> Scenes\". Without it: \"IKEA Scenes\".": "Dá nome ao acessório de cenas do hub, \"<name> Scenes\". Sem ele: \"IKEA Scenes\".",
      "Optional: a token from homebridge-dirigera. Pairing on the plugin's page keeps its own in the plugin's folder.": "Opcional: um token do homebridge-dirigera. O emparelhamento na página do plugin guarda o seu na pasta do plugin.",
      "Scene names or ids to leave out.": "Nomes ou ids das cenas a deixar de fora.",
      "Scenes": "Cenas",
      "Slow · 1000 ms": "Lenta · 1000 ms",
      "Slow · 800 ms": "Lenta · 800 ms",
      "The hub's IP address or host name.": "O endereço IP ou o nome de anfitrião do hub.",
      "The hubs to use, by address. A hub paired on the plugin's page is used too, without an entry here.": "Os hubs a usar, por endereço. Um hub emparelhado na página do plugin também é usado, sem entrada aqui.",
      "This block's name, shown in the logs and in the web UI.": "O nome deste bloco, mostrado nos registos e na interface web.",
      "Transition": "Transição",
      "Very fast · 30 ms": "Muito rápida · 30 ms",
      "Very fast · 60 ms": "Muito rápida · 60 ms",
      "Very slow · 1500 ms": "Muito lenta · 1500 ms",
      "Very slow · 2000 ms": "Muito lenta · 2000 ms"
    }
  }
}
"""#
}
