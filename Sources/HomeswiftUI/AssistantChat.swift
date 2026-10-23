import Foundation
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// The web UI's chat with the Assistant: a conversation per signed-in user, kept while the process runs.
/// The Assistant acts through the MCP server's tools (`ChatToolbox`), so a change asks the user first, on
/// the page, and lands in the MCP audit log.
final class AssistantChat: Sendable {
    let server: MCPServer
    private let conversations = NIOLockedValueBox<[String: Task<ChatConversation, Never>]>([:])

    init(catalog: HomeswiftCatalog, logger: Logger) {
        var options = MCPServer.Options(version: PluginHost.version, instructions: HomeswiftCatalog.instructions)
        options.logger = logger
        let mcp = (try? catalog.host.configuration.block(for: AIConfiguration.platform)).flatMap { try? MCPConfiguration(block: $0) } ?? MCPConfiguration()
        server = MCPServer(options: options, tools: catalog.tools, audit: mcp.makeAuditLog(configDirectory: catalog.configURL.deletingLastPathComponent(), logger: logger))
    }

    /// The user's conversation, started on first use.
    func conversation(for user: String) async -> ChatConversation {
        let task = conversations.withLockedValue { conversations in
            if let task = conversations[user] { return task }
            let server = server
            let task = Task { ChatConversation(toolbox: await ChatToolbox(server: server, user: user)) }
            conversations[user] = task
            return task
        }
        return await task.value
    }

    /// Ends the user's conversation: a run stops, and the next message starts afresh.
    func reset(user: String) async {
        guard let task = conversations.withLockedValue({ $0.removeValue(forKey: user) }) else { return }
        await task.value.close()
    }

    func close() async {
        let tasks = conversations.withLockedValue { conversations in
            defer { conversations = [:] }
            return Array(conversations.values)
        }
        for task in tasks { await task.value.close() }
    }
}

/// One user's conversation: what the model has seen, what the page shows, and the run in progress.
///
/// The page gets `items`: `user` and `assistant` messages, `tool` steps, `confirm` cards and `error`s. A
/// stream starts with a `snapshot` of them, then sends `item` (an item at an index, new or changed),
/// `delta` (text for the assistant message at an index) and `done` when the run ends.
final class ChatConversation: Sendable {
    struct State {
        var messages: [ChatMessage] = []
        var items: [JSONValue] = []
        /// The answer being streamed: its item's index and text so far, grown in place.
        var open: (index: Int, text: String)?
        var run: Task<Void, Never>?
        var confirmations: [String: CheckedContinuation<Bool, Never>] = [:]
        var listeners: [UUID: AsyncStream<Data>.Continuation] = [:]
        var tools: [AgentTool] = []
        var usage: UsageTracker.Summary?

        /// An item as the page shows it: the open answer with its text so far.
        func item(at index: Int) -> JSONValue {
            guard let open, open.index == index else { return items[index] }
            return ["kind": "assistant", "text": .string(open.text)]
        }

        var snapshot: JSONValue {
            [
                "items": .array(items.indices.map(item(at:))), "running": .bool(run != nil),
                "usage": usage.map { ["inputTokens": .number(Double($0.usage.inputTokens)), "outputTokens": .number(Double($0.usage.outputTokens)), "cost": $0.cost.map(JSONValue.number) ?? .null] } ?? .null,
            ]
        }
    }

    let toolbox: ChatToolbox
    private let usage = UsageTracker()
    private let state = NIOLockedValueBox(State())

    init(toolbox: ChatToolbox) {
        self.toolbox = toolbox
        // Built once: the tools and the user's scope do not change while the conversation lasts.
        let tools = toolbox.agentTools { [weak self] confirmation in await self?.ask(confirmation) ?? false }
        state.withLockedValue { $0.tools = tools }
    }

    var snapshot: JSONValue { state.withLockedValue(\.snapshot) }

    /// The conversation's events from now on, after a snapshot; ends with the run (at once when none runs).
    func subscribe() -> AsyncStream<Data> {
        let id = UUID()
        // Unbounded: a dropped delta would leave a gap in the answer shown. A run's frames are few enough.
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let running = state.withLockedValue { state -> Bool in
                continuation.yield(SSE.frame(event: "snapshot", data: state.snapshot.text()))
                if state.run != nil { state.listeners[id] = continuation }
                return state.run != nil
            }
            if !running { continuation.finish() }
            continuation.onTermination = { [weak self] _ in _ = self?.state.withLockedValue { $0.listeners.removeValue(forKey: id) } }
        }
    }

    /// Starts a turn with the user's message. False when one is already running.
    func send(_ text: String, page: String?, user: String, assistant: AssistantService, logger: Logger) -> Bool {
        // No one listens before the run starts: the subscriber's snapshot carries the user's message.
        state.withLockedValue { state -> Bool in
            guard state.run == nil else { return false }
            state.messages.append(.user(text))
            state.items.append(["kind": "user", "text": .string(text)])
            // The task waits for this lock before it touches the state, so it cannot finish before it is stored.
            state.run = Task { [self] in
                await run(page: page, user: user, assistant: assistant, logger: logger)
            }
            return true
        }
    }

    private func run(page: String?, user: String, assistant: AssistantService, logger: Logger) async {
        let (history, tools) = state.withLockedValue { (Self.fitting($0.messages, budget: assistant.budget(120_000)), $0.tools) }
        var context = "The user is signed in as \(user). Today is \(Date().formatted(date: .complete, time: .omitted))."
        if let page { context += " They have the web UI's \(page) page open." }
        do {
            let turn = try await assistant.converse(history: history, tools: tools, vault: toolbox.vault, context: context) { [weak self] event in
                self?.apply(event)
            }
            await usage.record(model: turn.model, usage: turn.usage)
            let total = await usage.total
            state.withLockedValue { state in
                state.messages += turn.messages
                state.usage = total
            }
            if turn.truncated {
                append(["kind": "error", "text": "The Assistant stopped after many steps without an answer. Ask again, or more precisely."])
            }
        } catch is CancellationError {
            append(["kind": "error", "text": "Stopped."])
        } catch {
            logger.warning("Assistant chat failed: \(error)")
            append(["kind": "error", "text": .string(Redaction.redactText("The Assistant did not answer: \(error)"))])
        }
        finish()
    }

    /// The latest messages that fit `budget` tokens, starting at a message of the user's own (never between a
    /// tool call and its result).
    static func fitting(_ messages: [ChatMessage], budget: Int) -> [ChatMessage] {
        guard !messages.isEmpty else { return [] }
        var total = 0
        var start = messages.count
        for index in messages.indices.reversed() {
            total += Tokens.estimate(messages[index].content.map { part -> String in
                switch part {
                case .text(let text): text
                case .toolCall(let call): call.arguments.text()
                case .toolResult(_, _, let content, _): content
                }
            }.joined())
            if total > budget { break }
            if messages[index].role == .user, !messages[index].text.isEmpty { start = index }
        }
        return Array(messages[min(start, messages.count - 1)...])
    }

    private func apply(_ event: AgentEvent) {
        switch event {
        case .text(let delta):
            let (index, created) = state.withLockedValue { state -> (Int, Bool) in
                if let open = state.open {
                    state.open?.text += delta
                    return (open.index, false)
                }
                state.items.append(["kind": "assistant", "text": ""])
                state.open = (state.items.count - 1, delta)
                return (state.items.count - 1, true)
            }
            if created { broadcastItem(at: index) } else { broadcast("delta", ["index": .number(Double(index)), "text": .string(delta)]) }
        case .toolStarted(let id, let name, let title):
            closeMessage()
            append(["kind": "tool", "id": .string(id), "name": .string(name), "title": .string(title), "state": "running"])
        case .toolFinished(let id, let outcome, let summary):
            update(where: { $0["kind"] == "tool" && $0["id"] == .string(id) }) { item in
                item["state"] = .string(outcome.rawValue)
                if let summary, outcome != .declined { item["summary"] = .string(summary) }
            }
        }
    }

    /// Shows a confirmation card and waits for the user's answer.
    private func ask(_ confirmation: ToolConfirmation) async -> Bool {
        let id = UUID().uuidString
        closeMessage()
        var card: [String: JSONValue] = [
            "kind": "confirm", "id": .string(id), "tool": .string(confirmation.tool), "title": .string(confirmation.title),
            "arguments": confirmation.arguments, "state": "pending",
        ]
        if let preview = confirmation.preview { card["preview"] = preview }
        let allowed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // The card and its continuation appear together: an answer as soon as the card shows (from a
                // snapshot) finds something waiting for it.
                let (index, cancelled) = state.withLockedValue { state -> (Int, Bool) in
                    state.items.append(.object(card))
                    guard state.run?.isCancelled != true else { return (state.items.count - 1, true) }
                    state.confirmations[id] = continuation
                    return (state.items.count - 1, false)
                }
                broadcastItem(at: index)
                if cancelled { continuation.resume(returning: false) }
            }
        } onCancel: {
            state.withLockedValue { $0.confirmations.removeValue(forKey: id) }?.resume(returning: false)
        }
        update(where: { $0["kind"] == "confirm" && $0["id"] == .string(id) }) { $0["state"] = allowed ? "allowed" : "declined" }
        return allowed
    }

    /// The user's answer to a confirmation card. False when nothing waits for it.
    func answer(_ id: String, allow: Bool) -> Bool {
        guard let continuation = state.withLockedValue({ $0.confirmations.removeValue(forKey: id) }) else { return false }
        continuation.resume(returning: allow)
        return true
    }

    func stop() {
        let (run, waiting) = state.withLockedValue { state in
            defer { state.confirmations = [:] }
            return (state.run, Array(state.confirmations.values))
        }
        run?.cancel()
        for continuation in waiting { continuation.resume(returning: false) }
    }

    func close() async {
        stop()
        let run = state.withLockedValue { $0.run }
        await run?.value
        toolbox.close()
    }

    // MARK: Items and listeners

    /// Ends the answer being streamed: its text goes into its item.
    private func closeMessage() {
        state.withLockedValue { state in
            guard let open = state.open else { return }
            state.items[open.index] = ["kind": "assistant", "text": .string(open.text)]
            state.open = nil
        }
    }

    private func append(_ item: JSONValue) {
        let index = state.withLockedValue { state -> Int in
            state.items.append(item)
            return state.items.count - 1
        }
        broadcastItem(at: index)
    }

    /// Changes the last item that matches.
    private func update(where matches: (JSONValue) -> Bool, _ change: (inout [String: JSONValue]) -> Void) {
        let index = state.withLockedValue { state -> Int? in
            guard let index = state.items.lastIndex(where: matches), var item = state.items[index].objectValue else { return nil }
            change(&item)
            state.items[index] = .object(item)
            return index
        }
        if let index { broadcastItem(at: index) }
    }

    private func broadcastItem(at index: Int) {
        let item = state.withLockedValue { state -> JSONValue? in state.items.indices.contains(index) ? state.item(at: index) : nil }
        if let item { broadcast("item", ["index": .number(Double(index)), "item": item]) }
    }

    private func broadcast(_ event: String, _ payload: JSONValue) {
        let frame = SSE.frame(event: event, data: payload.text())
        for listener in state.withLockedValue({ Array($0.listeners.values) }) { listener.yield(frame) }
    }

    private func finish() {
        closeMessage()
        let (listeners, usage) = state.withLockedValue { state in
            defer {
                state.run = nil
                state.listeners = [:]
            }
            return (Array(state.listeners.values), state.snapshot["usage"] ?? .null)
        }
        let frame = SSE.frame(event: "done", data: JSONValue.object(["usage": usage]).text())
        for listener in listeners {
            listener.yield(frame)
            listener.finish()
        }
    }
}
