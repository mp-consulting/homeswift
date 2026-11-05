import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

// Pan and tilt (docs/clean-room/TapoPTZ.md): the lens on the motor (a C675D's tele lens) moves through the camera's
// control API, only while a live view keeps the camera awake: a move never wakes a battery camera on its own (6.2).
// Whether a camera has a motor is asked once, the first time it is watched, and kept in `ptz.json`; so are its presets.
// The web UI's live view draws the controls (`cameraControls`), and the Assistant and MCP clients get the same moves as
// actions.
extension TapoPlugin {
    /// How far a step of the live view's pad turns the camera, in the camera's units (degrees, 5.2).
    static let stepAngle = 15

    /// What is known of a camera's motor, by Device Id.
    struct PTZState: Codable, Sendable, Equatable {
        var supported: Bool
        var presets: [CameraControls.Preset] = []
    }

    /// How long a camera that could not be asked about its motor is left alone (a wrong password, a locked sign-in).
    static let ptzProbeBackoff: Duration = .seconds(600)
    /// How often a watched camera's presets are read again, for the ones added or removed in the Tapo app.
    static let presetRefresh: Duration = .seconds(300)

    private var ptzFile: JSONFile<[String: PTZState]> { context.jsonFile("ptz.json", as: [String: PTZState].self) }

    /// The kept state of a camera's motor, from `ptz.json` the first time.
    func keptPTZ(_ deviceID: String) -> PTZState? {
        if ptzStates == nil { ptzStates = ptzFile.load() ?? [:] }
        return ptzStates?[deviceID]
    }

    /// A camera's control API, its certificate pinned the first time (TapoPTZ.md 2) and kept in `control-certificates.json`.
    func makeControl(deviceID: String, host: String) -> TapoControl {
        let http: @Sendable () -> any HTTPSending
        let observe: @Sendable (String?) -> Void
        var resetTrust: @Sendable () -> Void = {}
        if let fake = dependencies.controlHTTP {
            http = { fake }
            observe = { _ in }
        } else {
            let pins = controlPins
            let trust = HTTPClient.TrustOnFirstUse(pinned: pins[deviceID]) { fingerprint in
                pins[deviceID] = fingerprint
                try? pins.flush()
            }
            http = { trust.client }
            observe = { trust.observe($0) }
            resetTrust = {
                trust.reset()
                pins[deviceID] = nil
                try? pins.flush()
            }
        }
        return TapoControl(host: host, http: http, observe: observe, resetTrust: resetTrust, password: { [weak self] in self?.credentials?.password },
                           timeout: scaled(10), motorSpacing: scaled(1), logger: logger)
    }

    /// The camera whose motor moves `accessoryID`, by its accessory id or Device Id.
    func movable(_ id: String) -> (deviceID: String, runtime: TapoCameraRuntime)? {
        for (deviceID, runtime) in cameraRuntimes where runtime.movableLens != nil {
            if runtime.movableLens == id || deviceID == id || Self.accessoryID(deviceID: deviceID) == id { return (deviceID, runtime) }
        }
        return nil
    }

    /// The motor's state: kept, else asked now when the camera is awake (watched); nil while it is not known.
    func ptzState(deviceID: String, runtime: TapoCameraRuntime) async -> PTZState? {
        if let kept = keptPTZ(deviceID) { return kept }
        if let failed = ptzProbeFailures[deviceID], ContinuousClock.now - failed < Self.ptzProbeBackoff { return nil }
        guard await runtime.feed.isConnected, let control = runtime.control else { return nil }
        let state: PTZState
        do {
            state = PTZState(supported: true, presets: try await control.presets())
        } catch TapoControlError.code(let code) where TapoControlError.unsupportedCodes.contains(code) {
            state = PTZState(supported: false)
        } catch {
            // Asleep: asked again at the next live view; anything else (a refusal, a lockout) not for a while.
            if (error as? TapoControlError) != .asleep { ptzProbeFailures[deviceID] = .now }
            logger.info("\(name(of: runtime)): cannot tell whether it pans and tilts: \(error)")
            return nil
        }
        logger.info("\(name(of: runtime)) \(state.supported ? "pans and tilts, with \(state.presets.count) presets" : "does not pan or tilt")")
        presetsReadAt[deviceID] = .now
        ptzStates?[deviceID] = state
        do { try ptzFile.save(ptzStates ?? [:]) } catch { logger.warning("Could not keep what the cameras' motors do: \(error)") }
        return state
    }

    /// Reads a watched camera's presets again, when the kept ones are older than `presetRefresh` (or `force`), keeping them.
    @discardableResult
    func refreshPresets(deviceID: String, runtime: TapoCameraRuntime, force: Bool = false) async -> PTZState? {
        guard let kept = keptPTZ(deviceID), kept.supported else { return keptPTZ(deviceID) }
        if !force, let last = presetsReadAt[deviceID], ContinuousClock.now - last < Self.presetRefresh { return kept }
        guard await runtime.feed.isConnected, let control = runtime.control, let presets = try? await control.presets() else { return kept }
        presetsReadAt[deviceID] = .now
        guard presets != kept.presets else { return kept }
        let state = PTZState(supported: true, presets: presets)
        ptzStates?[deviceID] = state
        do { try ptzFile.save(ptzStates ?? [:]) } catch { logger.warning("Could not keep what the cameras' motors do: \(error)") }
        return state
    }

    private func name(of runtime: TapoCameraRuntime) -> String {
        runtime.cameras.first { $0.accessory.id == runtime.movableLens }?.accessory.name ?? runtime.cameras.first?.accessory.name ?? "The camera"
    }

    // MARK: The web UI's live view

    public func cameraControls(accessoryID: String) async -> CameraControls? {
        guard let (deviceID, runtime) = movable(accessoryID), runtime.movableLens == accessoryID,
              await ptzState(deviceID: deviceID, runtime: runtime)?.supported == true,
              let state = await refreshPresets(deviceID: deviceID, runtime: runtime) else { return nil }
        return CameraControls(presets: state.presets)
    }

    public func controlCamera(accessoryID: String, _ command: CameraCommand) async throws {
        switch command {
        case .move(let direction):
            try await move(accessoryID, direction: direction, angle: Self.stepAngle)
        case .preset(let id):
            try await goToPreset(accessoryID, id)
        case .home:
            throw CameraControlError("Tapo cameras have no home position: save one as a preset in the Tapo app")
        }
    }

    /// Runs `work` on the control API of a camera that is awake and pans and tilts, its errors in words.
    private func withControl(_ id: String, _ work: (TapoControl, PTZState, _ deviceID: String, _ runtime: TapoCameraRuntime) async throws -> Void) async throws {
        guard let (deviceID, runtime) = movable(id), let control = runtime.control else { throw CameraControlError("no Tapo camera that pans and tilts is \(id)") }
        guard await runtime.feed.isConnected else {
            throw CameraControlError("\(name(of: runtime)) is asleep: open its live view first, so moving it does not wake it")
        }
        let state = await ptzState(deviceID: deviceID, runtime: runtime) ?? PTZState(supported: true)
        guard state.supported else { throw CameraControlError("\(name(of: runtime)) does not pan or tilt") }
        do {
            try await work(control, state, deviceID, runtime)
        } catch TapoControlError.code(-64304) {
            // The end of the range: not a failure, nothing more that way.
            throw CameraControlError("\(name(of: runtime)) cannot turn further that way")
        } catch let error as TapoControlError {
            throw CameraControlError(error.description)
        }
    }

    func move(_ id: String, direction: CameraControls.Direction, angle: Int) async throws {
        let (x, y) = switch direction {
        case .up: (0, angle)
        case .down: (0, -angle)
        case .left: (-angle, 0)
        case .right: (angle, 0)
        }
        try await withControl(id) { control, _, _, _ in try await control.move(x: x, y: y) }
    }

    func goToPreset(_ id: String, _ preset: String) async throws {
        try await withControl(id) { control, state, deviceID, runtime in
            func find(_ presets: [CameraControls.Preset]) -> CameraControls.Preset? {
                presets.first { $0.id == preset || $0.name.caseInsensitiveCompare(preset) == .orderedSame }
            }
            // One the Tapo app added since they were read: read them again before refusing.
            var found = find(state.presets)
            if found == nil { found = find(await refreshPresets(deviceID: deviceID, runtime: runtime, force: true)?.presets ?? []) }
            guard let found else {
                throw CameraControlError("no preset \(preset): list_ptz_cameras gives them")
            }
            do {
                try await control.goToPreset(found.id)
            } catch TapoControlError.code(let code) where code == -64302 || code == -64321 {
                // Removed in the Tapo app: the list is read again for next time.
                await refreshPresets(deviceID: deviceID, runtime: runtime, force: true)
                throw CameraControlError("\(found.name) is no longer a preset of the camera")
            }
        }
    }

    // MARK: The Assistant and MCP clients

    public static let assistantActions: [AssistantAction] = {
        let camera: JSONValue = ["type": "string", "description": "The camera's accessory id (TapoP100:<Device Id>:tele for a C675D), from list_ptz_cameras"]
        return [
            AssistantAction(
                name: "list_ptz_cameras", title: "Look at the cameras that pan and tilt",
                description: "The Tapo cameras whose lens pans and tilts (a C675D's tele lens), by accessory id: whether the motor is known "
                    + "(it is asked the first time the camera is watched), its presets (id and name), and whether the camera is awake now. "
                    + "A battery camera moves only while awake, which a live view keeps it.",
                path: "ptz", access: .read),
            AssistantAction(
                name: "move_camera", title: "Turn a camera",
                description: "Turns a Tapo camera's lens up, down, left or right by an angle (default 15, at most 90). Only while the camera is "
                    + "awake (its live view open in the Home app or the web UI): moving never wakes it.",
                method: "POST", path: "ptz/move", access: .configure,
                inputSchema: [
                    "type": "object", "required": ["camera", "direction"],
                    "properties": [
                        "camera": camera, "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                        "angle": ["type": "integer", "minimum": 1, "maximum": 90],
                    ],
                ]),
            AssistantAction(
                name: "go_to_preset", title: "Turn a camera to a preset",
                description: "Turns a Tapo camera to one of its presets, by id or name (from list_ptz_cameras), while it is awake.",
                method: "POST", path: "ptz/preset", access: .configure,
                inputSchema: ["type": "object", "required": ["camera", "preset"], "properties": ["camera": camera, "preset": ["description": "The preset's id or name"]]]),
        ]
    }()

    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "ptz"):
            var list: [JSONValue] = []
            for (deviceID, runtime) in cameraRuntimes.sorted(by: { $0.key < $1.key }) {
                guard let lens = runtime.movableLens else { continue }
                let state = keptPTZ(deviceID)
                if state?.supported == false { continue }
                list.append([
                    "camera": .string(lens), "name": .string(name(of: runtime)), "awake": .bool(await runtime.feed.isConnected),
                    "motor": state == nil ? "unknown" : "yes",
                    "presets": .array((state?.presets ?? []).map { ["id": .string($0.id), "name": .string($0.name)] }),
                ])
            }
            return PluginWebResponse(["cameras": .array(list)])
        case ("POST", "ptz/move"):
            guard let id = request.body["camera"]?.stringValue else { return .error(400, "give camera") }
            guard let direction = request.body["direction"]?.stringValue.flatMap(CameraControls.Direction.init(rawValue:)) else {
                return .error(400, "direction must be up, down, left or right")
            }
            let angle = min(90, max(1, request.body["angle"]?.saturatingIntValue ?? Self.stepAngle))
            return await answer { try await self.move(id, direction: direction, angle: angle) }
        case ("POST", "ptz/preset"):
            guard let id = request.body["camera"]?.stringValue, let preset = request.body["preset"]?.stringValue ?? request.body["preset"]?.saturatingIntValue.map(String.init) else {
                return .error(400, "give camera and preset")
            }
            return await answer { try await self.goToPreset(id, preset) }
        default:
            return .error(404, "not found")
        }
    }

    private func answer(_ work: @Sendable () async throws -> Void) async -> PluginWebResponse {
        do {
            try await work()
            return PluginWebResponse(["ok": true])
        } catch let error as CameraControlError {
            return .error(409, error.description)
        } catch {
            return .error(502, "\(error)")
        }
    }
}
