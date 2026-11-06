import Foundation
import Testing

@testable import Homeswift

/// `Options.uniqueSerialNumbers`: accessories a plugin gave the same Serial Number (a device's channels) are told apart,
/// the one with the lowest aid keeping it, so a controller that knows accessories by serial number finds each.
@Suite struct UniqueSerialNumberTests {
    func server(unique: Bool = true) throws -> HAPServer {
        var options = HAPServer.Options(port: 0, advertise: false, logger: testLogger)
        options.uniqueSerialNumbers = unique
        return try HAPServer(
            bridge: Accessory(id: "bridge", name: "Test Bridge", serialNumber: "0E:11:22:33:44:55", category: .bridge, services: []),
            accessories: [], storage: MemoryStorage(), options: options)
    }

    func outlet(_ id: String, serialNumber: String) -> Accessory {
        Accessory(id: id, name: id, serialNumber: serialNumber, category: .outlet, services: [Service(.outlet, isPrimary: true)])
    }

    func serialNumber(_ accessory: Accessory) -> String? { accessory.information[.serialNumber]?.value.stringValue }

    @Test func accessoriesThatShareASerialNumberAreToldApart() throws {
        let server = try server()
        let first = outlet("Plugs:1000a", serialNumber: "1000a")
        let second = outlet("Plugs:1000a:1", serialNumber: "1000a")
        let other = outlet("Plugs:2000b", serialNumber: "2000b")
        try server.add(first)
        try server.add(second)
        try server.add(other)
        #expect(serialNumber(first) == "1000a")
        #expect(serialNumber(second) == "1000a-\(second.aid)")
        #expect(serialNumber(other) == "2000b")

        // Added again as it is (a new name), it keeps the one it was given; a new object with the plugin's keeps it too.
        try server.add(second)
        #expect(serialNumber(second) == "1000a-\(second.aid)")
        let again = outlet("Plugs:1000a:1", serialNumber: "1000a")
        try server.add(again)
        #expect(serialNumber(again) == "1000a-\(again.aid)")

        // The first leaves: the other has the plain one back, and gives it up when the first, with its old aid, returns.
        try server.remove(first)
        #expect(serialNumber(again) == "1000a")
        try server.add(first)
        #expect(serialNumber(first) == "1000a")
        #expect(serialNumber(again) == "1000a-\(again.aid)")
        // The bridge's own is never touched.
        #expect(serialNumber(server.primary) == "0E:11:22:33:44:55")
    }

    @Test func aMirroredAccessoryNeitherTakesNorKeepsOne() throws {
        let server = try server()
        let own = outlet("Plugs:1", serialNumber: "SN")
        let mirrored = outlet("Wingman:1", serialNumber: "SN")
        mirrored.mirroredFrom = "Apple Home"
        try server.add(own)
        try server.add(mirrored)
        #expect(serialNumber(own) == "SN")
        #expect(serialNumber(mirrored) == "SN")
    }

    @Test func withoutTheOptionSerialNumbersStayAsThePluginGaveThem() throws {
        let server = try server(unique: false)
        let first = outlet("Plugs:1", serialNumber: "SN")
        let second = outlet("Plugs:2", serialNumber: "SN")
        try server.add(first)
        try server.add(second)
        #expect(serialNumber(first) == "SN")
        #expect(serialNumber(second) == "SN")
    }
}
