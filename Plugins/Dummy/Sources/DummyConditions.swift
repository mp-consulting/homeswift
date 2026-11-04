import Foundation
import HomeswiftPlugin

/// The condition engine (spec 7.6): other accessories' states, lines of the bridge's log, reachability.
extension DummyEngine {
    /// An accessory's state, for the accessories whose conditions name it. Its first report only records it.
    func report(_ device: DummyDevice) {
        guard let state = device.conditionState else { return }
        let first = reported[device.identifier] == nil
        reported[device.identifier] = state
        guard !first else { return }
        for target in watchers[device.identifier] ?? [] {
            guard let watcher = devices[target] else { continue }
            act(on: watcher)
        }
    }

    /// Triggers the accessory when its conditions hold, resets it otherwise unless an auto-reset does that.
    func act(on device: DummyDevice) {
        // Accessories whose conditions name each other would otherwise act on each other without end.
        guard device.config.conditions != nil, !stopped, acting.insert(device.identifier).inserted else { return }
        defer { acting.remove(device.identifier) }
        if evaluate(device, forLog: false) {
            info(device, "\(device.name) conditions have been satisfied. Triggering…")
            trigger(device, source: .condition)
        } else if device.config.autoReset == nil {
            reset(device, source: .conditionReset)
        }
    }

    static let families: [String: String] = ["on": "power", "off": "power", "open": "position", "closed": "position", "locked": "lock", "unlocked": "lock"]

    func evaluate(_ device: DummyDevice, forLog: Bool) -> Bool {
        guard let conditions = device.config.conditions else { return false }
        var results: [Bool] = []
        for operand in conditions.operands {
            switch operand {
            case .log:
                if conditions.operator == .or || forLog { continue }
                return false
            case .accessory(let id, let desired):
                guard let state = reported[id] else { return false }
                if Self.families[state] != Self.families[desired] {
                    logger.error("\(device.name) compares '\(state)' with '\(desired)': is there a typo in its conditions?")
                    results.append(false)
                } else {
                    results.append(state == desired)
                }
            case .ping(let host, let available, _):
                guard let reachable = reachability[host] else { return false }
                results.append(reachable == available)
            }
        }
        if verbose { debug("\(device.name) conditions: \(results)") }
        guard !results.isEmpty else { return true }
        return conditions.operator == .and ? !results.contains(false) : results.contains(true)
    }

    // MARK: Log lines

    /// The log patterns of every accessory: a pattern that is not a regular expression matches as text.
    func registerLogPatterns() -> Bool {
        for identifier in order {
            guard let device = devices[identifier], let conditions = device.config.conditions else { continue }
            for case .log(let pattern) in conditions.operands {
                logPatterns.append((identifier, try? NSRegularExpression(pattern: pattern), pattern))
            }
        }
        return !logPatterns.isEmpty
    }

    func logLine(_ text: String) {
        guard !stopped else { return }
        let range = NSRange(text.startIndex..., in: text)
        for (identifier, regex, literal) in logPatterns {
            let matched = regex.map { $0.firstMatch(in: text, range: range) != nil } ?? text.contains(literal)
            guard matched, let device = devices[identifier], let conditions = device.config.conditions else { continue }
            // Not in an autoclosure of `||`: Linux's compiler takes the device for sent out of the actor.
            var satisfied = conditions.operands.count == 1 || conditions.operator == .or
            if !satisfied { satisfied = evaluate(device, forLog: true) }
            if satisfied {
                info(device, "\(device.name) conditions have been satisfied. Triggering…")
                trigger(device, source: .condition)
            }
        }
    }

    // MARK: Reachability

    func startPings(_ device: DummyDevice) {
        guard let conditions = device.config.conditions else { return }
        for case .ping(let host, _, let interval) in conditions.operands where pingTimers[host] == nil {
            if ReachabilityTarget(host) == nil {
                logger.warning("\(device.name): \(host) cannot be checked (a MAC address needs an ARP scan, which Homeswift does not run)")
                continue
            }
            pingTimers[host] = scheduler.after(milliseconds: 0) { [weak self] in await self?.check(host, every: interval) }
        }
    }

    func check(_ host: String, every interval: Double) async {
        guard !stopped, let target = ReachabilityTarget(host) else { return }
        let result = await dependencies.probe.isReachable(target)
        guard !stopped else { return }
        if let result {
            if reachability[host] != result { debug("\(host) is \(result ? "reachable" : "unreachable")") }
            reachability[host] = result
        } else {
            logger.warning("Could not check whether \(host) is reachable")
        }
        for identifier in order {
            guard let device = devices[identifier], let conditions = device.config.conditions,
                  conditions.operands.contains(where: { if case .ping(host, _, _) = $0 { true } else { false } }) else { continue }
            act(on: device)
        }
        pingTimers[host] = scheduler.after(milliseconds: interval) { [weak self] in await self?.check(host, every: interval) }
    }
}
