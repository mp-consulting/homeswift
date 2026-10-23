import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// The web UI's chat with the Assistant: a conversation per signed-in user, and the user's earlier ones, kept
/// in `ui-chats.json` (owner-only) when the server has a directory, so a reload, another browser or a restart
/// finds them; **New chat** files the conversation away, and one can be opened again (Glass UI's chat history).
/// The Assistant acts through the MCP server's tools (`ChatToolbox`), so a change asks the user first, on
/// the page, and lands in the MCP audit log. An administrator's chat has every tool; another user's, as Glass
/// UI's, only the read-only ones, without those reading what the web UI keeps for administrators.
final class AssistantChat: Sendable {
    let server: MCPServer
    let store: ChatStore?
    private let conversations = NIOLockedValueBox<[String: (admin: Bool, task: Task<ChatConversation, Never>)]>([:])

    /// Read-only tools that show what only an administrator sees in the web UI: config.json and its backups, the
    /// log, the cached accessories, the pairings and the child bridges' health.
    static let administratorReads: Set<String> = [
        "get_config", "list_config_backups", "get_recent_logs", "search_logs", "get_cached_accessories", "get_pairing_info", "get_child_bridge_health",
    ]

    init(catalog: HomeswiftCatalog, storeURL: URL? = nil, logger: Logger) {
        var options = MCPServer.Options(version: PluginHost.version, instructions: HomeswiftCatalog.instructions)
        options.logger = logger
        let mcp = (try? catalog.host.configuration.block(for: AIConfiguration.platform)).flatMap { try? MCPConfiguration(block: $0) } ?? MCPConfiguration()
        server = MCPServer(options: options, tools: catalog.tools, audit: mcp.makeAuditLog(configDirectory: catalog.configURL.deletingLastPathComponent(), logger: logger))
        store = storeURL.map { ChatStore(url: $0, logger: logger) }
    }

    /// The user's conversation, with the tools of their role: the one in memory, else the one they had open last,
    /// else a new one. A conversation started under another role (an administrator's role was taken away, or
    /// given) ends, and goes on with the new role's tools.
    func conversation(for user: String, admin: Bool = true) async -> ChatConversation {
        let (task, replaced) = conversations.withLockedValue { conversations -> (Task<ChatConversation, Never>, Task<ChatConversation, Never>?) in
            if let existing = conversations[user], existing.admin == admin { return (existing.task, nil) }
            let (server, store) = (server, store)
            let replaced = conversations[user]?.task
            let task = Task {
                // The conversation as it stood under the other role, else the one kept.
                let record = await replaced?.value.record ?? store?.chats(of: user).current
                let toolbox = await ChatToolbox(server: server, user: user, scope: admin ? .admin : .read)
                return ChatConversation(toolbox: toolbox, hidden: admin ? [] : Self.administratorReads, readOnly: !admin, record: record) { conversation in
                    // Kept after every answer.
                    store?.update(user) { $0.current = conversation.record.isEmpty ? nil : conversation.record }
                }
            }
            conversations[user] = (admin, task)
            return (task, replaced)
        }
        if let replaced { await replaced.value.close() }
        return await task.value
    }

    /// Ends the user's conversation: a run stops, the conversation joins the earlier ones, and the next message
    /// starts afresh.
    func reset(user: String) async {
        let record = await closeCurrent(of: user)
        store?.update(user) { chats in
            chats.file(record ?? chats.current)
            chats.current = nil
        }
    }

    /// Opens an earlier conversation: the current one joins the earlier ones. False when there is no such one.
    func open(user: String, id: String) async -> Bool {
        guard let store, store.chats(of: user).recent.contains(where: { $0.id == id }) else { return false }
        let record = await closeCurrent(of: user)
        store.update(user) { chats in
            chats.file(record ?? chats.current)
            chats.current = chats.recent.first { $0.id == id }
            chats.recent.removeAll { $0.id == id }
        }
        return true
    }

    /// Forgets a conversation, the current one included. False when there is no such one.
    func remove(user: String, id: String) async -> Bool {
        guard let store else { return false }
        let current = store.chats(of: user).current?.id
        let inMemory = await conversations.withLockedValue({ $0[user] })?.task.value.id
        if id == inMemory || id == current {
            _ = await closeCurrent(of: user)
            store.update(user) { $0.current = nil }
            return true
        }
        var found = false
        store.update(user) { chats in
            found = chats.recent.contains { $0.id == id }
            chats.recent.removeAll { $0.id == id }
        }
        return found
    }

    /// The user's conversations, the open one first, then the earlier ones, newest first: `id`, `title`,
    /// `updated`, `messages`, `current`.
    func list(user: String) async -> JSONValue {
        let open = await conversations.withLockedValue({ $0[user] })?.task.value.record
        let chats = store?.chats(of: user) ?? ChatStore.UserChats()
        let current = open ?? chats.current
        let entries = ([current].compactMap { $0 }.filter { !$0.isEmpty }.map { ($0, true) }) + chats.recent.filter { $0.id != current?.id }.map { ($0, false) }
        return .array(entries.map { record, isCurrent in
            ["id": .string(record.id), "title": .string(record.title), "updated": .string(Timestamp.iso8601(record.updated)),
             "messages": .number(Double(record.items.filter { $0["kind"] == "user" }.count)), "current": .bool(isCurrent)]
        })
    }

    /// Stops and forgets the conversation in memory; answers it as it stood.
    private func closeCurrent(of user: String) async -> ChatRecord? {
        guard let entry = conversations.withLockedValue({ $0.removeValue(forKey: user) }) else { return nil }
        let conversation = await entry.task.value
        await conversation.close()
        return conversation.record
    }

    func close() async {
        let tasks = conversations.withLockedValue { conversations in
            defer { conversations = [:] }
            return conversations.values.map(\.task)
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
        var updated = Date()

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
    let id: String
    let created: Date
    /// The user is not an administrator: the model is told it can change nothing.
    let readOnly: Bool
    private let usage = UsageTracker()
    private let state = NIOLockedValueBox(State())
    private let onFinish: (@Sendable (ChatConversation) -> Void)?

    /// `hidden`: tools the user's scope allows that the conversation still leaves out. `record`, an earlier
    /// conversation to go on with; `onFinish` runs after each answer (to keep it).
    init(toolbox: ChatToolbox, hidden: Set<String> = [], readOnly: Bool = false, record: ChatRecord? = nil, onFinish: (@Sendable (ChatConversation) -> Void)? = nil) {
        self.toolbox = toolbox
        self.readOnly = readOnly
        self.onFinish = onFinish
        id = record?.id ?? UUID().uuidString
        created = record?.created ?? Date()
        if let record {
            state.withLockedValue { state in
                state.messages = record.messages
                state.items = record.items
                state.updated = record.updated
            }
        }
        // Built once: the tools and the user's scope do not change while the conversation lasts.
        let tools = toolbox.agentTools { [weak self] confirmation in await self?.ask(confirmation) ?? false }.filter { !hidden.contains($0.definition.name) }
        state.withLockedValue { $0.tools = tools }
    }

    var snapshot: JSONValue { state.withLockedValue(\.snapshot) }

    /// The conversation as kept: what the model saw and what the page shows, a running step as failed and a
    /// pending question as declined (nothing waits for them once it is filed).
    var record: ChatRecord {
        state.withLockedValue { state in
            let items = state.items.indices.map { index -> JSONValue in
                let item = state.item(at: index)
                guard var object = item.objectValue else { return item }
                if object["kind"] == "tool", object["state"] == "running" { object["state"] = "failed" }
                if object["kind"] == "confirm", object["state"] == "pending" { object["state"] = "declined" }
                return .object(object)
            }
            return ChatRecord(id: id, created: created, updated: state.updated, messages: state.messages, items: items)
        }
    }

    /// The names of the tools the model may call.
    var toolNames: [String] { state.withLockedValue { $0.tools.map(\.definition.name) } }

    var isRunning: Bool { state.withLockedValue { $0.run != nil } }

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
            state.updated = Date()
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
        if readOnly {
            context += " They are not an administrator: only read-only tools are available, so explain what an administrator would need to do for any change."
        }
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
        onFinish?(self)
    }
}

/// A conversation as `ui-chats.json` keeps it.
struct ChatRecord: Sendable {
    var id: String
    var created: Date
    var updated: Date
    /// What the model saw, for going on with it.
    var messages: [ChatMessage]
    /// What the page shows.
    var items: [JSONValue]

    var isEmpty: Bool { items.isEmpty }

    /// Its first question, on one line.
    var title: String {
        let first = items.first { $0["kind"] == "user" }?["text"]?.stringValue ?? "New chat"
        let line = first.split(separator: "\n").first.map(String.init) ?? first
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    /// The latest messages that fit 100K tokens, and the last 200 items: a long conversation stays a small file.
    var json: JSONValue {
        let kept = ChatConversation.fitting(messages, budget: 100_000)
        let encoded = (try? JSONEncoder().encode(kept)).flatMap { try? JSONValue(data: $0) } ?? .array([])
        return [
            "id": .string(id), "created": .string(Timestamp.iso8601(created)), "updated": .string(Timestamp.iso8601(updated)),
            "messages": encoded, "items": .array(Array(items.suffix(200))),
        ]
    }

    init(id: String, created: Date, updated: Date, messages: [ChatMessage], items: [JSONValue]) {
        self.id = id
        self.created = created
        self.updated = updated
        self.messages = messages
        self.items = items
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let items = json["items"]?.arrayValue else { return nil }
        let date = { (key: String) in json[key]?.stringValue.flatMap(UIServer.date(iso:)) ?? Date() }
        let messages = (try? json["messages"].map { try JSONDecoder().decode([ChatMessage].self, from: $0.encoded()) }) ?? nil
        self.init(id: id, created: date("created"), updated: date("updated"), messages: messages ?? [], items: items)
    }
}

/// Each user's conversations: the open one and the 10 before it, newest first.
final class ChatStore: Sendable {
    struct UserChats: Sendable {
        var current: ChatRecord?
        var recent: [ChatRecord] = []

        /// Puts a conversation first among the earlier ones (an empty one is dropped).
        mutating func file(_ record: ChatRecord?) {
            guard let record, !record.isEmpty else { return }
            recent = Array(([record] + recent.filter { $0.id != record.id }).prefix(ChatStore.keptConversations))
        }
    }

    static let keptConversations = 10
    let url: URL
    let logger: Logger
    private let state: NIOLockedValueBox<[String: UserChats]>

    init(url: URL, logger: Logger) {
        self.url = url
        self.logger = logger
        let root = (try? Data(contentsOf: url)).flatMap { try? JSONValue(data: $0) }?.objectValue ?? [:]
        state = NIOLockedValueBox(root.mapValues { user in
            UserChats(current: user["current"].flatMap(ChatRecord.init(json:)), recent: (user["recent"]?.arrayValue ?? []).compactMap(ChatRecord.init(json:)))
        })
    }

    func chats(of user: String) -> UserChats { state.withLockedValue { $0[user] ?? UserChats() } }

    func update(_ user: String, _ change: (inout UserChats) -> Void) {
        let snapshot = state.withLockedValue { all -> [String: UserChats] in
            change(&all[user, default: UserChats()])
            return all
        }
        let json = JSONValue.object(snapshot.mapValues { chats in
            ["current": chats.current?.json ?? .null, "recent": .array(chats.recent.map(\.json))]
        })
        do {
            try OwnerOnlyFile.write(json.encoded(), to: url)
        } catch {
            logger.warning("Could not keep the Assistant's conversations", metadata: ["error": "\(error)"])
        }
    }
}
