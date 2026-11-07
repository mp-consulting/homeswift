import Foundation
import HomeswiftAI
import HomeswiftPlugin
import Testing
@testable import HomeswiftMCP

/// Home Time and the Home Language (GLOSSARY.md): the Bridge Settings, and notifications in the reader's language.
@Suite struct LanguageAndRegionTests {
    @Test func notificationTextsHaveEveryLanguageAndTheirPlaceholders() {
        let placeholders = { (text: String) in Set(text.matches(of: /\{\w+\}/).map { String($0.output) }) }
        for (english, translations) in NotificationTexts.strings {
            for language in ["fr", "es", "pt"] {
                let translated = translations[language]
                #expect(translated?.isEmpty == false, "\(english) has no \(language)")
                #expect(translated.map(placeholders) == placeholders(english), "\(english) in \(language)")
            }
        }
    }

    @Test func textsFillTheirValuesInTheLanguageAsked() {
        let offline = NotificationText("{name} is not responding", ["name": "Desk Lamp"])
        #expect(offline.text(in: "en") == "Desk Lamp is not responding")
        #expect(offline.text(in: "fr") == "Desk Lamp ne répond pas")
        // A language the catalog does not have, and words that are not the bridge's own, stay as they are.
        #expect(offline.text(in: "de") == "Desk Lamp is not responding")
        #expect(NotificationText.literal("Daily digest").text(in: "fr") == "Daily digest")
        #expect(NotificationText("Daily digest").text(in: "pt") == "Resumo diário")
        // A value is put in once: braces in a name are not filled again.
        let failed = NotificationText("Steps {steps} failed. Trigger: {trigger}.", ["steps": "{trigger}", "trigger": "time"])
        #expect(failed.text(in: "en") == "Steps {trigger} failed. Trigger: time.")
    }

    @Test func languagesAndZonesResolve() throws {
        #expect(HomeLanguage.resolve("fr-CA") == "fr")
        #expect(HomeLanguage.resolve("pt_BR") == "pt")
        #expect(HomeLanguage.resolve("de") == "en")
        #expect(HomeLanguage.resolve(nil) == "en")
        #expect(HomeTime.isValid("Europe/Paris"))
        #expect(!HomeTime.isValid("Mars/Olympus"))
        #expect(!HomeTime.isValid(""))
        let winter = try #require(ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z"))
        #expect(HomeTime.isUniversal(try #require(TimeZone(identifier: "UTC")), at: winter))
        // London is at UTC's offset in winter, but changes for summer.
        #expect(!HomeTime.isUniversal(try #require(TimeZone(identifier: "Europe/London")), at: winter))
    }

    @Test func bridgeSettingsCheckHomeTimeAndTheHomeLanguage() async throws {
        let environment = try MCPTestEnvironment()
        let client = DirectClient(server: environment.server)
        try await client.initialize()
        let zone = try await client.tool("update_bridge_settings", ["settings": ["timeZone": "Europe/Paris"], "dryRun": true])
        #expect(zone["structuredContent"]?["changes"] == ["bridge.timeZone"])
        #expect(try await client.tool("update_bridge_settings", ["settings": ["timeZone": "Mars/Olympus"], "dryRun": true])["isError"] == true)
        #expect(try await client.tool("update_bridge_settings", ["settings": ["language": "de"], "dryRun": true])["isError"] == true)
        let settings = try environment.catalog.bridgeSettingsJSON()
        #expect(settings["timeZone"]?.stringValue == TimeZone.current.identifier)
        #expect(settings["language"] == "en")
    }

    @Test func sharedChannelsSpeakTheHomeLanguageAdoptedFromTheFirstAccount() async throws {
        let environment = try MCPTestEnvironment()
        try await environment.start()
        defer { Task { await environment.stop() } }
        let catalog = environment.catalog
        let sender = RecordingSender()
        catalog.home.http = sender
        _ = try catalog.updateNotificationSettings(["channels": ["webhook": ["enabled": true, "url": "https://example.com/hook"]]])

        _ = try await catalog.sendTestNotification(channel: .webhook)
        let english = try JSONValue(data: try #require(sender.requests.last?.body))
        #expect(english["title"]?.stringValue?.hasSuffix(": Test notification") == true)

        await catalog.adoptHomeLanguage("fr")
        #expect(catalog.host.configuration.homeLanguage == "fr")
        #expect(try catalog.readConfig()["bridge"]?["language"] == "fr")
        _ = try await catalog.sendTestNotification(channel: .webhook)
        let french = try JSONValue(data: try #require(sender.requests.last?.body))
        #expect(french["title"]?.stringValue?.hasSuffix(": Notification de test") == true)
        #expect(french["message"] == "Les notifications de Homeswift fonctionnent.")

        // Once named, a later account does not change it.
        await catalog.adoptHomeLanguage("es")
        #expect(catalog.host.configuration.homeLanguage == "fr")
    }
}
