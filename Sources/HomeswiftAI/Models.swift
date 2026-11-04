import Foundation

/// A model a provider offers, as its models list names it: what the settings' Model menu shows.
public struct ProviderModel: Sendable, Equatable {
    /// The id the block's `model` takes (`claude-opus-5-5`, `gpt-6.1-sol`, `gemini-3.8-flash`, `llama3.1`).
    public var id: String
    /// The provider's own name for it (Claude Opus 5.5), when it gives one.
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["id": .string(id)]
        if let name { object["name"] = .string(name) }
        return .object(object)
    }
}

/// A models list the provider refused or answered in a shape it does not document.
public struct ModelListError: Error, CustomStringConvertible {
    public var description: String
}

extension AIConfiguration {
    /// The models the provider offers for chat, from its models list: Anthropic's `/v1/models`, OpenAI's and an
    /// OpenAI-compatible server's `/models`, Gemini's `/models` (those that generate content). Apple's on-device model
    /// is the only one there is: none. Sorted as the provider lists them, newest first where it says.
    public func listModels(transport: any HTTPTransport = URLSessionTransport(timeout: 20)) async throws -> [ProviderModel] {
        let base = baseURL ?? provider.defaultBaseURL ?? ""
        func get(_ path: String, headers: [String: String]) async throws -> JSONValue {
            guard let url = URL(string: base + path) else { throw AIConfigurationError.invalid(key: "baseUrl", expected: "a URL") }
            let response = try await transport.post(HTTPRequest(method: "GET", url: url, headers: headers))
            let body = (try? JSONValue(data: response.body)) ?? .null
            guard (200..<300).contains(response.status) else {
                let message = body["error"]?["message"]?.stringValue ?? body["error"]?.stringValue ?? "HTTP \(response.status)"
                throw ModelListError(description: Redaction.redactText(message))
            }
            return body
        }
        func key() throws -> String {
            guard let apiKey else { throw AIConfigurationError.missingAPIKey(provider: provider.rawValue, environmentVariable: provider.apiKeyEnvironmentVariable) }
            return apiKey
        }
        switch provider {
        case .anthropic:
            let body = try await get("/v1/models?limit=1000", headers: ["x-api-key": try key(), "anthropic-version": AnthropicProvider.apiVersion])
            return (body["data"]?.arrayValue ?? []).compactMap { model in
                model["id"]?.stringValue.map { ProviderModel(id: $0, name: model["display_name"]?.stringValue) }
            }
        case .openai, .openaiCompatible:
            let headers = apiKey.map { ["Authorization": "Bearer \($0)"] } ?? [:]
            if provider == .openai { _ = try key() }
            let body = try await get("/models", headers: headers)
            let models = (body["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
            // OpenAI's list holds every kind of model: those that do not chat are left out. A local server's are all kept.
            let chats = provider == .openai ? models.filter(Self.isOpenAIChatModel) : models
            return chats.sorted().map { ProviderModel(id: $0) }
        case .gemini:
            let body = try await get("/models?pageSize=1000", headers: ["x-goog-api-key": try key()])
            return (body["models"]?.arrayValue ?? []).compactMap { model in
                guard let name = model["name"]?.stringValue,
                      model["supportedGenerationMethods"]?.arrayValue?.contains(.string("generateContent")) ?? true else { return nil }
                return ProviderModel(id: name.hasPrefix("models/") ? String(name.dropFirst(7)) : name, name: model["displayName"]?.stringValue)
            }
        case .apple:
            return []
        }
    }

    /// Whether an id of OpenAI's models list is one that chats: not an embedding, speech, image, moderation or
    /// realtime model.
    static func isOpenAIChatModel(_ id: String) -> Bool {
        let other = ["embedding", "tts", "whisper", "dall-e", "moderation", "transcribe", "image", "audio", "realtime", "search", "babbage", "davinci"]
        return !other.contains { id.contains($0) }
    }
}
