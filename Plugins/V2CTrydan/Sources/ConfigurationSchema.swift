// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension V2CTrydanPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "V2CTrydan",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "default": "V2C Trydan",
        "description": "Plugin name as shown in the logs"
      },
      "pollingInterval": {
        "title": "Polling Interval (in seconds)",
        "type": "integer",
        "required": false,
        "placeholder": 10,
        "minimum": 5,
        "description": "How often each charger is asked for its values. 5 seconds at least."
      },
      "timeout": {
        "title": "Timeout (in seconds)",
        "type": "integer",
        "required": false,
        "placeholder": 5,
        "minimum": 1,
        "maximum": 60,
        "description": "How long a request to a charger waits for its answer."
      },
      "devices": {
        "title": "Chargers",
        "type": "array",
        "description": "Add a V2C Trydan by its address on the local network. Once it answers and the settings are saved, its address is with its accessory.",
        "items": {
          "title": "Charger",
          "type": "object",
          "properties": {
            "host": {
              "title": "Address",
              "type": "string",
              "required": true,
              "description": "The charger's IP address or host name on the local network, with :port when it is not 80."
            },
            "name": {
              "title": "Name",
              "type": "string",
              "required": false,
              "description": "The name in HomeKit; V2C Trydan when empty."
            }
          }
        }
      }
    }
  },
  "accessorySchema": {
    "properties": {
      "host": {
        "title": "Address",
        "type": "string",
        "description": "The charger's IP address or host name on the local network, with :port when it is not 80."
      },
      "exposeCurrent": {
        "title": "Charge current",
        "type": "boolean",
        "default": true,
        "description": "A fan whose speed is the current offered to the car, in amperes."
      },
      "exposeLock": {
        "title": "Lock",
        "type": "boolean",
        "default": true,
        "description": "A lock that disables the charger."
      },
      "exposeSensors": {
        "title": "Car connected",
        "type": "boolean",
        "default": true,
        "description": "A contact sensor that shows when a car is plugged in, and the charger's faults."
      },
      "exposeDynamic": {
        "title": "Timer and dynamic power",
        "type": "boolean",
        "default": false,
        "description": "Switches for the charge timer, dynamic power and its pause."
      },
      "exposeLeds": {
        "title": "LEDs",
        "type": "boolean",
        "default": false,
        "description": "The light ring and the logo as lights, when the firmware reports them."
      },
      "houseEnergyRole": {
        "title": "House power on the Energy page",
        "type": "string",
        "default": "none",
        "oneOf": [
          {
            "title": "Not counted",
            "enum": [
              "none"
            ]
          },
          {
            "title": "The home's use (the clamp measures the home)",
            "enum": [
              "home"
            ]
          },
          {
            "title": "The grid (the clamp is at the grid connection)",
            "enum": [
              "grid"
            ]
          }
        ],
        "description": "What the charger's meter clamp measures, for the Status page's Energy section. Leave it uncounted when another plugin reports it."
      },
      "solarEnergy": {
        "title": "Solar power on the Energy page",
        "type": "boolean",
        "default": false,
        "description": "Counts the solar power the charger's meter reads; leave it off when an inverter plugin reports it."
      },
      "exposeModes": {
        "title": "Dynamic power modes",
        "type": "boolean",
        "default": false,
        "description": "A switch for each dynamic power mode (timed, solar and minimum, solar only, solar and grid, stop): turning one on puts the charger in that mode, for scenes and automations."
      },
      "chargeMode": {
        "title": "Wiring",
        "type": "string",
        "oneOf": [
          { "title": "Single-phase", "enum": ["monophasic"] },
          { "title": "Three-phase", "enum": ["threephase"] },
          { "title": "Mixed", "enum": ["mixed"] }
        ],
        "description": "How the charger is wired (ChargeMode), sent to it once when it changes. Empty leaves the charger's: set it only to match the installation."
      },
      "minIntensity": {
        "title": "Minimum current (A)",
        "type": "integer",
        "minimum": 6,
        "maximum": 32,
        "description": "The lowest current the charger offers (MinIntensity), 6 to 32 A and not above the maximum, sent once when it changes. Empty leaves the charger's."
      },
      "maxIntensity": {
        "title": "Maximum current (A)",
        "type": "integer",
        "minimum": 6,
        "maximum": 32,
        "description": "The highest current the charger offers (MaxIntensity), 6 to 32 A, sent once when it changes. Never above what the installation's wiring and breaker take. Empty leaves the charger's."
      },
      "voltageInstallation": {
        "title": "Installation voltage (V)",
        "type": "integer",
        "minimum": 1,
        "maximum": 500,
        "description": "The installation's nominal voltage (VoltageInstallation), 1 to 500 V, sent once when it changes. Empty leaves the charger's."
      }
    }
  },
  "layout": [
    "name",
    {
      "type": "fieldset",
      "title": "Advanced",
      "expandable": true,
      "expanded": false,
      "items": [
        "pollingInterval",
        "timeout",
        "devices"
      ]
    }
  ],
  "i18n": {
    "fr": {
      "A contact sensor that shows when a car is plugged in, and the charger's faults.": "Un capteur de contact qui indique quand une voiture est branchée, et les défauts du chargeur.",
      "A fan whose speed is the current offered to the car, in amperes.": "Un ventilateur dont la vitesse est le courant offert à la voiture, en ampères.",
      "A lock that disables the charger.": "Un verrou qui désactive le chargeur.",
      "Add a V2C Trydan by its address on the local network. Once it answers and the settings are saved, its address is with its accessory.": "Ajoutez un V2C Trydan par son adresse sur le réseau local. Une fois qu’il a répondu et les réglages enregistrés, son adresse est avec son accessoire.",
      "Address": "Adresse",
      "Advanced": "Avancé",
      "Car connected": "Voiture branchée",
      "Charge current": "Courant de charge",
      "Charger": "Chargeur",
      "Chargers": "Chargeurs",
      "Counts the solar power the charger's meter reads; leave it off when an inverter plugin reports it.": "Compte la production solaire lue par le compteur du chargeur ; laissez-la désactivée quand un plugin d’onduleur l’indique.",
      "House power on the Energy page": "Consommation de la maison sur la page Énergie",
      "How long a request to a charger waits for its answer.": "Combien de temps une requête à un chargeur attend sa réponse.",
      "How often each charger is asked for its values. 5 seconds at least.": "À quelle fréquence chaque chargeur est interrogé sur ses valeurs. 5 secondes au minimum.",
      "LEDs": "LED",
      "Lock": "Verrou",
      "Name": "Nom",
      "Not counted": "Non comptée",
      "Plugin name as shown in the logs": "Nom du plugin tel qu’il apparaît dans les journaux",
      "Polling Interval (in seconds)": "Intervalle d’interrogation (en secondes)",
      "Solar power on the Energy page": "Production solaire sur la page Énergie",
      "Switches for the charge timer, dynamic power and its pause.": "Des interrupteurs pour la minuterie de charge, la puissance dynamique et sa pause.",
      "The charger's IP address or host name on the local network, with :port when it is not 80.": "L’adresse IP ou le nom d’hôte du chargeur sur le réseau local, avec :port s’il n’est pas 80.",
      "The grid (the clamp is at the grid connection)": "Le réseau (la pince est au raccordement)",
      "The home's use (the clamp measures the home)": "La consommation de la maison (la pince mesure la maison)",
      "The light ring and the logo as lights, when the firmware reports them.": "L’anneau lumineux et le logo comme des lumières, quand le firmware les indique.",
      "The name in HomeKit; V2C Trydan when empty.": "Le nom dans HomeKit ; V2C Trydan s’il est vide.",
      "Timeout (in seconds)": "Délai d’attente (en secondes)",
      "Timer and dynamic power": "Minuterie et puissance dynamique",
      "What the charger's meter clamp measures, for the Status page's Energy section. Leave it uncounted when another plugin reports it.": "Ce que mesure la pince du compteur du chargeur, pour la section Énergie de la page État. Laissez-la non comptée quand un autre plugin l’indique.",
      "Dynamic power modes": "Modes de puissance dynamique",
      "A switch for each dynamic power mode (timed, solar and minimum, solar only, solar and grid, stop): turning one on puts the charger in that mode, for scenes and automations.": "Un interrupteur par mode de puissance dynamique (programmé, solaire et minimum, solaire seul, solaire et réseau, arrêt) : en allumer un met la borne dans ce mode, pour les scènes et les automatisations.",
      "Wiring": "Câblage",
      "Single-phase": "Monophasé",
      "Three-phase": "Triphasé",
      "Mixed": "Mixte",
      "How the charger is wired (ChargeMode), sent to it once when it changes. Empty leaves the charger's: set it only to match the installation.": "Le câblage de la borne (ChargeMode), envoyé une fois quand il change. Vide garde celui de la borne : ne le réglez que pour suivre l'installation.",
      "Minimum current (A)": "Courant minimal (A)",
      "Maximum current (A)": "Courant maximal (A)",
      "Installation voltage (V)": "Tension de l'installation (V)",
      "The lowest current the charger offers (MinIntensity), 6 to 32 A and not above the maximum, sent once when it changes. Empty leaves the charger's.": "Le courant le plus bas que la borne propose (MinIntensity), de 6 à 32 A et pas au-dessus du maximum, envoyé une fois quand il change. Vide garde celui de la borne.",
      "The highest current the charger offers (MaxIntensity), 6 to 32 A, sent once when it changes. Never above what the installation's wiring and breaker take. Empty leaves the charger's.": "Le courant le plus haut que la borne propose (MaxIntensity), de 6 à 32 A, envoyé une fois quand il change. Jamais au-dessus de ce que supportent le câblage et le disjoncteur de l'installation. Vide garde celui de la borne.",
      "The installation's nominal voltage (VoltageInstallation), 1 to 500 V, sent once when it changes. Empty leaves the charger's.": "La tension nominale de l'installation (VoltageInstallation), de 1 à 500 V, envoyée une fois quand elle change. Vide garde celle de la borne."
    },
    "es": {
      "A contact sensor that shows when a car is plugged in, and the charger's faults.": "Un sensor de contacto que indica cuándo hay un coche enchufado, y los fallos del cargador.",
      "A fan whose speed is the current offered to the car, in amperes.": "Un ventilador cuya velocidad es la corriente ofrecida al coche, en amperios.",
      "A lock that disables the charger.": "Un cerrojo que desactiva el cargador.",
      "Add a V2C Trydan by its address on the local network. Once it answers and the settings are saved, its address is with its accessory.": "Añada un V2C Trydan por su dirección en la red local. Cuando responda y se guarden los ajustes, su dirección estará con su accesorio.",
      "Address": "Dirección",
      "Advanced": "Avanzado",
      "Car connected": "Coche conectado",
      "Charge current": "Corriente de carga",
      "Charger": "Cargador",
      "Chargers": "Cargadores",
      "Counts the solar power the charger's meter reads; leave it off when an inverter plugin reports it.": "Cuenta la producción solar que lee el contador del cargador; déjelo desactivado si un plugin de inversor la indica.",
      "House power on the Energy page": "Consumo de la casa en la página Energía",
      "How long a request to a charger waits for its answer.": "Cuánto espera una petición a un cargador su respuesta.",
      "How often each charger is asked for its values. 5 seconds at least.": "Con qué frecuencia se consulta a cada cargador. 5 segundos como mínimo.",
      "LEDs": "LED",
      "Lock": "Bloqueo",
      "Name": "Nombre",
      "Not counted": "No contado",
      "Plugin name as shown in the logs": "Nombre del plugin tal como aparece en los registros",
      "Polling Interval (in seconds)": "Intervalo de consulta (en segundos)",
      "Solar power on the Energy page": "Producción solar en la página Energía",
      "Switches for the charge timer, dynamic power and its pause.": "Interruptores para el temporizador de carga, la potencia dinámica y su pausa.",
      "The charger's IP address or host name on the local network, with :port when it is not 80.": "La dirección IP o el nombre de host del cargador en la red local, con :puerto si no es el 80.",
      "The grid (the clamp is at the grid connection)": "La red (la pinza está en la acometida)",
      "The home's use (the clamp measures the home)": "El consumo de la casa (la pinza mide la casa)",
      "The light ring and the logo as lights, when the firmware reports them.": "El anillo de luz y el logotipo como luces, cuando el firmware los indica.",
      "The name in HomeKit; V2C Trydan when empty.": "El nombre en HomeKit; V2C Trydan si está vacío.",
      "Timeout (in seconds)": "Tiempo de espera (en segundos)",
      "Timer and dynamic power": "Temporizador y potencia dinámica",
      "What the charger's meter clamp measures, for the Status page's Energy section. Leave it uncounted when another plugin reports it.": "Lo que mide la pinza del contador del cargador, para la sección Energía de la página Estado. Déjelo sin contar si otro plugin lo indica.",
      "Dynamic power modes": "Modos de potencia dinámica",
      "A switch for each dynamic power mode (timed, solar and minimum, solar only, solar and grid, stop): turning one on puts the charger in that mode, for scenes and automations.": "Un interruptor por modo de potencia dinámica (programado, solar y mínimo, solo solar, solar y red, parada): encender uno pone el cargador en ese modo, para escenas y automatizaciones.",
      "Wiring": "Cableado",
      "Single-phase": "Monofásico",
      "Three-phase": "Trifásico",
      "Mixed": "Mixto",
      "How the charger is wired (ChargeMode), sent to it once when it changes. Empty leaves the charger's: set it only to match the installation.": "Cómo está cableado el cargador (ChargeMode), enviado una vez cuando cambia. Vacío deja el del cargador: ajústelo solo para que coincida con la instalación.",
      "Minimum current (A)": "Corriente mínima (A)",
      "Maximum current (A)": "Corriente máxima (A)",
      "Installation voltage (V)": "Tensión de la instalación (V)",
      "The lowest current the charger offers (MinIntensity), 6 to 32 A and not above the maximum, sent once when it changes. Empty leaves the charger's.": "La corriente más baja que ofrece el cargador (MinIntensity), de 6 a 32 A y no por encima del máximo, enviada una vez cuando cambia. Vacío deja la del cargador.",
      "The highest current the charger offers (MaxIntensity), 6 to 32 A, sent once when it changes. Never above what the installation's wiring and breaker take. Empty leaves the charger's.": "La corriente más alta que ofrece el cargador (MaxIntensity), de 6 a 32 A, enviada una vez cuando cambia. Nunca por encima de lo que admiten el cableado y el interruptor de la instalación. Vacío deja la del cargador.",
      "The installation's nominal voltage (VoltageInstallation), 1 to 500 V, sent once when it changes. Empty leaves the charger's.": "La tensión nominal de la instalación (VoltageInstallation), de 1 a 500 V, enviada una vez cuando cambia. Vacío deja la del cargador."
    },
    "pt": {
      "A contact sensor that shows when a car is plugged in, and the charger's faults.": "Um sensor de contacto que indica quando um carro está ligado, e as falhas do carregador.",
      "A fan whose speed is the current offered to the car, in amperes.": "Uma ventoinha cuja velocidade é a corrente oferecida ao carro, em amperes.",
      "A lock that disables the charger.": "Uma fechadura que desativa o carregador.",
      "Add a V2C Trydan by its address on the local network. Once it answers and the settings are saved, its address is with its accessory.": "Adicione um V2C Trydan pelo seu endereço na rede local. Depois de responder e de as definições serem guardadas, o endereço fica com o seu acessório.",
      "Address": "Endereço",
      "Advanced": "Avançado",
      "Car connected": "Carro ligado",
      "Charge current": "Corrente de carga",
      "Charger": "Carregador",
      "Chargers": "Carregadores",
      "Counts the solar power the charger's meter reads; leave it off when an inverter plugin reports it.": "Contabiliza a produção solar lida pelo contador do carregador; deixe desligado quando um plugin de inversor a indica.",
      "House power on the Energy page": "Consumo da casa na página Energia",
      "How long a request to a charger waits for its answer.": "Quanto tempo um pedido a um carregador espera pela resposta.",
      "How often each charger is asked for its values. 5 seconds at least.": "Com que frequência cada carregador é consultado. 5 segundos no mínimo.",
      "LEDs": "LED",
      "Lock": "Bloqueio",
      "Name": "Nome",
      "Not counted": "Não contabilizado",
      "Plugin name as shown in the logs": "Nome do plugin tal como aparece nos registos",
      "Polling Interval (in seconds)": "Intervalo de consulta (em segundos)",
      "Solar power on the Energy page": "Produção solar na página Energia",
      "Switches for the charge timer, dynamic power and its pause.": "Interruptores para o temporizador de carga, a potência dinâmica e a sua pausa.",
      "The charger's IP address or host name on the local network, with :port when it is not 80.": "O endereço IP ou o nome de anfitrião do carregador na rede local, com :porta se não for a 80.",
      "The grid (the clamp is at the grid connection)": "A rede (a pinça está na ligação à rede)",
      "The home's use (the clamp measures the home)": "O consumo da casa (a pinça mede a casa)",
      "The light ring and the logo as lights, when the firmware reports them.": "O anel de luz e o logótipo como luzes, quando o firmware os indica.",
      "The name in HomeKit; V2C Trydan when empty.": "O nome no HomeKit; V2C Trydan se estiver vazio.",
      "Timeout (in seconds)": "Tempo limite (em segundos)",
      "Timer and dynamic power": "Temporizador e potência dinâmica",
      "What the charger's meter clamp measures, for the Status page's Energy section. Leave it uncounted when another plugin reports it.": "O que mede a pinça do contador do carregador, para a secção Energia da página Estado. Deixe-o por contabilizar quando outro plugin o indica.",
      "Dynamic power modes": "Modos de potência dinâmica",
      "A switch for each dynamic power mode (timed, solar and minimum, solar only, solar and grid, stop): turning one on puts the charger in that mode, for scenes and automations.": "Um interruptor por modo de potência dinâmica (programado, solar e mínimo, só solar, solar e rede, paragem): ligar um põe o carregador nesse modo, para cenas e automatizações.",
      "Wiring": "Cablagem",
      "Single-phase": "Monofásico",
      "Three-phase": "Trifásico",
      "Mixed": "Misto",
      "How the charger is wired (ChargeMode), sent to it once when it changes. Empty leaves the charger's: set it only to match the installation.": "Como o carregador está cablado (ChargeMode), enviado uma vez quando muda. Vazio mantém o do carregador: defina-o só para corresponder à instalação.",
      "Minimum current (A)": "Corrente mínima (A)",
      "Maximum current (A)": "Corrente máxima (A)",
      "Installation voltage (V)": "Tensão da instalação (V)",
      "The lowest current the charger offers (MinIntensity), 6 to 32 A and not above the maximum, sent once when it changes. Empty leaves the charger's.": "A corrente mais baixa que o carregador oferece (MinIntensity), de 6 a 32 A e não acima do máximo, enviada uma vez quando muda. Vazio mantém a do carregador.",
      "The highest current the charger offers (MaxIntensity), 6 to 32 A, sent once when it changes. Never above what the installation's wiring and breaker take. Empty leaves the charger's.": "A corrente mais alta que o carregador oferece (MaxIntensity), de 6 a 32 A, enviada uma vez quando muda. Nunca acima do que a cablagem e o disjuntor da instalação suportam. Vazio mantém a do carregador.",
      "The installation's nominal voltage (VoltageInstallation), 1 to 500 V, sent once when it changes. Empty leaves the charger's.": "A tensão nominal da instalação (VoltageInstallation), de 1 a 500 V, enviada uma vez quando muda. Vazio mantém a do carregador."
    }
  }
}
"""#
}
