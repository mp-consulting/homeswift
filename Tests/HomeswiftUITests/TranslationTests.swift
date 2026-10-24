import Foundation
import HomeswiftAI
import Testing

/// The pages' strings and their catalogs (docs/translations.md): every `t("…")` and `tn("…", "…")` literal and every
/// `data-i18n` text of the UI's pages and plugins' pages has a French, Spanish and Portuguese translation that keeps
/// its placeholders.
@Suite struct TranslationTests {
    static let languages = ["fr", "es", "pt"]
    static var root: URL { EmbeddingTests.root }

    /// The Assistant answers in the page's language, by its Accept-Language tag; English and other languages get no instruction.
    @Test func assistantAnswersInThePagesLanguage() {
        #expect(Prompts.answerLanguage("fr-FR")?.contains("French") == true)
        #expect(Prompts.answerLanguage("pt")?.contains("European Portuguese") == true)
        #expect(Prompts.answerLanguage("ES-es")?.contains("Spanish") == true)
        #expect(Prompts.answerLanguage("en-GB") == nil)
        #expect(Prompts.answerLanguage("de-DE") == nil)
        #expect(Prompts.answerLanguage(nil) == nil)
    }

    @Test func webStringsAreTranslated() throws {
        let web = Self.root.appendingPathComponent("Sources/HomeswiftUI/Web")
        var core: [String: [String: String]] = [:]
        for language in Self.languages {
            let entries = try Self.catalog(web.appendingPathComponent("i18n-\(language).js"))
            core[language] = entries[language] ?? [:]
        }
        // The three catalogs translate the same strings.
        let keys = Set(core["fr"].map { Array($0.keys) } ?? [])
        for language in Self.languages { #expect(Set(core[language].map { Array($0.keys) } ?? []) == keys, "i18n-\(language).js has other keys than i18n-fr.js") }
        try Self.expectTranslated(directory: web, catalogs: core)

        let plugins = Self.root.appendingPathComponent("Plugins")
        for name in try FileManager.default.contentsOfDirectory(atPath: plugins.path).sorted() {
            let directory = plugins.appendingPathComponent(name).appendingPathComponent("Web")
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            var catalogs = core
            let own = directory.appendingPathComponent("i18n.js")
            if FileManager.default.fileExists(atPath: own.path) {
                for (language, entries) in try Self.catalog(own) { catalogs[language, default: [:]].merge(entries) { _, plugin in plugin } }
            }
            try Self.expectTranslated(directory: directory, catalogs: catalogs)
        }
    }

    /// A catalog file: `HomeswiftI18n.add("fr", {…});` or a plugin's `HomeswiftI18n.add({"fr": {…}, …});`.
    static func catalog(_ url: URL) throws -> [String: [String: String]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let call = text.range(of: "HomeswiftI18n.add("), let open = text[call.upperBound...].firstIndex(of: "{"),
              let close = text.lastIndex(of: "}") else { throw CatalogFormatError(file: url.lastPathComponent) }
        let object = try JSONSerialization.jsonObject(with: Data(text[open...close].utf8))
        if let language = text[call.upperBound..<open].split(separator: "\"").first(where: { Self.languages.contains(String($0)) }) {
            return [String(language): object as? [String: String] ?? [:]]
        }
        return object as? [String: [String: String]] ?? [:]
    }

    struct CatalogFormatError: Error { let file: String }

    static func expectTranslated(directory: URL, catalogs: [String: [String: String]]) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        where (name.hasSuffix(".js") || name.hasSuffix(".html")) && !name.hasPrefix("i18n") {
            let source = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            for key in strings(in: source, html: name.hasSuffix(".html")) {
                for language in languages {
                    let translation = catalogs[language]?[key]
                    #expect(translation?.isEmpty == false, "\(directory.lastPathComponent)/\(name): no \(language) translation of \"\(key)\"")
                    if let translation, !translation.isEmpty {
                        #expect(placeholders(translation) == placeholders(key), "\(directory.lastPathComponent)/\(name): the \(language) translation of \"\(key)\" changes its placeholders")
                    }
                }
            }
        }
    }

    /// The literals of `t("…")` and `tn("…", "…")`, decoded; in HTML, the text and attributes of `data-i18n` elements.
    static func strings(in source: String, html: Bool) -> Set<String> {
        var found = Set<String>()
        let literal = #""((?:[^"\\]|\\.)*)""#
        for match in matches(#"\bt\("# + literal, in: source) { found.insert(decode(match[1])) }
        for match in matches(#"\btn\("# + literal + #",\s*"# + literal, in: source) { found.insert(decode(match[1])); found.insert(decode(match[2])) }
        if html {
            for match in matches(#"<\w+\b([^>]*\bdata-i18n\b[^>]*)>([^<]*)"#, in: source) {
                let text = match[2].split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !text.isEmpty { found.insert(text) }
                for attribute in matches(#"\b(?:title|aria-label|placeholder|alt)="([^"]*)""#, in: match[1]) where !attribute[1].isEmpty {
                    found.insert(attribute[1])
                }
            }
        }
        return found
    }

    static func matches(_ pattern: String, in text: String) -> [[String]] {
        let expression = try! NSRegularExpression(pattern: pattern)
        let string = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : string.substring(with: match.range(at: $0)) }
        }
    }

    /// A JavaScript string literal's text: its escapes read as JSON's.
    static func decode(_ literal: String) -> String {
        (try? JSONSerialization.jsonObject(with: Data("\"\(literal)\"".utf8), options: .fragmentsAllowed)) as? String ?? literal
    }

    static func placeholders(_ text: String) -> [String] {
        matches(#"\{(\w+)\}"#, in: text).map { $0[1] }.sorted()
    }
}
