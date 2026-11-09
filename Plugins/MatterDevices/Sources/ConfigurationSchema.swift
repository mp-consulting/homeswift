// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension MatterDevicesPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "MatterDevices",
  "pluginType": "platform",
  "singular": true,
  "headerDisplay": "Matter devices another app already has, controlled by Homeswift too. Add one from Add accessories with the pairing code that app shows when you turn on its pairing mode.",
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "required": true,
        "default": "Matter Devices",
        "description": "Plugin name as shown in the logs"
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "light1": {
        "type": "array",
        "items": {
          "type": "string"
        },
        "uniqueItems": true,
        "title": "Channel 1 controls",
        "description": "The lights the remote's first wheel or rocker channel dims together and the shutters it moves, a step per notch; its button switches the lights, and opens, closes or stops the shutters",
        "x-kinds": [
          "remote"
        ]
      },
      "light2": {
        "type": "array",
        "items": {
          "type": "string"
        },
        "uniqueItems": true,
        "title": "Channel 2 controls",
        "description": "The lights the second channel dims and the shutters it moves",
        "x-kinds": [
          "remote"
        ]
      },
      "light3": {
        "type": "array",
        "items": {
          "type": "string"
        },
        "uniqueItems": true,
        "title": "Channel 3 controls",
        "description": "The lights the third channel dims and the shutters it moves",
        "x-kinds": [
          "remote"
        ]
      },
      "light4": {
        "type": "array",
        "items": {
          "type": "string"
        },
        "uniqueItems": true,
        "title": "Channel 4 controls",
        "description": "The lights the fourth channel dims and the shutters it moves",
        "x-kinds": [
          "remote"
        ]
      },
      "power1": {
        "type": "array",
        "items": {
          "type": "string"
        },
        "uniqueItems": true,
        "title": "Channel 1 power",
        "description": "The switches that power the channel's lights (relays, such as eWeLink's), switched together: the button switches them, turning up switches them on first, and turning down past the lowest brightness switches them off",
        "x-kinds": [
          "remote"
        ]
      },
      "double1": {
        "type": "string",
        "title": "Double press runs",
        "description": "A scene the channel's button runs on a double press",
        "x-kinds": [
          "remote"
        ]
      },
      "long1": {
        "type": "string",
        "title": "Long press runs",
        "description": "A scene the channel's button runs when held",
        "x-kinds": [
          "remote"
        ]
      },
      "hold1": {
        "type": "string",
        "title": "Holding the button",
        "description": "What the channel's button does while held: runs the long press's scene, or dims the lights until let go",
        "default": "scene",
        "oneOf": [
          {
            "title": "Runs the long press's scene",
            "enum": [
              "scene"
            ]
          },
          {
            "title": "Brightens, then dims, in turn",
            "enum": [
              "alternate"
            ]
          },
          {
            "title": "Brightens",
            "enum": [
              "up"
            ]
          },
          {
            "title": "Dims",
            "enum": [
              "down"
            ]
          }
        ],
        "x-kinds": [
          "remote"
        ]
      },
      "power2": {
        "type": "array",
        "items": {
          "type": "string"
        },
        "uniqueItems": true,
        "title": "Channel 2 power",
        "description": "The switches that power the second channel's lights",
        "x-kinds": [
          "remote"
        ]
      },
      "double2": {
        "type": "string",
        "title": "Double press runs",
        "description": "A scene the channel's button runs on a double press",
        "x-kinds": [
          "remote"
        ]
      },
      "long2": {
        "type": "string",
        "title": "Long press runs",
        "description": "A scene the channel's button runs when held",
        "x-kinds": [
          "remote"
        ]
      },
      "hold2": {
        "type": "string",
        "title": "Holding the button",
        "description": "What the channel's button does while held: runs the long press's scene, or dims the lights until let go",
        "default": "scene",
        "oneOf": [
          {
            "title": "Runs the long press's scene",
            "enum": [
              "scene"
            ]
          },
          {
            "title": "Brightens, then dims, in turn",
            "enum": [
              "alternate"
            ]
          },
          {
            "title": "Brightens",
            "enum": [
              "up"
            ]
          },
          {
            "title": "Dims",
            "enum": [
              "down"
            ]
          }
        ],
        "x-kinds": [
          "remote"
        ]
      },
      "power3": {
        "type": "array",
        "items": {
          "type": "string"
        },
        "uniqueItems": true,
        "title": "Channel 3 power",
        "description": "The switches that power the third channel's lights",
        "x-kinds": [
          "remote"
        ]
      },
      "double3": {
        "type": "string",
        "title": "Double press runs",
        "description": "A scene the channel's button runs on a double press",
        "x-kinds": [
          "remote"
        ]
      },
      "long3": {
        "type": "string",
        "title": "Long press runs",
        "description": "A scene the channel's button runs when held",
        "x-kinds": [
          "remote"
        ]
      },
      "hold3": {
        "type": "string",
        "title": "Holding the button",
        "description": "What the channel's button does while held: runs the long press's scene, or dims the lights until let go",
        "default": "scene",
        "oneOf": [
          {
            "title": "Runs the long press's scene",
            "enum": [
              "scene"
            ]
          },
          {
            "title": "Brightens, then dims, in turn",
            "enum": [
              "alternate"
            ]
          },
          {
            "title": "Brightens",
            "enum": [
              "up"
            ]
          },
          {
            "title": "Dims",
            "enum": [
              "down"
            ]
          }
        ],
        "x-kinds": [
          "remote"
        ]
      },
      "power4": {
        "type": "array",
        "items": {
          "type": "string"
        },
        "uniqueItems": true,
        "title": "Channel 4 power",
        "description": "The switches that power the fourth channel's lights",
        "x-kinds": [
          "remote"
        ]
      },
      "double4": {
        "type": "string",
        "title": "Double press runs",
        "description": "A scene the channel's button runs on a double press",
        "x-kinds": [
          "remote"
        ]
      },
      "long4": {
        "type": "string",
        "title": "Long press runs",
        "description": "A scene the channel's button runs when held",
        "x-kinds": [
          "remote"
        ]
      },
      "hold4": {
        "type": "string",
        "title": "Holding the button",
        "description": "What the channel's button does while held: runs the long press's scene, or dims the lights until let go",
        "default": "scene",
        "oneOf": [
          {
            "title": "Runs the long press's scene",
            "enum": [
              "scene"
            ]
          },
          {
            "title": "Brightens, then dims, in turn",
            "enum": [
              "alternate"
            ]
          },
          {
            "title": "Brightens",
            "enum": [
              "up"
            ]
          },
          {
            "title": "Dims",
            "enum": [
              "down"
            ]
          }
        ],
        "x-kinds": [
          "remote"
        ]
      },
      "dimStep": {
        "type": "integer",
        "minimum": 1,
        "maximum": 25,
        "default": 5,
        "title": "Brightness per notch",
        "description": "Percent of brightness one notch of the wheel moves the light",
        "x-kinds": [
          "remote"
        ]
      },
      "reverseWheel": {
        "type": "boolean",
        "default": false,
        "title": "Reverse the wheel",
        "description": "Turning the other way brightens",
        "x-kinds": [
          "remote"
        ]
      },
      "powerDelay": {
        "type": "integer",
        "minimum": 1,
        "maximum": 30,
        "default": 5,
        "title": "Wait after power on",
        "description": "Seconds the lights take to come back once their switch is on, before the wheel sets them",
        "x-kinds": [
          "remote"
        ]
      }
    }
  },
  "layout": [
    {
      "type": "fieldset",
      "title": "Channel 1",
      "items": [
        "light1",
        "power1",
        "double1",
        "hold1",
        "long1"
      ]
    },
    {
      "type": "fieldset",
      "title": "Channel 2",
      "items": [
        "light2",
        "power2",
        "double2",
        "hold2",
        "long2"
      ]
    },
    {
      "type": "fieldset",
      "title": "Channel 3",
      "items": [
        "light3",
        "power3",
        "double3",
        "hold3",
        "long3"
      ]
    },
    {
      "type": "fieldset",
      "title": "Channel 4",
      "items": [
        "light4",
        "power4",
        "double4",
        "hold4",
        "long4"
      ]
    },
    {
      "type": "fieldset",
      "title": "Wheel",
      "items": [
        "dimStep",
        "reverseWheel",
        "powerDelay"
      ]
    }
  ],
  "i18n": {
    "fr": {
      "Name": "Nom",
      "Matter devices another app already has, controlled by Homeswift too. Add one from Add accessories with the pairing code that app shows when you turn on its pairing mode.": "Les appareils Matter qu'une autre app a déjà, contrôlés aussi par Homeswift. Ajoutez-en un depuis Ajouter des accessoires avec le code d'appairage que cette app affiche quand vous activez son mode d'appairage.",
      "Brightness per notch": "Luminosité par cran",
      "Percent of brightness one notch of the wheel moves the light": "Pourcentage de luminosité dont un cran de la molette change la lampe",
      "Reverse the wheel": "Inverser la molette",
      "Turning the other way brightens": "Tourner dans l'autre sens augmente la luminosité",
      "Plugin name as shown in the logs": "Nom du plugin tel qu'affiché dans les journaux",
      "Channel 1 power": "Alimentation du canal 1",
      "Channel 2 power": "Alimentation du canal 2",
      "Channel 3 power": "Alimentation du canal 3",
      "Channel 4 power": "Alimentation du canal 4",
      "Wait after power on": "Attente après l'allumage",
      "Seconds the lights take to come back once their switch is on, before the wheel sets them": "Secondes que mettent les lampes à revenir une fois leur interrupteur allumé, avant que la molette les règle",
      "The switches that power the channel's lights (relays, such as eWeLink's), switched together: the button switches them, turning up switches them on first, and turning down past the lowest brightness switches them off": "Les interrupteurs qui alimentent les lampes du canal (des relais, comme ceux d'eWeLink), commandés ensemble : le bouton les commande, monter les allume d'abord, et descendre sous la luminosité la plus basse les éteint",
      "The switches that power the second channel's lights": "Les interrupteurs qui alimentent les lampes du deuxième canal",
      "The switches that power the third channel's lights": "Les interrupteurs qui alimentent les lampes du troisième canal",
      "The switches that power the fourth channel's lights": "Les interrupteurs qui alimentent les lampes du quatrième canal",
      "Channel 1": "Canal 1",
      "Channel 2": "Canal 2",
      "Channel 3": "Canal 3",
      "Channel 4": "Canal 4",
      "Wheel": "Molette",
      "Channel 1 controls": "Le canal 1 commande",
      "Channel 2 controls": "Le canal 2 commande",
      "Channel 3 controls": "Le canal 3 commande",
      "Channel 4 controls": "Le canal 4 commande",
      "The lights the remote's first wheel or rocker channel dims together and the shutters it moves, a step per notch; its button switches the lights, and opens, closes or stops the shutters": "Les lampes que le premier canal de molette ou de bascule de la télécommande règle ensemble et les volets qu'il déplace, d'un pas par cran ; son bouton allume et éteint les lampes, et ouvre, ferme ou arrête les volets",
      "The lights the second channel dims and the shutters it moves": "Les lampes que le deuxième canal règle et les volets qu'il déplace",
      "The lights the third channel dims and the shutters it moves": "Les lampes que le troisième canal règle et les volets qu'il déplace",
      "The lights the fourth channel dims and the shutters it moves": "Les lampes que le quatrième canal règle et les volets qu'il déplace",
      "Double press runs": "Le double appui lance",
      "Long press runs": "Un appui long lance",
      "A scene the channel's button runs on a double press": "Une scène que le bouton du canal lance sur un double appui",
      "A scene the channel's button runs when held": "Une scène que le bouton du canal lance quand il est maintenu",
      "Holding the button": "Maintenir le bouton",
      "What the channel's button does while held: runs the long press's scene, or dims the lights until let go": "Ce que fait le bouton du canal tant qu'il est maintenu : lancer la scène de l'appui long, ou régler les lampes jusqu'à ce qu'il soit relâché",
      "Runs the long press's scene": "Lance la scène de l'appui long",
      "Brightens, then dims, in turn": "Augmente, puis baisse, tour à tour",
      "Brightens": "Augmente",
      "Dims": "Baisse",
      "Opens, then closes, in turn": "Ouvre, puis ferme, tour à tour",
      "Opens": "Ouvre",
      "Closes": "Ferme",
      "Brightens and opens, then dims and closes, in turn": "Augmente et ouvre, puis baisse et ferme, tour à tour",
      "Brightens and opens": "Augmente et ouvre",
      "Dims and closes": "Baisse et ferme",
      "Position per notch": "Position par cran",
      "Percent of position one notch of the wheel moves the shutters": "Pourcentage de position dont un cran de la molette déplace les volets",
      "Step per notch": "Pas par cran",
      "Percent one notch of the wheel moves a light's brightness or a shutter's position": "Pourcentage dont un cran de la molette change la luminosité d'une lampe ou la position d'un volet",
      "Turning the other way opens": "Tourner dans l'autre sens ouvre",
      "Turning the other way brightens and opens": "Tourner dans l'autre sens augmente la luminosité et ouvre",
      "What the channel's button does while held: runs the long press's scene, or moves the shutters until let go": "Ce que fait le bouton du canal tant qu'il est maintenu : lancer la scène de l'appui long, ou déplacer les volets jusqu'à ce qu'il soit relâché",
      "What the channel's button does while held: runs the long press's scene, or dims the lights and moves the shutters until let go": "Ce que fait le bouton du canal tant qu'il est maintenu : lancer la scène de l'appui long, ou régler les lampes et déplacer les volets jusqu'à ce qu'il soit relâché"
    },
    "es": {
      "Name": "Nombre",
      "Matter devices another app already has, controlled by Homeswift too. Add one from Add accessories with the pairing code that app shows when you turn on its pairing mode.": "Dispositivos Matter que ya tiene otra app, controlados también por Homeswift. Añade uno desde Añadir accesorios con el código de vinculación que esa app muestra al activar su modo de vinculación.",
      "Brightness per notch": "Brillo por muesca",
      "Percent of brightness one notch of the wheel moves the light": "Porcentaje de brillo que una muesca de la rueda cambia en la luz",
      "Reverse the wheel": "Invertir la rueda",
      "Turning the other way brightens": "Girar en el otro sentido aumenta el brillo",
      "Plugin name as shown in the logs": "Nombre del plugin tal como aparece en los registros",
      "Channel 1 power": "Alimentación del canal 1",
      "Channel 2 power": "Alimentación del canal 2",
      "Channel 3 power": "Alimentación del canal 3",
      "Channel 4 power": "Alimentación del canal 4",
      "Wait after power on": "Espera tras encender",
      "Seconds the lights take to come back once their switch is on, before the wheel sets them": "Segundos que tardan las luces en volver una vez encendido su interruptor, antes de que la rueda las regule",
      "The switches that power the channel's lights (relays, such as eWeLink's), switched together: the button switches them, turning up switches them on first, and turning down past the lowest brightness switches them off": "Los interruptores que alimentan las luces del canal (relés, como los de eWeLink), accionados juntos: el botón los acciona, subir los enciende primero y bajar por debajo del brillo mínimo los apaga",
      "The switches that power the second channel's lights": "Los interruptores que alimentan las luces del segundo canal",
      "The switches that power the third channel's lights": "Los interruptores que alimentan las luces del tercer canal",
      "The switches that power the fourth channel's lights": "Los interruptores que alimentan las luces del cuarto canal",
      "Channel 1": "Canal 1",
      "Channel 2": "Canal 2",
      "Channel 3": "Canal 3",
      "Channel 4": "Canal 4",
      "Wheel": "Rueda",
      "Channel 1 controls": "El canal 1 controla",
      "Channel 2 controls": "El canal 2 controla",
      "Channel 3 controls": "El canal 3 controla",
      "Channel 4 controls": "El canal 4 controla",
      "The lights the remote's first wheel or rocker channel dims together and the shutters it moves, a step per notch; its button switches the lights, and opens, closes or stops the shutters": "Las luces que el primer canal de rueda o balancín del mando regula juntas y las persianas que mueve, un paso por muesca; su botón enciende y apaga las luces, y abre, cierra o detiene las persianas",
      "The lights the second channel dims and the shutters it moves": "Las luces que regula el segundo canal y las persianas que mueve",
      "The lights the third channel dims and the shutters it moves": "Las luces que regula el tercer canal y las persianas que mueve",
      "The lights the fourth channel dims and the shutters it moves": "Las luces que regula el cuarto canal y las persianas que mueve",
      "Double press runs": "La doble pulsación ejecuta",
      "Long press runs": "La pulsación larga ejecuta",
      "A scene the channel's button runs on a double press": "Una escena que el botón del canal ejecuta con una doble pulsación",
      "A scene the channel's button runs when held": "Una escena que el botón del canal ejecuta al mantenerlo pulsado",
      "Holding the button": "Mantener el botón",
      "What the channel's button does while held: runs the long press's scene, or dims the lights until let go": "Lo que hace el botón del canal mientras se mantiene: ejecutar la escena de la pulsación larga, o regular las luces hasta soltarlo",
      "Runs the long press's scene": "Ejecuta la escena de la pulsación larga",
      "Brightens, then dims, in turn": "Sube y luego baja, por turnos",
      "Brightens": "Sube",
      "Dims": "Baja",
      "Opens, then closes, in turn": "Abre y luego cierra, por turnos",
      "Opens": "Abre",
      "Closes": "Cierra",
      "Brightens and opens, then dims and closes, in turn": "Sube y abre, luego baja y cierra, por turnos",
      "Brightens and opens": "Sube y abre",
      "Dims and closes": "Baja y cierra",
      "Position per notch": "Posición por muesca",
      "Percent of position one notch of the wheel moves the shutters": "Porcentaje de posición que una muesca de la rueda mueve las persianas",
      "Step per notch": "Paso por muesca",
      "Percent one notch of the wheel moves a light's brightness or a shutter's position": "Porcentaje que una muesca de la rueda cambia el brillo de una luz o la posición de una persiana",
      "Turning the other way opens": "Girar en el otro sentido abre",
      "Turning the other way brightens and opens": "Girar en el otro sentido sube el brillo y abre",
      "What the channel's button does while held: runs the long press's scene, or moves the shutters until let go": "Lo que hace el botón del canal mientras se mantiene: ejecutar la escena de la pulsación larga, o mover las persianas hasta soltarlo",
      "What the channel's button does while held: runs the long press's scene, or dims the lights and moves the shutters until let go": "Lo que hace el botón del canal mientras se mantiene: ejecutar la escena de la pulsación larga, o regular las luces y mover las persianas hasta soltarlo"
    },
    "pt": {
      "Name": "Nome",
      "Matter devices another app already has, controlled by Homeswift too. Add one from Add accessories with the pairing code that app shows when you turn on its pairing mode.": "Dispositivos Matter que outra app já tem, controlados também pelo Homeswift. Adicione um em Adicionar acessórios com o código de emparelhamento que essa app mostra quando ativa o modo de emparelhamento.",
      "Brightness per notch": "Brilho por entalhe",
      "Percent of brightness one notch of the wheel moves the light": "Percentagem de brilho que um entalhe da roda muda na luz",
      "Reverse the wheel": "Inverter a roda",
      "Turning the other way brightens": "Rodar no outro sentido aumenta o brilho",
      "Plugin name as shown in the logs": "Nome do plugin tal como aparece nos registos",
      "Channel 1 power": "Alimentação do canal 1",
      "Channel 2 power": "Alimentação do canal 2",
      "Channel 3 power": "Alimentação do canal 3",
      "Channel 4 power": "Alimentação do canal 4",
      "Wait after power on": "Espera após ligar",
      "Seconds the lights take to come back once their switch is on, before the wheel sets them": "Segundos que as luzes demoram a voltar depois de o interruptor ligar, antes de a roda as regular",
      "The switches that power the channel's lights (relays, such as eWeLink's), switched together: the button switches them, turning up switches them on first, and turning down past the lowest brightness switches them off": "Os interruptores que alimentam as luzes do canal (relés, como os da eWeLink), acionados em conjunto: o botão aciona-os, subir liga-os primeiro e descer abaixo do brilho mínimo desliga-os",
      "The switches that power the second channel's lights": "Os interruptores que alimentam as luzes do segundo canal",
      "The switches that power the third channel's lights": "Os interruptores que alimentam as luzes do terceiro canal",
      "The switches that power the fourth channel's lights": "Os interruptores que alimentam as luzes do quarto canal",
      "Channel 1": "Canal 1",
      "Channel 2": "Canal 2",
      "Channel 3": "Canal 3",
      "Channel 4": "Canal 4",
      "Wheel": "Roda",
      "Channel 1 controls": "O canal 1 controla",
      "Channel 2 controls": "O canal 2 controla",
      "Channel 3 controls": "O canal 3 controla",
      "Channel 4 controls": "O canal 4 controla",
      "The lights the remote's first wheel or rocker channel dims together and the shutters it moves, a step per notch; its button switches the lights, and opens, closes or stops the shutters": "As luzes que o primeiro canal de roda ou basculante do comando regula em conjunto e os estores que move, um passo por entalhe; o seu botão liga e desliga as luzes, e abre, fecha ou para os estores",
      "The lights the second channel dims and the shutters it moves": "As luzes que o segundo canal regula e os estores que move",
      "The lights the third channel dims and the shutters it moves": "As luzes que o terceiro canal regula e os estores que move",
      "The lights the fourth channel dims and the shutters it moves": "As luzes que o quarto canal regula e os estores que move",
      "Double press runs": "A pressão dupla executa",
      "Long press runs": "A pressão longa executa",
      "A scene the channel's button runs on a double press": "Uma cena que o botão do canal executa com uma pressão dupla",
      "A scene the channel's button runs when held": "Uma cena que o botão do canal executa quando mantido premido",
      "Holding the button": "Manter o botão",
      "What the channel's button does while held: runs the long press's scene, or dims the lights until let go": "O que o botão do canal faz enquanto mantido: executar a cena da pressão longa, ou regular as luzes até ser largado",
      "Runs the long press's scene": "Executa a cena da pressão longa",
      "Brightens, then dims, in turn": "Aumenta e depois diminui, alternadamente",
      "Brightens": "Aumenta",
      "Dims": "Diminui",
      "Opens, then closes, in turn": "Abre e depois fecha, alternadamente",
      "Opens": "Abre",
      "Closes": "Fecha",
      "Brightens and opens, then dims and closes, in turn": "Aumenta e abre, depois diminui e fecha, alternadamente",
      "Brightens and opens": "Aumenta e abre",
      "Dims and closes": "Diminui e fecha",
      "Position per notch": "Posição por entalhe",
      "Percent of position one notch of the wheel moves the shutters": "Percentagem de posição que um entalhe da roda move os estores",
      "Step per notch": "Passo por entalhe",
      "Percent one notch of the wheel moves a light's brightness or a shutter's position": "Percentagem que um entalhe da roda muda o brilho de uma luz ou a posição de um estore",
      "Turning the other way opens": "Rodar no outro sentido abre",
      "Turning the other way brightens and opens": "Rodar no outro sentido aumenta o brilho e abre",
      "What the channel's button does while held: runs the long press's scene, or moves the shutters until let go": "O que o botão do canal faz enquanto mantido: executar a cena da pressão longa, ou mover os estores até ser largado",
      "What the channel's button does while held: runs the long press's scene, or dims the lights and moves the shutters until let go": "O que o botão do canal faz enquanto mantido: executar a cena da pressão longa, ou regular as luzes e mover os estores até ser largado"
    }
  }
}
"""#
}
