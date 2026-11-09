import Foundation
import Homeswift

// How a Remote's Controls drive their targets (`RemoteControls`): a writer per light or shutter, one write at a time, and
// a runner per set of targets that powers them, toggles them, holds and steps them.

/// What a Control asks of its targets' writers: a step of so many notches, or a toggle.
enum DimmerAction: Equatable, Sendable {
    case step(Int)
    case toggle
}

/// The lights and shutters a Control drives together, and the switches that power them, when it has some.
struct ControlTargets: Sendable, Hashable {
    var lights: [String]
    var power: [String]
    var powerDelay: Duration
}

/// Writes a light's brightness as the wheel turns, the way the Home app does (through its characteristics, so its own
/// plugin sends it), one write at a time: steps that come while a write is out add up into the next. The button turns a
/// light the wheel dimmed away back on at the level it had. A shutter (`covering(in:)`) moves the same way, its Target
/// Position the level.
actor DimmerWriter {
    private let lightID: String
    private let find: @Sendable (String) -> Accessory?
    private var pending: Int = 0
    private var toggles = 0
    /// A switch to on or off asked while a write was out (a channel's button over several lights), sent next.
    private var switchTarget: Bool?
    private var writing = false
    /// The brightness the light had when the wheel dimmed it to the floor: what the button turns it back on at, rather
    /// than an invisible 1 %.
    private var restoreLevel: Int?
    /// What the writer last set, and when: for a few seconds it is the light's state, whatever the light's plugin says.
    /// A light reached through a cloud (Govee's) reports levels from before the last writes late, and stepping from
    /// those would jump back.
    private var lastSet: (on: Bool, brightness: Int?, at: ContinuousClock.Instant)?
    private let trustLastSet: Duration

    /// One write: a step of the wheel (in percent), the button's toggle, or a switch to on or off.
    private enum Write {
        case step(Int), toggle, set(Bool)
    }

    /// What the writer drives, found once per call: a shutter's Window Covering, or a light's Lightbulb and its On.
    private enum Target {
        case covering(Service)
        case light(Service, on: Characteristic)
    }

    init(lightID: String, trustLastSet: Duration = .seconds(3), find: @escaping @Sendable (String) -> Accessory?) {
        self.lightID = lightID
        self.trustLastSet = trustLastSet
        self.find = find
    }

    /// A window covering (a shutter, a blind) the wheel moves: its Target Position, a notch a step. The one test of what
    /// is a shutter, for the writer, the settings' choices and their words.
    static func covering(in accessory: Accessory) -> Service? {
        accessory.services.first { $0.type == .windowCovering && $0[.targetPosition] != nil }
    }

    /// Moves the light by `step` per notch (negative to dim), or toggles it; returns once this change has gone out, with
    /// whether a notch asked for less than the lowest brightness. `holdAtFloor`: such a notch leaves the light on at the
    /// floor rather than off, for a channel whose power switch goes off instead (the light comes back on with its power).
    @discardableResult
    func apply(_ action: DimmerAction, step: Int, holdAtFloor: Bool = false) async -> Bool {
        switch action {
        case .step(let notches): pending += notches * step
        case .toggle: toggles += 1
        }
        return await kick(holdAtFloor: holdAtFloor)
    }

    /// Switches the light on or off (a channel's button over several lights: all of them the same way); a shutter
    /// opens or closes. Through the same queue as the wheel's steps, so a press never races a step out on the same light.
    func switchTo(_ on: Bool) async {
        switchTarget = on
        pending = 0
        toggles = 0
        await kick(holdAtFloor: false)
    }

    /// Drains the queue unless a write is already out, which drains it; answers whether a step went below the floor.
    @discardableResult
    private func kick(holdAtFloor: Bool) async -> Bool {
        guard !writing else { return false }
        writing = true
        defer { writing = false }
        var belowFloor = false
        // A switch to on or off first, then the toggles and steps that came after it.
        while pending != 0 || toggles > 0 || switchTarget != nil {
            if let on = switchTarget {
                switchTarget = nil
                await write(.set(on), holdAtFloor: false)
                continue
            }
            let change = pending, toggle = toggles % 2 == 1
            pending = 0
            toggles = 0
            // A toggle settles the light; the steps that came with it are dropped, as their order is not known.
            if toggle {
                await write(.toggle, holdAtFloor: holdAtFloor)
            } else if await write(.step(change), holdAtFloor: holdAtFloor) {
                belowFloor = true
            }
        }
        return belowFloor
    }

    /// Whether it is on, and its brightness, as the writer knows it; a shutter is on while open, its position the level.
    func state() -> (on: Bool, brightness: Int?)? {
        target().map(state(of:))
    }

    private func state(of target: Target) -> (on: Bool, brightness: Int?) {
        let recent = recentSet()
        switch target {
        case .covering(let covering):
            let position = recent?.brightness ?? covering[.targetPosition]?.value.intValue ?? covering[.currentPosition]?.value.intValue ?? 0
            return (position > 0, position)
        case .light(let service, let on):
            return (recent?.on ?? on.value.boolValue ?? false, recent?.brightness ?? service[.brightness]?.value.intValue)
        }
    }

    /// A shutter moving (Position State opening or closing) stops where it is (Hold Position, else its target set to where
    /// it is); answers whether it was moving. A channel's button stops its shutters before anything else.
    func stopIfMoving() async -> Bool {
        guard case .covering(let covering) = target(), let state = covering[.positionState]?.value.intValue, state != 2 else { return false }
        do {
            if let hold = covering[.holdPosition] {
                try await hold.write(.bool(true))
            } else if let current = covering[.currentPosition]?.value.intValue {
                try await covering[.targetPosition]?.write(.int(current))
            }
            lastSet = nil
        } catch {}
        return true
    }

    /// Once its power is back: on, and at a visible level when it was left at the floor. What its plugin remembers from
    /// before the power went is not trusted.
    func wake() async {
        lastSet = nil
        guard case .light(let service, let on) = target() else { return }
        do {
            if let brightness = service[.brightness], (brightness.value.intValue ?? 100) <= 1 {
                let level = restoreLevel ?? 100
                try await brightness.write(.int(level))
                lastSet = (true, level, .now)
            }
            try await on.write(.bool(true))
            lastSet = (true, lastSet?.brightness ?? service[.brightness]?.value.intValue, .now)
        } catch {
            // Not back yet: the wheel's next notch tries again.
        }
    }

    /// Whether a light's or a shutter's service has a characteristic its plugin marks a security control: a Control never
    /// writes one (locks, doors and alarms are set only by a person).
    static func isSecure(_ service: Service) -> Bool {
        service.characteristics.contains { $0.isSecurityControl }
    }

    private func target() -> Target? {
        guard let accessory = find(lightID) else { return nil }
        if let covering = Self.covering(in: accessory) { return Self.isSecure(covering) ? nil : .covering(covering) }
        guard let service = accessory.services.first(where: { $0.type == .lightbulb && $0[.brightness] != nil })
                ?? accessory.services.first(where: { $0.type == .lightbulb }),
              let on = service[.on], !Self.isSecure(service) else { return nil }
        return .light(service, on: on)
    }

    private func recentSet() -> (on: Bool, brightness: Int?, at: ContinuousClock.Instant)? {
        lastSet.flatMap { ContinuousClock.now - $0.at < trustLastSet ? $0 : nil }
    }

    private func moveCovering(_ covering: Service, to position: Int) async {
        let target = min(max(position, 0), 100)
        do {
            try await covering[.targetPosition]?.write(.int(target))
            lastSet = (target > 0, target, .now)
        } catch {
            // No Response: the next notch tries again.
        }
    }

    /// Answers whether the step went below the floor.
    @discardableResult
    private func write(_ change: Write, holdAtFloor: Bool) async -> Bool {
        switch target() {
        case .covering(let covering)?:
            // A shutter: a notch moves it a step from where the wheel last sent it (its target, not where it is yet);
            // the button opens it, or closes it when it is more than half open.
            let position = state(of: .covering(covering)).brightness ?? 0
            switch change {
            case .step(let percent): await moveCovering(covering, to: position + percent)
            case .toggle: await moveCovering(covering, to: position <= 50 ? 100 : 0)
            case .set(let open): await moveCovering(covering, to: open ? 100 : 0)
            }
            return false
        case .light(let service, let on)?:
            do {
                return try await writeLight(change, service: service, on: on, holdAtFloor: holdAtFloor)
            } catch {
                // The light's plugin said No Response: the next turn tries again.
                return false
            }
        case nil:
            return false
        }
    }

    private func writeLight(_ change: Write, service: Service, on: Characteristic, holdAtFloor: Bool) async throws -> Bool {
        let (isOn, level) = state(of: .light(service, on: on))
        let percent: Int
        switch change {
        case .step(let value):
            percent = value
        case .toggle, .set:
            let wanted: Bool
            if case .set(let value) = change { wanted = value } else { wanted = !isOn }
            guard wanted != isOn else { return false }
            // Back on from the floor (the wheel's 1 %, or a light left there): at the level it had before, else full.
            var restored = level
            if wanted, let brightness = service[.brightness], (level ?? 100) <= 1 {
                restored = restoreLevel ?? 100
                try await brightness.write(.int(restored ?? 100))
            }
            try await on.write(.bool(wanted))
            lastSet = (wanted, restored, .now)
            return false
        }
        guard let brightness = service[.brightness] else {
            // A light without Brightness: turning up switches it on, down off (or, held, stays on for its power).
            if percent < 0, holdAtFloor { return isOn }
            if (percent > 0) != isOn { try await on.write(.bool(percent > 0)) }
            lastSet = (percent > 0, nil, .now)
            return false
        }
        let current = isOn ? (level ?? 100) : 0
        let next = Self.target(current: current, change: percent, isOn: isOn)
        if next <= 1, current > 1 { restoreLevel = current }
        if next == 0 {
            if holdAtFloor { return isOn }
            if isOn { try await on.write(.bool(false)) }
            lastSet = (false, level, .now)
        } else {
            if next != brightness.value.intValue || recentSet() != nil { try await brightness.write(.int(next)) }
            if !isOn { try await on.write(.bool(true)) }
            lastSet = (true, next, .now)
        }
        return false
    }

    /// The brightness after a change: within 1–100 while on; dimming below 1 % turns it off, and turning up from off
    /// starts from nothing.
    static func target(current: Int, change: Int, isOn: Bool) -> Int {
        let base = isOn ? current : 0
        let next = base + change
        if next <= 0 { return isOn && base > 1 ? 1 : 0 }
        return min(next, 100)
    }
}

/// A Control's lights and shutters driven together, and the switches that power them when it has some (Power Switches,
/// relays such as eWeLink's), switched together: a toggle switches that power (off when any is on, else on), dimming up
/// switches it on first (then waits `powerDelay` for the lights to come back), and dimming down past the floor switches it
/// off, the lights left on so they come back with it. Without Power Switches, a toggle switches the lights, all the same
/// way. One runner per set of targets: the Controls that share them share its power and its hold.
actor ControlRunner {
    let targets: ControlTargets
    private let find: @Sendable (String) -> Accessory?
    /// Its lights' writers, in `targets.lights`' order, shared with every runner that drives the same light.
    private let writers: [DimmerWriter]
    /// Notches that came while the power was coming on, applied once the lights are back.
    private var queued = 0
    private var powering = false
    /// The button held: a step every `holdInterval` until it is let go, up or down, the other way from the last hold.
    private var holding: Task<Void, Never>?
    /// The last hold's way, for the next to go the other.
    private var lastHoldUp: Bool?
    static let holdInterval: Duration = .milliseconds(300)
    /// The longest a hold dims, should its end be lost (a remote's release missed): 60 steps.
    static let longestHold = 60

    init(targets: ControlTargets, writers: [DimmerWriter], find: @escaping @Sendable (String) -> Accessory?) {
        self.targets = targets
        self.writers = writers
        self.find = find
    }

    func apply(_ action: DimmerAction, step: Int) async {
        let power = powerSwitches()
        guard !power.isEmpty else {
            switch action {
            case .toggle:
                // A shutter moving stops first; else all the same way: off (closed) when any is on (open), else on.
                if await Self.stopMoving(writers) { return }
                var anyOn = false
                for writer in writers where await writer.state()?.on == true { anyOn = true }
                let wanted = !anyOn
                await Self.each(writers) { await $0.switchTo(wanted) }
            case .step:
                await Self.each(writers) { _ = await $0.apply(action, step: step) }
            }
            return
        }
        // Powered while any of its switches is on: one off still takes the others down with it, one on brings them all.
        let isOn = power.contains { $0.value.boolValue == true }
        switch action {
        case .toggle:
            if powering { return }
            if isOn { await Self.switchAll(power, false) } else { await powerOn(power, step: step) }
        case .step(let notches) where notches > 0 && (!isOn || powering):
            queued += notches
            if !powering { await powerOn(power, step: step) }
        case .step(let notches) where notches < 0 && (!isOn || powering):
            return
        case .step:
            var belowFloor = false
            await withTaskGroup(of: Bool.self) { group in
                for writer in writers { group.addTask { await writer.apply(action, step: step, holdAtFloor: true) } }
                for await below in group where below { belowFloor = true }
            }
            // Past the floor once every light is at it: the power goes off, the lights stay on to come back with it.
            if belowFloor {
                var allAtFloor = true
                for writer in writers where (await writer.state()).map({ $0.on && ($0.brightness ?? 1) > 1 }) ?? false { allAtFloor = false }
                if allAtFloor { await Self.switchAll(power, false) }
            }
        }
    }

    /// Switches them all on or off: with Power Switches, the power (on, then the lights woken), else each light.
    func switchTo(_ on: Bool, step: Int) async {
        let power = powerSwitches()
        guard !power.isEmpty else {
            await Self.each(writers) { await $0.switchTo(on) }
            return
        }
        if on {
            // Powered already: the lights themselves (switched off while their relay stayed on).
            if power.contains(where: { $0.value.boolValue == true }) {
                if !powering { await Self.each(writers) { await $0.switchTo(true) } }
            } else if !powering {
                await powerOn(power, step: step)
            }
        } else {
            await Self.switchAll(power, false)
        }
    }

    /// Moving shutters stop where they are.
    func stop() async {
        _ = await Self.stopMoving(writers)
    }

    /// The button held: dims a step every `holdInterval` until `release()`, or for `duration` when the end will not be
    /// known (HomeKit's long press), up or down as `direction` says; alternating, the other way from the last hold (the
    /// first: up when the lights are off or at half or below), and never against a limit: at full it dims, at the lowest
    /// it brightens.
    func hold(step: Int, direction: RemoteControl.Direction = .alternate, for duration: Duration? = nil) async {
        holding?.cancel()
        var level: Int?
        for writer in writers { if let state = await writer.state() { level = state.on ? (state.brightness ?? 100) : 0; break } }
        var up: Bool
        switch direction {
        case .up: up = true
        case .down: up = false
        case .alternate:
            up = lastHoldUp.map { !$0 } ?? ((level ?? 0) <= 50)
            if let level, up, level >= 100 { up = false }
            if let level, !up, level <= 1 { up = true }
        }
        lastHoldUp = up
        let steps = duration.map { max(1, Int($0 / Self.holdInterval)) } ?? Self.longestHold
        holding = Task {
            for _ in 0..<steps where !Task.isCancelled {
                await self.apply(.step(up ? 1 : -1), step: step)
                try? await Task.sleep(for: Self.holdInterval)
            }
        }
    }

    /// The button let go: the dimming stops where it is.
    func release() {
        holding?.cancel()
        holding = nil
    }

    /// The power switches' On: each a Switch's or an Outlet's.
    private func powerSwitches() -> [Characteristic] {
        targets.power.compactMap { id in find(id).flatMap(RemoteControl.powerSwitch(of:)) }
    }

    private func powerOn(_ power: [Characteristic], step: Int) async {
        powering = true
        defer { powering = false }
        guard await Self.switchAll(power, true) else { queued = 0; return }
        try? await Task.sleep(for: targets.powerDelay)
        await Self.each(writers) { await $0.wake() }
        let notches = queued
        queued = 0
        if notches > 0 { await Self.each(writers) { _ = await $0.apply(.step(notches), step: step) } }
    }

    /// Switches every power switch that is not already so; answers whether any took it.
    @discardableResult
    private static func switchAll(_ power: [Characteristic], _ on: Bool) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for switchOn in power where switchOn.value.boolValue != on {
                group.addTask { (try? await switchOn.write(.bool(on))) != nil }
            }
            return await group.reduce(false) { $0 || $1 }
        }
    }

    /// Stops every shutter moving, at the same time; answers whether any was.
    private static func stopMoving(_ writers: [DimmerWriter]) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for writer in writers { group.addTask { await writer.stopIfMoving() } }
            return await group.reduce(false) { $0 || $1 }
        }
    }

    private static func each(_ writers: [DimmerWriter], _ body: @escaping @Sendable (DimmerWriter) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for writer in writers { group.addTask { await body(writer) } }
        }
    }
}
