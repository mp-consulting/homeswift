// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension MagicHomePlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "homebridge-magichome-dynamic-platform",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "default": "Magic Home",
        "description": "The name of this plugin's instance in the logs."
      },
      "addresses": {
        "title": "Devices by address",
        "type": "array",
        "description": "Devices the broadcast does not reach, for example on another network: each address gets the discovery probe directly. Every device the broadcast finds is added without an entry here.",
        "items": {
          "title": "IP address",
          "type": "string",
          "description": "Where the device answers, for example 192.168.1.50."
        }
      },
      "pruning": {
        "title": "Pruning",
        "type": "object",
        "description": "When accessories of devices that no longer answer leave the bridge.",
        "properties": {
          "pruneMissingCachedAccessories": {
            "title": "Remove missing accessories",
            "type": "boolean",
            "default": false,
            "description": "Removes the accessory of a device not heard for the number of restarts below."
          },
          "restartsBeforeMissingAccessoriesPruned": {
            "title": "Restarts before removing",
            "type": "integer",
            "default": 3,
            "minimum": 1,
            "description": "How many restarts a device may go unheard before its accessory is removed."
          },
          "pruneAllAccessoriesNextRestart": {
            "title": "Remove every accessory at the next restart",
            "type": "boolean",
            "default": false,
            "description": "Removes all of this plugin's accessories once, then adds the devices found again: turn it off afterwards. HomeKit loses their rooms, scenes and automations."
          }
        }
      },
      "whiteEffects": {
        "title": "White and colour",
        "type": "object",
        "description": "When a colour set in HomeKit lights the white LEDs instead, by its saturation.",
        "properties": {
          "simultaniousDevicesColorWhite": {
            "title": "Mix colour and white",
            "type": "boolean",
            "default": true,
            "description": "Lets controllers that drive colour and white LEDs together light both for pale colours."
          },
          "colorWhiteThreshold": {
            "title": "White below (saturation %)",
            "type": "integer",
            "default": 10,
            "minimum": 0,
            "maximum": 100,
            "description": "Below this saturation a bulb that shows colour or white shows white."
          },
          "colorWhiteThresholdSimultaniousDevices": {
            "title": "Mix below (saturation %)",
            "type": "integer",
            "default": 50,
            "minimum": 0,
            "maximum": 100,
            "description": "Below this saturation a controller that drives both mixes the colour with white."
          },
          "colorOffThresholdSimultaniousDevices": {
            "title": "White only below (saturation %)",
            "type": "integer",
            "default": 5,
            "minimum": 0,
            "maximum": 100,
            "description": "Below this saturation a controller that drives both shows white only."
          }
        }
      },
      "deviceManagement": {
        "title": "Device list",
        "type": "object",
        "description": "Devices left out, or the only ones let in, by MAC address. Excluding a device in its settings does the same.",
        "properties": {
          "blacklistOrWhitelist": {
            "title": "The list is",
            "type": "string",
            "default": "blacklist",
            "oneOf": [
              {
                "title": "Devices to leave out",
                "enum": [
                  "blacklist"
                ]
              },
              {
                "title": "The only devices to add",
                "enum": [
                  "whitelist"
                ]
              }
            ],
            "description": "Whether the MAC addresses below are left out or the only ones added."
          },
          "blacklistedUniqueIDs": {
            "title": "MAC addresses",
            "type": "array",
            "description": "Each device's MAC address, 12 hexadecimal digits as the scan reports it (6001940EDC1F).",
            "items": {
              "title": "MAC address",
              "type": "string",
              "description": "12 hexadecimal digits."
            }
          }
        }
      },
      "advancedOptions": {
        "title": "Advanced",
        "type": "object",
        "description": "Discovery, names and the log.",
        "properties": {
          "periodicDiscovery": {
            "title": "Look for devices every 30 seconds",
            "type": "boolean",
            "default": true,
            "description": "Finds new devices and those that changed address without a restart."
          },
          "namesWithMacAddress": {
            "title": "Name new devices by their MAC address",
            "type": "boolean",
            "default": false,
            "description": "Bulb A1B2C3 rather than the type of the device, for devices added from now on."
          },
          "logLevel": {
            "title": "Log level",
            "type": "integer",
            "default": 3,
            "oneOf": [
              {
                "title": "Errors",
                "enum": [
                  1
                ]
              },
              {
                "title": "Warnings",
                "enum": [
                  2
                ]
              },
              {
                "title": "Information",
                "enum": [
                  3
                ]
              },
              {
                "title": "Debug",
                "enum": [
                  4
                ]
              },
              {
                "title": "Trace",
                "enum": [
                  5
                ]
              }
            ],
            "description": "What the plugin writes to the log; Debug and Trace include addresses and the bytes sent."
          },
          "additionalSubnets": {
            "title": "More broadcast addresses",
            "type": "array",
            "description": "Broadcast addresses of other networks the scan also covers, for example 192.168.2.255.",
            "items": {
              "title": "Broadcast address",
              "type": "string",
              "description": "An IPv4 address."
            }
          }
        }
      }
    }
  },
  "accessorySchema": {
    "properties": {}
  },
  "layout": [
    "name",
    "addresses",
    {
      "type": "fieldset",
      "title": "White and colour",
      "expandable": true,
      "expanded": false,
      "items": [
        "whiteEffects.simultaniousDevicesColorWhite",
        "whiteEffects.colorWhiteThreshold",
        "whiteEffects.colorWhiteThresholdSimultaniousDevices",
        "whiteEffects.colorOffThresholdSimultaniousDevices"
      ]
    },
    {
      "type": "fieldset",
      "title": "Device list",
      "expandable": true,
      "expanded": false,
      "items": [
        "deviceManagement.blacklistOrWhitelist",
        "deviceManagement.blacklistedUniqueIDs"
      ]
    },
    {
      "type": "fieldset",
      "title": "Pruning",
      "expandable": true,
      "expanded": false,
      "items": [
        "pruning.pruneMissingCachedAccessories",
        "pruning.restartsBeforeMissingAccessoriesPruned",
        "pruning.pruneAllAccessoriesNextRestart"
      ]
    },
    {
      "type": "fieldset",
      "title": "Advanced",
      "expandable": true,
      "expanded": false,
      "items": [
        "advancedOptions.periodicDiscovery",
        "advancedOptions.namesWithMacAddress",
        "advancedOptions.logLevel",
        "advancedOptions.additionalSubnets"
      ]
    }
  ],
  "i18n": {
    "fr": {
      "12 hexadecimal digits.": "12 chiffres hexadécimaux.",
      "Advanced": "Avancé",
      "An IPv4 address.": "Une adresse IPv4.",
      "Below this saturation a bulb that shows colour or white shows white.": "En dessous de cette saturation, une ampoule qui affiche la couleur ou le blanc affiche le blanc.",
      "Below this saturation a controller that drives both mixes the colour with white.": "En dessous de cette saturation, un contrôleur qui pilote les deux mélange la couleur avec du blanc.",
      "Below this saturation a controller that drives both shows white only.": "En dessous de cette saturation, un contrôleur qui pilote les deux n'affiche que du blanc.",
      "Broadcast address": "Adresse de diffusion",
      "Broadcast addresses of other networks the scan also covers, for example 192.168.2.255.": "Les adresses de diffusion d'autres réseaux que la découverte couvre aussi, par exemple 192.168.2.255.",
      "Bulb A1B2C3 rather than the type of the device, for devices added from now on.": "Bulb A1B2C3 plutôt que le type de l'appareil, pour les appareils ajoutés à partir de maintenant.",
      "Debug": "Débogage",
      "Device list": "Liste d'appareils",
      "Devices by address": "Appareils par adresse",
      "Devices left out, or the only ones let in, by MAC address. Excluding a device in its settings does the same.": "Les appareils laissés de côté, ou les seuls admis, par adresse MAC. Exclure un appareil dans ses réglages fait de même.",
      "Devices the broadcast does not reach, for example on another network: each address gets the discovery probe directly. Every device the broadcast finds is added without an entry here.": "Les appareils que la diffusion n'atteint pas, par exemple sur un autre réseau : chaque adresse reçoit directement la sonde de découverte. Tout appareil trouvé par la diffusion est ajouté sans entrée ici.",
      "Devices to leave out": "Les appareils à laisser de côté",
      "Discovery, names and the log.": "La découverte, les noms et le journal.",
      "Each device's MAC address, 12 hexadecimal digits as the scan reports it (6001940EDC1F).": "L'adresse MAC de chaque appareil, 12 chiffres hexadécimaux comme la découverte la donne (6001940EDC1F).",
      "Errors": "Erreurs",
      "Finds new devices and those that changed address without a restart.": "Trouve les nouveaux appareils et ceux qui ont changé d'adresse sans redémarrage.",
      "How many restarts a device may go unheard before its accessory is removed.": "Combien de redémarrages un appareil peut rester sans réponse avant que son accessoire soit retiré.",
      "IP address": "Adresse IP",
      "Information": "Informations",
      "Lets controllers that drive colour and white LEDs together light both for pale colours.": "Permet aux contrôleurs qui pilotent ensemble des LED de couleur et blanches d'allumer les deux pour les couleurs pâles.",
      "Log level": "Niveau du journal",
      "Look for devices every 30 seconds": "Chercher des appareils toutes les 30 secondes",
      "MAC address": "Adresse MAC",
      "MAC addresses": "Adresses MAC",
      "Mix below (saturation %)": "Mélange en dessous de (saturation %)",
      "Mix colour and white": "Mélanger couleur et blanc",
      "More broadcast addresses": "Autres adresses de diffusion",
      "Name": "Nom",
      "Name new devices by their MAC address": "Nommer les nouveaux appareils d'après leur adresse MAC",
      "Pruning": "Nettoyage",
      "Remove every accessory at the next restart": "Retirer tous les accessoires au prochain redémarrage",
      "Remove missing accessories": "Retirer les accessoires absents",
      "Removes all of this plugin's accessories once, then adds the devices found again: turn it off afterwards. HomeKit loses their rooms, scenes and automations.": "Retire une fois tous les accessoires de ce plugin, puis ajoute à nouveau les appareils trouvés : désactivez-le ensuite. HomeKit perd leurs pièces, scènes et automatisations.",
      "Removes the accessory of a device not heard for the number of restarts below.": "Retire l'accessoire d'un appareil qui n'a pas été entendu pendant le nombre de redémarrages ci-dessous.",
      "Restarts before removing": "Redémarrages avant le retrait",
      "The list is": "La liste est",
      "The name of this plugin's instance in the logs.": "Le nom de cette instance du plugin dans les journaux.",
      "The only devices to add": "Les seuls appareils à ajouter",
      "Trace": "Trace",
      "Warnings": "Avertissements",
      "What the plugin writes to the log; Debug and Trace include addresses and the bytes sent.": "Ce que le plugin écrit dans le journal ; Débogage et Trace incluent les adresses et les octets envoyés.",
      "When a colour set in HomeKit lights the white LEDs instead, by its saturation.": "Quand une couleur choisie dans HomeKit allume plutôt les LED blanches, selon sa saturation.",
      "When accessories of devices that no longer answer leave the bridge.": "Quand les accessoires des appareils qui ne répondent plus quittent le pont.",
      "Where the device answers, for example 192.168.1.50.": "Là où l'appareil répond, par exemple 192.168.1.50.",
      "Whether the MAC addresses below are left out or the only ones added.": "Si les adresses MAC ci-dessous sont laissées de côté ou les seules ajoutées.",
      "White and colour": "Blanc et couleur",
      "White below (saturation %)": "Blanc en dessous de (saturation %)",
      "White only below (saturation %)": "Blanc seul en dessous de (saturation %)"
    },
    "es": {
      "12 hexadecimal digits.": "12 dígitos hexadecimales.",
      "Advanced": "Avanzado",
      "An IPv4 address.": "Una dirección IPv4.",
      "Below this saturation a bulb that shows colour or white shows white.": "Por debajo de esta saturación, una bombilla que muestra color o blanco muestra blanco.",
      "Below this saturation a controller that drives both mixes the colour with white.": "Por debajo de esta saturación, un controlador que maneja ambos mezcla el color con blanco.",
      "Below this saturation a controller that drives both shows white only.": "Por debajo de esta saturación, un controlador que maneja ambos muestra solo blanco.",
      "Broadcast address": "Dirección de difusión",
      "Broadcast addresses of other networks the scan also covers, for example 192.168.2.255.": "Las direcciones de difusión de otras redes que el descubrimiento también cubre, por ejemplo 192.168.2.255.",
      "Bulb A1B2C3 rather than the type of the device, for devices added from now on.": "Bulb A1B2C3 en lugar del tipo del dispositivo, para los dispositivos añadidos a partir de ahora.",
      "Debug": "Depuración",
      "Device list": "Lista de dispositivos",
      "Devices by address": "Dispositivos por dirección",
      "Devices left out, or the only ones let in, by MAC address. Excluding a device in its settings does the same.": "Los dispositivos que se dejan fuera, o los únicos admitidos, por dirección MAC. Excluir un dispositivo en sus ajustes hace lo mismo.",
      "Devices the broadcast does not reach, for example on another network: each address gets the discovery probe directly. Every device the broadcast finds is added without an entry here.": "Los dispositivos a los que no llega la difusión, por ejemplo en otra red: cada dirección recibe directamente la sonda de descubrimiento. Todo dispositivo que encuentra la difusión se añade sin una entrada aquí.",
      "Devices to leave out": "Los dispositivos que se dejan fuera",
      "Discovery, names and the log.": "El descubrimiento, los nombres y el registro.",
      "Each device's MAC address, 12 hexadecimal digits as the scan reports it (6001940EDC1F).": "La dirección MAC de cada dispositivo, 12 dígitos hexadecimales como la da el descubrimiento (6001940EDC1F).",
      "Errors": "Errores",
      "Finds new devices and those that changed address without a restart.": "Encuentra los dispositivos nuevos y los que cambiaron de dirección sin reiniciar.",
      "How many restarts a device may go unheard before its accessory is removed.": "Cuántos reinicios puede pasar un dispositivo sin oírse antes de quitar su accesorio.",
      "IP address": "Dirección IP",
      "Information": "Información",
      "Lets controllers that drive colour and white LEDs together light both for pale colours.": "Permite a los controladores que manejan juntos LED de color y blancos encender ambos para los colores pálidos.",
      "Log level": "Nivel del registro",
      "Look for devices every 30 seconds": "Buscar dispositivos cada 30 segundos",
      "MAC address": "Dirección MAC",
      "MAC addresses": "Direcciones MAC",
      "Mix below (saturation %)": "Mezcla por debajo de (saturación %)",
      "Mix colour and white": "Mezclar color y blanco",
      "More broadcast addresses": "Más direcciones de difusión",
      "Name": "Nombre",
      "Name new devices by their MAC address": "Nombrar los dispositivos nuevos por su dirección MAC",
      "Pruning": "Limpieza",
      "Remove every accessory at the next restart": "Quitar todos los accesorios en el próximo reinicio",
      "Remove missing accessories": "Quitar los accesorios ausentes",
      "Removes all of this plugin's accessories once, then adds the devices found again: turn it off afterwards. HomeKit loses their rooms, scenes and automations.": "Quita una vez todos los accesorios de este plugin y luego vuelve a añadir los dispositivos encontrados: desactívelo después. HomeKit pierde sus habitaciones, escenas y automatizaciones.",
      "Removes the accessory of a device not heard for the number of restarts below.": "Quita el accesorio de un dispositivo que no se ha oído durante el número de reinicios de abajo.",
      "Restarts before removing": "Reinicios antes de quitar",
      "The list is": "La lista es",
      "The name of this plugin's instance in the logs.": "El nombre de esta instancia del plugin en los registros.",
      "The only devices to add": "Los únicos dispositivos que se añaden",
      "Trace": "Traza",
      "Warnings": "Advertencias",
      "What the plugin writes to the log; Debug and Trace include addresses and the bytes sent.": "Lo que el plugin escribe en el registro; Depuración y Traza incluyen las direcciones y los bytes enviados.",
      "When a colour set in HomeKit lights the white LEDs instead, by its saturation.": "Cuándo un color elegido en HomeKit enciende en su lugar los LED blancos, según su saturación.",
      "When accessories of devices that no longer answer leave the bridge.": "Cuándo los accesorios de los dispositivos que ya no responden salen del puente.",
      "Where the device answers, for example 192.168.1.50.": "Donde responde el dispositivo, por ejemplo 192.168.1.50.",
      "Whether the MAC addresses below are left out or the only ones added.": "Si las direcciones MAC de abajo se dejan fuera o son las únicas que se añaden.",
      "White and colour": "Blanco y color",
      "White below (saturation %)": "Blanco por debajo de (saturación %)",
      "White only below (saturation %)": "Solo blanco por debajo de (saturación %)"
    },
    "pt": {
      "12 hexadecimal digits.": "12 dígitos hexadecimais.",
      "Advanced": "Avançado",
      "An IPv4 address.": "Um endereço IPv4.",
      "Below this saturation a bulb that shows colour or white shows white.": "Abaixo desta saturação, uma lâmpada que mostra cor ou branco mostra branco.",
      "Below this saturation a controller that drives both mixes the colour with white.": "Abaixo desta saturação, um controlador que comanda ambos mistura a cor com branco.",
      "Below this saturation a controller that drives both shows white only.": "Abaixo desta saturação, um controlador que comanda ambos mostra só branco.",
      "Broadcast address": "Endereço de difusão",
      "Broadcast addresses of other networks the scan also covers, for example 192.168.2.255.": "Os endereços de difusão de outras redes que a descoberta também cobre, por exemplo 192.168.2.255.",
      "Bulb A1B2C3 rather than the type of the device, for devices added from now on.": "Bulb A1B2C3 em vez do tipo do dispositivo, para os dispositivos adicionados a partir de agora.",
      "Debug": "Depuração",
      "Device list": "Lista de dispositivos",
      "Devices by address": "Dispositivos por endereço",
      "Devices left out, or the only ones let in, by MAC address. Excluding a device in its settings does the same.": "Os dispositivos deixados de fora, ou os únicos admitidos, por endereço MAC. Excluir um dispositivo nas suas definições faz o mesmo.",
      "Devices the broadcast does not reach, for example on another network: each address gets the discovery probe directly. Every device the broadcast finds is added without an entry here.": "Os dispositivos que a difusão não alcança, por exemplo noutra rede: cada endereço recebe diretamente a sonda de descoberta. Todos os dispositivos que a difusão encontra são adicionados sem uma entrada aqui.",
      "Devices to leave out": "Os dispositivos a deixar de fora",
      "Discovery, names and the log.": "A descoberta, os nomes e o registo.",
      "Each device's MAC address, 12 hexadecimal digits as the scan reports it (6001940EDC1F).": "O endereço MAC de cada dispositivo, 12 dígitos hexadecimais como a descoberta o indica (6001940EDC1F).",
      "Errors": "Erros",
      "Finds new devices and those that changed address without a restart.": "Encontra os dispositivos novos e os que mudaram de endereço sem reiniciar.",
      "How many restarts a device may go unheard before its accessory is removed.": "Quantos reinícios um dispositivo pode passar sem ser ouvido antes de o seu acessório ser removido.",
      "IP address": "Endereço IP",
      "Information": "Informações",
      "Lets controllers that drive colour and white LEDs together light both for pale colours.": "Permite aos controladores que comandam em conjunto LED de cor e brancos acender ambos nas cores pálidas.",
      "Log level": "Nível do registo",
      "Look for devices every 30 seconds": "Procurar dispositivos a cada 30 segundos",
      "MAC address": "Endereço MAC",
      "MAC addresses": "Endereços MAC",
      "Mix below (saturation %)": "Mistura abaixo de (saturação %)",
      "Mix colour and white": "Misturar cor e branco",
      "More broadcast addresses": "Mais endereços de difusão",
      "Name": "Nome",
      "Name new devices by their MAC address": "Nomear os dispositivos novos pelo seu endereço MAC",
      "Pruning": "Limpeza",
      "Remove every accessory at the next restart": "Remover todos os acessórios no próximo reinício",
      "Remove missing accessories": "Remover os acessórios ausentes",
      "Removes all of this plugin's accessories once, then adds the devices found again: turn it off afterwards. HomeKit loses their rooms, scenes and automations.": "Remove uma vez todos os acessórios deste plugin e depois volta a adicionar os dispositivos encontrados: desative-o a seguir. O HomeKit perde as suas divisões, cenas e automatizações.",
      "Removes the accessory of a device not heard for the number of restarts below.": "Remove o acessório de um dispositivo que não foi ouvido durante o número de reinícios abaixo.",
      "Restarts before removing": "Reinícios antes de remover",
      "The list is": "A lista é",
      "The name of this plugin's instance in the logs.": "O nome desta instância do plugin nos registos.",
      "The only devices to add": "Os únicos dispositivos a adicionar",
      "Trace": "Rastreio",
      "Warnings": "Avisos",
      "What the plugin writes to the log; Debug and Trace include addresses and the bytes sent.": "O que o plugin escreve no registo; Depuração e Rastreio incluem os endereços e os bytes enviados.",
      "When a colour set in HomeKit lights the white LEDs instead, by its saturation.": "Quando uma cor escolhida no HomeKit acende antes os LED brancos, conforme a sua saturação.",
      "When accessories of devices that no longer answer leave the bridge.": "Quando os acessórios dos dispositivos que já não respondem saem da ponte.",
      "Where the device answers, for example 192.168.1.50.": "Onde o dispositivo responde, por exemplo 192.168.1.50.",
      "Whether the MAC addresses below are left out or the only ones added.": "Se os endereços MAC abaixo são deixados de fora ou os únicos adicionados.",
      "White and colour": "Branco e cor",
      "White below (saturation %)": "Branco abaixo de (saturação %)",
      "White only below (saturation %)": "Só branco abaixo de (saturação %)"
    }
  }
}
"""#
}
