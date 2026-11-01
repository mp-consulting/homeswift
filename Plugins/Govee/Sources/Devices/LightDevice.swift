import Foundation
import Homeswift
import HomeswiftPlugin

/// RGB and white lights (`device/light.ts`): power, brightness, colour, colour temperature with Adaptive
/// Lighting, scenes (the legacy Eve slots and the scenes picked from the Govee library, one switch each) and
/// live music mode as a second lightbulb.
final class LightDevice: GoveeDevice {
    /// A scene the light can apply: a library pick (a switch) or a legacy slot (an Eve switch, or a switch).
    struct ActiveScene {
        /// The legacy slot's key, or the `gv-scene-*` subtype.
        var key: String
        var name: String
        var sceneCode: String
        var bleCode: String?
        /// The Eve characteristic, for a legacy slot not shown as a switch.
        var legacyCharacteristic: Characteristic?
        var switchService: Service?
    }

    static let sceneServicePrefix = "gv-scene-"
    static let musicServiceSubtype = "gv-music"
    static let minMired = 140.0
    static let maxMired = 500.0

    private var lightbulb: Service!
    private(set) var adaptiveLighting: AdaptiveLightingController?
    private let alShift: Int
    private let brightStep: Int
    private let colourSafeMode: Bool
    private let minKelvin = 2000
    private let maxKelvin = 9000

    private(set) var scenes: [ActiveScene] = []
    private var hasScenes: Bool { !scenes.isEmpty }
    private var colourMode: Characteristic?

    private var musicService: Service?
    private var musicSettings: JSONValue?
    private var cacheMusicSensitivity = 50
    private var cacheMusicHue = 0.0
    private var cacheMusicSat = 0.0

    private var cacheBright = 0
    private var cacheBrightRaw = 0
    private var cacheHue = 0.0
    private var cacheSat = 0.0
    private var cacheR = 0, cacheG = 0, cacheB = 0
    private var cacheKelvin = 0
    /// Whether the light has reported a colour since launch. The first report only fills the cache: compared with
    /// its empty values it would always look like a colour set elsewhere, and turn Adaptive Lighting off at every start.
    private var colourReported = false
    private var cacheMired = 0.0
    private var cacheScene = ""
    private var stateRequestSeq = 0

    private let debounceBright = LatestCallGuard(delay: .milliseconds(Catalog.debounceBrightnessMs))
    private let debounceColour = LatestCallGuard(delay: .milliseconds(Catalog.debounceColorMs))
    private let debounceCT = LatestCallGuard(delay: .milliseconds(Catalog.debounceColorMs))

    override init(environment: DeviceEnvironment) {
        colourSafeMode = environment.platform.colourSafeMode
        alShift = environment.settings.int("adaptiveLightingShift") ?? GoveeConstants.Defaults.adaptiveLightingShift
        let step = environment.settings.int("brightnessStep") ?? 0
        brightStep = step != 0 ? min(step, 100) : GoveeConstants.Defaults.brightnessStep
        super.init(environment: environment)
    }

    override var category: AccessoryCategory { .lightbulb }

    override func configure() {
        var characteristics: [CharacteristicType] = [.brightness.with(minStep: Double(brightStep)), .hue, .saturation]
        if !colourSafeMode { characteristics.append(.colorTemperature) }
        let slots = legacySlots()
        let library = librarySelections()
        let musicEnabled = settings["musicModeLive"].map { GoveePlugin.Configuration.truthy($0["enabled"]) } ?? false
        // The Eve characteristics of the slots not shown as switches, and the colour mode toggle when there is
        // another mode to switch away from.
        var extra: [Characteristic] = []
        var eveSlots: [String: Characteristic] = [:]
        for slot in slots where !slot.asSwitch {
            let characteristic = Characteristic(slot.type, value: false)
            eveSlots[slot.key] = characteristic
            extra.append(characteristic)
        }
        if !slots.isEmpty || !library.isEmpty || musicEnabled {
            let toggle = Characteristic(GoveeCharacteristic.colourMode, value: false)
            colourMode = toggle
            extra.append(toggle)
        }
        lightbulb = addService(.lightbulb, characteristics: characteristics, extra: extra, primary: true)

        scenes = []
        for slot in slots {
            // Keyed, named and subtyped by the characteristic's name, as the Homebridge plugin did ("SceneTwo").
            let name = slot.key.prefix(1).uppercased() + slot.key.dropFirst()
            var scene = ActiveScene(key: name, name: name, sceneCode: slot.sceneCode, bleCode: slot.bleCode)
            if slot.asSwitch {
                scene.switchService = sceneSwitch(name, subtype: name)
            } else {
                scene.legacyCharacteristic = eveSlots[slot.key]
            }
            scenes.append(scene)
        }
        for (index, selection) in library.enumerated() {
            let kind = selection["kind"]?.stringValue ?? "scene"
            let id = selection["sceneId"].flatMap(GoveePlugin.Configuration.integer).map(String.init) ?? String(index)
            let key = "\(Self.sceneServicePrefix)\(kind)-\(id)"
            let name = selection["name"]?.stringValue ?? ""
            var scene = ActiveScene(key: key, name: name, sceneCode: selection["sceneCode"]?.stringValue ?? "", bleCode: selection["bleCode"]?.stringValue)
            scene.switchService = sceneSwitch(name, subtype: key)
            scenes.append(scene)
        }
        for index in scenes.indices {
            let scene = scenes[index]
            if let characteristic = scene.legacyCharacteristic {
                characteristic.value = false
                characteristic.onWrite { [weak self] value in try await self?.internalSceneUpdate(scene, value.boolValue ?? false, isService: false) }
            }
            if let service = scene.switchService {
                service.characteristic(.on).value = false
                service.characteristic(.on).onWrite { [weak self] value in try await self?.internalSceneUpdate(scene, value.boolValue ?? false, isService: true) }
            }
        }

        setupMusicMode(enabled: musicEnabled)
        colourMode?.value = false
        colourMode?.onWrite { @GoveeActor [weak self] value in
            guard let self, value.boolValue == true else { return }
            try await self.internalColourUpdate(self.cacheHue, force: true)
        }
        setupLightbulb()

        if !colourSafeMode, alShift != -1, let factory = environment.adaptiveLighting {
            adaptiveLighting = factory(lightbulb, alShift, info.id)
        }

        logInitOptions([
            ("adaptiveLightingShift", String(alShift)), ("aws", "\"\(transports.label(transports.hasAWS, transports.useAWS))\""),
            ("ble", "\"\(transports.label(transports.hasBLE, transports.useBLE))\""), ("brightnessStep", String(brightStep)),
            ("colourSafeMode", String(colourSafeMode)), ("lan", "\"\(transports.label(transports.hasLAN, transports.useLAN))\""),
        ])
        initialised = true
    }

    /// The legacy slots configured with a code.
    private func legacySlots() -> [(key: String, type: CharacteristicType, sceneCode: String, bleCode: String?, asSwitch: Bool)] {
        GoveeCharacteristic.sceneSlots.compactMap { key, type in
            guard let slot = settings[key], let code = slot["sceneCode"]?.stringValue, !code.isEmpty else { return nil }
            return (key, type, code, slot["bleCode"]?.stringValue, slot["showAs"]?.stringValue == "switch")
        }
    }

    /// The scenes picked from the library, with a code and a name.
    private func librarySelections() -> [JSONValue] {
        (settings["scenes"]?.arrayValue ?? []).filter { ($0["sceneCode"]?.stringValue ?? "").isEmpty == false && ($0["name"]?.stringValue ?? "").isEmpty == false }
    }

    private func sceneSwitch(_ name: String, subtype: String) -> Service {
        let service = addService(.switch, name: name, subtype: subtype, characteristics: [.configuredName])
        update(service[.configuredName], .string(name))
        return service
    }

    // MARK: Music mode

    /// Live music mode as its own lightbulb: On starts it, Brightness is the microphone sensitivity, Hue and
    /// Saturation the colour when the device does not pick colours itself.
    private func setupMusicMode(enabled: Bool) {
        guard enabled, let settings = settings["musicModeLive"] else { return }
        musicSettings = settings
        let autoColour = settings["autoColour"].map { GoveePlugin.Configuration.truthy($0) } ?? true
        var characteristics: [CharacteristicType] = [.brightness]
        if !autoColour { characteristics += [.hue, .saturation] }
        let service = addService(.lightbulb, name: Lang.musicModeName, subtype: Self.musicServiceSubtype, characteristics: characteristics)
        musicService = service
        cacheMusicSensitivity = GoveePlugin.Configuration.integer(settings["sensitivity"]) ?? 50
        service.characteristic(.on).value = false
        service.characteristic(.on).onWrite { [weak self] value in
            if value.boolValue == true { try await self?.internalMusicUpdate() }
        }
        update(service[.brightness], cacheMusicSensitivity)
        service.characteristic(.brightness).onWrite { @GoveeActor [weak self] value in
            guard let self else { return }
            self.cacheMusicSensitivity = value.intValue ?? self.cacheMusicSensitivity
            // Sent again only while music mode is the active mode.
            if self.bool(self.musicService?[.on]) { try await self.internalMusicUpdate() }
        }
        if !autoColour {
            service.characteristic(.hue).onWrite { @GoveeActor [weak self] value in
                guard let self else { return }
                self.cacheMusicHue = value.doubleValue ?? 0
                if self.bool(self.musicService?[.on]) { try await self.internalMusicUpdate() }
            }
            service.characteristic(.saturation).onWrite { @GoveeActor [weak self] value in
                guard let self else { return }
                self.cacheMusicSat = value.doubleValue ?? 0
                if self.bool(self.musicService?[.on]) { try await self.internalMusicUpdate() }
            }
            cacheMusicHue = double(service[.hue])
            cacheMusicSat = double(service[.saturation])
        }
    }

    private func internalMusicUpdate() async throws {
        guard let settings = musicSettings else { return }
        let autoColour = settings["autoColour"].map { GoveePlugin.Configuration.truthy($0) } ?? true
        let effect = settings["effect"]?.stringValue.flatMap(SceneCodes.MusicEffect.init(rawValue:)) ?? .rhythm
        do {
            let rgb = Colour.hs2rgb(cacheMusicHue, cacheMusicSat)
            try await send(.musicMode(SceneCodes.MusicMode(
                effect: effect, sensitivity: cacheMusicSensitivity, autoColour: autoColour, colour: autoColour ? nil : rgb,
                soft: GoveePlugin.Configuration.truthy(settings["soft"]),
                musicProtocol: settings["protocol"]?.stringValue.flatMap(SceneCodes.MusicProtocol.init(rawValue:)) ?? .modern)))
            if !colourSafeMode, let adaptiveLighting, adaptiveLighting.isAdaptiveLightingActive {
                adaptiveLighting.disableAdaptiveLighting()
                log(Lang.alDisabledScene)
            }
            log("\(Lang.curMusicMode) [\(effect.rawValue)] [\(cacheMusicSensitivity)%]")
            // Music mode replaces whatever mode was active.
            schedule(after: .seconds(1)) { [weak self] in
                guard let self else { return }
                self.update(self.lightbulb[.on], true)
                self.update(self.colourMode, false)
                self.resetSceneIndicators(except: Self.musicServiceSubtype)
            }
        } catch {
            if let musicService { throw failed(error, musicService[.on], revert: false) }
            logWarn("\(Lang.devNotUpdated) \(error)")
        }
    }

    /// Clears every scene indicator but one, so HomeKit never shows two modes active.
    private func resetSceneIndicators(except key: String? = nil) {
        for scene in scenes where scene.key != key {
            update(scene.legacyCharacteristic, false)
            update(scene.switchService?[.on], false)
        }
        if key != Self.musicServiceSubtype { update(musicService?[.on], false) }
    }

    // MARK: The lightbulb

    private func setupLightbulb() {
        lightbulb.characteristic(.on).onWrite { [weak self] value in try await self?.internalStateUpdate(value.boolValue ?? false) }
        cacheState = bool(lightbulb[.on]) ? "on" : "off"
        lightbulb.characteristic(.brightness).onWrite { [weak self] value in try await self?.internalBrightnessUpdate(value.intValue ?? 0) }
        cacheBright = int(lightbulb[.brightness])
        cacheBrightRaw = cacheBright
        lightbulb.characteristic(.hue).onWrite { [weak self] value in try await self?.internalColourUpdate(value.doubleValue ?? 0) }
        cacheHue = double(lightbulb[.hue])
        cacheSat = double(lightbulb[.saturation])
        if colourSafeMode {
            cacheMired = 0
        } else {
            lightbulb.characteristic(.colorTemperature).onWrite { [weak self] value in try await self?.internalCTUpdate(value.doubleValue ?? 140) }
            cacheMired = double(lightbulb[.colorTemperature])
        }
    }

    private func internalStateUpdate(_ value: Bool) async throws {
        let newValue = value ? "on" : "off"
        stateRequestSeq += 1
        let seq = stateRequestSeq
        // A little longer than brightness and colour, so on/off is sent last.
        await environment.stateDelay()
        // Only the latest of quick taps is sent, and only when it changes the state.
        guard seq == stateRequestSeq, newValue != cacheState else { return }
        do {
            try await send(.state(value))
            if cacheState != newValue {
                cacheState = newValue
                log("\(Lang.curState) [\(cacheState)]")
            }
        } catch {
            throw failed(error, lightbulb[.on], revert: .bool(cacheState == "on"))
        }
    }

    private func internalBrightnessUpdate(_ value: Int) async throws {
        guard await debounceBright(), value != cacheBright else { return }
        do {
            try await send(.brightness(value))
            // Govee takes 0% as off.
            if value == 0 {
                schedule(after: .milliseconds(1500)) { [weak self] in
                    guard let self else { return }
                    self.cacheState = "off"
                    if self.bool(self.lightbulb[.on]) {
                        self.update(self.lightbulb[.on], false)
                        self.log("\(Lang.curState) [\(self.cacheState)]")
                    }
                    self.update(self.lightbulb[.brightness], self.cacheBright)
                }
                return
            }
            if cacheBright != value {
                cacheBright = value
                log("\(Lang.curBright) [\(value)%]")
            }
        } catch {
            throw failed(error, lightbulb[.brightness], revert: .int(cacheBright))
        }
    }

    private func internalColourUpdate(_ value: Double, force: Bool = false) async throws {
        guard await debounceColour() else { return }
        // The coldest temperature, as native Adaptive Lighting shows a colour.
        if !colourSafeMode { update(lightbulb[.colorTemperature], Self.minMired) }
        let saturation = double(lightbulb[.saturation])
        let rgb = Colour.hs2rgb(value, saturation)
        if !force, rgb.r == cacheR, rgb.g == cacheG, rgb.b == cacheB { return }
        do {
            try await send(.color(rgb))
            if hasScenes || musicService != nil {
                schedule(after: .seconds(1)) { [weak self] in
                    guard let self else { return }
                    self.update(self.lightbulb[.on], true)
                    self.update(self.colourMode, true)
                    self.resetSceneIndicators()
                }
            }
            cacheHue = value
            cacheSat = saturation
            cacheKelvin = 0
            cacheScene = ""
            if cacheR != rgb.r || cacheG != rgb.g || cacheB != rgb.b {
                (cacheR, cacheG, cacheB) = (rgb.r, rgb.g, rgb.b)
                log("\(Lang.curColour) [rgb \(cacheR) \(cacheG) \(cacheB)]")
            }
        } catch {
            throw failed(error, lightbulb[.hue], revert: .double(cacheHue))
        }
    }

    private func internalCTUpdate(_ value: Double) async throws {
        guard await debounceCT() else { return }
        // Govee wants kelvin to the nearest 100, within the light's range.
        let kelvin = Govee.roundInt(1_000_000 / value / 100) * 100
        let k = min(max(kelvin, minKelvin), maxKelvin)
        let viaAdaptiveLighting = adaptiveLighting?.isAdaptiveLightingActive ?? false
        guard cacheState == "on", cacheKelvin != k else {
            if viaAdaptiveLighting { logDebug("\(Lang.skippingAL) [\(k)K /\(Self.format(value))M]") }
            return
        }
        // Hue and saturation of that white, as native Adaptive Lighting does.
        let hs = Colour.m2hs(value)
        update(lightbulb[.hue], hs.hue)
        update(lightbulb[.saturation], hs.saturation)
        let rgb = Colour.k2rgb(Double(k))
        do {
            // BLE-only lights take the temperature as a colour.
            try await send(isBLEOnly ? .color(rgb) : .colorTem(k))
            if hasScenes || musicService != nil {
                schedule(after: .seconds(1)) { [weak self] in
                    guard let self else { return }
                    self.update(self.lightbulb[.on], true)
                    self.update(self.colourMode, true)
                    self.resetSceneIndicators()
                }
            }
            (cacheR, cacheG, cacheB) = (rgb.r, rgb.g, rgb.b)
            cacheMired = value
            cacheScene = ""
            if cacheKelvin != k {
                cacheKelvin = k
                log("\(Lang.curColour) [\(k)K / \(Self.format(value))M]\(viaAdaptiveLighting ? " \(Lang.viaAL)" : "")")
            }
        } catch {
            throw failed(error, lightbulb[.colorTemperature], revert: .double(cacheMired))
        }
    }

    /// The scenes picked from the Govee library (the switches), by subtype: what Homeswift's Scenes page lists.
    var librarySceneNames: [(key: String, name: String)] {
        scenes.filter { $0.key.hasPrefix(Self.sceneServicePrefix) }.map { ($0.key, $0.name) }
    }

    /// Applies a library pick by subtype, as its switch does.
    func applyScene(key: String) async throws {
        guard let scene = scenes.first(where: { $0.key == key }) else { throw PluginSceneError("no such scene") }
        try await internalSceneUpdate(scene, true, isService: true)
    }

    /// Plays a library scene that is not one of the light's switches (an animated scene's effect); answers whether
    /// the light took it.
    func applyLibraryScene(name: String, code: String) async -> Bool {
        do {
            try await send(.rgbScene(code: code, bleCode: nil))
            if !colourSafeMode, let adaptiveLighting, adaptiveLighting.isAdaptiveLightingActive { adaptiveLighting.disableAdaptiveLighting() }
            cacheScene = name
            log("\(Lang.curScene) [\(name)]")
            return true
        } catch {
            logWarn("\(Lang.devNotUpdated) \(error)")
            return false
        }
    }

    private func internalSceneUpdate(_ scene: ActiveScene, _ value: Bool, isService: Bool) async throws {
        guard value else { return }
        do {
            try await send(.rgbScene(code: scene.sceneCode, bleCode: scene.bleCode))
            if !colourSafeMode, let adaptiveLighting, adaptiveLighting.isAdaptiveLightingActive {
                adaptiveLighting.disableAdaptiveLighting()
                log(Lang.alDisabledScene)
            }
            if cacheScene != scene.name {
                cacheScene = scene.name
                log("\(Lang.curScene) [\(cacheScene)]")
            }
            schedule(after: .seconds(1)) { [weak self] in
                guard let self else { return }
                self.update(self.lightbulb[.on], true)
                self.update(self.colourMode, false)
                self.resetSceneIndicators(except: scene.key)
            }
        } catch {
            if isService, let service = scene.switchService { throw failed(error, service[.on], revert: false) }
            if let characteristic = scene.legacyCharacteristic { throw failed(error, characteristic, revert: false) }
            logWarn("\(Lang.devNotUpdated) \(error)")
        }
    }

    // MARK: Reports

    override func externalUpdate(_ update: DeviceUpdate) async {
        guard initialised else { return }
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(lightbulb[.on], cacheState == "on")
            log("\(Lang.curState) [\(cacheState)]")
        }
        if let brightness = update.brightness, brightness != cacheBrightRaw {
            cacheBrightRaw = brightness
            // Govee reports 0 when off; HomeKit shows 1 while the light is on.
            cacheBright = cacheState == "on" ? max(cacheBrightRaw, 1) : cacheBrightRaw
            self.update(lightbulb[.brightness], cacheBright)
            log("\(Lang.curBright) [\(cacheBright)%]")
        }
        if update.kelvin != nil || update.rgb != nil {
            externalColour(update)
        }
    }

    private func externalColour(_ update: DeviceUpdate) {
        var hs: (hue: Int, saturation: Int)
        var rgb: RGB
        var mired: Double?
        var changed = false
        var significant = false
        if let kelvin = update.kelvin {
            // HomeKit takes 140 to 500 mired (about 7143 K to 2000 K); Govee lights report up to 9000 K.
            mired = min(max(Govee.round(1_000_000 / Double(kelvin)), Self.minMired), Self.maxMired)
            hs = Colour.m2hs(mired!)
            rgb = Colour.hs2rgb(Double(hs.hue), Double(hs.saturation))
            changed = kelvin != cacheKelvin
        } else if let reported = update.rgb {
            rgb = reported
            hs = Colour.rgb2hs(rgb)
            if Double(hs.hue) != cacheHue || Double(hs.saturation) != cacheSat {
                changed = true
                significant = abs(rgb.r - cacheR) + abs(rgb.g - cacheG) + abs(rgb.b - cacheB) > 50
            }
        } else {
            return
        }
        guard changed else { return }
        let firstReport = !colourReported
        colourReported = true
        // A colour, or a white more than Govee's 100 K step from the one shown, set elsewhere stops Adaptive Lighting;
        // checked before the report is shown. A light that takes whites as colours (BLE only) echoes them, so only a
        // significant colour change counts.
        var stopped = false
        if !colourSafeMode, !firstReport, let adaptiveLighting {
            if let mired, let kelvin = update.kelvin {
                let step = Int((1_000_000 / Double(max(kelvin - 100, 1)) - 1_000_000 / Double(kelvin)).rounded(.up))
                stopped = adaptiveLighting.disableIfChangedElsewhere(mireds: Int(mired.rounded()), tolerance: step)
            } else {
                stopped = significant && adaptiveLighting.disableIfChangedElsewhere(mireds: nil)
            }
        }
        self.update(lightbulb[.hue], hs.hue)
        self.update(lightbulb[.saturation], hs.saturation)
        (cacheR, cacheG, cacheB) = (rgb.r, rgb.g, rgb.b)
        (cacheHue, cacheSat) = (Double(hs.hue), Double(hs.saturation))
        if let mired, let kelvin = update.kelvin {
            if !colourSafeMode { self.update(lightbulb[.colorTemperature], mired) }
            cacheMired = mired
            cacheKelvin = kelvin
            log("\(Lang.curColour) [\(kelvin)K / \(Self.format(mired))M]")
        } else {
            log("\(Lang.curColour) [rgb \(cacheR) \(cacheG) \(cacheB)]")
        }
        if stopped { log(Lang.alDisabled) }
    }

    static func format(_ number: Double) -> String { DeviceUpdate.format(number) }
}
