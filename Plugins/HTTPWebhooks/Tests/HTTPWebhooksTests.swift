import Crypto
import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftHTTPWebhooks

/// The specification's requests (docs/clean-room/HTTPWebhooks.md, 8.2) against the example block, with the differences
/// the README lists: readbacks answer the values after the call, as numbers.
@Suite(.timeLimit(.minutes(1)))
struct HTTPWebhooksTests {
    let environment = TestEnvironment()

    // MARK: Configuration and identity

    @Test func aMinimalBlockDecodesWithTheDefaults() throws {
        let configuration = try JSONDecoder().decode(HTTPWebhooksPlugin.Configuration.self, from: Data(#"{"platform":"HttpWebHooks"}"#.utf8))
        #expect(configuration.port == 51828)
        #expect(configuration.host == "0.0.0.0")
        #expect(configuration.credentials == nil)
        #expect(!configuration.https)
        #expect(!configuration.enableCORS)
    }

    @Test func optionsAreReadAsTheHomebridgePluginReadsThem() throws {
        func decode(_ json: String) throws -> HTTPWebhooksPlugin.Configuration {
            try JSONDecoder().decode(HTTPWebhooksPlugin.Configuration.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"webhook_port":"8080"}"#).port == 8080)
        #expect(try decode(#"{"webhook_port":9090}"#).port == 9090)
        #expect(try decode(#"{"webhook_port":""}"#).port == 51828)
        // HTTPS needs the boolean, and authentication both values.
        #expect(try !decode(#"{"https":"true"}"#).https)
        #expect(try decode(#"{"https":true}"#).https)
        #expect(try decode(#"{"http_auth_user":"a"}"#).credentials == nil)
        #expect(try decode(#"{"webhook_listen_host":"::"}"#).host == "::")
        // rejectUnauthorized: on when absent, and only `true` keeps it on.
        #expect(HTTPWebhooksPlugin.Entry(json: ["id": "a"]).rejectUnauthorized)
        #expect(HTTPWebhooksPlugin.Entry(json: ["rejectUnauthorized": true]).rejectUnauthorized)
        #expect(!HTTPWebhooksPlugin.Entry(json: ["rejectUnauthorized": "true"]).rejectUnauthorized)
        #expect(!HTTPWebhooksPlugin.Entry(json: ["rejectUnauthorized": false]).rejectUnauthorized)
    }

    /// HAP-NodeJS's `uuid.generate`: the SHA-1 of the seed in hex, laid into `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` one
    /// digit per `x`, the `y` with the variant bits 10 (the `4` takes no digit).
    static func homebridgeUUID(_ seed: String) -> String {
        var digits = Insecure.SHA1.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined().makeIterator()
        return String("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".map { character -> Character in
            switch character {
            case "x": digits.next()!
            case "y": Character(String((Int(String(digits.next()!), radix: 16)! & 0x3) | 0x8, radix: 16))
            default: character
            }
        }).uppercased()
    }

    @Test func idsAreHomebridgesSeeds() async throws {
        let host = try await environment.start()
        let switchAccessory = try host.accessory(named: "Switch name 1")
        #expect(switchAccessory.id == "HttpWebHooks:Switch name 1")
        // The specification's vectors: the id is the seed Homebridge derived the accessory's UUID from.
        #expect(Self.homebridgeUUID(switchAccessory.id) == "18FAC0D0-4B38-4C83-A34A-31826F39AF3B")
        #expect(Self.homebridgeUUID(HTTPWebhooksPlugin.accessoryID(name: "Motion Sensor name 2")) == "45B216E6-1783-40A6-A40D-8D5AD9C6A923")
        #expect(switchAccessory.information.characteristic(.serialNumber).value == "HttpWebHookSwitchAccessory-switch1")
        #expect(switchAccessory.information.characteristic(.model).value == "HttpWebHookSwitchAccessory-Switch name 1")
        #expect(switchAccessory.information.characteristic(.manufacturer).value == "HttpWebHooksPlatform")
        #expect(try host.accessory(named: "Doorbell").information.characteristic(.serialNumber).value == "db1")
        #expect(try host.accessory(named: "Desk Lamp").information.characteristic(.model).value == "HttpWebHookLightAccessory-Desk Lamp")
        await host.stop()
    }

    @Test func everyKindHasItsServices() async throws {
        let host = try await environment.start()
        #expect(host.mainBridge.server.accessories.filter { $0.id.hasPrefix("HttpWebHooks:") }.count == 17)
        let doorbell = try host.accessory(named: "Doorbell")
        for subtype in ["sps", "db"] {
            let service = try #require(doorbell.services.first { $0.subtype == subtype })
            #expect(service.characteristic(.programmableSwitchEvent).type.validValues == [0])
        }
        let remote = try host.accessory(named: "Remote")
        let up = try #require(remote.services.first { $0.subtype == "0" })
        let down = try #require(remote.services.first { $0.subtype == "1" })
        #expect(up.characteristic(.name).value == "Up")
        #expect(up.characteristic(.serviceLabelIndex).value == .int(1))
        #expect(up.characteristic(.programmableSwitchEvent).type.validValues == [0, 1, 2])
        #expect(down.characteristic(.serviceLabelIndex).value == .int(2))
        #expect(down.characteristic(.programmableSwitchEvent).type.validValues == [0, 1])
        let thermostat = try #require(try host.accessory(named: "Living Thermostat").service(.thermostat))
        #expect(thermostat.characteristic(.targetTemperature).type.minValue == 15)
        #expect(thermostat.characteristic(.targetTemperature).type.maxValue == 30)
        #expect(thermostat.characteristic(.targetTemperature).type.minStep == 0.5)
        #expect(try host.accessory(named: "Attic Temperature").service(.temperatureSensor)?.characteristic(.currentTemperature).type.minValue == -100)
        #expect(try host.accessory(named: "Garden Tap").service(.valve)?.characteristic(.valveType).value == .int(1))
        #expect(try host.accessory(named: "Ceiling Fan").service(.fanv2)?[.swingMode] == nil)
        await host.stop()
    }

    @Test func entriesWithoutAnIdentityOrAKnownTypeAreLeftOut() async throws {
        let host = try await environment.start(settings: [
            "sensors": [["id": "x", "name": "Odd", "type": "radiation"], ["id": "y", "name": "Twin", "type": "motion"]],
            "switches": [["id": "z", "name": "Twin"], ["name": "No id"], ["id": 5, "name": "Number id"]],
        ])
        let ids = host.mainBridge.server.accessories.map(\.id).filter { $0.hasPrefix("HttpWebHooks:") }
        // An `id` that is a number makes an accessory HomeKit drives, which no webhook reaches.
        #expect(ids == ["HttpWebHooks:Twin", "HttpWebHooks:Number id"])
        #expect(try await environment.call("/?accessoryId=5").status == 404)
        await host.stop()
    }

    // MARK: The server's answers

    @Test func requestsNeedTheCredentialsAndAnAccessory() async throws {
        let host = try await environment.start()
        // 1
        let unauthorized = try await environment.call("/?accessoryId=switch1", authorization: nil)
        #expect(unauthorized.status == 401)
        #expect(unauthorized.headers["WWW-Authenticate"] == #"Basic realm="Auth required""#)
        let wrong = try await environment.call("/?accessoryId=switch1", authorization: "Basic " + Data("hook:nope".utf8).base64EncodedString())
        #expect(wrong.status == 401)
        // 2, 3
        #expect(try await environment.call("/") == WebhookHTTPResponse(status: 404, contentType: "text/plain", body: "[ERROR Http WebHook Server] No accessoryId in request."))
        #expect(try await environment.call("/?accessoryId=nope").body == "[ERROR Http WebHook Server] AccessoryId 'nope' not found.")
        await host.stop()
    }

    @Test func switchWebhooksAndHomeKitWrites() async throws {
        let host = try await environment.start()
        let on = try #require(try host.accessory(named: "Switch name 1").service(.switch)?[.on])
        #expect(try await environment.call("/?accessoryId=switch1").body == #"{"success":true,"state":false}"#)   // 4
        #expect(try await environment.call("/whatever?accessoryId=switch1&state=true", method: "POST").body == #"{"success":true}"#)   // 5
        #expect(on.value == .bool(true))
        #expect(await environment.http.requests.isEmpty)
        #expect(try await environment.call("/?accessoryId=switch1").body == #"{"success":true,"state":true}"#)   // 6
        _ = try await environment.call("/?accessoryId=switch1&state=TRUE")   // 7
        #expect(on.value == .bool(false))
        try await on.write(.bool(true))   // 8
        #expect(await environment.http.urls == ["http://10.0.0.5/relay?on=1"])
        #expect(try await environment.call("/?accessoryId=switch1").body == #"{"success":true,"state":true}"#)
        await environment.http.answer("http://10.0.0.5/relay?on=0", status: 500)
        await #expect(throws: HAPStatusError.self) { try await on.write(.bool(false)) }
        // A failed call changes nothing.
        #expect(on.value == .bool(true))
        #expect(try await environment.call("/?accessoryId=switch1").body == #"{"success":true,"state":true}"#)
        await host.stop()
    }

    @Test func sensors() async throws {
        let host = try await environment.start()
        let motion = try #require(try host.accessory(named: "Hall Motion").service(.motionSensor)?[.motionDetected])
        #expect(try await environment.call("/?accessoryId=motion1&state=true").body == #"{"success":true}"#)   // 9
        #expect(motion.value == .bool(true))
        #expect(await eventually { motion.value == .bool(false) })
        #expect(try await environment.json("/?accessoryId=motion1") == ["success": true, "state": false])

        _ = try await environment.call("/?accessoryId=temp1&value=21.5")   // 10
        #expect(try await environment.call("/?accessoryId=temp1").body == #"{"success":true,"state":21.5}"#)
        #expect(try host.accessory(named: "Attic Temperature").service(.temperatureSensor)?[.currentTemperature]?.value == .double(21.5))
        // Not a number: ignored.
        _ = try await environment.call("/?accessoryId=temp1&value=warm")
        #expect(try await environment.json("/?accessoryId=temp1")["state"] == 21.5)

        _ = try await environment.call("/?accessoryId=door1&state=false")   // 11
        #expect(try host.accessory(named: "Front Door").service(.contactSensor)?[.contactSensorState]?.value == .int(1))
        await host.stop()
    }

    @Test func aNewTriggerRestartsTheAutoRelease() async throws {
        var settings = exampleBlock
        // A release 2 s after a trigger (at the tests' hundredth): room enough for a loaded runner between the steps.
        settings["sensors"] = [["id": "motion1", "name": "Hall Motion", "type": "motion", "autoRelease": true, "autoReleaseTime": 200_000]]
        let host = try await environment.start(settings: settings)
        let motion = try #require(try host.accessory(named: "Hall Motion").service(.motionSensor)?[.motionDetected])
        let first = ContinuousClock.now
        _ = try await environment.call("/?accessoryId=motion1&state=true")
        try await Task.sleep(until: first + .milliseconds(1200))
        _ = try await environment.call("/?accessoryId=motion1&state=true")
        // Past the first trigger's release (2 s), before the second one's (3.2 s): still detected.
        try await Task.sleep(until: first + .milliseconds(2600))
        #expect(motion.value == .bool(true))
        #expect(await eventually { motion.value == .bool(false) })
        await host.stop()
    }

    @Test func pushButton() async throws {
        let host = try await environment.start()
        let on = try #require(try host.accessory(named: "Gate Button").service(.switch)?[.on])
        #expect(try await environment.call("/?accessoryId=bell&state=true").body == #"{"success":true}"#)   // 12
        #expect(on.value == .bool(true))
        #expect(await eventually { on.value == .bool(false) })
        #expect(await environment.http.requests.isEmpty)
        try await on.write(.bool(true))
        let request = try #require(await environment.http.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://10.0.0.6/pulse")
        #expect(request.body == Data(#"{"pulse":true}"#.utf8))
        #expect(request.header("Content-Type") == "application/json")
        #expect(await eventually { on.value == .bool(false) })
        await host.stop()
    }

    @Test func doorbell() async throws {
        let host = try await environment.start()
        let doorbell = try host.accessory(named: "Doorbell")
        let event = try #require(doorbell.service(.doorbell)?[.programmableSwitchEvent])
        let changes = NIOLockedValueBox<[HAPValue]>([])
        event.observe { change in changes.withLockedValue { $0.append(change.newValue) } }
        #expect(try await environment.call("/?accessoryId=db1&event=0").body == #"{"success":true}"#)   // 13
        #expect(changes.withLockedValue { $0 } == [.int(0)])
        #expect(try await environment.call("/?accessoryId=db1&event=1").body == #"{"error":"event value 1 is outside of valid values: 0"}"#)   // 14
        #expect(changes.withLockedValue { $0 } == [.int(0)])
        await host.stop()
    }

    @Test func light() async throws {
        let host = try await environment.start()
        let service = try #require(try host.accessory(named: "Desk Lamp").service(.lightbulb))
        _ = try await environment.call("/?accessoryId=light1&state=true&value=255")   // 15
        #expect(service[.on]?.value == .bool(true))
        #expect(service[.brightness]?.value == .int(100))
        #expect(try await environment.call("/?accessoryId=light1").body == #"{"success":true,"brightness":255,"state":true}"#)   // 16
        try await service.characteristic(.brightness).write(.int(50))   // 17
        #expect(await environment.http.urls == ["http://10.0.0.7/set?on=true&bri=128"])
        #expect(try await environment.json("/?accessoryId=light1") == ["success": true, "brightness": 128, "state": true])
        // `value` alone does not turn the light on.
        _ = try await environment.call("/?accessoryId=light1&state=false")
        _ = try await environment.call("/?accessoryId=light1&value=51")
        #expect(service[.on]?.value == .bool(false))
        #expect(service[.brightness]?.value == .int(20))
        await host.stop()
    }

    @Test func thermostat() async throws {
        let host = try await environment.start()
        let service = try #require(try host.accessory(named: "Living Thermostat").service(.thermostat))
        #expect(try await environment.call("/?accessoryId=th1&currenttemperature=19.5&targetstate=1").body == #"{"success":true}"#)   // 18
        #expect(service[.currentTemperature]?.value == .double(19.5))
        #expect(service[.targetHeatingCoolingState]?.value == .int(1))
        try await service.characteristic(.targetTemperature).write(.double(21.5))   // 19
        try await service.characteristic(.targetHeatingCoolingState).write(.int(2))
        #expect(await environment.http.urls == ["http://10.0.0.8/t?target=21.5", "http://10.0.0.8/m?mode=2"])
        await host.stop()
    }

    @Test func outlet() async throws {
        let host = try await environment.start()
        _ = try await environment.call("/?accessoryId=out1&stateOutletInUse=true")   // 20
        #expect(try await environment.call("/?accessoryId=out1").body == #"{"success":true,"state":false,"stateOutletInUse":true}"#)
        #expect(try host.accessory(named: "Kettle").service(.outlet)?[.outletInUse]?.value == .bool(true))
        await host.stop()
    }

    @Test func securitySystem() async throws {
        let host = try await environment.start()
        let service = try #require(try host.accessory(named: "Alarm").service(.securitySystem))
        #expect(try await environment.call("/?accessoryId=alarm").body == #"{"success":true,"currentState":3,"targetState":3}"#)   // 21
        try await service.characteristic(.securitySystemTargetState).write(.int(1))   // 22
        #expect(await environment.http.urls == ["http://10.0.0.9/mode/1"])
        #expect(service[.securitySystemCurrentState]?.value == .int(1))
        #expect(try await environment.json("/?accessoryId=alarm") == ["success": true, "currentState": 1, "targetState": 1])
        _ = try await environment.call("/?accessoryId=alarm&currentstate=4")
        #expect(service[.securitySystemCurrentState]?.value == .int(4))
        await host.stop()
    }

    @Test func garageDoor() async throws {
        let host = try await environment.start()
        let service = try #require(try host.accessory(named: "Garage").service(.garageDoorOpener))
        // 23–25, with the values after the call.
        #expect(try await environment.call("/?accessoryId=garage&currentdoorstate=0").body == #"{"success":true,"currentState":0,"targetState":1,"obstruction":false}"#)
        #expect(service[.currentDoorState]?.value == .int(0))
        _ = try await environment.call("/?accessoryId=garage&currentdoorstate=1&obstructiondetected=1")
        #expect(service[.currentDoorState]?.value == .int(1))
        #expect(service[.obstructionDetected]?.value == .bool(true))
        try await service.characteristic(.targetDoorState).write(.int(0))
        #expect(await environment.http.urls == ["http://10.0.0.10/open"])
        #expect(service[.currentDoorState]?.value == .int(0))
        // The current state is kept too.
        #expect(try await environment.json("/?accessoryId=garage")["currentState"] == 0)
        await host.stop()
    }

    @Test func statelessSwitch() async throws {
        let host = try await environment.start()
        let remote = try host.accessory(named: "Remote")
        let down = try #require(remote.services.first { $0.subtype == "1" }?[.programmableSwitchEvent])
        let up = try #require(remote.services.first { $0.subtype == "0" }?[.programmableSwitchEvent])
        let events = NIOLockedValueBox<[String]>([])
        down.observe { change in events.withLockedValue { $0.append("Down \(change.newValue.intValue ?? -1)") } }
        up.observe { change in events.withLockedValue { $0.append("Up \(change.newValue.intValue ?? -1)") } }
        #expect(try await environment.call("/?accessoryId=remote&buttonName=Down&event=2").body == #"{"success":true}"#)   // 26
        // The accessory's own name presses nothing.
        _ = try await environment.call("/?accessoryId=remote&buttonName=Remote&event=0")
        // An event outside 0–2 presses nothing.
        _ = try await environment.call("/?accessoryId=remote&buttonName=Down&event=7")
        _ = try await environment.call("/?accessoryId=remote&buttonName=Down&event=-1")
        #expect(events.withLockedValue { $0 } == ["Down 2"])
        await host.stop()
    }

    @Test func windowCovering() async throws {
        let host = try await environment.start()
        let service = try #require(try host.accessory(named: "Blind").service(.windowCovering))
        try await service.characteristic(.targetPosition).write(.int(40))   // 27
        #expect(await environment.http.urls == ["http://x/o40"])
        #expect(await eventually { service[.currentPosition]?.value == .int(40) })
        try await service.characteristic(.targetPosition).write(.int(0))   // 28
        #expect(await environment.http.urls.last == "http://x/o")
        _ = try await environment.call("/?accessoryId=blind&targetposition=40")
        let reply = try await environment.call("/?accessoryId=blind&currentposition=50")   // 29
        #expect(reply.body == #"{"success":true,"CurrentPosition":50,"TargetPosition":40,"PositionState":2}"#)
        #expect(service[.currentPosition]?.value == .int(50))
        // Positions over 100 are kept within HomeKit's bounds.
        _ = try await environment.call("/?accessoryId=blind&currentposition=150")
        #expect(service[.currentPosition]?.value == .int(100))
        #expect(try await environment.json("/?accessoryId=blind")["CurrentPosition"] == 100)
        #expect(WindowCoveringAccessory.action(for: 25) == "open_20")
        #expect(WindowCoveringAccessory.action(for: 94) == "open_80")
        #expect(WindowCoveringAccessory.action(for: 95) == "close")
        await host.stop()
    }

    @Test func lock() async throws {
        let host = try await environment.start()
        let service = try #require(try host.accessory(named: "Front Lock").service(.lockMechanism))
        await environment.http.answer("http://x/unlock", status: 500)
        await #expect(throws: HAPStatusError.self) { try await service.characteristic(.lockTargetState).write(.int(0)) }   // 30
        #expect(service[.lockCurrentState]?.value == .int(3))
        #expect(service[.lockTargetState]?.value == .int(0))
        #expect(try await environment.json("/?accessoryId=lock") == ["success": true, "currentState": 3, "targetState": 0])
        _ = try await environment.call("/?accessoryId=lock&locktargetstate=1")   // 31
        #expect(service[.lockTargetState]?.value == .int(1))
        try await service.characteristic(.lockTargetState).write(.int(1))
        #expect(await environment.http.urls.last == "http://x/lock")
        #expect(service[.lockCurrentState]?.value == .int(1))
        await host.stop()
    }

    @Test func fan() async throws {
        var settings = exampleBlock
        settings["fanv2s"] = [
            [
                "id": "fan", "name": "Ceiling Fan", "speed_url": "http://x/fan?s=%speedPlaceholder", "speed_factor": 0.03,
                "enableLockPhysicalControls": true, "lock_url": "http://x/lock-controls", "rotation_direction_url": "http://x/dir/%rotationDirection",
            ]
        ]
        let host = try await environment.start(settings: settings)
        let service = try #require(try host.accessory(named: "Ceiling Fan").service(.fanv2))
        _ = try await environment.call("/?accessoryId=fan&state=true")
        _ = try await environment.call("/?accessoryId=fan&speed=40")   // 32: Active stays on.
        #expect(service[.rotationSpeed]?.value == .double(40))
        #expect(service[.active]?.value == .int(1))
        _ = try await environment.call("/?accessoryId=fan&lockstate=1")
        #expect(service[.lockPhysicalControls]?.value == .int(1))
        try await service.characteristic(.rotationSpeed).write(.double(100))   // 33
        try await service.characteristic(.rotationDirection).write(.int(1))
        try await service.characteristic(.lockPhysicalControls).write(.int(0))
        #expect(await environment.http.urls == ["http://x/fan?s=3", "http://x/dir/1"])
        await host.stop()
    }

    @Test func carbonDioxideSensor() async throws {
        let host = try await environment.start()
        let service = try #require(try host.accessory(named: "CO2").service(.carbonDioxideSensor))
        _ = try await environment.call("/?accessoryId=co2&value=1500")   // 34
        #expect(service[.carbonDioxideLevel]?.value == .double(1500))
        #expect(service[.carbonDioxideDetected]?.value == .int(1))
        #expect(try await environment.call("/?accessoryId=co2").body == #"{"success":true,"state":1500}"#)
        _ = try await environment.call("/?accessoryId=co2&value=900")
        #expect(service[.carbonDioxideDetected]?.value == .int(0))
        await host.stop()
    }

    @Test func valve() async throws {
        let host = try await environment.start()
        let service = try #require(try host.accessory(named: "Garden Tap").service(.valve))
        _ = try await environment.call("/?accessoryId=tap&state=true")   // 35
        #expect(service[.active]?.value == .int(1))
        #expect(service[.inUse]?.value == .int(1))
        #expect(try await environment.call("/?accessoryId=tap").body == #"{"success":true,"state":1,"statusFault":0}"#)
        try await service.characteristic(.active).write(.int(0))
        #expect(service[.inUse]?.value == .int(0))
        await host.stop()
    }

    @Test func corsAnswersPreflights() async throws {
        let host = try await environment.start(settings: ["webhook_enable_cors": true, "switches": [["id": "s", "name": "S"]]])
        let preflight = try await environment.call("/", method: "OPTIONS", authorization: nil)   // 36
        #expect(preflight.status == 200)
        #expect(preflight.body.isEmpty)
        #expect(preflight.headers == WebhookRouter.corsHeaders)
        #expect(try await environment.call("/?accessoryId=s", authorization: nil).headers["Access-Control-Allow-Origin"] == "*")
        await host.stop()
    }

    // MARK: State, Setup and the schema

    @Test func statesSurviveARestart() async throws {
        var host = try await environment.start()
        _ = try await environment.call("/?accessoryId=switch1&state=true")
        _ = try await environment.call("/?accessoryId=temp1&value=18")
        await host.stop()
        host = try await environment.start()
        #expect(try host.accessory(named: "Switch name 1").service(.switch)?[.on]?.value == .bool(true))
        #expect(try await environment.json("/?accessoryId=temp1")["state"] == 18)
        await host.stop()
    }

    @Test func setupListsTheEntries() async throws {
        let host = try await environment.start()
        let devices = try await #require(environment.plugin).discover()
        #expect(devices.count == 17)
        let lamp = try #require(devices.first { $0.deviceID == "Desk Lamp" })
        #expect(lamp.model == "Light")
        #expect(lamp.isSetUp)
        #expect(devices.first { $0.deviceID == "Hall Motion" }?.model == "Motion sensor")
        await host.stop()
    }

    @Test func setupKeepsTheCredentialsInTheVault() async throws {
        let host = try await environment.start(settings: ["switches": [["id": "s", "name": "S"]]])
        let plugin = try #require(environment.plugin)
        #expect(await plugin.accountAuthorized() == false)
        guard case .ask(let prompt, _) = try await plugin.authorize(SetupRequest(target: .account)) else {
            Issue.record("Setup asked nothing")
            return
        }
        #expect(prompt.fields.map(\.key) == ["user", "password"])
        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["user": "u", "password": "p"])) else {
            Issue.record("Setup did not finish")
            return
        }
        #expect(outcome.credentials == ["user": "u", "password": "p"])
        #expect(outcome.settings["http_auth_pass"] == .null)
        // Basic authentication cannot carry a colon in the user name.
        await #expect(throws: SetupError.self) {
            try await plugin.authorize(SetupRequest(target: .account, answers: ["user": "a:b", "password": "p"]))
        }
        await host.stop()
    }

    @Test func excludedEntriesAreLeftOut() async throws {
        var settings = exampleBlock
        settings["_accessories"] = ["Kettle": ["excluded": true]]
        let host = try await environment.start(settings: settings)
        #expect(host.mainBridge.server.accessories.first { $0.id == "HttpWebHooks:Kettle" } == nil)
        #expect(try await environment.call("/?accessoryId=out1").status == 404)
        await host.stop()
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(HTTPWebhooksPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/HTTPWebhooks HTTPWebhooksPlugin")
        let schema = try JSONValue(string: try #require(HTTPWebhooksPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "HttpWebHooks")
        let properties = try #require(schema["schema"]?["properties"]?.objectValue)
        for list in HTTPWebhooksPlugin.kinds { #expect(properties[list] != nil, "the schema has no \(list)") }
    }
}
