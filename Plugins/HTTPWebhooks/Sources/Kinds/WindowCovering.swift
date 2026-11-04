import Foundation
import Homeswift
import HomeswiftPlugin

/// `windowcoverings[]`: a Window Covering. `currentposition`, `targetposition` (0–100) and `positionstate` (0
/// decreasing, 1 increasing, 2 stopped) set it. HomeKit's Target Position calls one of six groups by the position, as the
/// Homebridge plugin maps them: 0 `open_*`, 1–25 `open_20_*`, 26–45 `open_40_*`, 46–65 `open_60_*`, 66–94 `open_80_*`,
/// 95 and above `close_*`; with `auto_set_current_position`, the current position follows a second after a call that
/// worked.
final class WindowCoveringAccessory: WebhookAccessory {
    let id: String
    let name: String
    let accessory: Accessory
    private let current: StatePair
    private let target: StatePair
    private let state: StatePair
    private let environment: KindEnvironment

    /// The action of a target position.
    static func action(for position: Int) -> String {
        switch position {
        case ...0: "open"
        case 1...25: "open_20"
        case 26...45: "open_40"
        case 46...65: "open_60"
        case 66...94: "open_80"
        default: "close"
        }
    }

    init(id: String, name: String, entry: HTTPWebhooksPlugin.Entry, environment: KindEnvironment) {
        self.id = id
        self.name = name
        self.environment = environment
        let service = Service(.windowCovering, name: name, isPrimary: true)
        current = StatePair(
            parameter: "currentposition", key: "http-webhook-current-position-\(id)", characteristic: service.characteristic(.currentPosition),
            fallback: 100, field: "CurrentPosition")
        target = StatePair(
            parameter: "targetposition", key: "http-webhook-target-position-\(id)", characteristic: service.characteristic(.targetPosition),
            fallback: 100, field: "TargetPosition")
        state = StatePair(
            parameter: "positionstate", key: "http-webhook-position-state-\(id)", characteristic: service.characteristic(.positionState),
            fallback: 2, field: "PositionState")
        accessory = HTTPWebhooksPlugin.accessory("WindowCovering", id: id, name: name, category: .windowCovering, services: [service])
        for pair in [current, target, state] { pair.characteristic.show(pair.stored(environment.store)) }

        let calls = Dictionary(uniqueKeysWithValues: ["open", "open_20", "open_40", "open_60", "open_80", "close"].map { ($0, entry.call($0)) })
        let follows = entry.flag("auto_set_current_position", default: false)
        let coalesce = LatestCallGuard(delay: environment.timing.coalescing)
        let (current, target) = (current, target)
        target.characteristic.onWrite { [environment, name] value in
            let position = value.intValue ?? 0
            guard await coalesce() else { return }
            environment.logger.info("\(name): setting target position to \(position) for \(id)")
            try await environment.send(calls[Self.action(for: position)] ?? nil, name: name, slow: true)
            environment.store.set(target.key, Double(position))
            guard follows else { return }
            environment.store.set(current.key, Double(position))
            environment.tasks.add {
                guard (try? await Task.sleep(for: environment.timing.currentPositionDelay)) != nil else { return }
                current.characteristic.show(Double(position))
            }
        }
    }

    func handle(_ query: WebhookQuery) -> WebhookReply {
        [current, target, state].reply(to: query, environment: environment, name: name)
    }
}
