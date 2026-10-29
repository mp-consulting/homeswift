import Foundation

/// Prompt templates shared by the Assistant features (and later the MCP prompts), so every client asks
/// the same questions the same way. The words are in `Prompts/` (Markdown, embedded by Scripts/embed-assets.swift);
/// this file puts in the values and the data, inside `<untrusted-data>` tags.
public enum Prompts {
    public static let base = PromptBook.text("base.base", ["placeholder": Redaction.placeholder])

    static func section(_ title: String, _ body: String?) -> String {
        guard let body, !body.isEmpty else { return "" }
        return "\n\n## \(title)\n\(body)"
    }

    static func fenced(_ text: String) -> String { "```\n\(text)\n```" }

    static func untrusted(_ text: String) -> String { "<untrusted-data>\n\(text)\n</untrusted-data>" }

    /// A file's system prompt, which starts with `base`.
    static func system(_ file: String) -> String { PromptBook.text("\(file).system", ["base": base]) }

    /// An optional fragment of a file, after a space; empty without a value.
    static func fragment(_ key: String, _ name: String, _ value: String?) -> String {
        value.map { " " + PromptBook.text(key, [name: $0]) } ?? ""
    }

    public enum DiagnoseLogs {
        public static let system = Prompts.system("diagnose-logs")
        public static func user(logs: String, focus: String?) -> String {
            PromptBook.text("diagnose-logs.user", ["focus": fragment("diagnose-logs.focus", "focus", focus)])
                + section(PromptBook.text("diagnose-logs.title-logs"), untrusted(fenced(logs)))
        }
    }

    public enum GeneratePluginConfig {
        public static let system = Prompts.system("generate-plugin-config")
        public static func user(request: String, schema: JSONValue, current: JSONValue?, pluginName: String?) -> String {
            PromptBook.text("generate-plugin-config.user", [
                "plugin": fragment("generate-plugin-config.plugin", "name", pluginName), "request": request,
                "current": current == nil ? "" : " " + PromptBook.text("generate-plugin-config.current"),
            ])
                + section(PromptBook.text("generate-plugin-config.title-schema"), schema.text(pretty: true))
                + section(PromptBook.text("generate-plugin-config.title-current"), current?.text(pretty: true))
        }
    }

    public enum ExplainDeviceError {
        public static let system = Prompts.system("explain-device-error")
        public static func user(error: String, context: String?, device: JSONValue?, pluginName: String?) -> String {
            PromptBook.text("explain-device-error.user", ["plugin": fragment("explain-device-error.plugin", "name", pluginName)])
                + section(PromptBook.text("explain-device-error.title-error"), untrusted(fenced(error)))
                + section(PromptBook.text("explain-device-error.title-device"), device.map { untrusted($0.text(pretty: true)) })
                + section(PromptBook.text("explain-device-error.title-context"), context.map(untrusted))
        }
    }

    public enum Ask {
        public static let system = Prompts.system("ask")
        public static func user(prompt: String, context: String?) -> String {
            prompt + section(PromptBook.text("ask.title-context"), context.map(untrusted))
        }
    }

    public enum SuggestOrganization {
        public static let system = Prompts.system("suggest-organization")
        public static func user(accessories: JSONValue, rooms: JSONValue?) -> String {
            PromptBook.text("suggest-organization.user")
                + section(PromptBook.text("suggest-organization.title-accessories"), untrusted(accessories.text(pretty: true)))
                + section(PromptBook.text("suggest-organization.title-rooms"), rooms.map { untrusted($0.text(pretty: true)) })
        }
    }

    public enum DesignScene {
        public static let system = Prompts.system("design-scene")
        public static func user(description: String, lights: JSONValue) -> String {
            PromptBook.text("design-scene.user", ["description": description])
                + section(PromptBook.text("design-scene.title-lights"), lights.text(pretty: true))
        }
    }

    public enum DailyDigest {
        public static let system = Prompts.system("daily-digest")
        public static func user(date: String, status: JSONValue?, logs: String?, accessories: JSONValue?, events: JSONValue?) -> String {
            PromptBook.text("daily-digest.user", ["date": date])
                + section(PromptBook.text("daily-digest.title-status"), status.map { untrusted($0.text(pretty: true)) })
                + section(PromptBook.text("daily-digest.title-accessories"), accessories.map { untrusted($0.text(pretty: true)) })
                + section(PromptBook.text("daily-digest.title-events"), events.map { untrusted($0.text(pretty: true)) })
                + section(PromptBook.text("daily-digest.title-logs"), logs.flatMap { $0.isEmpty ? nil : untrusted(fenced($0)) })
        }
    }

    /// The instruction to answer in the language of the web UI's reader, by its BCP 47 tag ("fr-FR", "pt"): nil for
    /// English and for languages the UI does not speak, which the model then picks by itself.
    public static func answerLanguage(_ tag: String?) -> String? {
        guard let code = tag?.lowercased().split(separator: "-").first.map(String.init), ["fr", "es", "pt"].contains(code) else { return nil }
        return PromptBook.text("answer-language.instruction", ["language": PromptBook.text("answer-language.\(code)")])
    }

    /// The connection test's one-word request.
    public static let connectionTest = PromptBook.text("base.connection-test")

    /// The web UI's chat, where the Assistant acts through tools.
    public enum Chat {
        public static let system = Prompts.system("chat")
    }

    /// Asks the model to fix JSON that failed validation.
    public static func repairJSON(_ errors: String) -> String {
        PromptBook.text("base.repair-json", ["errors": errors])
    }
}
