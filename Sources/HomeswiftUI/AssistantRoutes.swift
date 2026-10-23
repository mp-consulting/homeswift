import Foundation
import HomeswiftAI
import HomeswiftMCP
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// The Assistant's one-shot requests from the pages (explain, ask, Log Doctor's diagnosis, the daily digest),
/// streamed as they are written: homebridge-ai-kit's plugin routes, whose `ai:chunk` events are this stream's
/// `chunk`s. A request with a `requestId` is answered as a server-sent event stream, `start` (`{requestId}`), a
/// `chunk` (`{text}`) per piece of the answer, then `done` (the answer as JSON without a stream) or `error`
/// (`{error, status}`); `POST /api/assistant/cancel` with that `requestId` stops it, and so does closing the
/// connection. Without a `requestId` the answer is plain JSON.
final class AssistantRuns: Sendable {
    typealias Work = @Sendable (_ onChunk: (@Sendable (String) -> Void)?) async throws -> JSONValue

    private struct Run {
        let token: UUID
        let cancel: @Sendable () -> Void
    }

    private let runs = NIOLockedValueBox<[String: Run]>([:])

    /// The run's events. A new run under a key still running stops the old one.
    func stream(key: String, requestId: String, work: @escaping Work, failure: @escaping @Sendable (any Error) -> (status: Int, message: String)) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let send: @Sendable (String, JSONValue) -> Void = { event, payload in _ = continuation.yield(SSE.frame(event: event, data: payload.text())) }
            send("start", ["requestId": .string(requestId)])
            let token = UUID()
            // Registered under the lock the task waits for, so it cannot finish and leave before it is stored.
            let task = runs.withLockedValue { active -> Task<Void, Never> in
                let task = Task { [self] in
                    do {
                        let result = try await work { text in send("chunk", ["text": .string(text)]) }
                        // A provider's stream may end quietly when cancelled: what it wrote is not the answer.
                        try Task.checkCancellation()
                        send("done", result)
                    } catch {
                        // Cancelled, the provider may fail in its own words (a dropped request): it was stopped.
                        let (status, message) = Task.isCancelled ? (499, "Stopped.") : failure(error)
                        send("error", ["error": .string(Redaction.redactText(message)), "status": .number(Double(status))])
                    }
                    runs.withLockedValue { runs in if runs[key]?.token == token { runs[key] = nil } }
                    continuation.finish()
                }
                active[key]?.cancel()
                active[key] = Run(token: token, cancel: { task.cancel() })
                return task
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stops the run under `key`. False when none runs.
    func cancel(key: String) -> Bool {
        guard let run = runs.withLockedValue({ $0.removeValue(forKey: key) }) else { return false }
        run.cancel()
        return true
    }

    func cancelAll() {
        for run in runs.withLockedValue({ runs in defer { runs = [:] }; return Array(runs.values) }) { run.cancel() }
    }
}

extension UIServer {
    static let assistantOff = "the Assistant is off: add a HomeswiftAiKit block"

    /// `/api/assistant/…` besides the chat: `usage`, `test`, `digest`, `explain`, `ask`, `diagnose` and `cancel`.
    /// nil for a route it does not know.
    func assistantRoute(_ route: [String], _ request: Request, body: JSONValue, username: String) async throws -> Reply? {
        switch (request.method, route) {
        case (.GET, ["usage"]):
            // Today, this month, the budgets, by model and by user (the HomeswiftAiKit settings' usage card).
            return .json(await catalog.assistantUsageJSON())
        case (.POST, ["test"]):
            // The settings form's block, saved or not, or the saved one: does its provider answer?
            if let refused = limitAssistant(for: username) { return refused }
            let block = body["block"].flatMap { $0.objectValue == nil ? nil : $0 }
            return .json(await catalog.testAssistantConnection(block: block, user: username))
        case (.GET, ["digest"]):
            // Today's digest when it was written already; the Status page's widget writes it on demand.
            guard catalog.host.assistant != nil else { return .error(404, Self.assistantOff) }
            return .json(catalog.cachedDigest() ?? ["text": .null])
        case (.POST, ["digest"]):
            guard catalog.host.assistant != nil else { return .error(404, Self.assistantOff) }
            let catalog = catalog
            return await runAssistant(body, username: username) { onChunk in try await catalog.writeDigest(user: username, onChunk: onChunk) }
        case (.POST, ["explain"]):
            guard let assistant = assistant(for: username, plugin: body["plugin"]?.stringValue) else { return .error(404, Self.assistantOff) }
            guard let error = body["error"]?.stringValue, !error.isEmpty else { return .error(400, "an error to explain is required") }
            let (context, device, plugin) = (body["context"]?.stringValue, body["device"], body["plugin"]?.stringValue)
            return await runAssistant(body, username: username) { onChunk in
                Self.replyJSON(try await assistant.explain(error: error, context: context, device: device, pluginName: plugin, onChunk: onChunk))
            }
        case (.POST, ["ask"]):
            // A plugin page's question, with the plugin's background as for explain (ai-kit's /ai/ask).
            guard let assistant = assistant(for: username, plugin: body["plugin"]?.stringValue) else { return .error(404, Self.assistantOff) }
            guard let prompt = body["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return .error(400, "a prompt is required") }
            guard prompt.count <= 8000 else { return .error(400, "the prompt is too long: 8000 characters at most") }
            let context = body["context"]?.stringValue
            return await runAssistant(body, username: username) { onChunk in
                Self.replyJSON(try await assistant.ask(prompt, context: context, history: [], onChunk: onChunk))
            }
        case (.POST, ["diagnose"]):
            // Log Doctor: the lines the Logs page shows, grouped into issues with causes and fixes.
            guard let assistant = assistant(for: username, plugin: nil) else { return .error(404, Self.assistantOff) }
            let lines = body["lines"]?.arrayValue?.compactMap(\.stringValue) ?? body["logs"]?.stringValue.map { $0.components(separatedBy: "\n") } ?? []
            let logs = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !logs.isEmpty else { return .error(400, "there are no log lines to diagnose") }
            let focus = body["focus"]?.stringValue.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
            return await runAssistant(body, username: username) { onChunk in
                var answer = Self.replyJSON(try await assistant.diagnose(logs: logs.joined(separator: "\n"), focus: focus, onChunk: onChunk)).objectValue ?? [:]
                answer["lines"] = .number(Double(logs.count))
                return .object(answer)
            }
        case (.POST, ["cancel"]):
            guard let id = body["requestId"]?.stringValue else { return .error(400, "requestId is required") }
            return .json(["cancelled": .bool(runs.cancel(key: Self.runKey(username, id)))])
        default:
            return nil
        }
    }

    /// The Assistant counting for `username`, with a plugin's background when a plugin page asks.
    func assistant(for username: String, plugin platform: String?) -> AssistantService? {
        guard var assistant = catalog.host.assistant?.forUser(username) else { return nil }
        if let platform, let entry = catalog.host.registry.entry(for: platform) {
            assistant = assistant.withContext(PluginContext.assistantContext(name: entry.name, platform: platform, background: entry.assistantBackground))
        }
        return assistant
    }

    /// Runs `work`: streamed when the body has a `requestId`, else answered as JSON.
    func runAssistant(_ body: JSONValue, username: String, work: @escaping AssistantRuns.Work) async -> Reply {
        if let refused = limitAssistant(for: username) { return refused }
        if let id = body["requestId"]?.stringValue, !id.isEmpty, id.count <= 100 {
            return .events(runs.stream(key: Self.runKey(username, id), requestId: id, work: work, failure: Self.assistantFailure))
        }
        do {
            return .json(try await work(nil))
        } catch {
            let (status, message) = Self.assistantFailure(error)
            return .error(status, message)
        }
    }

    static func runKey(_ username: String, _ id: String) -> String { "\(username)\u{0}\(id)" }

    static func assistantFailure(_ error: any Error) -> (status: Int, message: String) {
        switch error {
        case let budget as BudgetExceededError: (429, budget.description)
        case is CancellationError: (499, "Stopped.")
        case let catalog as CatalogError: (404, catalog.description)
        default: (502, "the Assistant did not answer: \(error)")
        }
    }

    static func replyJSON(_ reply: AssistantReply) -> JSONValue {
        ["text": .string(reply.text), "model": .string(reply.model),
         "usage": ["inputTokens": .number(Double(reply.usage.inputTokens)), "outputTokens": .number(Double(reply.usage.outputTokens))]]
    }
}
