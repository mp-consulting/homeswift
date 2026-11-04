import Foundation
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftShelly

@Suite(.timeLimit(.minutes(1)))
struct CoIoTTests {
    /// 11.6, decoded.
    @Test func theSpecPacketDecodes() throws {
        let packet = CoAPTestBytes.packet
        let status = try #require(CoIoTStatus(datagram: packet))
        #expect(status.model == "SHSW-PM")
        #expect(status.deviceID == "A4CF12F45678")
        #expect(status.revision == "2")
        #expect(status.validity == 38)
        #expect(status.serial == 42)
        #expect(status.values.map(\.id) == [1101, 4101, 4103, 3104, 2101])
        #expect(status.values[1].value == .number(23.45))
    }

    @Test func validityAndMissingIDs() {
        #expect(CoIoTStatus.validity(1) == 4)
        #expect(CoIoTStatus.validity(382) == 38)
        let anonymous = CoAPMessage(type: .nonConfirmable, code: 30, messageID: 1, payload: Array(#"{"G":[]}"#.utf8)).encoded()
        #expect(CoIoTStatus(datagram: anonymous) == nil)
        let badG = CoAPMessage(type: .nonConfirmable, code: 30, messageID: 1, options: [.init(number: 3332, value: Array("SHSW-1#ABC#2".utf8))],
                               payload: Array(#"{"G":1}"#.utf8)).encoded()
        #expect(CoIoTStatus(datagram: badG) == nil)
        // An option longer than its 16 bits does not trap.
        let long = CoAPMessage(type: .nonConfirmable, code: 30, messageID: 1, options: [
            .init(number: 3332, value: Array("SHSW-1#ABC#2".utf8)), .init(number: 3412, value: Array(repeating: 0xFF, count: 8)),
            .init(number: 3420, value: Array(repeating: 0xFF, count: 8)),
        ], payload: Array(#"{"G":[]}"#.utf8)).encoded()
        #expect(CoIoTStatus(datagram: long)?.validity == 0xFFFF * 4)
        #expect(CoIoTStatus.request() == [0x50, 0x01, 0x00, 0x0A, 0xB3, 0x63, 0x69, 0x74, 0x01, 0x73, 0xFF, 0x00])
    }

    @Test func coloursConvertAsColorConvertDoes() {
        #expect(ShellyColor.hsv(red: 255, green: 0, blue: 0) == (0, 100, 100))
        #expect(ShellyColor.hsv(red: 0, green: 128, blue: 255).hue == 210)
        #expect(ShellyColor.rgb(hue: 120, saturation: 100) == (0, 255, 0))
        #expect(ShellyColor.rgb(hue: 0, saturation: 0) == (255, 255, 255))
        #expect(Gen1Device.version("20230913-113421/v1.14.0-gcb84623") == "1.14.0")
        #expect(Gen1Device.version("custom") == "custom")
    }
}

enum CoAPTestBytes {
    static let packet: [UInt8] = {
        let hex = "501e0001b36369740173ed0bec09534853572d504d234134434631324634353637382332d243017e82002aff"
            + "7b2247223a5b5b302c313130312c315d2c5b302c343130312c32332e34355d2c5b302c343130332c313233345d2c"
            + "5b302c333130342c34312e325d2c5b302c323130312c305d5d7d"
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }()
}

@Suite(.timeLimit(.minutes(1)))
struct ShellyGen1Tests {
    let environment = ShellyEnvironment()

    func start(_ settings: [String: Any] = [:]) async throws -> PluginHost {
        try await environment.start(platform: ShellyPlugin.platform, settings: settings)
    }

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(ShellyPlugin.Configuration.self, from: Data(#"""
            {"platform":"Shelly","name":"Shelly","username":"admin","password":"x","requestTimeout":10000,"staleTimeout":false,
             "admin":{"enabled":true,"port":8181},"devices":[{"id":"74B5A3","exclude":true},{"id":"1D56B0","accessories":[{"type":"outlet"}]}]}
            """#.utf8))
        #expect(configuration.devices?.count == 2)
    }

    /// 11.6: the 1PM's packet makes its switch with its power meter; a write goes to `/relay/0`.
    @Test func a1PMIsHeardAndDriven() async throws {
        let host = try await start()
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.gen1?.listening == true })
        #expect(environment.coiot.sent.first.map(Array.init) == CoIoTStatus.request())
        environment.coiot.receive(CoAPTestBytes.packet)
        let id = "Shelly:Shelly 1PM A4CF12F45678"
        #expect(await eventually { host.accessory(id) != nil })
        let accessory = try #require(host.accessory(id))
        #expect(accessory.information.characteristic(.manufacturer).value == "Shelly")
        #expect(accessory.information.characteristic(.model).value == "SHSW-PM")
        #expect(accessory.information.characteristic(.serialNumber).value == "A4CF12F45678")
        let switchService = try #require(accessory.services.first { $0.type == .switch })
        #expect(switchService.characteristic(.on).value == .bool(true))
        let meter = try #require(accessory.services.first { $0.type == PowerMeter.service })
        #expect(abs((meter.characteristic(PowerMeter.gen1Consumption).value.doubleValue ?? 0) - 23.45) <= 0.051)
        try await switchService.characteristic(.on).write(.bool(false))
        #expect(environment.http.paths.contains("/relay/0?turn=off"))
        // Its settings are read once it is online.
        #expect(await eventually { environment.http.paths.contains("/settings") })
    }

    /// Basic credentials go only to an address that answered 401, then with every request there.
    @Test func credentialsGoOnlyWhereTheyAreAskedFor() async throws {
        environment.http.answer("/settings", status: 401, "")
        let host = try await start(["username": "admin", "password": "secret"])
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.gen1?.listening == true })
        environment.coiot.receive(CoAPTestBytes.packet)
        #expect(await eventually { environment.http.requests.count >= 2 })
        let basic = "Basic \(Data("admin:secret".utf8).base64EncodedString())"
        #expect(environment.http.requests[0].header("Authorization") == nil)
        #expect(environment.http.requests[1].header("Authorization") == basic)
        let id = "Shelly:Shelly 1PM A4CF12F45678"
        #expect(await eventually { host.accessory(id) != nil })
        try await host.accessory(id)?.services.first { $0.type == .switch }?.characteristic(.on).write(.bool(false))
        #expect(environment.http.requests.last?.header("Authorization") == basic)
    }

    /// 11.6's v1 example: a Shelly 2.5 in roller mode is one window covering, opening; a write moves it a second later.
    @Test func aShelly25InRollerModeIsOneCovering() async throws {
        let host = try await start()
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.gen1?.listening == true })
        environment.coiot.receive(coiot("SHSW-25", "B92F3A", revision: 1, [(112, 1), (122, 0), (113, 40), (111, 55)]))
        let id = "Shelly:Shelly 2.5 B92F3A"
        #expect(await eventually { host.accessory(id) != nil })
        let covering = try #require(host.accessory(id)?.services.first { $0.type == .windowCovering })
        #expect(covering.characteristic(.currentPosition).value == .int(40))
        #expect(covering.characteristic(.positionState).value == .int(1))
        try await covering.characteristic(.targetPosition).write(.int(30))
        #expect(await eventually { environment.http.paths.contains("/roller/0?go=to_pos&roller_pos=30") })
        // Back to relays: two switches instead.
        environment.coiot.receive(coiot("SHSW-25", "B92F3A", revision: 1, [(112, 0), (122, 1), (111, 0)]))
        #expect(await eventually { host.accessory("Shelly:Shelly 2.5 B92F3A #1") != nil })
        #expect(await eventually { host.accessory(id) == nil })
        #expect(host.accessory("Shelly:Shelly 2.5 B92F3A #1")?.services.first { $0.type == .switch }?.characteristic(.on).value == .bool(true))
    }

    @Test func anRGBW2InWhiteModeHasFourLights() async throws {
        let host = try await start()
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.gen1?.listening == true })
        environment.coiot.receive(coiot("SHRGBW2", "B5E2C1", revision: 1, [(151, 1), (111, 40), (161, 0), (171, 0), (181, 1), (141, 100)]))
        #expect(await eventually { host.accessory("Shelly:Shelly RGBW2 B5E2C1 #3") != nil })
        let light = try #require(host.accessory("Shelly:Shelly RGBW2 B5E2C1 #0")?.services.first { $0.type == .lightbulb })
        #expect(light.characteristic(.on).value == .bool(true))
        #expect(light.characteristic(.brightness).value == .int(40))
        try await light.characteristic(.brightness).write(.int(70))
        #expect(await eventually { environment.http.paths.contains("/white/0?turn=on&brightness=70") }, "\(environment.http.paths)")
    }

    @Test func aColourBulbSendsOneRequestForAColour() async throws {
        let host = try await start(["devices": [["id": "c0ffee", "colorMode": "rgb"]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.gen1?.listening == true })
        environment.coiot.receive(coiot("SHBLB-1", "C0FFEE", [(1101, 1), (5105, 255), (5106, 0), (5107, 0), (5102, 50)]))
        let id = "Shelly:Shelly Bulb C0FFEE"
        #expect(await eventually { host.accessory(id) != nil })
        let light = try #require(host.accessory(id)?.services.first { $0.type == .lightbulb })
        #expect(await eventually { light.characteristic(.saturation).value.doubleValue == 100 })
        try await light.characteristic(.hue).write(.double(240))
        try await light.characteristic(.saturation).write(.double(100))
        #expect(await eventually { environment.http.paths.contains { $0.hasPrefix("/light/0?") } })
        try await Task.sleep(for: .milliseconds(30))
        let requests = environment.http.paths.filter { $0.hasPrefix("/light/0?") }
        #expect(requests == ["/light/0?mode=color&turn=on&gain=50&red=0&green=0&blue=255"], "\(environment.http.paths)")
    }

    @Test func aButtonPressFiresOnceAndNotAtStartUp() async throws {
        let host = try await start()
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.gen1?.listening == true })
        environment.coiot.receive(coiot("SHIX3-1", "A1B2C3", [(2102, 0), (2103, 4)]))
        let id = "Shelly:Shelly i3 A1B2C3"
        #expect(await eventually { host.accessory(id) != nil })
        let button = try #require(host.accessory(id)?.services.first { $0.subtype == "1" })
        let presses = PressLog()
        _ = button.characteristic(.programmableSwitchEvent).observe { presses.add($0.newValue) }
        let datagram = CoAPMessage(type: .nonConfirmable, code: 30, messageID: 2, options: [.init(number: 3332, value: Array("SHIX3-1#A1B2C3#2".utf8))],
                                   payload: Array(#"{"G":[[0,2102,"SS"],[0,2103,5]]}"#.utf8)).encoded()
        environment.coiot.receive(datagram)
        #expect(await eventually { presses.values == [.int(1)] })
    }

    @Test func sensorsShowTheirValues() async throws {
        let host = try await start()
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.gen1?.listening == true })
        environment.coiot.receive(coiot("SHHT-1", "D1E2F3", [(3101, 21.5), (3103, 48), (3111, -1)]))
        let id = "Shelly:Shelly H&T D1E2F3"
        #expect(await eventually { host.accessory(id) != nil })
        let accessory = try #require(host.accessory(id))
        #expect(accessory.services.first { $0.type == .temperatureSensor }?.characteristic(.currentTemperature).value.doubleValue == 21.5)
        #expect(accessory.services.first { $0.type == .humiditySensor }?.characteristic(.currentRelativeHumidity).value.doubleValue == 48)
        #expect(accessory.services.first { $0.type == .battery }?.characteristic(.batteryLevel).value == .int(100))
        environment.coiot.receive(coiot("SHDW-2", "D0D0D0", [(3108, 1), (3106, -1), (3109, 30), (6110, 0), (3101, 999), (3111, 5)]))
        let window = "Shelly:Shelly Door/Window 2 D0D0D0"
        #expect(await eventually { host.accessory(window) != nil })
        let services = try #require(host.accessory(window)?.services)
        #expect(services.first { $0.type == .contactSensor }?.characteristic(.contactSensorState).value == .int(1))
        #expect(services.first { $0.type == .lightSensor }?.characteristic(.statusFault).value == .int(1))
        #expect(services.first { $0.type == TiltSensor.service }?.characteristic(TiltSensor.angle).value == .int(30))
        #expect(services.first { $0.type == .temperatureSensor }?.characteristic(.statusFault).value == .int(1))
        #expect(services.first { $0.type == .battery }?.characteristic(.statusLowBattery).value == .int(1))
    }

    @Test func excludedAndUnknownDevicesAreLeftOut() async throws {
        let host = try await start(["devices": [["id": "a4cf12f45678 ", "exclude": true]]])
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.gen1?.listening == true })
        environment.coiot.receive(CoAPTestBytes.packet)
        environment.coiot.receive(coiot("SHTRV-01", "ABCDEF", [(1, 1)]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.accessory("Shelly:Shelly 1PM A4CF12F45678") == nil)
        #expect(await environment.gen1?.devices.isEmpty == true)
    }

    @Test func aDeviceOfflineTooLongIsForgotten() async throws {
        let host = try await start(["staleTimeout": 1000])
        defer { Task { await host.stop() } }
        #expect(await eventually { await environment.gen1?.listening == true })
        environment.coiot.receive(coiot("SHSW-1", "ABC123", validity: 1, [(1101, 1)]))
        #expect(await eventually { host.accessory("Shelly:Shelly 1 ABC123") != nil })
        // 4 s of validity and 1 s of stale timeout, at a hundredth of the time.
        #expect(await eventually { host.accessory("Shelly:Shelly 1 ABC123") == nil })
    }

    @Test func canonicalSettingsMoveDevicesAndCredentials() throws {
        let block: JSONValue = [
            "platform": "Shelly", "username": "admin", "password": "global",
            "devices": [["id": " a612f0", "username": "admin", "password": "own"], ["id": "1D56B0", "type": "outlet", "name": "Fan"],
                        ["id": "74B5A3", "exclude": true]],
        ]
        let (canonical, moved, account) = ShellyPlugin.canonical(
            block, plain: ["A612F0": DeviceCredentials(username: "admin", password: "own")], account: DeviceCredentials(username: "admin", password: "global"))
        #expect(account)
        #expect(canonical["password"] == nil && canonical["username"] == nil)
        #expect(moved["A612F0"]?.password == "own")
        #expect(canonical["_accessories"]?["1D56B0"]?["type"] == "outlet")
        #expect(canonical["_accessories"]?["1D56B0"]?["name"] == "Fan")
        #expect(canonical["_accessories"]?["74B5A3"]?["excluded"] == true)
        #expect(canonical["devices"] == nil)
    }
}
