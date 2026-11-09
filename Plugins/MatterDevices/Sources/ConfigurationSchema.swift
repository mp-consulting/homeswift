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
  "i18n": {
    "fr": {
      "Name": "Nom",
      "Matter devices another app already has, controlled by Homeswift too. Add one from Add accessories with the pairing code that app shows when you turn on its pairing mode.": "Les appareils Matter qu'une autre app a déjà, contrôlés aussi par Homeswift. Ajoutez-en un depuis Ajouter des accessoires avec le code d'appairage que cette app affiche quand vous activez son mode d'appairage.",
      "Plugin name as shown in the logs": "Nom du plugin tel qu'affiché dans les journaux"
    },
    "es": {
      "Name": "Nombre",
      "Matter devices another app already has, controlled by Homeswift too. Add one from Add accessories with the pairing code that app shows when you turn on its pairing mode.": "Dispositivos Matter que ya tiene otra app, controlados también por Homeswift. Añade uno desde Añadir accesorios con el código de vinculación que esa app muestra al activar su modo de vinculación.",
      "Plugin name as shown in the logs": "Nombre del plugin tal como aparece en los registros"
    },
    "pt": {
      "Name": "Nome",
      "Matter devices another app already has, controlled by Homeswift too. Add one from Add accessories with the pairing code that app shows when you turn on its pairing mode.": "Dispositivos Matter que outra app já tem, controlados também pelo Homeswift. Adicione um em Adicionar acessórios com o código de emparelhamento que essa app mostra quando ativa o modo de emparelhamento.",
      "Plugin name as shown in the logs": "Nome do plugin tal como aparece nos registos"
    }
  }
}
"""#
}
