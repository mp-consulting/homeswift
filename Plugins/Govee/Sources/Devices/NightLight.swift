import Foundation
import Homeswift
import HomeswiftPlugin

/// The night light of a heater, a fan or a humidifier: a lightbulb with brightness and colour, written with
/// Govee's `1b` frames. A dragged brightness or hue slider sends its last value only; brightness 0 sends, then
/// shows the light off after a moment.
@GoveeActor
final class NightLight {
    enum Frames {
        /// Heaters and fans (`3a1b…` over multiSync): power, brightness and colour each on their own.
        case separate
        /// Humidifiers (`331b…` over ptReal): power, brightness and colour in one frame.
        case combined
    }

    let service: Service
    private unowned let device: GoveeDevice
    private let frames: Frames
    private(set) var state = "off"
    private(set) var brightness = 100
    private(set) var hue = 0.0
    private(set) var saturation = 0.0
    private let brightnessGuard = LatestCallGuard(delay: .milliseconds(Catalog.debounceBrightnessMs))
    private let colourGuard = LatestCallGuard(delay: .milliseconds(Catalog.debounceColorMs))

    /// Adds the lightbulb to `device` (in its place among the services) and wires it.
    init(_ device: GoveeDevice, frames: Frames) {
        self.device = device
        self.frames = frames
        service = device.addService(.lightbulb, characteristics: [.brightness, .hue, .saturation])
        service.characteristic(.on).onWrite { [weak self] value in try await self?.setOn(value.boolValue ?? false) }
        state = device.bool(service[.on]) ? "on" : "off"
        service.characteristic(.brightness).onWrite { [weak self] value in try await self?.setBrightness(value.intValue ?? 0) }
        brightness = device.int(service[.brightness])
        service.characteristic(.hue).onWrite { [weak self] value in try await self?.setHue(value.doubleValue ?? 0) }
        hue = device.double(service[.hue])
        saturation = device.double(service[.saturation])
    }

    // MARK: Writes

    private func setOn(_ on: Bool) async throws {
        let state = try await device.toggle(on, current: state, label: Lang.curLight, service[.on], revert: .bool(self.state == "on")) { _ in
            switch frames {
            case .separate: return .multiSync(Govee.code([0x3A, 0x1B, 0x01, 0x01, on ? 0x01 : 0x00]))
            case .combined:
                let rgb = Colour.hs2rgb(hue, saturation)
                return .ptReal(Govee.code(on ? [0x33, 0x1B, 0x01, brightness, rgb.r, rgb.g, rgb.b] : [0x33, 0x1B, 0x00]))
            }
        }
        if let state { self.state = state }
    }

    private func setBrightness(_ value: Int) async throws {
        guard await brightnessGuard(), value != brightness else { return }
        let command: DeviceCommand
        switch frames {
        case .separate: command = .multiSync(Govee.code([0x3A, 0x1B, 0x01, 0x02, value]))
        case .combined:
            let rgb = Colour.hs2rgb(hue, saturation)
            command = .ptReal(Govee.code([0x33, 0x1B, 0x01, value, rgb.r, rgb.g, rgb.b]))
        }
        do {
            try await device.send(command)
            if value == 0 {
                device.schedule(after: .milliseconds(1500)) { [weak self] in
                    guard let self else { return }
                    state = "off"
                    if device.bool(service[.on]) {
                        device.update(service[.on], false)
                        device.log("\(Lang.curLight) [\(state)]")
                    }
                    device.update(service[.brightness], brightness)
                }
                return
            }
            brightness = value
            device.log("\(Lang.curBright) [\(value)%]")
        } catch {
            throw device.failed(error, service[.brightness], revert: .int(brightness))
        }
    }

    private func setHue(_ value: Double) async throws {
        guard await colourGuard(), value != hue else { return }
        let saturation = device.double(service[.saturation])
        let rgb = Colour.hs2rgb(value, saturation)
        let command: DeviceCommand =
            switch frames {
            case .separate: .multiSync(Govee.code([0x3A, 0x1B, 0x05, 0x0D, rgb.r, rgb.g, rgb.b]))
            case .combined: .ptReal(Govee.code([0x33, 0x1B, 0x01, brightness, rgb.r, rgb.g, rgb.b]))
            }
        do {
            try await device.send(command)
            hue = value
            self.saturation = saturation
            device.log("\(Lang.curColour) [rgb \(rgb.r) \(rgb.g) \(rgb.b)]")
        } catch {
            throw device.failed(error, service[.hue], revert: .double(hue))
        }
    }

    // MARK: Reports

    /// The light went on or off.
    func report(on: Bool) {
        let state = on ? "on" : "off"
        guard self.state != state else { return }
        self.state = state
        device.update(service[.on], on)
        device.log("\(Lang.curLight) [\(state)]")
    }

    func report(brightness: Int) {
        guard self.brightness != brightness else { return }
        self.brightness = brightness
        device.update(service[.brightness], brightness)
        device.log("\(Lang.curBright) [\(brightness)%]")
    }

    /// The colour, from bytes 5 to 7 of `parts`; a change of saturation alone counts with `orSaturation`.
    func report(colour parts: [String], orSaturation: Bool = false) {
        let rgb = RGB(Govee.hexToDecimal(Govee.item(parts, 5)), Govee.hexToDecimal(Govee.item(parts, 6)), Govee.hexToDecimal(Govee.item(parts, 7)))
        let hs = Colour.rgb2hs(rgb)
        guard Double(hs.hue) != hue || (orSaturation && Double(hs.saturation) != saturation) else { return }
        hue = Double(hs.hue)
        saturation = Double(hs.saturation)
        device.update(service[.hue], hue)
        device.update(service[.saturation], saturation)
        device.log("\(Lang.curColour) [rgb \(rgb.r) \(rgb.g) \(rgb.b)]")
    }

    /// The heaters' and fans' `aa1b01`: power (byte 4) and brightness (byte 5).
    func stateReport(_ parts: [String]) {
        report(on: Govee.item(parts, 4) == "01")
        report(brightness: Govee.hexToDecimal(Govee.item(parts, 5)))
    }
}
