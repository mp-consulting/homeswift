import Foundation
import Homeswift
@testable import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

/// Power On: what a light does when its power comes back. Natural Light, the bridge's, is every light's that can have
/// it until it is given one of its device's own (`naturalLight` false); the bridge writes it the white for the time of day.
@Suite(.timeLimit(.minutes(1)))
struct PowerOnTests {
    static func configuration(naturalLight: Bool? = nil) throws -> HomeswiftConfiguration {
        let settings = naturalLight.map { #", "_accessories": { "bulb": { "naturalLight": \#($0) } }"# } ?? ""
        return try HomeswiftConfiguration.decode(Data("""
            { "bridge": { "port": 0 }, "platforms": [{ "platform": "Recording", "name": "Home", "lamps": ["plain"], "whiteLamps": ["bulb"]\(settings) }] }
            """.utf8))
    }

    @Test func theWhiteFollowsTheSun() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 20)))
        let at = { (hour: Double) in NaturalLight.temperature(at: day.addingTimeInterval(hour * 3600), location: nil, calendar: calendar) }
        // Without a Location: sunrise at 7:00, sunset at 19:00, midday at 13:00.
        #expect(at(2) == NaturalLight.night)
        #expect(at(6) == NaturalLight.night)
        #expect(at(8) == NaturalLight.morning)
        #expect(at(13) == NaturalLight.midday)
        #expect(at(19) == NaturalLight.evening)
        #expect(at(23) == NaturalLight.night)
        #expect((NaturalLight.night...NaturalLight.morning).contains(at(7)))
        // At a Location, by its sun: Paris at the equinox, warm before six in the morning UTC, cool at noon.
        let paris = Location(latitude: 48.86, longitude: 2.35, name: "Paris")
        #expect(NaturalLight.temperature(at: day.addingTimeInterval(4 * 3600), location: paris) == NaturalLight.night)
        #expect(NaturalLight.temperature(at: day.addingTimeInterval(12 * 3600), location: paris) > NaturalLight.morning)
    }

    @Test func aLightHasNaturalLightUntilGivenItsDevicesOwn() async throws {
        let environment = TestEnvironment()
        let host = try PluginHost(configuration: try Self.configuration(), registry: environment.registry, storageDirectory: environment.directory,
                                  options: environment.options)
        try await host.start()
        let plugin = try #require(environment.createdPlugins.first)
        // Natural Light: nothing read from the device, and the white for now written to it.
        let state = try #require(try await host.powerOn(of: "Recording:bulb"))
        #expect(state.natural && state.device == nil)
        #expect(state.support.behaviours.contains(.natural))
        #expect(try await host.powerOn(of: "Recording:plain") == nil)
        await host.refreshNaturalLight(of: "Recording:bulb")
        let written = try #require(await plugin.powerOnWrites.last)
        #expect(written.accessoryID == "Recording:bulb" && written.value.behaviour == .natural)
        #expect((2000...6500).contains(written.value.temperature ?? 0))
        // Given its device's own: the bridge writes it no white, and reads the device.
        _ = await host.apply(try Self.configuration(naturalLight: false))
        let count = await plugin.powerOnWrites.count
        await host.refreshNaturalLight(of: "Recording:bulb")
        #expect(await plugin.powerOnWrites.count == count)
        #expect(try await host.powerOn(of: "Recording:bulb")?.natural == false)
        await host.stop()
    }

    /// West of Greenwich the evening is already the next UTC day: the curve takes the solar day the evening belongs to.
    @Test func theEveningIsTheDaysEvenInCalifornia() throws {
        let sanFrancisco = Location(latitude: 37.77, longitude: -122.42, name: "San Francisco")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 21 March 2026, 18:45 PDT is 01:45 UTC on the 22nd, a little after sunset (about 19:20 PDT, 02:20 UTC).
        let evening = try #require(utc.date(from: DateComponents(year: 2026, month: 3, day: 22, hour: 3, minute: 15)))
        let white = NaturalLight.temperature(at: evening, location: sanFrancisco)
        #expect(white > NaturalLight.night && white <= NaturalLight.evening)
    }

    /// A light given its white, then changed elsewhere (its maker's app): the next round reads it, leaves it as it is,
    /// and gives it its device's own Power On.
    @Test func aChangeMadeElsewhereEndsNaturalLight() async throws {
        let environment = TestEnvironment()
        let host = try PluginHost(configuration: try Self.configuration(), registry: environment.registry, storageDirectory: environment.directory,
                                  options: environment.options)
        try await host.start()
        let plugin = try #require(environment.createdPlugins.first)
        let clock = NIOLockedValueBox(Calendar.current.startOfDay(for: Date()).addingTimeInterval(13 * 3600))
        let takenOver = NIOLockedValueBox<[String]>([])
        let runner = NaturalLightRunner(
            lights: { [.init(accessoryID: "Recording:bulb", name: "bulb", plugin: plugin, wantsNatural: true)] }, location: { nil },
            takenOver: { id in takenOver.withLockedValue { $0.append(id) } }, now: { clock.withLockedValue { $0 } }, logger: testLogger)
        await runner.refresh()
        #expect(await plugin.powerOnWrites.last?.value == PowerOn(.natural, temperature: NaturalLight.midday))
        // Within the step: nothing written again.
        clock.withLockedValue { $0 = $0.addingTimeInterval(60) }
        await runner.refresh()
        #expect(await plugin.powerOnWrites.count == 1)
        // Changed in its app, then the white moves: left as it is, and Natural Light given back.
        await plugin.changePowerOnElsewhere(PowerOn(.lastOn), of: "Recording:bulb")
        clock.withLockedValue { $0 = $0.addingTimeInterval(6 * 3600) }
        await runner.refresh()
        #expect(takenOver.withLockedValue { $0 } == ["Recording:bulb"])
        #expect(await plugin.powerOnWrites.last?.value == PowerOn(.lastOn))
        await host.stop()
    }

    @Test func aRequestReadsAsAPowerOn() throws {
        #expect(try PowerOn(json: ["behaviour": "custom", "brightness": 60, "temperature": 2700]) == PowerOn(.custom, brightness: 60, temperature: 2700))
        #expect(try PowerOn(json: ["behaviour": "lastOn", "brightness": 60]) == PowerOn(.lastOn))
        #expect(throws: PowerOnError.self) { try PowerOn(json: ["behaviour": "sometimes"]) }
        #expect(throws: PowerOnError.self) { try PowerOn(json: ["behaviour": "custom", "brightness": 0]) }
        #expect(PowerOn(.natural, temperature: 2700).mirek == 370)
    }
}
