import Foundation
import HomeswiftPlugin
import Homeswift

/// A light shown as a plain switch (`device/light-switch.ts`).
final class LightSwitchDevice: GoveeDevice {
    private var service: Service!

    override var category: AccessoryCategory { .switch }

    override func configure() {
        service = addService(.switch, primary: true)
        service.characteristic(.on).onWrite { [weak self] value in try await self?.internalStateUpdate(value.boolValue ?? false) }
        cacheState = bool(service[.on]) ? "on" : "off"
        logInitOptions([("showAs", "\"switch\"")])
        initialised = true
    }

    private func internalStateUpdate(_ value: Bool) async throws {
        let newValue = value ? "on" : "off"
        guard newValue != cacheState else { return }
        do {
            try await send(.state(value))
            cacheState = newValue
            log("\(Lang.curState) [\(cacheState)]")
        } catch {
            throw failed(error, service[.on], revert: .bool(cacheState == "on"))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.on], cacheState == "on")
            log("\(Lang.curState) [\(cacheState)]")
        }
    }
}

/// A smart plug as a switch, the default (`device/switch-single.ts`).
final class SwitchSingleDevice: GoveeDevice {
    private var service: Service!

    override var category: AccessoryCategory { .switch }

    override func configure() {
        service = addService(.switch, primary: true)
        service.characteristic(.on).onWrite { [weak self] value in try await self?.internalStateUpdate(value.boolValue ?? false) }
        cacheState = bool(service[.on]) ? "on" : "off"
        startHistory(.switch)
        logInitOptions([("showAs", "\"switch\"")])
        initialised = true
    }

    private func internalStateUpdate(_ value: Bool) async throws {
        let newValue = value ? "on" : "off"
        guard newValue != cacheState else { return }
        do {
            try await send(.stateOutlet(value))
            if cacheState != newValue {
                cacheState = newValue
                log("\(Lang.curState) [\(cacheState)]")
            }
            addHistory(status: value ? 1 : 0)
        } catch {
            throw failed(error, service[.on], revert: .bool(cacheState == "on"))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.on], cacheState == "on")
            log("\(Lang.curState) [\(cacheState)]")
            addHistory(status: cacheState == "on" ? 1 : 0)
        }
    }
}

/// A smart plug as an outlet, with the power readings of the H5086 (`device/outlet-single.ts`).
final class OutletSingleDevice: GoveeDevice {
    private var service: Service!
    private var cacheWatt = 0.0
    private var cacheAmp = 0.0
    private var cacheVolt = 0.0

    override var category: AccessoryCategory { .outlet }

    private var monitorsPower: Bool { info.model == "H5086" }

    override func configure() {
        let power: [CharacteristicType] = monitorsPower ? [EveCharacteristic.currentConsumption, EveCharacteristic.electricCurrent, EveCharacteristic.voltage] : []
        service = addService(.outlet, characteristics: power, primary: true)
        service.characteristic(.on).onWrite { [weak self] value in try await self?.internalStateUpdate(value.boolValue ?? false) }
        cacheState = bool(service[.on]) ? "on" : "off"
        if monitorsPower {
            cacheWatt = double(service[EveCharacteristic.currentConsumption])
            cacheAmp = double(service[EveCharacteristic.electricCurrent])
            cacheVolt = double(service[EveCharacteristic.voltage])
            startHistory(.energy)
        } else {
            startHistory(.switch)
        }
        logInitOptions([("showAs", "\"outlet\"")])
        initialised = true
    }

    private func internalStateUpdate(_ value: Bool) async throws {
        let newValue = value ? "on" : "off"
        guard newValue != cacheState else { return }
        holdReports()
        do {
            try await send(.stateOutlet(value))
            if cacheState != newValue {
                cacheState = newValue
                log("\(Lang.curState) [\(cacheState)]")
            }
            addHistory(status: value ? 1 : 0)
        } catch {
            throw failed(error, service[.on], revert: .bool(cacheState == "on"))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        guard !isHoldingReports else { return }
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.on], cacheState == "on")
            log("\(Lang.curState) [\(cacheState)]")
            addHistory(status: cacheState == "on" ? 1 : 0)
        }
        guard let commands = update.commands else { return }
        for command in commands {
            let hex = Govee.base64ToHex(command)
            let parts = Govee.hexToTwoItems(hex)
            guard Govee.item(parts, 1) == "aa" else { continue }
            switch Govee.item(parts, 1) + Govee.item(parts, 2) {
            case "aa19": powerReadings(parts)
            default: newScene(command, hex)
            }
        }
    }

    private func powerReadings(_ parts: [String]) {
        guard monitorsPower else { return }
        let watt = Double(Govee.hexToDecimal(Govee.item(parts, 13) + Govee.item(parts, 14) + Govee.item(parts, 15))) / 100
        let amp = Double(Govee.hexToDecimal(Govee.item(parts, 11) + Govee.item(parts, 12))) / 100
        let volt = Double(Govee.hexToDecimal(Govee.item(parts, 9) + Govee.item(parts, 10))) / 100
        if cacheWatt != watt {
            cacheWatt = watt
            update(service[EveCharacteristic.currentConsumption], cacheWatt)
            addHistory(power: watt)
            log("\(Lang.curWatt) [\(DeviceUpdate.format(cacheWatt))W]")
        }
        if cacheAmp != amp {
            cacheAmp = amp
            update(service[EveCharacteristic.electricCurrent], cacheAmp)
            log("\(Lang.curAmp) [\(DeviceUpdate.format(cacheAmp))A]")
        }
        if cacheVolt != volt {
            cacheVolt = volt
            update(service[EveCharacteristic.voltage], cacheVolt)
            log("\(Lang.curVolt) [\(DeviceUpdate.format(cacheVolt))V]")
        }
    }
}

/// Double and triple plugs and power strips: one Outlet or Switch per channel (`device/multi-channel.ts`).
final class MultiChannelDevice: GoveeDevice {
    enum Kind: String { case outlet = "Outlet", `switch` = "Switch" }

    let channels: Int
    let kind: Kind
    private var channelServices: [Service] = []
    private var channelStates: [String] = []

    init(environment: DeviceEnvironment, channels: Int, kind: Kind) {
        self.channels = channels
        self.kind = kind
        super.init(environment: environment)
    }

    override var category: AccessoryCategory { kind == .outlet ? .outlet : .switch }

    /// One channel's `stateDual` command (1-based): the channel's bit in the high nibble, and in the low when on.
    nonisolated static func encode(channel: Int, on: Bool) -> Int {
        let bit = 1 << (channel - 1)
        return (bit << 4) | (on ? bit : 0)
    }

    /// The channels a `stateDual` report addresses, `on` or `off`, nil for the others.
    nonisolated static func decode(_ value: Int, channels: Int) -> [String?] {
        let mask = (value >> 4) & 0x0F
        let on = value & 0x0F
        return (0..<channels).map { index in
            let bit = 1 << index
            guard mask & bit != 0 else { return nil }
            return on & bit != 0 ? "on" : "off"
        }
    }

    override func configure() {
        for channel in 1...channels {
            let name = "\(kind.rawValue) \(channel)"
            let service = addService(kind == .outlet ? .outlet : .switch, name: name, subtype: "\(kind.rawValue.lowercased())\(channel)", characteristics: [.configuredName, .serviceLabelIndex])
            if (service[.configuredName]?.value.stringValue ?? "").isEmpty { update(service[.configuredName], .string(name)) }
            update(service[.serviceLabelIndex], channel)
            service.characteristic(.on).onWrite { [weak self] value in try await self?.internalStateUpdate(channel, value.boolValue ?? false) }
            channelServices.append(service)
            channelStates.append(bool(service[.on]) ? "on" : "off")
        }
        logInitOptions([("showAs", "\"\(kind.rawValue.lowercased())\""), ("channels", String(channels))])
        initialised = true
    }

    private func channelName(_ channel: Int) -> String {
        channelServices[channel - 1][.configuredName]?.value.stringValue.flatMap(\.nonEmpty) ?? "\(kind.rawValue) \(channel)"
    }

    private func internalStateUpdate(_ channel: Int, _ value: Bool) async throws {
        let index = channel - 1
        let newValue = value ? "on" : "off"
        guard channelStates[index] != newValue else { return }
        do {
            try await send(.stateDual(Self.encode(channel: channel, on: value)))
            channelStates[index] = newValue
            log("[\(channelName(channel))] \(Lang.curState) [\(newValue)]")
        } catch {
            throw failed(error, channelServices[index][.on], revert: .bool(channelStates[index] == "on"))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        guard let value = update.stateDual else { return }
        for (index, state) in Self.decode(value, channels: channels).enumerated() {
            guard let state, state != channelStates[index] else { continue }
            channelStates[index] = state
            self.update(channelServices[index][.on], state == "on")
            log("[\(channelName(index + 1))] \(Lang.curState) [\(state)]")
        }
    }
}
