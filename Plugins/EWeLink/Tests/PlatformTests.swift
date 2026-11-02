import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftEWeLink

/// The plugin end to end: the fake cloud, WebSocket and LAN, a real bridge.
@Suite(.timeLimit(.minutes(1)))
struct PlatformTests {
    let environment = EWeLinkTestEnvironment()

    @Test func doesNothingWithoutCredentials() async throws {
        let host = try environment.host(settings: [:])
        try await host.start()
        await environment.plugin?.settle()
        #expect(environment.cloud.requests.isEmpty)
        #expect(host.mainBridge.server.accessories.count == 1)
        await host.stop()
    }

    /// The account's rooms, listed through the platform's session and renamed with `PUT /v2/family/room`; a second
    /// home names the room's home.
    @Test func roomsAreRenamedInTheCloud() async throws {
        let host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1, name: "Lamp")], settings: ["mode": "wan"])
        let plugin = try #require(environment.plugin)
        #expect(await plugin.rooms() == [PluginRoom(id: "room-1", name: "Salon"), PluginRoom(id: "room-2", name: "Kitchen")])

        try await plugin.renameRoom(id: "room-1", name: "Lounge")
        let sent = try #require(environment.cloud.requests(path: "/v2/family/room").last)
        #expect(sent.method == "PUT")
        #expect(try JSONValue(data: sent.body ?? Data()) == ["id": "room-1", "name": "Lounge"])
        #expect(await plugin.rooms().first?.name == "Lounge")
        await #expect(throws: EWeLinkError.self) { try await plugin.renameRoom(id: "room-9", name: "Attic") }

        environment.cloud.update {
            $0.homes = ["home-1", "home-2"]
            $0.rooms["home-2"] = [("room-3", "Garage")]
        }
        #expect(await plugin.rooms().last == PluginRoom(id: "room-3", name: "Garage", place: "Home"))
        await host.stop()
    }

    @Test func discoversDevicesAndConnectsTheWebSocket() async throws {
        let host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1, name: "Lamp", params: ["switch": "on", "fwVersion": "3.5.0"])], settings: ["mode": "wan"])
        let accessory = try #require(environment.accessory(host, "1000aaaaaa"))
        #expect(accessory.name == "Lamp" && accessory.category == .switch)
        #expect(accessory.information[.manufacturer]?.value == "SONOFF" && accessory.information[.model]?.value == "BASIC")
        #expect(accessory.information[.serialNumber]?.value == "1000aaaaaa" && accessory.information[.firmwareRevision]?.value == "3.5.0")
        #expect(accessory.service(.switch)?[.on]?.value == true)

        #expect(await environment.socketReady())
        let login = try #require(environment.socket.sent.first { $0["action"] == "userOnline" })
        #expect(login["at"] == "access-token-1" && login["apikey"] == "user-api-key" && login["appid"] == .string(EWeLinkCloud.appID))
        #expect(login["version"] == 8 && login["userAgent"] == "app")
        #expect(environment.socket.state.withLockedValue { $0.urls.first?.absoluteString } == "wss://eu-pconnect9.coolkit.cc:8080/api/ws")

        // HomeKit writes become commands; updates from the cloud reach HomeKit.
        let on = try #require(accessory.service(.switch)?[.on])
        try await on.homeKitWrite(false)
        let command = try #require(environment.socket.sent.last { $0["action"] == "update" })
        #expect(command["params"] == ["switch": "off"] && command["deviceid"] == "1000aaaaaa" && command["apikey"] == "device-api-key" && command["selfApikey"] == "user-api-key")
        environment.push("1000aaaaaa", ["switch": "on"])
        #expect(await eventually { on.value == true })

        // A command the server rejects shows "No Response".
        environment.socket.update { $0.commandError = 504 }
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await on.homeKitWrite(false) }

        // Offline devices read as "No Response", unless offlineAsOff.
        environment.push("1000aaaaaa", ["online": false])
        #expect(await eventually { (try? await on.read()) == nil })
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { _ = try await on.read() }
        await host.stop()
    }

    @Test func retriesLoginWithBackoff() async throws {
        environment.cloud.update { $0.loginAnswers = [["error": 500, "msg": "busy"], ["error": 500, "msg": "busy"]] }
        let host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1)], settings: ["mode": "wan"])
        #expect(environment.accessory(host, "1000aaaaaa") == nil)
        // A retry is pending, unless a loaded runner took the 150 ms it waits before looking: then it already ran.
        #expect(await eventually {
            await environment.platform()?.hasPendingRetry == true || environment.cloud.requests(path: "/v2/user/login").count > 1
        })
        // 15 s, then 30 s of plugin time.
        #expect(await eventually { environment.accessory(host, "1000aaaaaa") != nil })
        #expect(environment.cloud.requests(path: "/v2/user/login").count == 3)
        await host.stop()
    }

    @Test func reconnectsTheWebSocketAndLogsInAgainWhenTheSessionWasInvalidated() async throws {
        let host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1)], settings: ["mode": "wan"])
        #expect(await environment.socketReady())
        environment.socket.current?.drop()
        #expect(await eventually { environment.socket.connections == 2 })
        #expect(await environment.socketReady())

        environment.socket.update { $0.authError = 406 }
        environment.socket.current?.drop()
        #expect(await eventually { environment.cloud.requests(path: "/v2/user/login").count >= 2 })
        environment.socket.update { $0.authError = 0 }
        #expect(await environment.socketReady())
        await host.stop()
    }

    @Test func aSocketThatDropsRightAfterSigningInIsReplaced() async throws {
        environment.socket.update { $0.dropAfterAuthentication = true }
        let host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1)], settings: ["mode": "wan"])
        #expect(await eventually { environment.socket.connections == 2 })
        #expect(await environment.socketReady())
        #expect(environment.socket.current?.isOpen == true)
        await host.stop()
    }

    /// Another client signing in to the account ends this session each time: the backoff keeps growing
    /// instead of starting over after every login, and starts over once a connection lasts.
    @Test func aSessionTakenOverAgainAndAgainBacksOff() async throws {
        // A connection lasting a minute of plugin time counts as stable: plugin time stands still through the drops
        // (however long a loaded runner takes over them), then moves on a minute at once.
        let clock = EWeLinkClock(scale: testClock.scale)
        clock.freeze()
        let environment = EWeLinkTestEnvironment(clock: clock)
        let host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1)], settings: ["mode": "wan"])
        #expect(await environment.socketReady())
        // Each connection after the first is one more attempt: the count never starts over. A handshake slower than the
        // authentication timeout (100 ms of real time here) is one more connection and one more attempt, counted alike.
        for attempt in 1...3 {
            let before = environment.socket.connections
            environment.socket.current?.drop()
            #expect(await eventually { environment.socket.connections > before })
            #expect(await environment.socketReady())
            let attempts = await environment.platform()?.socket?.reconnectAttempts ?? 0
            #expect(attempts >= attempt && attempts == environment.socket.connections - 1)
        }
        // A minute of plugin time connected: the next drop starts over.
        clock.advance(milliseconds: Double(Timing.socketStableConnection))
        let stable = environment.socket.connections
        environment.socket.current?.drop()
        #expect(await eventually { environment.socket.connections > stable })
        #expect(await environment.socketReady())
        #expect(await environment.platform()?.socket?.reconnectAttempts == environment.socket.connections - stable)
        await host.stop()
    }

    @Test func multiChannelDevicesGetAnAccessoryPerChannel() async throws {
        let switches: JSONValue = [["outlet": 0, "switch": "off"], ["outlet": 1, "switch": "off"], ["outlet": 2, "switch": "on"], ["outlet": 3, "switch": "off"]]
        let host = try await environment.start(
            devices: [device("1000bbbbbb", uiid: 4, name: "Four", params: ["switches": switches])],
            settings: ["mode": "wan", "multiDevices": [["deviceId": "1000bbbbbb", "hideChannels": "4"]]])
        #expect(environment.accessory(host, "1000bbbbbb") == nil)
        #expect((0...3).allSatisfy { environment.accessory(host, "1000bbbbbbSW\($0)") != nil })
        #expect(environment.accessory(host, "1000bbbbbbSW4") == nil)
        #expect(environment.accessory(host, "1000bbbbbbSW1")?.name == "Four 1")
        // Channel n is outlet n - 1 (eWeLink counts outlets from 0); the master shows on when any is.
        @Sendable func on(_ channel: Int) -> HAPValue? { environment.accessory(host, "1000bbbbbbSW\(channel)")?.service(.switch)?[.on]?.value }
        #expect(on(0) == true && on(1) == false && on(2) == false && on(3) == true)

        #expect(await environment.socketReady())
        let channel = try #require(environment.accessory(host, "1000bbbbbbSW1")?.service(.switch)?[.on])
        try await channel.homeKitWrite(true)
        #expect(environment.socket.commands.last == ["switches": [["outlet": 0, "switch": "on"], ["outlet": 1, "switch": "off"], ["outlet": 2, "switch": "on"], ["outlet": 3, "switch": "off"]]])
        // Another channel sees the change before the device confirms it.
        try await environment.accessory(host, "1000bbbbbbSW2")?.service(.switch)?[.on]?.homeKitWrite(true)
        #expect(environment.socket.commands.last == ["switches": [["outlet": 0, "switch": "on"], ["outlet": 1, "switch": "on"], ["outlet": 2, "switch": "on"], ["outlet": 3, "switch": "off"]]])
        // The master switches every outlet.
        try await environment.accessory(host, "1000bbbbbbSW0")?.service(.switch)?[.on]?.homeKitWrite(false)
        #expect(environment.socket.commands.last == ["switches": [["outlet": 0, "switch": "off"], ["outlet": 1, "switch": "off"], ["outlet": 2, "switch": "off"], ["outlet": 3, "switch": "off"]]])

        environment.push("1000bbbbbb", ["switches": [["outlet": 0, "switch": "off"], ["outlet": 1, "switch": "off"], ["outlet": 2, "switch": "off"], ["outlet": 3, "switch": "on"]]])
        // Each channel takes the push on its own: wait for all of them, not just the first to settle.
        #expect(await eventually { on(4) == nil && on(0) == true && channel.value == false && on(3) == false })
        environment.push("1000bbbbbb", ["switches": [["outlet": 0, "switch": "on"], ["outlet": 1, "switch": "off"], ["outlet": 2, "switch": "off"], ["outlet": 3, "switch": "off"]]])
        #expect(await eventually { channel.value == true && on(0) == true && on(2) == false && on(3) == false })
        await host.stop()
    }

    /// An animated scene's effect plays as one of an L2 strip's own scenes (homebridge-ewelink's modes), music in its
    /// Classic rhythm; a style it has none for, and other lights, are left to Homeswift; stopping goes back to colour.
    @Test func anL2StripPlaysItsOwnScenes() async throws {
        let host = try await environment.start(
            devices: [device("1000aaaaaa", uiid: 137, name: "Strip", params: ["switch": "off", "mode": 1]), device("1000bbbbbb", uiid: 1, name: "Lamp")],
            settings: ["mode": "wan"])
        #expect(await environment.socketReady())
        let plugin = try #require(environment.plugin)
        let strip = "eWeLink:1000aaaaaa", lamp = "eWeLink:1000bbbbbb"
        #expect(await plugin.animate(LightEffect(style: .candle), accessoryIDs: [strip, lamp]) == [strip])
        #expect(environment.socket.commands.last == ["switch": "on", "mode": 13])
        #expect(await plugin.animate(LightEffect(style: .music), accessoryIDs: [strip]) == [strip])
        #expect(environment.socket.commands.last == ["switch": "on", "mode": 4, "rhythmMode": 0, "rhythmSensitive": 0])
        #expect(await plugin.animate(LightEffect(style: .fire), accessoryIDs: [strip]).isEmpty)
        await plugin.stopAnimation(accessoryIDs: [strip, lamp])
        #expect(environment.socket.commands.last == ["mode": 1])
        await host.stop()
    }

    @Test func multiChannelOutletsDriveTheirOwnOutlet() async throws {
        let switches: JSONValue = [["outlet": 0, "switch": "off"], ["outlet": 1, "switch": "on"]]
        let host = try await environment.start(
            devices: [device("1000eeeeee", uiid: 2, name: "Two", params: ["switches": switches])],
            settings: ["mode": "wan", "multiDevices": [["deviceId": "1000eeeeee", "showAs": "outlet"]]])
        let first = try #require(environment.accessory(host, "1000eeeeeeSW1")?.service(.outlet)?[.on])
        let second = try #require(environment.accessory(host, "1000eeeeeeSW2")?.service(.outlet)?[.on])
        #expect(first.value == false && second.value == true)
        #expect(await environment.socketReady())
        try await first.homeKitWrite(true)
        #expect(environment.socket.commands.last == ["switches": [["outlet": 0, "switch": "on"], ["outlet": 1, "switch": "on"]]])
        try await second.homeKitWrite(false)
        #expect(environment.socket.commands.last == ["switches": [["outlet": 0, "switch": "on"], ["outlet": 1, "switch": "off"]]])
        await host.stop()
    }

    @Test func aMultiChannelDeviceShownAsABlindIsOneAccessory() async throws {
        let switches: JSONValue = [["outlet": 0, "switch": "off"], ["outlet": 1, "switch": "off"]]
        let host = try await environment.start(
            devices: [device("1000cccccc", uiid: 126, name: "Shade", params: ["switches": switches, "actPow_00": 0])],
            settings: ["mode": "wan", "multiDevices": [["deviceId": "1000cccccc", "showAs": "blind", "operationTime": 10]]])
        let covering = try #require(environment.accessory(host, "1000cccccc")?.service(.windowCovering))
        #expect(environment.accessory(host, "1000ccccccSW1") == nil)
        #expect(covering[EveCharacteristic.currentConsumption] != nil)
        #expect(await environment.socketReady())

        // Opening fully takes 10 s of plugin time: the write returns at once, the motor stops at the end.
        try await covering.characteristic(.targetPosition).homeKitWrite(100)
        #expect(covering[.positionState]?.value == 1)
        #expect(environment.socket.commands.last == ["switches": [["switch": "on", "outlet": 0]]])
        #expect(await eventually { covering[.currentPosition]?.value == 100 })
        #expect(covering[.positionState]?.value == 2)
        #expect(environment.socket.commands.last == ["switches": [["switch": "off", "outlet": 0], ["switch": "off", "outlet": 1]]])

        // DUALR3 power is the sum of both channels.
        environment.push("1000cccccc", ["actPow_00": 1200, "actPow_01": 300])
        #expect(await eventually { covering[EveCharacteristic.currentConsumption]?.value == 15 })
        await host.stop()
    }

    @Test func rfBridgesStayOutAndTheirRemotesComeIn() async throws {
        let bridge = device("1000dddddd", uiid: 28, name: "RF Bridge", extra: ["tags": ["zyx_info": [
            ["name": "Remote", "remote_type": "2", "buttonName": [["0": "Up"], ["1": "Down"]]],
            ["name": "Hall", "remote_type": "6", "buttonName": [["2": "Motion"]]],
            ["name": "Shade", "remote_type": "5", "buttonName": [["3": "Open"], ["4": "Stop"], ["5": "Close"]]],
        ]]])
        let host = try await environment.start(devices: [bridge], settings: [
            "mode": "wan", "rfDevices": [["deviceId": "1000dddddd", "subdevices": [["index": 2, "showAs": "contact", "resetTime": 3]]]],
            "bridgeSensors": [["fullDeviceId": "1000ddddddSW4", "curtainType": "blind"]],
        ])
        #expect(environment.accessory(host, "1000dddddd") == nil)
        let remote = try #require(environment.accessory(host, "1000ddddddSW1"))
        #expect(remote.services.filter { $0.type.uuid == ServiceType.switch.uuid }.count == 2)
        #expect(remote.information[.model]?.value == "RF button")
        let hall = try #require(environment.accessory(host, "1000ddddddSW3")?.service(.contactSensor))
        #expect(environment.accessory(host, "1000ddddddSW4")?.service(.windowCovering) != nil)
        #expect(await environment.socketReady())

        // Pressing a button transmits its channel.
        try await remote.service(.switch, subtype: "switch1")?[.on]?.homeKitWrite(true)
        #expect(environment.socket.commands.last == ["cmd": "transmit", "rfChl": 1])
        // The physical remote, then the sensor. On for three seconds of plugin time: the changes are recorded, so a
        // runner that stalls through them still sees it.
        let pressed = NIOLockedValueBox(false)
        remote.service(.switch, subtype: "switch0")?.characteristic(.on).observe { change in
            if change.newValue == .bool(true) { pressed.withLockedValue { $0 = true } }
        }
        environment.push("1000dddddd", ["cmd": "transmit", "rfChl": 0])
        #expect(await eventually { pressed.withLockedValue { $0 } })
        environment.push("1000dddddd", ["cmd": "trigger", "rfTrig2": .string(ISO8601DateFormatter().string(from: testClock.now))])
        // Open for three seconds: a loaded test machine still sees it before it closes again.
        #expect(await eventually { hall[.contactSensorState]?.value == 1 })
        #expect(await eventually { hall[.contactSensorState]?.value == 0 })
        await host.stop()
    }

    @Test func groupsGoThroughTheHTTPAPI() async throws {
        let host = try await environment.start(groups: [["id": "group-1", "name": "Downstairs", "params": ["switch": "off"]]], settings: ["mode": "wan"])
        let on = try #require(environment.accessory(host, "group-1")?.service(.switch)?[.on])
        try await on.homeKitWrite(true)
        let body = try JSONValue(data: try #require(environment.cloud.requests(path: "/v2/device/thing/status").last?.body))
        #expect(body == ["type": 2, "id": "group-1", "params": ["switch": "on"]])
        await host.stop()
    }

    @Test func cachedDevicesWorkWhileTheCloudIsDown() async throws {
        var host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1, params: ["switch": "off"], extra: ["localtype": 1, "ip": "10.0.0.5", "port": 8081])])
        await host.stop()

        environment.cloud.update { $0.unreachable = true }
        host = try environment.host(settings: EWeLinkTestEnvironment.account)
        try await host.start()
        await environment.plugin?.settle()
        let on = try #require(environment.accessory(host, "1000aaaaaa")?.service(.switch)?[.on])
        // LAN control from the cached device, the cloud being unreachable.
        try await on.homeKitWrite(true)
        let post = try #require(environment.lan.posts.last)
        #expect(post.url.host == "10.0.0.5" && post.body["encrypt"] == true)
        await host.stop()
    }

    @Test func removesStaleAndIgnoredAccessories() async throws {
        var host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1), device("1000eeeeee", uiid: 1), device("1000ffffff", uiid: 1)])
        #expect(environment.accessory(host, "1000eeeeee") != nil)
        await host.stop()
        environment.cloud.update { $0.devices = [device("1000aaaaaa", uiid: 1), device("1000ffffff", uiid: 1)] }
        host = try environment.host(settings: EWeLinkTestEnvironment.account.merging(["ignoredDevices": ["1000ffffff"]]) { $1 })
        try await host.start()
        await environment.plugin?.settle()
        #expect(environment.accessory(host, "1000aaaaaa") != nil)
        #expect(environment.accessory(host, "1000eeeeee") == nil)
        #expect(environment.accessory(host, "1000ffffff") == nil)
        await host.stop()
    }

    @Test func servesThePage() async throws {
        let bridge = device("1000dddddd", uiid: 28, name: "RF Bridge", extra: ["tags": ["zyx_info": [["name": "Remote", "remote_type": "2", "buttonName": [["0": "Up"], ["1": "Down"]]]]]])
        environment.lan.announce(.found(name: "eWeLink_1000aaaaaa", addresses: ["10.0.0.9"], port: 8081, txt: [:]))
        let host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1, name: "Lamp", extra: ["localtype": 1]), bridge])
        let plugin = try #require(environment.plugin)
        func call(_ method: String, _ path: String, _ body: JSONValue = .null) async throws -> PluginWebResponse {
            try await plugin.handleWebRequest(.init(method: method, path: path, body: body, user: "admin"))
        }
        // The plugin's own session (saved by its login) serves the page.
        #expect(try await call("GET", "session").json["success"] == true)
        let devices = try await call("GET", "devices")
        #expect(devices.status == 200)
        let list = try #require(devices.json["devices"]?.arrayValue)
        #expect(list.count == 3)
        #expect(list[0]["deviceId"] == "1000aaaaaa" && list[0]["lanIp"] == "10.0.0.9" && list[0]["lanEnabled"] == true && list[0]["uiid"] == 1)
        #expect(list[2]["deviceId"] == "1000ddddddSW1" && list[2]["isRfSubdevice"] == true && list[2]["model"] == "RF Button" && list[2]["buttons"] == ["Up", "Down"])
        #expect(list[2]["uiid"] == "28-sub" && list[2]["parentDeviceId"] == "1000dddddd")

        // Logging in from the page keeps the session in the plugin.
        #expect(try await call("POST", "login", ["username": "", "password": "x"]).status == 400)
        environment.cloud.update { $0.loginAnswers = [["error": 10001, "msg": "wrong"], ["error": 10001, "msg": "wrong"]] }
        let refused = try await call("POST", "login", ["username": "a@b.c", "password": "bad", "countryCode": "+44"])
        #expect(refused.status == 401 && refused.json["error"] == "wrong [10001]")
        let login = try await call("POST", "login", ["username": "a@b.c", "password": "good", "countryCode": "+44"])
        #expect(login.status == 200 && login.json["region"] == "eu" && login.json["accessToken"] == nil)

        let test = try await call("POST", "test-device", ["deviceId": "1000aaaaaa"])
        #expect(test.json["success"] == true)
        #expect(try await call("GET", "status").json["configured"] == true)
        // The instance's accessories, as Homebridge's /getCachedAccessories.
        let accessories = try #require(try await call("GET", "accessories").json.arrayValue)
        let ids = accessories.compactMap { $0["id"]?.stringValue }
        #expect(ids.contains("eWeLink:1000aaaaaa"))
        #expect(accessories.allSatisfy { $0["platform"] == "eWeLink" && $0["context"]?.objectValue != nil && $0["displayName"]?.stringValue != nil })
        #expect(try await call("GET", "nothing").status == 404)
        await host.stop()
    }

    @Test func theAssistantActionsReachTheirRoutes() async throws {
        let host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1, name: "Lamp")])
        let plugin = try #require(environment.plugin)
        let actions = Dictionary(uniqueKeysWithValues: EWeLinkPlugin.assistantActions.map { ($0.name, $0) })
        #expect(Set(actions.keys) == ["status", "list_devices", "test_device"])
        func run(_ name: String, _ arguments: JSONValue = [:]) async throws -> PluginWebResponse {
            let action = try #require(actions[name])
            return try await plugin.handleWebRequest(action.request(arguments: arguments, user: "admin"))
        }
        let status = try await run("status")
        #expect(status.status == 200 && status.json["configured"] == true && status.json["initialized"] == true)
        let devices = try await run("list_devices")
        #expect(devices.status == 200 && devices.json["devices"]?[0]?["deviceId"] == "1000aaaaaa")

        let test = try #require(actions["test_device"])
        #expect(test.access == .configure && test.confirm)
        #expect(try await run("test_device", ["deviceId": "1000aaaaaa", "params": ["switch": "off"]]).json["success"] == true)
        let body = try JSONValue(data: try #require(environment.cloud.requests(path: "/v2/device/thing/status").last?.body))
        #expect(body["id"] == "1000aaaaaa" && body["params"] == ["switch": "off"])
        #expect(try await run("test_device").status == 400)
        // Only the plugin's own routes, none that takes the account's password.
        #expect(EWeLinkPlugin.assistantActions.allSatisfy { $0.path != "login" })
        await host.stop()
    }
}

/// The accessory types, each on a bridge, commands going over the fake WebSocket.
@Suite(.timeLimit(.minutes(1)))
struct AccessoryTests {
    let environment = EWeLinkTestEnvironment()

    func start(_ devices: [JSONValue], _ settings: [String: Any] = [:]) async throws -> PluginHost {
        let host = try await environment.start(devices: devices, settings: ["mode": "wan"].merging(settings) { $1 })
        _ = await environment.socketReady()
        return host
    }

    @Test func inchingAlwaysSendsOnAndTogglesTheState() async throws {
        // The echo window is real time, the plugin's 1.5 s: a loaded machine still delivers the echo inside it.
        let environment = EWeLinkTestEnvironment(clock: EWeLinkClock(scale: 1))
        let host = try await environment.start(devices: [device("1000aaaaaa", uiid: 1)], settings: ["mode": "wan", "singleDevices": [["deviceId": "1000aaaaaa", "isInched": true]]])
        _ = await environment.socketReady()
        let on = try #require(environment.accessory(host, "1000aaaaaa")?.service(.switch)?[.on])
        try await on.homeKitWrite(true)
        #expect(environment.socket.commands.last == ["switch": "on"])
        #expect(try await on.read() == true)
        try await on.homeKitWrite(false)
        #expect(environment.socket.commands.last == ["switch": "on"])
        #expect(try await on.read() == false)
        // The echo of its own command is ignored; an external press toggles.
        environment.push("1000aaaaaa", ["switch": "on"])
        try await Task.sleep(for: .milliseconds(30))
        #expect(try await on.read() == false)
        // Once the window closes, a press from outside toggles it: pressed until it does, rather than waiting a set time.
        #expect(await eventually {
            environment.push("1000aaaaaa", ["switch": "on"])
            try? await Task.sleep(for: .milliseconds(50))
            return (try? await on.read()) == true
        })
        await host.stop()
    }

    @Test func outletsReportUseAndPower() async throws {
        let host = try await start([device("1000aaaaaa", uiid: 32, params: ["switch": "on", "power": "0", "voltage": "230", "current": "0"])],
                                   ["singleDevices": [["deviceId": "1000aaaaaa", "inUsePowerThreshold": 5]]])
        let outlet = try #require(environment.accessory(host, "1000aaaaaa")?.service(.outlet))
        #expect(outlet[EveCharacteristic.voltage] != nil && outlet[EveCharacteristic.electricCurrent] != nil)
        environment.push("1000aaaaaa", ["power": "12.5", "voltage": "231.5", "current": "0.06"])
        #expect(await eventually { outlet[.outletInUse]?.value == true })
        // On the types' steps, as on Homebridge: whole watts and volts.
        #expect(await eventually { outlet[EveCharacteristic.currentConsumption]?.value == 13 && outlet[EveCharacteristic.voltage]?.value == 232.0 })
        environment.push("1000aaaaaa", ["power": "2"])
        #expect(await eventually { outlet[.outletInUse]?.value == false })
        await host.stop()
    }

    @Test func lightsSendBrightnessAndColour() async throws {
        let host = try await start([
            device("1000aaaaaa", uiid: 36, params: ["switch": "off", "bright": 40]),
            device("1000bbbbbb", uiid: 104, params: ["switch": "on", "ltype": "white", "white": ["br": 20, "ct": 50], "color": ["r": 255, "g": 0, "b": 0, "br": 60]]),
        ])
        let dimmer = try #require(environment.accessory(host, "1000aaaaaa")?.service(.lightbulb))
        #expect(dimmer[.brightness]?.value == 40 && dimmer[.colorTemperature] == nil && dimmer[.hue] == nil)
        try await dimmer.characteristic(.on).homeKitWrite(true)
        #expect(environment.socket.commands.last == ["switch": "on"])
        try await dimmer.characteristic(.brightness).homeKitWrite(75)
        #expect(environment.socket.commands.last == ["bright": 75])

        let white = try #require(environment.accessory(host, "1000bbbbbb")?.service(.lightbulb))
        #expect(white[.colorTemperature]?.value == 320 && white[.hue]?.value == 0.0 && white[.saturation]?.value == 100.0)
        try await white.characteristic(.brightness).homeKitWrite(60)
        #expect(environment.socket.commands.last == ["white": ["br": 60, "ct": 50]])
        try await white.characteristic(.colorTemperature).homeKitWrite(500)
        #expect(environment.socket.commands.last == ["ltype": "white", "white": ["br": 60, "ct": 100]])
        try await white.characteristic(.hue).homeKitWrite(120)
        #expect(environment.socket.commands.last == ["ltype": "color", "color": ["r": 0, "g": 255, "b": 0, "br": 60]])
        await host.stop()
    }

    /// A light with brightness and colour temperature has Adaptive Lighting, `adaptiveLightingShift` mireds warmer, unless
    /// that is -1: the controller sets the white, a report of that white keeps it, a colour set elsewhere stops it.
    @Test func lightsHaveAdaptiveLightingUnlessShiftedToMinusOne() async throws {
        let white: JSONValue = ["switch": "on", "ltype": "white", "white": ["br": 20, "ct": 50]]
        let host = try await start([
            device("1000aaaaaa", uiid: 36, params: ["switch": "off", "bright": 40]),
            device("1000bbbbbb", uiid: 104, params: white),
            device("1000cccccc", uiid: 104, params: white),
        ], ["lightDevices": [["deviceId": "1000bbbbbb", "adaptiveLightingShift": 10], ["deviceId": "1000cccccc", "adaptiveLightingShift": -1]]])
        #expect(environment.accessory(host, "1000aaaaaa")?.service(.lightbulb)?.adaptiveLighting == nil)
        #expect(environment.accessory(host, "1000cccccc")?.service(.lightbulb)?.adaptiveLighting == nil)
        let bulb = try #require(environment.accessory(host, "1000bbbbbb")?.service(.lightbulb))
        let controller = try #require(bulb.adaptiveLighting)
        #expect(controller.customTemperatureAdjustment == 10)
        try controller.activateForTesting(mireds: 290)
        #expect(await eventually { bulb[.colorTemperature]?.value == .int(300) })
        let sent = try #require(environment.socket.commands.last?["white"]?["ct"]?.doubleValue)
        environment.push("1000bbbbbb", ["white": ["br": 20, "ct": .number(sent)]])
        environment.push("1000bbbbbb", ["switch": "on"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.isAdaptiveLightingActive)
        environment.push("1000bbbbbb", ["ltype": "color", "color": ["r": 255, "g": 0, "b": 0, "br": 20]])
        #expect(await eventually { !controller.isAdaptiveLightingActive })
        await host.stop()
    }

    @Test func airConditionersClampTheirTarget() async throws {
        let host = try await start([device("1000aaaaaa", uiid: 151, params: ["power": "on", "mode": "cool", "temperature": 40])])
        let service = try #require(environment.accessory(host, "1000aaaaaa")?.service(.heaterCooler))
        #expect(service[.coolingThresholdTemperature]?.value == 32.0 && service[.heatingThresholdTemperature]?.value == 32.0)
        #expect(service[.coolingThresholdTemperature]?.type.minValue == 16 && service[.coolingThresholdTemperature]?.type.maxValue == 32)
        environment.push("1000aaaaaa", ["temperature": 5])
        #expect(await eventually { service[.coolingThresholdTemperature]?.value == 16.0 })
        try await service.characteristic(.targetHeaterCoolerState).homeKitWrite(1)
        #expect(environment.socket.commands.last == ["mode": "heat"])
        environment.socket.update { $0.commandError = 500 }
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await service.characteristic(.targetHeaterCoolerState).homeKitWrite(2) }
        #expect(try await service.characteristic(.targetHeaterCoolerState).read() == 1)
        await host.stop()
    }

    @Test func curtainsMoveAndRevertWhenACommandFails() async throws {
        let host = try await start([device("1000aaaaaa", uiid: 11, params: ["setclose": 100])])
        let covering = try #require(environment.accessory(host, "1000aaaaaa")?.service(.windowCovering))
        // setclose is inverted: 100 is closed.
        #expect(covering[.currentPosition]?.value == 0)
        try await covering.characteristic(.targetPosition).homeKitWrite(100)
        #expect(environment.socket.commands.last == ["switch": "on"])
        try await covering.characteristic(.targetPosition).homeKitWrite(40)
        #expect(environment.socket.commands.last == ["setclose": 60])
        environment.push("1000aaaaaa", ["setclose": 60])
        #expect(await eventually { covering[.currentPosition]?.value == 40 && covering[.positionState]?.value == 2 })

        environment.socket.update { $0.commandError = 500 }
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await covering.characteristic(.targetPosition).homeKitWrite(80) }
        #expect(covering[.positionState]?.value == 2)
        // The curtain asks for its state once the WebSocket is up.
        #expect(await eventually { environment.socket.sent.contains { $0["action"] == "query" } })
        await host.stop()
    }

    @Test func fansKeepTheirStateOnPartialUpdates() async throws {
        let host = try await start([device("1000aaaaaa", uiid: 34, params: ["switches": [["outlet": 0, "switch": "off"], ["outlet": 1, "switch": "on"]], "speed": 2])])
        let accessory = try #require(environment.accessory(host, "1000aaaaaa"))
        let fan = try #require(accessory.service(.fanv2))
        #expect(fan[.active]?.value == 1 && fan[.rotationSpeed]?.value == 50.0)
        #expect(accessory.service(.lightbulb, subtype: "light") != nil)
        environment.push("1000aaaaaa", ["rssi": -50])
        environment.push("1000aaaaaa", ["switches": [["outlet": 0, "switch": "on"]], "speed": 4])
        // The light is its own service, updated after the fan.
        #expect(await eventually { fan[.rotationSpeed]?.value == 100.0 && accessory.service(.lightbulb, subtype: "light")?[.on]?.value == true })
        #expect(fan[.active]?.value == 1)
        try await fan.characteristic(.rotationSpeed).homeKitWrite(25)
        #expect(environment.socket.commands.last == ["speed": 1])
        await host.stop()
    }

    @Test func garageDoorsPulseTheSwitch() async throws {
        let host = try await start([device("1000aaaaaa", uiid: 1)], ["singleDevices": [["deviceId": "1000aaaaaa", "showAs": "garage"]]])
        let door = try #require(environment.accessory(host, "1000aaaaaa")?.service(.garageDoorOpener))
        try await door.characteristic(.targetDoorState).homeKitWrite(0)
        #expect(door[.currentDoorState]?.value == 2)
        #expect(environment.socket.commands.last == ["switch": "on"])
        #expect(await eventually { environment.socket.commands.last == ["switch": "off"] })
        #expect(await eventually { door[.currentDoorState]?.value == 0 })

        environment.socket.update { $0.commandError = 500 }
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await door.characteristic(.targetDoorState).homeKitWrite(1) }
        #expect(door[.currentDoorState]?.value == 0)
        await host.stop()
    }

    @Test func thHeatersFollowTheirTemperatureWithHysteresis() async throws {
        let host = try await start(
            [device("1000aaaaaa", uiid: 15, params: ["switch": "off", "currentTemperature": 21, "currentHumidity": 40])],
            ["thDevices": [["deviceId": "1000aaaaaa", "showAs": "heater", "targetTempThreshold": 1]]])
        let accessory = try #require(environment.accessory(host, "1000aaaaaa"))
        let heater = try #require(accessory.service(.heaterCooler))
        #expect(accessory.service(.humiditySensor, subtype: "humidity")?[.currentRelativeHumidity]?.value == 40.0)
        #expect(heater[.heatingThresholdTemperature]?.value == 20.0 && heater[.targetHeaterCoolerState]?.type.validValues == [1])
        try await heater.characteristic(.active).homeKitWrite(1)
        #expect(heater[.currentHeaterCoolerState]?.value == 1)
        // Within the band: nothing; under target − 1: heat; at the target: stop.
        environment.push("1000aaaaaa", ["currentTemperature": 19.5])
        try await Task.sleep(for: .milliseconds(50))
        // Only the uiActive polls went out.
        #expect(environment.socket.commands.allSatisfy { $0["uiActive"] != nil })
        environment.push("1000aaaaaa", ["currentTemperature": 18.5])
        #expect(await eventually { heater[.currentHeaterCoolerState]?.value == 2 })
        #expect(environment.socket.commands.last == ["deviceType": "normal", "mainSwitch": "on", "switch": "on"])
        environment.push("1000aaaaaa", ["currentTemperature": 20])
        #expect(await eventually { heater[.currentHeaterCoolerState]?.value == 1 })
        #expect(environment.socket.commands.last == ["deviceType": "normal", "mainSwitch": "off", "switch": "off"])
        await host.stop()
    }

    @Test func valvesTurnThemselvesOff() async throws {
        let host = try await start([device("1000aaaaaa", uiid: 1, params: ["switch": "off"])], ["singleDevices": [["deviceId": "1000aaaaaa", "showAs": "valve"]]])
        let valve = try #require(environment.accessory(host, "1000aaaaaa")?.service(.valve))
        #expect(valve[.valveType]?.value == 1 && valve[.setDuration]?.value == 120)
        // 30 s of plugin time, 300 ms here: still running when a loaded runner looks.
        try await valve.characteristic(.setDuration).homeKitWrite(30)
        try await valve.characteristic(.active).homeKitWrite(1)
        #expect(environment.socket.commands.last == ["switch": "on"] && valve[.inUse]?.value == 1)
        #expect(await eventually { environment.socket.commands.last == ["switch": "off"] })
        #expect(await eventually { valve[.active]?.value == 0 })
        #expect(valve[.setDuration]?.value == 30)
        await host.stop()
    }

    @Test func zigbeeWaterValvesAreFaucets() async throws {
        let host = try await start([device("1000aaaaaa", uiid: 7027, params: ["switch": true])])
        let valve = try #require(environment.accessory(host, "1000aaaaaa")?.service(.valve))
        #expect(valve[.valveType]?.value == 3 && valve[.active]?.value == 1)
        await host.stop()
    }

    @Test func programmableSwitchesSendFreshPresses() async throws {
        let environment = EWeLinkTestEnvironment(clock: EWeLinkClock(scale: 0.1))
        let host = try await environment.start(devices: [device("1000aaaaaa", uiid: 174), device("1000bbbbbb", uiid: 177)], settings: ["mode": "wan"])
        _ = await environment.socketReady()
        let mini = try #require(environment.accessory(host, "1000aaaaaa"))
        #expect(mini.services.filter { $0.type.uuid == ServiceType.statelessProgrammableSwitch.uuid }.count == 6)
        #expect(mini.service(.statelessProgrammableSwitch, subtype: "channel3")?[.serviceLabelIndex]?.value == 3)
        let now = ISO8601DateFormatter().string(from: environment.clock.now)
        environment.push("1000aaaaaa", ["outlet": 2, "key": 1, "actionTime": .string(now)])
        #expect(await eventually { mini.service(.statelessProgrammableSwitch, subtype: "channel3")?[.programmableSwitchEvent]?.value == 1 })
        // A press is fresh for 500 ms here: stamp it when it is sent.
        environment.push("1000bbbbbb", ["outlet": 2, "actionTime": .string(ISO8601DateFormatter().string(from: environment.clock.now))])
        #expect(await eventually { environment.accessory(host, "1000bbbbbb")?.service(.statelessProgrammableSwitch)?[.programmableSwitchEvent]?.value == 2 })
        await host.stop()
    }

    @Test func sensorsShowWhatTheyReport() async throws {
        let host = try await start([
            device("1000aaaaaa", uiid: 102, params: ["switch": "off", "battery": 3]),
            device("1000bbbbbb", uiid: 1, params: ["switch": "off"]),
        ], ["singleDevices": [["deviceId": "1000bbbbbb", "showAs": "sensor", "sensorType": "contact"]], "sensorDevices": [["deviceId": "1000aaaaaa", "lowBattery": 50]]])
        let door = try #require(environment.accessory(host, "1000aaaaaa"))
        #expect(door.service(.contactSensor)?[.contactSensorState]?.value == 0)
        environment.push("1000aaaaaa", ["switch": "on", "battery": 30])
        #expect(await eventually { door.service(.contactSensor)?[.contactSensorState]?.value == 1 })
        // The battery is its own service, updated after the contact.
        #expect(await eventually { door.service(.battery)?[.batteryLevel]?.value == 30 && door.service(.battery)?[.statusLowBattery]?.value == 1 })

        let simulated = try #require(environment.accessory(host, "1000bbbbbb")?.service(.contactSensor))
        environment.push("1000bbbbbb", ["switch": "on"])
        #expect(await eventually { simulated[.contactSensorState]?.value == 1 })
        #expect(simulated[EveCharacteristic.lastActivation] != nil)
        await host.stop()
    }
}

struct AssistantBackgroundTests {
    @Test func backgroundIsAboutHomeswift() throws {
        let background = try #require(EWeLinkPlugin.assistantBackground)
        #expect(background.count > 500)
        #expect(background.contains("Homeswift"))
        #expect(!background.contains("Homebridge"))
        #expect(background.contains("ewelink-tokens.json"))
        #expect(background.contains(SocketAuthenticationError(code: 406).description))
    }
}
