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
