import Foundation
import Homeswift
import Logging
import NIOConcurrencyHelpers

/// Runs Remotes' Controls (GLOSSARY.md, docs/adr/0009-remote-controls-are-not-automations.md) for every plugin: a moment of
/// a Button or Wheel comes from its plugin (`PluginContext.remoteMoment`), or from the press HomeKit gets for a Remote
/// whose plugin reports none, and the part's Controls run at once, the Remote as their Change Source.
final class RemoteControls: Sendable {
    /// How long a hold whose end will not come dims (HomeKit's long press, from a plugin that only has three presses).
    static let timedHold: Duration = .seconds(2)

    private let find: @Sendable (String) -> Accessory?
    private let remote: @Sendable (String) -> RemoteState?
    private let scenes: @Sendable () -> HomeScenes?
    private let logger: Logger
    private let tasks = TaskBag()
    private let state = NIOLockedValueBox(State())

    private struct State {
        /// A writer per light or shutter, shared by every runner that drives it.
        var writers: [String: DimmerWriter] = [:]
        /// A runner per set of targets, shared by the Controls that drive them.
        var runners: [ControlTargets: ControlRunner] = [:]
    }

    init(find: @escaping @Sendable (String) -> Accessory?, remote: @escaping @Sendable (String) -> RemoteState?,
         scenes: @escaping @Sendable () -> HomeScenes?, logger: Logger) {
        self.find = find
        self.remote = remote
        self.scenes = scenes
        self.logger = logger
    }

    /// What a moment makes a Control do.
    private enum Work: Sendable {
        case run(RemoteControl)
        /// Held, for so long when the end will not come.
        case hold(RemoteControl, Duration?)
        case release(RemoteControl)
        case turn(RemoteControl, notches: Int)
    }

    /// A moment of a Remote's part: its Controls for it run.
    func moment(_ moment: RemoteMoment, part: String, of accessoryID: String) {
        guard let remote = remote(accessoryID) else { return }
        run(moment, part: part, of: remote)
    }

    private func run(_ moment: RemoteMoment, part: String, of remote: RemoteState) {
        let controls = remote.controls.filter { $0.part == part }
        guard !controls.isEmpty else { return }
        func control(_ gesture: RemoteControl.Gesture) -> RemoteControl? { controls.first { $0.gesture == gesture } }
        let work: Work?
        switch moment {
        case .press: work = control(.press).map(Work.run)
        case .doublePress: work = control(.double).map(Work.run)
        case .longPress, .holdStart:
            // A Button holds or long-presses, not both (`RemoteControl.problem`); HomeKit's long press holds for a while.
            if let hold = control(.hold) {
                work = .hold(hold, moment == .longPress ? Self.timedHold : nil)
            } else {
                work = control(.long).map(Work.run)
            }
        case .holdEnd: work = control(.hold).map(Work.release)
        case .turned(let notches): work = control(.turn).map { Work.turn($0, notches: notches) }
        }
        guard let work else { return }
        let source = ChangeSource.remote("\(remote.name) · \(remote.layout.parts.first { $0.id == part }?.name ?? part)")
        tasks.add { await source.run { await self.perform(work) } }
    }

    private func perform(_ work: Work) async {
        switch work {
        case .run(let control): await run(control)
        case .hold(let control, let duration):
            await runner(for: control).hold(step: control.stepOrDefault, direction: control.direction ?? .alternate, for: duration)
        case .release(let control): await runner(for: control).release()
        case .turn(let control, let notches):
            await runner(for: control).apply(.step(control.reversed == true ? -notches : notches), step: control.stepOrDefault)
        }
    }

    /// A press HomeKit got (Programmable Switch Event), for a Remote whose plugin reports no moments of its own.
    func observed(_ accessory: Accessory, _ characteristic: Characteristic, _ value: HAPValue) {
        guard characteristic.type.uuid == CharacteristicType.programmableSwitchEvent.uuid, accessory.isRemote,
              let service = accessory.services.first(where: { $0.characteristics.contains { $0 === characteristic } }),
              service.type == .statelessProgrammableSwitch, let remote = remote(accessory.id), !remote.isDeclared else { return }
        let moment: RemoteMoment
        switch value.intValue {
        case HAPConstants.ProgrammableSwitchEvent.singlePress: moment = .press
        case HAPConstants.ProgrammableSwitchEvent.doublePress: moment = .doublePress
        case HAPConstants.ProgrammableSwitchEvent.longPress: moment = .longPress
        default: return
        }
        run(moment, part: RemoteLayout.partID(of: service), of: remote)
    }

    /// Stops what runs: holds, power waits, Scenes started.
    func stop() async {
        tasks.cancelAll()
        await releaseHolds()
    }

    /// Ends every hold: a plugin that stops (a reload, Forget) never sends the release of one under way.
    func releaseHolds() async {
        for runner in state.withLockedValue({ Array($0.runners.values) }) { await runner.release() }
    }

    /// Lets go of the runners whose targets no Control has any more (their hold ended), and of the writers of targets they
    /// alone drove: after the Controls changed.
    func prune(keeping controls: [RemoteControl]) async {
        let kept = Set(controls.filter { !$0.targets.isEmpty }.map(Self.targets(of:)))
        let gone = state.withLockedValue { state -> [ControlRunner] in
            let gone = state.runners.filter { !kept.contains($0.key) }.map(\.value)
            state.runners = state.runners.filter { kept.contains($0.key) }
            let driven = Set(state.runners.keys.flatMap(\.driven))
            state.writers = state.writers.filter { driven.contains($0.key) }
            return gone
        }
        for runner in gone { await runner.release() }
    }

    private static func targets(of control: RemoteControl) -> ControlTargets {
        ControlTargets(driven: control.targets, power: control.power, powerDelay: .seconds(control.powerDelay ?? RemoteControl.defaultPowerDelay))
    }

    /// Its action on its targets and its Scenes, at the same time: a slow light never holds a Scene back.
    private func run(_ control: RemoteControl) async {
        await withTaskGroup(of: Void.self) { group in
            switch control.action {
            case .scene, .dim, .step: break
            case .toggle: group.addTask { await self.runner(for: control).apply(.toggle, step: control.stepOrDefault) }
            case .on, .off: group.addTask { await self.runner(for: control).switchTo(control.action == .on, step: control.stepOrDefault) }
            case .stop: group.addTask { await self.runner(for: control).stop() }
            }
            for id in control.scenes { group.addTask { await self.runScene(id) } }
        }
    }

    private func runScene(_ id: String) async {
        guard let scenes = scenes() else { return logger.warning("A Remote's Scene \(id) did not run: the home's Scenes are not ready") }
        do { try await scenes.run(id) } catch { logger.warning("A Remote's Scene \(id) did not run: \(error)") }
    }

    /// The runner of a Control's targets, shared by the Controls with the same; `prune` lets go of those no Control has.
    private func runner(for control: RemoteControl) -> ControlRunner {
        let targets = Self.targets(of: control)
        let find = find
        return state.withLockedValue { state in
            if let runner = state.runners[targets] { return runner }
            let writers = targets.driven.map { id in
                if let writer = state.writers[id] { return writer }
                let writer = DimmerWriter(lightID: id, find: find)
                state.writers[id] = writer
                return writer
            }
            let runner = ControlRunner(targets: targets, writers: writers, find: find)
            state.runners[targets] = runner
            return runner
        }
    }
}
