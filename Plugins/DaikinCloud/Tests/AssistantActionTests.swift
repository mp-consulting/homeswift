import Foundation
import HomeswiftPlugin
import Testing

@testable import HomeswiftDaikinCloud

/// The Assistant's tools: each one's request reaches its route of `handleWebRequest`.
@Suite(.timeLimit(.minutes(1)))
struct AssistantActionTests {
    func action(_ name: String) throws -> AssistantAction {
        try #require(DaikinCloudPlugin.assistantActions.first { $0.name == name })
    }

    func call(_ name: String, _ arguments: JSONValue = [:], on environment: DaikinEnvironment) async throws -> PluginWebResponse {
        try await environment.plugin!.handleWebRequest(action(name).request(arguments: arguments, user: "admin"))
    }

    @Test func describesTheRoutes() throws {
        let actions = DaikinCloudPlugin.assistantActions
        #expect(actions.map(\.name) == ["status", "list_devices", "rate_limit", "test_connection", "revoke"])
        #expect(Set(actions.map(\.name)).count == actions.count)
        // Only revoking changes anything; it is confirmed and needs admin.
        #expect(actions.filter(\.confirm).map(\.name) == ["revoke"])
        #expect(actions.filter { $0.access != .read }.map(\.name) == ["revoke"])
        #expect(try action("revoke").access == .configure)
        // No sign-in: Setup's.
        #expect(!actions.contains { $0.path.hasPrefix("auth/") && !["auth/status", "auth/test", "auth/revoke"].contains($0.path) })
    }

    @Test func eachActionReachesItsRoute() async throws {
        let environment = DaikinEnvironment()
        environment.tokens = (.developerPortal, DaikinEnvironment.validToken)
        let host = try await environment.start(developerBlock)
        defer { Task { await host.stop() } }

        let status = try await call("status", on: environment)
        #expect(status.json["authenticated"] == true)
        #expect(status.json["authMode"] == "developer_portal")
        #expect(status.json["session"]?["running"] == true)

        // The running instance's list costs no call; refresh fetches.
        let gets = environment.cloud.gets.withLockedValue { $0 }
        let listed = try await call("list_devices", on: environment)
        #expect(listed.json["devices"]?.arrayValue?.count == 2)
        #expect(listed.json["cached"] == true)
        #expect(environment.cloud.gets.withLockedValue { $0 } == gets)
        let refreshed = try await call("list_devices", ["refresh": true, "mode": "developer_portal"], on: environment)
        #expect(refreshed.json["cached"] == false)
        #expect(environment.cloud.gets.withLockedValue { $0 } == gets + 1)

        #expect(try await call("rate_limit", on: environment).status == 200)
        #expect(try await call("test_connection", on: environment).json["message"] == "Connection successful! Found 2 device(s).")

        let revoked = try await call("revoke", on: environment)
        #expect(revoked.json["success"] == true)
        #expect(TokenFile.load(environment.tokenFile(named: AuthMode.developerPortal.tokenFileName)) == nil)
        #expect(environment.cloud.http.all.contains { $0.url == DeveloperPortalOAuth.revokeEndpoint })
        #expect(try await call("status", on: environment).json["authenticated"] == false)
    }
}

struct AssistantBackgroundTests {
    @Test func backgroundIsAboutHomeswift() throws {
        let background = try #require(DaikinCloudPlugin.assistantBackground)
        #expect(background.count > 500)
        #expect(background.contains("Homeswift"))
        #expect(!background.contains("Homebridge"))
        // The token files the port writes, and no Node fingerprint it does not have.
        #expect(background.contains(AuthMode.mobileApp.tokenFileName) && background.contains(AuthMode.developerPortal.tokenFileName))
        #expect(!background.contains("Node"))
    }
}
