import Foundation

/// Readable names: the web UI's addresses (`/plugins/dyson-pure-cool`) and the vault's suggested entries. Lower case,
/// accents dropped, anything but letters and digits as one dash. common.js's `slug` does the same for the names it
/// links to.
public enum Slug {
    public static func make(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        if slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    /// One slug per name, in order, unique: a name already taken gets `-2`, `-3`…; a name with no letter or digit
    /// falls back to `fallback`.
    public static func unique(_ names: [String], fallback: String) -> [String] {
        var taken = Set<String>()
        return names.map { name in
            let base = make(name).isEmpty ? fallback : make(name)
            var slug = base
            var suffix = 2
            while taken.contains(slug) {
                slug = "\(base)-\(suffix)"
                suffix += 1
            }
            taken.insert(slug)
            return slug
        }
    }
}
