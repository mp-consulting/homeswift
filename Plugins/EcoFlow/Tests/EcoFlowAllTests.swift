import Foundation
import Testing

@testable import HomeswiftEcoFlow

@Suite(.timeLimit(.minutes(1)))
struct EcoFlowAllTests {
    struct Listed: EcoFlowAPI {
        let listed: [EcoFlowDevice]
        func devices() async throws -> [EcoFlowDevice] { listed }
        func schemaChanges() async -> [String] { [] }
    }

    struct Failing: EcoFlowAPI {
        struct Refused: Error {}
        func devices() async throws -> [EcoFlowDevice] { throw Refused() }
        func schemaChanges() async -> [String] { [] }
    }

    @Test func aDeviceReportedByTwoAPIsIsListedOnceFromTheFirst() async throws {
        var developer = EcoFlowDevice(id: "BK11", name: "STREAM Ultra", online: true)
        developer.source = .mqtt
        var app = EcoFlowDevice(id: "BK11", name: "BK11", online: true)
        app.source = .app
        let river = EcoFlowDevice(id: "R631", name: "RIVER 3 Plus", online: true)
        let all = EcoFlowAll(apis: [Listed(listed: [developer]), Listed(listed: [app, river])])
        let devices = try await all.devices()
        #expect(devices.map(\.id) == ["BK11", "R631"])
        #expect(devices.first?.source == .mqtt, "the developer API's copy stands")
    }

    /// A model checked on the app's route only (a RIVER 3) is read from there, though the developer API reports it too.
    @Test func aModelIsReadFromTheRouteItWasCheckedOn() async throws {
        let model = EcoFlowModel.model(serial: "R655-TEST")
        var developer = EcoFlowDevice(id: "R655-TEST", name: "RIVER 3", online: true, model: model)
        developer.source = .rest
        var app = EcoFlowDevice(id: "R655-TEST", name: "RIVER 3", online: true, model: model)
        app.source = .app
        #expect(!developer.tested)
        let devices = try await EcoFlowAll(apis: [Listed(listed: [developer]), Listed(listed: [app])]).devices()
        #expect(devices.map(\.source) == [.app])
    }

    /// A STREAM the developer API reads from its REST quota has no level of its own: the app's route, which has it, is
    /// read instead; while the app's route has no level either, the developer API's copy stands.
    @Test func aDeviceIsReadFromTheRouteThatKnowsItsLevel() async throws {
        let model = EcoFlowModel.model(serial: "BK31-TEST")
        var developer = EcoFlowDevice(id: "BK31-TEST", name: "STREAM AC Pro", online: true, model: model)
        developer.source = .rest
        developer.state = EcoFlowState(readings: ["cmsBattSoc": 0, "powGetBpCms": -120], keys: EcoFlowModel.streamDeveloper)
        var app = EcoFlowDevice(id: "BK31-TEST", name: "STREAM AC Pro", online: true, model: model)
        app.source = .app
        app.state = EcoFlowState(soc: 40, power: EcoFlowState.Power())
        #expect(developer.tested && app.tested)
        let devices = try await EcoFlowAll(apis: [Listed(listed: [developer]), Listed(listed: [app])]).devices()
        #expect(devices.map(\.source) == [.app])
        #expect(devices.first?.state.battery.batteryLevel == 40)

        app.state = EcoFlowState(soc: nil, power: EcoFlowState.Power())
        let neither = try await EcoFlowAll(apis: [Listed(listed: [developer]), Listed(listed: [app])]).devices()
        #expect(neither.map(\.source) == [.rest])

        // The app's stream gone quiet (offline, an old level) does not stand for a device the developer API reads live.
        app.state = EcoFlowState(soc: 40, power: EcoFlowState.Power())
        app.online = false
        let quiet = try await EcoFlowAll(apis: [Listed(listed: [developer]), Listed(listed: [app])]).devices()
        #expect(quiet.map(\.source) == [.rest])
    }

    /// Counts its reads.
    actor Counting: EcoFlowAPI {
        let listed: [EcoFlowDevice]
        private(set) var reads = 0
        init(_ listed: [EcoFlowDevice]) { self.listed = listed }
        func devices() async throws -> [EcoFlowDevice] {
            reads += 1
            return listed
        }
        func schemaChanges() async -> [String] { [] }
    }

    /// The developer API is read at its interval and answers from its last read in between; the app's stream is read
    /// every time, so a RIVER on it moves as often as the plugin reads.
    @Test func eachAPIIsReadAtItsOwnPace() async throws {
        let developer = Counting([EcoFlowDevice(id: "BK11", name: "STREAM Ultra", online: true)])
        let app = Counting([EcoFlowDevice(id: "R631", name: "RIVER 3 Plus", online: true)])
        let all = EcoFlowAll(apis: [developer, app], intervals: [0: .seconds(60)])
        for _ in 0..<3 {
            #expect(try await all.devices().map(\.id) == ["BK11", "R631"])
        }
        #expect(await developer.reads == 1)
        #expect(await app.reads == 3)
    }

    /// Records what it is told the others reported.
    actor Told: EcoFlowAPI {
        let listed: [EcoFlowDevice]
        private(set) var told: [[String]] = []
        init(_ listed: [EcoFlowDevice]) { self.listed = listed }
        func devices() async throws -> [EcoFlowDevice] { listed }
        func devices(besides elsewhere: [EcoFlowDevice]) async throws -> [EcoFlowDevice] {
            told.append(elsewhere.map(\.id))
            return listed
        }
        nonisolated var readsElsewhere: Bool { true }
        func schemaChanges() async -> [String] { [] }
    }

    /// Each API hears what the others reported at their last read.
    @Test func eachAPIIsToldTheOthersDevices() async throws {
        let developer = Told([EcoFlowDevice(id: "BK11", name: "STREAM Ultra", online: true)])
        let app = Told([EcoFlowDevice(id: "R655", name: "RIVER 3", online: true)])
        let all = EcoFlowAll(apis: [developer, app])
        _ = try await all.devices()
        _ = try await all.devices()
        #expect(await developer.told.last == ["R655"])
        #expect(await app.told.last == ["BK11"])
    }

    @Test func aFailingAPIDoesNotHideTheOthersDevices() async throws {
        let river = EcoFlowDevice(id: "R631", name: "RIVER 3 Plus", online: true)
        let all = EcoFlowAll(apis: [Failing(), Listed(listed: [river])])
        #expect(try await all.devices().map(\.id) == ["R631"])
    }

    @Test func aFailureIsThrownWhenNoAPIReturnsADevice() async {
        let all = EcoFlowAll(apis: [Failing()])
        await #expect(throws: Failing.Refused.self) { _ = try await all.devices() }
    }

    private func dependencies(_ json: String) throws -> (any EcoFlowAPI)? {
        let configuration = try JSONDecoder().decode(EcoFlowPlugin.Configuration.self, from: Data(json.utf8))
        return EcoFlowPlugin.dependencies(for: configuration).api
    }

    @Test func theRouteDecidesWhichAPIsAreRead() throws {
        let keys = #""accessKey":"a","secretKey":"s","email":"e@example.test","password":"p""#
        #expect(try dependencies("{\(keys)}") is EcoFlowAll, "both by default")
        #expect(try dependencies(#"{"route":"both","# + keys + "}") is EcoFlowAll)
        #expect(try dependencies(#"{"route":"developer","# + keys + "}") is EcoFlowCloud)
        #expect(try dependencies(#"{"route":"app","# + keys + "}") is EcoFlowAppAPI)
        #expect(try dependencies(#"{"accessKey":"a","secretKey":"s"}"#) is EcoFlowCloud, "both, with only the developer keys set")
        #expect(try dependencies(#"{"route":"app","accessKey":"a","secretKey":"s"}"#) == nil, "the app route needs its email and password")
    }
}
