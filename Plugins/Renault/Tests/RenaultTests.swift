import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Testing

@testable import Homeswift
@testable import HomeswiftRenault

/// The plugin on a host against the fake cloud, an R5 (8.5).
@Suite(.timeLimit(.minutes(1)))
struct RenaultTests {
    let accessoryID = RenaultPlugin.accessoryID(vin: Fixtures.vin)

    /// The car's accessory once its first round is in (the interior temperature seen, so it is not rebuilt again).
    func accessory(_ host: PluginHost) async -> Accessory? {
        let id = accessoryID
        guard await eventually({
            host.mainBridge.server.accessories.first { $0.id == id }?.services.contains { $0.subtype == "InteriorTemperature" } == true
        }) else { return nil }
        return host.mainBridge.server.accessories.first { $0.id == accessoryID }
    }

    @Test func aMinimalBlockDecodes() throws {
        let configuration = try JSONDecoder().decode(RenaultPlugin.Configuration.self, from: Data(#"{"platform":"Renault"}"#.utf8))
        #expect(configuration.username == nil)
        #expect(configuration.vins == nil)
    }

    @Test func notSetUpCostsNothing() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: [:])
        #expect(await environment.plugin?.accountAuthorized() == false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(environment.cloud.requests.isEmpty)
        await host.stop()
    }

    @Test func theRenault5BecomesAnAccessory() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        let accessory = try #require(await accessory(host))
        #expect(accessory.information.characteristic(.name).value == "AA-00-AA")
        #expect(accessory.information.characteristic(.manufacturer).value == "Renault")
        #expect(accessory.information.characteristic(.model).value == "Renault 5")
        #expect(accessory.information.characteristic(.serialNumber).value == .string(Fixtures.vin))
        let battery = try #require(accessory.service(.battery))
        #expect(battery.isPrimary)
        #expect(await eventually { battery.characteristic(.batteryLevel).value == 73 })
        #expect(battery.characteristic(.chargingState).value == 0)
        #expect(battery.characteristic(.statusLowBattery).value == 0)
        let subtypes = Set(accessory.services.compactMap(\.subtype))
        #expect(subtypes.isSuperset(of: ["Climate", "Charging", "PluggedIn", "Lights"]))
        // The horn is off by default; the R5 has no lock-status (doors) and reports no exterior temperature.
        #expect(!subtypes.contains("Horn"))
        #expect(!subtypes.contains { $0.hasPrefix("Door.") })
        #expect(!subtypes.contains("ExteriorTemperature"))
        let plugged = try #require(accessory.services.first { $0.subtype == "PluggedIn" })
        #expect(plugged.characteristic(.contactSensorState).value == 1)
        // The interior temperature once seen.
        let refreshed = try #require(await eventually {
            host.mainBridge.server.accessories.first { $0.id == accessoryID }?.services.contains { $0.subtype == "InteriorTemperature" } == true
        } ? host.mainBridge.server.accessories.first { $0.id == accessoryID } : nil)
        #expect(refreshed.services.first { $0.subtype == "InteriorTemperature" }?.characteristic(.currentTemperature).value == 15.0)
        // Climate needs every request's headers.
        let read = try #require(environment.cloud.kamereon("/kca/car-adapter/v2/cars/\(Fixtures.vin)/battery-status").first)
        #expect(read.query["country"] == "FR")
        #expect(read.header("apikey") == "YjkKtHmGfaceeuExUDKGxrLZGGvtVS0J")
        #expect(read.header("Content-type") == "application/vnd.api+json")
        #expect(read.header("x-gigya-id_token")?.hasPrefix("eyJ") == true)
        // Nothing the R5 refuses is ever asked for.
        #expect(environment.cloud.kamereon.allSatisfy { !$0.path.contains("lock-status") && !$0.path.contains("charge-mode") && !$0.path.contains("cockpit") })
        // The plugin's discovery: the car with its parts.
        let discovered = try #require(try await environment.plugin?.discover().first)
        #expect(discovered.deviceID == Fixtures.vin)
        #expect(discovered.parts.first { $0.id == "Horn" }?.included == false)
        await host.stop()
    }

    @Test func climateWritesAndStaysOptimistic() async throws {
        // A hold a loaded runner reads the car within, waited out from the write rather than from the read.
        var timing = testTiming()
        timing.optimisticHold = .seconds(2)
        let environment = TestEnvironment(timing: timing)
        let host = try await environment.start()
        let accessory = try #require(await accessory(host))
        let on = try #require(accessory.services.first { $0.subtype == "Climate" }?.characteristic(.on))
        try await on.write(true)
        let written = ContinuousClock.now
        let start = try #require(environment.cloud.kamereon("/kca/car-adapter/v1/cars/\(Fixtures.vin)/actions/hvac-start", method: "POST").last)
        #expect(start.body == ["data": ["type": "HvacStart", "attributes": ["action": "start", "targetTemperature": 21]]])
        // The car still says off for a while: the switch keeps On until the hold runs out.
        await environment.plugin?.vehicles[Fixtures.vin]?.read(.hvacStatus, .poll)
        #expect(on.value == true)
        try await Task.sleep(until: written + environment.timing.optimisticHold + .milliseconds(50))
        await environment.plugin?.vehicles[Fixtures.vin]?.read(.hvacStatus, .poll)
        #expect(on.value == false)
        // The confirmation reads went out after the action.
        #expect(await eventually { environment.cloud.kamereon("/kca/car-adapter/v1/cars/\(Fixtures.vin)/hvac-status").count >= 3 })

        environment.cloud.answer("/kca/car-adapter/v1/cars/\(Fixtures.vin)/hvac-status", 200, Fixtures.hvacOn)
        await environment.plugin?.vehicles[Fixtures.vin]?.read(.hvacStatus, .poll)
        #expect(on.value == true)
        // The R5's stop is "stop", not "cancel".
        try await on.write(false)
        let stop = try #require(environment.cloud.kamereon("/kca/car-adapter/v1/cars/\(Fixtures.vin)/actions/hvac-start", method: "POST").last)
        #expect(stop.body == ["data": ["type": "HvacStart", "attributes": ["action": "stop"]]])
        await host.stop()
    }

    @Test func theRenault5StartsChargingButCannotStop() async throws {
        let environment = TestEnvironment()
        environment.cloud.answer("/kca/car-adapter/v2/cars/\(Fixtures.vin)/battery-status", 200, Fixtures.battery)
        let host = try await environment.start()
        let accessory = try #require(await accessory(host))
        let on = try #require(accessory.services.first { $0.subtype == "Charging" }?.characteristic(.on))
        #expect(on.isSecurityControl)
        #expect(await eventually { accessory.service(.battery)?.characteristic(.batteryLevel).value == 73 })

        // Unplugged: refused without a request.
        let before = environment.cloud.kamereon.count
        await #expect(throws: HAPStatusError.self) { try await on.write(true) }
        #expect(!environment.cloud.kamereon.dropFirst(before).contains { $0.method == "POST" || $0.path.hasSuffix("ev/settings") })

        // Plugged in: ev/settings is read, every program turned off, and the whole document written back.
        environment.cloud.answer("/kca/car-adapter/v2/cars/\(Fixtures.vin)/battery-status", 200, Fixtures.batteryPluggedIdle)
        await environment.plugin?.vehicles[Fixtures.vin]?.read(.batteryStatus, .poll)
        try await on.write(true)
        let posts = environment.cloud.kamereon("/kcm/v1/vehicles/\(Fixtures.vin)/ev/settings", method: "POST")
        #expect(posts.count == 1)
        var expected = try JSONValue(string: Fixtures.settings).objectValue!
        var program = expected["programs"]![0]!.objectValue!
        program["programActivationStatus"] = false
        expected["programs"] = [.object(program)]
        #expect(posts.first?.body == .object(expected))
        #expect(posts.first?.body?["chargeModeRq"] == "SCHEDULED")
        #expect(await environment.plugin?.vehicles[Fixtures.vin]?.programsBeforeChargeStart == [true])
        #expect(on.value == true)

        // Off: nothing is sent (there is no stop), and the switch goes back to what the car reports.
        environment.cloud.answer("/kca/car-adapter/v2/cars/\(Fixtures.vin)/battery-status", 200, Fixtures.batteryCharging)
        await environment.plugin?.vehicles[Fixtures.vin]?.read(.batteryStatus, .poll)
        let sent = environment.cloud.kamereon.filter { $0.method == "POST" }.count
        try await on.write(false)
        #expect(await eventually { on.value == true })
        #expect(environment.cloud.kamereon.filter { $0.method == "POST" }.count == sent)
        #expect(!environment.cloud.kamereon.contains { $0.path.contains("charging-start") || $0.path.contains("pause-resume") })
        await host.stop()
    }

    /// Range, time to full, charge power and battery temperature come from the battery-status read each round already:
    /// on the Battery service, a battery temperature sensor once seen, and the Status page's series; no other endpoint.
    @Test func batteryReadingsReachTheAccessoryAndTheStatusPage() async throws {
        let environment = TestEnvironment()
        environment.cloud.answer("/kca/car-adapter/v2/cars/\(Fixtures.vin)/battery-status", 200, Fixtures.batteryChargingSample)
        let host = try await environment.start()
        let id = accessoryID
        #expect(await eventually {
            host.mainBridge.server.accessories.first { $0.id == id }?.services.contains { $0.subtype == "BatteryTemperature" } == true
        })
        let accessory = try #require(host.mainBridge.server.accessories.first { $0.id == id })
        let battery = try #require(accessory.service(.battery))
        #expect(await eventually { battery[RenaultCharacteristic.range]?.value == 141 })
        #expect(battery[RenaultCharacteristic.timeToFull]?.value == 145)
        // The R5 reports kilowatts: 27 kW.
        #expect(battery[EveCharacteristic.currentConsumption]?.value == 27000)
        #expect(accessory.services.first { $0.subtype == "BatteryTemperature" }?.characteristic(.currentTemperature).value == 20.0)
        #expect(await eventually { environment.values("range").last == 141 })
        #expect(await eventually { environment.values("timeToFull").last == 145 })
        #expect(await eventually { environment.values("power").last == 27000 })
        #expect(await eventually { environment.values("batteryTemperature").last == 20 })
        // The rest of the battery's report: the energy left, what the charge is doing, the level and status codes.
        #expect(battery[RenaultCharacteristic.availableEnergy]?.value == .double(31))
        #expect(battery[RenaultCharacteristic.chargeStatus]?.value == .string("charge in progress"))
        #expect(await eventually { environment.values("availableEnergy").last == 31 })
        #expect(await eventually { environment.values("level").last == 60 && environment.values("chargingStatus").last == 1 })

        // Not charging: no time to full and no power, whatever estimate the car kept.
        environment.cloud.answer("/kca/car-adapter/v2/cars/\(Fixtures.vin)/battery-status", 200, Fixtures.battery)
        await environment.plugin?.vehicles[Fixtures.vin]?.read(.batteryStatus, .poll)
        #expect(battery[RenaultCharacteristic.range]?.value == 261)
        #expect(battery[RenaultCharacteristic.timeToFull]?.value == 0)
        #expect(battery[EveCharacteristic.currentConsumption]?.value == 0)
        #expect(battery[RenaultCharacteristic.chargeStatus]?.value == .string("not in charge"))
        #expect(battery[RenaultCharacteristic.batteryUpdated]?.value == .string("2026-05-01T06:07:54Z"))
        await host.stop()
        // Only the endpoints the plugin read before: the battery, the climate and the hourly limits.
        let reads = Set(environment.cloud.kamereon.filter { $0.method == "GET" && ($0.path.contains("/cars/") || $0.path.contains("/vehicles/VF1")) }.map(\.path))
        #expect(reads.allSatisfy { $0.hasSuffix("battery-status") || $0.hasSuffix("hvac-status") || $0.hasSuffix("soc-levels") }, "\(reads)")
    }

    /// The charge target of the Accessory Settings goes to the car once, with the minimum it last read, as 4.4's plain
    /// body; the car answering its old values for a while, or a restart, does not send it again.
    @Test func theChargeTargetIsSentOnce() async throws {
        let environment = TestEnvironment()
        var settings = TestEnvironment.signedIn
        settings["_accessories"] = [Fixtures.vin: ["socTarget": 90]]
        var host = try await environment.start(settings: settings)
        let path = "/kcm/v1/vehicles/\(Fixtures.vin)/ev/soc-levels"
        #expect(await eventually { environment.cloud.kamereon(path, method: "POST").count == 1 })
        #expect(environment.cloud.kamereon(path, method: "POST").first?.body == ["socMin": 20, "socTarget": 90])
        // Shown once the answer is in, a moment after the fake saw the request.
        #expect(await eventually { await environment.plugin?.vehicles[Fixtures.vin]?.soc == SocLevels(minimum: 20, target: 90) })
        // The next hourly read still says 80: nothing more is sent.
        await environment.plugin?.vehicles[Fixtures.vin]?.read(.socLevels, .poll)
        await environment.plugin?.vehicles[Fixtures.vin]?.applySocLimits()
        await host.stop()

        host = try await environment.start(settings: settings)
        _ = try #require(await accessory(host))
        #expect(await eventually { environment.cloud.kamereon(path).count >= 3 })
        await environment.plugin?.vehicles[Fixtures.vin]?.applySocLimits()
        #expect(environment.cloud.kamereon(path, method: "POST").count == 1)
        await host.stop()

        // A value Renault does not take is not sent.
        settings["_accessories"] = [Fixtures.vin: ["socTarget": 82]]
        host = try await environment.start(settings: settings)
        _ = try #require(await accessory(host))
        await environment.plugin?.vehicles[Fixtures.vin]?.applySocLimits()
        #expect(environment.cloud.kamereon(path, method: "POST").count == 1)
        await host.stop()
    }

    @Test func socLimitsFollowTheSteps() {
        #expect(SocLevels.isValid(target: 85))
        #expect(!SocLevels.isValid(target: 82))
        #expect(!SocLevels.isValid(target: 50))
        #expect(SocLevels.isValid(minimum: 20))
        #expect(!SocLevels.isValid(minimum: 10))
        #expect(SocLevels(attributes: try! JSONValue(string: Fixtures.soc)) == SocLevels(minimum: 20, target: 80))
    }

    @Test func hornAndLightsTurnThemselvesOff() async throws {
        let environment = TestEnvironment()
        var settings = TestEnvironment.signedIn
        settings["_accessories"] = [Fixtures.vin: ["parts": ["Horn": true]]]
        let host = try await environment.start(settings: settings)
        let accessory = try #require(await accessory(host))
        let horn = try #require(accessory.services.first { $0.subtype == "Horn" }?.characteristic(.on))
        #expect(horn.isSecurityControl)
        try await horn.write(true)
        #expect(environment.cloud.kamereon("/kca/car-adapter/v1/cars/\(Fixtures.vin)/actions/horn-lights", method: "POST").last?.body
            == ["data": ["type": "HornLights", "attributes": ["action": "start", "target": "horn"]]])
        #expect(await eventually { horn.value == false })
        await host.stop()
    }

    @Test func aMissingEndpointIsDroppedAndRemembered() async throws {
        let environment = TestEnvironment()
        environment.cloud.answer("/kca/car-adapter/v1/cars/\(Fixtures.vin)/hvac-status", 200, Fixtures.notSupported)
        let host = try await environment.start()
        let id = accessoryID
        #expect(await eventually { await environment.plugin?.vehicles[Fixtures.vin]?.dropped.contains(.hvacStatus) == true })
        #expect(await eventually {
            host.mainBridge.server.accessories.first { $0.id == id }.map { !$0.services.contains { $0.subtype == "Climate" } } ?? false
        })
        let stored = try #require(environment.plugin?.droppedStore[Fixtures.vin])
        #expect(stored.model == "R5E1VE")
        #expect(stored.endpoints["hvac-status"] != nil)
        // Not asked again.
        let asked = environment.cloud.kamereon("/kca/car-adapter/v1/cars/\(Fixtures.vin)/hvac-status").count
        _ = await environment.plugin?.round(try #require(await environment.plugin?.session))
        #expect(environment.cloud.kamereon("/kca/car-adapter/v1/cars/\(Fixtures.vin)/hvac-status").count == asked)
        await host.stop()
    }

    @Test func anUnauthorizedSessionIsMintedAgainOnce() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        _ = try #require(await accessory(host))
        let jwts = environment.cloud.state.withLockedValue { $0.jwtCount }
        environment.cloud.state.withLockedValue { $0.unauthorizedNext = 1 }
        #expect(await environment.plugin?.vehicles[Fixtures.vin]?.read(.batteryStatus, .poll) == .read)
        #expect(environment.cloud.state.withLockedValue { $0.jwtCount } == jwts + 1)
        await host.stop()
    }

    @Test func aDeadLoginTokenIsReplacedWithThePassword() async throws {
        let environment = TestEnvironment()
        environment.cloud.state.withLockedValue {
            $0.deadTokens = ["LT-old"]
            $0.loginToken = "LT-new"
        }
        let directory = environment.directory
        // The vault holds an old token from Setup.
        try await seedCredentials(environment, RenaultCredentials(loginToken: "LT-old", gmid: "G1", ucid: "U1", username: "driver@example.com", password: "secret"))
        let host = try await environment.start(settings: ["kamereonAccountId": "acc-myr-1", "locale": "fr_FR"])
        _ = try #require(await accessory(host))
        let login = try #require(environment.cloud.gigya("accounts.login").last)
        #expect(login.header("Cookie") == "gmid=G1; ucid=U1")
        #expect(await eventually { environment.plugin?.storedCredentials()?.loginToken == "LT-new" })
        _ = directory
        await host.stop()
    }

    @Test func aRefusedAccountNeedsAuthorizationAndStops() async throws {
        let environment = TestEnvironment()
        environment.cloud.state.withLockedValue {
            $0.deadTokens = ["LT-old"]
            $0.needsTwoFactor = true
        }
        try await seedCredentials(environment, RenaultCredentials(loginToken: "LT-old", username: "driver@example.com", password: "secret"))
        let host = try await environment.start(settings: ["kamereonAccountId": "acc-myr-1", "locale": "fr_FR"])
        let plugin = try #require(environment.plugin)
        #expect(await eventually { plugin.context.accountRefusal != nil })
        let count = environment.cloud.requests.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(environment.cloud.requests.count == count, "no retry loop after a refusal")
        #expect(environment.cloud.kamereon.isEmpty)
        _ = plugin
        await host.stop()
    }

    @Test func theQuotaErrorPausesEverything() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        _ = try #require(await accessory(host))
        environment.cloud.answer("/kca/car-adapter/v2/cars/\(Fixtures.vin)/battery-status", 200, Fixtures.quota)
        let vehicle = try #require(await environment.plugin?.vehicles[Fixtures.vin])
        #expect(await vehicle.read(.batteryStatus, .poll) == .skipped)
        let count = environment.cloud.kamereon.count
        #expect(await vehicle.read(.hvacStatus, .poll) == .skipped)
        let on = try #require(await vehicle.accessory?.services.first { $0.subtype == "Climate" }?.characteristic(.on))
        await #expect(throws: HAPStatusError.self) { try await on.write(true) }
        #expect(environment.cloud.kamereon.count == count, "nothing is sent during the cool-down")
        // The last data stays.
        #expect(await vehicle.accessory?.service(.battery)?.characteristic(.batteryLevel).value == 73)
        await host.stop()
    }

    /// Reads skipped during the cool-down are not failures: the car keeps answering in Home however long it lasts.
    @Test func skippedReadsDuringTheCooldownKeepTheCarAvailable() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start()
        _ = try #require(await accessory(host))
        environment.cloud.answer("/kca/car-adapter/v2/cars/\(Fixtures.vin)/battery-status", 200, Fixtures.quota)
        let vehicle = try #require(await environment.plugin?.vehicles[Fixtures.vin])
        #expect(await vehicle.read(.batteryStatus, .poll) == .skipped)
        #expect(await vehicle.read(.hvacStatus, .poll) == .skipped)
        #expect(await vehicle.read(.batteryStatus, .poll) == .skipped)
        await vehicle.updateAvailability(limit: .zero)
        #expect(await vehicle.accessory?.isUnavailable == false)
        await host.stop()
    }

    /// Several scaled hours of polling with actions and their confirmation reads: never more than the hour's budget in any
    /// rolling hour, never two requests at once.
    @Test func theHourlyBudgetHolds() async throws {
        let hour = Duration.milliseconds(1500)
        let environment = TestEnvironment(timing: testTiming(hour: hour))
        var settings = TestEnvironment.signedIn
        settings["maxCallsPerHour"] = 20
        // A charge target to send, and the readings of a charging car: within the same budget.
        settings["_accessories"] = [Fixtures.vin: ["socTarget": 90]]
        environment.cloud.answer("/kca/car-adapter/v2/cars/\(Fixtures.vin)/battery-status", 200, Fixtures.batteryChargingSample)
        let host = try await environment.start(settings: settings)
        let accessory = try #require(await accessory(host))
        let climate = try #require(accessory.services.first { $0.subtype == "Climate" }?.characteristic(.on))
        let lights = try #require(accessory.services.first { $0.subtype == "Lights" }?.characteristic(.on))
        // Three hours at least, and on until more than 20 requests went out (a loaded runner polls less often in the
        // same time), up to eight.
        let start = ContinuousClock.now, end = start + hour * 3, limit = start + hour * 8
        var toggle = false
        while ContinuousClock.now < end || (environment.cloud.kamereon.count <= 20 && ContinuousClock.now < limit) {
            toggle.toggle()
            try? await climate.write(.bool(toggle))
            try? await lights.write(true)
            try await Task.sleep(for: .milliseconds(150))
        }
        await host.stop()
        let times = environment.cloud.kamereon.map(\.at)
        #expect(times.count > 20, "it polled")
        let window = hour - .milliseconds(30)
        for time in times {
            let inWindow = times.filter { $0 <= time && $0 > time - window }.count
            #expect(inWindow <= 20, "\(inWindow) requests in an hour")
        }
        #expect(environment.cloud.state.withLockedValue { $0.maxInFlight } == 1)
        #expect(environment.cloud.kamereon("/kcm/v1/vehicles/\(Fixtures.vin)/ev/soc-levels", method: "POST").count == 1)
        #expect(!environment.values("range").isEmpty)
        // The poll interval follows the formula: two pollers (battery, climate), the list and the limits hourly.
        let interval = try #require(await environment.plugin?.currentInterval)
        #expect(interval == RenaultPlugin.pollInterval(pollers: 2, hourly: 2, budget: 20 - RequestBudget.actionReserve, hour: hour))
    }

    @Test func setupSignsInWithTheEmailedCode() async throws {
        let environment = TestEnvironment()
        environment.cloud.state.withLockedValue { $0.needsTwoFactor = true }
        let host = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        guard case .ask(let first, _) = try await plugin.authorize(SetupRequest(target: .account)) else { Issue.record("no prompt"); return }
        #expect(first.fields.map(\.key) == ["locale", "email", "password"])
        #expect(first.fields[2].kind == .secret)

        let answers = ["locale": "pt_PT", "email": "driver@example.com", "password": "secret"]
        guard case .ask(let codePrompt, let state) = try await plugin.authorize(SetupRequest(target: .account, answers: answers)) else {
            Issue.record("no code step"); return
        }
        #expect(codePrompt.text == "Enter the code Renault sent to d***@example.com.")
        #expect(environment.cloud.gigya("accounts.tfa.email.sendVerificationCode").first?.query["lang"] == "pt")
        #expect(environment.cloud.gigya("accounts.tfa.initTFA").first?.header("Cookie") == "gmid=G1; ucid=U1")

        // A wrong code: asked again, no new code sent.
        await #expect(throws: SetupError.self) { try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "000000"], state: state)) }
        #expect(environment.cloud.gigya("accounts.tfa.email.sendVerificationCode").count == 1)

        guard case .done(let outcome) = try await plugin.authorize(SetupRequest(target: .account, answers: ["code": "123456"], state: state)) else {
            Issue.record("not done"); return
        }
        let credentials = try #require(try outcome.credentials?.decode(RenaultCredentials.self))
        #expect(credentials == RenaultCredentials(loginToken: "LT-example-login-token", gmid: "G1", ucid: "U1", username: "driver@example.com", password: "secret"))
        #expect(outcome.settings["kamereonAccountId"] == "acc-myr-1")
        #expect(outcome.settings["locale"] == "pt_PT")
        #expect(outcome.settings["password"] == .null)
        // The second login sent the remembered device; the Kamereon requests used Portugal's country.
        #expect(environment.cloud.gigya("accounts.login").last?.header("Cookie") == "gmid=G1; ucid=U1")
        #expect(environment.cloud.kamereon.allSatisfy { $0.query["country"] == "PT" })
        await host.stop()
    }

    @Test func setupRefusesAWrongPassword() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: [:])
        let plugin = try #require(environment.plugin)
        await #expect(throws: SetupError("Renault refused the e-mail or the password")) {
            try await plugin.authorize(SetupRequest(target: .account, answers: ["locale": "fr_FR", "email": "driver@example.com", "password": "wrong"]))
        }
        await host.stop()
    }

    /// The plugin's directory, from this file's.
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    @Test func schemaIsCurrent() throws {
        let file = try String(contentsOf: Self.root.appendingPathComponent("config.schema.json"), encoding: .utf8)
        #expect(RenaultPlugin.configurationSchemaJSON == file.trimmingCharacters(in: .whitespacesAndNewlines),
            "run: swift Scripts/embed-assets.swift plugin Plugins/Renault RenaultPlugin")
        let schema = try JSONValue(string: try #require(RenaultPlugin.configurationSchemaJSON))
        #expect(schema["pluginAlias"] == "Renault")
    }

    /// Puts account credentials in the vault the host will open, as Setup leaves them.
    func seedCredentials(_ environment: TestEnvironment, _ credentials: RenaultCredentials) async throws {
        let host = try await environment.start(settings: [:])
        try #require(environment.plugin).context.saveCredentials(credentials)
        await host.stop()
    }
}
