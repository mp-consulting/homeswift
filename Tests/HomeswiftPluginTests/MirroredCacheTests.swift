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

    /// A service type is its UUID: a light restored from the cache, before its plugin finds the device again, is still a
    /// Lightbulb to whatever looks for one (a remote's dimmer, a Helper).
    @Test func aRestoredServiceIsOfItsType() throws {
        let lamp = Accessory(id: "Lights:1", name: "Lamp", category: .lightbulb, services: [Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)])
        let restored = try JSONDecoder().decode(CachedAccessory.self, from: try JSONEncoder().encode(CachedAccessory(lamp))).restore()
        #expect(restored.services.contains { $0.type == .lightbulb })
        #expect(Set(restored.services.map(\.type)).contains(.lightbulb))
    }
}
