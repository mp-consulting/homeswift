import Foundation
import Homeswift
import HomeswiftPlugin

/// A range (oven and cooktop), published on its own: the board also reads out the probe and each burner; besides
/// the cooking appliance's valves, switches and thermostat, a Monitor Only switch, Keep Warm, the door, the
/// cooking motion sensor, remote control, the number of burners as a light sensor, and a thermostat for the probe.
final class Oven: CookingAppliance {
    nonisolated static let inputMax = 14
    nonisolated static let ovenMaxC = 300.0
    nonisolated static let probeMaxC = 285.0
    nonisolated static let minLux = 0.0001
    nonisolated static let twelveHours = 43_200.0
    nonisolated static let thirtyMinutes = 1800.0

    override class var appliance: String { "Oven" }
    override class var statusPrefix: String { "upper" }
    override class var timerHasHours: Bool { true }
    override class var cookTimeLabels: CookTimeTracker.Labels {
        .init(start: "Oven Start Time Not Set", cookTime: "Oven Cook Time Not Set", end: "Oven End Time Not Set", timer: "Oven Timer Not Set")
    }

    struct Command: Equatable {
        var ovenMode = "NONE"
        var ovenSetTemperature = 350.0
        var tempUnits = "FAHRENHEIT"
        var ovenSetDuration = 1800.0
        var probeTemperature = 0.0
        var ovenKeepWarm = "DISABLE"
    }

    nonisolated static let burners: [Cooking.Burner] = [
        .init(index: 1, label: "Front Left", subtype: "NicoCataGaTa-Oven001", identifier: 10),
        .init(index: 2, label: "Back Left", subtype: "NicoCataGaTa-Oven002", identifier: 11),
        .init(index: 3, label: "Center", subtype: "NicoCataGaTa-Oven003", identifier: 12),
        .init(index: 4, label: "Front Right", subtype: "NicoCataGaTa-Oven004", identifier: 13),
        .init(index: 5, label: "Back Right", subtype: "NicoCataGaTa-Oven005", identifier: 14),
    ]

    nonisolated static let modeSwitches: [ModeDefinition] = [
        .init(name: "Bake Mode", subtype: "CataNicoGaTa-80", mode: "BAKE"),
        .init(name: "Convection Bake Mode", subtype: "CataNicoGaTa-Control1", mode: "CONVECTION_BAKE"),
        // Sent as CONVECTION_ROST, reported as CONVECTION_ROAST.
        .init(name: "Convection Roast Mode", subtype: "CataNicoGaTa-Control2", mode: "CONVECTION_ROST", aliases: ["CONVECTION_ROAST"]),
        .init(name: "Frozen Meal Mode", subtype: "CataNicoGaTa-Control3", mode: "FROZEN_MEAL"),
        .init(name: "Air Fry Mode", subtype: "CataNicoGaTa-Control4", mode: "AIR_FRY"),
        .init(name: "Air Sousvide Mode", subtype: "CataNicoGaTa-Control5", mode: "AIR_SOUSVIDE"),
        .init(name: "Proof-Warm Mode", subtype: "CataNicoGaTa-Control5W", mode: "WARM"),
    ]

    nonisolated static let modeLabels: [String: String] = [
        "NONE": "None", "BAKE": "Bake", "ROAST": "Roast", "CONVECTION_BAKE": "Convection Bake", "CONVECTION_ROAST": "Convection Roast",
        "CONVECTION_ROST": "Convection Roast", "CRISP_CONVECTION": "Crisp Convection", "FAVORITE": "Favorite", "BROIL": "Broil", "WARM": "Warm",
        "PROOF": "Proof", "FROZEN_MEAL": "Frozen Meal", "SLOW_COOK": "Slow Cook", "PROBE_SET": "Probe Set", "EASY_CLEAN": "Easy Clean",
        "SPEED_BROIL": "Speed Broil", "SELF_CLEAN": "Self Clean", "SPEED_ROAST": "Speed Roast", "AIR_FRY": "Air Fry", "PIZZA": "Pizza",
        "AIR_SOUSVIDE": "Air Sousvide",
    ]

    nonisolated static let stateLabels: [String: String] = [
        "PREHEATING": "Preheating", "COOKING_IN_PROGRESS": "Baking", "DONE": "Done Baking", "COOLING": "Cooling Down",
        "CLEANING": "Cleaning Itself", "CLEANING_DONE": "Done Cleaning Itself",
    ]

    var ovenCommandList = Command()
    var homekitMonitorOnly = true
    var wasOn = false

    var probeService: Service!
    var burnerServices: [(burner: Cooking.Burner, service: Service)] = []
    var monitorOnlySwitch: Service!
    var keepWarmSwitch: Service?
    var ovenDoorOpened: Service!
    var rangeOn: Service!
    var remoteEnabled: Service!
    var burnersOnNumber: Service!
    var probeTempControl: Service!

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        super.init(device: device, environment: environment)
        let data = status

        createBoard(configuredName: "LG Range", inputs: Self.inputMax)
        probeService = addBoardInputs(mode: "Oven Mode", temperature: "Oven Temperature", cooking: isOvenOn(), extra: "Probe Status",
            extraShown: probeStatus().shown, extraFirst: false) { (oven: Oven) in oven.probeStatus().name }
        burnerServices = Self.burners.map { burner in
            (burner, input("\(burner.label) Burner Status", burner.subtype, burner.identifier, Cooking.burnerStatus(data, burner).inUse) {
                Cooking.burnerStatus($0.status, burner).name
            })
        }

        addValves(cookTime: "Oven Cook Time", cookTimeMax: Self.twelveHours - 1, timer: "Oven Timer", timerMax: Self.twelveHours, timerLimit: Self.twelveHours - 1)
        addModeSwitches(Self.modeSwitches)
        addStopSwitch("Stop Oven")
        monitorOnlySwitch = createSwitch("Monitor Only Mode", subtype: "CataNicoGaTa-Control7")
        monitorOnlySwitch.characteristic(.on).onGet { [weak self] in .bool(self?.isMonitorOnly() ?? true) }
            .onSet { [weak self] value in self?.homekitMonitorOnly = Normalize.boolean(value) }
        addStartSwitch("Start Oven")
        if data["upperCookAndWarmStatus"] != nil {
            let keepWarm = createSwitch("Keep Warm", subtype: "CataNicoGaTa-Control9")
            keepWarm.characteristic(.on).onGet { [weak self] in .bool(self?.isKeepWarmOn() ?? false) }
                .onSet { [weak self] value in
                    guard let self else { return }
                    ovenCommandList.ovenKeepWarm = Normalize.boolean(value) ? "ENABLE" : "DISABLE"
                    markUserSelection()
                }
            keepWarmSwitch = keepWarm
        }

        ovenDoorOpened = addService(.contactSensor, name: "Oven Door", subtype: "NicoCataGaTa-OvenTCBCS", optional: [.statusActive])
        ovenDoorOpened.set(.statusActive, onStatus())
        ovenDoorOpened.set(.contactSensorState, doorContactState())
        rangeOn = addService(.motionSensor, name: "Range is Cooking", subtype: "NicoCataGaTa-OvenTCBCSMotion", optional: [.statusActive])
        rangeOn.set(.statusActive, onStatus())
        rangeOn.set(.motionDetected, onStatus())
        remoteEnabled = addService(.contactSensor, name: "Remote Control Enabled", subtype: "NicoCataGaTa-OvenTCRCS", optional: [.statusActive])
        remoteEnabled.set(.statusActive, onStatus())
        remoteEnabled.set(.contactSensorState, remoteContactState())
        burnersOnNumber = addService(.lightSensor, name: "Number of Burners in Use", subtype: "NicoCataGaTa-OvenTCB", optional: [.statusActive])
        burnersOnNumber.set(.currentAmbientLightLevel, burnerLux())
        burnersOnNumber.set(.statusActive, burnerCount() > 0)

        addTemperatureControl("Oven Temperature Control", subtype: "NicoCataGaTa-OvenTC", current: 0...Self.ovenMaxC, targetMax: Self.ovenMaxC)

        probeTempControl = addService(.thermostat, name: "Probe Temperature Control", subtype: "NicoCataGaTa-OvenTCP2", optional: [
            CharacteristicType.targetHeatingCoolingState.valid([0, 1]),
            CharacteristicType.currentTemperature.props(min: 0, max: Self.probeMaxC, step: 0.1),
            CharacteristicType.targetTemperature.props(min: Self.minTargetC, max: Self.probeMaxC, step: 0.1),
            .currentRelativeHumidity,
        ])
        probeTempControl.set(.currentHeatingCoolingState, probeCurrentState())
        probeTempControl.characteristic(.targetHeatingCoolingState).onGet { [weak self] in .int(self?.probeTargetState() ?? 0) }
            .onSet { [weak self] _ in self?.pauser.pause(Self.userEditPause) }
        probeTempControl.characteristic(.currentTemperature).onGet { [weak self] in .double(self?.probeCurrentTemperature() ?? Self.ambientC) }
        probeTempControl.characteristic(.currentRelativeHumidity).onGet { .double(Self.ambientHumidity) }
        probeTempControl.characteristic(.targetTemperature).onGet { [weak self] in .double(self?.probeTargetTemperature() ?? Self.minTargetC) }
            .onSet { [weak self] value in
                guard let self else { return }
                guard let celsius = Normalize.number(value) else {
                    logger.error("Probe TargetTemperature is not a valid number")
                    return
                }
                ovenCommandList.probeTemperature = Cooking.isFahrenheit(status["upperCurrentTemperatureUnit"]) ? Cooking.tempCtoF(celsius) : celsius.rounded(.toNearestOrAwayFromZero)
                markUserSelection()
            }
        probeTempControl.set(.name, "Probe Temperature Control")
    }

    // MARK: The pending cook

    override var selectedMode: String {
        get { ovenCommandList.ovenMode }
        set { ovenCommandList.ovenMode = newValue }
    }

    override func setCookDuration(_ seconds: Double) { ovenCommandList.ovenSetDuration = seconds }

    override func selectTargetTemperature(_ celsius: Double) {
        ovenCommandList.ovenSetTemperature = Cooking.isFahrenheit(status["upperCurrentTemperatureUnit"]) ? Cooking.tempCtoF(celsius) : celsius.rounded(.toNearestOrAwayFromZero)
    }

    override func boardActive() -> Int { serviceActive() }

    override func setBoardActive(_ on: Bool) async throws {
        if on { try await sendOvenCommand() } else { try await stopOven() }
    }

    // MARK: Commands

    /// The cook command from the pending selection: defaults (30 minutes, BAKE) and the mode's limits.
    func prepareOvenCommand() -> Command {
        let reported = status["upperCurrentTemperatureUnit"]?.stringValue
        let unit = reported ?? ovenCommandList.tempUnits
        var command = ovenCommandList
        command.tempUnits = unit
        if command.ovenSetDuration == 0 { command.ovenSetDuration = Self.thirtyMinutes }
        if command.ovenMode == "NONE" { command.ovenMode = "BAKE" }
        if command.ovenMode.contains("WARM") {
            return Command(ovenMode: "WARM", ovenSetTemperature: 0, tempUnits: Cooking.isFahrenheit(.string(unit)) ? "FAHRENHEIT" : "CELSIUS",
                ovenSetDuration: 0, probeTemperature: 0, ovenKeepWarm: "DISABLE")
        }
        command.ovenSetTemperature = Cooking.clampCookTemp(Cooking.ovenLimits, mode: command.ovenMode, unit: .string(unit), command.ovenSetTemperature)
        return command
    }

    override func sendOvenCommand() async throws {
        if isMonitorOnly() {
            logger.info("[\(device.name)] Monitor Only Mode is on; oven command not sent")
            return
        }
        try await commandGate.run {
            pauser.pause(Self.userEditPause)
            defer { pauser.pause(Self.commandSettle) }
            let command = prepareOvenCommand()
            ovenCommandList = command
            logger.debug("Sending the following commands: \(command)")
            try await sendOvenState("SetCookStart", [
                "cmdOptionContentsType": "REMOTE_COOK_START", "cmdOptionDataLength": "REMOTE_COOK_START",
                "cmdOptionSetCookAndWarm": .string(command.ovenKeepWarm), "cmdOptionSetCookName": .string(command.ovenMode),
                "cmdOptionSetMyRecipeCookNumber": 0, "cmdOptionSetSteamLevel": "", "cmdOptionSetSubCookNumber": 0,
                "cmdOptionSetTargetTemperatureUnit": .string(command.tempUnits),
                "cmdOptionSetTargetTimeHour": .number((command.ovenSetDuration / 3600).rounded(.down)),
                "cmdOptionSetTargetTimeMinute": .number((command.ovenSetDuration.truncatingRemainder(dividingBy: 3600) / 60).rounded(.down)),
                "cmdOptionSetRapidPreheat": "OFF", "setTargetProveTemperature": .number(command.probeTemperature),
                "setTargetTemperature": .number(command.ovenSetTemperature),
            ])
            clearUserSelection()
        }
    }

    // MARK: State

    override func isMonitorOnly() -> Bool { Cooking.includes(status["upperRemoteStart"], "DIS") || homekitMonitorOnly }
    /// The oven is on: its state known and not INITIAL.
    func isOvenOn() -> Bool { Cooking.excludes(status["upperState"], "INITIAL") }
    func burnerCount() -> Double { Cooking.toNumber(status["burnerOnCounter"]) }
    func burnerLux() -> Double { burnerCount() < 1 ? Self.minLux : burnerCount() }
    /// The oven or a burner is on.
    func onStatus() -> Bool { isOvenOn() || burnerCount() > 0 }
    func serviceActive() -> Int { onStatus() ? 1 : 0 }
    func isKeepWarmOn() -> Bool { Cooking.excludes(status["upperCookAndWarmStatus"], "DIS") }
    /// 1: no contact (the door is open).
    func doorContactState() -> Int { Cooking.excludes(status["upperDoorOpen"], "DIS") ? 1 : 0 }
    func remoteContactState() -> Int { Cooking.excludes(status["upperRemoteStart"], "DIS") ? 1 : 0 }

    override func ovenModeName() -> String {
        let cookName = status["upperManualCookName"]?.stringValue
        let label = cookName.map { Self.modeLabels[$0] ?? Cooking.capitalize(.string($0)) } ?? Self.modeLabels["NONE"]!
        var name = "Oven Mode: \(label)"
        if label != Self.modeLabels["NONE"] { name = withSubCookMenu(name) }
        if isKeepWarmOn() { name += " (Keep Warm On)" }
        return Cooking.truncateName(name)
    }

    func withSubCookMenu(_ name: String) -> String {
        guard let subCook = status["upperSubCookMenu"]?.stringValue, subCook != "NONE" else { return name }
        return "\(name) (\(Cooking.capitalize(.string(subCook))))"
    }

    override func ovenStatus() -> String {
        let data = status
        var text = "Oven is "
        if let state = data["upperState"]?.stringValue {
            if state == "INITIAL" {
                text += "in Standby"
                if Cooking.includes(data["upperRemoteStart"], "DIS") {
                    text += " (Remote Start Disabled)"
                } else if homekitMonitorOnly {
                    text += " (Homekit Monitor Only Mode)"
                }
            } else {
                text += Self.stateLabels[state] ?? Cooking.capitalize(.string(state))
            }
        } else {
            text += "Unknown"
        }
        if Cooking.excludes(data["commonControlLock"], "DIS") { text += " - Controls Locked" }
        return Cooking.truncateName(text)
    }

    override func ovenTemperature() -> String {
        let data = status
        var text = "Oven Temperature Information"
        if let current = Cooking.nonZero(data["upperCurrentTemperatureValue"]) { text = "Current Temp is \(JS.format(current))°" }
        if let target = Cooking.nonZero(data["upperTargetTemperatureValue"]) { text += " With Set Temp \(JS.format(target))°" }
        return Cooking.truncateName(text)
    }

    override func ovenCurrentTemperature() -> Double {
        let data = status
        let unit = data["upperCurrentTemperatureUnit"]
        if let current = Cooking.nonZero(data["upperCurrentTemperatureValue"]) { return clamp(Cooking.toCelsius(current, unit), 0, Self.ovenMaxC) }
        if let target = Cooking.nonZero(data["upperTargetTemperatureValue"]) { return clamp(Cooking.toCelsius(target, unit), 0, Self.ovenMaxC) }
        return Self.ambientC
    }

    override func ovenTargetTemperature() -> Double {
        if let userTargetTemperature { return clamp(userTargetTemperature, Self.minTargetC, Self.ovenMaxC) }
        if let target = Cooking.nonZero(status["upperTargetTemperatureValue"]) {
            return clamp(Cooking.toCelsius(target, status["upperCurrentTemperatureUnit"]), Self.minTargetC, Self.ovenMaxC)
        }
        return Self.minTargetC
    }

    func probeCurrentTemperature() -> Double {
        Cooking.nonZero(status["upperCurrentProveTemperatureF"]).map { clamp(Cooking.tempFtoC($0), 0, Self.probeMaxC) } ?? Self.ambientC
    }

    func probeTargetTemperature() -> Double {
        Cooking.nonZero(status["upperTargetProveTemperatureF"]).map { clamp(Cooking.tempFtoC($0), Self.minTargetC, Self.probeMaxC) } ?? Self.minTargetC
    }

    func probeStatus() -> (name: String, shown: Bool) {
        let data = status
        guard let current = Cooking.nonZero(data["upperCurrentProveTemperatureF"]) else { return ("Probe Settings Not Available", false) }
        let target = Cooking.nonZero(data["upperTargetProveTemperatureF"])
        let fahrenheit = Cooking.isFahrenheit(data["upperCurrentTemperatureUnit"])
        let display = { (value: Double) in JS.format(fahrenheit ? value : Cooking.tempFtoC(value)) }
        var name = ""
        if let target { name += "Food is \(JS.format((100 * current / target).rounded(.toNearestOrAwayFromZero)))% Done, " }
        name += "Current Probe Temp \(display(current))°"
        if let target { name += " With Set Temp \(display(target))°" }
        return (Cooking.truncateName(name), true)
    }

    override func ovenOptionsName() -> String {
        let data = status
        var options = "Settings: " + (Cooking.isFahrenheit(data["upperCurrentTemperatureUnit"]) ? "Temp in °F" : "Temp in °C")
        if Cooking.excludes(data["upperSabbath"], "DIS") { options += ", Sabbath On" }
        if Cooking.includes(data["settingConvAutoConversion"], "ENA") { options += ", Auto Conversion" }
        if Cooking.includes(data["settingPreheatAlarm"], "ON") { options += ", Preheat Alarm" }
        return Cooking.truncateName(options)
    }

    func probeCurrentState() -> Int { Cooking.nonZero(status["upperCurrentProveTemperatureF"]) != nil ? 1 : 0 }
    func probeTargetState() -> Int { Cooking.nonZero(status["upperTargetProveTemperatureF"]) != nil ? 1 : 0 }
    override func currentHeatingState() -> Int { Cooking.nonZero(status["upperCurrentTemperatureValue"]) != nil ? 1 : 0 }
    override func targetHeatingState() -> Int { Cooking.nonZero(status["upperTargetTemperatureValue"]) != nil ? 1 : 0 }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }

    // MARK: Updates

    /// The pending command follows the oven unless the user has an unsent selection: the running cook, or the
    /// defaults when idle.
    func syncCommandList(ovenOn: Bool) {
        if ovenOn, !wasOn { clearUserSelection() }
        wasOn = ovenOn
        if !userSelectionPending {
            let data = status
            if ovenOn {
                ovenCommandList = Command(
                    ovenMode: data["upperManualCookName"]?.stringValue ?? "NONE", ovenSetTemperature: Cooking.toNumber(data["upperTargetTemperatureValue"]),
                    tempUnits: data["upperCurrentTemperatureUnit"]?.stringValue ?? ovenCommandList.tempUnits, ovenSetDuration: ovenTargetTime(),
                    probeTemperature: Cooking.toNumber(data["upperTargetProveTemperatureF"]), ovenKeepWarm: isKeepWarmOn() ? "ENABLE" : "DISABLE")
            } else {
                ovenCommandList = Command()
            }
        }
        syncModeSwitches()
    }

    override func refreshCharacteristics() {
        guard ovenService != nil else { return }
        let data = status
        let ovenOn = isOvenOn()
        let rangeOnNow = onStatus()
        let targetTime = ovenTargetTime()
        let timerTime = ovenTimerTime()
        let remaining = remainTime()

        ovenService.set(.active, rangeOnNow ? 1 : 0)
        syncCommandList(ovenOn: ovenOn)
        cookTimes.update(cooking: Cooking.excludes(data["upperManualCookName"], "NONE"), targetSeconds: targetTime, timerSeconds: timerTime)

        let probe = probeStatus()
        refreshBoard(cooking: ovenOn, targetTime: targetTime, timerTime: timerTime, remaining: remaining)
        probeService.set(.configuredName, probe.name)
        setVisibility(probeService, probe.shown)
        for (burner, service) in burnerServices {
            let burnerStatus = Cooking.burnerStatus(data, burner)
            service.set(.configuredName, burnerStatus.name)
            setVisibility(service, burnerStatus.inUse)
        }

        let units = Cooking.isFahrenheit(data["upperCurrentTemperatureUnit"]) ? 1 : 0
        ovenTempControl.set(.temperatureDisplayUnits, units)
        probeTempControl.set(.temperatureDisplayUnits, units)
        ovenTempControl.set(.currentTemperature, ovenCurrentTemperature())
        if Cooking.nonZero(data["upperTargetTemperatureValue"]) != nil || userTargetTemperature != nil {
            ovenTempControl.set(.targetTemperature, ovenTargetTemperature())
        }
        ovenTempControl.set(.targetHeatingCoolingState, targetHeatingState())
        ovenTempControl.set(.currentHeatingCoolingState, currentHeatingState())
        ovenTempControl.set(.currentRelativeHumidity, Self.ambientHumidity)
        probeTempControl.set(.currentRelativeHumidity, Self.ambientHumidity)
        if Cooking.nonZero(data["upperCurrentProveTemperatureF"]) != nil { probeTempControl.set(.currentTemperature, probeCurrentTemperature()) }
        if Cooking.nonZero(data["upperTargetProveTemperatureF"]) != nil { probeTempControl.set(.targetTemperature, probeTargetTemperature()) }
        probeTempControl.set(.targetHeatingCoolingState, probeTargetState())
        probeTempControl.set(.currentHeatingCoolingState, probeCurrentState())

        monitorOnlySwitch.set(.on, isMonitorOnly())
        ovenDoorOpened.set(.statusActive, rangeOnNow)
        ovenDoorOpened.set(.contactSensorState, doorContactState())
        rangeOn.set(.statusActive, rangeOnNow)
        rangeOn.set(.motionDetected, rangeOnNow)
        remoteEnabled.set(.statusActive, rangeOnNow)
        remoteEnabled.set(.contactSensorState, remoteContactState())
        burnersOnNumber.set(.currentAmbientLightLevel, burnerLux())
        burnersOnNumber.set(.statusActive, burnerCount() > 0)

        if let keepWarmSwitch, data["upperCookAndWarmStatus"] != nil {
            let keepWarm = isKeepWarmOn()
            keepWarmSwitch.set(.on, keepWarm)
            if !userSelectionPending { ovenCommandList.ovenKeepWarm = keepWarm ? "ENABLE" : "DISABLE" }
        }
    }
}
