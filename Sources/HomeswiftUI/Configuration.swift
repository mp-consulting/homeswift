import Foundation
import HomeswiftAI
import HomeswiftPlugin

/// The `HomeswiftUI` platform block: where the web UI listens and how it authenticates.
///
/// ```json
/// { "platform": "HomeswiftUI", "port": 8581, "host": "0.0.0.0", "auth": "form", "https": true }
/// ```
public struct UIConfiguration: Sendable, Equatable {
    public static let platform = "HomeswiftUI"
    public static let defaultPort = 8581

    /// The block's settings form, in the shape of a plugin's config.schema.json: the web UI's Settings uses it.
    public static let schemaJSON = #"""
        {
          "pluginAlias": "HomeswiftUI",
          "schema": {
            "type": "object",
            "properties": {
              "port": { "title": "Port", "type": "integer", "default": 8581, "minimum": 1, "maximum": 65535, "description": "Where the web UI listens. After a change the page moves to the new port." },
              "host": { "title": "Listen on", "type": "string", "placeholder": "0.0.0.0", "description": "0.0.0.0 listens on every interface, so phones on the network can open the UI; 127.0.0.1 keeps it on this machine." },
              "auth": { "title": "Sign-in", "type": "string", "default": "form", "oneOf": [
                { "title": "Username and password", "enum": ["form"] },
                { "title": "None (a trusted network or this machine only)", "enum": ["none"] }
              ], "description": "Without sign-in anyone who reaches the address controls the bridge." },
              "sessionDays": { "title": "Stay signed in (days)", "type": "integer", "default": 7, "minimum": 1, "maximum": 365, "description": "How long a login lasts without activity." },
              "allowedHosts": { "title": "Other names", "type": "array", "items": { "type": "string" }, "description": "Names the UI answers to besides IP addresses, localhost and this machine's name: a DNS name, a reverse proxy's host. * allows every name." },
              "https": { "title": "HTTPS", "type": "boolean", "default": false, "description": "Serve the UI over HTTPS, which browsers need for the Assistant's microphone away from this machine. Without a certificate below, the bridge makes a self-signed one: the browser warns once, or install it from /homeswift-ui.crt to trust it." },
              "certificate": { "title": "Certificate file", "type": "string", "placeholder": "~/certs/homeswift.pem", "x-schema-form": { "type": "file", "accept": ".pem,.crt,.cer" }, "description": "A PEM certificate (with its chain) to use instead of the self-signed one: a path, or drop the file." },
              "privateKey": { "title": "Private key file", "type": "string", "placeholder": "~/certs/homeswift-key.pem", "x-schema-form": { "type": "file", "accept": ".pem,.key" }, "description": "The certificate's PEM private key: a path, or drop the file." },
              "trustProxy": { "title": "Trusted reverse proxies", "type": "array", "items": { "type": "string" }, "description": "Addresses or CIDR ranges (127.0.0.1, 10.0.0.0/8) of reverse proxies in front of the UI, or loopback, linklocal, uniquelocal. Only these may say who the client is (X-Forwarded-For, for the login throttle and the log) and that it came over HTTPS (X-Forwarded-Proto, for a secure cookie). Empty: the headers are ignored." },
              "scheduledRestartCron": { "title": "Scheduled restart", "type": "string", "placeholder": "0 4 * * 1", "x-schema-form": { "type": "schedule" }, "description": "Restart homeswift by itself, in this machine's time zone: at a time on the days ticked (none: every day), or under Custom a cron expression of five fields (minute hour day month weekday; 0 4 * * 1 is Mondays at 4:00)." },
              "scheduledBackupDisable": { "title": "Turn on the daily backup", "type": "boolean", "default": false, "x-schema-form": { "invert": true }, "description": "The web UI backs up the whole instance once a day, at a random time between midnight and 7:00. Off: scheduledBackupDisable is true." },
              "scheduledBackupPath": { "title": "Backup folder", "type": "string", "placeholder": "instance-backups next to config.json", "description": "Where the daily and manual backups are kept: a folder that exists, a network share for a copy off this machine. Empty: instance-backups next to config.json." },
              "scheduledBackupDays": { "title": "Keep daily backups (days)", "type": "integer", "default": 7, "minimum": 1, "maximum": 365, "description": "Older backups of this bridge are removed after each daily backup." },
              "checkForUpdates": { "title": "Check for updates", "type": "boolean", "default": true, "description": "Ask GitHub twice a day whether a newer Homeswift is out, and say so on the Status page with how to upgrade this install. The request carries only the version." }
            }
          },
          "layout": ["port", "host", "auth", "sessionDays", "allowedHosts", "https", "certificate", "privateKey", "checkForUpdates",
            { "type": "fieldset", "title": "Behind a reverse proxy", "expandable": true, "expanded": false, "items": ["trustProxy"] },
            { "type": "fieldset", "title": "Schedules", "expandable": true, "expanded": false, "items": ["scheduledRestartCron", "scheduledBackupDisable", "scheduledBackupPath", "scheduledBackupDays"] }],
          "i18n": {
            "fr": {
              "instance-backups next to config.json": "instance-backups à côté de config.json",
              "Port": "Port",
              "Where the web UI listens. After a change the page moves to the new port.": "Où l'interface web écoute. Après un changement, la page passe au nouveau port.",
              "Listen on": "Écouter sur",
              "0.0.0.0 listens on every interface, so phones on the network can open the UI; 127.0.0.1 keeps it on this machine.": "0.0.0.0 écoute sur toutes les interfaces, pour que les téléphones du réseau ouvrent l'interface ; 127.0.0.1 la garde sur cette machine.",
              "Sign-in": "Connexion",
              "Username and password": "Nom d'utilisateur et mot de passe",
              "None (a trusted network or this machine only)": "Aucune (réseau de confiance ou cette machine seulement)",
              "Without sign-in anyone who reaches the address controls the bridge.": "Sans connexion, quiconque atteint l'adresse contrôle le pont.",
              "Stay signed in (days)": "Rester connecté (jours)",
              "How long a login lasts without activity.": "Combien de temps une connexion dure sans activité.",
              "Other names": "Autres noms",
              "Names the UI answers to besides IP addresses, localhost and this machine's name: a DNS name, a reverse proxy's host. * allows every name.": "Les noms auxquels l'interface répond en plus des adresses IP, de localhost et du nom de cette machine : un nom DNS, l'hôte d'un proxy inverse. * autorise tous les noms.",
              "HTTPS": "HTTPS",
              "Serve the UI over HTTPS, which browsers need for the Assistant's microphone away from this machine. Without a certificate below, the bridge makes a self-signed one: the browser warns once, or install it from /homeswift-ui.crt to trust it.": "Servir l'interface en HTTPS, dont les navigateurs ont besoin pour le micro de l'Assistant hors de cette machine. Sans certificat ci-dessous, le pont en crée un autosigné : le navigateur avertit une fois, ou installez-le depuis /homeswift-ui.crt pour lui faire confiance.",
              "Certificate file": "Fichier de certificat",
              "A PEM certificate (with its chain) to use instead of the self-signed one: a path, or drop the file.": "Un certificat PEM (avec sa chaîne) à utiliser au lieu de l'autosigné : un chemin, ou déposez le fichier.",
              "Private key file": "Fichier de clé privée",
              "The certificate's PEM private key: a path, or drop the file.": "La clé privée PEM du certificat : un chemin, ou déposez le fichier.",
              "Trusted reverse proxies": "Proxys inverses de confiance",
              "Addresses or CIDR ranges (127.0.0.1, 10.0.0.0/8) of reverse proxies in front of the UI, or loopback, linklocal, uniquelocal. Only these may say who the client is (X-Forwarded-For, for the login throttle and the log) and that it came over HTTPS (X-Forwarded-Proto, for a secure cookie). Empty: the headers are ignored.": "Adresses ou plages CIDR (127.0.0.1, 10.0.0.0/8) des proxys inverses devant l'interface, ou loopback, linklocal, uniquelocal. Eux seuls peuvent dire qui est le client (X-Forwarded-For, pour la limitation des connexions et le journal) et qu'il est venu en HTTPS (X-Forwarded-Proto, pour un cookie sécurisé). Vide : ces en-têtes sont ignorés.",
              "Scheduled restart": "Redémarrage planifié",
              "Restart homeswift by itself, in this machine's time zone: at a time on the days ticked (none: every day), or under Custom a cron expression of five fields (minute hour day month weekday; 0 4 * * 1 is Mondays at 4:00).": "Redémarrer homeswift tout seul, dans le fuseau horaire de cette machine : à une heure les jours cochés (aucun : tous les jours), ou sous « Personnalisé » une expression cron de cinq champs (minute heure jour mois jour de la semaine ; 0 4 * * 1 est le lundi à 4:00).",
              "Turn on the daily backup": "Activer la sauvegarde quotidienne",
              "The web UI backs up the whole instance once a day, at a random time between midnight and 7:00. Off: scheduledBackupDisable is true.": "L'interface web sauvegarde toute l'instance une fois par jour, à une heure au hasard entre minuit et 7:00. Désactivé : scheduledBackupDisable vaut true.",
              "Backup folder": "Dossier des sauvegardes",
              "Where the daily and manual backups are kept: a folder that exists, a network share for a copy off this machine. Empty: instance-backups next to config.json.": "Où les sauvegardes quotidiennes et manuelles sont gardées : un dossier qui existe, un partage réseau pour une copie hors de cette machine. Vide : instance-backups à côté de config.json.",
              "Keep daily backups (days)": "Garder les sauvegardes quotidiennes (jours)",
              "Older backups of this bridge are removed after each daily backup.": "Les sauvegardes plus anciennes de ce pont sont supprimées après chaque sauvegarde quotidienne.",
              "Check for updates": "Rechercher des mises à jour",
              "Ask GitHub twice a day whether a newer Homeswift is out, and say so on the Status page with how to upgrade this install. The request carries only the version.": "Demander à GitHub deux fois par jour si un Homeswift plus récent est sorti, et l'indiquer sur la page État avec la façon de mettre à jour cette installation. La requête ne transmet que la version.",
              "Behind a reverse proxy": "Derrière un proxy inverse",
              "Schedules": "Planifications"
            },
            "es": {
              "instance-backups next to config.json": "instance-backups junto a config.json",
              "Port": "Puerto",
              "Where the web UI listens. After a change the page moves to the new port.": "Dónde escucha la interfaz web. Tras un cambio, la página pasa al nuevo puerto.",
              "Listen on": "Escuchar en",
              "0.0.0.0 listens on every interface, so phones on the network can open the UI; 127.0.0.1 keeps it on this machine.": "0.0.0.0 escucha en todas las interfaces, para que los teléfonos de la red puedan abrir la interfaz; 127.0.0.1 la deja en esta máquina.",
              "Sign-in": "Inicio de sesión",
              "Username and password": "Nombre de usuario y contraseña",
              "None (a trusted network or this machine only)": "Ninguno (solo una red de confianza o esta máquina)",
              "Without sign-in anyone who reaches the address controls the bridge.": "Sin inicio de sesión, cualquiera que llegue a la dirección controla el puente.",
              "Stay signed in (days)": "Mantener la sesión (días)",
              "How long a login lasts without activity.": "Cuánto dura una sesión sin actividad.",
              "Other names": "Otros nombres",
              "Names the UI answers to besides IP addresses, localhost and this machine's name: a DNS name, a reverse proxy's host. * allows every name.": "Nombres a los que responde la interfaz además de las direcciones IP, localhost y el nombre de esta máquina: un nombre DNS, el host de un proxy inverso. * permite todos los nombres.",
              "HTTPS": "HTTPS",
              "Serve the UI over HTTPS, which browsers need for the Assistant's microphone away from this machine. Without a certificate below, the bridge makes a self-signed one: the browser warns once, or install it from /homeswift-ui.crt to trust it.": "Sirve la interfaz por HTTPS, que los navegadores necesitan para el micrófono del Asistente fuera de esta máquina. Sin un certificado abajo, el puente crea uno autofirmado: el navegador avisa una vez, o instálalo desde /homeswift-ui.crt para confiar en él.",
              "Certificate file": "Archivo de certificado",
              "A PEM certificate (with its chain) to use instead of the self-signed one: a path, or drop the file.": "Un certificado PEM (con su cadena) para usar en lugar del autofirmado: una ruta, o suelta el archivo.",
              "Private key file": "Archivo de clave privada",
              "The certificate's PEM private key: a path, or drop the file.": "La clave privada PEM del certificado: una ruta, o suelta el archivo.",
              "Trusted reverse proxies": "Proxies inversos de confianza",
              "Addresses or CIDR ranges (127.0.0.1, 10.0.0.0/8) of reverse proxies in front of the UI, or loopback, linklocal, uniquelocal. Only these may say who the client is (X-Forwarded-For, for the login throttle and the log) and that it came over HTTPS (X-Forwarded-Proto, for a secure cookie). Empty: the headers are ignored.": "Direcciones o rangos CIDR (127.0.0.1, 10.0.0.0/8) de los proxies inversos delante de la interfaz, o loopback, linklocal, uniquelocal. Solo ellos pueden decir quién es el cliente (X-Forwarded-For, para el límite de inicios de sesión y el registro) y que llegó por HTTPS (X-Forwarded-Proto, para una cookie segura). Vacío: se ignoran las cabeceras.",
              "Scheduled restart": "Reinicio programado",
              "Restart homeswift by itself, in this machine's time zone: at a time on the days ticked (none: every day), or under Custom a cron expression of five fields (minute hour day month weekday; 0 4 * * 1 is Mondays at 4:00).": "Reinicia homeswift solo, en la zona horaria de esta máquina: a una hora los días marcados (ninguno: todos los días), o en Personalizado una expresión cron de cinco campos (minuto hora día mes día de la semana; 0 4 * * 1 es los lunes a las 4:00).",
              "Turn on the daily backup": "Activar la copia de seguridad diaria",
              "The web UI backs up the whole instance once a day, at a random time between midnight and 7:00. Off: scheduledBackupDisable is true.": "La interfaz web hace una copia de seguridad de toda la instancia una vez al día, a una hora al azar entre la medianoche y las 7:00. Desactivado: scheduledBackupDisable es true.",
              "Backup folder": "Carpeta de copias de seguridad",
              "Where the daily and manual backups are kept: a folder that exists, a network share for a copy off this machine. Empty: instance-backups next to config.json.": "Dónde se guardan las copias de seguridad diarias y manuales: una carpeta que exista, una carpeta compartida de red para una copia fuera de esta máquina. Vacío: instance-backups junto a config.json.",
              "Keep daily backups (days)": "Conservar las copias diarias (días)",
              "Older backups of this bridge are removed after each daily backup.": "Las copias de seguridad más antiguas de este puente se eliminan tras cada copia diaria.",
              "Check for updates": "Buscar actualizaciones",
              "Ask GitHub twice a day whether a newer Homeswift is out, and say so on the Status page with how to upgrade this install. The request carries only the version.": "Pregunta a GitHub dos veces al día si hay un Homeswift más reciente, y lo indica en la página Estado con cómo actualizar esta instalación. La petición solo lleva la versión.",
              "Behind a reverse proxy": "Detrás de un proxy inverso",
              "Schedules": "Programaciones"
            },
            "pt": {
              "instance-backups next to config.json": "instance-backups junto ao config.json",
              "Port": "Porta",
              "Where the web UI listens. After a change the page moves to the new port.": "Onde a interface web escuta. Após uma alteração, a página passa para a nova porta.",
              "Listen on": "Escutar em",
              "0.0.0.0 listens on every interface, so phones on the network can open the UI; 127.0.0.1 keeps it on this machine.": "0.0.0.0 escuta em todas as interfaces, para que os telemóveis da rede possam abrir a interface; 127.0.0.1 mantém-na nesta máquina.",
              "Sign-in": "Início de sessão",
              "Username and password": "Nome de utilizador e palavra-passe",
              "None (a trusted network or this machine only)": "Nenhum (só uma rede de confiança ou esta máquina)",
              "Without sign-in anyone who reaches the address controls the bridge.": "Sem início de sessão, quem chegar ao endereço controla a ponte.",
              "Stay signed in (days)": "Manter a sessão (dias)",
              "How long a login lasts without activity.": "Quanto tempo dura uma sessão sem atividade.",
              "Other names": "Outros nomes",
              "Names the UI answers to besides IP addresses, localhost and this machine's name: a DNS name, a reverse proxy's host. * allows every name.": "Nomes a que a interface responde além dos endereços IP, de localhost e do nome desta máquina: um nome DNS, o anfitrião de um proxy inverso. * permite todos os nomes.",
              "HTTPS": "HTTPS",
              "Serve the UI over HTTPS, which browsers need for the Assistant's microphone away from this machine. Without a certificate below, the bridge makes a self-signed one: the browser warns once, or install it from /homeswift-ui.crt to trust it.": "Servir a interface por HTTPS, de que os navegadores precisam para o microfone do Assistente fora desta máquina. Sem um certificado abaixo, a ponte cria um autoassinado: o navegador avisa uma vez, ou instale-o a partir de /homeswift-ui.crt para confiar nele.",
              "Certificate file": "Ficheiro de certificado",
              "A PEM certificate (with its chain) to use instead of the self-signed one: a path, or drop the file.": "Um certificado PEM (com a sua cadeia) a usar em vez do autoassinado: um caminho, ou largue o ficheiro.",
              "Private key file": "Ficheiro de chave privada",
              "The certificate's PEM private key: a path, or drop the file.": "A chave privada PEM do certificado: um caminho, ou largue o ficheiro.",
              "Trusted reverse proxies": "Proxies inversos de confiança",
              "Addresses or CIDR ranges (127.0.0.1, 10.0.0.0/8) of reverse proxies in front of the UI, or loopback, linklocal, uniquelocal. Only these may say who the client is (X-Forwarded-For, for the login throttle and the log) and that it came over HTTPS (X-Forwarded-Proto, for a secure cookie). Empty: the headers are ignored.": "Endereços ou intervalos CIDR (127.0.0.1, 10.0.0.0/8) dos proxies inversos à frente da interface, ou loopback, linklocal, uniquelocal. Só estes podem dizer quem é o cliente (X-Forwarded-For, para o limite de inícios de sessão e o registo) e que chegou por HTTPS (X-Forwarded-Proto, para um cookie seguro). Vazio: os cabeçalhos são ignorados.",
              "Scheduled restart": "Reinício agendado",
              "Restart homeswift by itself, in this machine's time zone: at a time on the days ticked (none: every day), or under Custom a cron expression of five fields (minute hour day month weekday; 0 4 * * 1 is Mondays at 4:00).": "Reiniciar o homeswift sozinho, no fuso horário desta máquina: a uma hora nos dias assinalados (nenhum: todos os dias), ou em Personalizado uma expressão cron de cinco campos (minuto hora dia mês dia da semana; 0 4 * * 1 é às segundas-feiras às 4:00).",
              "Turn on the daily backup": "Ativar a cópia de segurança diária",
              "The web UI backs up the whole instance once a day, at a random time between midnight and 7:00. Off: scheduledBackupDisable is true.": "A interface web faz uma cópia de segurança de toda a instância uma vez por dia, a uma hora aleatória entre a meia-noite e as 7:00. Desativado: scheduledBackupDisable é true.",
              "Backup folder": "Pasta das cópias de segurança",
              "Where the daily and manual backups are kept: a folder that exists, a network share for a copy off this machine. Empty: instance-backups next to config.json.": "Onde são guardadas as cópias de segurança diárias e manuais: uma pasta que exista, uma partilha de rede para uma cópia fora desta máquina. Vazio: instance-backups junto ao config.json.",
              "Keep daily backups (days)": "Manter as cópias diárias (dias)",
              "Older backups of this bridge are removed after each daily backup.": "As cópias de segurança mais antigas desta ponte são removidas após cada cópia diária.",
              "Check for updates": "Procurar atualizações",
              "Ask GitHub twice a day whether a newer Homeswift is out, and say so on the Status page with how to upgrade this install. The request carries only the version.": "Perguntar ao GitHub duas vezes por dia se há um Homeswift mais recente, e indicá-lo na página Estado com a forma de atualizar esta instalação. O pedido só leva a versão.",
              "Behind a reverse proxy": "Atrás de um proxy inverso",
              "Schedules": "Agendamentos"
            }
          }
        }
        """#

    public enum AuthMode: String, Sendable, Codable {
        /// A username and password, created on the first visit.
        case form
        /// No login: for a bridge that only listens on a trusted network or on localhost.
        case none
    }

    public var host = "0.0.0.0"
    public var port = defaultPort
    public var auth = AuthMode.form
    /// How long a login lasts without activity.
    public var sessionDays = 7
    /// Names the UI answers to besides IP addresses, localhost and this machine's name: a DNS name, a reverse
    /// proxy's host. Lower-cased. `*` allows every name.
    public var allowedHosts: [String] = []
    /// Serve over HTTPS, with `certificate` and `privateKey` (PEM files) or a self-signed certificate.
    public var https = false
    public var certificate: String?
    public var privateKey: String?
    /// The reverse proxies whose X-Forwarded-For and X-Forwarded-Proto count (`trustProxy`).
    public var trustProxy = TrustedProxies()
    /// When homeswift restarts by itself (`scheduledRestartCron`).
    public var scheduledRestart: CronSchedule?
    /// The daily backup is off (`scheduledBackupDisable`).
    public var scheduledBackupDisable = false
    /// Where backups are kept (`scheduledBackupPath`); `instance-backups` next to config.json without one.
    public var scheduledBackupPath: String?
    /// How many days daily backups are kept (`scheduledBackupDays`).
    public var scheduledBackupDays = 7
    /// Whether the Status page says when a newer Homeswift is out (`ReleaseWatcher`, GitHub twice a day).
    public var checkForUpdates = true

    public var scheme: String { https ? "https" : "http" }

    public init() {}

    public init(block: JSONValue) throws {
        if let host = block["host"]?.stringValue?.trimmingCharacters(in: .whitespaces), !host.isEmpty { self.host = host }
        if let port = block["port"], !port.isNull {
            guard let value = port.portValue else { throw UIConfigurationError.invalid(key: "port", expected: "a port number") }
            self.port = value
        }
        if let auth = block["auth"]?.stringValue {
            guard let mode = AuthMode(rawValue: auth) else { throw UIConfigurationError.invalid(key: "auth", expected: "form or none") }
            self.auth = mode
        }
        if let days = block["sessionDays"], !days.isNull {
            guard let value = days.intValue, value > 0 else { throw UIConfigurationError.invalid(key: "sessionDays", expected: "a positive number") }
            sessionDays = value
        }
        if let hosts = block["allowedHosts"], !hosts.isNull {
            guard let list = hosts.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
                throw UIConfigurationError.invalid(key: "allowedHosts", expected: "a list of host names")
            }
            allowedHosts = list.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
        if let https = block["https"], !https.isNull {
            guard let value = https.boolValue else { throw UIConfigurationError.invalid(key: "https", expected: "true or false") }
            self.https = value
        }
        if let check = block["checkForUpdates"], !check.isNull {
            guard let value = check.boolValue else { throw UIConfigurationError.invalid(key: "checkForUpdates", expected: "true or false") }
            checkForUpdates = value
        }
        certificate = block["certificate"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
        privateKey = block["privateKey"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
        if let proxies = block["trustProxy"], !proxies.isNull, proxies != .bool(false) {
            let entries: [String]
            if let text = proxies.stringValue {
                entries = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
            } else if let list = proxies.arrayValue, list.allSatisfy({ $0.stringValue != nil }) {
                entries = list.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else {
                throw UIConfigurationError.invalid(key: "trustProxy", expected: "a list of proxy addresses or CIDR ranges")
            }
            trustProxy = try TrustedProxies(entries)
        }
        if let cron = block["scheduledRestartCron"]?.stringValue?.trimmingCharacters(in: .whitespaces), !cron.isEmpty {
            do {
                scheduledRestart = try CronSchedule(cron)
            } catch let error as CronSchedule.ParseError {
                throw UIConfigurationError.invalid(key: "scheduledRestartCron", expected: "a cron expression: \(error.description)")
            }
        }
        if let disable = block["scheduledBackupDisable"], !disable.isNull {
            guard let value = disable.boolValue else { throw UIConfigurationError.invalid(key: "scheduledBackupDisable", expected: "true or false") }
            scheduledBackupDisable = value
        }
        scheduledBackupPath = block["scheduledBackupPath"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
        if let days = block["scheduledBackupDays"], !days.isNull {
            guard let value = days.intValue, value > 0 else { throw UIConfigurationError.invalid(key: "scheduledBackupDays", expected: "a positive number of days") }
            scheduledBackupDays = value
        }
        guard (certificate == nil) == (privateKey == nil) else {
            throw UIConfigurationError.invalid(key: certificate == nil ? "certificate" : "privateKey", expected: "given with the other: a certificate needs its private key")
        }
    }
}

public enum UIConfigurationError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalid(key: String, expected: String)

    public var description: String {
        switch self {
        case .invalid(let key, let expected): "HomeswiftUI: \"\(key)\" must be \(expected)"
        }
    }
}
