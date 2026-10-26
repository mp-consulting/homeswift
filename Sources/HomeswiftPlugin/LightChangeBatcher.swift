import Foundation

/// Gathers a light's changes for a moment and hands them over together: the Home app writes a light's brightness,
/// hue and saturation of one change at the same time, and a bridge or hub takes them best as one command. Each write
/// waits for the command that carries it, so its error reaches HomeKit.
///
/// ```swift
/// let writer = LightChangeBatcher { changes in try await bridge.put(light, body(for: changes)) }
/// bulb[.hue]?.onWrite { value in try await writer.set(.hue(value.doubleValue ?? 0)) }
/// ```
public actor LightChangeBatcher {
    /// What HomeKit asks a light to change.
    public enum Change: Sendable, Equatable {
        case on(Bool)
        case brightness(Double)
        case hue(Double)
        case saturation(Double)
        case mirek(Int)
    }

    /// A moment's changes: a colour (hue, saturation) and a white (mirek) replace each other.
    public struct Changes: Sendable, Equatable {
        public var on: Bool?
        public var brightness: Double?
        public var hue: Double?
        public var saturation: Double?
        public var mirek: Int?

        public init(on: Bool? = nil, brightness: Double? = nil, hue: Double? = nil, saturation: Double? = nil, mirek: Int? = nil) {
            self.on = on
            self.brightness = brightness
            self.hue = hue
            self.saturation = saturation
            self.mirek = mirek
        }

        public var isEmpty: Bool { self == Changes() }

        public mutating func add(_ change: Change) {
            switch change {
            case .on(let value): on = value
            case .brightness(let value): brightness = value
            case .hue(let value): hue = value; mirek = nil
            case .saturation(let value): saturation = value; mirek = nil
            case .mirek(let value): mirek = value; hue = nil; saturation = nil
            }
        }
    }

    /// How long changes are gathered: the Home app's writes of one change arrive within a few milliseconds.
    public static let defaultWindow = Duration.milliseconds(30)

    private let window: Duration
    private let send: @Sendable (Changes) async throws -> Void
    private var pending = Changes()
    private var batch: Task<Void, any Error>?
    /// When the last command went: a poll or an event right after it may still carry the old values.
    public private(set) var lastSent: ContinuousClock.Instant?

    /// Whether a command went within `window`: a poll or an event right after it may still carry the old values, so a
    /// plugin leaves those alone for that long.
    public func isSettling(within window: Duration) -> Bool {
        lastSent.map { ContinuousClock.now - $0 < window } ?? false
    }

    public init(window: Duration = defaultWindow, send: @escaping @Sendable (Changes) async throws -> Void) {
        self.window = window
        self.send = send
    }

    /// Adds a change to the next command and waits for it to be sent.
    public func set(_ change: Change) async throws {
        pending.add(change)
        let task: Task<Void, any Error>
        if let batch {
            task = batch
        } else {
            task = Task {
                try await Task.sleep(for: window)
                try await self.flush()
            }
            batch = task
        }
        try await task.value
    }

    private func flush() async throws {
        let changes = pending
        pending = Changes()
        batch = nil
        guard !changes.isEmpty else { return }
        lastSent = .now
        try await send(changes)
    }
}
