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
        let make: @Sendable (_ configuration: Data, _ context: PluginContext) async throws -> any HomeswiftPlugin
    }

    private var byPlatform: [String: Entry] = [:]
    private var order: [String] = []

    public init() {}

    public init(_ plugins: [any HomeswiftPlugin.Type]) {
        register(plugins)
    }

    public mutating func register<P: HomeswiftPlugin>(_ type: P.Type) {
        register(platform: P.platform, name: P.name) { json, context in
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
        platform: String, name: String,
        make: @escaping @Sendable (_ configuration: Data, _ context: PluginContext) async throws -> any HomeswiftPlugin
    ) {
        if byPlatform[platform] == nil { order.append(platform) }
        byPlatform[platform] = Entry(platform: platform, name: name, make: make)
    }

    /// In registration order.
    public var entries: [Entry] { order.compactMap { byPlatform[$0] } }

    public func entry(for platform: String) -> Entry? { byPlatform[platform] }
}
