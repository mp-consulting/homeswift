// Embeds files into Swift source, so a binary installed anywhere (Homebrew) carries them without a
// resource bundle. Run from the repository root:
//
//   swift Scripts/embed-assets.swift all
//
//   swift Scripts/embed-assets.swift plugin Plugins/ElgatoKeyLights ElgatoKeyLightsPlugin
//   swift Scripts/embed-assets.swift web Sources/HomeswiftUI/Web Sources/HomeswiftUI/WebAssets.swift
//   swift Scripts/embed-assets.swift web Plugins/ElgatoKeyLights/Web Plugins/ElgatoKeyLights/Sources/WebFiles.swift ElgatoKeyLightsPlugin
//   swift Scripts/embed-assets.swift prompts Sources/HomeswiftAI/Prompts Sources/HomeswiftAI/PromptFiles.swift
//
// `plugin` turns <dir>/config.schema.json into <dir>/Sources/ConfigurationSchema.swift; `web` turns every
// file of the directory into one Swift file: the UI's own assets, or, with a plugin type as the last
// argument, that plugin's `webFiles`; `prompts` turns the Assistant's Markdown prompts (every .md but README.md) into
// `PromptFiles.files`. `all` embeds the repository in one process, including both Shelly schemas and Govee scenes.
// Tests check the generated files are current.

import Foundation

/// A raw string literal that cannot be ended by its content.
func literal(_ text: String) -> String {
    var fence = "#"
    while text.contains("\"\"\"\(fence)") { fence += "#" }
    return "\(fence)\"\"\"\n\(text)\n\"\"\"\(fence)"
}

/// Do not invalidate compiler inputs when embedding changed nothing.
func writeIfChanged(_ output: String, to path: String) throws {
    let bytes = Data(output.utf8)
    if (try? Data(contentsOf: URL(fileURLWithPath: path))) == bytes { return }
    try bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
}

func embed(_ arguments: ArraySlice<String>) throws {
    guard let mode = arguments.first else { exit(2) }
    switch mode {
    case "all":
        guard arguments.count == 1 else { exit(2) }
        try embed(["web", "Sources/HomeswiftUI/Web", "Sources/HomeswiftUI/WebAssets.swift"])
        try embed(["prompts", "Sources/HomeswiftAI/Prompts", "Sources/HomeswiftAI/PromptFiles.swift"])
        for name in try FileManager.default.contentsOfDirectory(atPath: "Plugins").sorted() {
            let directory = "Plugins/\(name)"
            if FileManager.default.fileExists(atPath: "\(directory)/config.schema.json") {
                // Shelly has two platforms; its main schema belongs to ShellyNG.
                let type = name == "Shelly" ? "ShellyNGPlugin" : "\(name)Plugin"
                try embed(["plugin", directory, type])
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: "\(directory)/Web", isDirectory: &isDirectory), isDirectory.boolValue {
                try embed(["web", "\(directory)/Web", "\(directory)/Sources/WebFiles.swift", "\(name)Plugin"])
            }
        }
        if FileManager.default.fileExists(atPath: "Plugins/Shelly/config.gen1.schema.json") {
            try embed(["plugin", "Plugins/Shelly", "ShellyPlugin", "config.gen1.schema.json"])
        }
        if FileManager.default.fileExists(atPath: "Plugins/Govee/Resources/scene-library.json") {
            try embed(["govee-scenes", "Plugins/Govee"])
        }
    case "govee-scenes":
        guard arguments.count == 2 else { exit(2) }
        let directory = arguments[arguments.startIndex + 1]
        let json = try String(contentsOfFile: "\(directory)/Resources/scene-library.json", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = """
            // THIS FILE IS GENERATED from ../Resources/scene-library.json by ../Scripts/embed-scene-library.swift - DO NOT EDIT.
            // swiftlint:disable all

            extension SceneCatalogue {
                /// The scene catalogue of the Govee app, as JSON: `rgb` and `rgbic` category lists and the RGBIC models.
                static let json = \(literal(json))
            }

            """
        try writeIfChanged(output, to: "\(directory)/Sources/SceneLibraryData.swift")
    case "plugin":
        guard arguments.count == 3 || arguments.count == 4 else { exit(2) }
        let directory = arguments[arguments.startIndex + 1]
        let type = arguments[arguments.startIndex + 2]
        // A directory with two platforms gives the second one's schema file (`config.gen1.schema.json`), embedded as
        // Sources/<type>Schema.swift.
        let schemaFile = arguments.count == 4 ? arguments[arguments.startIndex + 3] : "config.schema.json"
        let outputFile = arguments.count == 4 ? "\(type)Schema.swift" : "ConfigurationSchema.swift"
        let schema = try String(contentsOfFile: "\(directory)/\(schemaFile)", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let output = """
            // THIS FILE IS GENERATED from ../\(schemaFile) by Scripts/embed-assets.swift - DO NOT EDIT.
            // swiftlint:disable all

            extension \(type) {
                /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
                public static let configurationSchemaJSON: String? = \(literal(schema))
            }

            """
        try writeIfChanged(output, to: "\(directory)/Sources/\(outputFile)")
    case "web":
        guard arguments.count == 3 || arguments.count == 4 else { exit(2) }
        let directory = arguments[arguments.startIndex + 1]
        let outputPath = arguments[arguments.startIndex + 2]
        let pluginType = arguments.count == 4 ? arguments[arguments.startIndex + 3] : nil
        let types = [
            "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "svg": "image/svg+xml", "json": "application/json",
            "webmanifest": "application/manifest+json", "png": "image/png", "webp": "image/webp",
        ]
        // Images other than SVG are bytes: embedded in base64.
        let binary: Set<String> = ["png", "webp"]
        let names = try FileManager.default.contentsOfDirectory(atPath: directory).filter { !$0.hasPrefix(".") }.sorted()
        var entries: [String] = []
        for name in names {
            let ext = (name as NSString).pathExtension
            let type = types[ext] ?? "application/octet-stream"
            if binary.contains(ext) {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: "\(directory)/\(name)"))
                entries.append("        \"\(name)\": WebFile(contentType: \"\(type)\", base64: \"\(bytes.base64EncodedString())\"),")
                continue
            }
            let content = try String(contentsOfFile: "\(directory)/\(name)", encoding: .utf8)
            entries.append("        \"\(name)\": WebFile(contentType: \"\(type)\", body: \(literal(content))),")
        }
        // The UI's own assets are an enum; a plugin's are its `webFiles`. Both are the same type, served the same way.
        let declaration = pluginType.map {
            "extension \($0) {\n    /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.\n    public static let webFiles: [String: WebFile] = ["
        } ?? "enum WebAssets {\n    /// The UI's pages, as written.\n    static let files: [String: WebFile] = ["
        let output = """
            // THIS FILE IS GENERATED from \(pluginType == nil ? "Web/" : "../Web/") by Scripts/embed-assets.swift - DO NOT EDIT.
            // swiftlint:disable all

            import HomeswiftPlugin

            \(declaration)
            \(entries.joined(separator: "\n"))
                ]
            }

            """
        try writeIfChanged(output, to: outputPath)
    case "prompts":
        guard arguments.count == 3 else { exit(2) }
        let directory = arguments[arguments.startIndex + 1]
        let outputPath = arguments[arguments.startIndex + 2]
        let names = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".md") && $0 != "README.md" }.sorted()
        var entries: [String] = []
        for name in names {
            let content = try String(contentsOfFile: "\(directory)/\(name)", encoding: .utf8)
            entries.append("        \"\(name.dropLast(3))\": \(literal(content)),")
        }
        let output = """
            // THIS FILE IS GENERATED from Prompts/ by Scripts/embed-assets.swift - DO NOT EDIT.
            // swiftlint:disable all

            enum PromptFiles {
                /// The Assistant's prompts as written in Prompts/, by file name without .md; `PromptBook` reads them.
                static let files: [String: String] = [
            \(entries.joined(separator: "\n"))
                ]
            }

            """
        try writeIfChanged(output, to: outputPath)
    default:
        exit(2)
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard !arguments.isEmpty else {
    FileHandle.standardError.write(Data("usage: embed-assets.swift all | plugin <dir> <type> [schema] | web <dir> <output> [type] | prompts <dir> <output> | govee-scenes <dir>\n".utf8))
    exit(2)
}
try embed(arguments)
