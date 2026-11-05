import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftMagicHome

/// The plugin on a host against devices of a fake LAN.
@Suite(.timeLimit(.minutes(1)))
struct MagicHomeTests {
    let environment = TestEnvironment()
    static let stripHost = "192.168.1.50"
    static let bulbHost = "192.168.1.51"
    static let socketHost = "192.168.1.52"
    static let cctHost = "192.168.1.53"
    static let tableHost = "192.168.1.54"

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(MagicHomePlugin.Configuration.self, from: Data(#"{"platform":"homebridge-magichome-dynamic-platform"}"#.utf8))
        #expect(configuration.advancedOptions == nil)
        // The Homebridge UI's block, as it is.
        let block = #"""
        { "platform": "homebridge-magichome-dynamic-platform",
          "pruning": { "pruneMissingCachedAccessories": false, "restartsBeforeMissingAccessoriesPruned": 3, "pruneAllAccessoriesNextRestart": false },
          "whiteEffects": { "simultaniousDevicesColorWhite": true, "colorWhiteThreshold": 10, "colorWhiteThresholdSimultaniousDevices": 50, "colorOffThresholdSimultaniousDevices": 5 },
          "deviceManagement": { "blacklistOrWhitelist": "blacklist", "blacklistedUniqueIDs": [] },
          "advancedOptions": { "periodicDiscovery": true, "namesWithMacAddress": false, "logLevel": 3 } }
        """#
        let full = try JSONDecoder().decode(MagicHomePlugin.Configuration.self, from: Data(block.utf8))
        #expect(full.whiteEffects?.colorWhiteThresholdSimultaniousDevices == 50 && full.advancedOptions?.logLevel == 3)
    }

    @Test func aDiscoveredStripBecomesALightbulb() async throws {
        environment.lan.put(Fixtures.strip, at: Self.stripHost)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.stripMAC) != nil })
        let accessory = try #require(host.accessory(Fixtures.stripMAC))
        #expect(accessory.id == "homebridge-magichome-dynamic-platform:ACCF23A1B2C3")
        #expect(accessory.category == .lightbulb)
        #expect(accessory.information[.name]?.value == .string("RGBWW Simultaneous"))
        #expect(accessory.information[.manufacturer]?.value == .string("MagicHome"))
        #expect(accessory.information[.model]?.value == .string("AK001-ZJ2145"))
        #expect(accessory.information[.serialNumber]?.value == .string(Fixtures.stripMAC))
        let light = try #require(accessory.service(.lightbulb))
        #expect(light.isPrimary && light.subtype == nil)
        #expect(light[.on]?.value == .bool(true))
        #expect(light[.hue]?.value == .double(0) && light[.saturation]?.value == .double(100) && light[.brightness]?.value == .int(100))
        // Mode 07 (RGB/CCT): a tunable white too, with Adaptive Lighting.
        #expect(light[.colorTemperature]?.type.minValue == 154 && light[.colorTemperature]?.type.maxValue == 370)
        #expect(await environment.plugin?.adaptiveLighting[Fixtures.stripMAC] != nil)
        // The own probe heard back made nothing; the scan asked for the version too.
        #expect(host.mainBridge.server.accessories.filter { $0.id.hasPrefix(MagicHomePlugin.platform) }.count == 1)
        #expect(environment.lan.probes.contains { $0.data == MagicHomeDiscovery.versionQuery && $0.host == "192.168.1.255" })
        #expect(await environment.plugin?.deviceKind(of: Fixtures.stripMAC) == "light")
        await host.stop()
    }

    /// Section 7.2's sequence: power on first on firmware 5, the levels 100 ms later, one connection.
    @Test func aColourWriteIsOneLevelFrame() async throws {
        environment.lan.put(Fixtures.strip, at: Self.stripHost)
        // HomeKit sends the three in one request; a loaded runner may start them tens of milliseconds apart, so the
        // window that gathers them into one frame is wider here than the suite's 20 ms.
        var timing = TestEnvironment.timing
        timing.coalesce = .milliseconds(250)
        let host = try await environment.start(timing: timing)
        #expect(await eventually { host.accessory(Fixtures.stripMAC) != nil })
        let light = try #require(host.accessory(Fixtures.stripMAC)?.service(.lightbulb))
        let connections = environment.lan.connections(to: Self.stripHost)
        async let hue: Void = write(light[.hue], .double(0))
        async let saturation: Void = write(light[.saturation], .double(100))
        async let brightness: Void = write(light[.brightness], .int(100))
        _ = try await (hue, saturation, brightness)
        #expect(environment.lan.commands(to: Self.stripHost).map(hex) == ["71 23 0F A3", "31 FF 00 00 00 00 FF 0F 3E"])
        #expect(environment.lan.connections(to: Self.stripHost) <= connections + 1)
        await host.stop()
    }

    @Test func firmwareSixSendsTheLevelsAlone() async throws {
        var strip = Fixtures.strip
        strip.state.version = 6
        environment.lan.put(strip, at: Self.stripHost)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.stripMAC) != nil })
        let light = try #require(host.accessory(Fixtures.stripMAC)?.service(.lightbulb))
        try await write(light[.hue], .double(120))
        #expect(environment.lan.commands(to: Self.stripHost).map(hex) == ["31 00 FF 00 00 00 FF 0F 3E"])
        await host.stop()
    }

    @Test func brightnessWhileOffSendsPowerOff() async throws {
        var strip = Fixtures.strip
        strip.state.isOn = false
        environment.lan.put(strip, at: Self.stripHost)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.stripMAC) != nil })
        let light = try #require(host.accessory(Fixtures.stripMAC)?.service(.lightbulb))
        #expect(light[.on]?.value == .bool(false))
        try await write(light[.brightness], .int(40))
        #expect(environment.lan.commands(to: Self.stripHost).map(hex) == ["71 24 0F A4"])
        // Adaptive Lighting's white for a light that is off sends nothing.
        try await write(light[.colorTemperature], .int(300))
        #expect(environment.lan.commands(to: Self.stripHost).count == 1)
        // On: the power frame, and the white that waited.
        try await write(light[.on], .bool(true))
        #expect(environment.lan.commands(to: Self.stripHost).dropFirst().first.map(hex) == "71 23 0F A3")
        #expect(environment.lan.commands(to: Self.stripHost).count == 3)
        await host.stop()
    }

    /// The bridge stays light: one query per device per poll, a slider's drag one frame.
    @Test func pollsAreCountedAndSlidersCoalesced() async throws {
        var strip = Fixtures.strip
        strip.state.version = 6
        environment.lan.put(strip, at: Self.stripHost)
        let started = ContinuousClock.now
        let host = try await environment.start(settings: ["advancedOptions": ["periodicDiscovery": false]])
        #expect(await eventually { host.accessory(Fixtures.stripMAC) != nil })
        _ = try #require(host.accessory(Fixtures.stripMAC)?.service(.lightbulb))
        #expect(await eventually { environment.lan.queries(to: Self.stripHost) >= 4 })
        let elapsed = ContinuousClock.now - started
        // The query that added it, then one every 200 ms.
        let queries = environment.lan.queries(to: Self.stripHost)
        #expect(queries >= 3 && queries <= Int(elapsed / .milliseconds(200)) + 2, "\(queries) queries in \(elapsed)")
        // A drag: twenty brightness writes 2 ms apart, one frame. They reach the device in order, as one connection's
        // requests do: twenty tasks sleeping 2 ms apart could wake out of order on a loaded machine.
        let before = environment.lan.commands(to: Self.stripHost).count
        let device = try #require(await environment.plugin?.devices[Fixtures.stripMAC])
        try await device.drag(brightness: (0..<20).map { 50 + $0 }, spacing: .milliseconds(2))
        // Coalesced (a loaded machine may stretch the drag past one window, so a few frames, never twenty), the last
        // with the drag's last value.
        let last = hex(MagicHomeLevels.original(.rgbwwStrip, light: MagicHomeLight(hue: 0, saturation: 100, brightness: 69), effects: MagicHomeWhiteEffects())[0])
        #expect(await eventually { environment.lan.commands(to: Self.stripHost).last.map(hex) == last })
        let frames = Array(environment.lan.commands(to: Self.stripHost).dropFirst(before))
        #expect(frames.count <= 3, "\(frames.map(hex))")
        // The scan ran once (no device was missing), and not periodically.
        #expect(await environment.plugin?.scans == 1)
        await host.stop()
    }

    @Test func aChangeOnTheDeviceReachesHomeKit() async throws {
        environment.lan.put(Fixtures.strip, at: Self.stripHost)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.stripMAC) != nil })
        let light = try #require(host.accessory(Fixtures.stripMAC)?.service(.lightbulb))
        environment.lan.update(at: Self.stripHost) { state in
            state.red = 0
            state.blue = 128
        }
        #expect(await eventually { light[.hue]?.value == .double(240) })
        #expect(light[.brightness]?.value == .int(50))
        environment.lan.update(at: Self.stripHost) { $0.isOn = false }
        #expect(await eventually { light[.on]?.value == .bool(false) })
        // Off: the brightness stays as it was.
        #expect(light[.brightness]?.value == .int(50))
        await host.stop()
    }

    @Test func aDeviceThatStopsAnsweringShowsNoResponse() async throws {
        environment.lan.put(Fixtures.strip, at: Self.stripHost)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.stripMAC) != nil })
        let accessory = try #require(host.accessory(Fixtures.stripMAC))
        #expect(!accessory.isUnavailable)
        environment.lan.silence(Self.stripHost)
        #expect(await eventually { accessory.isUnavailable })
        // A write fails rather than pretending.
        await #expect(throws: (any Error).self) { try await write(accessory.service(.lightbulb)?[.on], .bool(false)) }
        environment.lan.silence(Self.stripHost, false)
        #expect(await eventually { !accessory.isUnavailable })
        await host.stop()
    }

    @Test func adaptiveLightingFollowsItsOwnWhiteAndStopsForAColourSetElsewhere() async throws {
        environment.lan.put(Fixtures.bulb, at: Self.bulbHost)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.bulbMAC) != nil })
        let light = try #require(host.accessory(Fixtures.bulbMAC)?.service(.lightbulb))
        // The 0x35 bulb's white shows as a colour temperature.
        #expect(await eventually { light[.colorTemperature]?.value == .int(274) })
        let controller = try #require(await environment.plugin?.adaptiveLighting[Fixtures.bulbMAC])
        // Turned on, it writes its white through the characteristic's handler, as HomeKit would.
        try controller.activateForTesting(mireds: 300)
        // The frames go out before the write returns, and the characteristic takes the white once it has.
        #expect(await eventually {
            environment.lan.commands(to: Self.bulbHost).count >= 2 && light[.colorTemperature]?.value.intValue.map { abs($0 - 300) <= 2 } == true
        })
        let shown = try #require(light[.colorTemperature]?.value.intValue)
        #expect(abs(shown - 300) <= 2)
        // Version 8 needs the power first.
        let white = MagicHomeLevels.whiteFrames(mireds: shown, brightness: 100, profile: MagicHomeProfile.make(model: 0x35, version: 8, modeByte: 1)!)
        #expect(Array(environment.lan.commands(to: Self.bulbHost).prefix(2)).map(hex) == ["71 23 0F A3"] + white.map { hex($0.bytes) })
        // The bulb reports that white back: it stays on.
        let queries = environment.lan.queries(to: Self.bulbHost)
        #expect(await eventually { environment.lan.queries(to: Self.bulbHost) >= queries + 2 })
        #expect(controller.isAdaptiveLightingActive)
        #expect(abs((light[.colorTemperature]?.value.intValue ?? 0) - shown) <= 2)
        // Red set in the Magic Home app: off.
        environment.lan.update(at: Self.bulbHost) { state in
            (state.red, state.warm, state.cool) = (255, 0, 0)
        }
        #expect(await eventually { !controller.isAdaptiveLightingActive })
        #expect(await eventually { light[.hue]?.value == .double(0) && light[.saturation]?.value == .double(100) })
        await host.stop()
    }

    @Test func aCCTBulbTakesItsTemperatureInPercent() async throws {
        environment.lan.put(Fixtures.cct, at: Self.cctHost)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.cctMAC) != nil })
        let light = try #require(host.accessory(Fixtures.cctMAC)?.service(.lightbulb))
        #expect(light[.hue] == nil && light[.saturation] == nil)
        #expect(light[.colorTemperature]?.value == .int(260) && light[.brightness]?.value == .int(80))
        #expect(await environment.plugin?.adaptiveLighting[Fixtures.cctMAC] != nil)
        try await write(light[.colorTemperature], .int(200))
        // Its family needs the power first: 5000 K at 80 %.
        #expect(environment.lan.commands(to: Self.cctHost).map(hex) == ["71 23 0F A3", hex(MagicHomeFrame.temperature(61, brightness: 80))])
        // The version from AT+LVER names it in Setup before any TCP connection.
        let found = try await environment.plugin?.discover() ?? []
        #expect(found.first { $0.deviceID == Fixtures.cctMAC }?.model == "High Voltage Bulb CCT")
        await host.stop()
    }

    @Test func aSocketIsASwitch() async throws {
        environment.lan.put(Fixtures.socket, at: Self.socketHost)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.socketMAC) != nil })
        let accessory = try #require(host.accessory(Fixtures.socketMAC))
        #expect(accessory.category == .switch)
        #expect(accessory.information[.name]?.value == .string("Power Socket"))
        let on = try #require(accessory.service(.switch)?[.on])
        #expect(on.value == .bool(true))
        try await write(on, .bool(false))
        #expect(environment.lan.commands(to: Self.socketHost).map(hex) == ["71 24 0F A4"])
        #expect(await environment.plugin?.deviceKind(of: Fixtures.socketMAC) == "switch")
        await host.stop()
    }

    /// A family that wraps its requests and pushes its changes on a connection it keeps open.
    @Test func aWrappedDeviceKeepsItsConnectionAndPushes() async throws {
        environment.lan.put(Fixtures.table, at: Self.tableHost)
        // No poll of its own while the test waits for the push: what arrives is the push.
        var timing = TestEnvironment.timing
        timing.pushPoll = .seconds(60)
        let host = try await environment.start(timing: timing)
        #expect(await eventually { host.accessory(Fixtures.tableMAC) != nil })
        let light = try #require(host.accessory(Fixtures.tableMAC)?.service(.lightbulb))
        #expect(light[.colorTemperature]?.value == .int(217) && light[.brightness]?.value == .int(100))
        // Counted before the writes: the read that follows them comes 250 ms after the last one, which a loaded runner
        // can let pass before the test looks.
        let written = environment.lan.queries(to: Self.tableHost)
        try await write(light[.on], .bool(false))
        try await write(light[.on], .bool(true))
        // Wrapped, and counted from 0 on the connection: every frame on it, a query a slow machine lets in between the
        // writes included.
        let wrapped = environment.lan.frames.filter { $0.host == Self.tableHost && $0.wrapCounter != nil }
        #expect(wrapped.map(\.wrapCounter) == wrapped.indices.map { UInt8($0) })
        #expect(wrapped.filter { $0.inner != MagicHomeFrame.stateQuery }.map(\.inner).map(hex) == ["71 24 0F A4", "71 23 0F A3"])
        // One connection: the query that found it had its own.
        #expect(environment.lan.connections(to: Self.tableHost) == 2)
        // After the read that follows the writes (a push before it would be taken for the fade), a change in the app
        // arrives on that connection before any poll.
        #expect(await eventually { environment.lan.queries(to: Self.tableHost) > written })
        let queries = environment.lan.queries(to: Self.tableHost)
        environment.lan.update(at: Self.tableHost) { $0.warm = 0 }
        environment.lan.push(from: Self.tableHost)
        #expect(await eventually { light[.colorTemperature]?.value == .int(370) })
        #expect(environment.lan.queries(to: Self.tableHost) == queries)
        await host.stop()
    }

    /// A push while a write settles may be the fade: not shown, and the read once it settled still goes out.
    @Test func aPushWhileAWriteSettlesIsReadAgain() async throws {
        environment.lan.put(Fixtures.table, at: Self.tableHost)
        var timing = TestEnvironment.timing
        timing.pushPoll = .seconds(60)
        // Long enough for the push to come within it on a loaded machine.
        timing.settle = .seconds(2)
        let host = try await environment.start(timing: timing)
        #expect(await eventually { host.accessory(Fixtures.tableMAC) != nil })
        let light = try #require(host.accessory(Fixtures.tableMAC)?.service(.lightbulb))
        #expect(light[.colorTemperature]?.value == .int(217))
        try await write(light[.on], .bool(true))
        let written = environment.lan.queries(to: Self.tableHost)
        environment.lan.update(at: Self.tableHost) { $0.warm = 0 }
        environment.lan.push(from: Self.tableHost)
        #expect(await eventually { environment.lan.queries(to: Self.tableHost) > written })
        #expect(await eventually { light[.colorTemperature]?.value == .int(370) })
        await host.stop()
    }

    /// A reply and a push right behind it: the reply's poll, resumed after the push was shown, does not put back the older
    /// state.
    @Test func aPushRightAfterAReplyIsNotUndoneByIt() async throws {
        environment.lan.put(Fixtures.table, at: Self.tableHost)
        var timing = TestEnvironment.timing
        timing.pushPoll = .seconds(60)
        let host = try await environment.start(timing: timing)
        #expect(await eventually { host.accessory(Fixtures.tableMAC) != nil })
        let light = try #require(host.accessory(Fixtures.tableMAC)?.service(.lightbulb))
        #expect(light[.colorTemperature]?.value == .int(217))
        let device = try #require(await environment.plugin?.devices[Fixtures.tableMAC])
        environment.lan.pushAfterNextReply(from: Self.tableHost) { $0.warm = 0 }
        _ = await device.poll()
        #expect(await eventually { light[.colorTemperature]?.value == .int(370) })
        #expect(environment.lan.queries(to: Self.tableHost) == 2)
        await host.stop()
    }

    @Test func aDeviceThatMovesKeepsItsAccessory() async throws {
        environment.lan.put(Fixtures.socket, at: Self.socketHost)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.socketMAC) != nil })
        let aid = try #require(host.accessory(Fixtures.socketMAC)).aid
        environment.lan.remove(at: Self.socketHost)
        environment.lan.put(Fixtures.socket, at: "192.168.1.99")
        #expect(await eventually { await environment.plugin?.records[Fixtures.socketMAC]?.host == "192.168.1.99" })
        try await write(host.accessory(Fixtures.socketMAC)?.service(.switch)?[.on], .bool(false))
        #expect(environment.lan.commands(to: "192.168.1.99").map(hex) == ["71 24 0F A4"])
        #expect(host.accessory(Fixtures.socketMAC)?.aid == aid)
        await host.stop()
    }

    @Test func theListsLeaveDevicesOut() async throws {
        environment.lan.put(Fixtures.strip, at: Self.stripHost)
        environment.lan.put(Fixtures.socket, at: Self.socketHost)
        let host = try await environment.start(settings: ["deviceManagement": ["blacklistOrWhitelist": "blacklist", "blacklistedUniqueIDs": [Fixtures.stripMAC]]])
        #expect(await eventually { host.accessory(Fixtures.socketMAC) != nil })
        #expect(host.accessory(Fixtures.stripMAC) == nil)
        let found = try await environment.plugin?.discover() ?? []
        #expect(found.first { $0.deviceID == Fixtures.stripMAC }?.excludedBySettings == true)
        await host.stop()

        let whitelisted = TestEnvironment()
        whitelisted.lan.put(Fixtures.strip, at: Self.stripHost)
        whitelisted.lan.put(Fixtures.socket, at: Self.socketHost)
        let other = try await whitelisted.start(settings: ["deviceManagement": ["blacklistOrWhitelist": "whitelist", "blacklistedUniqueIDs": [Fixtures.stripMAC]]])
        #expect(await eventually { other.accessory(Fixtures.stripMAC) != nil })
        #expect(other.accessory(Fixtures.socketMAC) == nil)
        await other.stop()
    }

    @Test func anExcludedDeviceIsNotReached() async throws {
        environment.lan.put(Fixtures.strip, at: Self.stripHost)
        environment.lan.put(Fixtures.socket, at: Self.socketHost)
        let host = try await environment.start(settings: ["_accessories": [Fixtures.stripMAC: ["excluded": true]]])
        #expect(await eventually { host.accessory(Fixtures.socketMAC) != nil })
        #expect(host.accessory(Fixtures.stripMAC) == nil)
        #expect(environment.lan.connections(to: Self.stripHost) == 0)
        await host.stop()
    }

    @Test func anUnknownModelMakesNothing() async throws {
        var strange = Fixtures.strip
        strange.state.model = 0x99
        environment.lan.put(strange, at: Self.stripHost)
        environment.lan.put(Fixtures.socket, at: Self.socketHost)
        var timing = TestEnvironment.timing
        timing.retryRejected = .seconds(300)
        let host = try await environment.start(timing: timing)
        #expect(await eventually { host.accessory(Fixtures.socketMAC) != nil })
        #expect(host.accessory(Fixtures.stripMAC) == nil)
        // The periodic scans hear it again, and do not ask it again (`retryRejected`).
        #expect(await eventually { await (environment.plugin?.scans ?? 0) >= 4 })
        #expect(environment.lan.queries(to: Self.stripHost) == 1)
        // Heard, not set up.
        let found = try await environment.plugin?.discover() ?? []
        #expect(found.first { $0.deviceID == Fixtures.stripMAC }?.isSetUp == false)
        await host.stop()
    }

    @Test func aWhitelistRemovesTheCachedAccessoriesItLeavesOut() async throws {
        environment.lan.put(Fixtures.strip, at: Self.stripHost)
        environment.lan.put(Fixtures.socket, at: Self.socketHost)
        let first = try await environment.start()
        #expect(await eventually { first.accessory(Fixtures.stripMAC) != nil && first.accessory(Fixtures.socketMAC) != nil })
        await first.stop()
        let second = try await environment.start(settings: ["deviceManagement": ["blacklistOrWhitelist": "whitelist", "blacklistedUniqueIDs": [Fixtures.socketMAC]]])
        #expect(await eventually { second.accessory(Fixtures.socketMAC) != nil })
        #expect(second.accessory(Fixtures.stripMAC) == nil)
        await second.stop()
    }

    /// Adaptive Lighting's white while the light is off is not sent then, and goes with the power-on.
    @Test func adaptiveLightingWhileOffWaitsForThePowerOn() async throws {
        var bulb = Fixtures.bulb
        bulb.state.isOn = false
        environment.lan.put(bulb, at: Self.bulbHost)
        let host = try await environment.start(settings: ["advancedOptions": ["periodicDiscovery": false]])
        #expect(await eventually { host.accessory(Fixtures.bulbMAC)?.service(.lightbulb)?[.on]?.value == .bool(false) })
        let light = try #require(host.accessory(Fixtures.bulbMAC)?.service(.lightbulb))
        let controller = try #require(await environment.plugin?.adaptiveLighting[Fixtures.bulbMAC])
        try controller.activateForTesting(mireds: 300)
        #expect(await eventually { light[.colorTemperature]?.value.intValue.map { abs($0 - 300) <= 2 } == true })
        try await Task.sleep(for: .milliseconds(100))
        #expect(environment.lan.commands(to: Self.bulbHost).isEmpty)
        try await write(light[.on], .bool(true))
        let shown = try #require(light[.colorTemperature]?.value.intValue)
        let white = MagicHomeLevels.whiteFrames(mireds: shown, brightness: 100, profile: MagicHomeProfile.make(model: 0x35, version: 8, modeByte: 1)!)
        #expect(environment.lan.commands(to: Self.bulbHost).map(hex) == ["71 23 0F A3"] + white.map { hex($0.bytes) })
        await host.stop()
    }

    @Test func aKnownDeviceIsBackBeforeAnyScan() async throws {
        environment.lan.put(Fixtures.socket, at: Self.socketHost)
        let first = try await environment.start()
        #expect(await eventually { first.accessory(Fixtures.socketMAC) != nil })
        await first.stop()
        // The broadcast reaches nothing now; the device still answers at its address.
        environment.lan.remove(at: Self.socketHost)
        var socket = Fixtures.socket
        socket.state.isOn = false
        environment.lan.put(socket, at: Self.socketHost)
        environment.lan.hideFromScans(Self.socketHost)
        let second = try await environment.start(settings: ["advancedOptions": ["periodicDiscovery": false]])
        #expect(await eventually { second.accessory(Fixtures.socketMAC)?.service(.switch)?[.on]?.value == .bool(false) })
        await second.stop()
    }

    @Test func pruningRemovesWhatNoScanHears() async throws {
        environment.lan.put(Fixtures.socket, at: Self.socketHost)
        let first = try await environment.start()
        #expect(await eventually { first.accessory(Fixtures.socketMAC) != nil })
        await first.stop()
        environment.lan.remove(at: Self.socketHost)
        let settings: [String: Any] = ["pruning": ["pruneMissingCachedAccessories": true, "restartsBeforeMissingAccessoriesPruned": 2]]
        let second = try await environment.start(settings: settings)
        try await Task.sleep(for: .milliseconds(100))
        #expect(second.accessory(Fixtures.socketMAC) != nil)
        await second.stop()
        let third = try await environment.start(settings: settings)
        #expect(third.accessory(Fixtures.socketMAC) == nil)
        #expect(await environment.plugin?.records.values.isEmpty == true)
        await third.stop()
    }

    @Test func identifyFlashesAndPutsTheLightBack() async throws {
        var strip = Fixtures.strip
        strip.state.version = 6
        environment.lan.put(strip, at: Self.stripHost)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.stripMAC) != nil })
        let identify = try #require(host.accessory(Fixtures.stripMAC)?.information[.identify])
        try await write(identify, .bool(true))
        // Answered at once; four ticks, then the red it showed.
        #expect(await eventually { environment.lan.commands(to: Self.stripHost).count == 5 })
        let frames = environment.lan.commands(to: Self.stripHost).map(hex)
        let red = MagicHomeLevels.original(.rgbwwStrip, light: MagicHomeLight(hue: 0, saturation: 100, brightness: 100), effects: MagicHomeWhiteEffects())
        #expect(frames.last == hex(red[0]))
        await host.stop()
    }

    @Test func setupListsWhatTheScanHeard() async throws {
        environment.lan.put(Fixtures.strip, at: Self.stripHost)
        environment.lan.put(Fixtures.cct, at: Self.cctHost)
        let host = try await environment.start()
        #expect(await eventually { host.accessory(Fixtures.cctMAC) != nil && host.accessory(Fixtures.stripMAC) != nil })
        let found = try await environment.plugin?.discover() ?? []
        #expect(found.map(\.deviceID).sorted() == [Fixtures.stripMAC, Fixtures.cctMAC].sorted())
        let strip = try #require(found.first { $0.deviceID == Fixtures.stripMAC })
        #expect(strip.address == Self.stripHost && strip.isSetUp && strip.isReachable && strip.kind == "light")
        await host.stop()
    }

    @Test func canonicalSettingsMovesTheBlacklist() throws {
        let block: JSONValue = [
            "platform": "homebridge-magichome-dynamic-platform",
            "deviceManagement": ["blacklistOrWhitelist": "blacklist", "blacklistedUniqueIDs": ["accf23a1b2c3", "6001940EDC1F"]],
            "_accessories": ["6001940EDC1F": ["excluded": false]],
        ]
        let canonical = MagicHomePlugin.canonical(block)
        #expect(canonical["deviceManagement"] == nil)
        #expect(canonical["_accessories"]?["ACCF23A1B2C3"]?["excluded"] == true)
        // An entry's own value wins.
        #expect(canonical["_accessories"]?["6001940EDC1F"]?["excluded"] == false)
        #expect(MagicHomePlugin.canonical(canonical) == canonical)
        // A whitelist cannot be said per device: unchanged.
        let whitelist: JSONValue = ["deviceManagement": ["blacklistOrWhitelist": "whitelist", "blacklistedUniqueIDs": ["ACCF23A1B2C3"]]]
        #expect(MagicHomePlugin.canonical(whitelist) == whitelist)
        // What is not a MAC stays in the list.
        let odd: JSONValue = ["deviceManagement": ["blacklistOrWhitelist": "blacklist", "blacklistedUniqueIDs": ["kitchen"]]]
        #expect(MagicHomePlugin.canonical(odd)["deviceManagement"]?["blacklistedUniqueIDs"] == ["kitchen"])
    }

    @Test func schemaIsCurrent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(MagicHomePlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/MagicHome MagicHomePlugin")
        let schema = try JSONValue(string: try #require(MagicHomePlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "homebridge-magichome-dynamic-platform")
        #expect(schema["schema"]?["properties"]?["whiteEffects"]?["properties"]?["simultaniousDevicesColorWhite"] != nil)
    }
}
