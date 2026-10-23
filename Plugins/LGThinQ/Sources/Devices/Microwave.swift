import Foundation
import Homeswift
import HomeswiftPlugin

/// An over-the-range microwave, published on its own: besides the cooking appliance's board, valves, switches
/// and thermostat, its vent fan and lamp, the microwave power as a dimmable light, and a switch that turns the
/// vent and lamp off.
final class Microwave: CookingAppliance {
    nonisolated static let inputMax = 9
    nonisolated static let ventSpeedMax = 5.0
    nonisolated static let lampLevelMax = 2.0
    nonisolated static let defaultVentLampLevel = 2.0
    nonisolated static let powerLevelToPercent = 10.0
    nonisolated static let defaultCookSeconds = 300.0
    nonisolated static let cookTimeMax = 9 * 3600.0
    nonisolated static let timerMax = 100 * 60.0 - 1
    nonisolated static let minCurrentC = 10.0
    nonisolated static let maxC = 233.0
    nonisolated static let targetIncrement = 5.0
    nonisolated static let stopSettle: Duration = .milliseconds(1500)

    override class var appliance: String { "Microwave" }
    override class var statusPrefix: String { "LWO" }
    override class var cookTimeLabels: CookTimeTracker.Labels {
        .init(start: "Microwave Start Time Not Set", cookTime: "Microwave Cook Time Not Set", end: "Microwave End Time Not Set", timer: "Microwave Cook Timer Not Set")
    }

    struct Command: Equatable {
        var ovenMode = "NONE"
        var ovenSetTemperature = 0.0
        var tempUnits: String
        var ovenSetDuration = 0.0
        var subCookNumber = 0.0
        var weightUnits = "KG"
        var microwavePower = "100"
        var targetWeight = 0.0

        init(tempUnits: String) { self.tempUnits = tempUnits }
    }

    nonisolated static let modeSwitches: [ModeDefinition] = [
        .init(name: "Microwave Mode", subtype: "CataNicoGaTa-80M", mode: "MICROWAVE"),
        .init(name: "Combination Bake Mode", subtype: "CataNicoGaTa-80B", mode: "COMBI_BAKE"),
        .init(name: "Dehydrate Mode", subtype: "CataNicoGaTa-80d", mode: "DEHYDRATE"),
        .init(name: "Oven Mode", subtype: "CataNicoGaTa-80OVen", mode: "OVEN"),
        .init(name: "Convection Bake Mode", subtype: "CataNicoGaTa-Control1", mode: "CONV_BAKE"),
        .init(name: "Combination Roast Mode", subtype: "CataNicoGaTa-Control2", mode: "COMBI_ROAST"),
        .init(name: "Time Defrost Mode", subtype: "CataNicoGaTa-Control3", mode: "TIME_DEFROST"),
        .init(name: "Defrost Mode", subtype: "CataNicoGaTa-Control3D", mode: "INVERTER_DEFROST"),
        .init(name: "Air Fry Mode", subtype: "CataNicoGaTa-Control4", mode: "AIRFRY"),
        .init(name: "Proof Mode", subtype: "CataNicoGaTa-Control5", mode: "PROOF"),
        .init(name: "Warm Mode (High)", subtype: "CataNicoGaTa-Control5W", mode: "WARM"),
    ]

    nonisolated static let modeLabels: [String: String] = [
        "STANDBY": "Standby", "MICROWAVE": "Microwave", "GRILL": "Grill", "OVEN": "Oven", "COMBI": "Combination", "COMBI_BAKE": "Combination Bake",
        "COMBI_ROAST": "Combination Roast", "INVERTER_DEFROST": "Inverter Defrost", "AUTO_COOK": "Air Fry", "AIRFRY": "Air Fry", "WARM": "Warm",
        "CONV_BAKE": "Convection Bake", "BROIL": "Broil", "DEHYDRATE": "Dehydrate", "SPEED_CONV": "Speed Convection", "SPEED_ROAST": "Speed Roast",
        "SPEED_BROIL": "Speed Broil", "PROOF": "Proof", "SENSOR_COOK": "Sensor Cook", "TIME_DEFROST": "Timed Defrost",
    ]

    nonisolated static let stateLabels: [String: String] = [
        "INITIAL": "in Standby", "PREHEATING": "Preheating", "COOKING_IN_PROGRESS": "Cooking", "DONE": "Done Baking", "COOLING": "Cooling Down",
        "CLEANING": "Cleaning Itself", "CLEANING_DONE": "Done Cleaning Itself", "PAUSED": "Paused", "PREFERENCE": "Preference",
        "ERROR": "Not Working", "READY_TO_START": "Ready To Start", "PREHEATING_IS_DONE": "Done Preheating",
    ]

    /// Sub-cook programs: label and default temperature (°F).
    nonisolated static let subCookPrograms: [Int: (label: String, defaultTempF: Double)] = [
        3335: ("Buffalo Wings", 450), 3212: ("Chicken Nuggets", 450), 3227: ("Chicken Tenders", 450), 3339: ("Fish Sticks", 450),
        3253: ("French Fries", 450), 3345: ("Hash Brown Patties", 450), 3336: ("Mozzarella Sticks", 450), 3343: ("Popcorn Shrimp", 450),
        3225: ("Potato Wedges", 450), 211: ("Meat", 350), 212: ("Poultry", 425), 213: ("Fish", 400), 214: ("Bread", 400),
    ]
    nonisolated static let otherSubCook = (label: "Other Food", defaultTempF: 450.0)
    nonisolated static let bakeOrOvenModes = ["COMBI_BAKE", "CONV_BAKE", "COMBI_ROAST", "OVEN"]

    var ventSpeed = 0.0
    var lampLevel = 0.0
    var mwPower = 50.0
    var ovenCommandList = Command(tempUnits: "FAHRENHEIT")
    var wasCooking = false

    var serviceHood: Service!
    var serviceLight: Service!
    var microwavePower: Service!
    var offSwitch: Service!
    var lightVent: Service!

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        super.init(device: device, environment: environment)
        ovenCommandList = Command(tempUnits: reportedTempUnit() ?? "FAHRENHEIT")

        serviceHood = addService(.fanv2, name: "Microwave Fan", subtype: "YourUniqueIdentifier-59F", optional: [
            CharacteristicType.rotationSpeed.props(min: 0, max: Self.ventSpeedMax, step: 1),
        ])
        serviceHood.characteristic(.active).onGet { [weak self] in .int((self?.ventLevel() ?? 0) > 0 ? 1 : 0) }
            .onSet { [weak self] value in
                guard let self, let speed = Normalize.number(value) else { return }
                ventSpeed = speed
                if ventSpeed != ventLevel() { try await sendLightVentCommand() }
            }
        serviceHood.characteristic(.rotationSpeed).onGet { [weak self] in .double(self?.ventLevel() ?? 0) }
            .onSet { [weak self] value in
                guard let self, let speed = Normalize.number(value) else { return }
                ventSpeed = speed
                try await sendLightVentCommand()
            }

        serviceLight = addService(.lightbulb, name: "Microwave Light", subtype: "YourUniqueIdentifier-59L", optional: [
            CharacteristicType.brightness.props(min: 0, max: Self.lampLevelMax, step: 1),
        ])
        serviceLight.characteristic(.on).onGet { [weak self] in .bool((self?.lampLevelReported() ?? 0) > 0) }
            .onSet { [weak self] value in
                guard let self else { return }
                lampLevel = Normalize.boolean(value) ? Self.lampLevelMax : 0
                try await sendLightVentCommand()
            }
        serviceLight.characteristic(.brightness).onGet { [weak self] in .double(self?.lampLevelReported() ?? 0) }
            .onSet { [weak self] value in
                guard let self, let level = Normalize.number(value) else { return }
                lampLevel = level
                if lampLevel != lampLevelReported() { try await sendLightVentCommand() }
            }

        offSwitch = createSwitch("Turn Off Microwave", subtype: "CataNicoGaTa-Control8Off")
        offSwitch.set(.configuredName, "Turn Off the Microwave")
        offSwitch.characteristic(.on).onGet { .bool(false) }.onSet { [weak self] value in
            guard let self, Normalize.boolean(value) else { return }
            defer { resetMomentarySwitch(offSwitch) }
            try await turnOffVentAndLamp()
        }

        microwavePower = addService(.lightbulb, name: "Microwave Power", subtype: "YourUniqueIdentifier-59SP", optional: [
            CharacteristicType.brightness.props(min: 0, max: 100, step: Self.powerLevelToPercent),
        ])
        microwavePower.characteristic(.on).onGet { [weak self] in .bool((self?.powerPercent() ?? 0) > 0) }
            .onSet { [weak self] value in self?.mwPower = Normalize.boolean(value) ? 100 : 0 }
        microwavePower.characteristic(.brightness).onGet { [weak self] in .double(self?.powerPercent() ?? 0) }
            .onSet { [weak self] value in
                if let power = Normalize.number(value) { self?.mwPower = power }
            }

        createBoard(configuredName: "LG Microwave Oven", inputs: Self.inputMax)
        lightVent = addBoardInputs(mode: "Microwave Cooking Mode", temperature: "Microwave Oven Temperature", cooking: isCooking(),
            extra: "Light and Vent Status", extraShown: lightVentState(), extraFirst: true) { (microwave: Microwave) in microwave.lightVentStatus() }

        addValves(cookTime: "Microwave Cook Time", cookTimeMax: Self.cookTimeMax, timer: "Microwave Timer", timerMax: Self.timerMax, timerLimit: Self.timerMax,
            timerStep: 60)
        addModeSwitches(Self.modeSwitches)
        addStopSwitch("Stop Microwave")
        addStartSwitch("Start Microwave")
        addTemperatureControl("Microwave Oven Temperature Control", subtype: "NicoCataGaTa-OvenTC", current: Self.minCurrentC...Self.maxC, targetMax: Self.maxC)
    }

    // MARK: The pending cook

    override var selectedMode: String {
        get { ovenCommandList.ovenMode }
        set { ovenCommandList.ovenMode = newValue }
    }

    override func setCookDuration(_ seconds: Double) { ovenCommandList.ovenSetDuration = seconds }

    override func selectTargetTemperature(_ celsius: Double) {
        let deviceTemperature = Cooking.isFahrenheit(status["LWOTargetTemperatureUnit"]) ? Cooking.tempCtoF(celsius) : celsius
        ovenCommandList.ovenSetTemperature = (deviceTemperature / Self.targetIncrement).rounded(.toNearestOrAwayFromZero) * Self.targetIncrement
    }

    override func boardActive() -> Int { ovenServiceActive() }

    override func setBoardActive(_ on: Bool) async throws {
        if on {
            if ventLevel() == 0 || lampLevelReported() == 0 {
                lampLevel = Self.defaultVentLampLevel
                ventSpeed = Self.defaultVentLampLevel
                try await sendLightVentCommand()
            }
            return
        }
        if isCooking() {
            try await stopOven()
            try? await Task.sleep(for: Self.stopSettle)
        }
        try await turnOffVentAndLamp()
    }

    // MARK: Commands

    func turnOffVentAndLamp() async throws {
        if ventLevel() != 0 || lampLevelReported() != 0 {
            lampLevel = 0
            ventSpeed = 0
            try await sendLightVentCommand()
        }
    }

    func sendLightVentCommand() async throws {
        logger.debug("Fan Speed: \(JS.format(ventSpeed)) Light: \(JS.format(lampLevel))")
        try await sendOvenState("setVentLampLevel", [
            "cmdOptionContentsType": "REMOTE_VENT_LAMP", "cmdOptionDataLength": "REMOTE_VENT_LAMP",
            "mwoVentOnOff": .string(ventSpeed > 0 ? "ENABLE" : "DISABLE"), "mwoVentSpeedLevel": .number(ventSpeed),
            "mwoLampOnOff": .string(lampLevel > 0 ? "ENABLE" : "DISABLE"), "mwoLampLevel": .number(lampLevel),
        ])
    }

    /// The cook command from the pending selection, with each mode's defaults and limits.
    func prepareOvenCommand() -> Command {
        let unit = reportedTempUnit() ?? ovenCommandList.tempUnits
        var command = ovenCommandList
        command.tempUnits = unit
        command.microwavePower = JS.format(mwPower)
        if command.ovenMode == "NONE" { command.ovenMode = "WARM" }
        if command.ovenSetDuration == 0 { command.ovenSetDuration = Self.defaultCookSeconds }
        let mode = command.ovenMode
        if Self.bakeOrOvenModes.contains(where: { mode.contains($0) }) {
            command.ovenSetTemperature = Cooking.clampCookTemp(Cooking.microwaveLimits, mode: mode, unit: .string(unit), command.ovenSetTemperature)
            if mode.contains("COMBI_BAKE") { (command.subCookNumber, command.microwavePower, command.targetWeight, command.weightUnits) = (82, "10", 0, "KG") }
            if mode.contains("COMBI_ROAST") { (command.subCookNumber, command.microwavePower, command.targetWeight, command.weightUnits) = (82, "30", 0, "LBS") }
            if mode.contains("CONV_BAKE") || mode.contains("OVEN") { (command.subCookNumber, command.microwavePower, command.targetWeight, command.weightUnits) = (0, "100", 0, "LBS") }
        } else if mode.contains("DEHYDRATE") {
            command.ovenSetTemperature = Cooking.clampCookTemp(Cooking.microwaveLimits, mode: mode, unit: .string(unit), command.ovenSetTemperature)
            (command.subCookNumber, command.microwavePower, command.targetWeight, command.weightUnits) = (0, "100", 0, "LBS")
        } else if mode.contains("PROOF") {
            (command.subCookNumber, command.microwavePower, command.ovenSetTemperature, command.targetWeight, command.weightUnits) = (0, "100", 0, 0, "KG")
        } else if mode.contains("MICROWAVE") {
            (command.subCookNumber, command.microwavePower, command.ovenSetTemperature, command.targetWeight) = (0, mwPower == 0 ? "100" : JS.format(mwPower), 0, 0)
        } else if mode.contains("AIRFRY") {
            (command.ovenMode, command.subCookNumber, command.ovenSetDuration, command.microwavePower, command.ovenSetTemperature, command.targetWeight) =
                ("AUTO_COOK", 0, 0, "100", 0, 0)
        } else if mode.contains("INVERTER_DEFROST") {
            (command.subCookNumber, command.ovenSetDuration, command.microwavePower, command.ovenSetTemperature, command.targetWeight) = (211, 0, "NONE", 0, 300)
        } else if mode.contains("TIME_DEFROST") {
            (command.subCookNumber, command.microwavePower, command.ovenSetTemperature, command.targetWeight, command.weightUnits) = (0, "100", 0, 0, "KG")
        } else if mode.contains("WARM") {
            var warm = Command(tempUnits: unit)
            warm.ovenMode = "WARM"
            return warm
        }
        return command
    }

    override func sendOvenCommand() async throws {
        try await commandGate.run {
            pauser.pause(Self.userEditPause)
            defer { pauser.pause(Self.commandSettle) }
            let command = prepareOvenCommand()
            ovenCommandList = command
            logger.debug("Sending the following commands to the Microwave: \(command)")
            let duration = command.ovenSetDuration
            // Dehydrate and Proof take hours and minutes; the other modes minutes only.
            let splitHours = command.ovenMode.contains("DEHYDRATE") || command.ovenMode.contains("PROOF")
            try await sendOvenState("SetCookStart", [
                "cmdOptionContentsType": "REMOTE_COOK_START", "cmdOptionDataLength": "REMOTE_COOK_START",
                "cmdOptionSetCookName": .string(command.ovenMode), "cmdOptionSetReserved": 0, "cmdOptionSetSubCookNumber": .number(command.subCookNumber),
                "cmdOptionSetTargetTemperatureUnit": .string(command.tempUnits),
                "cmdOptionSetTargetTimeHour": .number(splitHours ? (duration / 3600).rounded(.down) : 0),
                "cmdOptionSetTargetTimeMinute": .number(splitHours ? (duration.truncatingRemainder(dividingBy: 3600) / 60).rounded(.down) : (duration / 60).rounded(.down)),
                "cmdOptionSetTargetTimeSecond": .number(duration.truncatingRemainder(dividingBy: 60).rounded(.down)),
                "cmdOptionSetWeightUnit": .string(command.weightUnits), "cmdOptionStep": 0, "setMwoPowerLevel": .string(command.microwavePower),
                "setTargetSteamLevel": "NONE", "setTargetTemp": .number(command.ovenSetTemperature),
                "setTargetTempLevel": command.ovenMode == "WARM" ? "HIGH" : 0, "setTargetWeight": .number(command.targetWeight), "setWarmType": "NONE",
            ])
            clearUserSelection()
        }
    }

    // MARK: State

    func reportedTempUnit() -> String? { status["LWOTargetTemperatureUnit"]?.stringValue }
    func ventLevel() -> Double { Cooking.toNumber(status["mwoVentSpeedLevel"]) }
    func lampLevelReported() -> Double { Cooking.toNumber(status["mwoLampLevel"]) }
    /// The power as a percentage (the microwave reports 1 to 10).
    func powerPercent() -> Double { JS.parseInt(status["LWOMGTPowerLevel"]) * Self.powerLevelToPercent }
    /// Cooking: the state known and not INITIAL.
    func isCooking() -> Bool { Cooking.excludes(status["LWOState"], "INITIAL") }
    func onStatus() -> Bool { isCooking() }
    func lightVentState() -> Bool { isCooking() || ventLevel() != 0 || lampLevelReported() != 0 }
    func ovenServiceActive() -> Int { lightVentState() ? 1 : 0 }

    func subCookProgram() -> (label: String, defaultTempF: Double)? {
        guard let code = status["LWOSubCookName"], code != .null, code != .number(0) else { return nil }
        return Int(saturating: Cooking.toNumber(code)).flatMap { Self.subCookPrograms[$0] } ?? Self.otherSubCook
    }

    /// A sub-cook program's default temperature (°F) while cooking.
    func defaultTemp() -> Double {
        guard isCooking(), status["LWOManualCookName"]?.stringValue != "STANDBY" else { return 0 }
        return subCookProgram()?.defaultTempF ?? 0
    }

    override func ovenModeName() -> String {
        let cookName = status["LWOManualCookName"]?.stringValue
        let label = cookName.map { Self.modeLabels[$0] ?? Cooking.capitalize(.string($0)) } ?? "Unknown"
        var name = "Microwave Mode: \(label)"
        if cookName != "STANDBY", let program = subCookProgram() { name += " (\(program.label))" }
        return Cooking.truncateName(name)
    }

    override func ovenStatus() -> String {
        let state = status["LWOState"]?.stringValue
        let label = state.map { Self.stateLabels[$0] ?? Cooking.capitalize(.string($0)) } ?? "Unknown"
        return Cooking.truncateName("Microwave is \(label)")
    }

    override func ovenTemperature() -> String {
        let current = Cooking.nonZero(status["upperCurrentTemperatureValue"])
        let target = Cooking.nonZero(status["LWOTargetTemperatureValue"])
        let defaultTemperature = defaultTemp()
        var text = "Microwave Oven Temperature Information"
        if let current { text = "Current Temp is \(JS.format(current))°" }
        if let target {
            text += " With Set Temp \(JS.format(target))°"
        } else if defaultTemperature != 0, current == nil {
            text = "Current Temp is \(JS.format(defaultTemperature))° With Set Temp \(JS.format(defaultTemperature))°"
        }
        return Cooking.truncateName(text)
    }

    /// A sub-cook program's default temperature while cooking or preheating.
    func defaultTempC() -> Double? {
        let state = status["LWOState"]
        let defaultTemperature = defaultTemp()
        guard defaultTemperature != 0, Cooking.includes(state, "COOKING_IN_PROGRESS") || Cooking.includes(state, "PREHEATING") else { return nil }
        return Cooking.tempFtoC(defaultTemperature)
    }

    override func ovenCurrentTemperature() -> Double {
        let unit = status["LWOTargetTemperatureUnit"]
        var celsius: Double?
        if let current = Cooking.nonZero(status["upperCurrentTemperatureValue"]) {
            celsius = Cooking.toCelsius(current, unit)
        } else if let target = Cooking.nonZero(status["LWOTargetTemperatureValue"]) {
            celsius = Cooking.toCelsius(target, unit)
        } else {
            celsius = defaultTempC()
        }
        return min(Self.maxC, max(Self.minCurrentC, celsius ?? Self.ambientC))
    }

    override func ovenTargetTemperature() -> Double {
        if let userTargetTemperature { return min(Self.maxC, max(Self.minTargetC, userTargetTemperature)) }
        let celsius = Cooking.nonZero(status["LWOTargetTemperatureValue"]).map { Cooking.toCelsius($0, status["LWOTargetTemperatureUnit"]) } ?? defaultTempC()
        return min(Self.maxC, max(Self.minTargetC, celsius ?? Self.minTargetC))
    }

    override func ovenOptionsName() -> String {
        var options = "Settings: " + (Cooking.isFahrenheit(status["LWOTargetTemperatureUnit"]) ? "Temp in °F" : "Temp in °C")
        if Cooking.excludes(status["LWOSabbath"], "NOT") { options += ", Sabbath On" }
        if Cooking.includes(status["LWOControlLock"], "ENA") { options += ", Control Lock" }
        return Cooking.truncateName(options)
    }

    override func currentHeatingState() -> Int {
        Cooking.nonZero(status["upperCurrentTemperatureValue"]) != nil || defaultTemp() != 0 || Cooking.nonZero(status["LWOTargetTemperatureValue"]) != nil ? 1 : 0
    }

    override func targetHeatingState() -> Int {
        Cooking.nonZero(status["LWOTargetTemperatureValue"]) != nil || defaultTemp() != 0 ? 1 : 0
    }

    func lightVentStatus() -> String {
        let lamp = lampLevelReported()
        let vent = ventLevel()
        let lampText = lamp == 0 ? "Light is Off" : lamp == 1 ? "Light is set to Low" : "Light is set to High"
        return lampText + (vent > 0 ? " and Vent is set to Level \(JS.format(vent))" : " and Vent is Off")
    }

    // MARK: Updates

    func syncCommandList(cooking: Bool, active: Int) {
        if cooking, !wasCooking { clearUserSelection() }
        wasCooking = cooking
        if !userSelectionPending {
            if active == 0 { ovenCommandList = Command(tempUnits: reportedTempUnit() ?? ovenCommandList.tempUnits) }
            if let cookName = status["LWOManualCookName"]?.stringValue, !cookName.contains("STAND") { ovenCommandList.ovenMode = cookName }
        }
        syncModeSwitches()
    }

    override func refreshCharacteristics() {
        guard ovenService != nil else { return }
        let data = status
        let cooking = isCooking()
        let active = ovenServiceActive()
        let targetTime = ovenTargetTime()
        let timerTime = ovenTimerTime()
        let remaining = remainTime()

        ovenService.set(.active, active)
        syncCommandList(cooking: cooking, active: active)
        cookTimes.update(cooking: Cooking.excludes(data["LWOManualCookName"], "STAND"), targetSeconds: targetTime, timerSeconds: timerTime)

        refreshBoard(cooking: cooking, targetTime: targetTime, timerTime: timerTime, remaining: remaining)
        lightVent.set(.configuredName, lightVentStatus())
        setVisibility(lightVent, lightVentState())

        ovenTempControl.set(.temperatureDisplayUnits, Cooking.isFahrenheit(data["LWOTargetTemperatureUnit"]) ? 1 : 0)
        ovenTempControl.set(.currentTemperature, ovenCurrentTemperature())
        ovenTempControl.set(.targetTemperature, ovenTargetTemperature())
        ovenTempControl.set(.targetHeatingCoolingState, targetHeatingState())
        ovenTempControl.set(.currentHeatingCoolingState, currentHeatingState())
        ovenTempControl.set(.currentRelativeHumidity, Self.ambientHumidity)

        let power = powerPercent()
        microwavePower.set(.on, power > 0)
        microwavePower.set(.brightness, power)
        let lamp = lampLevelReported()
        serviceLight.set(.on, lamp > 0)
        serviceLight.set(.brightness, lamp)
        let vent = ventLevel()
        serviceHood.set(.active, vent > 0 ? 1 : 0)
        serviceHood.set(.rotationSpeed, vent)
    }
}
