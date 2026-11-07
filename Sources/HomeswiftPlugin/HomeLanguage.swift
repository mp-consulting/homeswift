import Foundation

/// The Home Language (GLOSSARY.md): what the bridge writes with no one reader (notifications on shared channels, the
/// daily digest) is in it; someone known to be reading gets their own Language.
public enum HomeLanguage {
    /// The web UI's languages, which the bridge's own texts have too.
    public static let all = ["en", "fr", "es", "pt"]

    /// One of `all` for a setting or a language tag (`fr-CA`); English for anything else.
    public static func resolve(_ value: String?) -> String {
        guard let primary = value?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init), all.contains(primary) else { return "en" }
        return primary
    }
}
