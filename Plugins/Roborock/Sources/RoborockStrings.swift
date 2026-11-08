import Foundation

/// The names the plugin gives services, in the block's `language` (section 6.3 and 6.5). The dock-wash switch has the
/// Roborock app's words in its twelve languages; the consumables, which the Homebridge plugin leaves in English (or as
/// raw catalogue keys), are translated here in the web UI's languages (French, Spanish, Portuguese) and German,
/// Italian and Dutch, and fall back to English in the others. A new name renames the service only: ids stay.
enum RoborockStrings {
    static let languages = ["en", "de", "es", "fr", "it", "nl", "pl", "pt", "ru", "uk", "zh-cn", "zh-tw"]

    /// The block's `language`, or `en` for anything else.
    static func language(_ value: String?) -> String {
        let value = value?.lowercased().trimmingCharacters(in: .whitespaces) ?? "en"
        return languages.contains(value) ? value : "en"
    }

    static let dockWash: [String: String] = [
        "en": "Start Mop Washing", "de": "Beginnen Sie mit dem Moppwaschen", "es": "Comenzar a lavar el trapeador",
        "fr": "Démarrer le lavage à la vadrouille", "it": "Avvia il lavaggio del panno", "nl": "Start dweilwassen",
        "pl": "Rozpocznij mycie mopa", "pt": "Comece a lavar o esfregão", "ru": "Начать мытье шваброй",
        "uk": "Розпочати прання шваброю", "zh-cn": "开始拖把清洗", "zh-tw": "開始拖布清洗",
    ]

    static let consumables: [String: [String: String]] = [
        "filter_life": ["en": "Filter", "fr": "Filtre", "es": "Filtro", "pt": "Filtro", "de": "Filter", "it": "Filtro", "nl": "Filter"],
        "main_brush_life": ["en": "Main brush", "fr": "Brosse principale", "es": "Cepillo principal", "pt": "Escova principal", "de": "Hauptbürste", "it": "Spazzola principale", "nl": "Hoofdborstel"],
        "side_brush_life": ["en": "Side brush", "fr": "Brosse latérale", "es": "Cepillo lateral", "pt": "Escova lateral", "de": "Seitenbürste", "it": "Spazzola laterale", "nl": "Zijborstel"],
    ]

    /// The mop switch: the Roborock app's "Mop" in the web UI's languages and German, Italian and Dutch.
    static let mop: [String: String] = [
        "en": "Mop", "fr": "Serpillière", "es": "Fregado", "pt": "Esfregona", "de": "Wischen", "it": "Lavaggio", "nl": "Dweilen",
    ]

    static func mopName(_ language: String) -> String { mop[language] ?? mop["en"]! }

    static func dockWashName(_ language: String) -> String { dockWash[language] ?? dockWash["en"]! }

    static func consumableName(_ field: String, _ language: String) -> String {
        consumables[field]?[language] ?? consumables[field]?["en"] ?? field
    }
}
