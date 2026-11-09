import Foundation
import HomeswiftPlugin

/// A notification's title or message: words the bridge wrote, put in the reader's language when it is sent, or text
/// that came as it is (an Automation's message, the digest, a log line), sent as it is. The shared channels (ntfy,
/// Pushover, Telegram, the webhook) have no one reader and get the Home Language; a browser gets its user's Language.
public struct NotificationText: Sendable, Equatable, ExpressibleByStringLiteral {
    /// The English text, `{name}` where a value goes; a key of `NotificationTexts.strings` unless `literal`.
    public var text: String
    public var values: [String: String]
    /// Sent as it is, in no catalog.
    public var literal: Bool

    /// Words of the bridge's own: the English is the key, as in the web UI's catalogs.
    public init(_ text: String, _ values: [String: String] = [:]) {
        self.text = text
        self.values = values
        literal = false
    }

    public init(stringLiteral value: String) { self.init(value) }

    /// Text that is not the bridge's own words: sent as it is.
    public static func literal(_ text: String) -> NotificationText {
        var one = NotificationText(text)
        one.literal = true
        return one
    }

    /// The text in `language` (`en`, `fr`, `es`, `pt`), its values filled in; English when the catalog lacks it.
    public func text(in language: String) -> String {
        if literal { return text }
        let words = NotificationTexts.strings[text]?[language] ?? text
        // One pass over the template: a value that holds "{name}" (an automation's name) is not filled again.
        return words.replacing(/\{(\w+)\}/) { match in values[String(match.output.1)] ?? String(match.output.0) }
    }
}

/// The bridge's own words in notifications, in French, Spanish and Portuguese; the English is the key. The style and
/// the glossary are the web UI's (docs/translations.md). `NotificationTextTests` checks each key has the three and
/// the same placeholders.
enum NotificationTexts {
    static let strings: [String: [String: String]] = [
        "Homeswift started": ["fr": "Homeswift a démarré", "es": "Homeswift se ha iniciado", "pt": "O Homeswift arrancou"],
        "Homeswift {version} is running with {count} accessories.": [
            "fr": "Homeswift {version} fonctionne avec {count} accessoires.",
            "es": "Homeswift {version} funciona con {count} accesorios.",
            "pt": "O Homeswift {version} está a funcionar com {count} acessórios.",
        ],
        "Homeswift stopped": ["fr": "Homeswift s'est arrêté", "es": "Homeswift se ha detenido", "pt": "O Homeswift parou"],
        "Homeswift is shutting down; its accessories show No Response until it is back.": [
            "fr": "Homeswift s'arrête\u{00A0}: ses accessoires affichent Pas de réponse jusqu'à son retour.",
            "es": "Homeswift se está deteniendo: sus accesorios muestran Sin respuesta hasta que vuelva.",
            "pt": "O Homeswift está a parar: os seus acessórios mostram Sem resposta até voltar.",
        ],
        "{name} is not responding": ["fr": "{name} ne répond pas", "es": "{name} no responde", "pt": "{name} não responde"],
        "{name} has answered No Response for 5 minutes.": [
            "fr": "{name} affiche Pas de réponse depuis 5 minutes.",
            "es": "{name} muestra Sin respuesta desde hace 5 minutos.",
            "pt": "{name} mostra Sem resposta há 5 minutos.",
        ],
        "{plugin}: error": ["fr": "{plugin}\u{00A0}: erreur", "es": "{plugin}: error", "pt": "{plugin}: erro"],
        "Daily digest": ["fr": "Résumé du jour", "es": "Resumen diario", "pt": "Resumo diário"],
        "Automation {name} failed": ["fr": "L'automatisation {name} a échoué", "es": "La automatización {name} ha fallado", "pt": "A automação {name} falhou"],
        "Steps {steps} failed. Trigger: {trigger}.": [
            "fr": "Étapes en échec\u{00A0}: {steps}. Déclencheur\u{00A0}: {trigger}.",
            "es": "Pasos con error: {steps}. Activador: {trigger}.",
            "pt": "Passos com erro: {steps}. Acionador: {trigger}.",
        ],
        "Scheduled backup done": ["fr": "Sauvegarde planifiée effectuée", "es": "Copia de seguridad programada hecha", "pt": "Cópia de segurança agendada feita"],
        "The scheduled instance backup {file} was saved.": [
            "fr": "La sauvegarde planifiée de l'instance {file} a été enregistrée.",
            "es": "Se ha guardado la copia de seguridad programada de la instancia {file}.",
            "pt": "A cópia de segurança agendada da instância {file} foi guardada.",
        ],
        "Scheduled backup failed": ["fr": "Échec de la sauvegarde planifiée", "es": "Ha fallado la copia de seguridad programada", "pt": "A cópia de segurança agendada falhou"],
        "The scheduled instance backup failed: {error}": [
            "fr": "La sauvegarde planifiée de l'instance a échoué\u{00A0}: {error}",
            "es": "Ha fallado la copia de seguridad programada de la instancia: {error}",
            "pt": "A cópia de segurança agendada da instância falhou: {error}",
        ],
        "Test notification": ["fr": "Notification de test", "es": "Notificación de prueba", "pt": "Notificação de teste"],
        "Notifications from Homeswift are working.": [
            "fr": "Les notifications de Homeswift fonctionnent.",
            "es": "Las notificaciones de Homeswift funcionan.",
            "pt": "As notificações do Homeswift estão a funcionar.",
        ],
        "{name} kept switching on and off": [
            "fr": "{name} n'a cessé de s'allumer et de s'éteindre",
            "es": "{name} no paró de encenderse y apagarse",
            "pt": "{name} não parou de ligar e desligar",
        ],
        "{name} switched on and off {n} times in {minutes} min.": [
            "fr": "{name} s'est allumé et éteint {n} fois en {minutes} min.",
            "es": "{name} se encendió y apagó {n} veces en {minutes} min.",
            "pt": "{name} ligou e desligou {n} vezes em {minutes} min.",
        ],
        "Night floor": ["fr": "Plancher de nuit", "es": "Mínimo nocturno", "pt": "Mínimo noturno"],
        "The home never drew less than {watts} at night.": [
            "fr": "La maison n'a jamais consommé moins de {watts} la nuit.",
            "es": "La casa nunca consumió menos de {watts} por la noche.",
            "pt": "A casa nunca consumiu menos de {watts} à noite.",
        ],
        "The home never drew less than {watts} at night: about {cost} a year.": [
            "fr": "La maison n'a jamais consommé moins de {watts} la nuit\u{00A0}: environ {cost} par an.",
            "es": "La casa nunca consumió menos de {watts} por la noche: unos {cost} al año.",
            "pt": "A casa nunca consumiu menos de {watts} à noite: cerca de {cost} por ano.",
        ],
        "Open in Homeswift": ["fr": "Ouvrir dans Homeswift", "es": "Abrir en Homeswift", "pt": "Abrir no Homeswift"],
        "Choose in Homeswift": ["fr": "Choisir dans Homeswift", "es": "Elegir en Homeswift", "pt": "Escolher no Homeswift"],
    ]
}
