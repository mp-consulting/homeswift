import Foundation
import HomeswiftAI
import HomeswiftNetwork
import Logging
import NIOConcurrencyHelpers

/// Called with each state an action of an execution goes through.
typealias ExecutionObserver = @Sendable (ExecutionUpdate) -> Void

/// The executions the plugin starts (docs/clean-room/Tahoma.md, 6.4): commands for several devices written within
/// `window` go out as one execution (one action per device, the commands of one device merged by name), a standalone
/// one alone; each is followed through the event listener's `ExecutionStateChangedEvent`s, an action of a failed
/// execution getting FAILED when the server names its device in `failedCommands` and COMPLETED otherwise, and one that
/// hears nothing for `timeout` gets TIMED_OUT.
actor Executions {
    struct Timings: Sendable {
        var window: Duration = .milliseconds(100)
        var timeout: Duration = .seconds(120)
        /// Between tries of an execution the server is too busy for (`EXEC_QUEUE_FULL`, "Too many executions").
        var busy = Backoff(initial: .seconds(5), maximum: .seconds(60), jitter: .proportional(0.3))
        var busyTries = 5
    }

    private struct Pending {
        var deviceURL: String
        var label: String
        var highPriority: Bool
        var commands: [OverkizCommand]
        var observers: [ExecutionObserver]
        var waiters: [CheckedContinuation<String, any Error>]
    }

    private struct Tracked {
        var actions: [(deviceURL: String, observers: [ExecutionObserver])]
        var timeout: Task<Void, Never>?
    }

    private let client: @Sendable () async -> OverkizClient?
    private let timings: Timings
    private let logger: Logger
    private let started: @Sendable () -> Void
    /// The language of the labels the vendor's app shows in its history: `fr`, `en`, or nil for the raw names.
    private var language: String?
    private var pending: [Pending] = []
    private var flush: Task<Void, Never>?
    private var tracked: [String: Tracked] = [:]
    /// Events of executions not tracked yet: a fetch can bring one's first states while its post is still answered.
    /// The last few only, replayed when it is tracked.
    private var early: [(execID: String, event: Event)] = []

    private struct Event {
        var newState: ExecutionState
        var final: Bool
        var failureType: String?
        var failedDevices: Set<String>?
    }

    init(
        timings: Timings = Timings(), logger: Logger, client: @escaping @Sendable () async -> OverkizClient?,
        started: @escaping @Sendable () -> Void
    ) {
        self.timings = timings
        self.logger = logger
        self.client = client
        self.started = started
    }

    /// Executions in flight.
    var inFlight: Int { tracked.count }

    func setLanguage(_ language: String?) { self.language = language }

    /// Sends `commands` to a device and answers the execution's id once posted; `observer` hears its states. Commands for
    /// the same device within the window join its action, replacing one of the same name.
    func submit(
        deviceURL: String, label: String, commands: [OverkizCommand], highPriority: Bool, standalone: Bool = false,
        observer: @escaping ExecutionObserver
    ) async throws -> String {
        if standalone {
            return try await post([Pending(deviceURL: deviceURL, label: label, highPriority: highPriority, commands: commands, observers: [observer], waiters: [])])
        }
        return try await withCheckedThrowingContinuation { continuation in
            if let index = pending.firstIndex(where: { $0.deviceURL == deviceURL }) {
                pending[index].commands = Self.merge(pending[index].commands, commands)
                pending[index].observers.append(observer)
                pending[index].waiters.append(continuation)
                pending[index].highPriority = pending[index].highPriority || highPriority
            } else {
                pending.append(Pending(deviceURL: deviceURL, label: label, highPriority: highPriority, commands: commands, observers: [observer], waiters: [continuation]))
            }
            if flush == nil {
                let window = timings.window
                flush = Task { [weak self] in
                    try? await Task.sleep(for: window)
                    await self?.flushPending()
                }
            }
        }
    }

    /// One action's commands: a command of the same name replaced, others appended (the Homebridge plugin dropped them,
    /// docs/clean-room/Tahoma.md 10.4). A light given On and Brightness together gets only `setIntensity`, which turns it on.
    static func merge(_ existing: [OverkizCommand], _ added: [OverkizCommand]) -> [OverkizCommand] {
        var commands = existing
        for command in added {
            if let index = commands.firstIndex(where: { $0.name == command.name }) { commands[index] = command } else { commands.append(command) }
        }
        if commands.contains(where: { $0.name == "setIntensity" }) {
            commands.removeAll { $0.name == "on" }
        }
        return commands
    }

    private func flushPending() async {
        let batch = pending
        pending = []
        flush = nil
        guard !batch.isEmpty else { return }
        do {
            let execID = try await post(batch)
            for action in batch { action.waiters.forEach { $0.resume(returning: execID) } }
        } catch {
            for action in batch { action.waiters.forEach { $0.resume(throwing: error) } }
        }
    }

    /// Posts one execution, again when the server is busy, and tracks it.
    private func post(_ batch: [Pending]) async throws -> String {
        guard let client = await client() else { throw OverkizError(message: "not connected") }
        let label = batch.count == 1
            ? "\(batch[0].label) - \(Self.label(of: batch[0].commands.first, language: language)) - HomeKit"
            : "Execute scene (\(batch.count) devices) - HomeKit"
        let actions: [JSONValue] = batch.map { ["deviceURL": .string($0.deviceURL), "commands": .array($0.commands.map(\.json))] }
        let highPriority = batch.contains(where: \.highPriority)
        var attempt = 0
        while true {
            do {
                let execID = try await client.apply(label: label, actions: actions, highPriority: highPriority)
                track(execID, actions: batch.map { ($0.deviceURL, $0.observers) })
                return execID
            } catch let error as OverkizError where error.isBusy && attempt + 1 < timings.busyTries {
                let delay = timings.busy.delay(attempt: attempt)
                logger.info("The server is busy (\(error)): sending again in \(delay)")
                attempt += 1
                try await Task.sleep(for: delay)
            }
        }
    }

    /// Follows an execution started elsewhere (a scenario's).
    func track(_ execID: String, observer: @escaping ExecutionObserver) {
        track(execID, actions: [("", [observer])])
    }

    private func track(_ execID: String, actions: [(deviceURL: String, observers: [ExecutionObserver])]) {
        let timeout = timings.timeout
        let task = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.timedOut(execID)
        }
        tracked[execID] = Tracked(actions: actions, timeout: task)
        started()
        let replayed = early.filter { $0.execID == execID }
        early.removeAll { $0.execID == execID }
        for (_, event) in replayed {
            handle(execID: execID, newState: event.newState, final: event.final, failureType: event.failureType, failedDevices: event.failedDevices)
        }
    }

    private func timedOut(_ execID: String) {
        guard let execution = tracked.removeValue(forKey: execID) else { return }
        let update = ExecutionUpdate(state: .timedOut, failureType: nil, execID: execID)
        for action in execution.actions { action.observers.forEach { $0(update) } }
    }

    /// An `ExecutionStateChangedEvent`: passed to every action of a tracked execution.
    func handle(execID: String, newState: ExecutionState, final: Bool, failureType: String?, failedDevices: Set<String>?) {
        guard let execution = tracked[execID] else {
            early.append((execID, Event(newState: newState, final: final, failureType: failureType, failedDevices: failedDevices)))
            if early.count > 32 { early.removeFirst(early.count - 32) }
            return
        }
        let ends = final || newState.isFinal
        if ends {
            execution.timeout?.cancel()
            tracked.removeValue(forKey: execID)
        }
        for action in execution.actions {
            let update: ExecutionUpdate
            if let failureType, let failedDevices {
                let failed = failedDevices.contains(action.deviceURL) || action.deviceURL.isEmpty
                update = ExecutionUpdate(state: failed ? .failed : .completed, failureType: failed ? failureType : nil, execID: execID)
            } else {
                update = ExecutionUpdate(state: newState, failureType: failureType, execID: execID)
            }
            action.observers.forEach { $0(update) }
        }
    }

    func cancel(_ execID: String) async throws {
        guard let client = await client() else { throw OverkizError(message: "not connected") }
        try await client.cancel(execID: execID)
    }

    /// Stops following everything (the plugin stops): each observer hears TIMED_OUT, the waiters an error.
    func stop() {
        flush?.cancel()
        flush = nil
        for action in pending { action.waiters.forEach { $0.resume(throwing: CancellationError()) } }
        pending = []
        for (execID, execution) in tracked {
            execution.timeout?.cancel()
            let update = ExecutionUpdate(state: .timedOut, failureType: nil, execID: execID)
            for action in execution.actions { action.observers.forEach { $0(update) } }
        }
        tracked = [:]
        early = []
    }

    /// A command's label in the execution's (6.4): `setClosure` named in English or French, the rest as the raw
    /// `<name>.<first parameter>` key, as the Homebridge plugin left them; raw on the local API.
    static func label(of command: OverkizCommand?, language: String?) -> String {
        guard let command else { return "" }
        let parameter = command.parameters.first.flatMap(\.scalarText)
        if command.name == "setClosure", let parameter, let language {
            return language == "fr" ? "Fermeture \(parameter)%" : "Close \(parameter)%"
        }
        return parameter.map { "\(command.name).\($0)" } ?? command.name
    }
}
