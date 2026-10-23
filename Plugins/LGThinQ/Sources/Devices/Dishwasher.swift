import Foundation
import Homeswift
import HomeswiftPlugin

/// A dishwasher's `dishwasher` state.
struct DishwasherStatus {
    let data: [String: JSONValue]
    let deviceModel: DeviceModel

    var state: String { data["state"]?.stringValue ?? "" }
    var isPowerOn: Bool { !["POWEROFF", "POWERFAIL"].contains(state) }
    var isRunning: Bool {
        guard isPowerOn, let running = deviceModel.lookupMonitorName("state", "@DW_STATE_RUNNING_W") else { return false }
        return data["state"]?.stringValue == running
    }
    var isDoorClosed: Bool {
        guard let closed = deviceModel.lookupMonitorName("door", "@CP_OFF_EN_W") else { return false }
        return data["door"]?.stringValue == closed
    }
    var remainDuration: Double {
        isRunning ? JS.parseInt(data["remainTimeHour"]) * 3600 + JS.parseInt(data["remainTimeMinute"]) * 60 : 0
    }
}

/// A dishwasher, published on its own: a Television whose inputs read out the cycle (status, options, start,
/// duration and end, rinse aid, cleanliness), a Valve with the remaining time, the door as a contact sensor
/// whose battery is the rinse aid, and an optional Program Finished sensor. Not controllable.
final class Dishwasher: BaseDevice {
    nonisolated static let inputStatus = 1, inputOptions = 2, inputStartTime = 3, inputDuration = 4, inputEndTime = 5, inputRinse = 6, inputCleanliness = 7
    nonisolated static let defaultStart = "Cycle Start Time Not Set"
    nonisolated static let defaultDuration = "Cycle Duration Not Set"
    nonisolated static let defaultEnd = "Cycle End Time Not Set"
    nonisolated static let sixHours = 21_600.0
    nonisolated static let standbyInterval: Duration = .milliseconds(902_500)
    nonisolated static let standbyLimit = 360.0
    nonisolated static let dryCycleThreshold = 3
    nonisolated static let tclThreshold = 30.0

    nonisolated static let courseNames: [(String, String)] = [
        ("AUTO", "Running a Auto Cycle"), ("HEAVY", "Running a Heavy Cycle"), ("DELICATE", "Running a Delicate Cycle"),
        ("TURBO", "Running a Turbo Cycle"), ("NORMAL", "Running a Normal Cycle"), ("RINSE", "Running a Rinse Cycle"),
        ("REFRESH", "Running a Refresh Cycle"), ("EXPRESS", "Running a Express Cycle"), ("CLEAN", "Cleaning the Dishwasher"),
        ("SHORT", "Running a Short Cycle"),
    ]
    nonisolated static let lateCourseNames: [(String, String)] = [
        ("QUICK", "Running a Quick Cycle"), ("STREAM", "Running a Stream Cycle"), ("SPRAY", "Running a Spray Cycle"), ("ECO", "Running an Eco Cycle"),
    ]
    nonisolated static let stateNames: [(String, String)] = [
        ("FAIL", "Failure Detected"), ("RESERVED", "Is Reserved"), ("RINSING", "Rinsing"), ("DRYING", "Drying"), ("NIGHT", "Night Drying"),
        ("CANCEL", "Cancelled Cleaning"), ("ERROR", "Cleaning Error"),
    ]
    nonisolated static let optionNames: [(String, String)] = [
        ("energySaver", "Energy Saver"), ("halfLoad", "Half Load"), ("dualZone", "Dual Zone"), ("highTemp", "High Temp"), ("steam", "Steam"),
        ("extraRinse", "Extra Rinse"), ("extraDry", "Extra Dry"), ("nightDry", "Night Dry"), ("delayStart", "Delay Start"),
    ]

    var isRunning = false
    var rinseLevel = "LEVEL_2"
    var inputName = "Dishwasher Status"
    var inputNameOptions = "Dishwasher Options"
    var inputNameRinse = "Dishwasher Rinse Aid Level"
    var inputNameMachine = "Dishwasher Cleanness Status"
    var courseStartString = defaultStart
    var courseTimeString = defaultDuration
    var courseTimeEndString = defaultEnd
    var showTime = false
    var firstTime = true
    var firstEnd = true
    var settingDuration = 0.0
    var dryCounter = 0
    var delayTime = 0.0
    var firstDelay = true
    var firstStandby = true
    /// When the dishwasher entered standby (seconds since 1970), 0 when it is not in standby.
    var standbyTime = 0.0
    var finishedTime = "Today"
    private var lastReportedState: JSONValue?
    private let standbyTimer = Timeout()
    private let finishedTimer = Timeout()

    var tvService: Service!
    var dishwasherState: Service!
    var dishwasherOptions: Service!
    var startTime: Service!
    var courseDuration: Service!
    var endTime: Service!
    var dishwasherRinseLevel: Service!
    var dishwasherCleanliness: Service!
    var serviceDishwasher: Service!
    var serviceDoorOpened: Service!
    var serviceEventFinished: Service?

    required init(device: ThinQDevice, environment: DeviceEnvironment) {
        super.init(device: device, environment: environment)
        let tv = createTelevision(name: config.name ?? device.name, subtype: "CataNicoGaTa-70", configuredName: "LG Dishwasher", inputs: Self.inputCleanliness,
            identifierLabel: "Dishwasher ActiveIdentifier")
        tv.characteristic(.active).onSet { [weak self] _ in self?.setActive() }.onGet { [weak self] in .int(self?.onStatus() == true ? 1 : 0) }
        tv.set(.active, 0)
        tvService = tv

        let on = onStatus()
        func input(_ name: String, _ subtype: String, _ identifier: Int, _ shown: Bool, _ getName: @escaping @ThinQActor @Sendable (Dishwasher) -> String) -> Service {
            createInputSource(tv, name: name, subtype: subtype, identifier: identifier, shown: shown) { [weak self] in self.map(getName) ?? name }
        }
        dishwasherState = input("Dishwasher Status", "CataNicoGaTa-10030", Self.inputStatus, true) { $0.inputName }
        dishwasherOptions = input("Dishwasher Options", "CataNicoGaTa-10040", Self.inputOptions, on) { $0.inputNameOptions }
        startTime = input("Cycle Start Time", "CataNico-Always10", Self.inputStartTime, showTime) { $0.courseStartString }
        courseDuration = input("Cycle Duration", "CataNico-Always20", Self.inputDuration, showTime) { $0.courseTimeString }
        endTime = input("Cycle End Time", "CataNico-Always30", Self.inputEndTime, showTime) { $0.courseTimeEndString }
        dishwasherRinseLevel = input("Dishwasher Rinse Aid Level", "CataNicoGaTa-10050", Self.inputRinse, on) { $0.inputNameRinse }
        dishwasherCleanliness = input("Dishwasher Cleanness Status", "CataNicoGaTa-10060", Self.inputCleanliness, on) { $0.inputNameMachine }

        let valve = append(Service(.valve, name: "LG Dishwasher", subtype: nil, optional: [
            .statusFault, CharacteristicType.remainingDuration.props(max: Self.sixHours), CharacteristicType.setDuration.props(max: Self.sixHours),
        ], extra: [Characteristic(.configuredName, value: .string(device.name))], isPrimary: true))
        valve.set(.name, device.name)
        valve.set(.valveType, 1)
        valve.characteristic(.active).onSet { [weak self] _ in self?.setActive() }.onGet { [weak self] in .int(self?.timerStatus() ?? 0) }
        valve.set(.active, 0)
        valve.set(.inUse, 0)
        valve.characteristic(.statusFault).onGet { [weak self] in .int(self?.rinseLevelFault() ?? 0) }
        valve.characteristic(.setDuration).onGet { [weak self] in .double(self?.settingDuration ?? 0) }
        serviceDishwasher = valve

        let door = append(Service(.contactSensor, name: "Dishwasher Door", subtype: nil, optional: [.statusActive, .batteryLevel, .statusLowBattery],
            extra: [Characteristic(.configuredName, value: "Dishwasher Door")]))
        door.characteristic(.statusActive).onGet { [weak self] in .bool(self?.onStatus() ?? false) }
        door.characteristic(.batteryLevel).onGet { [weak self] in .int(self?.rinseLevelPercent() ?? 100) }
        door.characteristic(.statusLowBattery).onGet { [weak self] in .int(self?.rinseLevelFault() ?? 0) }
        serviceDoorOpened = door

        if config.flag("dishwasher_trigger") {
            let finished = append(Service(.occupancySensor, name: "\(device.name) - Program Finished", subtype: nil))
            finished.set(.occupancyDetected, 0)
            serviceEventFinished = finished
        }
    }

    override func destroy() {
        standbyTimer.cancel()
        finishedTimer.cancel()
        super.destroy()
    }

    var status: DishwasherStatus { DishwasherStatus(data: statusData("dishwasher"), deviceModel: device.deviceModel) }

    /// `Running a Heavy Cycle`.
    func runningCourseName() -> String {
        let data = status.data
        let course = data["course"]
        if let match = Self.courseNames.first(where: { Cooking.includes(course, $0.0) }) { return match.1 }
        if Cooking.includes(course, "DOWNLOAD") { return "Running a \(Cooking.capitalize(data["currentDownloadCourse"])) Cycle" }
        if let match = Self.lateCourseNames.first(where: { Cooking.includes(course, $0.0) }) { return match.1 }
        return "Running a \(Cooking.capitalize(course)) Cycle"
    }

    /// The status and options lines.
    func currentInputName() {
        let data = status.data
        let state = data["state"]
        let process = data["process"]
        if !Cooking.includes(process, "RESERVED") { firstDelay = true }
        if !Cooking.includes(state, "STAND") {
            standbyTime = 0
            firstStandby = true
        }
        if firstDelay {
            if Cooking.includes(state, "OFF") {
                inputName = "Power Off"
                firstEnd = true
                resetTimeSettings()
                settingDuration = 0
                dryCounter = 0
            } else if Cooking.includes(state, "STAND") {
                firstEnd = true
                resetTimeSettings()
                dryCounter = 0
                if !onStatus() {
                    inputName = "Power Off"
                } else {
                    inputName = "In Standby"
                    if !Cooking.includes(data["door"], "OPEN") { inputName += " (Door Closed)" }
                }
                if firstStandby {
                    standbyTime = Date().timeIntervalSince1970
                    firstStandby = false
                    scheduleStandbyRefresh()
                }
            } else if Cooking.includes(state, "INITIAL") {
                inputName = "Initializing"
                resetTimeSettings()
            } else if Cooking.includes(state, "RUNNING") {
                inputName = runningCourseName()
            } else if Cooking.includes(state, "PAUSE") {
                inputName = "Paused Cleaning"
                firstTime = true
                firstDelay = true
            } else if Cooking.includes(state, "END") {
                if firstEnd {
                    finishedTime = Cooking.formatDateTime(Date(), short: true)
                    firstEnd = false
                    resetTimeSettings()
                }
                inputName = "Finished Cycle \(finishedTime)"
                if Cooking.includes(data["extraDry"], "ON"), dryCounter > Self.dryCycleThreshold, status.remainDuration == Cooking.oneHour {
                    inputName += " (Waiting For Extra Dry Step)"
                }
            } else {
                inputName = Self.stateNames.first { Cooking.includes(state, $0.0) }?.1 ?? "Dishwasher \(Cooking.capitalize(state))"
            }
            if Cooking.includes(data["door"], "OPEN") {
                inputName += " (Door Open)"
                resetTimeSettings()
            }
            if JS.strictEquals(state, process), Cooking.includes(process, "RUNNING") { inputName += ". Step: Cleaning" }
            if !JS.strictEquals(state, process), let processName = process?.stringValue, !processName.contains("NONE"), !Cooking.includes(state, "END") {
                inputName += processStepName()
            }
        }
        let options = Self.optionNames.filter { Cooking.includes(data[$0.0], "ON") }.map(\.1)
        inputNameOptions = "Options: " + (options.isEmpty ? "None" : options.joined(separator: ", "))
        inputName = Cooking.truncateName(inputName)
        inputNameOptions = Cooking.truncateName(inputNameOptions)
        if !status.isPowerOn { inputNameOptions = "Dishwasher Options" }
        dishwasherState.set(.configuredName, inputName)
        dishwasherOptions.set(.configuredName, inputNameOptions)
        setVisibility(dishwasherOptions, onStatus())
    }

    /// `. Step: Drying`.
    func processStepName() -> String {
        let data = status.data
        let process = data["process"]
        if Cooking.includes(process, "RINSING") { return ". Step: Rinsing" }
        if Cooking.includes(process, "DRYING") {
            return ". Step: Drying" + (Cooking.includes(data["extraDry"], "ON") && dryCounter > Self.dryCycleThreshold ? " (Extra)" : "")
        }
        if Cooking.includes(process, "NIGHT") { return ". Step: Night Drying" }
        if Cooking.includes(process, "END") { return ". Step: Ending" }
        if Cooking.includes(process, "CANCEL") { return ". Step: Cancelling" }
        if Cooking.includes(process, "RESERVED"), data["delayStart"]?.stringValue == "ON" {
            delayTime = Cooking.sumTimeFields(data["reserveTimeHour"], data["reserveTimeMinute"])
            timeDurationEnd()
            firstDelay = false
            return ". Step: Waiting \(Cooking.formatDuration(delayTime)) to Start"
        }
        let state = data["state"]
        if !Cooking.includes(state, "INITIAL"), !Cooking.includes(state, "STAND"), !Cooking.includes(process, "RESERVED") {
            return ". Step: \(Cooking.capitalize(state))"
        }
        return ""
    }

    /// Re-evaluates Active once the standby window has passed.
    func scheduleStandbyRefresh() {
        standbyTimer.schedule(after: Self.standbyInterval) { [weak self] in
            guard let self else { return }
            serviceDishwasher.set(.active, timerStatus())
            tvService.set(.active, onStatus() ? 1 : 0)
            serviceDoorOpened.set(.statusActive, onStatus())
        }
    }

    func timeDurationEnd() {
        let remaining = status.remainDuration
        showTime = true
        courseTimeString = "Duration: " + Cooking.formatDuration(remaining)
        if Cooking.includes(status.data["extraDry"], "ON") { courseTimeString += " + 1:00:00 Hour For Extra Dry" }
        let start = Date().addingTimeInterval(delayTime)
        courseStartString = Cooking.truncateName("Start: " + Cooking.formatDateTime(start))
        courseTimeString = Cooking.truncateName(courseTimeString)
        courseTimeEndString = Cooking.truncateName("End: " + Cooking.formatDateTime(start.addingTimeInterval(remaining)))
        pushTimeInputs()
    }

    func pushTimeInputs() {
        startTime.set(.configuredName, courseStartString)
        courseDuration.set(.configuredName, courseTimeString)
        endTime.set(.configuredName, courseTimeEndString)
        setVisibility(startTime, showTime)
        setVisibility(courseDuration, showTime)
        setVisibility(endTime, showTime)
    }

    /// Not controllable from HomeKit.
    func setActive() {
        logger.debug("Dishwasher Response \(JSONValue.object(status.data).text())")
    }

    override func updateAccessoryCharacteristic(_ device: ThinQDevice) {
        super.updateAccessoryCharacteristic(device)
        let status = status
        let data = status.data
        let remaining = status.remainDuration
        if serviceDishwasher.value(.remainingDuration)?.doubleValue != remaining {
            if Cooking.includes(data["extraDry"], "ON"), remaining == Cooking.oneHour { dryCounter += 1 }
            if dryCounter <= Self.dryCycleThreshold { serviceDishwasher.set(.remainingDuration, remaining) }
        }
        if status.isPowerOn { settingDuration = Cooking.sumTimeFields(data["initialTimeHour"], data["initialTimeMinute"]) }
        serviceDishwasher.set(.setDuration, settingDuration)
        serviceDishwasher.set(.active, timerStatus())
        tvService.set(.active, onStatus() ? 1 : 0)
        if (data["delayStart"]?.stringValue == "ON" && Cooking.includes(data["process"], "RESER")) || Cooking.includes(data["state"], "STAND") {
            serviceDishwasher.set(.inUse, 0)
        } else {
            serviceDishwasher.set(.inUse, status.isRunning ? 1 : 0)
        }
        serviceDoorOpened.set(.contactSensorState, status.isDoorClosed ? 0 : 1)
        currentInputName()
        if Cooking.includes(data["state"], "RUNNING"), !Cooking.includes(data["process"], "RESERVED"), firstTime {
            delayTime = 0
            timeDurationEnd()
            firstTime = false
        }
        updateRinseLevel()
    }

    /// The level reported while running, the last known one otherwise.
    func effectiveRinseLevel() -> String {
        let data = status.data
        if Cooking.includes(data["state"], "RUNNING") {
            if let level = data["rinseLevel"]?.stringValue, !level.isEmpty { return level }
            return "LEVEL_1"
        }
        return rinseLevel
    }

    func updateRinseLevel() {
        rinseLevel = effectiveRinseLevel()
        var input = activeInput
        var percent = 100
        var fault = 0
        switch rinseLevel {
        case "LEVEL_0":
            percent = 0
            fault = 1
            inputNameRinse = "Rinse Aid Level is Running Low"
            input = Self.inputRinse
        case "LEVEL_1":
            percent = 50
            inputNameRinse = "Rinse Aid Level is at 50% Capacity"
        case "LEVEL_2":
            inputNameRinse = "Rinse Aid Level is at 100% Capacity"
        default:
            inputNameRinse = "Rinse Aid Level is Normal"
        }
        let on = onStatus()
        serviceDishwasher.set(.statusFault, fault)
        serviceDoorOpened.set(.statusActive, on)
        serviceDoorOpened.set(.batteryLevel, percent)
        serviceDoorOpened.set(.statusLowBattery, fault)
        let needsCleaning = JS.number(status.data["tclCount"]) > Self.tclThreshold
        if needsCleaning {
            input = Self.inputCleanliness
            inputNameMachine = "Machine Cleaning Cycle is Needed Soon"
        } else {
            inputNameMachine = "Dishwasher is Clean"
        }
        dishwasherCleanliness.set(.configuredName, inputNameMachine)
        setVisibility(dishwasherCleanliness, needsCleaning && on)
        dishwasherRinseLevel.set(.configuredName, inputNameRinse)
        setVisibility(dishwasherRinseLevel, on)
        if input != activeInput {
            activeInput = input
            tvService.set(.activeIdentifier, input)
        }
    }

    /// Off after six minutes in standby.
    func onStatus() -> Bool {
        if standbyTime != 0, Date().timeIntervalSince1970 - standbyTime > Self.standbyLimit { return false }
        return status.isPowerOn
    }

    func timerStatus() -> Int {
        !onStatus() || status.remainDuration == 0 || Cooking.includes(status.data["state"], "STAND") ? 0 : 1
    }

    func rinseLevelFault() -> Int { effectiveRinseLevel() == "LEVEL_0" ? 1 : 0 }

    func rinseLevelPercent() -> Int {
        switch effectiveRinseLevel() {
        case "LEVEL_0": 0
        case "LEVEL_1": 50
        default: 100
        }
    }

    func resetTimeSettings() {
        showTime = false
        firstTime = true
        firstDelay = true
        courseStartString = Self.defaultStart
        courseTimeString = Self.defaultDuration
        courseTimeEndString = Self.defaultEnd
        if let startTime, let courseDuration, let endTime {
            setVisibility(startTime, false)
            setVisibility(courseDuration, false)
            setVisibility(endTime, false)
        }
    }

    override func update(_ snapshot: [String: JSONValue]) {
        super.update(snapshot)
        guard let dishwasher = snapshot["dishwasher"]?.objectValue, let state = dishwasher["state"] else { return }
        let previous = lastReportedState
        lastReportedState = state
        guard config.flag("dishwasher_trigger"), let sensor = serviceEventFinished else { return }
        // Done: on the transition into END, or running to not running.
        if Cooking.enteredState(previous, state, "END") || (isRunning && !status.isRunning) {
            sensor.set(.occupancyDetected, 1)
            isRunning = false
            finishedTimer.schedule(after: WasherDryer.finishedSensorDuration) { [weak sensor] in sensor?.set(.occupancyDetected, 0) }
        }
        if status.isRunning, !isRunning {
            sensor.set(.occupancyDetected, 0)
            isRunning = true
        }
    }
}
