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
    case notAllowedInCurrentState = -70412
}

/// One value of a service, such as a lightbulb's On or Brightness.
///
/// Set `value` from your device code to update HomeKit; controllers that subscribed get an event.
/// Register `onRead` to fetch a fresh value whenever a controller reads, and `onWrite` to act on
/// writes from HomeKit. Throw `HAPStatusError` from either to report a failure.
///
/// The Home app often writes a value the characteristic already has (On while already on, the
/// same brightness twice). Pass `changesOnly: true` to `onWrite` to skip those writes.
public final class Characteristic: @unchecked Sendable {
    public typealias ReadHandler = @Sendable () async throws -> HAPValue
    public typealias WriteHandler = @Sendable (HAPValue) async throws -> Void
    /// A write handler whose result is the characteristic's write response (`wr`), as for control points.
    public typealias WriteResponseHandler = @Sendable (HAPValue) async throws -> HAPValue

    /// Why a value changed, as HAP-NodeJS's `ChangeReason`.
    public enum ChangeReason: Sendable {
        /// A write from a controller, or `write(_:)`.
        case write
        /// `value` was set.
        case update
        /// A read handler returned the value.
        case read
        /// `sendEvent(_:)`.
        case event
    }

    /// One change, given to the observers registered with `observe(_:)`. Unlike events, observers see every
    /// write and update, also when the value stays the same.
    public struct Change: Sendable {
        public var oldValue: HAPValue
        public var newValue: HAPValue
        public var reason: ChangeReason
        /// Set by the code that made the change (a controller such as Adaptive Lighting tags its own writes).
        public var context: ObjectIdentifier?
    }

    public typealias Observer = @Sendable (Change) -> Void

    public let type: CharacteristicType

    struct State {
        var value: HAPValue
        var aid = 0
        var iid = 0
        /// The server the characteristic is attached to, told of every change.
        weak var server: HAPServer?
        var onRead: ReadHandler?
        var onWrite: WriteHandler?
        var onWriteResponse: WriteResponseHandler?
        var writesChangesOnly = false
        /// Reads and writes fail with "No Response" without reaching the handlers (`Accessory.isUnavailable`).
        var unavailable = false
        var observers: [Int: Observer] = [:]
        var nextObserver = 0
        var isSecurityControl: Bool
        var isConfidential: Bool
    }

    let state: NIOLockedValueBox<State>

    public init(_ type: CharacteristicType, value: HAPValue? = nil) {
        self.type = type
        let initial = value.flatMap(type.coerce) ?? type.defaultValue
        state = NIOLockedValueBox(State(
            value: initial, isSecurityControl: Self.securityControls.contains(type.uuid), isConfidential: Self.confidentialTypes.contains(type.uuid)))
    }

    /// Types whose writes unlock, open or disarm: on by default for `isSecurityControl`.
    public static let securityControls: Set<HAPUUID> = [
        CharacteristicType.lockTargetState.uuid, CharacteristicType.targetDoorState.uuid, CharacteristicType.securitySystemTargetState.uuid,
        CharacteristicType.lockControlPoint.uuid,
    ]

    /// Types whose values carry keys (the SRTP master keys of Setup Endpoints, the salts of the data streams): on by
    /// default for `isConfidential`.
    public static let confidentialTypes: Set<HAPUUID> = [
        CharacteristicType.setupEndpoints.uuid, CharacteristicType.setupDataStreamTransport.uuid, CharacteristicType.setupTransferTransport.uuid,
        CharacteristicType.pairSetup.uuid, CharacteristicType.pairVerify.uuid, CharacteristicType.listPairings.uuid,
    ]

    /// Whether a write unlocks, opens or disarms something. The bridge's own surfaces treat these as they treat a
    /// lock: the MCP server writes them only through `set_security_accessory`, after the user confirmed, and the web
    /// UI asks before it writes. On for Lock Target State, Target Door State, Security System Target State and Lock
    /// Control Point; a plugin turns it on for a characteristic that does the same, such as a switch whose On
    /// unlocks a door. HomeKit itself is not affected.
    public var isSecurityControl: Bool {
        get { state.withLockedValue { $0.isSecurityControl } }
        set { state.withLockedValue { $0.isSecurityControl = newValue } }
    }

    /// Marks the characteristic as a security control (`isSecurityControl`) and returns it, for chaining.
    @discardableResult
    public func securityControl(_ on: Bool = true) -> Self {
        isSecurityControl = on
        return self
    }

    /// Whether the value is for HomeKit only. Controllers read and write it as usual, but the MCP server, the web UI,
    /// the accessory cache and the request trace never show or keep it. On for Setup Endpoints (SRTP keys), Setup
    /// Data Stream Transport and Setup Transfer Transport (key salts) and the pairing characteristics.
    public var isConfidential: Bool {
        get { state.withLockedValue { $0.isConfidential } }
        set { state.withLockedValue { $0.isConfidential = newValue } }
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

    /// Registers the handler for writes from HomeKit.
    ///
    /// With `changesOnly`, a write of the current value is accepted without calling the handler.
    /// Leave it off when the stored value can drift from the device, so a repeated write can
    /// still correct it. Write-only characteristics such as Identify always call the handler.
    @discardableResult
    public func onWrite(changesOnly: Bool = false, _ handler: WriteHandler?) -> Self {
        state.withLockedValue {
            $0.onWrite = handler
            $0.writesChangesOnly = changesOnly
        }
        return self
    }

    /// Registers a handler for writes whose result is sent back as the write response and kept as the value
    /// (HAP-NodeJS's `onSet` returning a value): control points such as Setup Endpoints or Transition Control.
    @discardableResult
    public func onWriteResponse(_ handler: WriteResponseHandler?) -> Self {
        state.withLockedValue { $0.onWriteResponse = handler }
        return self
    }

    /// Calls `observer` for every change of the value, whatever its origin. Returns a token for `removeObserver(_:)`.
    @discardableResult
    public func observe(_ observer: @escaping Observer) -> Int {
        state.withLockedValue { state in
            state.nextObserver += 1
            state.observers[state.nextObserver] = observer
            return state.nextObserver
        }
    }

    public func removeObserver(_ token: Int) {
        _ = state.withLockedValue { $0.observers.removeValue(forKey: token) }
    }

    /// Sets the value back after `delay`, once a write that failed or changed nothing has landed: HomeKit takes a
    /// write that does not throw as done, and would otherwise show the requested value. Cancelling the task
    /// leaves the value alone.
    @discardableResult
    public func revert(to value: HAPValue, after delay: Duration) -> Task<Void, Never> {
        revert(after: delay) { value }
    }

    /// Sets the value back after `delay` to what `value` reads then (the device's state).
    @discardableResult
    public func revert(after delay: Duration, to value: @escaping @Sendable () async -> HAPValue) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            let current = await value()
            self?.value = current
        }
    }

    var readHandler: ReadHandler? { state.withLockedValue { $0.onRead } }

    /// Whether reads and writes fail with `serviceCommunicationFailure` ("No Response" in the Home app) without
    /// calling the handlers; the value and the handlers stay for when it is available again.
    var isUnavailable: Bool {
        get { state.withLockedValue { $0.unavailable } }
        set { state.withLockedValue { $0.unavailable = newValue } }
    }

    /// Writes a value the way a controller does: checks the permissions and the format, calls the write
    /// handler, stores the value and notifies subscribed controllers. For writes that come from outside
    /// HomeKit, such as an automation or an MCP tool. Timed writes are not enforced.
    /// `context` lets a scheduler distinguish its own writes from manual changes in observers.
    public func write(_ value: HAPValue, context: ObjectIdentifier? = nil) async throws {
        try await write(value, origin: nil, context: context)
    }

    /// The write path, for controllers too: `origin` is the connection whose own event is skipped. Returns the
    /// value stored afterwards: the write response when a response handler gave one.
    @discardableResult
    func write(_ value: HAPValue, origin: ObjectIdentifier?, context: ObjectIdentifier? = nil, notify: Bool = true) async throws -> HAPValue {
        guard type.permissions.contains(.pairedWrite) else { throw HAPStatusError(.readOnlyCharacteristic) }
        guard !isUnavailable else { throw HAPStatusError(.serviceCommunicationFailure) }
        guard let coerced = type.coerce(value) else { throw HAPStatusError(.invalidValueInRequest) }
        if let respond = state.withLockedValue({ $0.onWriteResponse }) {
            let response = try await timed { try await respond(coerced) }
            // As HAP-NodeJS: a write response replaces the value without a change event.
            state.withLockedValue { $0.value = type.coerce(response) ?? response }
            return response
        }
        if let handler = writeHandler(for: coerced) { try await timed { try await handler(coerced) } }
        update(coerced, origin: origin, force: false, reason: .write, context: context, notify: notify)
        return coerced
    }

    /// Writes from code inside the library (Adaptive Lighting's transition steps): always calls the handler, tags
    /// the change with `context` and sends no event when `notify` is off.
    func writeFromController(_ value: HAPValue, context: ObjectIdentifier, notify: Bool) async throws {
        guard !isUnavailable else { throw HAPStatusError(.serviceCommunicationFailure) }
        let coerced = type.coerce(value) ?? value
        if let handler = state.withLockedValue({ $0.onWrite }) { try await timed { try await handler(coerced) } }
        update(coerced, origin: nil, force: false, reason: .write, context: context, notify: notify)
    }

    /// Runs one of the accessory's handlers, the plugin reaching its device, timed for the server's observers.
    func timed<Result>(_ handler: () async throws -> Result) async rethrows -> Result {
        let (server, aid) = state.withLockedValue { ($0.server, $0.aid) }
        let start = ContinuousClock.now
        defer { server?.recordTiming(.handler, aids: [aid], since: start) }
        return try await handler()
    }

    /// Sets the value with a reason and context, with or without an event.
    func set(_ value: HAPValue, reason: ChangeReason = .update, context: ObjectIdentifier? = nil, notify: Bool = true, force: Bool = false) {
        update(value, origin: nil, force: force, reason: reason, context: context, notify: notify)
    }

    /// The handler to call for a write of `value`, or nil when there is none or the write changes nothing.
    func writeHandler(for value: HAPValue) -> WriteHandler? {
        let readable = type.permissions.contains(.pairedRead)
        return state.withLockedValue { state in
            if state.writesChangesOnly, readable, state.value == value { return nil }
            return state.onWrite
        }
    }

    func attach(aid: Int, iid: Int, server: HAPServer) {
        state.withLockedValue {
            $0.aid = aid
            $0.iid = iid
            $0.server = server
        }
    }

    func update(
        _ newValue: HAPValue, origin: ObjectIdentifier?, force: Bool, reason: ChangeReason? = nil, context: ObjectIdentifier? = nil,
        notify: Bool = true
    ) {
        let coerced = type.coerce(newValue) ?? newValue
        let (old, server, observers) = state.withLockedValue { state -> (HAPValue, HAPServer?, [Observer]) in
            let old = state.value
            state.value = coerced
            return (old, state.server, Array(state.observers.values))
        }
        let changed = old != coerced
        if notify, changed || force, type.permissions.contains(.events) {
            server?.characteristicDidChange(self, value: coerced, origin: origin)
        }
        guard !observers.isEmpty else { return }
        let change = Change(oldValue: old, newValue: coerced, reason: reason ?? (force ? .event : .update), context: context)
        for observer in observers { observer(change) }
    }
}
