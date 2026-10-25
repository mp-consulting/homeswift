import Foundation
import Homeswift
import Testing

@testable import HomeswiftPlugin

/// A mirrored accessory comes back from the cache mirrored, with its room: at launch it stays out of HomeKit before
/// its plugin runs.
@Suite struct MirroredCacheTests {
    @Test func theCacheKeepsTheMirrorAndTheRoom() throws {
        let lamp = Accessory(id: "Wingman:1", name: "Lamp", category: .lightbulb, services: [Service(.lightbulb, name: "Lamp", isPrimary: true)])
        lamp.mirroredFrom = "Apple Home"
        lamp.suggestedRoom = "Salon"
        let data = try JSONEncoder().encode(CachedAccessory(lamp))
        let restored = try JSONDecoder().decode(CachedAccessory.self, from: data).restore()
        #expect(restored.mirroredFrom == "Apple Home")
        #expect(restored.suggestedRoom == "Salon")

        let plain = try JSONDecoder().decode(CachedAccessory.self, from: try JSONEncoder().encode(CachedAccessory(Accessory(id: "x", name: "x", services: [])))).restore()
        #expect(plain.mirroredFrom == nil)
    }
}
