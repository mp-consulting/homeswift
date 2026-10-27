// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension PhilipsHuePlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "PhilipsHue",
  "pluginType": "platform",
  "singular": false,
  "headerDisplay": "Philips Hue lights, scenes and effects through a Hue Bridge on your network (its local API v2). The first start pairs: press the bridge's link button when the log asks.",
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "default": "Philips Hue",
        "description": "This block's name, shown in the logs and in the web UI."
      },
      "host": {
        "title": "Bridge Address",
        "type": "string",
        "description": "The Hue Bridge's IP address or host name. Leave blank to find it on the network."
      },
      "transitionMs": {
        "title": "Transition",
        "type": "integer",
        "default": 100,
        "description": "How long a light takes to reach a new colour or brightness: the plugin page's speed scale. Extreme changes at once, for fast effects; the Hue app uses about 400 ms.",
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
      "pollingInterval": {
        "title": "Polling Interval (s)",
        "type": "integer",
        "minimum": 1,
        "maximum": 300,
        "default": 2,
        "description": "How often the bridge is asked for changes made elsewhere (the Hue app, a dimmer switch)."
      },
      "scenes": {
        "title": "Scenes",
        "type": "boolean",
        "default": true,
        "description": "A switch for each scene of a room or zone, on one accessory per room or zone. On recalls the scene; it shows on while the scene is active."
      },
      "excludeScenes": {
        "title": "Hidden Scenes",
        "type": "array",
        "items": { "type": "string" },
        "description": "Scene names (or \"Room/Scene\") to leave out."
      },
      "sceneTransitions": {
        "title": "Scene Transitions",
        "type": "array",
        "description": "Scenes that take their own transition instead of the one above.",
        "items": {
          "title": "Scene transition",
          "type": "object",
          "properties": {
            "scene": {
              "title": "Scene",
              "type": "string",
              "required": true,
              "description": "\"Room/Scene\", or a scene's name in any room."
            },
            "transitionMs": {
              "title": "Transition",
              "type": "integer",
              "required": true,
              "description": "How long the lights take to reach this scene.",
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
            }
          }
        }
      },
      "dynamicScenes": {
        "title": "Play Scenes Dynamically",
        "type": "boolean",
        "default": false,
        "description": "Recall scenes with their colours slowly moving through the palette, as the Hue app's play button does."
      },
      "effects": {
        "title": "Effects",
        "type": "boolean",
        "default": true,
        "description": "A switch for each effect a light has (candle, fire, sparkle, prism…)."
      },
      "roomLights": {
        "title": "Room Lights",
        "type": "boolean",
        "default": false,
        "description": "A lightbulb on each room's and zone's accessory: on, off and brightness for all its lights at once, as one command, like the Hue app's room controls."
      },
      "flashSwitch": {
        "title": "Flash Switch",
        "type": "boolean",
        "default": false,
        "description": "A switch on each light that makes it flash for a few seconds (Hue's signaling)."
      },
      "gradientPoints": {
        "title": "Gradient Points",
        "type": "boolean",
        "default": false,
        "description": "On gradient lightstrips and lamps, a light for each colour point, so each part of the strip takes its own colour."
      },
      "excludeLights": {
        "title": "Hidden Lights",
        "type": "array",
        "items": { "type": "string" },
        "description": "Light names or ids to leave out of HomeKit."
      }
    }
  },
  "layout": [
    "name",
    "host",
    "transitionMs",
    {
      "type": "fieldset",
      "title": "Scenes and Effects",
      "expandable": true,
      "items": ["scenes", "roomLights", "dynamicScenes", "excludeScenes", "sceneTransitions", "effects", "flashSwitch", "gradientPoints"]
    },
    {
      "type": "fieldset",
      "title": "Advanced Settings",
      "expandable": true,
      "items": ["pollingInterval", "excludeLights"]
    }
  ],
  "i18n": {
    "fr": {
      "\"Room/Scene\", or a scene's name in any room.": "« Pièce/Scène », ou le nom d'une scène dans n'importe quelle pièce.",
      "A lightbulb on each room's and zone's accessory: on, off and brightness for all its lights at once, as one command, like the Hue app's room controls.": "Une ampoule sur l'accessoire de chaque pièce et zone : allumer, éteindre et régler la luminosité de toutes ses lampes à la fois, en une commande, comme les commandes de pièce de l'app Hue.",
      "A switch for each effect a light has (candle, fire, sparkle, prism…).": "Un interrupteur pour chaque effet d'une lampe (bougie, feu, scintillement, prisme…).",
      "A switch for each scene of a room or zone, on one accessory per room or zone. On recalls the scene; it shows on while the scene is active.": "Un interrupteur pour chaque scène d'une pièce ou zone, sur un accessoire par pièce ou zone. L'allumer rappelle la scène ; il reste allumé tant que la scène est active.",
      "A switch on each light that makes it flash for a few seconds (Hue's signaling).": "Un interrupteur sur chaque lampe qui la fait clignoter quelques secondes (la signalisation de Hue).",
      "Advanced Settings": "Réglages avancés",
      "Bridge Address": "Adresse du pont",
      "Effects": "Effets",
      "Extreme · at once": "Extrême · immédiat",
      "Fast · 100 ms": "Rapide · 100 ms",
      "Fast · 200 ms": "Rapide · 200 ms",
      "Flash Switch": "Interrupteur Clignoter",
      "Gradient Points": "Points du dégradé",
      "Hidden Lights": "Lampes masquées",
      "Hidden Scenes": "Scènes masquées",
      "How long a light takes to reach a new colour or brightness: the plugin page's speed scale. Extreme changes at once, for fast effects; the Hue app uses about 400 ms.": "Le temps que met une lampe pour atteindre une nouvelle couleur ou luminosité : l'échelle de vitesse de la page du plugin. Extrême change aussitôt, pour les effets rapides ; l'app Hue utilise environ 400 ms.",
      "How long the lights take to reach this scene.": "Le temps que mettent les lampes pour atteindre cette scène.",
      "How often the bridge is asked for changes made elsewhere (the Hue app, a dimmer switch).": "La fréquence à laquelle le pont est interrogé sur les changements faits ailleurs (l'app Hue, un variateur).",
      "Light names or ids to leave out of HomeKit.": "Les noms ou identifiants des lampes à laisser hors de HomeKit.",
      "Medium · 300 ms": "Moyenne · 300 ms",
      "Medium · 400 ms": "Moyenne · 400 ms",
      "Medium · 600 ms": "Moyenne · 600 ms",
      "Name": "Nom",
      "On gradient lightstrips and lamps, a light for each colour point, so each part of the strip takes its own colour.": "Sur les rubans et lampes à dégradé, une lampe par point de couleur, pour que chaque partie du ruban ait sa couleur.",
      "Play Scenes Dynamically": "Scènes dynamiques",
      "Polling Interval (s)": "Intervalle d'interrogation (s)",
      "Recall scenes with their colours slowly moving through the palette, as the Hue app's play button does.": "Rappelle les scènes avec leurs couleurs qui parcourent lentement la palette, comme le bouton lecture de l'app Hue.",
      "Room Lights": "Lampes de la pièce",
      "Scene": "Scène",
      "Scene names (or \"Room/Scene\") to leave out.": "Les noms des scènes (ou « Pièce/Scène ») à laisser de côté.",
      "Scene transition": "Transition de scène",
      "Scene Transitions": "Transitions des scènes",
      "Scenes": "Scènes",
      "Scenes and Effects": "Scènes et effets",
      "Scenes that take their own transition instead of the one above.": "Les scènes qui ont leur propre transition au lieu de celle ci-dessus.",
      "Slow · 1000 ms": "Lente · 1000 ms",
      "Slow · 800 ms": "Lente · 800 ms",
      "The Hue Bridge's IP address or host name. Leave blank to find it on the network.": "L'adresse IP ou le nom d'hôte du pont Hue. Laissez vide pour le trouver sur le réseau.",
      "This block's name, shown in the logs and in the web UI.": "Le nom de ce bloc, affiché dans les journaux et l'interface web.",
      "Transition": "Transition",
      "Very fast · 30 ms": "Très rapide · 30 ms",
      "Very fast · 60 ms": "Très rapide · 60 ms",
      "Very slow · 1500 ms": "Très lente · 1500 ms",
      "Very slow · 2000 ms": "Très lente · 2000 ms"
    },
    "es": {
      "\"Room/Scene\", or a scene's name in any room.": "\"Habitación/Escena\", o el nombre de una escena en cualquier habitación.",
      "A lightbulb on each room's and zone's accessory: on, off and brightness for all its lights at once, as one command, like the Hue app's room controls.": "Una bombilla en el accesorio de cada habitación y zona: encender, apagar y ajustar el brillo de todas sus luces a la vez, en un solo comando, como los controles de habitación de la app Hue.",
      "A switch for each effect a light has (candle, fire, sparkle, prism…).": "Un interruptor por cada efecto de una luz (vela, fuego, destello, prisma…).",
      "A switch for each scene of a room or zone, on one accessory per room or zone. On recalls the scene; it shows on while the scene is active.": "Un interruptor por cada escena de una habitación o zona, en un accesorio por habitación o zona. Encenderlo activa la escena; se ve encendido mientras la escena está activa.",
      "A switch on each light that makes it flash for a few seconds (Hue's signaling).": "Un interruptor en cada luz que la hace parpadear unos segundos (la señalización de Hue).",
      "Advanced Settings": "Ajustes avanzados",
      "Bridge Address": "Dirección del puente",
      "Effects": "Efectos",
      "Extreme · at once": "Extrema · al instante",
      "Fast · 100 ms": "Rápida · 100 ms",
      "Fast · 200 ms": "Rápida · 200 ms",
      "Flash Switch": "Interruptor Parpadear",
      "Gradient Points": "Puntos del degradado",
      "Hidden Lights": "Luces ocultas",
      "Hidden Scenes": "Escenas ocultas",
      "How long a light takes to reach a new colour or brightness: the plugin page's speed scale. Extreme changes at once, for fast effects; the Hue app uses about 400 ms.": "Lo que tarda una luz en llegar a un nuevo color o brillo: la escala de velocidad de la página del plugin. Extrema cambia al instante, para efectos rápidos; la app Hue usa unos 400 ms.",
      "How long the lights take to reach this scene.": "Lo que tardan las luces en llegar a esta escena.",
      "How often the bridge is asked for changes made elsewhere (the Hue app, a dimmer switch).": "Cada cuánto se consulta al puente por cambios hechos en otro sitio (la app Hue, un regulador).",
      "Light names or ids to leave out of HomeKit.": "Nombres o ids de las luces que se dejan fuera de HomeKit.",
      "Medium · 300 ms": "Media · 300 ms",
      "Medium · 400 ms": "Media · 400 ms",
      "Medium · 600 ms": "Media · 600 ms",
      "Name": "Nombre",
      "On gradient lightstrips and lamps, a light for each colour point, so each part of the strip takes its own colour.": "En las tiras y lámparas con degradado, una luz por punto de color, para que cada parte de la tira tenga su color.",
      "Play Scenes Dynamically": "Escenas dinámicas",
      "Polling Interval (s)": "Intervalo de consulta (s)",
      "Recall scenes with their colours slowly moving through the palette, as the Hue app's play button does.": "Activa las escenas con sus colores recorriendo despacio la paleta, como el botón de reproducir de la app Hue.",
      "Room Lights": "Luces de la habitación",
      "Scene": "Escena",
      "Scene names (or \"Room/Scene\") to leave out.": "Nombres de las escenas (o \"Habitación/Escena\") que se dejan fuera.",
      "Scene transition": "Transición de escena",
      "Scene Transitions": "Transiciones de escenas",
      "Scenes": "Escenas",
      "Scenes and Effects": "Escenas y efectos",
      "Scenes that take their own transition instead of the one above.": "Las escenas que tienen su propia transición en lugar de la de arriba.",
      "Slow · 1000 ms": "Lenta · 1000 ms",
      "Slow · 800 ms": "Lenta · 800 ms",
      "The Hue Bridge's IP address or host name. Leave blank to find it on the network.": "La dirección IP o el nombre de host del puente Hue. Déjalo vacío para buscarlo en la red.",
      "This block's name, shown in the logs and in the web UI.": "El nombre de este bloque, que se muestra en los registros y en la interfaz web.",
      "Transition": "Transición",
      "Very fast · 30 ms": "Muy rápida · 30 ms",
      "Very fast · 60 ms": "Muy rápida · 60 ms",
      "Very slow · 1500 ms": "Muy lenta · 1500 ms",
      "Very slow · 2000 ms": "Muy lenta · 2000 ms"
    },
    "pt": {
      "\"Room/Scene\", or a scene's name in any room.": "\"Divisão/Cena\", ou o nome de uma cena em qualquer divisão.",
      "A lightbulb on each room's and zone's accessory: on, off and brightness for all its lights at once, as one command, like the Hue app's room controls.": "Uma lâmpada no acessório de cada divisão e zona: ligar, desligar e ajustar o brilho de todas as suas luzes de uma vez, num só comando, como os controlos de divisão da app Hue.",
      "A switch for each effect a light has (candle, fire, sparkle, prism…).": "Um interruptor por cada efeito de uma luz (vela, fogo, cintilar, prisma…).",
      "A switch for each scene of a room or zone, on one accessory per room or zone. On recalls the scene; it shows on while the scene is active.": "Um interruptor por cada cena de uma divisão ou zona, num acessório por divisão ou zona. Ligá-lo ativa a cena; aparece ligado enquanto a cena está ativa.",
      "A switch on each light that makes it flash for a few seconds (Hue's signaling).": "Um interruptor em cada luz que a faz piscar alguns segundos (a sinalização da Hue).",
      "Advanced Settings": "Definições avançadas",
      "Bridge Address": "Endereço da ponte",
      "Effects": "Efeitos",
      "Extreme · at once": "Extrema · de imediato",
      "Fast · 100 ms": "Rápida · 100 ms",
      "Fast · 200 ms": "Rápida · 200 ms",
      "Flash Switch": "Interruptor Piscar",
      "Gradient Points": "Pontos do gradiente",
      "Hidden Lights": "Luzes ocultas",
      "Hidden Scenes": "Cenas ocultas",
      "How long a light takes to reach a new colour or brightness: the plugin page's speed scale. Extreme changes at once, for fast effects; the Hue app uses about 400 ms.": "O tempo que uma luz demora a chegar a uma nova cor ou brilho: a escala de velocidade da página do plugin. Extrema muda de imediato, para efeitos rápidos; a app Hue usa cerca de 400 ms.",
      "How long the lights take to reach this scene.": "O tempo que as luzes demoram a chegar a esta cena.",
      "How often the bridge is asked for changes made elsewhere (the Hue app, a dimmer switch).": "A frequência com que a ponte é consultada sobre alterações feitas noutro sítio (a app Hue, um regulador).",
      "Light names or ids to leave out of HomeKit.": "Nomes ou ids das luzes a deixar fora do HomeKit.",
      "Medium · 300 ms": "Média · 300 ms",
      "Medium · 400 ms": "Média · 400 ms",
      "Medium · 600 ms": "Média · 600 ms",
      "Name": "Nome",
      "On gradient lightstrips and lamps, a light for each colour point, so each part of the strip takes its own colour.": "Nas fitas e candeeiros com gradiente, uma luz por ponto de cor, para cada parte da fita ter a sua cor.",
      "Play Scenes Dynamically": "Cenas dinâmicas",
      "Polling Interval (s)": "Intervalo de consulta (s)",
      "Recall scenes with their colours slowly moving through the palette, as the Hue app's play button does.": "Ativa as cenas com as cores a percorrer devagar a paleta, como o botão de reprodução da app Hue.",
      "Room Lights": "Luzes da divisão",
      "Scene": "Cena",
      "Scene names (or \"Room/Scene\") to leave out.": "Nomes das cenas (ou \"Divisão/Cena\") a deixar de fora.",
      "Scene transition": "Transição de cena",
      "Scene Transitions": "Transições de cenas",
      "Scenes": "Cenas",
      "Scenes and Effects": "Cenas e efeitos",
      "Scenes that take their own transition instead of the one above.": "As cenas que têm a sua própria transição em vez da indicada acima.",
      "Slow · 1000 ms": "Lenta · 1000 ms",
      "Slow · 800 ms": "Lenta · 800 ms",
      "The Hue Bridge's IP address or host name. Leave blank to find it on the network.": "O endereço IP ou o nome de anfitrião da ponte Hue. Deixe vazio para a encontrar na rede.",
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
