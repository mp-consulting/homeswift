import Foundation
import Testing

@testable import HomeswiftAI

/// The settings' Model menu: each provider's models list, asked as it documents it.
@Suite(.timeLimit(.minutes(1)))
struct ModelListTests {
    @Test func anthropicListsItsModelsWithTheirNames() async throws {
        let transport = FakeTransport(json: #"{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"},{"id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5"}],"has_more":false}"#)
        let models = try await AIConfiguration(block: ["provider": "anthropic", "apiKey": "sk-ant-test"], environment: [:]).listModels(transport: transport)
        #expect(models == [ProviderModel(id: "claude-opus-5-5", name: "Claude Opus 5.5"), ProviderModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5")])
        let request = try #require(transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(request.headers["x-api-key"] == "sk-ant-test")
        #expect(request.headers["anthropic-version"] == AnthropicProvider.apiVersion)
    }

    @Test func openAIKeepsTheModelsThatChat() async throws {
        let transport = FakeTransport(json: #"{"data":[{"id":"gpt-6.1-sol"},{"id":"text-embedding-3-large"},{"id":"whisper-1"},{"id":"o5-mini"},{"id":"gpt-image-2"}]}"#)
        let models = try await AIConfiguration(block: ["provider": "openai", "apiKey": "sk-test"], environment: [:]).listModels(transport: transport)
        #expect(models.map(\.id) == ["gpt-6.1-sol", "o5-mini"])
        #expect(transport.requests.first?.url.absoluteString == "https://api.openai.com/v1/models")
        #expect(transport.requests.first?.headers["Authorization"] == "Bearer sk-test")
    }

    @Test func aCompatibleServerIsAskedAtItsAddressWithoutAKey() async throws {
        let transport = FakeTransport(json: #"{"data":[{"id":"qwen3:8b"},{"id":"llama3.1"}]}"#)
        let block: JSONValue = ["provider": "openai-compatible", "baseUrl": "http://192.168.1.9:11434/v1/"]
        let models = try await AIConfiguration(block: block, environment: [:]).listModels(transport: transport)
        #expect(models.map(\.id) == ["llama3.1", "qwen3:8b"])
        #expect(transport.requests.first?.url.absoluteString == "http://192.168.1.9:11434/v1/models")
        #expect(transport.requests.first?.headers["Authorization"] == nil)
    }

    @Test func geminiListsTheModelsThatGenerateContent() async throws {
        let transport = FakeTransport(json: #"{"models":[{"name":"models/gemini-3.8-flash","displayName":"Gemini 3.8 Flash","supportedGenerationMethods":["generateContent","countTokens"]},{"name":"models/text-embedding-005","supportedGenerationMethods":["embedContent"]}]}"#)
        let models = try await AIConfiguration(block: ["provider": "gemini", "apiKey": "g-test"], environment: [:]).listModels(transport: transport)
        #expect(models == [ProviderModel(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash")])
        #expect(transport.requests.first?.headers["x-goog-api-key"] == "g-test")
    }

    @Test func aRefusalSaysWhyAndNoKeyAsksNothing() async throws {
        let refused = FakeTransport([FakeTransport.Reply(status: 401, body: #"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)])
        await #expect(throws: ModelListError.self) {
            try await AIConfiguration(block: ["provider": "anthropic", "apiKey": "sk-ant-wrong"], environment: [:]).listModels(transport: refused)
        }
        let none = FakeTransport()
        await #expect(throws: AIConfigurationError.self) {
            try await AIConfiguration(block: ["provider": "openai"], environment: [:]).listModels(transport: none)
        }
        #expect(none.requests.isEmpty)
        #expect(try await AIConfiguration(block: ["provider": "apple"], environment: [:]).listModels(transport: none).isEmpty)
    }

    /// The form's Default (X) follows the provider: its defaults are the providers' own.
    @Test func theMenusDefaultsAreTheProviders() throws {
        let schema = try JSONValue(string: AIConfiguration.schemaJSON)
        let defaults = try #require(schema["schema"]?["properties"]?["model"]?["x-schema-form"]?["defaults"]?.objectValue)
        for kind in AIConfiguration.ProviderKind.allCases where kind != .apple {
            #expect(defaults[kind.rawValue] == .string(kind.defaultModel), "\(kind)")
        }
    }
}
