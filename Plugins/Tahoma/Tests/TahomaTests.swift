import Foundation
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftTahoma

let shutter = "io://1234-5678-9012/7654321"
let kitchenBlind = "rts://1234-5678-9012/16712345"
let heater = "io://1234-5678-9012/5551234#1"
let heaterSensor = "io://1234-5678-9012/5551234#2"

@Suite(.timeLimit(.minutes(1)))
struct TahomaConfigurationTests {
    @Test func theHomebridgeBlockDecodes() throws {
        let block = #"""
        { "platform": "Tahoma", "name": "My TaHoma Box", "service": "somfy_europe", "user": "user@example.com", "password": "...",
          "exposeScenarios": true, "exclude": ["hue", "rts", "Main door", "PositionableHorizontalAwning"],
          "devicesConfig": [ { "key": "Alarm", "stayZones": "A,C" }, { "key": "Bedroom blind", "blindMode": true },
                             { "key": "UpDownRollerShutter", "defaultPosition": 50 }, { "key": "Kitchen shutter", "lowSpeed": "22:00-07:30" } ] }
        """#
        let configuration = try JSONDecoder().decode(TahomaPlugin.Configuration.self, from: Data(block.utf8))
        #expect(configuration.service == "somfy_europe")
        #expect(configuration.exposeScenarios == .all(true))
        #expect(configuration.exclude?.count == 4)
        #expect(configuration.devicesConfig?.count == 4)
        let minimal = try JSONDecoder().decode(TahomaPlugin.Configuration.self, from: Data(#"{"platform":"Tahoma","pollingPeriod":"30"}"#.utf8))
        #expect(minimal.pollingPeriod?.value == 30)
        let named = try JSONDecoder().decode(TahomaPlugin.Configuration.self, from: Data(#"{"exposeScenarios":["Good night"]}"#.utf8))
        #expect(named.exposeScenarios?.exposes("Good night") == true)
        #expect(named.exposeScenarios?.exposes("Morning") == false)
    }

    @Test func servicesAndAliases() {
        #expect(OverkizService(configured: "TaHoma") == .somfyEurope)
        #expect(OverkizService(configured: "connexoon_rts") == .somfyAustralia)
        #expect(OverkizService(configured: "Cozytouch")?.host == "ha110-1.overkiz.com")
        #expect(OverkizService(configured: "nexity") == nil)
    }

    @Test func identitiesAndSerialNumbers() {
        let vectors = [
            ("io://1234-5678-9012/7654321", "3892b52a-cffc-5c6b-92ed-821149e1148c", "io:7654321"),
            ("io://1234-5678-9012/7654321#2", "ff55e3f0-435e-53cc-9e3f-62ca4256b764", "io:7654321#2"),
            ("rts://1234-5678-9012/16712345", "f45d05a3-b3b7-58b9-b83a-d7def5831642", "rts:16712345"),
            ("internal://1234-5678-9012/alarm/0", "ca122a11-3a3e-52f4-8ef0-9b46bfc4975f", "internal:0"),
        ]
        for (url, uuid, serial) in vectors {
            let device = OverkizDevice(json: ["deviceURL": .string(url)])!
            #expect(device.legacyUUID == uuid)
            #expect(device.serialNumber == serial)
        }
        #expect(OverkizDevice(json: ["deviceURL": "io://x/1", "oid": "0F1E2D3C-4B5A-4968-8776-5A4B3C2D1E0F"])!.legacyUUID == "0f1e2d3c-4b5a-4968-8776-5a4b3c2d1e0f")
        #expect(TahomaPlugin.accessoryID(deviceID: shutter) == "Tahoma:io://1234-5678-9012/7654321")
    }

    @Test func theRootCertificateIsOverkiz() throws {
        let body = OverkizRootCA.pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = try #require(Data(base64Encoded: body))
        #expect(HTTPClient.fingerprint(der: Array(der)) == OverkizRootCA.sha256Fingerprint)
        #expect(OverkizRootCA.sha256Fingerprint == HTTPClient.normalizeFingerprint("BB:FA:96:11:1E:AE:15:E3:C6:ED:15:F3:43:27:6C:0C:27:26:03:2E:A1:9D:F5:BB:D0:67:E2:F1:CF:FC:44:DB"))
    }

    @Test func statesAreDecodedByType() {
        let states = OverkizState.decode([
            ["name": "a", "type": 1, "value": "23247220"], ["name": "b", "type": 6, "value": "true"],
            ["name": "c", "type": 11, "value": #"{"relaunch":"off"}"#], ["name": "d", "type": 3, "value": "open"],
        ])
        #expect(states["a"] == 23247220)
        #expect(states["b"] == true)
        #expect(states["c"]?["relaunch"] == "off")
        #expect(states["d"] == "open")
    }

    @Test func exclusionsAndGrouping() throws {
        let devices = OverkizDevice.list(FakeOverkiz.setupExcerpt)
        let groups = DeviceGrouping.group(devices)
        #expect(groups.map(\.device.deviceURL) == [shutter, kitchenBlind, heater])
        #expect(groups[2].sensors.map(\.deviceURL) == [heaterSensor])
        let exclusions = DeviceGrouping.builtInExclusions.union(["rts", "Living room shutter", "HeatingSystem"])
        #expect(devices.filter { DeviceGrouping.isExcluded($0, by: exclusions) }.count == 3)
        let pod = OverkizDevice(json: ["deviceURL": "internal://1234/pod/0", "definition": ["uiClass": "Pod", "widgetName": "Pod"]])!
        #expect(DeviceGrouping.isExcluded(pod, by: DeviceGrouping.builtInExclusions))
    }

    @Test func lowSpeedWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let at = { (hour: Int) in calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour))! }
        #expect(LowSpeedRollerShutterMapper.lowSpeedApplies("22:00-07:30", at: at(23), calendar: calendar))
        #expect(LowSpeedRollerShutterMapper.lowSpeedApplies("22:00-07:30", at: at(5), calendar: calendar))
        #expect(!LowSpeedRollerShutterMapper.lowSpeedApplies("22:00-07:30", at: at(12), calendar: calendar))
        #expect(LowSpeedRollerShutterMapper.lowSpeedApplies("08:00-18:00", at: at(12), calendar: calendar))
        #expect(LowSpeedRollerShutterMapper.lowSpeedApplies(true, at: at(12), calendar: calendar))
        #expect(LowSpeedRollerShutterMapper.lowSpeedApplies("always", at: at(12), calendar: calendar))
        #expect(!LowSpeedRollerShutterMapper.lowSpeedApplies(false, at: at(12), calendar: calendar))
    }

    @Test func pilotWireSnapping() {
        let snap = { (value: Double) in PilotWireHeaterMapper.snap(value, comfort: 19, eco: 17) }
        #expect([8, 12, 13, 18, 19].map(snap) == [7, 7, 17, 19, 19])
    }

    @Test func tiltConversions() {
        #expect(VenetianBlindMapper.orientation(-90) == 0)
        #expect(VenetianBlindMapper.orientation(90) == 100)
        #expect(VenetianBlindMapper.angle(30) == -36)
        #expect(VenetianBlindMapper.orientation(0) == 50)
    }

    @Test func commandsMergeByName() {
        let merged = Executions.merge([OverkizCommand("on"), OverkizCommand("setClosure", 10)], [OverkizCommand("setClosure", 20), OverkizCommand("setIntensity", 50)])
        #expect(merged == [OverkizCommand("setClosure", 20), OverkizCommand("setIntensity", 50)])
        #expect(Executions.label(of: OverkizCommand("setClosure", 40), language: "en") == "Close 40%")
        #expect(Executions.label(of: OverkizCommand("setClosure", 40), language: "fr") == "Fermeture 40%")
        #expect(Executions.label(of: OverkizCommand("setHeatingLevel", "comfort"), language: "en") == "setHeatingLevel.comfort")
        #expect(Executions.label(of: OverkizCommand("open"), language: nil) == "open")
    }

    @Test func eventsDecode() throws {
        let events = OverkizEvent.list(try JSONValue(string: #"""
        [ { "name": "ExecutionStateChangedEvent", "execId": "e1", "oldState": "TRANSMITTED", "newState": "IN_PROGRESS", "timeToNextState": 0 },
          { "name": "DeviceStateChangedEvent", "deviceURL": "io://1234-5678-9012/7654321", "deviceStates": [ { "name": "core:ClosureState", "type": 1, "value": 40 } ] },
          { "name": "ExecutionStateChangedEvent", "execId": "e1", "newState": "FAILED", "timeToNextState": -1, "failureType": "WHILEEXEC_BLOCKED_BY_HAZARD",
            "failedCommands": [ { "deviceURL": "io://1234-5678-9012/7654321", "command": { "name": "setClosure" } } ] },
          { "name": "GatewaySynchronizationEndedEvent" } ]
        """#))
        #expect(events.count == 3)
        #expect(events[1] == .deviceStateChanged(deviceURL: shutter, states: ["core:ClosureState": 40]))
        #expect(events[2] == .executionStateChanged(execID: "e1", newState: .failed, final: true, failureType: "WHILEEXEC_BLOCKED_BY_HAZARD", failedDevices: [shutter]))
    }

    @Test func errorsAreFlattened() {
        let response = HomeswiftNetwork.HTTPResponse(status: 400, body: Data(#"{"errorCode":"EXEC_QUEUE_FULL","error":"Execution queue is full on gateway"}"#.utf8))
        let error = OverkizError(response: response)
        #expect(error.description == "Error 400 Execution queue is full on gateway(EXEC_QUEUE_FULL)")
        #expect(error.isBusy)
        #expect(OverkizError(response: HomeswiftNetwork.HTTPResponse(status: 401, body: Data(#"{"errorCode":"AUTHENTICATION_ERROR","error":"Bad credentials"}"#.utf8))).isBadCredentials)
        #expect(OverkizClient.redacted("https://x/config/1234-5678-9012/local") == "https://x/config/****-****-****/local")
    }

    @Test func canonicalSettingsMovesDeviceOptionsAndExclusions() throws {
        let devices = OverkizDevice.list(FakeOverkiz.setupExcerpt)
        let block = try JSONValue(string: #"""
        { "platform": "Tahoma", "exclude": ["rts", "Kitchen blind", "Good night"],
          "devicesConfig": [ { "key": "Living room shutter", "reverse": true, "lowSpeed": true }, { "key": "UpDownRollerShutter", "defaultPosition": 50 } ] }
        """#)
        let canonical = TahomaPlugin.canonical(block, devices: devices, scenarios: [OverkizScenario(oid: "s1", label: "Good night")])
        #expect(canonical["_accessories"]?[shutter]?["reverse"] == true)
        #expect(canonical["_accessories"]?[shutter]?["lowSpeed"] == "always")
        #expect(canonical["_accessories"]?[kitchenBlind]?["excluded"] == true)
        #expect(canonical["_accessories"]?["scene:s1"]?["excluded"] == true)
        #expect(canonical["exclude"] == ["rts"])
        #expect(canonical["devicesConfig"]?.arrayValue?.count == 1)
    }

    @Test func theSchemaIsCurrent() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config.schema.json")
        #expect(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == TahomaPlugin.configurationSchemaJSON)
        let schema = try JSONValue(string: try #require(TahomaPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "Tahoma")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct TahomaClientTests {
    func client(_ server: FakeOverkiz, endpoint: OverkizEndpoint, refused: NIOLockedBox = NIOLockedBox()) -> OverkizClient {
        OverkizClient(endpoint: endpoint, transport: .init(http: server), logger: testLogger, onAccount: { error in refused.set(error) })
    }

    @Test func signsInWithASessionAndAgainWhenItExpires() async throws {
        let server = FakeOverkiz()
        let client = client(server, endpoint: .cloud(.somfyEurope, user: "user@example.com", password: "secret"))
        _ = try await client.devices()
        let login = try #require(server.requests("/login").first)
        #expect(login.url.absoluteString == "https://ha101-1.overkiz.com/enduser-mobile-web/enduserAPI/login")
        #expect(login.form == ["userId": "user@example.com", "userPassword": "secret"])
        #expect(server.requests("/setup/devices").first?.headers["cookie"] == "JSESSIONID=ABCDEF0123456789")
        server.expireSession()
        _ = try await client.devices()
        #expect(server.requests("/login").count == 2)
        #expect(server.requests("/setup/devices").count == 3)
    }

    @Test func refusedLoginsLockTheClientOut() async throws {
        let server = FakeOverkiz()
        server.setPassword("other")
        let refused = NIOLockedBox()
        let client = client(server, endpoint: .cloud(.somfyEurope, user: "user@example.com", password: "secret"), refused: refused)
        await #expect(throws: OverkizError.self) { try await client.devices() }
        #expect(refused.value?.isBadCredentials == true)
        await #expect(throws: OverkizError.self) { try await client.devices() }
        #expect(server.requests("/login").count == 1)
    }

    @Test func serverErrorsDoNotLockOut() async throws {
        let server = FakeOverkiz()
        server.setLoginStatus(503)
        let client = client(server, endpoint: .cloud(.somfyEurope, user: "user@example.com", password: "secret"))
        await #expect(throws: OverkizError.self) { try await client.devices() }
        server.setLoginStatus(nil)
        _ = try await client.devices()
        #expect(server.requests("/login").count == 2)
    }

    @Test func cozytouchSignsInWithAtlanticsJWT() async throws {
        let server = FakeOverkiz()
        let client = client(server, endpoint: .cloud(.cozytouch, user: "user@example.com", password: "secret"))
        _ = try await client.devices()
        let token = try #require(server.requests("/token").first)
        #expect(token.headers["authorization"] == "Basic \(OverkizClient.cozytouchBasic)")
        #expect(token.form["username"] == "GA-PRIVATEPERSON/user@example.com")
        #expect(server.requests("/magellan/accounts/jwt").first?.headers["authorization"] == "Bearer atlantic-access")
        #expect(server.requests("/login").first?.form == ["jwt": "jwt-from-atlantic"])
        #expect(server.requests("/login").first?.url.host == "ha110-1.overkiz.com")
    }

    @Test func theLocalAPIUsesTheTokenAndNoModes() async throws {
        let server = FakeOverkiz()
        let client = client(server, endpoint: .local(host: "192.168.1.50", pin: nil, token: "0123456789abcdef0123"))
        _ = try await client.apply(label: "x", actions: [], highPriority: true)
        let version = try #require(server.requests("/apiVersion").first)
        #expect(version.url.absoluteString == "https://192.168.1.50:8443/enduser-mobile-web/1/enduserAPI/apiVersion")
        #expect(version.headers["authorization"] == "Bearer 0123456789abcdef0123")
        #expect(server.applies.first?.path.hasSuffix("/exec/apply") == true)
    }
}

/// A value set from a callback, read by a test.
final class NIOLockedBox: Sendable {
    private let box = NIOLockedValueBox<OverkizError?>(nil)
    var value: OverkizError? { box.withLockedValue { $0 } }
    func set(_ error: OverkizError?) { box.withLockedValue { $0 = error } }
}

import NIOConcurrencyHelpers
