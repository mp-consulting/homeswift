import Foundation
import Testing

@testable import HomeswiftAI

struct PromptTests {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HomeswiftAI/Prompts")
    }

    /// PromptFiles.swift has every Markdown file of Prompts/ as written (README.md is for people).
    @Test func embeddedPromptsAreCurrent() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path).filter { $0.hasSuffix(".md") && $0 != "README.md" }.sorted()
        #expect(names.map { String($0.dropLast(3)) } == PromptFiles.files.keys.sorted())
        for name in names {
            let file = try String(contentsOf: Self.directory.appendingPathComponent(name), encoding: .utf8)
            #expect(PromptFiles.files[String(name.dropLast(3))] == file,
                "\(name) is stale: run swift Scripts/embed-assets.swift prompts Sources/HomeswiftAI/Prompts Sources/HomeswiftAI/PromptFiles.swift")
        }
    }

    @Test func markdownReadsAsDocumented() {
        let texts = Dictionary(uniqueKeysWithValues: PromptBook.parse("""
            # Title, not sent

            Notes, not sent.

            ## one

            First line
            wraps here.

            Second paragraph, with a break  
            here.

            ## two
            {"json": "stays"} and {{value}}
            """))
        #expect(texts["one"] == "First line wraps here.\n\nSecond paragraph, with a break\nhere.")
        #expect(texts["two"] == #"{"json": "stays"} and {{value}}"#)
        #expect(texts.count == 2)
    }

    /// Every prompt renders with its values: no text is missing, no placeholder is left, and the untrusted data stays
    /// inside its tags.
    @Test func everyPromptRenders() {
        let prompts = [
            Prompts.base, Prompts.DiagnoseLogs.system, Prompts.DiagnoseLogs.user(logs: "a", focus: "Govee"), Prompts.DiagnoseLogs.user(logs: "a", focus: nil),
            Prompts.GeneratePluginConfig.system, Prompts.GeneratePluginConfig.user(request: "r", schema: ["type": "object"], current: ["a": 1], pluginName: "Govee"),
            Prompts.ExplainDeviceError.system, Prompts.ExplainDeviceError.user(error: "e", context: "c", device: ["m": 1], pluginName: "P"),
            Prompts.Ask.system, Prompts.Ask.user(prompt: "q", context: "c"), Prompts.SuggestOrganization.system,
            Prompts.SuggestOrganization.user(accessories: ["a": 1], rooms: ["Den"]), Prompts.DesignMood.system,
            Prompts.DesignMood.user(description: "d", lights: ["n": 1]), Prompts.DailyDigest.system,
            Prompts.DailyDigest.user(date: "d", status: ["s": 1], logs: "l", accessories: ["a": 1], events: ["e": 1]),
            Prompts.connectionTest, Prompts.Chat.system, Prompts.repairJSON("x"),
        ] + ["fr", "es-ES", "pt"].compactMap(Prompts.answerLanguage)
        for prompt in prompts {
            #expect(!prompt.isEmpty)
            #expect(!prompt.contains("{{"), "\(prompt)")
        }
        #expect(Prompts.base.contains(Redaction.placeholder))
        #expect(Prompts.DiagnoseLogs.user(logs: "a", focus: "Govee").contains("lines. Focus on: Govee."))
        #expect(Prompts.ExplainDeviceError.user(error: "boom", context: nil, device: nil, pluginName: nil).contains("<untrusted-data>\n```\nboom\n```\n</untrusted-data>"))
        #expect(Prompts.answerLanguage("en") == nil)
    }

    /// A person's text with placeholders in it goes in as written: it is not filled, and it does not stop the bridge.
    @Test func valuesAreNotReadForPlaceholders() {
        let prompt = Prompts.DesignMood.user(description: "a {{jazz}} bar, {{description}} and {{", lights: ["n": 1])
        #expect(prompt.contains("a {{jazz}} bar, {{description}} and {{"))
        #expect(Prompts.DiagnoseLogs.user(logs: "{{focus}}", focus: "Govee").contains("{{focus}}"))
    }
}
