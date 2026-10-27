import Foundation
import Homeswift
import NIOConcurrencyHelpers

/// A subscription (to the host's characteristic changes, to the log) that `cancel()` ends. Dropping the token
/// does not: whoever subscribes for a while, a web UI or an MCP server that may be restarted, cancels on stop.
public final class Observation: Sendable {
    private let onCancel: NIOLockedValueBox<(@Sendable () -> Void)?>

    init(_ onCancel: @escaping @Sendable () -> Void) {
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

    func follow(_ server: HAPServer) {
        server.observeChanges { [self] accessory, characteristic, value in
            for observer in observers.withLockedValue({ Array($0.values) }) { observer(accessory, characteristic, value) }
        }
    }

    func add(_ observer: @escaping HAPServer.ChangeObserver) -> Observation {
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

/// The energy history plugins import with `PluginContext.importEnergy`, by source (the plugin's key), to whoever
/// follows them (the metrics store's archive). Imports made while no one follows yet (a plugin that imports as it
/// starts, before the metrics store follows the host) wait, and go to the first follower.
final class EnergyImportFeed: Sendable {
    private struct State {
        var observers: [UUID: @Sendable (String, [EnergyHourImport]) -> Void] = [:]
        var pending: [(String, [EnergyHourImport])] = []
    }
    private let state = NIOLockedValueBox(State())

    func publish(_ source: String, _ hours: [EnergyHourImport]) {
        let observers = state.withLockedValue { state -> [@Sendable (String, [EnergyHourImport]) -> Void] in
            if state.observers.isEmpty { state.pending.append((source, hours)) }
            return Array(state.observers.values)
        }
        for observer in observers { observer(source, hours) }
    }

    func add(_ observer: @escaping @Sendable (String, [EnergyHourImport]) -> Void) -> Observation {
        let id = UUID()
        let pending = state.withLockedValue { state -> [(String, [EnergyHourImport])] in
            state.observers[id] = observer
            defer { state.pending = [] }
            return state.pending
        }
        for (source, hours) in pending { observer(source, hours) }
        return Observation { [self] in _ = state.withLockedValue { $0.observers.removeValue(forKey: id) } }
    }
}

/// The readings plugins record with `PluginContext.recordValue`, to whoever follows them (the metrics store).
final class ValueFeed: Sendable {
    private let observers = NIOLockedValueBox<[UUID: @Sendable (String, Double, EnergyTag?) -> Void]>([:])

    func publish(_ series: String, _ value: Double, _ tag: EnergyTag?) {
        for observer in observers.withLockedValue({ Array($0.values) }) { observer(series, value, tag) }
    }

    func add(_ observer: @escaping @Sendable (String, Double, EnergyTag?) -> Void) -> Observation {
        let id = UUID()
        observers.withLockedValue { $0[id] = observer }
        return Observation { [self] in _ = observers.withLockedValue { $0.removeValue(forKey: id) } }
    }
}
