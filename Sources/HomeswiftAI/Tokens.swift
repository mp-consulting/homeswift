import Foundation

/// Rough token maths, good enough to keep inputs inside a model's context window.
public enum Tokens {
    static let charactersPerToken = 4

    /// Estimated token count of `text` (about 4 characters per token).
    public static func estimate(_ text: String) -> Int {
        (text.utf8.count + charactersPerToken - 1) / charactersPerToken
    }

    public enum Keep: Sendable { case head, tail }

    /// Cuts `text` to roughly `maxTokens`, on a line boundary when possible, and says how much was dropped
    /// so the model knows it is not seeing everything. `tail` (the default) suits logs.
    public static func trim(_ text: String, to maxTokens: Int, keep: Keep = .tail) -> String {
        let maxChars = max(0, maxTokens * charactersPerToken)
        guard text.count > maxChars else { return text }
        switch keep {
        case .tail:
            var kept = String(text.suffix(maxChars))
            if let newline = kept.firstIndex(of: "\n"), kept.index(after: newline) < kept.endIndex {
                kept = String(kept[kept.index(after: newline)...])
            }
            return "[… \(text.count - kept.count) earlier characters trimmed]\n\(kept)"
        case .head:
            var kept = String(text.prefix(maxChars))
            if let newline = kept.lastIndex(of: "\n"), newline > kept.startIndex {
                kept = String(kept[..<newline])
            }
            return "\(kept)\n[… \(text.count - kept.count) later characters trimmed]"
        }
    }

    /// Tokens left for variable input once the output and a fixed overhead (system prompt, instructions)
    /// are reserved, capped at `cap`.
    public static func inputBudget(contextTokens: Int, maxOutputTokens: Int, cap: Int = .max, overhead: Int = 1024) -> Int {
        max(256, min(cap, contextTokens - maxOutputTokens - overhead))
    }
}

/// Terminal escape codes in log text.
public enum ANSI {
    private static let pattern = try! NSRegularExpression(pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]")

    public static func strip(_ text: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// The last `maxLines` non-blank lines, without escape codes.
    public static func tailLines(_ text: String, maxLines: Int) -> [String] {
        let lines = strip(text).split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return maxLines > 0 ? Array(lines.suffix(maxLines)) : []
    }
}
