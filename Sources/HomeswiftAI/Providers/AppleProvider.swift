import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (Foundation Models): no key, nothing leaves the Mac. macOS 26 or later with
/// Apple Intelligence turned on. Small context (about 4,000 tokens), no tool calling yet.
public enum AppleProvider {
    /// Why the on-device model cannot be used, or nil when it can.
    public static func unavailabilityReason() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "this Mac does not support Apple Intelligence"
                case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off in System Settings"
                case .modelNotReady: return "the on-device model is still downloading; try again in a few minutes"
                @unknown default: return "the on-device model is unavailable"
                }
            }
        }
        return "Apple's on-device model needs macOS 26 or later"
        #else
        return "Apple's on-device model is only available on macOS"
        #endif
    }

    static func make(configuration: AIConfiguration) throws -> any Provider {
        if let reason = unavailabilityReason() { throw AIConfigurationError.unavailable(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return FoundationModelsProvider(configuration: configuration)
        }
        #endif
        throw AIConfigurationError.unavailable("Apple's on-device model needs macOS 26 or later")
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
final class FoundationModelsProvider: Provider, Sendable {
    let name = "apple"
    let model = "system"
    let capabilities: ProviderCapabilities
    let maxOutputTokens: Int

    init(configuration: AIConfiguration) {
        maxOutputTokens = configuration.maxOutputTokens
        capabilities = ProviderCapabilities(tools: false, streaming: true, contextTokens: configuration.contextTokens ?? 4096, jsonMode: false)
    }

    /// One prompt from the conversation: the last user message alone, or a transcript when there is history.
    static func prompt(_ messages: [ChatMessage]) -> String {
        if messages.count == 1 { return messages[0].text }
        return messages.map { message in
            "\(message.role == .user ? "User" : "Assistant"): \(message.text)"
        }.joined(separator: "\n\n") + "\n\nAssistant:"
    }

    private func options(_ request: ChatRequest) -> GenerationOptions {
        GenerationOptions(maximumResponseTokens: request.maxOutputTokens ?? maxOutputTokens)
    }

    private func result(prompt: String, text: String, stopReason: StopReason = .end) -> ChatResult {
        ChatResult(model: model, text: text, toolCalls: [], usage: TokenUsage(inputTokens: Tokens.estimate(prompt), outputTokens: Tokens.estimate(text)), stopReason: stopReason)
    }

    /// Maps the framework's errors: a refusal becomes a result the Assistant can show, the rest a `ProviderError`.
    private func handle(_ error: any Error, prompt: String) throws -> ChatResult {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .guardrailViolation, .refusal:
                return result(prompt: prompt, text: "The on-device model declined this request.", stopReason: .refusal)
            case .exceededContextWindowSize:
                throw ProviderError(provider: name, message: "the input is too long for the on-device model (about 4,000 tokens); shorten it or use a cloud provider")
            case .unsupportedLanguageOrLocale:
                throw ProviderError(provider: name, message: "the on-device model does not support this language")
            case .assetsUnavailable:
                throw ProviderError(provider: name, message: "the on-device model is not ready; try again in a few minutes")
            case .rateLimited, .concurrentRequests:
                throw ProviderError(provider: name, message: "the on-device model is busy; try again")
            default:
                throw ProviderError(provider: name, message: "\(generation)")
            }
        }
        throw ProviderError(provider: name, message: "\(error)")
    }

    func chat(_ request: ChatRequest) async throws -> ChatResult {
        let prompt = Self.prompt(request.messages)
        let session = LanguageModelSession(instructions: request.system)
        do {
            let response = try await session.respond(to: prompt, options: options(request))
            return result(prompt: prompt, text: response.content)
        } catch {
            return try handle(error, prompt: prompt)
        }
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let prompt = Self.prompt(request.messages)
                let session = LanguageModelSession(instructions: request.system)
                var text = ""
                do {
                    for try await snapshot in session.streamResponse(to: prompt, options: options(request)) {
                        let content = snapshot.content
                        if content.hasPrefix(text) {
                            let delta = String(content.dropFirst(text.count))
                            if !delta.isEmpty { continuation.yield(.text(delta)) }
                        } else {
                            continuation.yield(.text(content))
                        }
                        text = content
                    }
                    continuation.yield(.done(result(prompt: prompt, text: text)))
                    continuation.finish()
                } catch {
                    do {
                        let declined = try handle(error, prompt: prompt)
                        if text.isEmpty { continuation.yield(.text(declined.text)) }
                        continuation.yield(.done(declined))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
