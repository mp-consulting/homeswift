import Foundation

/// The Assistant's prompts, read from the Markdown of `Prompts/` (embedded in `PromptFiles.swift`): each `## name`
/// of `<file>.md` is the text `<file>.<name>`. A paragraph's lines are joined with spaces, a blank line is a paragraph
/// break, and a line ending with two spaces keeps its line break; what comes before the first heading is not sent.
/// `{{name}}` is filled by `text(_:_:)`.
enum PromptBook {
    static let texts: [String: String] = {
        var texts: [String: String] = [:]
        for (file, content) in PromptFiles.files {
            for (name, text) in parse(content) { texts["\(file).\(name)"] = text }
        }
        return texts
    }()

    /// The text `key` with its `{{name}}` placeholders filled. A missing text or value is a mistake of this module, caught
    /// by `PromptTests`, so it traps rather than sending a broken prompt.
    static func text(_ key: String, _ values: [String: String] = [:]) -> String {
        guard var text = texts[key] else { preconditionFailure("no prompt \(key) in Prompts/") }
        for (name, value) in values { text = text.replacingOccurrences(of: "{{\(name)}}", with: value) }
        precondition(!text.contains("{{"), "prompt \(key) has a placeholder left: \(text)")
        return text
    }

    /// The texts of one file, by heading.
    static func parse(_ markdown: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var name: String?
        var lines: [String] = []
        func finish() {
            if let name { result.append((name, join(lines))) }
            lines = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                finish()
                name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if name != nil {
                lines.append(line)
            }
        }
        finish()
        return result
    }

    /// Paragraphs joined with a blank line, a paragraph's lines with a space (or a line break after two trailing spaces).
    static func join(_ lines: [String]) -> String {
        var paragraphs: [String] = []
        var current = ""
        var breakNext = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current) }
                current = ""
                breakNext = false
                continue
            }
            let hardBreak = line.hasSuffix("  ")
            var content = line
            while content.last == " " { content.removeLast() }
            if current.isEmpty {
                current = content
            } else {
                current += (breakNext ? "\n" : " ") + content
            }
            breakNext = hardBreak
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }
}
