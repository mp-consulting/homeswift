import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import Testing

@testable import HomeswiftUniFiAccess

/// `settings.test.ts`, `access-device-catalog.test.ts`, `access-options.test.ts`: helpers, the catalog and the configuration.
@Suite struct SettingsTests {
    @Test func identity() {
        #expect(UniFiAccessPlugin.platform == "UniFi Access")
        #expect(AccessSettings.mqttTopic == "unifi/access")
        #expect(AccessSettings.controllerRefreshInterval == .seconds(120))
        #expect(AccessSettings.controllerRetryInterval == .seconds(10))
        #expect(AccessSettings.deviceRemovalDelay == 60)
        #expect(AccessSettings.deviceUnlockInterval == 0)
        #expect(AccessSettings.revertDelay == .milliseconds(50))
        #expect(AccessSettings.tlsPinFile == "unifi-access-tls-pins.json")
    }

    @Test func normalizeMac() {
        #expect(AccessSettings.normalizeMac("aa:bb:cc:dd:ee:ff") == "AABBCCDDEEFF")
        #expect(AccessSettings.normalizeMac("AABBCCDDEEFF") == "AABBCCDDEEFF")
        #expect(AccessSettings.normalizeMac("aA:Bb:cC:Dd:eE:Ff") == "AABBCCDDEEFF")
        #expect(AccessSettings.normalizeMac("") == "")
    }

    @Test(arguments: [("AABBCCDDEEFF", true), ("aabbccddeeff-PORT1", true), ("10", false), ("AABBCCDDEEF", false), ("AA:BB:CC:DD:EE:FF", false)])
    func accessIdentifier(segment: String, expected: Bool) {
        #expect(AccessSettings.isAccessIdentifier(segment) == expected)
    }

    @Test func validAddresses() {
        for address in ["192.168.1.1", "10.0.0.1", "172.16.0.1", "unifi.local", "access.example.com", "192.168.1.1:8443", "unifi.local:443", "  192.168.1.1  "] {
            #expect(AccessSettings.isValidAddress(address), "\(address)")
        }
        for address in [
            "", "  ", "evil.com/x#", "user:pass@192.168.1.1", "192.168.1.1/api", "192.168.1.1:99999", "2130706433", "0177.0.0.1", "127.1", "localhost.",
            "foo.localhost", "localhost", "Localhost", "LOCALHOST", "127.0.0.1", "127.0.1.1", "127.255.255.255", "169.254.1.1", "169.254.0.0", "0.0.0.0", "[::1]",
            "::1", "fe80::1", "  localhost  ", "1.2.3.4.5", "256.1.1.1", "-bad.example",
        ] {
            #expect(!AccessSettings.isValidAddress(address), "\(address)")
        }
        #expect(!AccessSettings.isValidAddress(nil))
    }

    @Test func names() {
        #expect(AccessSettings.sanitizeName("Front Door") == "Front Door")
        #expect(AccessSettings.sanitizeName("  Porte d'entrée 🚪 ") == "Porte d'entrée")
        #expect(AccessSettings.sanitizeName("Hub [Main]") == "Hub Main")
        #expect(AccessSettings.sanitizeName("--Gate--") == "Gate")
        #expect(AccessSettings.firmwareRevision("v1.2.3.4567") == "1.2.3")
        #expect(AccessSettings.firmwareRevision("v4") == "4.0.0")
        #expect(AccessSettings.firmwareRevision("v1.x") == "1.0.0")
        #expect(AccessSettings.firmwareRevision("2.0") == "2.0")
    }

    @Test func catalog() {
        #expect(DeviceCatalog.modelsDps == ["UA Hub Door Mini", "UA Ultra", "UA Hub", "UA Hub Enterprise", "UA Gate"])
        #expect(DeviceCatalog.modelsRel == ["UA Hub", "UA Hub Enterprise"])
        #expect(DeviceCatalog.modelsRen == ["UA Hub", "UA Hub Enterprise"])
        #expect(DeviceCatalog.modelsRex == ["UA Hub Door Mini", "UA Ultra", "UA Hub", "UA Hub Enterprise"])
        #expect(DeviceCatalog.modelsSideDoor == ["UA Gate"])
        #expect(DeviceCatalog.modelsDefaultGarageDoor == ["UA Gate"])
        #expect(DeviceCatalog.modelsDefaultLock == ["UA Hub Door Mini", "UA Ultra", "UA Hub"])
        #expect(DeviceCatalog.entry("UGT")?.usesLocationApi == true)
        #expect(DeviceCatalog.entry("UGT")?.skipsV1LockEvents == true)
        #expect(DeviceCatalog.entry("UVC G6 Entry")?.usesConfigsApi == true)
        #expect(DeviceCatalog.entry("UA-ULTRA")?.sensors[.rex]?.proxyMode == "rex")
        #expect(DeviceCatalog.entry("nope") == nil)
        #expect(DeviceCatalog.deviceIdentifier(deviceType: "UAH", mac: "aa:bb:cc:dd:ee:ff", sourceId: "port1") == "aabbccddeeff")
        #expect(DeviceCatalog.deviceIdentifier(deviceType: "UAH-Ent", mac: "aa:bb:cc:dd:ee:ff", sourceId: "port1") == "aabbccddeeff-PORT1")
        #expect(DeviceCatalog.deviceIdentifier(deviceType: "UAH-Ent", mac: "aa:bb:cc:dd:ee:ff", sourceId: nil) == "aabbccddeeff")
    }

    @Test func device() throws {
        let device = try #require(AccessDevice(.object(uah())))
        #expect(device.config("input_state_dps") == "close")
        #expect(device.wiringActive(["wiring_state_dps-neg", "wiring_state_dps-pos"]))
        #expect(!device.wiringActive(["wiring_state_dps-neg", "missing"]))
        #expect(device.wiringActive([]))
        #expect(device.isFullyOnline)
        #expect(device.identifier == "AABBCCDDEEFF")
        #expect(AccessAPI.deviceName(device) == "Test Device [UA Hub]")
        #expect(AccessAPI.deviceName(device, deviceInfo: true) == "Test Device [UA Hub] (address: 192.168.1.100 mac: AABBCCDDEEFF)")
        let unnamed = try #require(AccessDevice(.object(deviceJSON(["alias": "", "name": .null, "display_model": .null]))))
        #expect(unnamed.resolvedName == "UAH")
    }

    @Test func telemetry() {
        let packet = AccessEventPacket(event: "access.data.device.update", eventObjectId: "x", metaId: "m", metaObjectType: "device", data: ["secret": "no"])
        #expect(packet.telemetry == #"{"event":"access.data.device.update","event_object_id":"x","meta":{"id":"m","object_type":"device"}}"#)
        #expect(AccessEventPacket(event: "e", eventObjectId: "o").telemetry == #"{"event":"e","event_object_id":"o"}"#)
    }

    /// A realistic block decodes, with Homebridge's leniency.
    @Test func configuration() throws {
        let json = """
            {
              "platform": "UniFi Access", "name": "UniFi Access", "ringDelay": "5", "debugAll": "true",
              "controllers": [
                { "address": "1.2.3.4", "username": "homebridge", "password": "pw", "name": "UDM", "mqttUrl": "mqtt://broker", "mqttTopic": "doors",
                  "mqttVerifyTls": false, "verifyTls": "true" },
                { "address": "unifi.local", "username": "u", "password": "p" },
                "not a controller"
              ],
              "options": ["Disable.Device", "Enable.Hub.LockDelayInterval.AABBCCDDEEFF.5", 3],
              "_bridge": { "username": "0E:00:00:00:00:01" }
            }
            """
        let configuration = try JSONDecoder().decode(UniFiAccessPlugin.Configuration.self, from: Data(json.utf8))
        #expect(configuration.name == "UniFi Access")
        #expect(configuration.ringDelay == 5)
        #expect(configuration.debugAll)
        #expect(configuration.controllers.count == 2)
        #expect(
            configuration.controllers[0]
                == .init(address: "1.2.3.4", username: "homebridge", password: "pw", name: "UDM", mqttUrl: "mqtt://broker", mqttTopic: "doors", mqttVerifyTls: false, verifyTls: true))
        #expect(configuration.controllers[1].verifyTls == nil)
        #expect(configuration.options == ["Disable.Device", "Enable.Hub.LockDelayInterval.AABBCCDDEEFF.5"])

        let empty = try JSONDecoder().decode(UniFiAccessPlugin.Configuration.self, from: Data(#"{"platform": "UniFi Access"}"#.utf8))
        #expect(empty.controllers.isEmpty && empty.options.isEmpty && empty.ringDelay == 0 && !empty.debugAll)
    }

    /// `debugAll` logs the debug lines at info, through a log that would drop them; the other levels are as they were.
    @Test func debugAllPromotesDebugLines() {
        let log = LogRecorder()
        var base = log.logger
        base.logLevel = .info
        let logger = DebugAllLogHandler.promoting(base)
        logger.debug("a debug line")
        logger.trace("a trace line")
        logger.warning("a warning")
        #expect(log.messages(.info) == ["a debug line"])
        #expect(log.messages(.warning) == ["a warning"])
        #expect(log.messages(.debug).isEmpty && log.messages(.trace).isEmpty)
    }

    @Test func debugAllReachesThePluginsLog() async throws {
        let environment = AccessTestEnvironment()
        let host = try await environment.start(devices: [deviceJSON()], extra: ["debugAll": true])
        #expect(environment.log.contains("Debug logging on. Expect a lot of data.", level: .info))
        await host.stop()

        let quiet = AccessTestEnvironment()
        let second = try await quiet.start(devices: [deviceJSON()])
        #expect(quiet.log.contains("Debug logging on. Expect a lot of data.", level: .debug))
        #expect(!quiet.log.contains("Debug logging on. Expect a lot of data.", level: .info))
        await second.stop()
    }

    @Test func assistantBackgroundDescribesThePort() throws {
        let background = try #require(UniFiAccessPlugin.assistantBackground)
        #expect(!background.isEmpty)
        #expect(!background.contains("Homebridge"))
        #expect(background.contains(AccessSettings.tlsPinFile))
        #expect(background.contains("Invalid login credentials given") && background.contains("Throttling API calls"))
    }

    /// The schema is the Homebridge plugin's and is embedded as written.
    @Test func schema() throws {
        let file = try String(contentsOf: Self.pluginDirectory.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(UniFiAccessPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines))
        let schema = try JSONValue(string: file)
        #expect(schema["pluginAlias"] == "UniFi Access")
        #expect(schema["schema"]?["properties"]?["controllers"]?["items"]?["properties"]?["verifyTls"] != nil)
    }

    /// `Web/` is embedded as it is on disk: `swift Scripts/embed-assets.swift web Plugins/UniFiAccess/Web Plugins/UniFiAccess/Sources/WebFiles.swift UniFiAccessPlugin`.
    @Test func webFilesAreCurrent() throws {
        let directory = Self.pluginDirectory.appendingPathComponent("Web")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
        #expect(names == UniFiAccessPlugin.webFiles.keys.sorted())
        for name in names {
            let content = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(UniFiAccessPlugin.webFiles[name]?.body == content, "\(name) is stale: run the embed script")
        }
    }

    static let pluginDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test func discoveryAnswers() {
        // Header, MAC+IP, hostname, short model, firmware.
        var packet: [UInt8] = [0x01, 0x00, 0x00, 0x30]
        packet += [0x02, 0x00, 0x0A, 0xAA, 0xBB, 0xCC, 0x01, 0x02, 0x03, 192, 168, 1, 1]
        packet += [0x0B, 0x00, 0x03] + Array("udm".utf8)
        packet += [0x0C, 0x00, 0x04] + Array("UDMP".utf8)
        packet += [0x03, 0x00, 0x05] + Array("4.0.6".utf8)
        packet += [0x14, 0x00, 0x09] + Array("UDM Pro X".utf8)
        let console = UbiquitiDiscovery.parse(packet)
        #expect(console == DiscoveredConsole(ip: "192.168.1.1", mac: "aa:bb:cc:01:02:03", name: "udm", model: "UDMP", modelLong: "UDM Pro X", firmware: "4.0.6"))
        #expect(UbiquitiDiscovery.parse([0x01, 0x00, 0x00]) == nil)
        #expect(UbiquitiDiscovery.parse([0x01, 0x00, 0x00, 0x00, 0x0B, 0x00, 0x03] + Array("udm".utf8)) == nil)
        // Truncated field: parsing stops.
        #expect(UbiquitiDiscovery.parse([0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x0A, 0x01]) == nil)

        let network = { (address: String, netmask: String) in IPv4Network(address: IPv4Network.parse(address)!, netmask: IPv4Network.parse(netmask)!) }
        let targets = UbiquitiDiscovery.targets(interfaces: [network("192.168.1.20", "255.255.255.0"), network("10.0.0.5", "255.0.0.0")])
        #expect(targets.broadcasts == ["255.255.255.255", "192.168.1.255", "10.255.255.255"])
        // The subnets around 192.168.1.0/24 that exist (0 and 2 to 6); the /8 interface only gets its broadcast.
        #expect(targets.unicast.count == 6 * 254)
        #expect(targets.unicast.contains("192.168.6.254") && targets.unicast.contains("192.168.0.1") && !targets.unicast.contains("192.168.1.5"))
    }

    @Test func brokerRedaction() {
        #expect(AccessMQTT.redact("mqtt://user:pass@1.2.3.4") == "mqtt://REDACTED@1.2.3.4")
        // As the TypeScript expression reads it, a leading `user:` is a scheme.
        #expect(AccessMQTT.redact("user:p@ss@1.2.3.4") == "user:REDACTED@1.2.3.4")
        #expect(AccessMQTT.redact("p@ss@1.2.3.4") == "REDACTED@1.2.3.4")
        #expect(AccessMQTT.redact("mqtt://1.2.3.4") == "mqtt://1.2.3.4")
    }

    @Test func pinStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unifi-pins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(AccessSettings.tlsPinFile)
        let store = TLSPinStore(url: url, logger: testLogger)
        #expect(store.pin(for: "10.0.0.1") == nil)
        store.set(String(repeating: "ab", count: 32), for: " 10.0.0.1 ")
        store.set("not a fingerprint", for: "10.0.0.2")
        let expected = Array(repeating: "AB", count: 32).joined(separator: ":")
        #expect(TLSPinStore(url: url, logger: testLogger).pin(for: "10.0.0.1") == expected)
        #expect(store.pin(for: "10.0.0.2") == nil)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
        #expect(saved == ["10.0.0.1": expected])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(colonFingerprint("ab:" + String(repeating: "cd", count: 31)) == "AB:" + Array(repeating: "CD", count: 31).joined(separator: ":"))
        #expect(colonFingerprint("abc") == nil)
    }
}

/// MQTT on `HomeswiftNetwork`'s client, against nothing listening.
@Suite(.timeLimit(.minutes(1)))
struct MQTTClientTests {
    @Test func reportsFailuresAndRetries() async throws {
        let log = LogRecorder()
        let mqtt = AccessMQTT(brokerURL: "mqtt://user:pw@127.0.0.1:1", topicPrefix: "unifi/access", verifyTLS: true, connector: { MQTTClient($0) }, logger: log.logger, prefix: "UDM: ")
        await mqtt.start()
        let failures: @Sendable () -> Int = { log.messages(.error).filter { $0.hasPrefix("UDM: MQTT Broker: ") && $0.hasSuffix("Will retry again in 60 seconds.") }.count }
        #expect(await eventually { failures() >= 2 })
        // Publishing while disconnected is dropped, not thrown.
        await mqtt.publish("x", "lock", "true")
        await mqtt.subscribe("x", "lock/set") { _ in }
        await mqtt.end()
    }

    @Test func refusesOtherSchemes() async {
        let log = LogRecorder()
        let mqtt = AccessMQTT(brokerURL: "http://broker", topicPrefix: "unifi/access", verifyTLS: true, connector: { MQTTClient($0) }, logger: log.logger, prefix: "")
        await mqtt.start()
        #expect(log.contains("MQTT Broker: Unsupported protocol: http:.", level: .error))
    }
}
