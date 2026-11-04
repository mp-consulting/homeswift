import Foundation
import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// A blind or a curtain (9.3): its position, its tilt, Hold Position, and the two ways it says it is moving: a
/// `motor_state`, or positions that keep changing, asked for every few seconds while it moves.
final class CoverHandler: ServiceHandler, @unchecked Sendable {
    let service: Service
    let gettableKeys: [String]
    private let position: Expose
    private let tilt: Expose?
    private let motorState: Expose?
    private let link: DeviceLink
    private let polls: Bool
    private let lock = NIOLock()

    private var lastSent = -1.0
    private var current = -1.0
    private var awaitingUpdate = false
    private var ignoreNextIfEqual = false
    private var motor: String?
    private var previousMotor: String?
    private var targetSetByHomeKit = false
    private var timer: Task<Void, Never>?

    static let decreasing = 0, increasing = 1, stopped = 2

    init(service: Service, position: Expose, tilt: Expose?, state: Expose?, motorState: Expose?, link: DeviceLink) {
        self.service = service
        self.position = position
        self.tilt = tilt
        self.motorState = motorState
        self.link = link
        polls = position.isGettable && motorState == nil
        gettableKeys = [position.gettableProperty, tilt?.gettableProperty, motorState?.gettableProperty].compactMap { $0 }
        service.characteristic(.targetPosition).onWrite { [weak self] value in self?.targetWritten(value.doubleValue ?? 0) }
        if let tilt, let property = tilt.property, let low = tilt.valueMin, let high = tilt.valueMax {
            service.characteristic(.targetHorizontalTiltAngle).onWrite { value in
                let device = ColorMath.jsRound(linearScale(value.doubleValue ?? 0, from: -90, 90, to: low, high))
                link.set([property: .number(device)])
            }
        }
        if let state, let property = state.property {
            service.characteristic(.holdPosition).onWrite { value in
                if value.boolValue == true { link.set([property: "STOP"]) }
            }
        }
    }

    deinit { timer?.cancel() }

    private var range: (Double, Double) { (position.valueMin ?? 0, position.valueMax ?? 100) }

    private func targetWritten(_ percent: Double) {
        guard let property = position.property else { return }
        let (low, high) = range
        let target = linearScale(percent, from: 0, 100, to: low, high)
        link.set([property: .number(target)])
        let positionState: Int? = lock.withLock {
            var state: Int?
            if motorState == nil {
                state = target > current ? Self.increasing : target < current ? Self.decreasing : Self.stopped
            } else {
                targetSetByHomeKit = true
            }
            lastSent = target
            if position.isGettable { ignoreNextIfEqual = true }
            awaitingUpdate = true
            if polls { restartTimer() }
            return state
        }
        if let positionState { service.characteristic(.positionState).value = .int(positionState) }
    }

    /// Asks for the position every few seconds while an update is awaited. Called with the lock held.
    private func restartTimer() {
        timer?.cancel()
        let interval = link.coverPollInterval
        guard let property = position.property else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                if lock.withLock({ awaitingUpdate }) { link.get([property]) }
            }
        }
    }

    func update(_ message: [String: JSONValue]) {
        if let tilt, let property = tilt.property, let value = message[property]?.doubleValue, let low = tilt.valueMin, let high = tilt.valueMax, low != high {
            service.characteristic(.currentHorizontalTiltAngle).value = .int(Int(ColorMath.jsRound(linearScale(value, from: low, high, to: -90, 90))))
        }
        if let property = motorState?.property, let value = message[property] {
            let text = value.stringValue
            lock.withLock { motor = text == "opening" || text == "closing" ? text : "stopped" }
        }
        guard let property = position.property, let value = message[property]?.doubleValue else { return }
        let (low, high) = range
        let scaled = Int(ColorMath.jsRound(low == high ? value : linearScale(value, from: low, high, to: 0, 100)))
        enum Show { case nothing, current(stopped: Bool), motor(state: Int, target: Int?, current: Int?) }
        let show: Show = lock.withLock {
            let ignore = ignoreNextIfEqual && value == lastSent
            ignoreNextIfEqual = false
            if ignore {
                link.log.debug("\(link.displayName): ignoring position \(value), the one just sent")
                return .nothing
            }
            awaitingUpdate = false
            var isStopped = true
            if timer != nil {
                if value == current {
                    timer?.cancel()
                    timer = nil
                } else {
                    isStopped = false
                    awaitingUpdate = true
                    restartTimer()
                }
            }
            current = value
            guard motorState != nil else { return .current(stopped: isStopped) }
            guard motor != previousMotor else { return .nothing }
            defer {
                previousMotor = motor
                targetSetByHomeKit = false
            }
            let fromHomeKit = targetSetByHomeKit
            switch motor {
            case "closing": return .motor(state: Self.decreasing, target: fromHomeKit ? nil : 0, current: nil)
            case "opening": return .motor(state: Self.increasing, target: fromHomeKit ? nil : 100, current: nil)
            default: return .motor(state: Self.stopped, target: scaled, current: scaled)
            }
        }
        switch show {
        case .nothing:
            break
        case .current(let isStopped):
            service.characteristic(.currentPosition).value = .int(scaled)
            if isStopped {
                link.log.debug("\(link.displayName): assume movement stopped")
                service.characteristic(.positionState).value = .int(Self.stopped)
                service.characteristic(.targetPosition).value = .int(scaled)
            }
        case .motor(let state, let target, let currentPosition):
            service.characteristic(.positionState).value = .int(state)
            if let currentPosition { service.characteristic(.currentPosition).value = .int(currentPosition) }
            if let target { service.characteristic(.targetPosition).value = .int(target) }
        }
    }
}

extension ServiceBuilder {
    func buildCovers(_ exposes: [Expose]) {
        for expose in exposes where expose.type == "cover" {
            guard let features = expose.features else { continue }
            func movable(_ name: String) -> Expose? {
                features.first { $0.name == name && $0.isSettableRange }
            }
            var position = movable("position")
            var tilt = movable("tilt")
            if position == nil, let onlyTilt = tilt {
                position = onlyTilt
                tilt = nil
            }
            guard let position else {
                warn("a cover without position or tilt", expose)
                continue
            }
            let state = features.first { $0.name == "state" && $0.isEnum && $0.isSettable && $0.valueStrings.contains("STOP") }
            let motorState = exposes.first {
                $0.name == "motor_state" && $0.endpoint == expose.endpoint && $0.isEnum && $0.isPublished
                    && ["opening", "closing", "stopped"].allSatisfy($0.valueStrings.contains)
            }
            guard claim(.windowCovering, subtype: expose.endpoint) else { continue }
            var optional: [CharacteristicType] = []
            if tilt != nil { optional += [.currentHorizontalTiltAngle, .targetHorizontalTiltAngle] }
            if state != nil { optional.append(.holdPosition) }
            let service = service(.windowCovering, subtype: expose.endpoint, optional: optional)
            add(CoverHandler(service: service, position: position, tilt: tilt, state: state, motorState: motorState, link: link))
        }
    }
}
