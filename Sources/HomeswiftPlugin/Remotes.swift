import Foundation
import Homeswift
import NIOConcurrencyHelpers

// Remotes (GLOSSARY.md, "Remotes"): accessories whose Buttons and Wheels send presses rather than show a state, from any
// plugin. A plugin that knows more than HomeKit's three presses (when a hold ends, how far a Wheel turned) declares its
// Remote's layout and reports each moment; for the others the bridge reads the presses HomeKit gets. Either way the
// plugin sends HomeKit's presses itself: they are its device's own mapping (a Tap dial's turn, a wheel's count).

/// What a Remote's Button or Wheel just did, as its plugin reports it (`PluginContext.remoteMoment`).
public enum RemoteMoment: Sendable, Equatable {
    case press
    case doublePress
    /// A long press whose end is not known (HomeKit's long press): a hold that dims stops on its own.
    case longPress
    /// Held: the end comes as `holdEnd`.
    case holdStart
    case holdEnd
    /// A Wheel turned by so many notches, up when positive.
    case turned(Int)
}

/// One Button or Wheel of a Remote.
/// A Remote as the host knows it (`PluginHost.remote(of:)`): its name, its Buttons and Wheels (what its plugin declared,
/// else a Button per switch), whether its plugin reports their moments, and its Controls.
public struct RemoteState: Sendable {
    public var name: String
    public var layout: RemoteLayout
    /// Its plugin declared it (`declareRemote`), and reports its moments.
    public var isDeclared: Bool
    public var controls: [RemoteControl]
}

public struct RemotePart: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case button, wheel }

    /// Its id among the Remote's parts, which its Controls name: a Button's Stateless Programmable Switch subtype
    /// (`RemoteLayout.partID(of:)`), or what the plugin calls it.
    public var id: String
    public var kind: Kind
    /// What a person calls it ("Channel 2 wheel"); the Name HomeKit shows when nil.
    public var name: String?
    /// The Channel it belongs to (GLOSSARY.md), counted from 1; nil on a Remote without them.
    public var channel: Int?
    /// The Stateless Programmable Switches HomeKit numbers for it (their subtypes): one for a Button, a Wheel's two
    /// directions; a press on any of them is this part's (the Remotes page finds a part by them).
    public var services: [String]

    public init(id: String, kind: Kind, name: String? = nil, channel: Int? = nil, services: [String]) {
        self.id = id
        self.kind = kind
        self.name = name
        self.channel = channel
        self.services = services
    }

    /// A Button that is one Stateless Programmable Switch, by its part id (`RemoteLayout.partID(of:)`).
    public static func button(_ id: String, name: String? = nil, channel: Int? = nil) -> RemotePart {
        RemotePart(id: id, kind: .button, name: name, channel: channel, services: [id])
    }
}

/// A Remote's Buttons and Wheels, in its own order.
public struct RemoteLayout: Sendable, Equatable, Codable {
    public var parts: [RemotePart]

    public init(parts: [RemotePart]) {
        self.parts = parts
    }

    /// The id of a Button that is one Stateless Programmable Switch: its subtype, else its iid.
    public static func partID(of service: Service) -> String {
        service.subtype ?? "iid:\(service.iid)"
    }

    /// A Button per Stateless Programmable Switch, named as HomeKit names it: a Remote whose plugin declares none, or the
    /// layout a plugin declares for a remote whose switches are all buttons.
    public static func inferred(from accessory: Accessory) -> RemoteLayout {
        let buttons = accessory.services.filter { $0.type == .statelessProgrammableSwitch }
        return RemoteLayout(parts: buttons.map { .button(partID(of: $0), name: $0[.name]?.value.stringValue) })
    }

    /// The part a Stateless Programmable Switch of the Remote is part of.
    public func part(service: Service) -> RemotePart? {
        let id = Self.partID(of: service)
        return parts.first { $0.services.contains(id) }
    }
}

extension Accessory {
    /// Whether it is a Remote (GLOSSARY.md): it has Buttons, and is no doorbell (whose button rings).
    public var isRemote: Bool {
        services.contains { $0.type == .statelessProgrammableSwitch } && !services.contains { $0.type == .doorbell }
    }
}

extension PluginContext {
    /// Declares one of its accessories a Remote with these Buttons and Wheels, replacing what it said before: it reports each
    /// of their moments (`remoteMoment`), and the bridge no longer reads the presses HomeKit gets from it as moments. The
    /// plugin still sends HomeKit's presses itself. Removing the accessory forgets it.
    public func declareRemote(_ accessoryID: String, _ layout: RemoteLayout) {
        remoteLayouts.withLockedValue { $0[accessoryID] = layout }
    }

    /// What it declared of one of its Remotes; nil when it declared nothing.
    public func remoteLayout(of accessoryID: String) -> RemoteLayout? {
        remoteLayouts.withLockedValue { $0[accessoryID] }
    }

    /// A moment of a declared Remote's part: the bridge runs the part's Controls. Nothing happens in a context no host runs.
    public func remoteMoment(_ moment: RemoteMoment, part: String, of accessoryID: String) {
        remoteMoments?(accessoryID, part, moment)
    }
}
