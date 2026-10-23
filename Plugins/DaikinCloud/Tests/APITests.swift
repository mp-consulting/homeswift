import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftDaikinCloud

/// The Homebridge plugin's DaikinApi tests: refreshes, rate limits, gateway errors, the write queue.
@Suite(.timeLimit(.minutes(1)))
struct APITests {
    let devices: JSONValue = [["id": "device-1", "managementPoints": []]]
    let sleeps = NIOLockedValueBox<[Duration]>([])

    /// An API that does not wait: retries and write gaps are recorded instead.
    /// Held write gaps: the queue stands still until the test fires it.
    let gate = Signal()

    func api(_ http: FakeHTTP, oauth: FakeOAuth = FakeOAuth(), onRateLimit: @escaping @Sendable (RateLimitStatus) -> Void = { _ in }, gap: Bool = false) -> DaikinAPI {
        let sleeps = sleeps, gate = gate
        var dependencies = DaikinAPI.Dependencies()
        dependencies.sleep = { duration in
            sleeps.withLockedValue { $0.append(duration) }
            if gap, duration == DaikinAPI.writeGap { await gate.wait() }
        }
        dependencies.random = { 0.5 }
        return DaikinAPI(oauth: oauth, http: DaikinHTTP(transport: http), dependencies: dependencies, onRateLimit: onRateLimit)
    }

    @Test func devicesWithAToken() async throws {
        let http = FakeHTTP { _, _ in .json([["id": "device-1", "managementPoints": []]]) }
        let result = try await api(http).devices()
        #expect(result == devices.arrayValue)
        let request = try #require(http.all.first)
        #expect(request.header("Authorization") == "Bearer valid-token")
        #expect(request.header("User-Agent") == "okhttp/4.12.0")
        #expect(request.url.absoluteString == "https://api.onecta.daikineurope.com/v1/gateway-devices")
    }

    @Test func refreshesOn401AndRetries() async throws {
        let oauth = FakeOAuth()
        await oauth.set(tokens: ["expired-token", "new-token"])
        let devices = devices
        let http = FakeHTTP { _, index in index == 1 ? .text("Unauthorized", status: 401) : .json(devices) }
        #expect(try await api(http, oauth: oauth).devices() == devices.arrayValue)
        #expect(await oauth.refreshes == 1)
        #expect(http.count == 2)
    }

    @Test func aFailedRefreshAsksToAuthenticateAgain() async throws {
        let oauth = FakeOAuth()
        await oauth.set(refreshError: DaikinError("Refresh failed"))
        let http = FakeHTTP { _, _ in .text("Unauthorized", status: 401) }
        await #expect(throws: DaikinError("Unauthorized (401): Token refresh failed. Please re-authenticate.")) { try await api(http, oauth: oauth).devices() }
        #expect(await oauth.refreshes == 1)
    }

    @Test func givesUpAfterThreeRefreshes() async throws {
        let oauth = FakeOAuth()
        let http = FakeHTTP { _, _ in .text("Unauthorized", status: 401) }
        await #expect(throws: DaikinError("Unauthorized (401): Token expired or invalid")) { try await api(http, oauth: oauth).devices() }
        #expect(await oauth.refreshes == DaikinAPI.maxRetries)
        #expect(http.count == DaikinAPI.maxRetries + 1)
    }

    @Test func concurrent401sShareOneRefresh() async throws {
        let oauth = FakeOAuth()
        await oauth.set(tokens: ["expired-token", "expired-token", "new-token"])
        let release = Signal()
        await oauth.set(refreshGate: { await release.wait() })
        let devices = devices
        let http = FakeHTTP { _, index in index <= 2 ? .text("Unauthorized", status: 401) : .json(devices) }
        let api = api(http, oauth: oauth)
        async let first = api.devices()
        async let second = api.devices()
        #expect(await eventually { http.count >= 2 })
        release.fire()
        _ = try await (first, second)
        #expect(await oauth.refreshes == 1)
    }

    @Test func blocksAfterA429() async throws {
        let http = FakeHTTP { _, _ in .text("Too Many Requests", status: 429, headers: [("retry-after", "60")]) }
        let api = api(http)
        await #expect(throws: RateLimitedError.self) { try await api.devices() }
        #expect(await api.isRateLimited)
        http.set { _, _ in .json([]) }
        do {
            _ = try await api.devices()
            Issue.record("a blocked request went out")
        } catch let error as RateLimitedError {
            #expect(error.message.hasPrefix("API request blocked due to rate limit"))
        }
        #expect(http.count == 1)
    }

    @Test(arguments: [502, 503, 504])
    func pollsAreNotRetriedOnGatewayErrors(_ status: Int) async throws {
        let http = FakeHTTP { _, index in index == 1 ? .text("Gateway error", status: status) : .json([]) }
        do {
            _ = try await api(http).devices()
            Issue.record("no error")
        } catch let error as APIUnavailableError {
            #expect(error.statusCode == status)
            #expect(error.attemptsMade == 1)
        }
        #expect(http.count == 1)
    }

    @Test func discoveryRetriesGatewayErrors() async throws {
        let devices = devices
        let http = FakeHTTP { _, index in index == 1 ? .text("Gateway error", status: 504) : .json(devices) }
        #expect(try await api(http).devices(retryGatewayErrors: true) == devices.arrayValue)
        #expect(http.count == 2)
    }

    @Test(arguments: [502, 503, 504])
    func writesAreRetriedOnGatewayErrors(_ status: Int) async throws {
        let http = FakeHTTP { _, index in index == 1 ? .text("Gateway error", status: status) : .text("", status: 204) }
        try await api(http).updateDevice("device-1", embeddedID: "climateControl", dataPoint: "onOffMode", value: "on", path: nil)
        #expect(http.count == 2)
    }

    @Test func holidayModeIsRetriedOnGatewayErrors() async throws {
        let http = FakeHTTP { _, index in index == 1 ? .text("Gateway error", status: 503) : .text("", status: 204) }
        try await api(http).setHolidayMode("device-1", embeddedID: "climateControl", enabled: true, startDate: nil, endDate: nil)
        #expect(http.count == 2)
        #expect(http.all.last?.bodyJSON == ["enabled": true])
    }

    @Test(arguments: [(502, "Bad Gateway"), (503, "Service Unavailable"), (504, "Gateway Timeout")])
    func writesGiveUpAfterTheRetries(_ status: Int, _ name: String) async throws {
        let http = FakeHTTP { _, _ in .text("Gateway error", status: status) }
        do {
            try await api(http).updateDevice("device-1", embeddedID: "climateControl", dataPoint: "onOffMode", value: "on", path: nil)
            Issue.record("no error")
        } catch let error as APIUnavailableError {
            #expect(error.statusCode == status)
            #expect(error.attemptsMade == DaikinAPI.maxRetries + 1)
            #expect(error.message.contains(name))
            #expect(error.message.contains(String(status)))
        }
        #expect(http.count == DaikinAPI.maxRetries + 1)
    }

    @Test func queuedWritesToOneTargetCoalesce() async throws {
        let http = FakeHTTP { _, _ in .text("", status: 204) }
        let api = api(http, gap: true)
        async let first: Void = api.updateDevice("device-1", embeddedID: "climateControl", dataPoint: "temperatureControl", value: 20, path: "/a")
        #expect(await eventually { http.count == 1 })
        // These queue behind the first for the same target: the last value wins, one request.
        let second = Task { try await api.updateDevice("device-1", embeddedID: "climateControl", dataPoint: "temperatureControl", value: 21, path: "/a") }
        try await Task.sleep(for: .milliseconds(20))
        let third = Task { try await api.updateDevice("device-1", embeddedID: "climateControl", dataPoint: "temperatureControl", value: 22, path: "/a") }
        try await Task.sleep(for: .milliseconds(20))
        gate.fire()
        _ = try await (first, second.value, third.value)
        #expect(http.count == 2)
        #expect(http.all.map(\.bodyJSON) == [["value": 20, "path": "/a"], ["value": 22, "path": "/a"]])
        #expect(http.all.allSatisfy { $0.method == "PATCH" && $0.header("Content-Type") == "application/json" })
    }

    @Test func writesToDifferentTargetsDoNotCoalesce() async throws {
        let http = FakeHTTP { _, _ in .text("", status: 204) }
        let api = api(http)
        async let a: Void = api.updateDevice("device-1", embeddedID: "climateControl", dataPoint: "onOffMode", value: "on", path: nil)
        async let b: Void = api.updateDevice("device-1", embeddedID: "climateControl", dataPoint: "temperatureControl", value: 21, path: "/a")
        async let c: Void = api.updateDevice("device-1", embeddedID: "climateControl", dataPoint: "temperatureControl", value: 22, path: "/b")
        _ = try await (a, b, c)
        #expect(http.count == 3)
    }

    @Test func coalescedWritesShareTheError() async throws {
        let http = FakeHTTP { _, _ in .text("{}", status: 400) }
        let api = api(http, gap: true)
        let first = Task { try await api.updateDevice("device-1", embeddedID: "climateControl", dataPoint: "onOffMode", value: "on", path: nil) }
        #expect(await eventually { http.count == 1 })
        let second = Task { try await api.updateDevice("device-1", embeddedID: "climateControl", dataPoint: "onOffMode", value: "off", path: nil) }
        try await Task.sleep(for: .milliseconds(20))
        let third = Task { try await api.updateDevice("device-1", embeddedID: "climateControl", dataPoint: "onOffMode", value: "on", path: nil) }
        try await Task.sleep(for: .milliseconds(20))
        gate.fire()
        for task in [first, second, third] { await #expect(throws: DaikinError.self) { try await task.value } }
        #expect(http.count == 2)
        #expect(http.all.last?.bodyJSON == ["value": "on"])
    }

    @Test func keepsAGapBetweenWritesToADevice() async throws {
        let http = FakeHTTP { _, _ in .text("", status: 204) }
        let api = api(http)
        try await api.updateDevice("device-1", embeddedID: "climateControl", dataPoint: "onOffMode", value: "on", path: nil)
        try await api.updateDevice("device-1", embeddedID: "climateControl", dataPoint: "operationMode", value: "cooling", path: nil)
        #expect(sleeps.withLockedValue { $0 } == [DaikinAPI.writeGap, DaikinAPI.writeGap])
    }

    @Test func reportsTheQuotaWhenTheAnswerHasIt() async throws {
        let reports = NIOLockedValueBox<[RateLimitStatus]>([])
        let http = FakeHTTP { _, _ in .json([], headers: [("x-ratelimit-remaining-day", "0"), ("x-ratelimit-limit-day", "200")]) }
        let api = api(http) { status in reports.withLockedValue { $0.append(status) } }
        _ = try await api.devices()
        #expect(reports.withLockedValue { $0 } == [RateLimitStatus(limitDay: 200, remainingDay: 0)])
        http.set { _, _ in .json([]) }
        _ = try await api.devices()
        #expect(reports.withLockedValue { $0.count } == 1)
    }

    @Test func badRequestsInWords() async throws {
        let cases: [(String, [String])] = [
            (#"{"code":"READ_ONLY_CHARACTERISTIC","message":"Characteristic is read-only and therefore can not be set"}"#, ["temporarily read-only", "powered off, updating its firmware"]),
            (#"{"code":"INVALID_VALUE"}"#, ["Bad Request (400)", "INVALID_VALUE"]),
            ("<html>WAF error page</html>", ["Bad Request (400)"]),
        ]
        for (body, expected) in cases {
            let http = FakeHTTP { _, _ in .text(body, status: 400) }
            do {
                try await api(http).updateDevice("device-1", embeddedID: "climateControl", dataPoint: "onOffMode", value: "on", path: nil)
                Issue.record("no error")
            } catch let error as DaikinError {
                for text in expected { #expect(error.message.contains(text)) }
            }
        }
    }

    @Test func cloudIdsCannotChangeTheEndpoint() async throws {
        let http = FakeHTTP { _, _ in .text("", status: 204) }
        let api = api(http)
        try await api.updateDevice("dev/../x", embeddedID: "mp?y=1", dataPoint: "name#z", value: "v", path: nil)
        try await api.setHolidayMode("dev/1", embeddedID: "mp/2", enabled: true, startDate: nil, endDate: nil)
        try await api.triggerFirmwareUpdate("dev/1", embeddedID: "gateway", firmwareID: "fw/../../evil?a")
        #expect(http.all.map { $0.url.absoluteString.replacingOccurrences(of: DaikinAPI.baseURL, with: "") } == [
            "/v1/gateway-devices/dev%2F..%2Fx/management-points/mp%3Fy%3D1/characteristics/name%23z",
            "/v1/gateway-devices/dev%2F1/management-points/mp%2F2/holiday-mode",
            "/v1/gateway-devices/dev%2F1/management-points/gateway/firmware/fw%2F..%2F..%2Fevil%3Fa",
        ])
        #expect(http.all[2].method == "PUT")
        #expect(http.all[2].body == nil)
    }

    @Test func settingsPageReads() async throws {
        let http = FakeHTTP { _, _ in .json([["id": "a"]], headers: [("X-RateLimit-Remaining-Day", "180"), ("X-RateLimit-Limit-Day", "200")]) }
        let (data, limit) = try await DaikinAPI.get("/v1/gateway-devices", accessToken: "t", http: DaikinHTTP(transport: http))
        #expect(data?.arrayValue?.count == 1)
        #expect(limit == RateLimitStatus(limitDay: 200, remainingDay: 180))
        for (status, message) in [(401, "Token expired or invalid"), (429, "Rate limit exceeded"), (500, "API error: 500")] {
            http.set { _, _ in .text("", status: status) }
            await #expect(throws: DaikinError(message)) { try await DaikinAPI.get("/v1/gateway-devices", accessToken: "t", http: DaikinHTTP(transport: http)) }
        }
    }
}
