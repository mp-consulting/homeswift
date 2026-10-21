import NIOConcurrencyHelpers

/// An error a read or write handler can throw to report a specific HAP status to the controller.
public struct HAPStatusError: Error, Sendable, Equatable {
    public let status: HAPStatus
    public init(_ status: HAPStatus) { self.status = status }
}

/// HAP status codes returned per characteristic.
public enum HAPStatus: Int, Sendable, Codable {
    case success = 0
    case insufficientPrivileges = -70401
    case serviceCommunicationFailure = -70402
    case resourceBusy = -70403
    case readOnlyCharacteristic = -70404
    case writeOnlyCharacteristic = -70405
    case notificationNotSupported = -70406
    case outOfResource = -70407
    case operationTimedOut = -70408
    case resourceDoesNotExist = -70409
    case invalidValueInRequest = -70410
    case insufficientAuthorization = -70411
}

protocol CharacteristicObserver: AnyObject, Sendable {
    func characteristicDidChange(_ characteristic: Characteristic, value: HAPValue, origin: ObjectIdentifier?)
}

/// One value of a service, such as a lightbulb's On or Brightness.
///
/// Set `value` from your device code to update HomeKit; controllers that subscribed get an event.
/// Register `onRead` to fetch a fresh value whenever a controller reads, and `onWrite` to act on
/// writes from HomeKit. Throw `HAPStatusError` from either to report a failure.
public final class Characteristic: @unchecked Sendable {
    public typealias ReadHandler = @Sendable () async throws -> HAPValue
    public typealias WriteHandler = @Sendable (HAPValue) async throws -> Void

    public let type: CharacteristicType

    struct Weak: @unchecked Sendable {
        weak var value: (any CharacteristicObserver)?
    }

    struct State {
        var value: HAPValue
        var aid = 0
        var iid = 0
        var observer = Weak()
        var onRead: ReadHandler?
        var onWrite: WriteHandler?
    }

    let state: NIOLockedValueBox<State>

    public init(_ type: CharacteristicType, value: HAPValue? = nil) {
        self.type = type
        let initial = value.flatMap(type.coerce) ?? type.defaultValue
        state = NIOLockedValueBox(State(value: initial))
    }

    public var iid: Int { state.withLockedValue { $0.iid } }
    public var aid: Int { state.withLockedValue { $0.aid } }

    /// The current value. Setting it notifies subscribed controllers when the value changes.
    public var value: HAPValue {
        get { state.withLockedValue { $0.value } }
        set { update(newValue, origin: nil, force: false) }
    }

    /// Sends an event even when the value is unchanged, e.g. for a programmable switch press.
    public func sendEvent(_ value: HAPValue) {
        update(value, origin: nil, force: true)
    }

    @discardableResult
    public func onRead(_ handler: ReadHandler?) -> Self {
        state.withLockedValue { $0.onRead = handler }
        return self
    }

    @discardableResult
    public func onWrite(_ handler: WriteHandler?) -> Self {
        state.withLockedValue { $0.onWrite = handler }
        return self
    }

    var readHandler: ReadHandler? { state.withLockedValue { $0.onRead } }
    var writeHandler: WriteHandler? { state.withLockedValue { $0.onWrite } }

    func attach(aid: Int, iid: Int, observer: any CharacteristicObserver) {
        state.withLockedValue {
            $0.aid = aid
            $0.iid = iid
            $0.observer = Weak(value: observer)
        }
    }

    func update(_ newValue: HAPValue, origin: ObjectIdentifier?, force: Bool) {
        let coerced = type.coerce(newValue) ?? newValue
        let (changed, observer) = state.withLockedValue { state -> (Bool, (any CharacteristicObserver)?) in
            let changed = state.value != coerced
            state.value = coerced
            return (changed, state.observer.value)
        }
        if changed || force, type.permissions.contains(.events) {
            observer?.characteristicDidChange(self, value: coerced, origin: origin)
        }
    }
}
