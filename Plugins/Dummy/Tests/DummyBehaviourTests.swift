import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOHTTP1
import Testing

@testable import Homeswift
@testable import HomeswiftDummy

/// The spec's identities and test vectors (docs/clean-room/Dummy.md, sections 3, 6.3 and 14).
@Suite(.timeLimit(.minutes(1)))
struct DummyIdentityTests {
    @Test func uuidsAreHAPNodeJSNameBasedOnes() {
        #expect(DummyIdentity.uuid("HomebridgeDummy:Switch:MySwitch") == "8c1a1e2a-e4ee-432a-acc4-74e1053649de")
        #expect(DummyIdentity.uuid("3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f") == "f76a7be0-5e66-4b53-8c02-8da11fc4ad3b")
        #expect(DummyIdentity.uuid("HomebridgeDummy:Group:LivingRoom)}") == "c2d8b53c-f535-47da-973d-eee490dcbff7")
    }

    @Test func identifiersComeFromTheIdOrTheTypeAndName() throws {
        let reader = ConfigReader(logger: testLogger)
        let derived = try #require(reader.accessory(["name": "My\u{00A0}Switch \t", "type": "Switch"]))
        #expect(derived.identifier == "HomebridgeDummy:Switch:MySwitch")
        #expect(DummyPlugin.accessoryID(deviceID: derived.deviceID) == "HomebridgeDummy:Switch:MySwitch")
        let explicit = try #require(reader.accessory(["id": "3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f", "name": "Desk Lamp", "type": "Lightbulb"]))
        #expect(explicit.identifier == "3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f")
        #expect(DummyPlugin.accessoryID(deviceID: explicit.deviceID) == "HomebridgeDummy:3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f")
        #expect(DummyIdentity.groupIdentifier("Living Room") == "HomebridgeDummy:Group:LivingRoom)}")
        #expect(reader.accessory(["type": "Switch"]) == nil)
        #expect(reader.accessory(["name": "X", "type": "Toaster"]) == nil)
        #expect(reader.accessory(["name": "X", "type": "Door", "protocol": "Matter"]) == nil)
    }

    @Test func limiterUsageIsKeptUnderTheHashOfItsSettings() throws {
        let limiter = LimiterConfig(limit: 1, units: .hours, period: .day, resetOnRestart: false)
        #expect(DummyIdentity.limiterIdentifier(accessory: "3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f", limiter: limiter) == "0891db4a-556e-42fd-8ee0-a5a3a9004061")
    }

    @Test func durationsAreDescribedInTheirLargestUnit() {
        #expect(TimeUnits.describe(milliseconds: 5000) == "5 seconds")
        #expect(TimeUnits.describe(milliseconds: 60_000) == "1 minute")
        #expect(TimeUnits.describe(milliseconds: 500) == "500 milliseconds")
        #expect(TimeUnits.describe(milliseconds: 3 * 3_600_000) == "3 hours")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DummyScheduleTests {
    @Test func cronPresetsAndSeconds() throws {
        let weekdays = try CronExpression("@weekdays")
        let saturday = parisDate(2026, 11, 7, 12)
        #expect(weekdays.next(after: saturday, calendar: paris) == parisDate(2026, 11, 9))
        let tenSeconds = try CronExpression("*/10 * * * * *")
        #expect(tenSeconds.next(after: parisDate(2026, 11, 7, 12, 0, 3), calendar: paris) == parisDate(2026, 11, 7, 12, 0, 10))
        #expect(try CronExpression("0 4 * * mon-fri").next(after: saturday, calendar: paris) == parisDate(2026, 11, 9, 4))
        #expect(try CronExpression("@monthly").next(after: saturday, calendar: paris) == parisDate(2026, 12, 1))
        #expect(throws: CronExpression.ParseError.self) { try CronExpression("61 * * * *") }
    }

    @Test func aCustomCronNeedsItsExpression() {
        let reader = ConfigReader(logger: testLogger)
        #expect(reader.schedule(["type": "CRON", "cron": "CRON_CUSTOM"], name: "X") == nil)
        #expect(reader.schedule(["type": "CRON", "cron": "CRON_CUSTOM", "cronCustom": "*/10 * * * * *"], name: "X") != nil)
        #expect(reader.schedule(["type": "SUNSET"], name: "X") == nil)
        #expect(reader.schedule(["delay": 3, "units": "SECONDS"], name: "X") == ScheduleConfig(kind: .timeout(milliseconds: 3000, random: false)))
    }

    @Test func sunTimesForParis() throws {
        let day = parisDate(2026, 6, 21, 12)
        let sunset = try #require(SunTimes.time(of: .sunset, on: day, latitude: 48.8566, longitude: 2.3522))
        // Paris sets at about 21:58 on the solstice.
        #expect(abs(sunset.timeIntervalSince(parisDate(2026, 6, 21, 21, 58))) < 180)
        let sunrise = try #require(SunTimes.time(of: .sunrise, on: day, latitude: 48.8566, longitude: 2.3522))
        #expect(abs(sunrise.timeIntervalSince(parisDate(2026, 6, 21, 5, 47))) < 180)
        let order: [SunEvent] = [.dawn, .sunrise, .goldenHour, .sunset, .dusk]
        let times = order.compactMap { SunTimes.time(of: $0, on: day, latitude: 48.8566, longitude: 2.3522) }
        #expect(times == times.sorted() && times.count == 5)
        // No astronomical night in Paris at midsummer; none in the Arctic summer.
        #expect(SunTimes.time(of: .night, on: day, latitude: 48.8566, longitude: 2.3522) == nil)
        #expect(SunTimes.time(of: .sunset, on: day, latitude: 78, longitude: 15) == nil)
    }

    /// TV6: on at sunset less 15 minutes, off four hours later, every day.
    @Test func aSunScheduleFiresEveryDayWithItsOffset() async throws {
        let start = parisDate(2026, 6, 21, 12)
        let harness = await Harness([[
            "id": "porch", "name": "Porch", "type": "Switch",
            "schedule": ["type": "SUNSET", "offset": -15, "latitude": 48.8566, "longitude": 2.3522],
            "autoReset": ["type": "TIMEOUT", "time": 4, "units": "HOURS"],
        ]], now: start)
        let sunset = try #require(SunTimes.time(of: .sunset, on: start, latitude: 48.8566, longitude: 2.3522))
        await harness.advance(sunset.timeIntervalSince(start) - 15 * 60 - 1)
        #expect(harness.value("porch", .on) == .bool(false))
        await harness.advance(2)
        #expect(harness.value("porch", .on) == .bool(true))
        await harness.advance(4 * 3600)
        #expect(harness.value("porch", .on) == .bool(false))
        await harness.advance(20 * 3600 + 300)
        #expect(harness.value("porch", .on) == .bool(true))
    }

    /// TV1: the auto-reset restarts on every trigger, and resumes or fires soon after a restart.
    @Test func autoResetRestartsAndResumes() async throws {
        let entry: JSONValue = ["name": "My Switch", "type": "Switch", "autoReset": ["type": "TIMEOUT", "time": 5, "units": "SECONDS"]]
        let id = "HomebridgeDummy:Switch:MySwitch"
        let start = parisDate(2026, 11, 4, 10)
        let harness = await Harness([entry], now: start)
        _ = await harness.engine.write(id, .on(true))
        await check(await harness.stored(id, "On") == .bool(true))
        await check(await harness.stored(id, "AutoReset")?.doubleValue == start.timeIntervalSince1970 * 1000 + 5000)
        await harness.advance(3)
        _ = await harness.engine.write(id, .on(true))
        await harness.advance(4.9)
        #expect(harness.value(id, .on) == .bool(true))
        await harness.advance(0.2)
        #expect(harness.value(id, .on) == .bool(false))
        await check(await harness.stored(id, "AutoReset") == nil)

        // On again, then a restart before it resets: the timer resumes for what was left.
        _ = await harness.engine.write(id, .on(true))
        let resumed = await harness.restarted([entry], at: harness.scheduler.now.addingTimeInterval(3))
        #expect(resumed.value(id, .on) == .bool(true))
        await resumed.advance(1.9)
        #expect(resumed.value(id, .on) == .bool(true))
        await resumed.advance(0.2)
        #expect(resumed.value(id, .on) == .bool(false))

        // A restart after it should have reset: it resets 100 ms later.
        _ = await resumed.engine.write(id, .on(true))
        let late = await resumed.restarted([entry], at: resumed.scheduler.now.addingTimeInterval(10))
        #expect(late.value(id, .on) == .bool(true))
        await late.advance(0.15)
        #expect(late.value(id, .on) == .bool(false))
    }

    /// Q3: a timeout schedule arms once the accessory is reset, then on every reset.
    @Test func aTimeoutScheduleArmsOnReset() async {
        let harness = await Harness([[
            "id": "s", "name": "S", "type": "Switch", "schedule": ["type": "TIMEOUT", "time": 2, "units": "SECONDS"],
        ]], now: parisDate(2026, 11, 4, 10))
        await harness.advance(5)
        #expect(harness.value("s", .on) == .bool(false))
        _ = await harness.engine.write("s", .on(false))
        await harness.advance(2.1)
        #expect(harness.value("s", .on) == .bool(true))
    }

    @Test func intervalsRepeat() async {
        let harness = await Harness([[
            "id": "m", "name": "Motion", "type": "MotionSensor",
            "schedule": ["type": "INTERVAL", "time": 1, "units": "MINUTES"],
            "autoReset": ["type": "TIMEOUT", "time": 10, "units": "SECONDS"],
        ]], now: parisDate(2026, 11, 4, 10))
        await harness.advance(60.5)
        #expect(harness.value("m", .motionDetected) == .bool(true))
        await harness.advance(10)
        #expect(harness.value("m", .motionDetected) == .bool(false))
        await harness.advance(50)
        #expect(harness.value("m", .motionDetected) == .bool(true))
    }

    @Test func randomDurationsUseTheDrawnFraction() async {
        let harness = await Harness([[
            "id": "r", "name": "R", "type": "Switch", "autoReset": ["type": "TIMEOUT", "time": 10, "units": "SECONDS", "random": true],
        ]], now: parisDate(2026, 11, 4, 10), random: { 0.25 })
        _ = await harness.engine.write("r", .on(true))
        await harness.advance(2.4)
        #expect(harness.value("r", .on) == .bool(true))
        await harness.advance(0.2)
        #expect(harness.value("r", .on) == .bool(false))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DummyFeatureTests {
    /// TV5: triggered at 23:30, the rest of the day plus a day's hour; reset at 01:00.
    @Test func theLimiterSpansThePeriodsEnd() async throws {
        let harness = await Harness([[
            "id": "h", "name": "Heater", "type": "Switch", "limiter": ["limit": 1, "units": "HOURS", "period": "DAY"],
        ]], now: parisDate(2026, 11, 4, 23, 30))
        _ = await harness.engine.write("h", .on(true))
        let limiterID = DummyIdentity.limiterIdentifier(accessory: "h", limiter: LimiterConfig(limit: 1, units: .hours, period: .day, resetOnRestart: false))
        let stored = await harness.stored(limiterID, "Limiter")
        let record = try #require(LimiterRecord(stored))
        #expect(record.timeRemaining == 90 * 60_000)
        #expect(record.resetTimestamp == parisDate(2026, 11, 5).timeIntervalSince1970 * 1000)
        await harness.advance(89 * 60)
        #expect(harness.value("h", .on) == .bool(true))
        await harness.advance(61)
        #expect(harness.value("h", .on) == .bool(false))
        // The period ended at midnight: the next trigger has a fresh hour.
        _ = await harness.engine.write("h", .on(true))
        let freshStored = await harness.stored(limiterID, "Limiter")
        let fresh = try #require(LimiterRecord(freshStored))
        #expect(fresh.timeRemaining == 3_600_000)
        #expect(fresh.resetTimestamp == parisDate(2026, 11, 6).timeIntervalSince1970 * 1000)
        // Off after 10 minutes: 50 minutes are left.
        await harness.advance(600)
        _ = await harness.engine.write("h", .on(false))
        await check(LimiterRecord(await harness.stored(limiterID, "Limiter"))?.timeRemaining == 50 * 60_000)
    }

    @Test func aLimiterLongerThanItsPeriodIsRefused() {
        #expect(ConfigReader(logger: testLogger).limiter(["limit": 2, "units": "HOURS", "period": "HOUR"], name: "X") == nil)
    }

    /// TV10: an egg timer and a fixed fade.
    @Test func fadesStepDownThenTurnOff() async {
        let start = parisDate(2026, 11, 4, 10)
        let harness = await Harness([
            ["id": "egg", "name": "Egg", "type": "Lightbulb", "isDimmer": true, "fadeOut": ["type": "INCREMENTAL", "time": 1, "units": "MINUTES"]],
            ["id": "fix", "name": "Fixed", "type": "Lightbulb", "isDimmer": true, "fadeOut": ["type": "FIXED", "time": 10, "units": "SECONDS"]],
        ], now: start)
        _ = await harness.engine.write("egg", .brightness(50))
        _ = await harness.engine.write("fix", .brightness(50))
        _ = await harness.engine.write("egg", .on(true))
        _ = await harness.engine.write("fix", .on(true))
        await harness.advance(0.21)
        #expect(harness.value("fix", .brightness) == .int(49))
        await harness.advance(10)
        #expect(harness.value("fix", .on) == .bool(false))
        #expect(harness.value("fix", .brightness) == .int(50))
        await harness.advance(50)
        #expect(harness.value("egg", .brightness) == .int(49))
        await harness.advance(49 * 60)
        #expect(harness.value("egg", .on) == .bool(false))
        #expect(harness.value("egg", .brightness) == .int(50))
    }

    /// TV4: the alarm follows the door and the lock.
    /// Homeswift's `exactPosition`: a shutter keeps 0 to 100 % (open when above 0); without it, open or closed.
    @Test func aShutterWithExactPositionsKeepsThePositionSet() async {
        let harness = await Harness([
            ["id": "exact", "name": "Shutter", "type": "WindowCovering", "exactPosition": true],
            ["id": "plain", "name": "Blind", "type": "WindowCovering"],
        ], now: parisDate(2026, 11, 4, 10))
        await check(await harness.engine.write("exact", .targetPosition(35)) == nil)
        #expect(harness.value("exact", .targetPosition) == .int(35) && harness.value("exact", .currentPosition) == .int(35))
        await check(await harness.engine.write("plain", .targetPosition(35)) == .int(100))
    }

    @Test func conditionsFollowOtherAccessories() async {
        let harness = await Harness([
            ["id": "door", "name": "Front Door", "type": "Door"],
            ["id": "lock", "name": "Front Lock", "type": "LockMechanism"],
            ["id": "alarm", "name": "Alarm", "type": "Switch", "conditions": ["operator": "and", "operands": [
                ["type": "ACCESSORY", "accessoryId": "door", "accessoryState": "open"],
                ["type": "ACCESSORY", "accessoryId": "lock", "accessoryState": "locked"],
            ]]],
        ], now: parisDate(2026, 11, 4, 10))
        #expect(harness.value("alarm", .on) == .bool(false))
        await check(await harness.engine.write("door", .targetPosition(40)) == .int(100))
        #expect(harness.value("door", .targetPosition) == .int(100))
        #expect(harness.value("alarm", .on) == .bool(true))
        _ = await harness.engine.write("door", .targetPosition(0))
        #expect(harness.value("alarm", .on) == .bool(false))
        _ = await harness.engine.write("door", .targetPosition(100))
        _ = await harness.engine.write("lock", .lock(0))
        #expect(harness.value("alarm", .on) == .bool(false))
    }

    @Test func accessoriesNamingEachOtherDoNotLoop() async {
        let harness = await Harness([
            ["id": "a", "name": "A", "type": "Switch", "conditions": ["operator": "or", "operands": [["type": "ACCESSORY", "accessoryId": "b", "accessoryState": "on"]]]],
            ["id": "b", "name": "B", "type": "Switch", "conditions": ["operator": "or", "operands": [["type": "ACCESSORY", "accessoryId": "a", "accessoryState": "on"]]]],
        ], now: parisDate(2026, 11, 4, 10))
        _ = await harness.engine.write("b", .on(true))
        #expect(harness.value("a", .on) == .bool(true))
        #expect(harness.value("b", .on) == .bool(true))
    }

    @Test func aConditionCannotReferenceItself() {
        let reader = ConfigReader(logger: testLogger)
        let config = reader.accessory(["id": "a", "name": "A", "type": "Switch", "conditions": ["operator": "or", "operands": [
            ["type": "ACCESSORY", "accessoryId": "a", "accessoryState": "on"],
        ]]])
        #expect(config?.conditions == nil)
    }

    @Test func logLinesTrigger() async {
        let harness = await Harness([
            ["id": "l", "name": "Log", "type": "Switch", "conditions": ["operator": "or", "operands": [["type": "LOG", "pattern": "doorbell (rang|pressed)"]]]],
        ], now: parisDate(2026, 11, 4, 10))
        await check(await harness.engine.registerLogPatterns())
        await harness.engine.logLine("the front doorbell rang twice")
        #expect(harness.value("l", .on) == .bool(true))
    }

    @Test func reachabilityConditions() async {
        let harness = await Harness([
            ["id": "home", "name": "Home", "type": "OccupancySensor", "enableWebhook": true, "conditions": ["operator": "and", "operands": [
                ["type": "PING", "pingHost": "phone.local", "checkInterval": 30, "checkUnits": "SECONDS"],
            ]]],
        ], now: parisDate(2026, 11, 4, 10))
        await harness.advance(0.01)
        #expect(harness.value("home", .occupancyDetected) == .int(0))
        harness.probe.reachable.withLockedValue { $0["phone.local"] = true }
        await harness.advance(30)
        #expect(harness.value("home", .occupancyDetected) == .int(1))
        harness.probe.reachable.withLockedValue { $0["phone.local"] = false }
        await harness.advance(30)
        #expect(harness.value("home", .occupancyDetected) == .int(0))
        #expect(ReachabilityTarget("aa:bb:cc:dd:ee:ff") == nil)
        #expect(ReachabilityTarget("http://10.0.0.2:8080/x") == ReachabilityTarget(host: "10.0.0.2", ports: [8080]))
    }

    @Test func aTimerSensorPulsesWhenTheAccessoryIsReset() async {
        let harness = await Harness([[
            "id": "t", "name": "Timer", "type": "Switch", "sensor": ["type": "MotionSensor", "behavior": "TIMER"],
            "autoReset": ["type": "TIMEOUT", "time": 5, "units": "SECONDS"],
        ], [
            "id": "m", "name": "Mirror", "type": "Switch", "sensor": ["type": "ContactSensor"],
        ]], now: parisDate(2026, 11, 4, 10))
        _ = await harness.engine.write("t", .on(true))
        #expect(harness.services["t"]?.sensor?[.motionDetected]?.value == .bool(false))
        await harness.advance(5.1)
        #expect(harness.services["t"]?.sensor?[.motionDetected]?.value == .bool(true))
        await harness.advance(1)
        #expect(harness.services["t"]?.sensor?[.motionDetected]?.value == .bool(false))
        _ = await harness.engine.write("m", .on(true))
        #expect(harness.services["m"]?.sensor?[.contactSensorState]?.value == .int(1))
    }

    @Test func aGarageDoorSimulatesItsMovement() async {
        let harness = await Harness([[
            "id": "g", "name": "Garage", "type": "GarageDoorOpener", "simulation": ["enabled": true, "time": 10, "units": "SECONDS"],
        ]], now: parisDate(2026, 11, 4, 10))
        #expect(harness.value("g", .currentDoorState) == .int(1))
        _ = await harness.engine.write("g", .targetDoor(0))
        #expect(harness.value("g", .currentDoorState) == .int(2))
        await harness.advance(10)
        #expect(harness.value("g", .currentDoorState) == .int(0))
    }

    @Test func aWindowMovesAPercentAtATime() async {
        let harness = await Harness([[
            "id": "w", "name": "Window", "type": "Window", "simulation": ["enabled": true, "time": 10, "units": "SECONDS"],
        ]], now: parisDate(2026, 11, 4, 10))
        _ = await harness.engine.write("w", .targetPosition(100))
        await harness.advance(5.05)
        #expect(harness.value("w", .currentPosition) == .int(50))
        await harness.advance(5)
        #expect(harness.value("w", .currentPosition) == .int(100))
    }

    @Test func aValveShowsItsDurations() async {
        let harness = await Harness([[
            "id": "v", "name": "Sprinkler", "type": "Valve", "valveType": "irrigation", "autoReset": ["type": "TIMEOUT", "time": 2, "units": "MINUTES"],
        ]], now: parisDate(2026, 11, 4, 10))
        #expect(harness.value("v", .setDuration) == .int(120))
        #expect(harness.value("v", .valveType) == .int(1))
        _ = await harness.engine.write("v", .active(1))
        await harness.advance(20)
        await check(await harness.engine.remainingDuration("v") == 100)
        _ = await harness.engine.write("v", .setDuration(30))
        _ = await harness.engine.write("v", .active(1))
        await harness.advance(30.1)
        #expect(harness.value("v", .active) == .int(0))
        #expect(harness.value("v", .inUse) == .int(0))
    }

    @Test func notificationsAreSentOnChangesOnly() async {
        let harness = await Harness([[
            "id": "n", "name": "N", "type": "Switch",
            "notification": ["api": "PUSHOVER", "token": "user-key", "id": "app-token", "title": "On", "text": "It is on", "resetText": "It is off"],
        ]], now: parisDate(2026, 11, 4, 10))
        _ = await harness.engine.write("n", .on(true))
        _ = await harness.engine.write("n", .on(true))
        _ = await harness.engine.write("n", .on(false))
        await check(await eventually { harness.notifier.sent.withLockedValue { $0.count } == 2 })
        let sent = harness.notifier.sent.withLockedValue { $0 }
        #expect(sent.map(\.text).sorted() == ["It is off", "It is on"])
    }

    @Test func notificationRequests() throws {
        let notifier = PushNotifier(http: HTTPClient())
        let pushover = NotificationConfig(api: .pushover, token: "user key", id: "app", title: "T", text: "x")
        let request = try #require(notifier.request(pushover, title: "T", text: "Hello there"))
        #expect(request.url.absoluteString == "https://api.pushover.net/1/messages.json?token=app&user=user%20key&message=Hello%20there&title=T")
        #expect(request.method == "POST")
        let notify = NotificationConfig(api: .notify, token: "tok", id: "dev1", text: "x", groupType: "g")
        let other = try #require(notifier.request(notify, title: nil, text: "Hi"))
        #expect(other.url.absoluteString == "https://push.getnotifyapp.com/notify-json/dev1?token=tok")
        let body = try JSONValue(data: try #require(other.body))
        #expect(body["text"] == "Hi")
        #expect(body["groupType"] == "g")
        #expect(body["iconUrl"] == JSONValue.string(PushNotifier.notifyIcon))
        // Pushover without the user's own application token is refused when read.
        let reader = ConfigReader(logger: testLogger)
        #expect(reader.notification(["api": "PUSHOVER", "token": "u", "text": "x"], name: "X") == nil)
    }

    /// TV12: a thermostat in Fahrenheit with two modes.
    @Test func aThermostatInFahrenheit() async throws {
        let harness = await Harness([[
            "id": "t", "name": "Thermo", "type": "Thermostat", "temperatureUnits": "F", "minimumTemperature": 50, "maximumTemperature": 90,
            "validStates": ["off", "heat"], "enableWebhook": true,
        ]], now: parisDate(2026, 11, 4, 10))
        let target = try #require(harness.services["t"]?.primary[.targetTemperature])
        #expect(target.type.minValue == 10)
        #expect(abs((target.type.maxValue ?? 0) - 32.2222) < 0.001)
        #expect(harness.services["t"]?.primary[.targetHeatingCoolingState]?.type.validValues == [0, 1])
        #expect(harness.services["t"]?.primary[.currentHeatingCoolingState]?.type.validValues == [0, 1])
        let set = await harness.webhook(["id": "t", "set": "TargetTemperature", "value": "77"])
        #expect(set == .json(200, ["success": "Thermo set to 77°F"]))
        await check(abs((await harness.stored("t", "TargetTemperature")?.doubleValue ?? 0) - 25) < 1e-9)
        #expect(abs((harness.value("t", .currentTemperature)?.doubleValue ?? 0) - 25) < 1e-9)
        let range = await harness.webhook(["id": "t", "set": "TargetTemperature", "value": "95"])
        #expect(range == .error("The TargetTemperature characteristic expects a number value between 50 and 90"))
        let mode = await harness.webhook(["id": "t", "set": "TargetHeatingCoolingState", "value": "2"])
        #expect(mode == .error("Valid values for the TargetHeatingCoolingState characteristic command are: 0 (Off), 1 (Heat)"))
        _ = await harness.webhook(["id": "t", "set": "TargetHeatingCoolingState", "value": "1"])
        #expect(harness.value("t", .currentHeatingCoolingState) == .int(1))
    }

    @Test func aHumidifierFollowsItsTarget() async {
        let harness = await Harness([[
            "id": "h", "name": "Humid", "type": "HumidifierDehumidifier", "humidifierType": "dehumidifier", "enableWebhook": true,
        ]], now: parisDate(2026, 11, 4, 10))
        #expect(harness.services["h"]?.primary[.targetHumidifierDehumidifierState]?.type.validValues == [2])
        _ = await harness.engine.write("h", .threshold(40))
        #expect(harness.value("h", .currentRelativeHumidity) == .double(40))
        _ = await harness.engine.write("h", .active(1))
        #expect(harness.value("h", .currentHumidifierDehumidifierState) == .int(3))
        _ = await harness.webhook(["id": "h", "set": "CurrentRelativeHumidity", "value": "55"])
        #expect(harness.value("h", .currentRelativeHumidity) == .double(55))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DummyWebhookTests {
    let lamp: JSONValue = ["id": "3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f", "name": "Desk Lamp", "type": "Lightbulb", "isDimmer": true, "enableWebhook": true]
    let id: JSONValue = "3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f"

    /// TV2.
    @Test func theLampsWebhooks() async {
        let harness = await Harness([lamp], now: parisDate(2026, 11, 4, 10))
        await check(await harness.webhook(["id": id, "set": "On", "value": "true"]) == .json(200, ["success": "Desk Lamp is on, brightness is 100%"]))
        await check(await harness.webhook(["id": id, "set": "On", "value": "1"]) == .error("Valid values for the On characteristic command are: true, false"))
        await check(await harness.webhook(["id": id, "get": "Brightness"]) == .json(200, ["value": 100]))
        await check(await harness.webhook(["id": id, "set": "Brightness", "value": "150"])
            == .error("The Brightness characteristic expects a number value between 0 and 100"))
        await check(await harness.webhook(["id": id, "sync": "On", "value": false]) == .json(200, ["success": "Desk Lamp is off"]))
        #expect(harness.value("3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f", .on) == .bool(false))
        let unknown = await harness.webhook(["id": "nope", "set": "On", "value": "true"])
        #expect(unknown.status == 400 && unknown.body.contains("`nope`"))
        await check(await harness.webhook(["set": "On"]) == .error("Request is missing id"))
        await check(await harness.webhook(["id": id, "set": "On"]) == .error("`set` requests require a `value`"))
        await check(await harness.webhook(["id": id]).body.contains("missing a get or set command"))
        let page = await harness.webhook([:])
        #expect(page.contentType.hasPrefix("text/html"))
        #expect(page.body.components(separatedBy: "<tr><td>").count - 1 == 2)
    }

    @Test func aButtonIsPressedByWebhook() async {
        let harness = await Harness([["id": "b", "name": "Bell", "type": "StatelessProgrammableSwitch", "enableWebhook": true]], now: parisDate(2026, 11, 4, 10))
        await check(await harness.webhook(["id": "b", "set": "ProgrammableSwitchEvent", "value": "1"]) == .json(200, ["success": "Bell was double pressed"]))
        #expect(harness.value("b", .programmableSwitchEvent) == .int(1))
        await check(await harness.webhook(["id": "b", "get": "ProgrammableSwitchEvent"]) == .json(200, [:]))
    }

    @Test func requestsAreParsedAndTheTokenChecked() throws {
        let query = try #require(WebhookServer.parameters(uri: "/?id=a&set=On&value=true", contentType: nil, body: Data()))
        #expect(query == ["id": "a", "set": "On", "value": "true"])
        let json = try #require(WebhookServer.parameters(uri: "/?id=a", contentType: "application/json", body: Data(#"{"sync":"On","value":false}"#.utf8)))
        #expect(json == ["id": "a", "sync": "On", "value": false])
        #expect(WebhookServer.parameters(uri: "/", contentType: "application/json", body: Data("{oops".utf8)) == nil)
        #expect(WebhookServer.authorized([:], authorization: nil, token: nil))
        #expect(!WebhookServer.authorized([:], authorization: nil, token: "s3cret"))
        #expect(WebhookServer.authorized(["token": "s3cret"], authorization: nil, token: "s3cret"))
        #expect(WebhookServer.authorized([:], authorization: "Bearer s3cret", token: "s3cret"))
        #expect(!WebhookServer.authorized(["token": "s3cre"], authorization: nil, token: "s3cret"))
        #expect(WebhookServer.isCrossSite(["Sec-Fetch-Site": "cross-site"]))
        #expect(WebhookServer.isCrossSite(["Sec-Fetch-Site": "same-site"]))
        #expect(!WebhookServer.isCrossSite(["Sec-Fetch-Site": "same-origin", "Origin": "http://bridge.local:63743", "Host": "bridge.local:63743"]))
        #expect(WebhookServer.isCrossSite(["Origin": "https://evil.example", "Host": "192.168.1.2:63743"]))
        #expect(!WebhookServer.isCrossSite(["Host": "192.168.1.2:63743"]))
        #expect(!WebhookServer.isLoopback("0.0.0.0"))
    }

    @Test func theServerAnswersOverHTTP() async throws {
        let harness = await Harness([lamp], now: parisDate(2026, 11, 4, 10))
        let server = WebhookServer(logger: testLogger)
        let engine = harness.engine
        try await server.start(host: "127.0.0.1", port: 0, tls: nil, token: "s3cret") { await engine.webhook($0) }
        defer { Task { await server.stop() } }
        let port = try #require(server.port)
        let client = HTTPClient()
        let refused = try await client.send(HTTPRequest(url: URL(string: "http://127.0.0.1:\(port)/?id=x&get=On")!))
        #expect(refused.status == 401)
        let answer = try await client.send(HTTPRequest(
            method: "POST", url: URL(string: "http://127.0.0.1:\(port)/")!, headers: [("Content-Type", "application/json"), ("Authorization", "Bearer s3cret")],
            body: Data(#"{"id":"3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f","set":"On","value":true}"#.utf8)))
        #expect(answer.status == 200)
        #expect(String(decoding: answer.body, as: UTF8.self) == #"{"success":"Desk Lamp is on, brightness is 100%"}"#)
        let big = try await client.send(HTTPRequest(method: "POST", url: URL(string: "http://127.0.0.1:\(port)/?token=s3cret")!, body: Data(count: 70_000)))
        #expect(big.status == 413)
        let page = try await client.send(HTTPRequest(
            url: URL(string: "http://127.0.0.1:\(port)/?token=s3cret&id=3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f&set=On&value=false")!,
            headers: [("Sec-Fetch-Site", "cross-site")]))
        #expect(page.status == 403)
        #expect(harness.value("3f2c9a1e-8b7d-4c55-9e21-0a1b2c3d4e5f", .on) == .bool(true))
        await server.stop()
    }
}
