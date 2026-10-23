import Foundation
import HomeswiftPlugin
import Testing

@testable import HomeswiftDaikinCloud

/// The Homebridge plugin's ConfigManager tests, and the block users have today.
@Suite struct ConfigurationTests {
    let developerPortal: [String: JSONValue] = [
        "platform": "DaikinCloud", "authMode": "developer_portal", "clientId": "test-id", "clientSecret": "test-secret",
        "callbackServerExternalAddress": "192.168.1.100", "callbackServerPort": 8582,
    ]
    let mobileApp: [String: JSONValue] = ["platform": "DaikinCloud", "authMode": "mobile_app", "daikinEmail": "test@example.com", "daikinPassword": "password123"]

    func merged(_ base: [String: JSONValue], _ changes: [String: JSONValue]) -> [String: JSONValue] { base.merging(changes) { $1 } }

    @Test func decodesAFullHomebridgeBlock() throws {
        let json = """
            {
              "platform": "DaikinCloud", "name": "Daikin Cloud", "authMode": "mobile_app",
              "daikinEmail": "me@example.com", "daikinPassword": "secret",
              "clientId": "id", "clientSecret": "secret", "callbackServerExternalAddress": "192.168.1.100", "callbackServerPort": "8583",
              "oidcCallbackServerBindAddr": "0.0.0.0", "showExtraFeatures": true, "showPowerfulMode": false, "showEconoMode": null,
              "showStreamerMode": true, "showOutdoorSilentMode": true, "showIndoorSilentMode": true, "showAutoFanMode": true, "showDryMode": true,
              "showFanOnlyMode": true, "showOscillationSwitch": true, "showSeparateFanControl": true, "showHolidayMode": true,
              "showFirmwareUpdateSwitch": false, "httpTransport": "curl", "excludedDevicesByDeviceId": ["abc", "def"],
              "updateIntervalInMinutes": "5", "forceUpdateDelay": 10000, "enableWebSocket": false,
              "_bridge": { "username": "0E:1A:2B:3C:4D:5F" }
            }
            """
        let configuration = try JSONDecoder().decode(DaikinCloudPlugin.Configuration.self, from: Data(json.utf8))
        let settings = DaikinSettings(configuration)
        #expect(settings.name == "Daikin Cloud")
        #expect(settings.authMode == .mobileApp)
        #expect(settings.mobileCredentials?.email == "me@example.com")
        #expect(settings.callbackServerPort == 8583)
        #expect(settings.callbackBindAddress == "0.0.0.0")
        #expect(settings.httpTransport == .curl)
        #expect(settings.excludedDeviceIDs == ["abc", "def"])
        #expect(settings.updateInterval == 5 * 60_000)
        #expect(settings.forceUpdateDelay == 10_000)
        #expect(!settings.webSocketEnabled)
        #expect(!settings.isEnabled(.showPowerfulMode))
        #expect(settings.isEnabled(.showEconoMode))  // null follows showExtraFeatures
        #expect(settings.isEnabled(.showSeparateFanControl))
        #expect(!settings.isEnabled(.showFirmwareUpdateSwitch))
        #expect(DaikinSettings.validate(configuration.raw).valid)
        // Anything decodes: a block the plugin cannot use is reported, not refused.
        _ = try JSONDecoder().decode(DaikinCloudPlugin.Configuration.self, from: Data(#"{"platform":"DaikinCloud","excludedDevicesByDeviceId":"d"}"#.utf8))
    }

    @Test func authModeAndCredentials() {
        #expect(settings(["authMode": "mobile_app"]).authMode == .mobileApp)
        #expect(settings([:]).authMode == .developerPortal)
        #expect(settings(["authMode": "bogus"]).authMode == .developerPortal)
        #expect(settings(["clientId": "id", "clientSecret": "secret"]).hasDeveloperCredentials)
        #expect(!settings(["clientId": "id"]).hasDeveloperCredentials)
        #expect(!settings(["clientId": "", "clientSecret": "secret"]).hasDeveloperCredentials)
        #expect(settings(mobileApp).mobileCredentials! == ("test@example.com", "password123"))
        #expect(settings(["daikinEmail": "test@example.com"]).mobileCredentials == nil)
        // The legacy keys older READMEs documented.
        let legacy: [String: JSONValue] = ["email": "legacy@example.com", "password": "legacy-password"]
        #expect(settings(legacy).mobileCredentials! == ("legacy@example.com", "legacy-password"))
        #expect(DaikinSettings.legacyCredentialKeys(legacy) == ["email", "password"])
        let both = merged(legacy, ["daikinEmail": "canonical@example.com", "daikinPassword": "canonical-password"])
        #expect(settings(both).mobileCredentials! == ("canonical@example.com", "canonical-password"))
        #expect(DaikinSettings.legacyCredentialKeys(both).isEmpty)
    }

    @Test func callbackDefaults() {
        let developer = settings(merged(developerPortal, ["callbackServerPort": 9000, "oidcCallbackServerBindAddr": "127.0.0.1"]))
        #expect(developer.clientID == "test-id")
        #expect(developer.callbackServerExternalAddress == "192.168.1.100")
        #expect(developer.callbackServerPort == 9000)
        #expect(developer.callbackBindAddress == "127.0.0.1")
        #expect(settings(["clientId": "id"]).callbackServerPort == 8582)
        #expect(settings(["clientId": "id"]).callbackBindAddress == "0.0.0.0")
        for (port, expected) in [(JSONValue.string("9000"), 9000), (.number(99999), 8582), (.string("abc"), 8582), (.string(""), 8582)] {
            #expect(settings(["callbackServerPort": port]).callbackServerPort == expected)
        }
    }

    @Test func validation() {
        #expect(DaikinSettings.validate(developerPortal) == .init())
        #expect(DaikinSettings.validate(["authMode": "developer_portal"]).errors == [
            "Client ID is required for Developer Portal mode", "Client Secret is required for Developer Portal mode",
            "Callback Server Address is required for Developer Portal mode",
        ])
        for address in ["localhost", "127.0.0.1"] {
            #expect(DaikinSettings.validate(merged(developerPortal, ["callbackServerExternalAddress": .string(address)])).errors == [
                "Callback address cannot be localhost. Use your external IP or domain.",
            ])
        }
        for port: JSONValue in [99999, 0, "abc", 1.5] {
            let result = DaikinSettings.validate(merged(developerPortal, ["callbackServerPort": port]))
            #expect(!result.valid)
            #expect(result.errors.contains { $0.contains("port") })
        }
        #expect(DaikinSettings.validate(merged(developerPortal, ["callbackServerPort": "8582"])).valid)
        #expect(DaikinSettings.validate(merged(developerPortal, ["callbackServerPort": ""])).valid)
        #expect(DaikinSettings.validate(merged(developerPortal, ["callbackServerPort": .null])).valid)
        let privileged = DaikinSettings.validate(merged(developerPortal, ["callbackServerPort": 443]))
        #expect(privileged.valid)
        #expect(privileged.warnings.contains("Port 443 is privileged (< 1024) and may require root permissions."))
        #expect(DaikinSettings.validate(mobileApp) == .init())
        #expect(DaikinSettings.validate(["authMode": "mobile_app"]).errors == [
            "Email is required for Mobile App mode (config key: \"daikinEmail\")", "Password is required for Mobile App mode (config key: \"daikinPassword\")",
        ])
        let legacy = DaikinSettings.validate(["authMode": "mobile_app", "email": "legacy@example.com", "password": "legacy-password"])
        #expect(legacy.valid)
        #expect(legacy.warnings.contains { $0.contains("daikinEmail") })
        let developerInterval = DaikinSettings.validate(merged(developerPortal, ["updateIntervalInMinutes": 5]))
        #expect(developerInterval.valid)
        #expect(developerInterval.warnings.contains { $0.contains("rate limit") })
        #expect(DaikinSettings.validate(merged(mobileApp, ["updateIntervalInMinutes": 5])).warnings.isEmpty)
        let clamped = DaikinSettings.validate(merged(mobileApp, ["updateIntervalInMinutes": 120, "forceUpdateDelay": 1000]))
        #expect(clamped.valid)
        #expect(clamped.warnings.count == 2)
        #expect(clamped.warnings[0].contains("Using 60 minutes"))
        #expect(clamped.warnings[1].contains("Using 5000 ms"))
    }

    @Test func intervals() {
        let minutes: [(JSONValue?, Double)] = [(nil, 15), (0, 15), ("abc", 15), (30, 30), ("5", 5), (0.5, 1), (-5, 1), (120, 60)]
        for (value, expected) in minutes {
            #expect(settings(value.map { ["updateIntervalInMinutes": $0] } ?? [:]).updateInterval == expected * 60_000)
        }
        let delays: [(JSONValue?, Double)] = [(nil, 60_000), (0, 60_000), (10000, 10000), ("20000", 20000), (1000, 5000), (600_000, 300_000)]
        for (value, expected) in delays {
            #expect(settings(value.map { ["forceUpdateDelay": $0] } ?? [:]).forceUpdateDelay == expected)
        }
    }

    @Test func exclusionsWebSocketAndTransport() {
        let excluded = settings(["excludedDevicesByDeviceId": ["device1", "device2"]])
        #expect(excluded.isExcluded("device1"))
        #expect(!excluded.isExcluded("device3"))
        #expect(!settings([:]).isExcluded("device1"))
        // A string is not a list: its characters are not ids.
        #expect(!settings(["excludedDevicesByDeviceId": "d"]).isExcluded("d"))
        #expect(settings([:]).webSocketEnabled)
        #expect(settings(["enableWebSocket": true]).webSocketEnabled)
        #expect(!settings(["enableWebSocket": false]).webSocketEnabled)
        #expect(settings(["name": "Daikin", "httpTransport": "curl"]).name == "Daikin")
        #expect(settings(["httpTransport": "curl"]).httpTransport == .curl)
        #expect(settings(["httpTransport": "bogus"]).httpTransport == nil)
        #expect(DaikinHTTP.transport(for: .curl, environment: [:]) == .curl)
        #expect(DaikinHTTP.transport(for: nil, environment: [:]) == .node)
        #expect(DaikinHTTP.transport(for: .node, environment: ["DAIKIN_HTTP_TRANSPORT": "curl"]) == .curl)
    }

    @Test func redactedBlockHidesSecrets() {
        let raw = merged(developerPortal, ["daikinPassword": "secret-password", "excludedDevicesByDeviceId": ["0123456789abcdef"]])
        let text = DaikinSettings.redacted(raw, excluded: settings(raw).excludedDeviceIDs).text()
        #expect(!text.contains("test-secret"))
        #expect(!text.contains("secret-password"))
        #expect(!text.contains("0123456789abcdef"))
        #expect(text.contains("192.168.1.100"))
        #expect(DaikinSettings.mask("0123456789abcdef") == "012******def")
        #expect(DaikinSettings.mask("short") == "******")
    }

    @Test func featureToggles() {
        let values: [JSONValue?] = [nil, .null, true, false]
        for key in FeatureKey.extra {
            for value in values {
                for legacy in [true, false] {
                    var raw: [String: JSONValue] = ["showExtraFeatures": .bool(legacy)]
                    if let value { raw[key.rawValue] = value }
                    #expect(settings(raw).isEnabled(key) == (value?.boolValue ?? legacy), "\(key) \(String(describing: value)) legacy \(legacy)")
                }
            }
        }
        for key in FeatureKey.standalone {
            for value in values {
                for legacy in [true, false] {
                    var raw: [String: JSONValue] = ["showExtraFeatures": .bool(legacy)]
                    if let value { raw[key.rawValue] = value }
                    #expect(settings(raw).isEnabled(key) == (value == .bool(true)))
                }
            }
        }
        #expect(settings(["showExtraFeatures": true, "showPowerfulMode": "false"]).isEnabled(.showPowerfulMode))
        #expect(!settings(["showSeparateFanControl": "true"]).isEnabled(.showSeparateFanControl))
        for key in FeatureKey.allCases { #expect(!settings([:]).isEnabled(key)) }
    }

    /// The feature keys, the schema and the page agree (the Homebridge plugin's feature-config-keys test).
    @Test func featureKeysMatchTheSchemaAndThePage() throws {
        #expect(Set(FeatureKey.extra + FeatureKey.standalone).count == FeatureKey.allCases.count)
        let schema = try JSONValue(string: DaikinCloudPlugin.configurationSchemaJSON!)
        let shown = Set((schema["schema"]?["properties"]?.objectValue ?? [:]).keys.filter { $0.hasPrefix("show") && $0 != "showExtraFeatures" })
        #expect(shown == Set(FeatureKey.allCases.map(\.rawValue)))
        // No default on an extra feature: absent means "follow showExtraFeatures".
        for key in FeatureKey.extra { #expect(schema["schema"]?["properties"]?[key.rawValue]?["default"] == nil) }
        let page = try #require(DaikinCloudPlugin.webFiles["app.js"]?.body)
        for key in FeatureKey.extra { #expect(page.contains("\"\(key.rawValue)\""), "\(key) missing from the page") }
        #expect(page.contains(#"const STANDALONE_KEYS = ["showSeparateFanControl", "showFirmwareUpdateSwitch"]"#))
    }
}

/// Generated files are current: the page and the schema the binary serves are the ones in the directory.
@Suite struct EmbeddingTests {
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(DaikinCloudPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines), "run: swift Scripts/embed-assets.swift plugin Plugins/DaikinCloud DaikinCloudPlugin")
        #expect(try JSONValue(string: DaikinCloudPlugin.configurationSchemaJSON!)["pluginAlias"] == "DaikinCloud")
    }

    @Test func webFilesAreCurrent() throws {
        let web = Self.root.appendingPathComponent("Web")
        for name in try FileManager.default.contentsOfDirectory(atPath: web.path) where !name.hasPrefix(".") {
            let file = try String(contentsOf: web.appendingPathComponent(name), encoding: .utf8)
            #expect(DaikinCloudPlugin.webFiles[name]?.body == file, "run: swift Scripts/embed-assets.swift web Plugins/DaikinCloud/Web Plugins/DaikinCloud/Sources/WebFiles.swift DaikinCloudPlugin (\(name))")
        }
        #expect(DaikinCloudPlugin.webFiles["index.html"]?.contentType == "text/html; charset=utf-8")
    }
}
