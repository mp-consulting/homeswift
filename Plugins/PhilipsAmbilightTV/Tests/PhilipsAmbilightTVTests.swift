import Foundation
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftNetwork
@testable import HomeswiftPhilipsAmbilightTV

/// The log in tests: set HOMESWIFT_TEST_LOG to a level (trace, debug, ...) to see it.
let testLogger: Logger = {
    var logger = Logger(label: "homeswift")
    logger.logLevel = ProcessInfo.processInfo.environment["HOMESWIFT_TEST_LOG"].flatMap(Logger.Level.init(rawValue:)) ?? .warning
    return logger
}()

/// A host with one Philips platform block whose plugin talks to `tv`.
final class PhilipsTestEnvironment: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-philips-tests-\(UUID().uuidString)")
    let tv = FakeTV()
    /// This machine's ARP table as the plugin sees it: IP to MAC.
    let arpTable = NIOLockedValueBox<[String: String]>([:])
    private let plugins = NIOLockedValueBox<[PhilipsAmbilightTVPlugin]>([])
    private let storages = NIOLockedValueBox<[String: MemoryStorage]>([:])

    var plugin: PhilipsAmbilightTVPlugin? { plugins.withLockedValue { $0.last } }

    func host(settings: [String: Any]) throws -> PluginHost {
        var registry = PluginRegistry()
        registry.register(platform: PhilipsAmbilightTVPlugin.platform, name: PhilipsAmbilightTVPlugin.name) { json, context in
            let configuration = try JSONDecoder().decode(PhilipsAmbilightTVPlugin.Configuration.self, from: json)
            let plugin = PhilipsAmbilightTVPlugin(
                configuration: configuration, context: context,
                dependencies: .init(transports: FakeTransports(tv: self.tv), discover: { _ in [.init(name: "Fake TV", host: "192.168.1.20")] },
                    lookUpARP: { ip in self.arpTable.withLockedValue { $0[ip] } }))
            self.plugins.withLockedValue { $0.append(plugin) }
            return plugin
        }
        let block = try HomeswiftConfiguration.Platform(platform: PhilipsAmbilightTVPlugin.platform, name: "Philips TVs", settings: settings)
        let configuration = HomeswiftConfiguration(bridge: .init(port: 0), platforms: [block])
        let options = PluginHost.Options(advertise: false, logger: testLogger) { name in
            self.storages.withLockedValue { storages in
                if let storage = storages[name] { return storage }
                let storage = MemoryStorage()
                storages[name] = storage
                return storage
            }
        }
        return try PluginHost(configuration: configuration, registry: registry, storageDirectory: directory, options: options)
    }

    func start(settings: [String: Any]) async throws -> PluginHost {
        let host = try host(settings: settings)
        try await host.start()
        return host
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

var livingRoom: [String: Any] { [
    "name": "Living Room TV", "mac": "aa:bb:cc:dd:ee:ff", "ip": "192.168.1.20", "username": "user1", "password": "secret",
    "certFingerprint": FakeTV.fingerprint, "pollingInterval": 1000, "wakeOnLanEnabled": false,
    "sourceSwitches": true, "ambilightHueSwitch": true, "customButtons": [["name": "Netflix key", "key": "RedColour"], ["name": "Again", "key": "RedColour"]],
    "stateSensors": ["power", "ambilight", "mute"], "customApps": [["name": "Plex", "packageName": "com.plexapp.android", "className": "com.plexapp.plex.activities.SplashActivity"]],
    "sources": [["id": "com.android.tv.settings", "visible": true], ["id": JointSpace.homeURI, "order": 1], ["id": JointSpace.watchTVURI, "order": 2, "customName": "Télé"]],
] }
let tvID = "PhilipsAmbilightTV:AA:BB:CC:DD:EE:FF"

@Suite(.timeLimit(.minutes(1)))
struct ConfigurationTests {
    @Test func checksADeviceBlock() throws {
        let data = try JSONSerialization.data(withJSONObject: ["name": "TVs", "devices": [livingRoom, ["name": "Broken", "mac": "nope", "ip": "1.2.3.4", "username": "u", "password": "p"]]])
        let configuration = try JSONDecoder().decode(PhilipsAmbilightTVPlugin.Configuration.self, from: data)
        let devices = try #require(configuration.devices)
        let settings = try TVSettings(devices[0])
        #expect(settings.mac == "AA:BB:CC:DD:EE:FF")
        #expect(settings.pollingInterval == .seconds(1))
        #expect(settings.ambilightMode == "FOLLOW_VIDEO/NATURAL")
        #expect(settings.infoButtonKey == "Source" && settings.backButtonKey == "Back" && settings.playPauseButtonKey == "PlayPause")
        #expect(settings.customButtons.map(\.key) == ["RedColour", "RedColour"])
        #expect(settings.stateSensors == [.power, .ambilight, .mute])
        #expect(settings.customApps == [InputData(id: "com.plexapp.android", name: "Plex", type: .app, className: "com.plexapp.plex.activities.SplashActivity")])
        #expect(settings.sources[JointSpace.watchTVURI]?.customName == "Télé")
        #expect(throws: TVConfigurationError.invalid("mac", "nope")) { try TVSettings(devices[1]) }
        #expect(throws: TVConfigurationError.missing("password")) { try TVSettings(.init(name: "x", mac: "aa:bb:cc:dd:ee:ff", ip: "1.2.3.4", username: "u")) }
        #expect(throws: TVConfigurationError.invalid("pollingInterval", "10")) { try TVSettings(.init(name: "x", mac: "aa:bb:cc:dd:ee:ff", ip: "1.2.3.4", username: "u", password: "p", pollingInterval: 10)) }
        // A fingerprint that is not one must not quietly accept any certificate.
        #expect(throws: TVConfigurationError.invalid("certFingerprint", "abc")) { try TVSettings(.init(name: "x", mac: "aa:bb:cc:dd:ee:ff", ip: "1.2.3.4", username: "u", password: "p", certFingerprint: "abc")) }
        #expect(try TVSettings(.init(name: "x", mac: "aa:bb:cc:dd:ee:ff", ip: "1.2.3.4", username: "u", password: "p", certFingerprint: " ")).certFingerprint == nil)
        #expect(try TVSettings(.init(name: "x", mac: "aa:bb:cc:dd:ee:ff", ip: "1.2.3.4", username: "u", password: "p", certFingerprint: FakeTV.fingerprint.uppercased())).certFingerprint == FakeTV.fingerprint)
    }

    @Test func helpers() {
        #expect(TVSettings.canonicalMAC("aa-bb-cc-dd-ee-ff") == "AA:BB:CC:DD:EE:FF")
        #expect(TVSettings.canonicalMAC("aabbccddeeff") == "AA:BB:CC:DD:EE:FF")
        #expect(TVSettings.canonicalMAC("hello") == nil)
        #expect(TVSettings.homeKitName("Disney+") == "Disney Plus")
        #expect(TVSettings.homeKitName("com.netflix.ninja") == "com.netflix.ninja")
        #expect(TVSettings.homeKitName("  Tom & Jerry / 2 ") == "Tom and Jerry 2")
        #expect(TVSettings.homeKitName("!!!") == "Unnamed")
        #expect(Inputs.isGenericName("Input Source 2") && Inputs.isGenericName("entrada 3") && !Inputs.isGenericName("Netflix"))
        #expect(Inputs.displayOrder([1, 2]) == Data([0x01, 0x04, 1, 0, 0, 0, 0x00, 0x00, 0x01, 0x04, 2, 0, 0, 0]).base64EncodedString())
        #expect(ColorConversion.philipsColor(hue: 360, saturation: 100, brightness: 100) == .init(hue: 255, saturation: 255, brightness: 255))
        let converted = ColorConversion.homeKitColor(.init(hue: 128, saturation: 255, brightness: 0))
        #expect(converted.hue == 181 && converted.saturation == 100 && converted.brightness == 0)
        let warm = ColorConversion.hueAndSaturation(mireds: 500)
        #expect(warm.hue < 45 && warm.saturation > 50)
        let cool = ColorConversion.hueAndSaturation(mireds: 140)
        #expect(cool.saturation < 30)
        #expect(JointSpacePairing.signature(timestamp: 42, pin: "1234") == JointSpacePairing.signature(timestamp: 42, pin: "1234"))
        #expect(JointSpacePairing.signature(timestamp: 42, pin: "1234") != JointSpacePairing.signature(timestamp: 43, pin: "1234"))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct PairingTests {
    let environment = PhilipsTestEnvironment()

    @Test func pairsWithDigestAndPIN() async throws {
        let transport = FakeTransports(tv: environment.tv).makeTransport(tls: .any)
        let session = try await JointSpacePairing.request(ip: "192.168.1.20", deviceName: "Homeswift", transport: transport)
        #expect(session.authKey == "key-from-tv" && session.timestamp == 42)
        #expect(session.certificateFingerprint == FakeTV.fingerprint)
        #expect(session.device.app_id == "app.homeswift.philips.\(session.device.id)")
        let pinned = FakeTransports(tv: environment.tv).makeTransport(tls: .pinned(FakeTV.fingerprint))
        await #expect(throws: JointSpaceError.self) { try await JointSpacePairing.grant(session, pin: "0000", transport: pinned) }
        let credentials = try await JointSpacePairing.grant(session, pin: "1234", transport: pinned)
        #expect(credentials.username == session.device.id && credentials.password == "key-from-tv" && credentials.certFingerprint == FakeTV.fingerprint)
        #expect(await environment.tv.challenges == 2)   // one per grant: the TV challenges every new connection
    }

    @Test func pairsFromTheWebPage() async throws {
        _ = try await environment.start(settings: ["devices": []])
        let plugin = try #require(environment.plugin)
        let started = try await plugin.handleWebRequest(.init(method: "POST", path: "pair", body: ["ip": "192.168.1.20"], user: "admin"))
        #expect(started.status == 200 && started.json["certificateSeen"] == true)
        let wrong = try await plugin.handleWebRequest(.init(method: "POST", path: "pair/grant", body: ["ip": "192.168.1.20", "pin": "9999"], user: "admin"))
        #expect(wrong.status == 502)
        let granted = try await plugin.handleWebRequest(.init(method: "POST", path: "pair/grant", body: ["ip": "192.168.1.20", "pin": "1234"], user: "admin"))
        #expect(granted.status == 200)
        #expect(granted.json["device"]?["password"] == "key-from-tv")
        #expect(granted.json["device"]?["certFingerprint"]?.stringValue == FakeTV.fingerprint)
        #expect(granted.json["device"]?["mac"] == "AA:BB:CC:DD:EE:FF")
        let found = try await plugin.handleWebRequest(.init(method: "GET", path: "discover", user: "admin"))
        #expect(found.json["tvs"]?[0]?["host"] == "192.168.1.20")
    }

    /// Pairs from the web page and returns the MAC address the entry carries.
    private func pairedMAC() async throws -> JSONValue? {
        _ = try await environment.start(settings: ["devices": []])
        let plugin = try #require(environment.plugin)
        _ = try await plugin.handleWebRequest(.init(method: "POST", path: "pair", body: ["ip": "192.168.1.20"], user: "admin"))
        let granted = try await plugin.handleWebRequest(.init(method: "POST", path: "pair/grant", body: ["ip": "192.168.1.20", "pin": "1234"], user: "admin"))
        #expect(granted.status == 200)
        return granted.json["device"]?["mac"]
    }

    @Test func prefersTheInterfaceThatAnswers() async throws {
        await environment.tv.set(networkDevices: [
            ["id": "wifi0", "mac": "aa:bb:cc:dd:ee:ff", "type": "Wifi"],
            ["id": "eth0", "mac": "11:22:33:44:55:66", "ip": "192.168.1.20", "type": "Ethernet"],
        ])
        #expect(try await pairedMAC() == "11:22:33:44:55:66")
    }

    @Test func findsTheMACInTheARPTableWhenTheTVDoesNotSay() async throws {
        await environment.tv.set(networkDevices: nil)
        environment.arpTable.withLockedValue { $0["192.168.1.20"] = "0a:bb:cc:0d:ee:f0" }
        #expect(try await pairedMAC() == "0A:BB:CC:0D:EE:F0")
    }

    @Test func pairsWithoutAMACWhenNothingKnowsIt() async throws {
        await environment.tv.set(networkDevices: [["id": "wifi0", "type": "Wifi"]])
        #expect(try await pairedMAC() == nil)
    }

    @Test func readsNetworkDevicesWithOddFieldTypes() throws {
        let json = #"[{"id": "eth0", "mac": "11:22:33:44:55:66", "ip": "192.168.1.20", "wake-on-lan": true, "type": 1}]"#
        let devices = try JSONDecoder().decode([JointSpace.NetworkDevice].self, from: Data(json.utf8))
        #expect(devices.first?.mac == "11:22:33:44:55:66" && devices.first?.wake_on_lan == nil && devices.first?.type == nil)
    }

    @Test func refusesAnotherCertificate() async throws {
        let tv = environment.tv
        let client = JointSpaceClient(ip: "192.168.1.20", username: "user1", password: "secret", certificateFingerprint: String(repeating: "cd", count: 32), transports: FakeTransports(tv: tv), logger: testLogger)
        await #expect(throws: JointSpaceError.certificateMismatch(expected: String(repeating: "cd", count: 32), observed: FakeTV.fingerprint)) { try await client.powerState() }
        let trusting = JointSpaceClient(ip: "192.168.1.20", username: "user1", password: "wrong", certificateFingerprint: nil, transports: FakeTransports(tv: tv), logger: testLogger)
        await #expect(throws: JointSpaceError.unauthorized) { try await trusting.powerState() }
    }

    @Test func pinsTheFirstCertificateAndNeverDowngrades() async throws {
        // Without a configured fingerprint, the first certificate seen is pinned for the run.
        let tv = SchemeFakeTV()
        let client = JointSpaceClient(ip: "192.168.1.20", username: "u", password: "p", certificateFingerprint: nil, transports: SchemeFakeTransports(tv: tv), logger: testLogger)
        #expect(try await client.powerState())
        #expect(await client.pinnedFingerprint == FakeTV.fingerprint)
        let other = String(repeating: "ef", count: 32)
        await tv.set(httpsFingerprint: other)
        await #expect(throws: JointSpaceError.certificateMismatch(expected: FakeTV.fingerprint, observed: other)) { try await client.powerState() }
        // HTTPS answered once: a refused HTTPS port is an error, never a switch to plain HTTP.
        await tv.set(httpsFingerprint: nil)
        await #expect(throws: JointSpaceError.connectionRefused(port: JointSpace.securePort)) { try await client.powerState() }
        #expect(await tv.schemes.allSatisfy { $0 == "https" })

        // A set without HTTPS: plain HTTP, but only because the HTTPS port refuses the connection.
        let old = SchemeFakeTV()
        await old.set(httpsFingerprint: nil)
        let plain = JointSpaceClient(ip: "192.168.1.21", username: "u", password: "p", certificateFingerprint: nil, transports: SchemeFakeTransports(tv: old), logger: testLogger)
        #expect(try await plain.powerState())
        #expect(try await plain.powerState())
        #expect(await old.schemes == ["https", "http", "http"])

        // A TV that does not answer (asleep, away) is not probed over plain HTTP.
        let asleep = SchemeFakeTV()
        await asleep.set(httpsTimesOut: true)
        let quiet = JointSpaceClient(ip: "192.168.1.22", username: "u", password: "p", certificateFingerprint: nil, transports: SchemeFakeTransports(tv: asleep), logger: testLogger)
        await #expect(throws: JointSpaceError.self) { try await quiet.powerState() }
        #expect(await asleep.schemes == ["https"])

        // A configured fingerprint never tries plain HTTP.
        let pinned = JointSpaceClient(ip: "192.168.1.21", username: "u", password: "p", certificateFingerprint: FakeTV.fingerprint, transports: SchemeFakeTransports(tv: old), logger: testLogger)
        await #expect(throws: JointSpaceError.connectionRefused(port: JointSpace.securePort)) { try await pinned.powerState() }
    }
}

@Suite(.timeLimit(.minutes(2)), .serialized)
struct TelevisionTests {
    let environment = PhilipsTestEnvironment()

     func publishesTheTelevisionAndFollowsItOn() async throws {
        let tv = environment.tv
        let host = try await environment.start(settings: ["devices": [livingRoom]])
        defer { Task { await host.stop() } }

        // Its own HAP server, a Television with linked inputs and speaker, the switches and sensors asked for.
        #expect(host.bridges.count == 2)
        let bridge = host.bridges[1]
        #expect(bridge.isExternal && bridge.owner == "Philips TVs")
        #expect(bridge.server.primary.id == tvID && bridge.server.primary.category == .television)
        var accessory = bridge.server.primary
        let television = try #require(accessory.service(.television))
        #expect(television.isPrimary)
        #expect(television.linked.count == 6 + 1 + 2)   // the static inputs, the custom app, the speaker and Ambilight
        #expect(television[.configuredName]?.value == .string("Living Room TV"))
        #expect(television[.sleepDiscoveryMode]?.value == .int(1))
        #expect(television[.active]?.value == .int(0))
        // Identifiers start above the six static sources, as the Homebridge plugin numbers them: Watch TV is 7.
        let watchTV = try #require(accessory.service(.inputSource, subtype: "input-7"))
        #expect(watchTV[.configuredName]?.value == .string("Télé"))
        #expect(watchTV[.inputSourceType]?.value == .int(HAPConstants.InputSourceType.hdmi))
        #expect(accessory.service(.inputSource, subtype: "input-13")?[.configuredName]?.value == .string("Plex"))
        #expect(accessory.service(.switch, subtype: "custom-button-RedColour") != nil)
        #expect(accessory.services.filter { $0.type.uuid == ServiceType.switch.uuid && $0.subtype?.hasPrefix("custom-button-") == true }.count == 1)
        #expect(accessory.service(.motionSensor, subtype: "state-sensor-power")?[.motionDetected]?.value == .bool(false))
        #expect(accessory.service(.switch, subtype: "ambilight-hue-switch") != nil)
        #expect(accessory.service(.switch, subtype: "source-switch-\(JointSpace.watchTVURI)") != nil)

        // The TV comes on: HomeKit hears it, the apps are discovered and the accessory rebuilt with them.
        await tv.set(power: "On")
        await tv.set(currentApp: "com.netflix.ninja")
        #expect(await eventually { bridge.server.primary.service(.inputSource, subtype: "input-14") != nil })
        accessory = bridge.server.primary
        let inputs = accessory.services.filter { $0.type.uuid == ServiceType.inputSource.uuid }
        let names = inputs.compactMap { $0[.configuredName]?.value.stringValue }
        #expect(names.contains("Netflix") && names.contains("YouTube") && names.contains("Disney Plus") && names.contains("Settings"))
        #expect(!names.contains("Google TV launcher"))
        let netflix = try #require(inputs.first { $0[.configuredName]?.value == .string("Netflix") })
        #expect(accessory.service(.television)?[.active]?.value == .int(1))
        #expect(await eventually { bridge.server.primary.service(.television)?[.activeIdentifier]?.value == netflix[.identifier]?.value })
        #expect(bridge.server.primary.service(.switch, subtype: "source-switch-com.netflix.ninja")?[.on]?.value == .bool(true))
        #expect(accessory.service(.motionSensor, subtype: "state-sensor-power")?[.motionDetected]?.value == .bool(true))
    }

     func controlsTheTelevision() async throws {
        let tv = environment.tv
        await tv.set(power: "On")
        let host = try await environment.start(settings: ["devices": [livingRoom]])
        defer { Task { await host.stop() } }
        let bridge = host.bridges[1]
        #expect(await eventually { bridge.server.primary.service(.inputSource, subtype: "input-14") != nil })
        let accessory = bridge.server.primary
        let inputs = accessory.services.filter { $0.type.uuid == ServiceType.inputSource.uuid }

        // Writes from HomeKit reach the TV.
        let tvService = try #require(accessory.service(.television))
        try await tvService.characteristic(.remoteKey).write(.int(HAPConstants.RemoteKey.arrowUp))
        try await tvService.characteristic(.remoteKey).write(.int(HAPConstants.RemoteKey.information))
        #expect(await tv.keys == ["CursorUp", "Source"])
        let youtube = try #require(inputs.first { $0[.configuredName]?.value == .string("YouTube") })
        try await tvService.characteristic(.activeIdentifier).write(youtube.characteristic(.identifier).value)
        #expect(await tv.launches.last?.component.className == "com.google.android.apps.youtube.tv.activity.ShellActivity")
        #expect(tvService[.activeIdentifier]?.value == youtube[.identifier]?.value)
        let disney = try #require(inputs.first { $0[.configuredName]?.value == .string("Disney Plus") })
        try await tvService.characteristic(.activeIdentifier).write(disney.characteristic(.identifier).value)
        #expect(await tv.launches.last?.component.className == "com.bamtechmedia.dominguez.main.MainActivity")
        let hdmi2 = try #require(accessory.service(.inputSource, subtype: "input-10"))
        try await tvService.characteristic(.activeIdentifier).write(hdmi2.characteristic(.identifier).value)
        #expect(await tv.launches.last?.extras?["uri"] == JointSpace.hdmiSources[1].id)
        #expect(accessory.service(.switch, subtype: "source-switch-\(JointSpace.hdmiSources[1].id)")?[.on]?.value == .bool(true))

        let speaker = try #require(accessory.service(.televisionSpeaker))
        try await speaker.characteristic(.mute).write(.bool(true))
        #expect(await tv.volume.muted == true)
        #expect(accessory.service(.motionSensor, subtype: "state-sensor-mute")?[.motionDetected]?.value == .bool(false))   // until the TV reports it
        try await speaker.characteristic(.volumeSelector).write(.int(HAPConstants.VolumeSelector.decrement))
        #expect(await tv.keys.last == "VolumeDown")

        let ambilight = try #require(accessory.service(.lightbulb, subtype: "ambilight"))
        try await ambilight.characteristic(.on).write(.bool(true))
        let configuration = await tv.ambilight
        #expect(configuration.style == "FOLLOW_VIDEO" && configuration.menuSetting == "NATURAL")
        try await ambilight.characteristic(.brightness).write(.int(50))
        #expect(await tv.menuBrightness == 5)
        async let hue: Void = ambilight.characteristic(.hue).write(.double(180))
        async let saturation: Void = ambilight.characteristic(.saturation).write(.double(100))
        _ = try await (hue, saturation)
        let colorWrites = await tv.ambilightWrites.filter { $0.style == "FOLLOW_COLOR" }
        #expect(colorWrites.count == 1)
        #expect(colorWrites.first?.colorSettings?.color == .init(hue: 128, saturation: 255, brightness: 128))
        try await ambilight.characteristic(.on).write(.bool(false))
        #expect(await tv.ambilight.style == "OFF")

        let hueSwitch = try #require(accessory.service(.switch, subtype: "ambilight-hue-switch"))
        try await hueSwitch.characteristic(.on).write(.bool(true))
        #expect(await tv.hueLamp)
        let button = try #require(accessory.service(.switch, subtype: "custom-button-RedColour"))
        try await button.characteristic(.on).write(.bool(true))
        #expect(await tv.keys.last == "RedColour")
        #expect(await eventually(timeout: .seconds(3)) { button[.on]?.value == .bool(false) })

        try await tvService.characteristic(.active).write(.int(0))
        #expect(await tv.power == "Standby")
        #expect(accessory.service(.motionSensor, subtype: "state-sensor-power")?[.motionDetected]?.value == .bool(false))
        #expect(accessory.service(.switch, subtype: "source-switch-\(JointSpace.hdmiSources[1].id)")?[.on]?.value == .bool(false))
    }

    @Test func followsTheTVThroughNotificationsAndPolls() async throws {
        let tv = environment.tv
        await tv.set(power: "On")
        let host = try await environment.start(settings: ["devices": [livingRoom]])
        defer { Task { await host.stop() } }
        let bridge = host.bridges[1]
        #expect(await eventually { bridge.server.primary.service(.television)?[.active]?.value == .int(1) })

        // A notification carries the new values: applied without a poll.
        await tv.set(muted: true)
        await tv.notify(["audio/volume": .object(["muted": .bool(true), "current": .number(12)])])
        #expect(await eventually { bridge.server.primary.service(.televisionSpeaker)?[.mute]?.value == .bool(true) })
        #expect(bridge.server.primary.service(.motionSensor, subtype: "state-sensor-mute")?[.motionDetected]?.value == .bool(true))
        await tv.notify(["ambilight/currentconfiguration": .object(["styleName": .string("FOLLOW_COLOR"), "colorSettings": .object(["color": .object(["hue": .number(255), "saturation": .number(255), "brightness": .number(255)])])])])
        #expect(await eventually { bridge.server.primary.service(.lightbulb, subtype: "ambilight")?[.hue]?.value == .double(360) })
        #expect(bridge.server.primary.service(.lightbulb, subtype: "ambilight")?[.on]?.value == .bool(true))

        // The TV goes to standby from the remote: the tile goes dark on the next poll.
        await tv.set(power: "Standby")
        await tv.notify(["powerstate": .object(["powerstate": .string("Standby")])])
        #expect(await eventually { bridge.server.primary.service(.television)?[.active]?.value == .int(0) })
        #expect(bridge.server.primary.service(.lightbulb, subtype: "ambilight")?[.on]?.value == .bool(false))

        // Unreachable for two polls: off; answering again: back.
        await tv.set(power: "On")
        #expect(await eventually { bridge.server.primary.service(.television)?[.active]?.value == .int(1) })
        await tv.set(reachable: false)
        #expect(await eventually(timeout: .seconds(8)) { bridge.server.primary.service(.television)?[.active]?.value == .int(0) })
        await tv.set(reachable: true)
        #expect(await eventually(timeout: .seconds(8)) { bridge.server.primary.service(.television)?[.active]?.value == .int(1) })
    }

    @Test func keepsInputIdentifiersAndNamesAcrossLaunches() async throws {
        let tv = environment.tv
        await tv.set(power: "On")
        let first = try await environment.start(settings: ["devices": [livingRoom]])
        let bridge = first.bridges[1]
        @Sendable func inputNamed(_ name: String) -> Service? {
            bridge.server.primary.services.first { $0.type.uuid == ServiceType.inputSource.uuid && $0[.configuredName]?.value == .string(name) }
        }
        #expect(await eventually { inputNamed("Netflix") != nil })
        let netflix = try #require(inputNamed("Netflix"))
        let identifier = netflix.characteristic(.identifier).value
        try await netflix.characteristic(.configuredName).write(.string("Films"))
        try await netflix.characteristic(.configuredName).write(.string("Input Source 3"))   // tvOS's placeholder, ignored
        try await netflix.characteristic(.targetVisibilityState).write(.int(HAPConstants.TargetVisibilityState.hidden))
        let sourceSwitch = try #require(bridge.server.primary.service(.switch, subtype: "source-switch-com.netflix.ninja"))
        try await sourceSwitch.characteristic(.configuredName).write(.string("Netflix please"))
        let deviceID = bridge.server.deviceID
        await first.stop()

        // The TV is off at the next launch: the inputs come back from the plugin's own file, same numbers.
        await tv.set(power: "Standby")
        let second = try await environment.start(settings: ["devices": [livingRoom]])
        defer { Task { await second.stop() } }
        let again = second.bridges[1]
        #expect(again.server.deviceID == deviceID)
        let restored = try #require(again.server.primary.services.first { $0.type.uuid == ServiceType.inputSource.uuid && $0[.identifier]?.value == identifier })
        #expect(restored[.configuredName]?.value == .string("Films"))
        #expect(restored[.currentVisibilityState]?.value == .int(HAPConstants.CurrentVisibilityState.hidden))
        #expect(again.server.primary.service(.switch, subtype: "source-switch-com.netflix.ninja")?[.configuredName]?.value == .string("Netflix please"))
        let records = try JSONDecoder().decode([InputRecord].self, from: Data(contentsOf: environment.directory.appendingPathComponent("plugins/PhilipsAmbilightTV-Philips-TVs/inputs-aabbccddeeff.json")))
        #expect(records.first { $0.id == "com.netflix.ninja" }?.identifier == identifier.intValue)

        // A TV taken out of the configuration leaves.
        let third = try environment.host(settings: ["devices": []])
        #expect(third.bridges.count == 2)
        try await third.start()
        #expect(third.bridges.count == 1)
        await third.stop()
    }

    @Test func parksASelectionWhileTheTVWakes() async throws {
        let tv = environment.tv
        let host = try await environment.start(settings: ["devices": [livingRoom]])
        defer { Task { await host.stop() } }
        let bridge = host.bridges[1]
        let television = try #require(bridge.server.primary.service(.television))
        let home = try #require(bridge.server.primary.service(.inputSource, subtype: "input-8"))

        // Off: the choice is shown at once and kept for when the TV is up.
        try await television.characteristic(.activeIdentifier).write(home.characteristic(.identifier).value)
        #expect(television[.activeIdentifier]?.value == home[.identifier]?.value)
        #expect(await tv.launches.isEmpty)
        try await television.characteristic(.active).write(.int(1))
        #expect(await tv.power == "On")
        #expect(await eventually(timeout: .seconds(10)) { await tv.keys.contains("Home") })
        let page = try await environment.plugin!.handleWebRequest(.init(method: "GET", path: "tvs", user: "admin"))
        #expect(page.json["tvs"]?[0]?["on"] == true)
    }
}
