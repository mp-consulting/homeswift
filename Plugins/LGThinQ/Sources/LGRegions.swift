import Foundation
import HomeswiftPlugin

/// The LG account regions the Homebridge plugin offers (its settings page's list): each a country and the language LG
/// takes with it, which are not all ones the system names (en-AM, zh-CN). Setup picks the country and the language
/// from them.
enum LGRegions {
    static let all: [(country: String, language: String)] = [
        ("AE", "ar-AE"), ("AE", "en-AE"), ("AG", "en-AG"), ("AL", "en-AL"), ("AL", "sq-AL"), ("AM", "en-AM"),
        ("AM", "fr-AM"), ("AO", "en-AO"), ("AR", "es-AR"), ("AT", "de-AT"), ("AT", "en-AT"), ("AU", "en-AU"),
        ("AZ", "en-AZ"), ("BA", "hr-BA"), ("BA", "sr-BA"), ("BB", "en-BB"), ("BD", "en-BD"), ("BE", "en-BE"),
        ("BE", "fr-BE"), ("BE", "nl-BE"), ("BF", "fr-BF"), ("BG", "bg-BG"), ("BG", "en-BG"), ("BH", "ar-BH"),
        ("BH", "en-BH"), ("BJ", "fr-BJ"), ("BO", "es-BO"), ("BR", "pt-BR"), ("BS", "en-BS"), ("BY", "ru-BY"),
        ("BZ", "en-BZ"), ("CA", "en-CA"), ("CA", "fr-CA"), ("CD", "fr-CD"), ("CF", "fr-CF"), ("CG", "fr-CG"),
        ("CH", "de-CH"), ("CH", "en-CH"), ("CH", "fr-CH"), ("CI", "fr-CI"), ("CL", "en-CL"), ("CL", "es-CL"),
        ("CM", "fr-CM"), ("CN", "en-CN"), ("CN", "zh-CN"), ("CO", "en-CO"), ("CO", "es-CO"), ("CR", "es-CR"),
        ("CU", "es-CU"), ("CV", "pt-CV"), ("CY", "el-CY"), ("CY", "en-CY"), ("CZ", "cs-CZ"), ("CZ", "en-CZ"),
        ("DE", "de-DE"), ("DE", "en-DE"), ("DJ", "fr-DJ"), ("DK", "da-DK"), ("DK", "en-DK"), ("DM", "en-DM"),
        ("DO", "es-DO"), ("DZ", "ar-DZ"), ("DZ", "en-DZ"), ("DZ", "fr-DZ"), ("EC", "en-EC"), ("EC", "es-EC"),
        ("EE", "en-EE"), ("EE", "et-EE"), ("EE", "ru-EE"), ("EG", "ar-EG"), ("EG", "en-EG"), ("ES", "en-ES"),
        ("ES", "es-ES"), ("ET", "en-ET"), ("FI", "en-FI"), ("FI", "fi-FI"), ("FR", "fr-FR"), ("GA", "fr-GA"),
        ("GB", "en-GB"), ("GD", "en-GD"), ("GE", "en-GE"), ("GH", "en-GH"), ("GM", "en-GM"), ("GN", "fr-GN"),
        ("GQ", "es-GQ"), ("GQ", "fr-GQ"), ("GR", "el-GR"), ("GR", "en-GR"), ("GT", "es-GT"), ("GY", "en-GY"),
        ("HK", "en-HK"), ("HK", "zh-HK"), ("HN", "es-HN"), ("HR", "en-HR"), ("HR", "hr-HR"), ("HT", "fr-HT"),
        ("HU", "en-HU"), ("HU", "hu-HU"), ("ID", "en-ID"), ("ID", "id-ID"), ("IE", "en-IE"), ("IL", "en-IL"),
        ("IN", "en-IN"), ("IQ", "ar-IQ"), ("IQ", "en-IQ"), ("IR", "en-IR"), ("IS", "en-IS"), ("IT", "en-IT"),
        ("IT", "it-IT"), ("JM", "en-JM"), ("JO", "ar-JO"), ("JO", "en-JO"), ("JP", "ja-JP"), ("KE", "en-KE"),
        ("KG", "ru-KG"), ("KH", "en-KH"), ("KN", "en-KN"), ("KR", "ko-KR"), ("KW", "ar-KW"), ("KW", "en-KW"),
        ("KZ", "en-KZ"), ("KZ", "kk-KZ"), ("KZ", "ru-KZ"), ("LB", "ar-LB"), ("LB", "en-LB"), ("LC", "en-LC"),
        ("LK", "en-LK"), ("LR", "en-LR"), ("LT", "en-LT"), ("LT", "lt-LT"), ("LU", "de-LU"), ("LU", "en-LU"),
        ("LU", "fr-LU"), ("LV", "en-LV"), ("LV", "lv-LV"), ("LY", "ar-LY"), ("LY", "en-LY"), ("MA", "ar-MA"),
        ("MA", "en-MA"), ("MA", "fr-MA"), ("MD", "ro-MD"), ("MD", "ru-MD"), ("ME", "en-ME"), ("ME", "sr-ME"),
        ("MK", "en-MK"), ("MK", "mk-MK"), ("ML", "fr-ML"), ("MM", "en-MM"), ("MT", "en-MT"), ("MU", "en-MU"),
        ("MX", "en-MX"), ("MX", "es-MX"), ("MY", "en-MY"), ("NE", "fr-NE"), ("NG", "en-NG"), ("NI", "es-NI"),
        ("NL", "en-NL"), ("NL", "nl-NL"), ("NO", "en-NO"), ("NO", "no-NO"), ("NZ", "en-NZ"), ("OM", "ar-OM"),
        ("OM", "en-OM"), ("PA", "en-PA"), ("PA", "es-PA"), ("PE", "en-PE"), ("PE", "es-PE"), ("PH", "en-PH"),
        ("PK", "en-PK"), ("PL", "en-PL"), ("PL", "pl-PL"), ("PR", "es-PR"), ("PS", "en-PS"), ("PT", "en-PT"),
        ("PT", "pt-PT"), ("PY", "es-PY"), ("QA", "ar-QA"), ("QA", "en-QA"), ("RO", "en-RO"), ("RO", "ro-RO"),
        ("RS", "en-RS"), ("RS", "sr-RS"), ("RU", "ru-RU"), ("RW", "fr-RW"), ("SA", "ar-SA"), ("SA", "en-SA"),
        ("SD", "en-SD"), ("SE", "en-SE"), ("SE", "sv-SE"), ("SG", "en-SG"), ("SI", "en-SI"), ("SI", "sl-SI"),
        ("SK", "en-SK"), ("SK", "sk-SK"), ("SL", "en-SL"), ("SN", "fr-SN"), ("SO", "en-SO"), ("SR", "nl-SR"),
        ("ST", "pt-ST"), ("SV", "es-SV"), ("SY", "ar-SY"), ("SY", "en-SY"), ("TD", "fr-TD"), ("TG", "fr-TG"),
        ("TH", "en-TH"), ("TH", "th-TH"), ("TN", "ar-TN"), ("TN", "en-TN"), ("TR", "en-TR"), ("TR", "tr-TR"),
        ("TT", "en-TT"), ("TW", "en-TW"), ("TW", "zh-TW"), ("TZ", "en-TZ"), ("UA", "ru-UA"), ("UA", "uk-UA"),
        ("UG", "en-UG"), ("US", "en-US"), ("UY", "es-UY"), ("UZ", "en-UZ"), ("UZ", "ru-UZ"), ("UZ", "uz-UZ"),
        ("VC", "en-VC"), ("VE", "es-VE"), ("VN", "en-VN"), ("VN", "vi-VN"), ("XK", "en-XK"), ("YE", "ar-YE"),
        ("YE", "en-YE"), ("ZA", "en-ZA"), ("ZM", "en-ZM"),
    ]

    /// The countries, as Setup offers them.
    static func countries() -> [SetupOption] {
        var seen = Set<String>()
        return SetupOption.countries(all.map(\.country).filter { seen.insert($0).inserted })
    }

    /// The languages, named in English by their tag (French (France)), as Setup offers them.
    static func languages() -> [SetupOption] {
        let english = Locale(identifier: "en_US")
        var seen = Set<String>()
        return all.map(\.language).filter { seen.insert($0).inserted }.map { tag in
            SetupOption(tag, label: english.localizedString(forIdentifier: tag.replacingOccurrences(of: "-", with: "_")) ?? tag, language: tag)
        }.sorted { $0.label < $1.label }
    }
}
