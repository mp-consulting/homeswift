import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// The Matter bridge as the catalog sees it: what the MCP tools and the web UI read and do. `HomeswiftMatter`
/// implements it; the CLI sets it on the catalog when the `HomeswiftMatter` block is configured.
public protocol MatterControl: Sendable {
    /// Whether it is commissioned, the commissioning window, the fabrics and the bridged devices, and the same for each
    /// accessory that is a Matter device of its own (`ownDevices`). The pairing codes (the QR code's text, the manual
    /// code) only with `includePairing`, and only while a window is open.
    func statusJSON(includePairing: Bool) async -> JSONValue
    /// The QR code's text of the bridge, or of the device `device`, while its window is open.
    func qrCode(device: String?) async -> String?
    /// Stops the bridge: the CLI's shutdown, and a saved block that starts a new one.
    func stop() async
    /// Opens the commissioning window for another ecosystem (Google Home, Alexa, Home Assistant) to add the bridge, or
    /// the accessory `device` that is a Matter device of its own.
    func openCommissioningWindow(minutes: Int, device: String?) async throws -> JSONValue
    /// Removes a fabric of the bridge (that ecosystem loses it and its devices), or of the device `device`.
    func removeFabric(index: Int, device: String?) async throws -> JSONValue
}

/// Where the catalog finds the Matter bridge, once it runs. Shared by the catalog's copies.
public final class MatterControlSlot: Sendable {
    private let box = NIOLockedValueBox<(any MatterControl)?>(nil)
    private let mapsBox = NIOLockedValueBox<(@Sendable (_ accessory: Accessory, _ exposeSecurity: Bool) -> Bool)?>(nil)
    public init() {}
    public var current: (any MatterControl)? {
        get { box.withLockedValue { $0 } }
        set { box.withLockedValue { $0 = newValue } }
    }
    private let listeners = NIOLockedValueBox<[UUID: @Sendable (_ device: String?) -> Void]>([:])
    /// Calls `observer` when the bridge (nil) or the accessory that is a Matter device of its own (its id) is added to
    /// an ecosystem or removed from one, or opens or closes its commissioning window: the web UI's pages follow it.
    public func observeChanges(_ observer: @escaping @Sendable (_ device: String?) -> Void) -> Observation {
        let id = UUID()
        listeners.withLockedValue { $0[id] = observer }
        return Observation { [listeners] in _ = listeners.withLockedValue { $0.removeValue(forKey: id) } }
    }
    /// The running bridge says what changed (the CLI passes its changes on).
    public func changed(device: String?) {
        for listener in listeners.withLockedValue({ Array($0.values) }) { listener(device) }
    }
    /// Whether Matter can show an accessory (set by the CLI, which has the mapping): the switch refuses one it cannot.
    public var maps: (@Sendable (_ accessory: Accessory, _ exposeSecurity: Bool) -> Bool)? {
        get { mapsBox.withLockedValue { $0 } }
        set { mapsBox.withLockedValue { $0 = newValue } }
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

    /// Makes an accessory a Matter device of its own, with its own pairing code, or puts it back: its id in the
    /// `HomeswiftMatter` block's `devices`. A block made for it runs no bridge, so only that accessory is on Matter.
    public func setMatterDevice(_ id: String, own: Bool) async throws -> JSONValue {
        let block = try readConfig()["platforms"]?.arrayValue?.first { $0["platform"]?.stringValue == "HomeswiftMatter" }
        if own {
            guard let accessory = host.bridges.lazy.compactMap({ $0.server.accessories.first { $0.id == id } }).first else {
                throw CatalogError("No accessory \(id): list_accessories gives the ids")
            }
            if let maps = matter.maps, !maps(accessory, block?["exposeSecurity"]?.boolValue ?? false) {
                throw CatalogError("Matter has nothing to show for \(accessory.name): its services have no Matter device type (locks need exposeSecurity)")
            }
        }
        let exists = block != nil
        return try await editBlock(platform: "HomeswiftMatter", name: nil, dryRun: false) { block in
            if !exists { block["bridge"] = false }
            var devices = (block["devices"]?.arrayValue ?? []).compactMap(\.stringValue).filter { $0 != id }
            if own { devices.append(id) }
            block["devices"] = .array(devices.map { .string($0) })
        }
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
                description: "Lets another ecosystem add the Matter bridge, or an accessory that is a Matter device of its own, for the next "
                    + "minutes (15 at most, the default): the user then scans the QR code or types the pairing code from the web UI in that ecosystem's app.",
                inputSchema: ["type": "object", "properties": [
                    "minutes": ["type": "integer", "minimum": 3, "maximum": 15, "description": "How long the window stays open (default 15)"],
                    "device": ["type": "string", "description": "The accessory id of a Matter device of its own (get_matter_status's ownDevices); omit for the bridge"],
                ]],
                scope: .admin
            ) { call in
                .json(try await catalog.requireMatter().openCommissioningWindow(minutes: call.int("minutes", default: 15), device: call.optionalString("device")))
            },
            MCPTool(
                name: "remove_matter_fabric", title: "Remove a Matter fabric",
                description: "Removes one ecosystem (a fabric from get_matter_status) from the Matter bridge, or from a Matter device of its own: it "
                    + "loses the bridge and every device on it (or that device), with their rooms and automations, and the user must add it again with the pairing code.",
                inputSchema: ["type": "object", "required": ["index"], "properties": [
                    "index": ["type": "integer", "minimum": 1, "maximum": 254, "description": "The fabric's index, from get_matter_status"],
                    "device": ["type": "string", "description": "The accessory id of a Matter device of its own; omit for the bridge"],
                ]],
                scope: .admin, destructive: true
            ) { call in
                guard let index = call.arguments["index"]?.intValue else { throw JSONRPCError.invalidParams("index is required") }
                return .json(try await catalog.requireMatter().removeFabric(index: index, device: call.optionalString("device")))
            },
            MCPTool(
                name: "set_matter_device", title: "Make an accessory a Matter device of its own",
                description: "Turns an accessory into a Matter device of its own (own: true), with its own pairing code, which Apple Home, Google Home "
                    + "or Alexa add as the device itself rather than through the bridge; own: false puts it back. Matter restarts with the change. "
                    + "The pairing code is shown in the web UI, never here.",
                inputSchema: ["type": "object", "required": ["id", "own"], "properties": [
                    "id": ["type": "string", "description": "The accessory's id, from list_accessories"],
                    "own": ["type": "boolean"],
                ]],
                scope: .admin
            ) { call in
                guard let own = call.arguments["own"]?.boolValue else { throw JSONRPCError.invalidParams("own is required") }
                return .json(try await catalog.setMatterDevice(try call.string("id"), own: own))
            },
        ]
    }
}
