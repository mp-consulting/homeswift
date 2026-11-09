import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftSmartThings

/// The server-sent events (docs/clean-room/SmartThings.md, 5.1 and 15.7) and polling within the limits (5.3, 6.1).
@Suite(.timeLimit(.minutes(1)))
struct EventTests {
    static func event(_ name: String, _ data: String) -> String { "event: \(name)\ndata: \(data)\n\n" }

    static func deviceEvent(_ deviceID: String, _ component: String, _ capability: String, _ attribute: String, _ value: String, stateChange: Bool = true) -> String {
        event("DEVICE_EVENT", #"{"eventTime":1794045600123,"eventType":"DEVICE_EVENT","deviceEvent":{"eventId":"f0f0","locationId":"\#(Fixture.location)","deviceId":"\#(deviceID)","componentId":"\#(component)","capability":"\#(capability)","attribute":"\#(attribute)","value":\#(value),"valueType":"string","stateChange":\#(stateChange),"subscriptionName":"homeswift-SmartThings"}}"#)
    }

    @Test func eventsReachHomeKitAndAGoodbyeSubscribesAgain() async throws {
        // A minute is 0.6 s and no Poll*Seconds polls only every 30 minutes (18 s): every list here is the stream's.
        let environment = TestEnvironment(sse: true, scale: 0.01)
        let cloud = environment.cloud
        let host = try await environment.start(settings: TestEnvironment.block.merging(["PollSwitchesAndLightsSeconds": 0]) { $1 })
        defer { Task { await host.stop() } }
        #expect(await eventually { cloud.streamCount == 1 })

        // The subscription: one location filter, the four event types, a User-Agent; the stream opened with the same token.
        let create = try #require(cloud.sent("POST", "/v1/sse/subscriptions").first)
        #expect(create.body == [
            "name": "homeswift-SmartThings",
            "subscriptionFilters": [["type": "LOCATIONIDS", "value": [.string(Fixture.location)],
                                     "eventType": ["DEVICE_EVENT", "DEVICE_HEALTH_EVENT", "DEVICE_LIFECYCLE_EVENT", "SCENE_LIFECYCLE_EVENT"]]],
        ])
        #expect(create.userAgent?.hasPrefix("Homeswift/") == true)
        let open = try #require(cloud.sent("GET", "/v1/sse/subscriptions/\(Fixture.subscription)/stream").first)
        #expect(open.accept == "text/event-stream" && open.authorization == create.authorization && open.userAgent != nil)

        // The first list is the welcome's.
        #expect(cloud.sent("GET", "/v1/devices").isEmpty)
        cloud.push(Self.event("CONTROL_EVENT", "welcome"))
        // The remote is the list's last device: once it is there, every device is.
        #expect(await eventually { host.accessory(Fixture.remote) != nil })
        let plugin = try #require(environment.plugin)
        #expect(await plugin.sseActive)

        let lamp = try #require(host.accessory(Fixture.lamp)?.service(.lightbulb))
        cloud.push(Self.deviceEvent(Fixture.lamp, "main", "switch", "switch", #""off""#))
        #expect(await eventually { lamp[.on]?.value == .bool(false) })

        // A temperature without its unit keeps the status's: 69.8 °F.
        let thermostat = try #require(host.accessory(Fixture.thermostat)?.service(.thermostat))
        cloud.push(Self.deviceEvent(Fixture.thermostat, "main", "temperatureMeasurement", "temperature", "69.8"))
        #expect(await eventually { abs((thermostat[.currentTemperature]?.value.doubleValue ?? 0) - 21.0) < 0.01 })

        // A press repeating the last value is still a press.
        let button = try #require(host.accessory(Fixture.remote)?.service(subtype: "button1/button")?[.programmableSwitchEvent])
        let presses = NIOLockedValueBox<[Int]>([])
        let token = button.observe { change in presses.withLockedValue { $0.append(change.newValue.intValue ?? -1) } }
        defer { button.removeObserver(token) }
        cloud.push(Self.deviceEvent(Fixture.remote, "button1", "button", "button", #""pushed""#, stateChange: false))
        cloud.push(Self.deviceEvent(Fixture.remote, "button1", "button", "button", #""held""#, stateChange: true))
        #expect(await eventually { presses.withLockedValue { $0 } == [0, 2] })

        // Health: offline is No Response.
        cloud.push(Self.event("DEVICE_HEALTH_EVENT", #"{"eventTime":1794045610000,"eventType":"DEVICE_HEALTH_EVENT","deviceHealthEvent":{"deviceId":"\#(Fixture.lamp)","status":"OFFLINE","reason":"NONE"}}"#))
        #expect(await eventually { host.accessory(Fixture.lamp)?.isUnavailable == true })

        // A second welcome is a keepalive: no reconciliation.
        let listsAfter = cloud.sent("GET", "/v1/devices").count
        cloud.push(Self.event("CONTROL_EVENT", "welcome"))
        cloud.push(Self.deviceEvent(Fixture.lamp, "main", "switchLevel", "level", "30"))
        #expect(await eventually { lamp[.brightness]?.value.intValue == 30 })
        #expect(cloud.sent("GET", "/v1/devices").count == listsAfter)

        // Goodbye: the old subscription deleted, a new one created and opened, the devices read again on its welcome.
        cloud.push(Self.event("CONTROL_EVENT", "goodbye"))
        #expect(await eventually { cloud.sent("POST", "/v1/sse/subscriptions").count == 2 && cloud.streamCount == 2 })
        #expect(cloud.sent("DELETE", "/v1/sse/subscriptions/\(Fixture.subscription)").count == 1)
        cloud.push(Self.event("CONTROL_EVENT", "welcome"))
        #expect(await eventually { cloud.sent("GET", "/v1/devices").count > listsAfter })
    }

    @Test func aSilentStreamIsAGap() async throws {
        let environment = TestEnvironment(sse: true, watchdogSeconds: 300)
        let host = try await environment.start()
        defer { Task { await host.stop() } }
        // The watchdog is 5 minutes, 300 ms here: nothing at all comes.
        #expect(await eventually { environment.cloud.streamCount >= 2 })
    }

    @Test func aForbiddenStreamFallsBackToPolling() async throws {
        let environment = TestEnvironment(sse: true)
        environment.cloud.setStreamStatus(403)
        let host = try await environment.start(settings: TestEnvironment.block.merging(["PollSwitchesAndLightsSeconds": 60]) { $1 })
        defer { Task { await host.stop() } }
        let plugin = try #require(environment.plugin)
        #expect(await eventually { await plugin.eventsNote == .refused })
        #expect(await plugin.sseActive == false)
        // The devices are listed although no welcome came.
        #expect(await eventually { host.accessory(Fixture.lamp) != nil })
        // Polling goes on: 60 s here are 60 ms.
        #expect(await eventually { environment.cloud.sent("GET", "/v1/devices").count >= 4 })
    }

    /// Polling stays within its period: one device list a period, nothing per device.
    @Test func pollingStaysWithinItsPeriod() async throws {
        let environment = TestEnvironment()
        let started = ContinuousClock.now
        let host = try await environment.start(settings: TestEnvironment.block.merging(["PollSwitchesAndLightsSeconds": 10, "PollSensorsSeconds": 5]) { $1 })
        defer { Task { await host.stop() } }
        // The floor is 60 s (60 ms here), not the block's 5 s.
        // A list is its first page and the next ones.
        @Sendable func lists() -> Int { environment.cloud.sent("GET", "/v1/devices").filter { $0.query?.contains("page=") != true }.count }
        #expect(await eventually { lists() >= 5 })
        let elapsed = ContinuousClock.now - started
        let lists = lists()
        #expect(Double(lists) <= elapsed / .milliseconds(60) + 2)
        #expect(environment.cloud.sent.allSatisfy { !$0.path.hasSuffix("/status") })
    }

    /// No more than 12 status reads or command requests a minute per device (section 6.1): a minute is 500 ms here, and
    /// the 13th request of a burst waits for it.
    /// Twelve requests a minute per device, on a virtual clock that moves only when the test moves it, and only once the
    /// state it waits for is reached: how slowly the machine schedules the tasks (all of Linux's tests share one process)
    /// can delay the test but never change its counts.
    @Test func eachDeviceGetsTwelveRequestsAMinute() async throws {
        let clock = ManualClock()
        let limiter = RateLimiter(limit: 12, window: .seconds(60), clock: clock.limiterClock)
        let granted = NIOLockedValueBox<[String: Int]>([:])
        let count: @Sendable (String) -> Int = { key in granted.withLockedValue { $0[key, default: 0] } }
        let all = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<30 {
                    group.addTask { if (try? await limiter.acquire("d")) != nil { granted.withLockedValue { $0["d", default: 0] += 1 } } }
                }
                // Another device has its own twelve.
                group.addTask { if (try? await limiter.acquire("e")) != nil { granted.withLockedValue { $0["e", default: 0] += 1 } } }
            }
        }
        // At the start: twelve through, eighteen waiting for the window; the other device is not held up.
        _ = await eventually(timeout: .seconds(60)) { count("d") == 12 && clock.sleepers == 18 && count("e") == 1 }
        #expect(count("d") == 12)
        #expect(clock.sleepers == 18)
        #expect(count("e") == 1)
        // A window later: twelve more, six still waiting.
        clock.advance(by: .seconds(60))
        _ = await eventually(timeout: .seconds(60)) { count("d") == 24 && clock.sleepers == 6 }
        #expect(count("d") == 24)
        #expect(clock.sleepers == 6)
        // A second short of the next window: nothing more.
        clock.advance(by: .seconds(59))
        #expect(count("d") == 24)
        #expect(clock.sleepers == 6)
        clock.advance(by: .seconds(1))
        await all.value
        #expect(count("d") == 30)
        #expect(await limiter.waits == 24)
    }

    /// The API reads a device's status through its limiter: the thirteenth read of a minute waits for the window.
    @Test func statusReadsGoThroughTheDeviceLimiter() async throws {
        let cloud = FakeSmartThings()
        cloud.answer("GET", "/v1/devices/d/status", ["components": [:]])
        let clock = ManualClock()
        let limiter = RateLimiter(limit: 12, window: .seconds(60), clock: clock.limiterClock)
        let api = try await TestAPI.make(cloud, limiter: limiter)
        let sent: @Sendable () -> Int = { cloud.sent("GET", "/v1/devices/d/status").count }
        let all = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<13 { group.addTask { _ = try? await api.status(deviceID: "d") } }
            }
        }
        _ = await eventually(timeout: .seconds(60)) { sent() == 12 && clock.sleepers == 1 }
        #expect(sent() == 12)
        #expect(clock.sleepers == 1)
        clock.advance(by: .seconds(60))
        await all.value
        #expect(sent() == 13)
    }

    /// A 429 backs off the whole plugin: reads are not sent until it passes.
    @Test func aRateLimitStopsReadsForItsReset() async throws {
        let cloud = FakeSmartThings()
        cloud.answer("GET", "/v1/devices/d/status", status: 429, headers: [("X-RateLimit-Reset", "60")])
        cloud.answer("GET", "/v1/devices/d/status", ["components": [:]])
        // The API's clock stands still until the test moves it: a loaded runner cannot let the 60 s (60 ms here) pass early.
        let ahead = NIOLockedValueBox<Duration>(.zero)
        let api = try await TestAPI.make(cloud, ahead: ahead)
        await #expect(throws: SmartThingsError.self) { _ = try await api.status(deviceID: "d") }
        await #expect(throws: SmartThingsError.rateLimited(path: "devices/d/status")) { _ = try await api.status(deviceID: "d") }
        #expect(cloud.sent("GET", "/v1/devices/d/status").count == 1)
        ahead.withLockedValue { $0 = .seconds(1) }
        #expect((try? await api.status(deviceID: "d")) != nil)
    }

    @Test func a401IsRefreshedOnceAndRetried() async throws {
        let cloud = FakeSmartThings()
        cloud.answer("GET", "/v1/devices/d/status", status: 401)
        cloud.answer("GET", "/v1/devices/d/status", ["components": [:]])
        let api = try await TestAPI.make(cloud) { _ in try #require(TokenResponse(["access_token": "fresh", "refresh_token": "r2", "expires_in": 86399])) }
        _ = try await api.status(deviceID: "d")
        #expect(cloud.sent("GET", "/v1/devices/d/status").map(\.authorization) == ["Bearer access", "Bearer fresh"])
    }
}

/// A clock that moves only when the test says: sleepers wake when it reaches their time.
final class ManualClock: Sendable {
    private struct State {
        var now: Duration = .zero
        var sleepers: [(until: Duration, wake: CheckedContinuation<Void, Never>)] = []
    }
    private let state = NIOLockedValueBox(State())

    var sleepers: Int { state.withLockedValue { $0.sleepers.count } }

    var limiterClock: LimiterClock {
        LimiterClock(now: { [self] in state.withLockedValue { $0.now } }, sleep: { [self] duration in await sleep(duration) })
    }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
            let now = state.withLockedValue { state -> Bool in
                guard duration > .zero else { return true }
                state.sleepers.append((state.now + duration, wake))
                return false
            }
            if now { wake.resume() }
        }
    }

    func advance(by duration: Duration) {
        let woken = state.withLockedValue { state -> [CheckedContinuation<Void, Never>] in
            state.now += duration
            let due = state.sleepers.filter { $0.until <= state.now }
            state.sleepers.removeAll { $0.until <= state.now }
            return due.map(\.wake)
        }
        for wake in woken { wake.resume() }
    }
}
