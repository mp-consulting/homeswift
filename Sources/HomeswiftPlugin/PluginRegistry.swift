import Foundation

/// The plugins a `homeswift` binary knows, by platform name.
///
/// Register a type, or a closure for a plugin that needs more than its configuration (tests inject fake
/// transports this way):
///
/// ```swift
/// var registry = PluginRegistry()
/// registry.register(ElgatoKeyLightsPlugin.self)
/// registry.register(platform: "Fake", name: "Fake") { json, context in
///     try FakePlugin(configuration: try JSONDecoder().decode(FakePlugin.Configuration.self, from: json), context: context)
/// }
/// ```
public struct PluginRegistry: Sendable {
    public struct Entry: Sendable {
        public let platform: String
        public let name: String
        /// The web UI's icon for it (`HomeswiftPlugin.icon`).
        public let icon: String?
        /// What it brings, in one line (`HomeswiftPlugin.summary`).
        public let summary: String?
        /// The plugin's config.schema.json as text, when it has one.
        public let configurationSchemaJSON: String?
        /// The plugin's web pages, when it has any.
        public let webFiles: [String: WebFile]
        /// What the Assistant may do with an instance.
        public let assistantActions: [AssistantAction]
        /// What the Assistant should know about the plugin (`HomeswiftPlugin.assistantBackground`).
        public let assistantBackground: String?
        /// What an instance's account asks before the plugin may use it (`HomeswiftPlugin.accountAuthorization`).
        public let accountAuthorization: AuthorizationMethod
        /// `HomeswiftPlugin.deviceID(ofAccessory:)`.
        public let deviceIDOfAccessory: (@Sendable (String) -> String?)?
        /// Whether the web UI can offer a page for it.
        public var hasPages: Bool { webFiles["index.html"] != nil }
        let make: @Sendable (_ configuration: Data, _ context: PluginContext) async throws -> any HomeswiftPlugin
    }

    private var byPlatform: [String: Entry] = [:]
    private var order: [String] = []

    public init() {}

    public init(_ plugins: [any HomeswiftPlugin.Type]) {
        register(plugins)
    }

    public mutating func register<P: HomeswiftPlugin>(_ type: P.Type) {
        register(platform: P.platform, name: P.name, icon: P.icon, summary: P.summary, configurationSchemaJSON: P.configurationSchemaJSON, webFiles: P.webFiles, assistantActions: P.assistantActions, assistantBackground: P.assistantBackground, accountAuthorization: P.accountAuthorization,
                 deviceIDOfAccessory: { P.deviceID(ofAccessory: $0) }) { json, context in
            let configuration = try JSONDecoder().decode(P.Configuration.self, from: json)
            return try await P(configuration: configuration, context: context)
        }
    }

    /// Registers plugin types from a list. (Not an overload of `register(_:)` taking one existential: the
    /// call inside it would resolve to itself and recurse.)
    public mutating func register(_ types: [any HomeswiftPlugin.Type]) {
        func open<P: HomeswiftPlugin>(_: P.Type) { register(P.self) }
        for type in types { open(type) }
    }

    public mutating func register(
        platform: String, name: String, icon: String? = nil, summary: String? = nil, configurationSchemaJSON: String? = nil, webFiles: [String: WebFile] = [:], assistantActions: [AssistantAction] = [],
        assistantBackground: String? = nil, accountAuthorization: AuthorizationMethod = .none, deviceIDOfAccessory: (@Sendable (String) -> String?)? = nil,
        make: @escaping @Sendable (_ configuration: Data, _ context: PluginContext) async throws -> any HomeswiftPlugin
    ) {
        if byPlatform[platform] == nil { order.append(platform) }
        byPlatform[platform] = Entry(
            platform: platform, name: name, icon: icon, summary: summary, configurationSchemaJSON: configurationSchemaJSON, webFiles: webFiles, assistantActions: assistantActions, assistantBackground: assistantBackground, accountAuthorization: accountAuthorization, deviceIDOfAccessory: deviceIDOfAccessory, make: make)
    }

    /// In registration order.
    public var entries: [Entry] { order.compactMap { byPlatform[$0] } }

    public func entry(for platform: String) -> Entry? { byPlatform[platform] }
}
