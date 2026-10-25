import Foundation
import HomeswiftAI
import Testing
@testable import HomeswiftMCP

@Suite struct WebhookAuthenticationTests {
    @Test func oldSettingsStillDecode() throws {
        let old = try JSONDecoder().decode(NotificationSettings.Webhook.self, from: Data(#"{"enabled":true,"url":"https://example.com/hook"}"#.utf8))
        #expect(old.auth == "none")
        #expect(old.headers.isEmpty)
    }

    @Test func authHeadersMaskingAndValidation() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let sender = RecordingSender()
        catalog.home.http = sender
        let response = try catalog.updateNotificationSettings(["channels": ["webhook": [
            "enabled": true, "url": "https://example.com/hook", "auth": "bearer", "token": "test-secret-token",
            "headers": ["X-API-Key": "test-header-secret", "X-Source": "homeswift"]
        ]]])
        #expect(response["channels"]?["webhook"]?["token"] == "********")
        #expect(response["channels"]?["webhook"]?["headers"]?["X-API-Key"] == "********")
        _ = try catalog.updateNotificationSettings(response)
        #expect(catalog.home.notifications.value.channels.webhook.headers["X-API-Key"] == "test-header-secret")
        _ = try await catalog.sendTestNotification(channel: .webhook)
        #expect(sender.requests.last?.header("Authorization") == "Bearer test-secret-token")
        #expect(sender.requests.last?.header("X-API-Key") == "test-header-secret")
        #expect(sender.requests.last?.header("Content-Type") == "application/json")
        _ = try catalog.updateNotificationSettings(["channels": ["webhook": ["auth": "basic", "username": "test-user", "password": " pass with spaces ", "headers": [:]]]])
        _ = try await catalog.sendTestNotification(channel: .webhook)
        let basic = "Basic " + Data("test-user: pass with spaces ".utf8).base64EncodedString()
        #expect(sender.requests.last?.header("Authorization") == basic)
        #expect(sender.requests.last?.header("X-API-Key") == nil)
        let invalidHeaders: [JSONValue] = [["Host": "other.example.com"], ["X-Bad": "a\r\nInjected: value"], ["X-Key": "one", "x-key": "two"], ["Authorization": "another"], ["New-Key": "********"]]
        for headers in invalidHeaders {
            #expect(throws: CatalogError.self) {
                try catalog.updateNotificationSettings(["channels": ["webhook": ["headers": headers]]])
            }
        }
        #expect(catalog.home.notifications.value.channels.webhook.auth == "basic")
        #expect(catalog.home.notifications.value.channels.webhook.headers.isEmpty)
        _ = try catalog.updateNotificationSettings(["channels": ["webhook": ["auth": "none", "password": "", "token": "", "headers": ["Authorization": "ApiKey custom-secret"]]]])
        _ = try await catalog.sendTestNotification(channel: .webhook)
        #expect(sender.requests.last?.header("Authorization") == "ApiKey custom-secret")
    }
}
