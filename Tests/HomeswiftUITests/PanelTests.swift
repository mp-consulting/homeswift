import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftUI

/// An OpenAI-compatible server in memory: every request gets "All is well.", in two pieces when streamed. With
/// `hold`, a stream sends its first piece and then waits until it is cancelled.
final class CannedModel: HTTPTransport, @unchecked Sendable {
    private let lock = NIOLock()
    private var bodies: [String] = []
    let hold: Bool

    init(hold: Bool = false) { self.hold = hold }

    /// What each request sent, as text.
    var sent: [String] { lock.withLock { bodies } }

    private func record(_ request: HTTPRequest) { lock.withLock { bodies.append(String(decoding: request.body, as: UTF8.self)) } }

    func post(_ request: HTTPRequest) async throws -> HTTPResponse {
        record(request)
        let body = #"{"model":"llama3.1","choices":[{"index":0,"message":{"role":"assistant","content":"All is well."},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":4}}"#
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(body.utf8))
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        record(request)
        let hold = hold
        return HTTPStream(status: 200, headers: ["content-type": "text/event-stream"], body: AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(Data((#"data: {"model":"llama3.1","choices":[{"index":0,"delta":{"content":"All "}}]}"# + "\n\n").utf8))
                if hold { try? await Task.sleep(for: .seconds(60)) }
                continuation.yield(Data((#"data: {"model":"llama3.1","choices":[{"index":0,"delta":{"content":"is well."},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":4}}"# + "\n\n").utf8))
                continuation.yield(Data("data: [DONE]\n\n".utf8))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        })
    }
}

/// Server-sent events as (event, data) pairs.
func events(_ body: String) -> [(String, JSONValue)] {
    body.components(separatedBy: "\n\n").compactMap { frame in
        let lines = frame.split(separator: "\n")
        guard let event = lines.first(where: { $0.hasPrefix("event: ") })?.dropFirst(7),
              let data = lines.first(where: { $0.hasPrefix("data: ") })?.dropFirst(6), let json = try? JSONValue(string: String(data)) else { return nil }
        return (String(event), json)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct PanelTests {
    /// explain and ask answer as JSON, or streamed with a requestId; ask carries the plugin's background; Log Doctor
    /// reads the lines it is given.
    @Test func streamsTheAssistantsAnswers() async throws {
        let model = CannedModel()
        let environment = try UITestEnvironment(auth: .none, model: model)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        #expect(try await browser.get("/api/assistant").json?["enabled"] == true)

        let plain = try await browser.post("/api/assistant/explain", ["error": "Could not reach the lamp at 192.168.1.50"])
        #expect(plain.json?["text"] == "All is well.")
        #expect(plain.json?["usage"]?["outputTokens"] == 4)
        #expect(!model.sent.joined().contains("192.168.1.50"))   // addresses stay home

        let streamed = try await browser.post("/api/assistant/ask", ["prompt": "Why is the lamp slow?", "plugin": "Lamps", "requestId": "q1"])
        #expect(streamed.headers["content-type"] == "text/event-stream")
        let frames = events(streamed.body)
        #expect(frames.map(\.0) == ["start", "chunk", "chunk", "done"])
        #expect(frames.first?.1["requestId"] == "q1")
        #expect(frames.filter { $0.0 == "chunk" }.compactMap { $0.1["text"]?.stringValue }.joined() == "All is well.")
        #expect(frames.last?.1["text"] == "All is well.")
        #expect(model.sent.last?.contains("Lamps Plugin") == true)   // the plugin's background went along

        let diagnosis = try await browser.post("/api/assistant/diagnose", ["lines": ["[Lamps] Lamp unreachable", "", "[Lamps] Lamp timed out"], "focus": "the lamp"])
        #expect(diagnosis.json?["lines"] == 2)
        #expect(model.sent.last?.contains("Lamp timed out") == true)
        #expect(try await browser.post("/api/assistant/diagnose", ["lines": []]).status == 400)
        #expect(try await browser.post("/api/assistant/ask", ["prompt": " "]).status == 400)
        #expect(try await browser.post("/api/assistant/cancel", ["requestId": "nothing"]).json?["cancelled"] == false)
        // Usage counts for the user (auth none: "local").
        let usage = try await browser.get("/api/assistant/usage")
        #expect(usage.json?["usage"]?["today"]?["requests"] == 3)
        #expect(usage.json?["usage"]?["byUser"]?["today"]?["local"]?["requests"] == 3)
    }

    /// A streamed request stops on cancel, with an error event, and the next one runs.
    @Test func cancelsAStreamedRequest() async throws {
        let environment = try UITestEnvironment(auth: .none, model: CannedModel(hold: true))
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        async let answer = browser.post("/api/assistant/explain", ["error": "boom", "requestId": "slow"])
        var cancelled = false
        for _ in 0..<50 where !cancelled {
            try await Task.sleep(for: .milliseconds(50))
            cancelled = try await browser.post("/api/assistant/cancel", ["requestId": "slow"]).json?["cancelled"] == true
        }
        #expect(cancelled)
        let frames = events(try await answer.body)
        #expect(frames.last?.0 == "error")
        #expect(frames.last?.1["status"] == 499)
    }

    /// The digest is written on demand, kept for the day owner-only, and given back from then on.
    @Test func keepsTheDigestForTheDay() async throws {
        let environment = try UITestEnvironment(auth: .none, model: CannedModel())
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        environment.logs.append(LogBuffer.Line(level: .error, label: "Lamps", text: "Desk Lamp unreachable"))
        let browser = Browser(base: base)
        #expect(try await browser.get("/api/assistant/digest").json?["text"] == .null)
        let written = try await browser.post("/api/assistant/digest", [:])
        #expect(written.json?["text"] == "All is well.")
        #expect(written.json?["cached"] == false)
        let kept = try await browser.get("/api/assistant/digest")
        #expect(kept.json?["text"] == "All is well.")
        #expect(kept.json?["cached"] == true)
        let file = environment.directory.appendingPathComponent(HomeswiftCatalog.digestFileName)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
    }

    /// Test connection with the saved block and with the form's, and its failure in words.
    @Test func testsTheConnection() async throws {
        let environment = try UITestEnvironment(auth: .none, model: CannedModel())
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        let saved = try await browser.post("/api/assistant/test", [:])
        #expect(saved.json?["ok"] == true)
        #expect(saved.json?["model"] == "llama3.1")
        let bad = try await browser.post("/api/assistant/test", ["block": ["platform": "HomeswiftAiKit", "provider": "nonsense"]])
        #expect(bad.json?["ok"] == false)
        #expect(bad.json?["message"]?.stringValue?.isEmpty == false)
    }

    /// Each user's appearance and dashboard, checked, kept in ui-preferences.json, and a wallpaper of their own.
    @Test func keepsEachUsersPreferences() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        let defaults = try await browser.get("/api/preferences")
        #expect(defaults.json?["theme"] == "auto")
        #expect(defaults.json?["temperatureUnit"] == "c")
        #expect(defaults.json?["language"] == "auto")
        #expect(try await browser.put("/api/preferences", ["language": "pt"]).json?["language"] == "pt")
        #expect(try await browser.put("/api/preferences", ["language": "de"]).status == 400)
        let changed = try await browser.put("/api/preferences", ["theme": "dark", "temperatureUnit": "f", "dashboard": ["order": ["activity", "overview"], "hidden": ["system"]]])
        #expect(changed.json?["theme"] == "dark")
        #expect(changed.json?["dashboard"]?["hidden"] == ["system"])
        #expect(try await browser.put("/api/preferences", ["theme": "purple"]).status == 400)
        #expect(try await browser.put("/api/preferences", ["colour": "red"]).status == 400)
        #expect(try await browser.put("/api/preferences", ["dashboard": ["order": ["../etc"]]]).status == 400)
        let url = environment.directory.appendingPathComponent("ui-preferences.json")
        #expect(PreferencesStore(url: url).preferences(for: "local")["temperatureUnit"] == "f")
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)

        #expect(try await browser.get("/api/preferences/wallpaper").status == 404)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: 64)
        let set = try await browser.put("/api/preferences/wallpaper", ["data": .string(png.base64EncodedString())])
        #expect(set.json?["wallpaper"] == "custom")
        let image = try await browser.get("/api/preferences/wallpaper")
        #expect(image.headers["content-type"] == "image/png")
        #expect(try await browser.put("/api/preferences/wallpaper", ["data": .string(Data("<svg/>".utf8).base64EncodedString())]).status == 400)
        let removed = try await browser.send("DELETE", "/api/preferences/wallpaper")
        #expect(removed.json?["wallpaper"] == "none")
        #expect(try await browser.get("/api/preferences/wallpaper").status == 404)

        // Several images: each added one is shown, any can be chosen again, and removing the one shown leaves none.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 1, count: 64)
        let first = try await browser.put("/api/preferences/wallpaper", ["data": .string(png.base64EncodedString())]).json
        let second = try await browser.put("/api/preferences/wallpaper", ["data": .string(jpeg.base64EncodedString())]).json
        let ids = second?["wallpaperImages"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(ids.count == 2)
        #expect(second?["wallpaperImage"]?.stringValue == ids.last)
        #expect(try await browser.get("/api/preferences/wallpaper").headers["content-type"] == "image/jpeg")
        #expect(try await browser.get("/api/preferences/wallpaper/\(ids[0])").headers["content-type"] == "image/png")
        let chosen = try await browser.put("/api/preferences", ["wallpaper": "custom", "wallpaperImage": .string(ids[0])])
        #expect(chosen.json?["wallpaperVersion"]?.stringValue == ids[0])
        #expect(try await browser.get("/api/preferences/wallpaper").headers["content-type"] == "image/png")
        #expect(try await browser.put("/api/preferences", ["wallpaperImage": "zzz"]).status == 400)
        #expect(try await browser.get("/api/preferences/wallpaper/x.png").status == 404)
        let kept = try await browser.send("DELETE", "/api/preferences/wallpaper/\(ids[1])")
        #expect(kept.json?["wallpaperImages"] == [.string(ids[0])])
        #expect(kept.json?["wallpaper"] == "custom")
        let gone = try await browser.send("DELETE", "/api/preferences/wallpaper/\(ids[0])")
        #expect(gone.json?["wallpaper"] == "none")
        #expect(gone.json?["wallpaperImages"] == [])
        #expect(first?["wallpaper"] == "custom")

        // The single image an earlier version kept, a file named after the user, moves into the user's folder.
        let store = PreferencesStore(url: url)
        let legacy = store.wallpaperFolder(for: "old")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: legacy)
        #expect(store.wallpaperIDs(for: "old") == ["0"])
        #expect(store.wallpaper(for: "old", id: "0")?.type == "image/png")
    }

    /// The log as a file, and emptied.
    @Test func downloadsAndEmptiesTheLog() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        environment.logs.append(LogBuffer.Line(level: .warning, label: "Lamps", text: "Desk Lamp slow"))
        let browser = Browser(base: base)
        let file = try await browser.get("/api/logs/download")
        #expect(file.headers["content-disposition"]?.hasPrefix("attachment; filename=\"homeswift-") == true)
        #expect(file.headers["content-type"] == "text/plain; charset=utf-8")
        #expect(file.body.contains("[Lamps] [WARNING] Desk Lamp slow"))
        let range = try await browser.get("/api/logs/download?from=2001-01-01T00:00:00Z&to=2001-01-02T00:00:00Z")
        #expect(!range.body.contains("Desk Lamp"))
        #expect(try await browser.post("/api/logs/truncate", [:]).json?["truncated"] == true)
        #expect(try await browser.get("/api/logs").json?.arrayValue?.contains { $0["text"] == "Desk Lamp slow" } == false)
    }

    /// The chat's conversations: New chat files the current one away, it opens again with its messages, and goes.
    @Test func keepsEarlierChats() async throws {
        let environment = try UITestEnvironment(auth: .none, model: CannedModel())
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        let run = try await browser.post("/api/assistant/chat", ["text": "Is my bridge fine?"])
        #expect(events(run.body).last?.0 == "done")
        var chats = try await browser.get("/api/assistant/chats").json?.arrayValue ?? []
        #expect(chats.count == 1)
        #expect(chats.first?["title"] == "Is my bridge fine?")
        #expect(chats.first?["current"] == true)
        let id = try #require(chats.first?["id"]?.stringValue)

        #expect(try await browser.send("DELETE", "/api/assistant/chat").status == 200)
        chats = try await browser.get("/api/assistant/chats").json?.arrayValue ?? []
        #expect(chats.map { $0["current"] == true } == [false])
        #expect(events(try await browser.get("/api/assistant/chat").body).first?.1["items"] == [])

        #expect(try await browser.post("/api/assistant/chats/\(id)/open", [:]).status == 200)
        let snapshot = events(try await browser.get("/api/assistant/chat").body).first?.1
        #expect(snapshot?["items"]?.arrayValue?.map { $0["kind"]?.stringValue ?? "" } == ["user", "assistant"])
        let file = environment.directory.appendingPathComponent("ui-chats.json")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Is my bridge fine?"))

        #expect(try await browser.send("DELETE", "/api/assistant/chats/\(id)").status == 200)
        #expect(try await browser.get("/api/assistant/chats").json?.arrayValue?.isEmpty == true)
        #expect(try await browser.post("/api/assistant/chats/nothing/open", [:]).status == 404)
    }

    /// The pages install as an app: the manifest and its icons, with their types, allowed by the policy.
    @Test func servesTheWebAppManifest() async throws {
        let environment = try UITestEnvironment(auth: .form)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let browser = Browser(base: base)
        let manifest = try await browser.get("/manifest.webmanifest")
        #expect(manifest.status == 200)
        #expect(manifest.headers["content-type"] == "application/manifest+json")
        #expect(manifest.json?["display"] == "standalone")
        #expect(manifest.headers["content-security-policy"]?.contains("manifest-src 'self'") == true)
        for icon in manifest.json?["icons"]?.arrayValue ?? [] {
            let response = try await browser.get(icon["src"]?.stringValue ?? "")
            #expect(response.status == 200)
            #expect(response.headers["content-type"] == icon["type"]?.stringValue)
        }
        let touch = try await browser.get("/apple-touch-icon.png")
        #expect(touch.headers["content-type"] == "image/png")
        #expect(touch.body.utf8.starts(with: [0xEF, 0xBF, 0xBD, 0x50, 0x4E, 0x47]))   // \u{89}PNG, decoded as UTF-8
        let page = try await browser.get("/status")
        #expect(page.body.contains(#"<link rel="manifest" href="/manifest.webmanifest">"#))
        #expect(page.body.contains(#"<link rel="apple-touch-icon" href="/apple-touch-icon.png">"#))
    }

    /// The new routes follow the roles: a user who is not an administrator reads today's digest, keeps their own
    /// chats and appearance, and stops their own requests; writing the digest, the Assistant's other requests, its
    /// usage and test, and the log's download and emptying are an administrator's.
    @Test func followsTheRoles() async throws {
        let environment = try UITestEnvironment(model: CannedModel())
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let origin = "http://127.0.0.1:\(environment.server.port!)"
        let admin = Browser(base: base)
        admin.origin = origin
        let code = try #require(environment.server.setupCode)
        #expect(try await admin.post("/api/auth/setup", ["username": "rosaly", "password": "correct horse battery", "setupCode": .string(code)]).status == 200)
        #expect(try await admin.post("/api/users", ["username": "milo", "password": "battery staple lamp"]).status == 201)
        let milo = Browser(base: base)
        milo.origin = origin
        #expect(try await milo.post("/api/auth/login", ["username": "milo", "password": "battery staple lamp"]).status == 200)

        #expect(try await milo.get("/api/assistant/digest").status == 200)
        #expect(try await milo.get("/api/assistant/chats").status == 200)
        #expect(try await milo.put("/api/preferences", ["theme": "dark"]).json?["theme"] == "dark")
        #expect(try await admin.get("/api/preferences").json?["theme"] == "auto")   // each user's own
        #expect(try await milo.post("/api/assistant/cancel", ["requestId": "x"]).status == 200)
        for (method, path) in [("POST", "/api/assistant/digest"), ("POST", "/api/assistant/ask"), ("POST", "/api/assistant/diagnose"), ("POST", "/api/assistant/test"),
                               ("GET", "/api/assistant/usage"), ("GET", "/api/logs/download"), ("POST", "/api/logs/truncate")] {
            #expect(try await milo.send(method, path, body: method == "GET" ? nil : "{}").status == 403, "\(method) \(path)")
        }
        #expect(try await admin.get("/api/assistant/usage").status == 200)
        #expect(try await admin.get("/api/logs/download").status == 200)
    }
}
