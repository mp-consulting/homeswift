import Foundation
import HomeswiftNetwork

/// Opens a byte stream to a device; tests give one in memory.
protocol MagicHomeTransport: Sendable {
    func connect(host: String, port: Int, timeout: Duration) async throws -> any ByteStream
}

struct MagicHomeTCPTransport: MagicHomeTransport {
    func connect(host: String, port: Int, timeout: Duration) async throws -> any ByteStream {
        try await TCPStream.connect(host: host, port: port, timeout: timeout)
    }
}

struct MagicHomeTimeout: Error, CustomStringConvertible {
    var description: String { "the device did not answer" }
}

struct MagicHomeClosed: Error, CustomStringConvertible {
    var description: String { "the device closed the connection" }
}

/// The connection to one device on TCP 5577, one command at a time (sections 4.2, 10.10). A device whose family sends
/// its changes keeps it open, and what it sends arrives in `onPush`; any other has it closed after `idleTimeout`
/// without a command, so a burst (power on, then levels, then a read) shares one connection and the module's few
/// connection slots are free the rest of the time. The wrapper's counter belongs to the connection.
actor MagicHomeConnection {
    struct Timing: Sendable {
        var connect: Duration = .seconds(2)
        var reply: Duration = .seconds(2)
        var idle: Duration = .seconds(3)
    }

    static let port = 5577

    let transport: any MagicHomeTransport
    let timing: Timing
    private(set) var host: String
    private(set) var persistent: Bool
    private var stream: (any ByteStream)?
    private var reading: Task<Void, Never>?
    private var idleClose: Task<Void, Never>?
    private var wrapper = MagicHomeWrapper()
    /// The query waiting for a state reply.
    private var waiter: (id: Int, continuation: CheckedContinuation<MagicHomeState, any Error>)?
    private var nextWaiter = 0
    /// One command after the other: a command waits for the one before it.
    private var tail: Task<Void, Never>?
    private var onPush: (@Sendable (MagicHomeMessage) async -> Void)?
    /// Which connection the reading task belongs to: one that ended late does not close the next.
    private var generation = 0

    init(host: String, persistent: Bool, transport: any MagicHomeTransport, timing: Timing) {
        self.host = host
        self.persistent = persistent
        self.transport = transport
        self.timing = timing
    }

    func setPush(_ handler: (@Sendable (MagicHomeMessage) async -> Void)?) { onPush = handler }

    /// A new address (the device moved) or another family: the open connection goes.
    func update(host: String, persistent: Bool) async {
        guard host != self.host || persistent != self.persistent else { return }
        self.host = host
        self.persistent = persistent
        await close()
    }

    var isOpen: Bool { stream != nil }

    /// Sends frames in order (each after its delay), wrapping those that need it.
    func send(_ frames: [MagicHomeOutgoing]) async throws {
        try await serially {
            for frame in frames {
                if frame.delay > .zero { try await Task.sleep(for: frame.delay) }
                try await self.write(frame)
            }
        }
    }

    /// Asks for the state; `wrapped` for the families whose queries go in the wrapper.
    func query(wrapped: Bool) async throws -> MagicHomeState {
        try await serially { try await self.runQuery(wrapped: wrapped) }
    }

    func close() async {
        idleClose?.cancel()
        idleClose = nil
        reading?.cancel()
        reading = nil
        let open = stream
        stream = nil
        wrapper = MagicHomeWrapper()
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(throwing: MagicHomeClosed())
        }
        await open?.close()
    }

    // MARK: Inside

    private func serially<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, any Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func runQuery(wrapped: Bool) async throws -> MagicHomeState {
        let id = nextWaiter
        nextWaiter += 1
        // The reply's wait starts once the connection is open: a connection still to open has its own wait too.
        let reply = stream == nil ? timing.connect + timing.reply : timing.reply
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: MagicHomeState?.self) { group in
                group.addTask { try await self.awaitState(id: id, wrapped: wrapped) }
                group.addTask {
                    try await Task.sleep(for: reply)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let state = first else {
                    // The waiting child ends with this, so the group can.
                    self.fail(id: id, MagicHomeTimeout())
                    throw MagicHomeTimeout()
                }
                return state
            }
        } onCancel: {
            Task { await self.fail(id: id, CancellationError()) }
        }
    }

    private func awaitState(id: Int, wrapped: Bool) async throws -> MagicHomeState {
        try await withCheckedThrowingContinuation { continuation in
            // Timed out or cancelled before this ran: `fail` found no waiter to end, so nothing else would.
            guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
            waiter = (id, continuation)
            Task { await self.sendQuery(id: id, wrapped: wrapped) }
        }
    }

    private func sendQuery(id: Int, wrapped: Bool) async {
        // Given up already: no connection is opened for it.
        guard waiter?.id == id else { return }
        do {
            try await write(MagicHomeOutgoing(bytes: MagicHomeFrame.stateQuery, wrapVersion: wrapped ? 1 : nil))
        } catch {
            fail(id: id, error)
        }
    }

    private func fail(id: Int, _ error: any Error) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(throwing: error)
    }

    private func write(_ frame: MagicHomeOutgoing) async throws {
        let stream = try await open()
        let bytes = frame.wrapVersion.map { wrapper.wrap(frame.bytes, version: $0) } ?? frame.bytes
        do {
            try await stream.send(bytes)
        } catch {
            await close()
            throw error
        }
        scheduleIdleClose()
    }

    private func open() async throws -> any ByteStream {
        if let stream { return stream }
        let stream = try await transport.connect(host: host, port: Self.port, timeout: timing.connect)
        self.stream = stream
        generation += 1
        let generation = generation
        wrapper = MagicHomeWrapper()
        reading = Task { [weak self] in
            var reader = MagicHomeReader()
            do {
                for try await chunk in stream.incoming {
                    for message in reader.add(chunk) { await self?.received(message) }
                }
            } catch {}
            await self?.ended(generation)
        }
        return stream
    }

    private func received(_ message: MagicHomeMessage) async {
        scheduleIdleClose()
        if case .state(let state) = message, let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: state)
            return
        }
        await onPush?(message)
    }

    /// The device closed the connection: the next command opens another.
    private func ended(_ ended: Int) async {
        guard stream != nil, ended == generation else { return }
        await close()
    }

    private func scheduleIdleClose() {
        idleClose?.cancel()
        guard !persistent else { idleClose = nil; return }
        let idle = timing.idle
        idleClose = Task { [weak self] in
            do { try await Task.sleep(for: idle) } catch { return }
            await self?.closeIfIdle()
        }
    }

    private func closeIfIdle() async {
        guard waiter == nil else { return }
        await close()
    }
}
