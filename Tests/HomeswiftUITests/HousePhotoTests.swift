import Foundation
import HomeswiftAI
import Testing
@testable import HomeswiftUI

struct HousePhotoTests {
    @Test func photoOwnershipAndMarkers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preferences.json")
        let store = PreferencesStore(url: url)
        let body: JSONValue = ["name": "Demo home", "description": "Sample photo", "width": 800, "height": 600,
            "markers": ["solar": [0.5, 0.2], "battery": [0.1, 0.8], "grid": [0.9, 0.6], "home": [0.5, 0.6]],
            "data": .string(Data([0xff, 0xd8, 0xff, 0xe0]).base64EncodedString())]
        let saved = try store.saveHouse(body, for: "alice")
        let version = try #require(saved["customHouse"]?["version"]?.stringValue)
        #expect(store.housePhoto(for: "alice", version: version) != nil)
        #expect(store.housePhoto(for: "bob", version: version) == nil)
        #expect(PreferencesStore(url: url).preferences(for: "alice")["customHouse"] == saved["customHouse"])
        var bad = try #require(body.objectValue)
        bad["markers"] = ["solar": [2, 0], "battery": [0, 0], "grid": [0, 0], "home": [0, 0]]
        #expect(throws: PreferencesError.self) { try store.saveHouse(.object(bad), for: "alice") }
        bad = try #require(body.objectValue)
        bad["data"] = "bm90IGFuIGltYWdl"
        #expect(throws: PreferencesError.self) { try store.saveHouse(.object(bad), for: "alice") }
        let replaced = try store.saveHouse(body, for: "alice")
        #expect(replaced["customHouse"]?["version"] != .string(version))
        #expect(store.housePhoto(for: "alice", version: version) == nil)
        _ = try store.removeHouse(for: "alice")
        #expect(store.preferences(for: "alice")["customHouse"] == nil)
        #expect(store.preferences(for: "alice")["energyHouseStyle"] == "realistic")
    }
}
