// Embeds Resources/scene-library.json, the scene catalogue the Govee app ships (trimmed to the fields the
// plugin uses), into Sources/SceneLibraryData.swift, so the binary carries it without a resource bundle.
// Run from the repository root after updating the JSON (a test checks the two match):
//
//   swift Plugins/Govee/Scripts/embed-scene-library.swift

import Foundation

let json = try String(contentsOfFile: "Plugins/Govee/Resources/scene-library.json", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
var fence = "#"
while json.contains("\"\"\"\(fence)") { fence += "#" }
let output = """
    // THIS FILE IS GENERATED from ../Resources/scene-library.json by ../Scripts/embed-scene-library.swift - DO NOT EDIT.
    // swiftlint:disable all

    extension SceneCatalogue {
        /// The scene catalogue of the Govee app, as JSON: `rgb` and `rgbic` category lists and the RGBIC models.
        static let json = \(fence)\"\"\"
    \(json)
    \"\"\"\(fence)
    }

    """
try output.write(toFile: "Plugins/Govee/Sources/SceneLibraryData.swift", atomically: true, encoding: .utf8)
