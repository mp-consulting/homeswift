// THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
// swiftlint:disable all

extension GoogleNestSDMPlugin {
    /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
    public static let configurationSchemaJSON: String? = #"""
{
  "pluginAlias": "homebridge-google-nest-sdm",
  "pluginType": "platform",
  "singular": true,
  "schema": {
    "type": "object",
    "properties": {
      "name": {
        "title": "Name",
        "type": "string",
        "default": "Google Nest",
        "description": "Name shown in the logs"
      },
      "projectId": {
        "title": "Device Access project ID",
        "type": "string",
        "description": "The project's ID in the Device Access Console"
      },
      "clientId": {
        "title": "OAuth client ID",
        "type": "string",
        "description": "The OAuth client of the Google Cloud project linked to the Device Access project"
      },
      "subscriptionId": {
        "title": "Pub/Sub subscription",
        "type": "string",
        "description": "The pull subscription's full name: projects/<project>/subscriptions/<subscription>"
      },
      "gcpProjectId": {
        "title": "Google Cloud project ID",
        "type": "string",
        "description": "The Google Cloud project of the subscription, when it is not the Device Access project's"
      },
      "showFan": {
        "title": "Show the fan",
        "type": "boolean",
        "default": false,
        "description": "Adds a fan accessory to each thermostat, which runs the fan timer"
      },
      "fanDuration": {
        "title": "Fan duration (seconds)",
        "type": "integer",
        "default": 900,
        "minimum": 1,
        "maximum": 43200,
        "description": "How long the fan runs when turned on",
        "condition": { "functionBody": "return model.showFan === true;" }
      },
      "vEncoder": {
        "title": "Video encoder",
        "type": "string",
        "placeholder": "libx264 -preset ultrafast -tune zerolatency",
        "description": "FFmpeg's encoder and its options for live views; copy sends the camera's video as it is"
      },
      "analyzeDuration": {
        "title": "Analyze duration (microseconds)",
        "type": "integer",
        "placeholder": 15000000,
        "description": "FFmpeg's -analyzeduration for the camera streams"
      },
      "probeSize": {
        "title": "Probe size (bytes)",
        "type": "integer",
        "placeholder": 100000000,
        "description": "FFmpeg's -probesize for the camera streams"
      }
    }
  },
  "accessorySchema": {
    "properties": {}
  },
  "layout": [
    "name",
    {
      "type": "fieldset",
      "title": "Device Access",
      "expandable": true,
      "expanded": false,
      "items": ["projectId", "clientId", "subscriptionId", "gcpProjectId"]
    },
    {
      "type": "fieldset",
      "title": "Thermostats",
      "expandable": true,
      "expanded": false,
      "items": ["showFan", "fanDuration"]
    },
    {
      "type": "fieldset",
      "title": "Cameras",
      "expandable": true,
      "expanded": false,
      "items": ["vEncoder", "analyzeDuration", "probeSize"]
    }
  ],
  "i18n": {
    "fr": {
      "Name": "Nom",
      "Name shown in the logs": "Nom affiché dans les journaux",
      "Device Access project ID": "ID du projet Device Access",
      "The project's ID in the Device Access Console": "L’ID du projet dans la console Device Access",
      "OAuth client ID": "ID du client OAuth",
      "The OAuth client of the Google Cloud project linked to the Device Access project": "Le client OAuth du projet Google Cloud associé au projet Device Access",
      "Pub/Sub subscription": "Abonnement Pub/Sub",
      "The pull subscription's full name: projects/<project>/subscriptions/<subscription>": "Le nom complet de l’abonnement pull : projects/<project>/subscriptions/<subscription>",
      "Google Cloud project ID": "ID du projet Google Cloud",
      "The Google Cloud project of the subscription, when it is not the Device Access project's": "Le projet Google Cloud de l’abonnement, s’il n’est pas celui du projet Device Access",
      "Show the fan": "Afficher le ventilateur",
      "Adds a fan accessory to each thermostat, which runs the fan timer": "Ajoute à chaque thermostat un accessoire ventilateur, qui lance sa minuterie",
      "Fan duration (seconds)": "Durée du ventilateur (secondes)",
      "How long the fan runs when turned on": "Combien de temps le ventilateur tourne une fois allumé",
      "Video encoder": "Encodeur vidéo",
      "FFmpeg's encoder and its options for live views; copy sends the camera's video as it is": "L’encodeur de FFmpeg et ses options pour la vidéo en direct ; copy envoie la vidéo de la caméra telle quelle",
      "Analyze duration (microseconds)": "Durée d’analyse (microsecondes)",
      "FFmpeg's -analyzeduration for the camera streams": "Le -analyzeduration de FFmpeg pour les flux des caméras",
      "Probe size (bytes)": "Taille de sondage (octets)",
      "FFmpeg's -probesize for the camera streams": "Le -probesize de FFmpeg pour les flux des caméras",
      "Device Access": "Device Access",
      "Thermostats": "Thermostats",
      "Cameras": "Caméras",
      "libx264 -preset ultrafast -tune zerolatency": "libx264 -preset ultrafast -tune zerolatency"
    },
    "es": {
      "Name": "Nombre",
      "Name shown in the logs": "Nombre que se muestra en los registros",
      "Device Access project ID": "ID del proyecto de Device Access",
      "The project's ID in the Device Access Console": "El ID del proyecto en la consola de Device Access",
      "OAuth client ID": "ID del cliente OAuth",
      "The OAuth client of the Google Cloud project linked to the Device Access project": "El cliente OAuth del proyecto de Google Cloud vinculado al proyecto de Device Access",
      "Pub/Sub subscription": "Suscripción de Pub/Sub",
      "The pull subscription's full name: projects/<project>/subscriptions/<subscription>": "El nombre completo de la suscripción pull: projects/<project>/subscriptions/<subscription>",
      "Google Cloud project ID": "ID del proyecto de Google Cloud",
      "The Google Cloud project of the subscription, when it is not the Device Access project's": "El proyecto de Google Cloud de la suscripción, cuando no es el del proyecto de Device Access",
      "Show the fan": "Mostrar el ventilador",
      "Adds a fan accessory to each thermostat, which runs the fan timer": "Añade a cada termostato un accesorio ventilador, que activa su temporizador",
      "Fan duration (seconds)": "Duración del ventilador (segundos)",
      "How long the fan runs when turned on": "Cuánto tiempo funciona el ventilador al encenderlo",
      "Video encoder": "Codificador de vídeo",
      "FFmpeg's encoder and its options for live views; copy sends the camera's video as it is": "El codificador de FFmpeg y sus opciones para el vídeo en directo; copy envía el vídeo de la cámara tal cual",
      "Analyze duration (microseconds)": "Duración de análisis (microsegundos)",
      "FFmpeg's -analyzeduration for the camera streams": "El -analyzeduration de FFmpeg para las transmisiones de las cámaras",
      "Probe size (bytes)": "Tamaño de sondeo (bytes)",
      "FFmpeg's -probesize for the camera streams": "El -probesize de FFmpeg para las transmisiones de las cámaras",
      "Device Access": "Device Access",
      "Thermostats": "Termostatos",
      "Cameras": "Cámaras",
      "libx264 -preset ultrafast -tune zerolatency": "libx264 -preset ultrafast -tune zerolatency"
    },
    "pt": {
      "Name": "Nome",
      "Name shown in the logs": "Nome mostrado nos registos",
      "Device Access project ID": "ID do projeto Device Access",
      "The project's ID in the Device Access Console": "O ID do projeto na consola Device Access",
      "OAuth client ID": "ID do cliente OAuth",
      "The OAuth client of the Google Cloud project linked to the Device Access project": "O cliente OAuth do projeto Google Cloud associado ao projeto Device Access",
      "Pub/Sub subscription": "Subscrição Pub/Sub",
      "The pull subscription's full name: projects/<project>/subscriptions/<subscription>": "O nome completo da subscrição pull: projects/<project>/subscriptions/<subscription>",
      "Google Cloud project ID": "ID do projeto Google Cloud",
      "The Google Cloud project of the subscription, when it is not the Device Access project's": "O projeto Google Cloud da subscrição, quando não é o do projeto Device Access",
      "Show the fan": "Mostrar a ventoinha",
      "Adds a fan accessory to each thermostat, which runs the fan timer": "Acrescenta a cada termóstato um acessório ventoinha, que liga o seu temporizador",
      "Fan duration (seconds)": "Duração da ventoinha (segundos)",
      "How long the fan runs when turned on": "Quanto tempo a ventoinha funciona quando é ligada",
      "Video encoder": "Codificador de vídeo",
      "FFmpeg's encoder and its options for live views; copy sends the camera's video as it is": "O codificador do FFmpeg e as suas opções para o vídeo em direto; copy envia o vídeo da câmara tal como está",
      "Analyze duration (microseconds)": "Duração de análise (microssegundos)",
      "FFmpeg's -analyzeduration for the camera streams": "O -analyzeduration do FFmpeg para as transmissões das câmaras",
      "Probe size (bytes)": "Tamanho de sondagem (bytes)",
      "FFmpeg's -probesize for the camera streams": "O -probesize do FFmpeg para as transmissões das câmaras",
      "Device Access": "Device Access",
      "Thermostats": "Termostatos",
      "Cameras": "Câmaras",
      "libx264 -preset ultrafast -tune zerolatency": "libx264 -preset ultrafast -tune zerolatency"
    }
  }
}
"""#
}
