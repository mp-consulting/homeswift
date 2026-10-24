import Foundation
import Homeswift
import HomeswiftPlugin

/// Liveviews as scenes (`ProtectLiveviews`, docs/liveviews.md of the Homebridge plugin): liveviews named
/// `Protect-Away`, `Protect-Home`, `Protect-Night` and `Protect-Off` make a security system whose modes turn
/// motion detection on for the cameras of that liveview and off for the others; any other `Protect-<Name>`
/// liveview becomes a switch that turns motion detection on or off for its cameras.
@ProtectActor
final class ProtectLiveviews: ProtectBase {
    private var configured: Set<String> = []
    private var isMqttConfigured = false
    private(set) var liveviews: [ProtectLiveview] = []
    private(set) var securitySystem: ProtectSecuritySystem?
    private var switches: [String: (accessory: ProtectAccessory, name: String)] = [:]

    nonisolated static func isSecuritySystemLiveview(_ name: String) -> Bool {
        name.range(of: "^Protect-(Away|Home|Night|Off)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The switch name of a `Protect-<Name>` liveview that is not one of the security system's.
    nonisolated static func switchName(_ liveview: String) -> String? {
        guard liveview.range(of: "^Protect-.+$", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let name = String(liveview.dropFirst("Protect-".count))
        return ["AWAY", "OFF", "HOME", "NIGHT"].contains(name.uppercased()) ? nil : name
    }

    func configureLiveviews() async {
        guard let bootstrap = await api.bootstrap, bootstrap.at("nvr") != nil else { return }
        liveviews = bootstrap.array("liveviews").map(ProtectLiveview.init)
        await configureSecuritySystem(bootstrap: bootstrap)
        await configureSwitches(bootstrap: bootstrap)
        configureMqtt()
    }

    private var securityID: String { ProtectPlatform.accessoryID(nvr.mac + ".Security") }

    private func configureSecuritySystem(bootstrap: JSONValue) async {
        guard liveviews.contains(where: { Self.isSecuritySystemLiveview($0.name) }) else {
            if securitySystem != nil || platform.host.accessoryIDs.contains(securityID) {
                log.info("No plugin-specific liveviews found. Disabling the security system accessory associated with this UniFi Protect controller.")
                await securitySystem?.accessory.unpublish()
                if securitySystem == nil, platform.host.accessoryIDs.contains(securityID) { try? await platform.host.remove(id: securityID) }
                platform.contexts.remove(securityID)
            }
            securitySystem = nil
            return
        }
        if securitySystem == nil {
            let nvrJSON = bootstrap.at("nvr") ?? .object([:])
            let name = platform.host.cachedName(id: securityID) ?? nvrJSON.string("name") ?? nvrJSON.string("marketName") ?? "UniFi Protect"
            let accessory = ProtectAccessory(id: securityID, name: name, category: .securitySystem, host: platform.host, log: nvr.log)
            log.info("Plugin-specific liveviews have been detected. Enabling the security system accessory.")
            securitySystem = ProtectSecuritySystem(nvr: nvr, accessory: accessory)
        }
        platform.contexts[securityID].nvr = nvr.mac
        await securitySystem?.accessory.publish()
    }

    private func configureSwitches(bootstrap: JSONValue) async {
        let prefix = ProtectPlatform.accessoryID(nvr.mac + ".Liveview.")
        for id in platform.host.accessoryIDs where id.hasPrefix(prefix) || platform.contexts[id].liveview != nil && platform.contexts[id].nvr == nvr.mac {
            let liveview = platform.contexts[id].liveview ?? String(id.dropFirst(prefix.count))
            guard !liveviews.contains(where: { $0.name.uppercased() == ("Protect-" + liveview).uppercased() }) else { continue }
            log.info("Removing plugin-specific liveview switch: \(liveview). The liveview has been either removed or renamed in UniFi Protect.")
            configured.remove(liveview.uppercased())
            switches[id] = nil
            try? await platform.host.remove(id: id)
            platform.contexts.remove(id)
        }
        var seen: Set<String> = []
        for liveview in liveviews.map(\.name) where seen.insert(liveview).inserted {
            guard let viewName = Self.switchName(liveview), !configured.contains(viewName.uppercased()) else { continue }
            let id = prefix + viewName.uppercased()
            let nvrName = bootstrap.string("nvr.name") ?? ""
            let accessory = ProtectAccessory(id: id, name: platform.host.cachedName(id: id) ?? nvrName + " " + viewName, category: .switch, host: platform.host, log: nvr.log)
            accessory.setInformation(manufacturer: "Ubiquiti Inc.", model: "UniFi Protect Liveview Switch", serialNumber: nvr.mac + ".Liveview." + viewName.uppercased())
            let saved = platform.contexts[id]
            let state = saved.liveview != nil ? (saved.liveviewState ?? false) : true
            platform.contexts[id] = ProtectAccessoryContext(liveview: viewName, liveviewState: state, nvr: nvr.mac)
            let service = accessory.acquire(.switch, name: accessory.name)
            service[.on]?.onRead { [weak self] in .bool(await self?.switchState(viewName) ?? false) }
            service[.on]?.onWrite { @ProtectActor [weak self] value in self?.setSwitchState(id: id, viewName: viewName, value.boolValue ?? false) }
            service[.on]?.value = .bool(state)
            switches[id] = (accessory, viewName)
            setSwitchState(id: id, viewName: viewName, state)
            configured.insert(viewName.uppercased())
            await accessory.publish()
            log.info("Configuring plugin-specific liveview switch: \(viewName).")
        }
    }

    private func configureMqtt() {
        guard !isMqttConfigured else { return }
        isMqttConfigured = true
        nvr.mqtt?.subscribeGet(nvr.mac, "liveviews", type: "liveview scenes", log: log) { [weak self] in
            await self?.liveviewStates() ?? "[]"
        }
        nvr.mqtt?.subscribeSet(nvr.mac, "liveviews", type: "liveview scenes", log: log) { [weak self] _, raw in
            await self?.handleMQTT(raw)
        }
    }

    private func liveviewStates() -> String {
        let entries: [JSONValue] = switches.values.sorted { $0.name < $1.name }.map { entry in
            ["name": .string(entry.name), "state": entry.accessory.firstService(.switch)?[.on]?.value.boolValue.map(JSONValue.bool) ?? .null]
        }
        return JSONValue.array(entries).text()
    }

    private func handleMQTT(_ raw: String) {
        guard let payload = try? JSONValue(string: raw), let entries = payload.arrayValue else {
            log.error("Unable to process MQTT message: \"\(raw)\". Invalid JSON.")
            return
        }
        guard !entries.isEmpty else {
            log.error("Unable to process MQTT message: \"\(raw)\".")
            return
        }
        for entry in entries {
            guard let name = entry.string("name"), let (id, match) = switches.first(where: { $0.value.name.uppercased() == name.uppercased() }) else { continue }
            // As a HomeKit write does (the Homebridge plugin's `setValue`): the cameras follow, not only the switch.
            let state = entry.at("state")?.boolValue == true
            match.accessory.firstService(.switch)?[.on]?.value = .bool(state)
            setSwitchState(id: id, viewName: match.name, state)
            log.info("Liveview scene updated via MQTT: \(match.name).")
        }
    }

    /// Turns motion detection on or off for the cameras of a liveview.
    func setSwitchState(id: String, viewName: String, _ target: Bool) {
        guard switchState(viewName) != target else { return }
        let cameras = liveviewCameras(viewName)
        guard !cameras.isEmpty else { return }
        for cameraID in cameras {
            guard let device = nvr.getDevice(id: cameraID), device.context.detectMotion != target else { continue }
            device.accessory.service(.switch, subtype: ProtectReservedNames.switchMotionSensor)?[.on]?.value = .bool(target)
            device.context.detectMotion = target
            log.info("\(viewName) -> \(device.accessoryName): Motion detection \(target ? "enabled" : "disabled").")
        }
        platform.contexts[id].liveviewState = target
        nvr.publish(nvr.mac, "liveviews", JSONValue.array([["name": .string(viewName), "state": .bool(target)]]).text())
    }

    /// On when every camera of the liveview detects motion, off when none or when they differ.
    func switchState(_ viewName: String) -> Bool {
        let states = Set(liveviewCameras(viewName).map { nvr.getDevice(id: $0)?.context.detectMotion })
        guard states.count == 1, let state = states.first else { return false }
        return state ?? false
    }

    /// The cameras of every liveview named `Protect-<name>`: there may be several of the same name.
    func liveviewCameras(_ viewName: String) -> [String] {
        liveviews.filter { $0.name.uppercased() == ("Protect-" + viewName).uppercased() }.flatMap(\.cameras)
    }
}

/// The security system of the liveview scenes (`ProtectSecuritySystem`): Home, Away, Night and Off select a
/// liveview's cameras for motion detection; an optional switch triggers the alarm (`SecuritySystem.Alarm`).
@ProtectActor
final class ProtectSecuritySystem: ProtectBase {
    let accessory: ProtectAccessory
    private var isAlarmTriggered = false

    init(nvr: ProtectNVR, accessory: ProtectAccessory) {
        self.accessory = accessory
        super.init(nvr: nvr)
        configureDevice()
    }

    private var context: ProtectAccessoryContext {
        get { platform.contexts[accessory.id] }
        set { platform.contexts[accessory.id] = newValue }
    }

    private var securityState: Int { context.securityState ?? HAPConstants.SecuritySystemCurrentState.disarmed }

    private func configureDevice() {
        let saved = context.securityState ?? HAPConstants.SecuritySystemCurrentState.stayArm
        context = ProtectAccessoryContext(nvr: nvr.mac, securityState: saved)
        accessory.setInformation(manufacturer: "github.com/mp-consulting", model: "UniFi Protect Liveview Security System", serialNumber: nvr.mac + ".Security",
                                 hardwareRevision: ProtectDeviceConfig(nvr.ufp).hardwareRevision)
        configureMqtt()
        configureSecuritySystem()
        configureSecurityAlarm()
    }

    private func configureMqtt() {
        nvr.mqtt?.subscribeGet(nvr.mac, "securitysystem", type: "security system state", log: log) { [weak self] in
            await self?.currentStateName ?? "Off"
        }
        nvr.mqtt?.subscribeSet(nvr.mac, "securitysystem", type: "security system state", log: log) { [weak self] value, _ in
            await self?.handleMQTT(value)
        }
    }

    private func handleMQTT(_ value: String) {
        let target: Int
        switch value {
        case "home": target = HAPConstants.SecuritySystemTargetState.stayArm
        case "away": target = HAPConstants.SecuritySystemTargetState.awayArm
        case "night": target = HAPConstants.SecuritySystemTargetState.nightArm
        case "off": target = HAPConstants.SecuritySystemTargetState.disarm
        case "alarmoff":
            setSecurityAlarm(false)
            return
        case "alarmon":
            setSecurityAlarm(true)
            return
        default:
            log.error("Unable to process MQTT security system setting: \(value).")
            return
        }
        accessory.firstService(.securitySystem)?[.securitySystemTargetState]?.value = .int(target)
        setSecurityState(target)
    }

    private func configureSecuritySystem() {
        let service = accessory.acquire(.securitySystem, name: accessory.name)
        let target: Int = switch context.securityState {
        case HAPConstants.SecuritySystemCurrentState.stayArm: HAPConstants.SecuritySystemTargetState.stayArm
        case HAPConstants.SecuritySystemCurrentState.awayArm: HAPConstants.SecuritySystemTargetState.awayArm
        case HAPConstants.SecuritySystemCurrentState.nightArm: HAPConstants.SecuritySystemTargetState.nightArm
        default: HAPConstants.SecuritySystemTargetState.disarm
        }
        service[.securitySystemCurrentState]?.value = .int(securityState)
        service[.securitySystemCurrentState]?.onRead { [weak self] in
            guard let self else { return .int(HAPConstants.SecuritySystemCurrentState.disarmed) }
            return .int(await self.isAlarmTriggered ? HAPConstants.SecuritySystemCurrentState.alarmTriggered : self.securityState)
        }
        service[.securitySystemTargetState]?.onWrite { @ProtectActor [weak self] value in self?.setSecurityState(value.intValue ?? 0) }
        service[.securitySystemTargetState]?.value = .int(target)
    }

    @discardableResult
    private func configureSecurityAlarm() -> Bool {
        isAlarmTriggered = false
        guard accessory.valid(.switch, nvr.hasFeature("SecuritySystem.Alarm")) else { return false }
        let service = accessory.acquire(.switch, name: accessory.name + " Security Alarm")
        log.info("Enabling the security alarm switch on the security system accessory.")
        service[.on]?.onRead { [weak self] in .bool(await self?.isAlarmTriggered ?? false) }
        service[.on]?.onWrite { @ProtectActor [weak self] value in
            guard let self else { return }
            let on = value.boolValue ?? false
            self.setSecurityAlarm(on)
            self.log.info("Security system alarm \(on ? "triggered" : "reset").")
        }
        service[.on]?.value = .bool(isAlarmTriggered)
        return true
    }

    /// `Home`, `Away`, `Night`, `Off` or `Alarm`, for MQTT.
    var currentStateName: String {
        if isAlarmTriggered { return "Alarm" }
        switch securityState {
        case HAPConstants.SecuritySystemCurrentState.alarmTriggered: return "Alarm"
        case HAPConstants.SecuritySystemCurrentState.awayArm: return "Away"
        case HAPConstants.SecuritySystemCurrentState.nightArm: return "Night"
        case HAPConstants.SecuritySystemCurrentState.stayArm: return "Home"
        default: return "Off"
        }
    }

    /// Applies a mode: motion detection on for the cameras of its liveview, off for the rest of the
    /// controller's devices.
    func setSecurityState(_ value: Int) {
        guard !liveviews.isEmpty || nvr.liveviews != nil else { return }
        let newState: Int
        var scene = ""
        switch value {
        case HAPConstants.SecuritySystemTargetState.stayArm:
            newState = HAPConstants.SecuritySystemCurrentState.stayArm
            scene = "protect-home"
        case HAPConstants.SecuritySystemTargetState.awayArm:
            newState = HAPConstants.SecuritySystemCurrentState.awayArm
            scene = "protect-away"
        case HAPConstants.SecuritySystemTargetState.nightArm:
            newState = HAPConstants.SecuritySystemCurrentState.nightArm
            scene = "protect-night"
        case HAPConstants.SecuritySystemTargetState.disarm:
            newState = HAPConstants.SecuritySystemCurrentState.disarmed
            scene = "protect-off"
        default:
            newState = HAPConstants.SecuritySystemCurrentState.disarmed
        }
        let cameras = liveviews.filter { $0.name.lowercased() == scene }.flatMap(\.cameras)
        let service = accessory.firstService(.securitySystem)
        if newState != HAPConstants.SecuritySystemCurrentState.disarmed, cameras.isEmpty {
            log.info("No liveview configured for this security system state. Create a liveview named \(scene) in the Protect webUI to use this feature.")
            context.securityState = newState
            service?[.securitySystemCurrentState]?.value = .int(newState)
            return
        }
        log.info("Setting the liveview scene: \(scene).")
        for device in nvr.deviceList.sorted(by: { $0.accessoryName < $1.accessoryName }) where device.context.nvr == nvr.mac {
            let target = cameras.contains(device.ufp.id)
            guard device.context.detectMotion != target else { continue }
            device.context.detectMotion = target
            device.accessory.service(.switch, subtype: ProtectReservedNames.switchMotionSensor)?[.on]?.value = .bool(target)
            log.info("\(scene) -> \(device.accessoryName): Motion detection \(target ? "enabled" : "disabled").")
        }
        context.securityState = newState
        service?[.securitySystemCurrentState]?.value = .int(newState)
        isAlarmTriggered = false
        if let alarm = accessory.firstService(.switch), alarm[.on]?.value.boolValue != false { alarm[.on]?.value = .bool(false) }
        nvr.publish(nvr.mac, "securitysystem", currentStateName)
    }

    private var liveviews: [ProtectLiveview] { nvr.liveviews?.liveviews ?? [] }

    func setSecurityAlarm(_ value: Bool) {
        guard isAlarmTriggered != value else { return }
        isAlarmTriggered = value
        accessory.firstService(.securitySystem)?[.securitySystemCurrentState]?.value = .int(value ? HAPConstants.SecuritySystemCurrentState.alarmTriggered : securityState)
        accessory.firstService(.switch)?[.on]?.value = .bool(value)
        nvr.publish(nvr.mac, "securitysystem", currentStateName)
    }
}

/// The controller's system information (`ProtectNvrSystemInfo`, `Nvr.SystemInfo`): a temperature sensor
/// with the CPU temperature, and MQTT `systeminfo`.
@ProtectActor
final class ProtectNvrSystemInfo: ProtectBase {
    private(set) var accessory: ProtectAccessory?

    static func make(nvr: ProtectNVR) async -> ProtectNvrSystemInfo {
        let info = ProtectNvrSystemInfo(nvr: nvr)
        await info.configureAccessory()
        info.configureMqtt()
        info.subscribe("updateEvent." + (nvr.ufp.string("id") ?? "")) { [weak info] packet in
            guard packet.payload.has("systemInfo") else { return }
            info?.updateDevice()
        }
        return info
    }

    private var id: String { ProtectPlatform.accessoryID(nvr.mac + ".NVRSystemInfo") }

    private func configureAccessory() async {
        guard nvr.hasFeature("Nvr.SystemInfo") else {
            if platform.host.accessoryIDs.contains(id) {
                log.info("Removing UniFi Protect controller system information sensors.")
                try? await platform.host.remove(id: id)
                platform.contexts.remove(id)
            }
            accessory = nil
            return
        }
        let accessory = ProtectAccessory(id: id, name: platform.host.cachedName(id: id) ?? nvr.ufp.string("name") ?? nvr.ufp.string("marketName") ?? "UniFi Protect",
                                         category: .sensor, host: platform.host, log: nvr.log)
        self.accessory = accessory
        platform.contexts[id] = ProtectAccessoryContext(nvr: nvr.mac, systemInfo: true)
        let device = ProtectDeviceConfig(nvr.ufp)
        accessory.setInformation(manufacturer: "Ubiquiti Inc.", model: device.marketName ?? device.type, serialNumber: device.mac, firmwareRevision: device.firmwareVersion,
                                 hardwareRevision: device.hardwareRevision)
        let enabled = updateDevice(configureHandler: true)
        log.info(enabled.isEmpty ? "No system information sensors enabled." : "Enabled system information sensor\(enabled.count > 1 ? "s" : ""): \(enabled.joined(separator: ", ")).")
        await accessory.publish()
    }

    @discardableResult
    func updateDevice(configureHandler: Bool = false) -> [String] {
        guard let accessory, accessory.valid(.temperatureSensor, nvr.hasFeature("Nvr.SystemInfo")) else { return [] }
        let service = accessory.acquire(.temperatureSensor, name: accessory.name + " CPU Temperature")
        if configureHandler {
            service[.currentTemperature]?.onRead { [weak self] in .double(await self?.nvr.ufp.double("systemInfo.cpu.temperature") ?? 0) }
        }
        service[.currentTemperature]?.value = .double(nvr.ufp.double("systemInfo.cpu.temperature") ?? 0)
        return ["cpu temperature"]
    }

    private func configureMqtt() {
        nvr.mqtt?.subscribeGet(nvr.mac, "systeminfo", type: "system information", log: log) { [weak self] in
            await self?.nvr.ufp.at("systemInfo")?.text() ?? "{}"
        }
    }
}
