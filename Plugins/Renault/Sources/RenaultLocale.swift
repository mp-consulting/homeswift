import Foundation
import HomeswiftPlugin
import HomeswiftNetwork

/// The servers and public keys of the MyRenault app for a locale (docs/clean-room/Renault.md, 3.1): Gigya (the sign-in)
/// and Kamereon (the cars).
struct RenaultServers: Sendable, Equatable {
    var gigyaRoot: String
    var gigyaKey: String
    var kamereonRoot: String
    var kamereonKey: String
    /// Sent with every Kamereon request: the locale's last two letters (`fr_FR` → `FR`).
    var country: String
    /// The language sent with the 2FA code (`fr` for `fr_FR`).
    var language: String?
}

enum RenaultLocale {
    static let gigyaEU = "https://accounts.eu1.gigya.com"
    static let gigyaUS = "https://accounts.us1.gigya.com"
    static let gigyaAU = "https://gigya-prod-au1.renaultgroup.com"
    static let gigyaKeyEU = "3_VgdkgtIRH3AdHvJm-cjV2ug2EFE0lxt0IJzMC4MFqZjFpn_GYFXVdNZ19L7wZX0N"
    static let kamereonKey = "YjkKtHmGfaceeuExUDKGxrLZGGvtVS0J"
    static let kamereonEU = "https://api-wired-prod-1-euw1.wrd-aws.com"
    static let kamereonUS = "https://api-wired-prod-1-usw2.wrd-aws.com"
    static let kamereonAU = "https://api-wired-prod-1-apn1.wrd-aws.com"
    static let configurationBase = "https://renault-wrd-prod-1-euw1-myrapp-one.s3-eu-west-1.amazonaws.com"
    static let defaultLocale = "fr_FR"

    /// The locales on the EU servers with the EU key.
    static let european = [
        "bg_BG", "cs_CZ", "da_DK", "de_DE", "de_AT", "de_CH", "en_GB", "en_IE", "es_ES", "fi_FI", "fr_FR", "fr_BE", "fr_CH",
        "hr_HR", "hu_HU", "it_IT", "it_CH", "nl_NL", "nl_BE", "no_NO", "pl_PL", "pt_PT", "ro_RO", "ru_RU", "sk_SK", "sl_SI",
        "sv_SE",
    ]

    /// The exceptions: their own Gigya key, and for two of them other servers.
    static let exceptions: [String: (gigyaRoot: String, gigyaKey: String, kamereonRoot: String)] = [
        "en_AU": (gigyaAU, "4_GC9iGd3sH8sMJpz2x0q0CQ", kamereonAU),
        "es_MX": (gigyaUS, "4_yTFqPSsGxVyRXPZUM7t1Iw", kamereonUS),
        "fr_LU": (gigyaEU, "3_zt44Wl_wT9mnqn-BHrR19PvXj3wYRPQKLcPbGWawlatFR837KdxSZZStbBTDaqnb", kamereonEU),
    ]

    /// Every locale the plugin knows, sorted: Setup's choices.
    static var known: [String] { (european + exceptions.keys).sorted() }

    /// The servers of a known locale; nil for another (`fetch` asks Renault's configuration for those).
    static func servers(for locale: String) -> RenaultServers? {
        let country = String(locale.suffix(2)).uppercased()
        let language = locale.split(separator: "_").first.map(String.init)
        if let exception = exceptions[locale] {
            return RenaultServers(
                gigyaRoot: exception.gigyaRoot, gigyaKey: exception.gigyaKey, kamereonRoot: exception.kamereonRoot, kamereonKey: kamereonKey,
                country: country, language: language)
        }
        guard european.contains(locale) else { return nil }
        return RenaultServers(gigyaRoot: gigyaEU, gigyaKey: gigyaKeyEU, kamereonRoot: kamereonEU, kamereonKey: kamereonKey, country: country, language: language)
    }

    /// A locale the plugin does not list, from the MyRenault app's configuration file (3.1); its content type may be wrong,
    /// so the body is read as JSON whatever it says.
    static func fetch(_ locale: String, http: any HTTPSending, timeout: Duration) async throws -> RenaultServers {
        let safe = locale.filter { $0.isLetter || $0 == "_" }
        guard safe.count >= 4, safe.count <= 8, let url = URL(string: "\(configurationBase)/configuration/android/config_\(safe).json") else {
            throw RenaultError.unknownLocale(locale)
        }
        let response = try await http.send(HTTPRequest(method: "GET", url: url, timeout: timeout))
        guard response.isSuccess, let json = try? JSONValue(data: response.body),
            let gigyaKey = json["servers"]?["gigyaProd"]?["apikey"]?.stringValue,
            let gigyaRoot = json["servers"]?["gigyaProd"]?["target"]?.stringValue,
            let kamereonKey = json["servers"]?["wiredProd"]?["apikey"]?.stringValue,
            let kamereonRoot = json["servers"]?["wiredProd"]?["target"]?.stringValue,
            gigyaRoot.hasPrefix("https://"), kamereonRoot.hasPrefix("https://")
        else { throw RenaultError.unknownLocale(locale) }
        return RenaultServers(
            gigyaRoot: gigyaRoot, gigyaKey: gigyaKey, kamereonRoot: kamereonRoot, kamereonKey: kamereonKey,
            country: String(safe.suffix(2)).uppercased(), language: safe.split(separator: "_").first.map(String.init))
    }

    /// The servers of any locale: the table's, else Renault's configuration file.
    static func resolve(_ locale: String, http: any HTTPSending, timeout: Duration) async throws -> RenaultServers {
        if let servers = servers(for: locale) { return servers }
        return try await fetch(locale, http: http, timeout: timeout)
    }
}
