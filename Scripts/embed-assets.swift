// Embeds files into Swift source, so a binary installed anywhere (Homebrew) carries them without a
// resource bundle. Run from the repository root:
//
//   swift Scripts/embed-assets.swift plugin Plugins/ElgatoKeyLights ElgatoKeyLightsPlugin
//   swift Scripts/embed-assets.swift web Sources/HomeswiftUI/Web Sources/HomeswiftUI/WebAssets.swift
//   swift Scripts/embed-assets.swift web Plugins/ElgatoKeyLights/Web Plugins/ElgatoKeyLights/Sources/WebFiles.swift ElgatoKeyLightsPlugin
//
// `plugin` turns <dir>/config.schema.json into <dir>/Sources/ConfigurationSchema.swift; `web` turns every
// file of the directory into one Swift file: the UI's own assets, or, with a plugin type as the last
// argument, that plugin's `webFiles`. Tests check the generated files are current.

import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard let mode = arguments.first else {
    FileHandle.standardError.write(Data("usage: embed-assets.swift plugin <plugin dir> <plugin type> | web <web dir> <output file> [<plugin type>]\n".utf8))
    exit(2)
}

/// A raw string literal that cannot be ended by its content.
func literal(_ text: String) -> String {
    var fence = "#"
    while text.contains("\"\"\"\(fence)") { fence += "#" }
    return "\(fence)\"\"\"\n\(text)\n\"\"\"\(fence)"
}

switch mode {
case "plugin":
    guard arguments.count == 3 else { exit(2) }
    let directory = arguments[arguments.startIndex + 1]
    let type = arguments[arguments.startIndex + 2]
    let schema = try String(contentsOfFile: "\(directory)/config.schema.json", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let output = """
        // THIS FILE IS GENERATED from ../config.schema.json by Scripts/embed-assets.swift - DO NOT EDIT.
        // swiftlint:disable all

        extension \(type) {
            /// The plugin's config.schema.json, as written, for settings forms and the config copilot.
            public static let configurationSchemaJSON: String? = \(literal(schema))
        }

        """
    try output.write(toFile: "\(directory)/Sources/ConfigurationSchema.swift", atomically: true, encoding: .utf8)
case "web":
    guard arguments.count == 3 || arguments.count == 4 else { exit(2) }
    let directory = arguments[arguments.startIndex + 1]
    let outputPath = arguments[arguments.startIndex + 2]
    let pluginType = arguments.count == 4 ? arguments[arguments.startIndex + 3] : nil
    let fileType = pluginType == nil ? "WebAsset" : "PluginWebFile"
    let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "svg": "image/svg+xml", "json": "application/json"]
    let names = try FileManager.default.contentsOfDirectory(atPath: directory).filter { !$0.hasPrefix(".") }.sorted()
    var entries: [String] = []
    for name in names {
        let content = try String(contentsOfFile: "\(directory)/\(name)", encoding: .utf8)
        let type = types[(name as NSString).pathExtension] ?? "application/octet-stream"
        entries.append("        \"\(name)\": \(fileType)(contentType: \"\(type)\", body: \(literal(content))),")
    }
    if let pluginType {
        let output = """
            // THIS FILE IS GENERATED from ../Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
            // swiftlint:disable all

            import HomeswiftPlugin

            extension \(pluginType) {
                /// The plugin's web pages, as written, served by the web UI under /plugins/<platform>/.
                public static let webFiles: [String: PluginWebFile] = [
            \(entries.joined(separator: "\n"))
                ]
            }

            """
        try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
        exit(0)
    }
    let output = """
        // THIS FILE IS GENERATED from Web/ by Scripts/embed-assets.swift - DO NOT EDIT.
        // swiftlint:disable all

        struct WebAsset: Sendable {
            let contentType: String
            let body: String
        }

        enum WebAssets {
            static let files: [String: WebAsset] = [
        \(entries.joined(separator: "\n"))
            ]
        }

        """
    try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
default:
    exit(2)
}
