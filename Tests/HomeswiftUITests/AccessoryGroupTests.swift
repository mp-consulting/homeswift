import Foundation
import HomeswiftAI
import Testing
@testable import HomeswiftUI

struct AccessoryGroupTests {
    @Test func persistsGroupsAndRejectsAmbiguousMembership() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AccessoryLayout(url: folder.appendingPathComponent("layout.json"))
        let group: JSONValue = ["id": "group:test", "name": "Living room", "members": ["a", "b"]]
        let saved = try store.save(["groups": .array([group])])
        #expect(store.load() == saved)
        #expect(saved["groups"]?.arrayValue?.count == 1)
        #expect(throws: (any Error).self) { try store.save(["groups": .array([group, ["id": "group:second", "name": "Other", "members": ["b", "c"]]])]) }
        #expect(store.load() == saved)
        #expect(throws: (any Error).self) { try store.save(["groups": [["id": "group:nested", "name": "Nested", "members": ["group:test", "c"]]]]) }
        #expect(try AccessoryLayout.checked([:])["groups"] == nil)
    }
}
