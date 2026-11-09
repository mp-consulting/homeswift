import Foundation
import Homeswift
@testable import HomeswiftPlugin
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

    @Test func aRequestReadsAsAPowerOn() throws {
        #expect(try PowerOn(json: ["behaviour": "custom", "brightness": 60, "temperature": 2700]) == PowerOn(.custom, brightness: 60, temperature: 2700))
        #expect(try PowerOn(json: ["behaviour": "lastOn", "brightness": 60]) == PowerOn(.lastOn))
        #expect(throws: PowerOnError.self) { try PowerOn(json: ["behaviour": "sometimes"]) }
        #expect(throws: PowerOnError.self) { try PowerOn(json: ["behaviour": "custom", "brightness": 0]) }
        #expect(PowerOn(.natural, temperature: 2700).mirek == 370)
    }
}
