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
        #expect(await eventually { host.accessory(Fixture.lamp) != nil })
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
    @Test func eachDeviceGetsTwelveRequestsAMinute() async throws {
        let cloud = FakeSmartThings()
        cloud.answer("GET", "/v1/devices/d/status", ["components": [:]])
        cloud.answer("GET", "/v1/devices/e/status", ["components": [:]])
        let window = Duration.milliseconds(500)
        let limiter = RateLimiter(limit: 12, window: window)
        let api = try await TestAPI.make(cloud, limiter: limiter)
        let started = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { _ = try? await api.status(deviceID: "d") } }
            // Another device has its own twelve.
            group.addTask { _ = try? await api.status(deviceID: "e") }
        }
        let times = cloud.sent("GET", "/v1/devices/d/status").map(\.at).sorted()
        #expect(times.count == 30)
        #expect(await limiter.waits >= 18)
        // Thirty requests need two waits of a window; a request's send may lag its slot by the scheduler's jitter.
        #expect(times[29] - started >= window * 2 - .milliseconds(20))
        // At most twelve before the first window ends and 24 before the second: a send lagging its slot only comes later,
        // so the counts hold however busy the machine is.
        #expect(times.filter { $0 < started + window }.count <= 12)
        #expect(times.filter { $0 < started + window * 2 }.count <= 24)
        #expect(cloud.sent("GET", "/v1/devices/e/status").count == 1)
    }

    /// A 429 backs off the whole plugin: reads are not sent until it passes.
    @Test func aRateLimitStopsReadsForItsReset() async throws {
        let cloud = FakeSmartThings()
        cloud.answer("GET", "/v1/devices/d/status", status: 429, headers: [("X-RateLimit-Reset", "60")])
        cloud.answer("GET", "/v1/devices/d/status", ["components": [:]])
        let api = try await TestAPI.make(cloud)
        await #expect(throws: SmartThingsError.self) { _ = try await api.status(deviceID: "d") }
        await #expect(throws: SmartThingsError.rateLimited(path: "devices/d/status")) { _ = try await api.status(deviceID: "d") }
        #expect(cloud.sent("GET", "/v1/devices/d/status").count == 1)
        // 60 s are 60 ms here.
        #expect(await eventually { (try? await api.status(deviceID: "d")) != nil })
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
