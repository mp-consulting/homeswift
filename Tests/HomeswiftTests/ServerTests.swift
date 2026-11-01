import Foundation
import Logging
import Testing

@testable import Homeswift

/// The server's log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .info
    return logger
}()

@Suite(.timeLimit(.minutes(1)))
struct ServerTests {
    let lamp: Accessory
    let lightbulb: Service
    let server: HAPServer
    let storage = MemoryStorage()

    init() throws {
        lightbulb = Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)
        lamp = Accessory(id: "lamp-1", name: "Lamp", category: .lightbulb, services: [lightbulb])
        let bridge = Accessory(
            id: "bridge", name: "Test Bridge", category: .bridge,
            services: [Service(.protocolInformation, extra: [Characteristic(.version, value: "1.1.0")])])
        server = try HAPServer(
            bridge: bridge, accessories: [lamp], storage: storage,
            options: .init(setupCode: SetupCode("031-45-154"), port: 0, advertise: false, logger: testLogger))
    }

    /// A controller paired and verified; through pair setup when the test is about it, else added directly.
    private func pairedController(throughPairSetup: Bool = false) async throws -> TestController {
        try await server.start()
        let controller = TestController()
        try await controller.connect(port: server.port!)
        if throughPairSetup {
            try await controller.pairSetup(code: "031-45-154")
        } else {
            try controller.addPairing(to: server)
        }
        try await controller.pairVerify()
        return controller
    }

    @Test func pairsAndServesTheDatabase() async throws {
        let controller = try await pairedController(throughPairSetup: true)
        #expect(server.isPaired)
        #expect(controller.accessoryID == server.deviceID)

        let response = try await controller.request("GET", "/accessories")
        #expect(response.status == 200)
        let accessories = try #require((response.json as? [String: Any])?["accessories"] as? [[String: Any]])
        #expect(accessories.map { $0["aid"] as? Int } == [1, 2])
        let lampServices = try #require(accessories[1]["services"] as? [[String: Any]])
        #expect(lampServices.first?["iid"] as? Int == 1)
        #expect(lampServices.first?["type"] as? String == "3E")
        #expect(lampServices.last?["type"] as? String == "43")
        #expect(lampServices.last?["primary"] as? Bool == true)
        await controller.close()
        await server.stop()
    }

    @Test func rejectsUnverifiedRequestsAndWrongCodes() async throws {
        try await server.start()
        let controller = TestController()
        try await controller.connect(port: server.port!)
        #expect(try await controller.request("GET", "/accessories").status == 470)
        await #expect(throws: TestController.PairingFailure.self) {
            try await controller.pairSetup(code: "999-99-998")
        }
        #expect(!server.isPaired)
        await controller.close()
        await server.stop()
    }

    @Test func skipsUnchangedWritesWhenAsked() async throws {
        let writes = WriteLog()
        let brightness = lightbulb.characteristic(.brightness)
        brightness.onWrite(changesOnly: true) { await writes.append($0) }
        let controller = try await pairedController()

        for value in [40, 40, 60] {
            let write = try await controller.json("PUT", "/characteristics", ["characteristics": [["aid": 2, "iid": brightness.iid, "value": value]]])
            #expect(write.status == 204)
        }
        #expect(await writes.values == [.int(40), .int(60)])

        // Without changesOnly every write reaches the handler.
        brightness.onWrite { await writes.append($0) }
        _ = try await controller.json("PUT", "/characteristics", ["characteristics": [["aid": 2, "iid": brightness.iid, "value": 60]]])
        #expect(await writes.values == [.int(40), .int(60), .int(60)])
        await controller.close()
        await server.stop()
    }

    @Test func readsWritesAndNotifies() async throws {
        let writes = WriteLog()
        let brightness = lightbulb.characteristic(.brightness)
        brightness.onWrite { await writes.append($0) }
        let on = lightbulb.characteristic(.on)

        let first = try await pairedController()
        let second = TestController(identifier: "second", signingKey: .init())
        // Pair the second controller through the first, as the Home app does for other users and hubs.
        var add = TLV8()
        add.append(.state, 1)
        add.append(.method, 3)
        add.append(.identifier, Data(second.identifier.utf8))
        add.append(.publicKey, second.signingKey.publicKey.rawRepresentation)
        add.append(.permissions, 0)
        let added = try await first.tlv("/pairings", add)
        #expect(added.byte(.error) == nil)
        second.accessoryLTPK = first.accessoryLTPK
        try await second.connect(port: server.port!)
        try await second.pairVerify()

        let ids = "2.\(on.iid),2.\(brightness.iid)"
        let read = try await first.request("GET", "/characteristics?id=\(ids)&meta=1")
        #expect(read.status == 200)
        let values = (read.json as? [String: Any])?["characteristics"] as? [[String: Any]]
        #expect(values?.first?["value"] as? Bool == false)
        #expect(values?.last?["unit"] as? String == "percentage")

        // Second controller subscribes; first writes; second gets the event, first does not.
        let subscribe = try await second.json("PUT", "/characteristics", ["characteristics": [["aid": 2, "iid": brightness.iid, "ev": true]]])
        #expect(subscribe.status == 204)
        let write = try await first.json("PUT", "/characteristics", ["characteristics": [["aid": 2, "iid": brightness.iid, "value": 55]]])
        #expect(write.status == 204)
        #expect(await writes.values == [.int(55)])
        #expect(brightness.value == .int(55))

        let event = try await second.nextMessage()
        #expect(event.startLine == "EVENT/1.0 200")
        let changed = (event.json as? [String: Any])?["characteristics"] as? [[String: Any]]
        #expect(changed?.first?["value"] as? Int == 55)

        // Device-side updates reach subscribers too.
        brightness.value = 12
        let deviceEvent = try await second.nextMessage()
        #expect(((deviceEvent.json as? [String: Any])?["characteristics"] as? [[String: Any]])?.first?["value"] as? Int == 12)

        // Out of range and read-only writes come back as a multi-status.
        let bad = try await first.json("PUT", "/characteristics", ["characteristics": [
            ["aid": 2, "iid": brightness.iid, "value": 150],
            ["aid": 1, "iid": 3, "value": "x"],  // Manufacturer
        ]])
        #expect(bad.status == 207)
        let statuses = ((bad.json as? [String: Any])?["characteristics"] as? [[String: Any]])?.map { $0["status"] as? Int }
        #expect(statuses == [HAPStatus.invalidValueInRequest.rawValue, HAPStatus.readOnlyCharacteristic.rawValue])

        // A non-admin cannot manage pairings.
        var list = TLV8()
        list.append(.state, 1)
        list.append(.method, 5)
        #expect(try await second.tlv("/pairings", list).byte(.error) == TLVError.authentication.rawValue)
        let pairings = try await first.tlv("/pairings", list)
        #expect(pairings.groups.count == 2)

        await first.close()
        await second.close()
        await server.stop()
    }

    /// As HAP-NodeJS: the writes of one request run at the same time (a light's colour and brightness reach a plugin
    /// together), the results keep the request's order, and one characteristic twice is refused.
    @Test func writesOfOneRequestRunTogether() async throws {
        let events = EventLog()
        let on = lightbulb.characteristic(.on)
        let brightness = lightbulb.characteristic(.brightness)
        on.onWrite { _ in
            await events.append("on started")
            try await Task.sleep(for: .milliseconds(300))
            await events.append("on done")
        }
        brightness.onWrite { _ in
            await events.append("brightness started")
            throw HAPStatusError(.resourceBusy)
        }
        let controller = try await pairedController()

        let write = try await controller.json("PUT", "/characteristics", ["characteristics": [
            ["aid": 2, "iid": on.iid, "value": true],
            ["aid": 2, "iid": brightness.iid, "value": 40],
        ]])
        // Brightness started while On was still being written.
        let lines = await events.lines
        #expect(Set(lines.prefix(2)) == ["on started", "brightness started"])
        #expect(lines.last == "on done")
        #expect(write.status == 207)
        let results = (write.json as? [String: Any])?["characteristics"] as? [[String: Any]]
        #expect(results?.map { $0["iid"] as? Int } == [on.iid, brightness.iid])
        #expect(results?.map { $0["status"] as? Int } == [HAPStatus.success.rawValue, HAPStatus.resourceBusy.rawValue])
        #expect(on.value == .bool(true))

        let twice = try await controller.json("PUT", "/characteristics", ["characteristics": [
            ["aid": 2, "iid": on.iid, "value": false],
            ["aid": 2, "iid": on.iid, "value": true],
        ]])
        #expect(twice.status == 422)
        #expect(on.value == .bool(true))
        await controller.close()
        await server.stop()
    }

    /// As HAP-NodeJS: the reads of one request run at the same time (one slow device does not hold up the others),
    /// the results keep the request's order, and one characteristic twice is refused.
    @Test func readsOfOneRequestRunTogether() async throws {
        let events = EventLog()
        let on = lightbulb.characteristic(.on)
        let brightness = lightbulb.characteristic(.brightness)
        on.onRead {
            await events.append("on started")
            try await Task.sleep(for: .milliseconds(300))
            await events.append("on done")
            return .bool(true)
        }
        brightness.onRead {
            await events.append("brightness started")
            throw HAPStatusError(.resourceBusy)
        }
        let controller = try await pairedController()

        let read = try await controller.request("GET", "/characteristics?id=2.\(on.iid),2.\(brightness.iid),2.999")
        // Brightness started while On was still being read.
        let lines = await events.lines
        #expect(Set(lines.prefix(2)) == ["on started", "brightness started"])
        #expect(lines.last == "on done")
        #expect(read.status == 207)
        let results = (read.json as? [String: Any])?["characteristics"] as? [[String: Any]]
        #expect(results?.map { $0["iid"] as? Int } == [on.iid, brightness.iid, 999])
        #expect(results?.map { $0["status"] as? Int } == [
            HAPStatus.success.rawValue, HAPStatus.resourceBusy.rawValue, HAPStatus.resourceDoesNotExist.rawValue,
        ])
        #expect(results?.first?["value"] as? Bool == true)

        let twice = try await controller.request("GET", "/characteristics?id=2.\(on.iid),2.\(on.iid)")
        #expect(twice.status == 422)
        await controller.close()
        await server.stop()
    }

    /// As HAP-NodeJS: changes within the coalescing delay go as one event message, in order, the same value twice
    /// in a row once; a button press goes at once and takes the queued changes with it.
    @Test func eventsOfABurstGoAsOneMessage() async throws {
        let on = lightbulb.characteristic(.on)
        let brightness = lightbulb.characteristic(.brightness)
        let controller = try await pairedController()
        let subscribe = try await controller.json("PUT", "/characteristics", ["characteristics": [
            ["aid": 2, "iid": on.iid, "ev": true], ["aid": 2, "iid": brightness.iid, "ev": true],
        ]])
        #expect(subscribe.status == 204)

        on.value = true
        brightness.value = 30
        brightness.sendEvent(.int(30))
        brightness.value = 40
        let event = try await controller.nextMessage()
        #expect(event.startLine == "EVENT/1.0 200")
        let changed = (event.json as? [String: Any])?["characteristics"] as? [[String: Any]]
        #expect(changed?.map { $0["iid"] as? Int } == [on.iid, brightness.iid, brightness.iid])
        #expect(changed?.map { ($0["value"] as? NSNumber)?.intValue } == [1, 30, 40])
        await controller.close()
        await server.stop()

        // A delay no test waits out: only the button press can send the brightness.
        let button = Service(.statelessProgrammableSwitch, name: "Button")
        let light = Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)
        let lamp = Accessory(id: "lamp-2", name: "Lamp", category: .lightbulb, services: [light, button])
        var options = HAPServer.Options(setupCode: SetupCode("031-45-154"), port: 0, advertise: false, logger: testLogger)
        options.eventCoalescingDelay = .seconds(60)
        let server = try HAPServer(accessory: lamp, storage: MemoryStorage(), options: options)
        try await server.start()
        let pressing = TestController()
        try await pressing.connect(port: server.port!)
        try pressing.addPairing(to: server)
        try await pressing.pairVerify()
        let level = light.characteristic(.brightness)
        let press = button.characteristic(.programmableSwitchEvent)
        let subscribed = try await pressing.json("PUT", "/characteristics", ["characteristics": [
            ["aid": 1, "iid": level.iid, "ev": true], ["aid": 1, "iid": press.iid, "ev": true],
        ]])
        #expect(subscribed.status == 204)
        level.value = 70
        press.sendEvent(.int(0))
        let pressed = try await pressing.nextMessage()
        let both = (pressed.json as? [String: Any])?["characteristics"] as? [[String: Any]]
        #expect(both?.map { $0["iid"] as? Int } == [level.iid, press.iid])
        await pressing.close()
        await server.stop()
    }

    @Test func timesRequestsAndHandlers() async throws {
        let timings = TimingLog()
        server.observeTimings { timings.append($0) }
        let on = lightbulb.characteristic(.on)
        on.onRead {
            try await Task.sleep(for: .milliseconds(20))
            return .bool(true)
        }
        let brightness = lightbulb.characteristic(.brightness)
        brightness.onWrite { _ in }
        let controller = try await pairedController()

        // A read: the handler of the one characteristic that has one, then the request, both about the lamp.
        let read = try await controller.request("GET", "/characteristics?id=2.\(on.iid),2.\(brightness.iid)")
        #expect(read.status == 200)
        var seen = timings.take()
        #expect(seen.map(\.kind) == [.handler, .request])
        #expect(seen.allSatisfy { $0.accessories.map(\.id) == ["lamp-1"] })
        #expect(seen.allSatisfy { $0.duration >= .milliseconds(20) })

        // A subscription alone is not timed; a write is, its handler and its request.
        _ = try await controller.json("PUT", "/characteristics", ["characteristics": [["aid": 2, "iid": brightness.iid, "ev": true]]])
        #expect(timings.take().isEmpty)
        _ = try await controller.json("PUT", "/characteristics", ["characteristics": [["aid": 2, "iid": brightness.iid, "value": 30]]])
        seen = timings.take()
        #expect(seen.map(\.kind) == [.handler, .request])

        // A write from outside HomeKit (an automation, the web UI) times the handler only.
        try await brightness.write(.int(31))
        #expect(timings.take().map(\.kind) == [.handler])
        await controller.close()
        await server.stop()
    }

    @Test func identifiesBridgedAccessories() async throws {
        let identified = WriteLog()
        let sensor = Service(.temperatureSensor, name: "Sensor")
        let thermometer = Accessory(
            id: "sensor-1", name: "Sensor", category: .sensor, services: [sensor],
            onIdentify: { await identified.append(.string("sensor")) })
        try server.add(thermometer)
        let controller = try await pairedController()
        let identify = thermometer.information.characteristic(.identify)
        let response = try await controller.json("PUT", "/characteristics", ["characteristics": [["aid": thermometer.aid, "iid": identify.iid, "value": true]]])
        #expect(response.status == 204)
        #expect(await identified.values == [.string("sensor")])
        await controller.close()
        await server.stop()
    }

    @Test func aDifferentDeviceIDIsANewAccessory() async throws {
        let controller = try await pairedController()
        await controller.close()
        await server.stop()
        let publicKey = server.signingKey.publicKey.rawRepresentation
        let bridge = { Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []) }

        // The same ID, spelled differently, keeps the pairings and the key.
        let same = try HAPServer(
            bridge: bridge(), accessories: [], storage: storage,
            options: .init(deviceID: server.deviceID.lowercased(), port: 0, advertise: false, logger: testLogger))
        #expect(same.deviceID == server.deviceID)
        #expect(same.isPaired)
        #expect(same.signingKey.publicKey.rawRepresentation == publicKey)

        // A new ID drops them: controllers know the old accessory, not this one.
        let renamed = try HAPServer(
            bridge: bridge(), accessories: [], storage: storage,
            options: .init(deviceID: "0e:aa:bb:cc:dd:ee", port: 0, advertise: false, logger: testLogger))
        #expect(renamed.deviceID == "0E:AA:BB:CC:DD:EE")
        #expect(!renamed.isPaired)
        #expect(renamed.signingKey.publicKey.rawRepresentation != publicKey)
        #expect(renamed.setupCode == server.setupCode)
        #expect(renamed.txtRecord().first { $0.0 == "sf" }?.1 == "1")
    }

     func servesStandaloneAccessoriesWithLinkedServices() async throws {
        // A television published on its own: aid 1, its inputs and speaker listed as linked services.
        func makeTelevision(inputs: [String]) -> (Accessory, Service) {
            let sources = inputs.enumerated().map { index, name in
                Service(.inputSource, name: name, subtype: "input-\(index + 1)", optional: [.identifier], extra: [Characteristic(.identifier, value: .int(index + 1))])
            }
            let speaker = Service(.televisionSpeaker, name: "Speaker", optional: [.volumeSelector])
            let tv = Service(.television, name: "TV", linked: sources + [speaker], isPrimary: true)
            return (Accessory(id: "tv", name: "TV", category: .television, services: [tv] + sources + [speaker]), tv)
        }
        let storage = MemoryStorage()
        let (accessory, tv) = makeTelevision(inputs: ["HDMI 1", "Netflix"])
        let server = try HAPServer(accessory: accessory, storage: storage, options: .init(setupCode: SetupCode("031-45-154"), port: 0, advertise: false, logger: testLogger))
        #expect(accessory[.protocolInformation] != nil)
        try await server.start()
        let controller = TestController()
        try await controller.connect(port: server.port!)
        try controller.addPairing(to: server)
        try await controller.pairVerify()
        let response = try await controller.request("GET", "/accessories")
        let accessories = try #require((response.json as? [String: Any])?["accessories"] as? [[String: Any]])
        #expect(accessories.map { $0["aid"] as? Int } == [1])
        let services = try #require(accessories[0]["services"] as? [[String: Any]])
        let television = try #require(services.first { $0["type"] as? String == "D8" })
        let linked = tv.linked.map(\.iid)
        #expect(linked.count == 3)
        #expect(television["linked"] as? [Int] == linked)
        #expect(services.contains { $0["type"] as? String == "A2" })   // Protocol Information, added by the server
        let netflixIID = accessory.service(.inputSource, subtype: "input-2")?.iid

        // The accessory replaced with one more input keeps its identity and the iids of what it kept.
        let (replacement, _) = makeTelevision(inputs: ["HDMI 1", "Netflix", "Plex"])
        try server.replace(primary: replacement)
        #expect(server.primary === replacement)
        #expect(replacement.service(.inputSource, subtype: "input-2")?.iid == netflixIID)
        #expect(replacement.aid == 1)
        let again = try await controller.request("GET", "/accessories")
        let againServices = try #require(((again.json as? [String: Any])?["accessories"] as? [[String: Any]])?[0]["services"] as? [[String: Any]])
        #expect(againServices.filter { $0["type"] as? String == "D9" }.count == 3)
        #expect(server.txtRecord().first { $0.0 == "c#" }?.1 == "2")
        await controller.close()
        await server.stop()
    }

     func restoredAccessoriesBumpTheConfigurationNumberOnce() async throws {
        func lamp(_ id: String) -> Accessory {
            Accessory(id: id, name: id, category: .lightbulb, services: [Service(.lightbulb, name: id, optional: [.brightness], isPrimary: true)])
        }
        let storage = MemoryStorage()
        // As the plugin runtime does: an empty bridge, the cached accessories added one by one, then start.
        func launch(_ ids: [String]) async throws -> String {
            let server = try HAPServer(
                bridge: Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []), accessories: [], storage: storage,
                options: .init(port: 0, advertise: false, logger: testLogger))
            for id in ids { try server.add(lamp(id)) }
            try await server.start()
            let number = server.txtRecord().first { $0.0 == "c#" }?.1 ?? "?"
            await server.stop()
            return number
        }
        #expect(try await launch(["a", "b", "c"]) == "1")   // the first database is the baseline, not a change
        #expect(try await launch(["a", "b", "c"]) == "1")   // the same database: controllers keep their copy
        #expect(try await launch(["a", "b"]) == "2")        // a change: one bump
        #expect(try await launch(["a", "b"]) == "2")
    }

    @Test func keepsIdentityAndIDsAcrossRestarts() async throws {
        let controller = try await pairedController()
        let iid = lightbulb.characteristic(.brightness).iid
        await controller.close()
        await server.stop()

        let restartedBulb = Service(.lightbulb, name: "Lamp", optional: [.brightness], isPrimary: true)
        let restarted = try HAPServer(
            bridge: Accessory(id: "bridge", name: "Test Bridge", category: .bridge, services: []),
            accessories: [Accessory(id: "lamp-1", name: "Lamp", category: .lightbulb, services: [restartedBulb])],
            storage: storage, options: .init(port: 0, advertise: false, logger: testLogger))
        #expect(restarted.deviceID == server.deviceID)
        #expect(restarted.isPaired)
        #expect(restartedBulb.characteristic(.brightness).iid == iid)

        try await restarted.start()
        // Protocol Information is the server's to add, so the database is the same and the configuration number stays.
        #expect(restarted.txtRecord().first { $0.0 == "c#" }?.1 == "1")
        let again = TestController(identifier: controller.identifier, signingKey: controller.signingKey)
        again.accessoryLTPK = controller.accessoryLTPK
        try await again.connect(port: restarted.port!)
        try await again.pairVerify()
        #expect(try await again.request("GET", "/accessories").status == 200)
        await again.close()
        await restarted.stop()
    }

    @Test func removingTheLastAdminUnpairs() async throws {
        let controller = try await pairedController()
        var remove = TLV8()
        remove.append(.state, 1)
        remove.append(.method, 4)
        remove.append(.identifier, Data(controller.identifier.utf8))
        let response = try await controller.tlv("/pairings", remove)
        #expect(response.byte(.error) == nil)
        #expect(!server.isPaired)
        await #expect(throws: (any Error).self) { _ = try await controller.nextMessage() }
        await server.stop()
    }
}

actor WriteLog {
    var values: [HAPValue] = []
    func append(_ value: HAPValue) { values.append(value) }
}

actor EventLog {
    var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}

/// The timings a server reports, as they come.
final class TimingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var timings: [HAPServer.Timing] = []

    func append(_ timing: HAPServer.Timing) { lock.withLock { timings.append(timing) } }

    /// The timings so far, emptying the log.
    func take() -> [HAPServer.Timing] {
        lock.withLock {
            defer { timings.removeAll() }
            return timings
        }
    }
}
