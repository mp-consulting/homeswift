import Foundation
import Homeswift
import Testing
@testable import HomeswiftMCP

@Suite struct NaturalLightingTests {
    private func date(_ hour: Int) -> Date { Date(timeIntervalSince1970: Double(hour * 3600)) }

    @Test func curveAndTimeZone() {
        let utc = TimeZone(secondsFromGMT: 0)!
        #expect(NaturalLighting.mireds(at: date(0), timeZone: utc, minimum: 140, maximum: 500) == 455)
        #expect(NaturalLighting.mireds(at: date(12), timeZone: utc, minimum: 140, maximum: 500) == 200)
        #expect(NaturalLighting.mireds(at: date(9), timeZone: utc, minimum: 140, maximum: 500) == 250)
        #expect(NaturalLighting.mireds(at: date(12), timeZone: TimeZone(secondsFromGMT: -3 * 3600)!, minimum: 140, maximum: 500) == 250)
        #expect(NaturalLighting.mireds(at: date(0), timeZone: utc, minimum: 250, maximum: 400) == 400)
        #expect(NaturalLighting.mireds(at: date(12), timeZone: utc, minimum: 250, maximum: 400) == 250)
    }

    @Test func optInPauseResumePersistenceAndOffline() async throws {
        let environment = try MCPTestEnvironment(config: """
        {"bridge":{"name":"Test","username":"0E:11:22:33:44:57","pin":"031-45-154","port":0},
         "platforms":[{"platform":"Devices","mirroredBulb":true}]}
        """)
        try await environment.start()
        let catalog = environment.catalog
        let engine = catalog.home.naturalLighting
        let located = try #require(catalog.find(id: "Devices:mirrored"))
        let light = try #require(located.accessory.services.first { $0.type.uuid == ServiceType.lightbulb.uuid })
        let temperature = try #require(light[.colorTemperature])
        light[.on]?.value = .bool(true)
        await engine.tick(catalog, at: date(12))
        #expect(environment.written.isEmpty) // never opted in
        _ = try await engine.configure(located, service: nil, on: true, timeZone: "UTC", catalog: catalog)
        #expect(environment.written.count == 1)
        #expect(environment.written.allSatisfy { $0.0 == "mirrored.colorTemperature" })
        await engine.tick(catalog, at: date(12))
        #expect(temperature.value == .int(200))
        #expect(engine.json(for: located.accessory.id)?["Lightbulb"]?["paused"] == false)
        // Tagged scheduler writes must not pause themselves.
        await Task.yield()
        #expect(engine.settings.value.first?.paused == false)
        let count = environment.written.count
        light[.on]?.value = false
        await engine.tick(catalog, at: date(21))
        #expect(environment.written.count == count)
        light[.on]?.value = true
        located.accessory.isUnavailable = true
        await engine.tick(catalog, at: date(21))
        #expect(environment.written.count == count)
        located.accessory.isUnavailable = false
        // A manual white change pauses before the write, and a restart retains that pause.
        _ = try await catalog.write(located, service: nil, characteristic: "Color Temperature", value: 300, allowSecurity: false)
        await engine.tick(catalog, at: date(21))
        #expect(temperature.value == .int(300))
        #expect(engine.settings.value.first?.paused == true)
        let restored = NaturalLighting(directory: environment.directory)
        #expect(restored.settings.value.first?.paused == true)
        // Drain the manual-write observer before explicitly resuming.
        for _ in 0..<10 { await Task.yield() }
        _ = try await engine.configure(located, service: nil, on: true, timeZone: "UTC", catalog: catalog)
        #expect(engine.settings.value.first?.paused == false)
        // A temperature reported by another controller stops the schedule too.
        temperature.value = 140
        await engine.tick(catalog, at: date(12))
        #expect(engine.settings.value.first?.paused == true)
        #expect(temperature.value == 140)
        _ = try await engine.configure(located, service: nil, on: false, timeZone: "UTC", catalog: catalog)
        #expect(engine.settings.value.isEmpty)
        #expect(engine.json(for: located.accessory.id) == nil)
        await environment.stop()
    }

    @Test func failedWriteDoesNotClaimActive() async throws {
        let environment = try MCPTestEnvironment(config: """
        {"bridge":{"name":"Test","username":"0E:11:22:33:44:58","pin":"031-45-154","port":0},
         "platforms":[{"platform":"Devices","mirroredBulb":true}]}
        """)
        try await environment.start()
        let catalog = environment.catalog
        let located = try #require(catalog.find(id: "Devices:mirrored"))
        let light = try #require(located.accessory.services.first { $0.type.uuid == ServiceType.lightbulb.uuid })
        light[.on]?.value = true
        light[.colorTemperature]?.onWrite { _ in throw HAPStatusError(.serviceCommunicationFailure) }
        await #expect(throws: CatalogError.self) {
            try await catalog.home.naturalLighting.configure(located, service: nil, on: true, timeZone: "UTC", catalog: catalog)
        }
        #expect(catalog.home.naturalLighting.settings.value.first?.paused == true)
        await environment.stop()
    }
}
