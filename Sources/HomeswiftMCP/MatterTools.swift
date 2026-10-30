import HomeswiftAI
import NIOConcurrencyHelpers

/// The Matter bridge as the catalog sees it: what the MCP tools and the web UI read and do. `HomeswiftMatter`
/// implements it; the CLI sets it on the catalog when the `HomeswiftMatter` block is configured.
public protocol MatterControl: Sendable {
    /// Whether it is commissioned, the commissioning window, the fabrics and the bridged devices. The pairing codes
    /// (the QR code's text, the manual code) only with `includePairing`, and only while the window is open.
    func statusJSON(includePairing: Bool) async -> JSONValue
    /// Stops the bridge: the CLI's shutdown, and a saved block that starts a new one.
    func stop() async
    /// Opens the commissioning window for another ecosystem (Google Home, Alexa, Home Assistant) to add the bridge.
    func openCommissioningWindow(minutes: Int) async throws -> JSONValue
    /// Removes a fabric: that ecosystem loses the bridge and its devices.
    func removeFabric(index: Int) async throws -> JSONValue
}

/// Where the catalog finds the Matter bridge, once it runs. Shared by the catalog's copies.
public final class MatterControlSlot: Sendable {
    private let box = NIOLockedValueBox<(any MatterControl)?>(nil)
    public init() {}
    public var current: (any MatterControl)? {
        get { box.withLockedValue { $0 } }
        set { box.withLockedValue { $0 = newValue } }
    }
}

extension HomeswiftCatalog {
    /// The Matter bridge, or an error saying it is not configured.
    func requireMatter() throws -> any MatterControl {
        guard let matter = matter.current else {
            throw CatalogError("The Matter bridge is off: add a HomeswiftMatter block to config.json to turn it on")
        }
        return matter
    }

    var matterTools: [MCPTool] {
        let catalog = self
        return [
            MCPTool(
                name: "get_matter_status", title: "Matter bridge status",
                description: "The Matter bridge, which puts the plugins' accessories in Google Home, Alexa, SmartThings or Home Assistant: "
                    + "whether it is commissioned, whether its commissioning window is open, the fabrics (one per ecosystem) and the bridged devices. "
                    + "The pairing code is never given out here: the user reads it in the web UI or where homeswift prints it.",
                scope: .read, idempotent: true
            ) { _ in .json(await (try catalog.requireMatter()).statusJSON(includePairing: false)) },
            MCPTool(
                name: "open_matter_commissioning_window", title: "Open the Matter commissioning window",
                description: "Lets another ecosystem add the Matter bridge for the next minutes (15 at most, the default): the user then scans the "
                    + "QR code or types the pairing code from the web UI in that ecosystem's app.",
                inputSchema: ["type": "object", "properties": [
                    "minutes": ["type": "integer", "minimum": 3, "maximum": 15, "description": "How long the window stays open (default 15)"],
                ]],
                scope: .admin
            ) { call in .json(try await catalog.requireMatter().openCommissioningWindow(minutes: call.int("minutes", default: 15))) },
            MCPTool(
                name: "remove_matter_fabric", title: "Remove a Matter fabric",
                description: "Removes one ecosystem (a fabric from get_matter_status) from the Matter bridge: it loses the bridge and every device on it, "
                    + "with their rooms and automations, and the user must add the bridge again with the pairing code.",
                inputSchema: ["type": "object", "required": ["index"], "properties": [
                    "index": ["type": "integer", "minimum": 1, "maximum": 254, "description": "The fabric's index, from get_matter_status"],
                ]],
                scope: .admin, destructive: true, idempotent: true
            ) { call in
                guard let index = call.arguments["index"]?.intValue else { throw JSONRPCError.invalidParams("index is required") }
                return .json(try await catalog.requireMatter().removeFabric(index: index))
            },
        ]
    }
}
