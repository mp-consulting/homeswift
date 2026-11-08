import Foundation
import Homeswift
import NIOConcurrencyHelpers

/// A subscription (to the host's characteristic changes, to the log) that `cancel()` ends. Dropping the token
/// does not: whoever subscribes for a while, a web UI or an MCP server that may be restarted, cancels on stop.
public final class Observation: Sendable {
    private let onCancel: NIOLockedValueBox<(@Sendable () -> Void)?>

    public init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = NIOLockedValueBox(onCancel)
    }

    public func cancel() {
        onCancel.withLockedValue { action in
            defer { action = nil }
            return action
        }?()
    }
}

/// Characteristic changes from every HAP server the host runs, for whoever follows them. Each server is followed
/// once, when the host adds it (at start, a child bridge, a television published later), so a subscriber sees
/// servers that did not exist when it subscribed.
final class ChangeFeed: Sendable {
    private let observers = NIOLockedValueBox<[UUID: HAPServer.ChangeObserver]>([:])
    /// Those of writes (`HAPServer.observeWrites`).
    private let writeObservers = NIOLockedValueBox<[UUID: HAPServer.ChangeObserver]>([:])

    func follow(_ server: HAPServer) {
        server.observeChanges { [self] accessory, characteristic, value in
            for observer in observers.withLockedValue({ Array($0.values) }) { observer(accessory, characteristic, value) }
        }
        server.observeWrites { [self] accessory, characteristic, value in
            for observer in writeObservers.withLockedValue({ Array($0.values) }) { observer(accessory, characteristic, value) }
        }
    }

    func add(_ observer: @escaping HAPServer.ChangeObserver) -> Observation {
        let id = UUID()
        observers.withLockedValue { $0[id] = observer }
        return Observation { [self] in _ = observers.withLockedValue { $0.removeValue(forKey: id) } }
    }

    func addWrites(_ observer: @escaping HAPServer.ChangeObserver) -> Observation {
        let id = UUID()
        writeObservers.withLockedValue { $0[id] = observer }
        return Observation { [self] in _ = writeObservers.withLockedValue { $0.removeValue(forKey: id) } }
    }
}

/// Accessories added, replaced or removed on every HAP server the host runs, and servers it adds (a child bridge, a
/// television published after start), followed the way `ChangeFeed` follows changes.
final class StructureFeed: Sendable {
    private let observers = NIOLockedValueBox<[UUID: @Sendable () -> Void]>([:])

    func follow(_ server: HAPServer) {
        server.observeStructure { [self] in notify() }
        notify()
    }

    private func notify() {
        for observer in observers.withLockedValue({ Array($0.values) }) { observer() }
    }

    func add(_ observer: @escaping @Sendable () -> Void) -> Observation {
        let id = UUID()
        observers.withLockedValue { $0[id] = observer }
        return Observation { [self] in _ = observers.withLockedValue { $0.removeValue(forKey: id) } }
    }
}

/// How long requests and handlers take on every HAP server the host runs (`HAPServer.Timing`), with the server's
/// bridge, followed the way `ChangeFeed` follows changes.
final class TimingFeed: Sendable {
    private let observers = NIOLockedValueBox<[UUID: @Sendable (PluginHost.Bridge, HAPServer.Timing) -> Void]>([:])

    func follow(_ bridge: PluginHost.Bridge) {
        bridge.server.observeTimings { [self, weak bridge] timing in
            guard let bridge else { return }
            for observer in observers.withLockedValue({ Array($0.values) }) { observer(bridge, timing) }
        }
    }

    func add(_ observer: @escaping @Sendable (PluginHost.Bridge, HAPServer.Timing) -> Void) -> Observation {
        let id = UUID()
        observers.withLockedValue { $0[id] = observer }
        return Observation { [self] in _ = observers.withLockedValue { $0.removeValue(forKey: id) } }
    }
}

/// What a feed carries to whoever follows it, those published while no one follows yet waiting for the first follower:
/// the energy history plugins import (`PluginContext.importEnergy`), and the readings of the Meters they declare
/// (`PluginContext.meter`), which a plugin makes as it starts, before the metrics store follows the host. At most
/// `limit` wait; the oldest go first.
final class QueuedFeed<Payload: Sendable>: Sendable {
    private struct State {
        var observers: [UUID: @Sendable (Payload) -> Void] = [:]
        var pending: [Payload] = []
    }
    private let state = NIOLockedValueBox(State())
    private let limit: Int
    /// What waits whatever the limit (what the first follower must hear, however many came after).
    private let keeping: @Sendable (Payload) -> Bool

    init(limit: Int = 10_000, keeping: @escaping @Sendable (Payload) -> Bool = { _ in false }) {
        self.limit = limit
        self.keeping = keeping
    }

    func publish(_ payload: Payload) {
        let observers = state.withLockedValue { state -> [@Sendable (Payload) -> Void] in
            if state.observers.isEmpty {
                state.pending.append(payload)
                if state.pending.count > limit, let oldest = state.pending.firstIndex(where: { !keeping($0) }) { state.pending.remove(at: oldest) }
            }
            return Array(state.observers.values)
        }
        for observer in observers { observer(payload) }
    }

    func add(_ observer: @escaping @Sendable (Payload) -> Void) -> Observation {
        let id = UUID()
        let pending = state.withLockedValue { state -> [Payload] in
            state.observers[id] = observer
            defer { state.pending = [] }
            return state.pending
        }
        for payload in pending { observer(payload) }
        return Observation { [self] in _ = state.withLockedValue { $0.observers.removeValue(forKey: id) } }
    }
}

/// An energy history a plugin imported, with its key as the source; `forget` instead drops everything it imported
/// (`PluginContext.forgetImportedEnergy`), and carries no hours.
struct EnergyImport: Sendable {
    var source: String
    var hours: [EnergyHourImport]
    var forget = false
}

typealias EnergyImportFeed = QueuedFeed<EnergyImport>
typealias MeterFeed = QueuedFeed<MeterReading>

/// The readings plugins record with `PluginContext.recordValue`, to whoever follows them (the metrics store).
final class ValueFeed: Sendable {
    private let observers = NIOLockedValueBox<[UUID: @Sendable (String, Double, EnergyTag?) -> Void]>([:])

    func publish(_ series: String, _ value: Double, _ tag: EnergyTag?) {
        // The dictionary itself, not an array of it: a plugin publishes dozens of readings every few seconds.
        for observer in observers.withLockedValue({ $0 }).values { observer(series, value, tag) }
    }

    func add(_ observer: @escaping @Sendable (String, Double, EnergyTag?) -> Void) -> Observation {
        let id = UUID()
        observers.withLockedValue { $0[id] = observer }
        return Observation { [self] in _ = observers.withLockedValue { $0.removeValue(forKey: id) } }
    }
}
