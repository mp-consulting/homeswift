import Foundation
import Homeswift
import Testing

@testable import HomeswiftPlugin

@Suite struct ControllerStorageTests {
    @Test func keepsStatesPerAccessoryAndControllerAcrossInstances() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-controllers-\(UUID().uuidString)/controllers/X-x.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let storage = ControllerStorage(url: url)
        try storage.save(Data("a".utf8), accessoryID: "lamp", controllerID: "characteristic-transition-1")
        try storage.save(Data("b".utf8), accessoryID: "camera", controllerID: "camera")

        let reloaded = ControllerStorage(url: url)
        #expect(reloaded.state(accessoryID: "lamp", controllerID: "characteristic-transition-1") == Data("a".utf8))
        #expect(reloaded.state(accessoryID: "camera", controllerID: "camera") == Data("b".utf8))
        try reloaded.save(nil, accessoryID: "lamp", controllerID: "characteristic-transition-1")
        #expect(ControllerStorage(url: url).state(accessoryID: "lamp", controllerID: "characteristic-transition-1") == nil)
        #if !os(Windows)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #endif
    }
}
