import Foundation
import Homeswift
import HomeswiftPlugin

/// Lights: on/off, and brightness, colour temperature and colour when the device reports them. White
/// lights carry `white: {br, ct}` (ct 0-100), others `bright` and `colorTemp`; colour is `color: {r, g, b, br}`.
final class LightAccessory: BaseAccessory {
    let supportsBrightness: Bool
    let supportsColorTemperature: Bool
    let supportsColor: Bool
    /// With brightness and colour temperature: Adaptive Lighting, unless the light's `adaptiveLightingShift` is -1.
    private(set) var adaptiveLighting: AdaptiveLightingController?
    /// Set while the whole state is applied again: no report of a change, so Adaptive Lighting is left alone.
    private var resyncing = false

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        let params = box.params
        supportsBrightness = params["bright"] != nil || params["white"]?["br"] != nil
        supportsColorTemperature = params["colorTemp"] != nil || params["white"]?["ct"] != nil
        supportsColor = params["color"] != nil || params["ltype"] == "color"
        super.init(platform: platform, record: record, box: box)
        category = .lightbulb
        var optional: [CharacteristicType] = []
        if supportsBrightness { optional.append(.brightness) }
        if supportsColorTemperature { optional.append(.colorTemperature) }
        if supportsColor { optional += [.hue, .saturation] }
        service = addService(.lightbulb, optional: optional, primary: true)

        onRead(service.characteristic(.on), "On") { [weak self] in .bool(self?.deviceParams["switch"] == "on") }
        onWrite(service.characteristic(.on)) { [weak self] value in
            guard let self else { return }
            try await self.handleSet("On", value) { await self.sendCommand(["switch": onOff(value.boolValue == true)]) }
        }
        if supportsBrightness {
            onRead(service.characteristic(.brightness), "Brightness") { [weak self] in
                guard let self else { return nil }
                if let br = self.deviceParams["white"]?["br"] { return .int((br.jsNumber ?? 0).clampedInt) }
                let bright = self.deviceParams["bright"]?.jsNumber ?? 0
                return .int((bright == 0 ? 100 : bright).clampedInt)
            }
            onWrite(service.characteristic(.brightness)) { [weak self] value in try await self?.setBrightness(value) }
        }
        if supportsColorTemperature {
            onRead(service.characteristic(.colorTemperature), "ColorTemperature") { [weak self] in
                guard let self else { return nil }
                return .int(clamp(self.mired(self.deviceParams), EWeLinkColor.minimumMired, EWeLinkColor.maximumMired).clampedInt)
            }
            onWrite(service.characteristic(.colorTemperature)) { [weak self] value in try await self?.setColorTemperature(value) }
        }
        if supportsColor {
            onRead(service.characteristic(.hue), "Hue") { [weak self] in
                guard let self, let color = self.deviceParams["color"] else { return .int(0) }
                return .double(self.hsv(color).h)
            }
            onWrite(service.characteristic(.hue)) { [weak self] value in try await self?.setColor(hue: value.doubleValue) }
            onRead(service.characteristic(.saturation), "Saturation") { [weak self] in
                guard let self, let color = self.deviceParams["color"] else { return .int(100) }
                return .double(self.hsv(color).s)
            }
            onWrite(service.characteristic(.saturation)) { [weak self] value in try await self?.setColor(saturation: value.doubleValue) }
        }
        applyInitialState()
        // Adaptive Lighting, once turned on in the Home app: the controller sets the temperature through the handler
        // above, `adaptiveLightingShift` mireds warmer. After the initial state, which reports no change.
        let shift = configuration.light(record.deviceID)?.adaptiveLightingShift ?? 0
        if shift != -1 {
            adaptiveLighting = platform.context.adaptiveLighting(for: service, accessoryID: record.id, customTemperatureAdjustment: Int(max(0, shift).rounded()))
        }
    }

    private func mired(_ params: DeviceParams) -> Double {
        if let ct = params["white"]?["ct"]?.jsNumber { return EWeLinkColor.miredFromPercent(ct) }
        return params["colorTemp"]?.jsNumber ?? EWeLinkColor.defaultMired
    }

    private func hsv(_ color: JSONValue) -> (h: Double, s: Double, v: Double) {
        EWeLinkColor.rgbToHSV(color["r"]?.jsNumber ?? 0, color["g"]?.jsNumber ?? 0, color["b"]?.jsNumber ?? 0)
    }

    private func setBrightness(_ value: HAPValue) async throws {
        let brightness = value.doubleValue ?? 0
        try await handleSet("Brightness", value) {
            if var white = deviceParams["white"]?.objectValue {
                white["br"] = .number(brightness)
                return await sendCommand(["white": .object(white)])
            }
            return await sendCommand(["bright": .number(brightness)])
        }
    }

    private func setColorTemperature(_ value: HAPValue) async throws {
        let mired = value.doubleValue ?? EWeLinkColor.defaultMired
        try await handleSet("ColorTemperature", value) {
            if var white = deviceParams["white"]?.objectValue {
                white["ct"] = .number(EWeLinkColor.percentFromMired(mired))
                return await sendCommand(["ltype": "white", "white": .object(white)])
            }
            return await sendCommand(["colorTemp": .number(mired)])
        }
    }

    private func setColor(hue: Double? = nil, saturation: Double? = nil) async throws {
        let label = hue != nil ? "Hue" : "Saturation"
        try await handleSet(label, .double(hue ?? saturation ?? 0)) {
            let current = deviceParams["color"]?.objectValue ?? ["r": 255, "g": 255, "b": 255, "br": 100]
            let hsv = EWeLinkColor.rgbToHSV(current["r"]?.jsNumber ?? 0, current["g"]?.jsNumber ?? 0, current["b"]?.jsNumber ?? 0)
            let rgb = EWeLinkColor.hsvToRGB(hue ?? hsv.h, saturation ?? hsv.s, hsv.v)
            var color: [String: JSONValue] = ["r": .number(rgb.r), "g": .number(rgb.g), "b": .number(rgb.b)]
            if let br = current["br"] { color["br"] = br }
            return await sendCommand(["ltype": "color", "color": .object(color)])
        }
    }

    override func refreshFromDevice() {
        resyncing = true
        defer { resyncing = false }
        super.refreshFromDevice()
    }

    override func updateState(_ params: DeviceParams) {
        // A colour, or another white, set elsewhere (the eWeLink app, a remote) stops Adaptive Lighting.
        let colour = params["ltype"] == "color"
        if !resyncing, let adaptiveLighting, colour || params["colorTemp"] != nil || params["white"]?["ct"] != nil,
           adaptiveLighting.disableIfChangedElsewhere(mireds: colour ? nil : Int(mired(params).rounded())) {
            logInfo("Colour changed outside HomeKit, Adaptive Lighting off")
        }
        mergeDeviceParams(params)
        let on = params["switch"] == "on"
        service.characteristic(.on).value = .bool(on)
        if supportsBrightness {
            update(service.characteristic(.brightness), params["white"]?["br"]?.jsNumber ?? params["bright"]?.jsNumber ?? 100)
        }
        if supportsColorTemperature {
            update(service.characteristic(.colorTemperature), clamp(mired(params), EWeLinkColor.minimumMired, EWeLinkColor.maximumMired))
        }
        if supportsColor, let color = params["color"] {
            let values = hsv(color)
            update(service.characteristic(.hue), values.h)
            update(service.characteristic(.saturation), values.s)
        }
        logDebug("State updated: \(on ? "ON" : "OFF")")
    }
}
