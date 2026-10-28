import Foundation
import Testing

@testable import HomeswiftUI

/// The stylesheet keeps to its tokens (docs/design-system.md, "Tokens"): a value that has a token is written as the
/// token, and the system's dark mode and the dark theme chosen in the web UI declare the same values.
@Suite(.timeLimit(.minutes(1)))
struct DesignTokenTests {
    static let css = String(decoding: WebAssets.files["style.css"]?.data ?? Data(), as: UTF8.self)

    /// The rules after the token definitions on `:root`, one line each.
    static var rules: [(number: Int, text: String)] {
        let lines = css.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "* { box-sizing: border-box; }") else { return [] }
        return lines.indices.filter { $0 > start }.map { ($0 + 1, lines[$0]) }
    }

    /// The lines whose `property: value` declarations have a value matching `pattern`.
    /// Derived values (`calc(var(--radius) - 3px)`) are allowed, so `calc()` is left out of the value first.
    static func offenders(_ properties: String, _ pattern: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"(?<![\w-])(?:"# + properties + #"):\s*([^;}]*)"#)
        let value = try NSRegularExpression(pattern: pattern)
        return rules.compactMap { line in
            let range = NSRange(line.text.startIndex..., in: line.text)
            let hits = expression.matches(in: line.text, range: range).contains { match in
                let declared = (line.text as NSString).substring(with: match.range(at: 1))
                    .replacingOccurrences(of: #"calc\((?:[^()]|\([^()]*\))*\)"#, with: "", options: .regularExpression)
                return value.firstMatch(in: declared, range: NSRange(declared.startIndex..., in: declared)) != nil
            }
            return hits ? "line \(line.number): \(line.text.trimmingCharacters(in: .whitespaces).prefix(100))" : nil
        }
    }

    @Test func radiiUseTheShapeScale() throws {
        // Hairline marks (under 6 px) stay literal; anything larger is a --radius token or derived from one in calc().
        let found = try Self.offenders("border(?:-[a-z]+)*-radius", #"(?<![\d.])([6-9]|[1-9]\d+)(\.\d+)?px"#)
        #expect(found.isEmpty, "use --radius-xs…xl, --radius or --radius-pill:\n\(found.joined(separator: "\n"))")
    }

    @Test func typeUsesTheRamp() throws {
        let ramp = #"(?<![\d.])(0?\.6875|0?\.75|0?\.8125|0?\.875|0?\.9375|1|1\.0625|1\.25|1\.375)rem"#
        let sizes = try Self.offenders("font-size", ramp)
        #expect(sizes.isEmpty, "use --text-2xs…3xl:\n\(sizes.joined(separator: "\n"))")
        let weights = try Self.offenders("font-weight", #"^\s*(400|500|600|650|700)\b"#)
        #expect(weights.isEmpty, "use --weight-regular…bold:\n\(weights.joined(separator: "\n"))")
    }

    @Test func spacingUsesTheScale() throws {
        let found = try Self.offenders("(?:row-|column-)?gap|padding(?:-[a-z-]+)?|margin(?:-[a-z-]+)?", #"(?<![\w.\-])(4|6|8|10|12|14|16|18|20|24)px\b"#)
        #expect(found.isEmpty, "use --space-N:\n\(found.joined(separator: "\n"))")
    }

    @Test func accentTintsMixTheAccent() {
        let copies = Self.rules.filter { $0.text.contains("rgba(255, 122, 26") }.map { "line \($0.number)" }
        #expect(copies.isEmpty, "write color-mix(in srgb, var(--accent) N%, transparent): \(copies)")
    }

    /// The dark tokens are written twice (prefers-color-scheme, and data-theme="dark" for a theme chosen in the UI):
    /// `light-dark()` would share them but is missing before iOS 17.5, where every colour would fall back.
    @Test func bothDarkThemesDeclareTheSameTokens() throws {
        func declarations(after opening: String) throws -> [String: String] {
            let start = try #require(Self.css.range(of: opening))
            let body = Self.css[start.upperBound...].prefix { $0 != "}" }
            var tokens: [String: String] = [:]
            for declaration in body.components(separatedBy: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if parts.count == 2, parts[0].hasPrefix("--") { tokens[parts[0]] = parts[1] }
            }
            return tokens
        }
        let system = try declarations(after: "@media (prefers-color-scheme: dark) {\n  :root:not(:where([data-theme=\"light\"])) {")
        let chosen = try declarations(after: ":root:where([data-theme=\"dark\"]) {")
        #expect(system.count > 20)
        #expect(system == chosen, "the two dark blocks differ: \(Set(system.keys).symmetricDifference(chosen.keys).sorted()) \(system.filter { chosen[$0.key] != $0.value }.keys.sorted())")
    }
}
