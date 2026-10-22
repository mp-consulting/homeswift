import Foundation
import HomeswiftAI
import Testing

@testable import HomeswiftUI

/// A model that calls one tool, then answers.
final class OneToolModel: Provider, @unchecked Sendable {
    let name = "scripted"
    let model = "scripted-1"
    let capabilities = ProviderCapabilities(streaming: true, contextTokens: 200_000)
    let call: HomeswiftAI.ToolCall
    private let lock = NSLock()
    private var step = 0

    init(call: HomeswiftAI.ToolCall) { self.call = call }

    func chat(_ request: ChatRequest) async throws -> ChatResult {
        let current = lock.withLock { () -> Int in
            defer { step += 1 }
            return step
        }
        if current == 0 { return ChatResult(model: model, text: "", toolCalls: [call], usage: .zero, stopReason: .toolCalls) }
        let declined = request.messages.last?.content.contains { part in
            if case .toolResult(_, _, let content, _) = part { content.contains("did not confirm") } else { false }
        } == true
        return ChatResult(model: model, text: declined ? "Left locked." : "The door is unlocked.", toolCalls: [], usage: .zero, stopReason: .end)
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let result = try await self.chat(request)
                for word in result.text.split(separator: " ") { continuation.yield(.text(word + " ")) }
                continuation.yield(.done(result))
                continuation.finish()
            }
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ChatConversationTests {
    /// The events of a run, as the page reads them; `onConfirm` answers each confirmation card.
    func run(_ conversation: ChatConversation, onConfirm: (String) -> Void) async -> [(String, JSONValue)] {
        var events: [(String, JSONValue)] = []
        var buffer = ""
        for await chunk in conversation.subscribe() {
            buffer += String(decoding: chunk, as: UTF8.self)
            while let end = buffer.range(of: "\n\n") {
                let frame = String(buffer[..<end.lowerBound])
                buffer = String(buffer[end.upperBound...])
                guard let event = frame.split(separator: "\n").first(where: { $0.hasPrefix("event: ") })?.dropFirst(7),
                      let data = frame.split(separator: "\n").first(where: { $0.hasPrefix("data: ") })?.dropFirst(6),
                      let value = try? JSONValue(string: String(data)) else { continue }
                events.append((String(event), value))
                if event == "item", value["item"]?["kind"] == "confirm", value["item"]?["state"] == "pending", let id = value["item"]?["id"]?.stringValue {
                    onConfirm(id)
                }
            }
        }
        return events
    }

    @Test func asksBeforeAChangeAndStreamsTheAnswer() async throws {
        let environment = try UITestEnvironment()
        _ = try await environment.start()
        defer { Task { await environment.stop() } }
        let conversation = await environment.server.chat.conversation(for: "rosaly")
        let assistant = AssistantService(provider: OneToolModel(call: .init(
            id: "1", name: "set_security_accessory", arguments: ["id": "Lamps:lock", "characteristic": "Lock Target State", "value": 0])))
        #expect(conversation.send("Unlock the front door", page: "accessories", user: "rosaly", assistant: assistant, logger: testLogger))
        #expect(!conversation.send("Again", page: nil, user: "rosaly", assistant: assistant, logger: testLogger))   // one run at a time
        let events = await run(conversation) { id in _ = conversation.answer(id, allow: true) }

        #expect(events.first?.0 == "snapshot")
        #expect(events.last?.0 == "done")
        let items = conversation.snapshot["items"]?.arrayValue ?? []
        #expect(items.map { $0["kind"]?.stringValue ?? "" } == ["user", "tool", "confirm", "assistant"])
        #expect(items[1]["state"] == "done")
        #expect(items[2]["state"] == "allowed")
        #expect(items[3]["text"]?.stringValue?.trimmingCharacters(in: .whitespaces) == "The door is unlocked.")
        #expect(environment.writes.withLockedValue { $0 }.contains { $0.0 == "lock" })
        #expect(conversation.snapshot["running"] == false)
    }

    @Test func leavesEverythingWhenTheUserDeclines() async throws {
        let environment = try UITestEnvironment()
        _ = try await environment.start()
        defer { Task { await environment.stop() } }
        let conversation = await environment.server.chat.conversation(for: "rosaly")
        let assistant = AssistantService(provider: OneToolModel(call: .init(
            id: "1", name: "set_security_accessory", arguments: ["id": "Lamps:lock", "characteristic": "Lock Target State", "value": 0])))
        #expect(conversation.send("Unlock the front door", page: nil, user: "rosaly", assistant: assistant, logger: testLogger))
        _ = await run(conversation) { id in _ = conversation.answer(id, allow: false) }
        let items = conversation.snapshot["items"]?.arrayValue ?? []
        #expect(items[1]["state"] == "declined")
        #expect(items[2]["state"] == "declined")
        #expect(items.last?["text"]?.stringValue?.contains("Left locked") == true)
        #expect(!environment.writes.withLockedValue { $0 }.contains { $0.0 == "lock" })
    }

    @Test func keepsTheLatestMessagesThatFit() {
        let long = String(repeating: "word ", count: 400)
        let messages: [ChatMessage] = [.user("first " + long), .assistant(long), .user("second"), .assistant("ok"), .user("third")]
        let kept = ChatConversation.fitting(messages, budget: 50)
        #expect(kept.first?.text == "second")
        #expect(ChatConversation.fitting(messages, budget: 100_000).count == 5)
        #expect(ChatConversation.fitting([.user(long)], budget: 1).count == 1)
    }
}
