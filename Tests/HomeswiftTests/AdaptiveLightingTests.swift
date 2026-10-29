import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift

/// Vectors from HAP-NodeJS 2.2.2's AdaptiveLightingController (scratch script al.js): brightness iid 10, colour
/// temperature iid 11, a schedule that started ten minutes before `now` on a controller ten minutes behind.
@Suite(.timeLimit(.minutes(1)))
struct AdaptiveLightingTests {
    static let now = 1_700_000_000_000
    static let write = "AqkBpwEBCwIgARAPf1wmjI9NepuOPCodDp+LAghADDUIqAAAAAMCqrsDAQEFcwEVAQQAAAA/AgQAABZDAwEABASA7jYAAAABFQEEAACAPgIEAABIQwMEQHcbAAQBAAAAARgBBAAAAAACBAAAlkMDBIDuNgAEBEB3GwAAAAESAQQAAIC+AgQAAK9DAwQA3W0AAgEKAwwBBAoAAAACBGQAAAAGAmDqCATAJwkA"
    static let response = "AioBKAEBCwIgARAPf1wmjI9NepuOPCodDp+LAghADDUIqAAAAAMCqrsDAQA="
    static let readWrite = "AQMBAQs="
    static let readResponse = "AacBAQsCIAEQD39cJoyPTXqbjjwqHQ6fiwIIQAw1CKgAAAADAqq7AwEBBXMBEgEEAAAAPwIEAAAWQwMBAAQBAAAAARUBBAAAgD4CBAAASEMDBEB3GwAEAQAAAAEYAQQAAAAAAgQAAJZDAwSA7jYABARAdxsAAAABFQEEAACAvgIEAACvQwMEAN1tAAQBAAIBCgMMAQQKAAAAAgRkAAAABgJg6ggEwCcJAA=="
    static let controlValue = "ASgBAQsCIAEQD39cJoyPTXqbjjwqHQ6fiwIIQAw1CKgAAAADAqq7AwEA"
    static let serialized = #"{"activeTransition":{"iid":11,"transitionStartMillis":1699999400000,"timeMillisOffset":600000,"transitionId":"0f7f5c26-8c8f-4d7a-9b8e-3c2a1d0e9f8b","transitionStartBuffer":"400c3508a8000000","id3":"aabb","brightnessCharacteristicIID":10,"brightnessAdjustmentRange":{"minBrightnessValue":10,"maxBrightnessValue":100},"transitionCurve":[{"temperature":150,"brightnessAdjustmentFactor":0.5,"transitionTime":0,"duration":0},{"temperature":200,"brightnessAdjustmentFactor":0.25,"transitionTime":1800000,"duration":1800000},{"temperature":300,"brightnessAdjustmentFactor":0,"transitionTime":3600000},{"temperature":350,"brightnessAdjustmentFactor":-0.25,"transitionTime":7200000}],"updateInterval":60000,"notifyIntervalThreshold":600000}}"#

    final class Clock: @unchecked Sendable {
        let box = NIOLockedValueBox(AdaptiveLightingTests.now)
        var now: Int {
            get { box.withLockedValue { $0 } }
            set { box.withLockedValue { $0 = newValue } }
        }
    }

    static func lightbulb(hueAndSaturation: Bool = false) -> Service {
        let lightbulb = Service(
            .lightbulb, name: "Lamp", optional: [.brightness, .colorTemperature] + (hueAndSaturation ? [.hue, .saturation] : []))
        lightbulb.characteristic(.brightness).state.withLockedValue { $0.iid = 10 }
        lightbulb.characteristic(.colorTemperature).state.withLockedValue { $0.iid = 11 }
        return lightbulb
    }

    static func controller(_ lightbulb: Service, mode: AdaptiveLightingController.Mode, clock: Clock, shift: Int = 0) -> AdaptiveLightingController {
        AdaptiveLightingController(lightbulb, mode: mode, customTemperatureAdjustment: shift, logger: nil) { clock.now }
    }

    @Test func addsTheTransitionCharacteristicsAndDescribesThem() throws {
        let lightbulb = Self.lightbulb()
        let controller = Self.controller(lightbulb, mode: .manual, clock: Clock())
        #expect(lightbulb[.supportedCharacteristicValueTransitionConfiguration] != nil)
        #expect(lightbulb[.characteristicValueTransitionControl]?.value == .string(""))
        #expect(lightbulb[.characteristicValueActiveTransitionCount]?.value == .int(0))
        #expect(controller.supportedTransitionConfigurationTLV().base64EncodedString() == "AQYBAQoCAQEAAAEGAQELAgEC")
        #expect(controller.controllerID == "characteristic-transition-00000043-0000-1000-8000-0026BB765291")
    }

    @Test func manualModeTakesTheScheduleAndAnswersLikeHAPNodeJS() async throws {
        let lightbulb = Self.lightbulb()
        let clock = Clock()
        let controller = Self.controller(lightbulb, mode: .manual, clock: clock)
        let updates = NIOLockedValueBox<[AdaptiveLightingController.Update]>([])
        let saves = NIOLockedValueBox(0)
        controller.onUpdate { update in updates.withLockedValue { $0.append(update) } }
        controller.setupStateChangeDelegate { saves.withLockedValue { $0 += 1 } }

        // Through the characteristic, as a controller's write with "r": true: the response is the value.
        let control = try #require(lightbulb[.characteristicValueTransitionControl])
        let stored = try await control.write(.string(Self.write), origin: nil)
        #expect(stored == .string(Self.response))
        #expect(control.value == .string(Self.response))
        #expect(controller.isAdaptiveLightingActive)
        #expect(lightbulb[.characteristicValueActiveTransitionCount]?.value == .int(1))
        #expect(saves.withLockedValue { $0 } == 1)

        let expected = try JSONDecoder().decode([String: AdaptiveLightingController.Transition].self, from: Data(Self.serialized.utf8))["activeTransition"]
        #expect(controller.activeTransition == expected)
        let update = try #require(updates.withLockedValue { $0.first })
        #expect(update.transitionStartMillis == 1_699_999_400_000)
        #expect(update.timeMillisOffset == 600_000)
        #expect(update.transitionCurve.count == 4)
        #expect(update.notifyIntervalThreshold == 600_000)

        #expect(try controller.handleTransitionControlWrite(.string(Self.readWrite)) == Self.readResponse)
        #expect(controller.transitionControlResponse().base64EncodedString() == Self.controlValue)
        // A serialized state reads back the same.
        let restored = Self.controller(Self.lightbulb(), mode: .manual, clock: clock)
        try restored.deserialize(try #require(controller.serialize()))
        #expect(restored.activeTransition == expected)

        let disabled = NIOLockedValueBox(false)
        controller.onDisable { disabled.withLockedValue { $0 = true } }
        #expect(try controller.handleTransitionControlWrite(.string("AgUBAwEBCw==")) == "AgA=")
        #expect(disabled.withLockedValue { $0 })
        #expect(!controller.isAdaptiveLightingActive)
        #expect(lightbulb[.characteristicValueActiveTransitionCount]?.value == .int(0))
    }

    @Test func rejectsAnUnknownIIDAndTurnsOff() async throws {
        let lightbulb = Self.lightbulb()
        let controller = Self.controller(lightbulb, mode: .manual, clock: Clock())
        _ = try controller.handleTransitionControlWrite(.string(Self.write))
        let control = try #require(lightbulb[.characteristicValueTransitionControl])
        // Read the transition of iid 12, which is not the active one.
        let wrong = HAPTLV.encode((1, .data(HAPTLV.encode((1, .data(HAPTLV.variableUInt(12)))))))
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) {
            try await control.write(.string(wrong.base64EncodedString()), origin: nil)
        }
        #expect(!controller.isAdaptiveLightingActive)
    }

    /// Temperatures HAP-NodeJS computes for the same schedule (scratch script al2.js), minutes after the start.
    @Test(arguments: [
        (0, 50, 0, 175, 35.0, 4.0), (10, 50, 0, 188, 31, 7), (30, 50, 0, 213, 28, 13), (45, 100, 0, 225, 27, 16),
        (60, 5, 0, 203, 29, 11), (90, 50, 0, 256, 27, 22), (150, 50, 10, 319, 27, 34), (200, 70, 0, 322, 27, 34),
    ])
    func automaticModeFollowsTheCurve(minutes: Int, brightness: Int, shift: Int, temperature: Int, hue: Double, saturation: Double) async throws {
        let lightbulb = Self.lightbulb(hueAndSaturation: true)
        lightbulb.characteristic(.brightness).value = .int(brightness)
        let written = NIOLockedValueBox<[HAPValue]>([])
        lightbulb.characteristic(.colorTemperature).onWrite { value in written.withLockedValue { $0.append(value) } }
        let clock = Clock()
        let controller = Self.controller(lightbulb, mode: .automatic, clock: clock, shift: shift)
        // The clock first: restoring runs a step at once.
        clock.now = 1_699_999_400_000 + 600_000 + minutes * 60_000
        try controller.deserialize(Data(Self.serialized.utf8))
        await controller.scheduleNextUpdate(dryRun: true)
        #expect(written.withLockedValue { $0.last } == .int(temperature))
        #expect(lightbulb.characteristic(.colorTemperature).value == .int(temperature))
        #expect(lightbulb.characteristic(.hue).value == .double(hue))
        #expect(lightbulb.characteristic(.saturation).value == .double(saturation))
        controller.disableAdaptiveLighting()
    }

    @Test func automaticModeEndsWithTheCurveAndOnManualWrites() async throws {
        let lightbulb = Self.lightbulb(hueAndSaturation: true)
        lightbulb.characteristic(.brightness).value = .int(50)
        let clock = Clock()
        let controller = Self.controller(lightbulb, mode: .automatic, clock: clock)
        clock.now = 1_699_999_400_000 + 600_000 + 400 * 60_000
        try controller.deserialize(Data(Self.serialized.utf8))
        await controller.scheduleNextUpdate(dryRun: false)
        #expect(!controller.isAdaptiveLightingActive)

        clock.now = 1_699_999_400_000 + 600_000 + 30 * 60_000
        try controller.deserialize(Data(Self.serialized.utf8))
        await controller.scheduleNextUpdate(dryRun: true)
        #expect(controller.isAdaptiveLightingActive)
        // The controller's own writes do not count; a write from HomeKit does.
        lightbulb.characteristic(.hue).value = .double(120)
        #expect(controller.isAdaptiveLightingActive)
        try await lightbulb.characteristic(.hue).write(.double(120), origin: nil)
        #expect(!controller.isAdaptiveLightingActive)
    }

    /// A curve's temperature and factor `offset` milliseconds after its start, as `scheduleNextUpdate` computes them.
    static func value(_ curve: [AdaptiveLightingController.TransitionCurveEntry], at offset: Int) -> (Double, Double)? {
        var reached = 0
        for index in 0..<curve.count - 1 {
            let lower = curve[index], upper = curve[index + 1]
            reached += lower.transitionTime
            let hold = lower.duration ?? 0
            if offset <= reached + hold + upper.transitionTime, offset >= reached {
                if offset - reached <= hold { return (lower.temperature, lower.brightnessAdjustmentFactor) }
                let fraction = upper.transitionTime == 0 ? 1 : Double(offset - reached - hold) / Double(upper.transitionTime)
                return (lower.temperature + (upper.temperature - lower.temperature) * fraction,
                        lower.brightnessAdjustmentFactor + (upper.brightnessAdjustmentFactor - lower.brightnessAdjustmentFactor) * fraction)
            }
            reached += hold
        }
        return nil
    }

    /// A day's curve that ends where it begins (the Home app's) starts again at any time of day as the Home app
    /// sends it: the same id, the new start time, a curve that still covers a day and gives the same values at the
    /// same times, in a ramp or in a hold.
    @Test func rotatesADaysCurveToStartNow() throws {
        let hour = 3_600_000
        let curve: [AdaptiveLightingController.TransitionCurveEntry] = [
            .init(temperature: 360, brightnessAdjustmentFactor: -0.6, transitionTime: 0),
            .init(temperature: 350, brightnessAdjustmentFactor: -1.4, transitionTime: 4 * hour, duration: 2 * hour),
            .init(temperature: 500, brightnessAdjustmentFactor: -0.6, transitionTime: 8 * hour, duration: 3 * hour),
            .init(temperature: 360, brightnessAdjustmentFactor: -0.6, transitionTime: 7 * hour),
        ]
        let start = 1_700_000_000_000
        let transition = AdaptiveLightingController.Transition(
            iid: 11, transitionStartMillis: start, timeMillisOffset: 0, transitionId: "0f7f5c26-8c8f-4d7a-9b8e-3c2a1d0e9f8b",
            transitionStartBuffer: "00", id3: "aabb", brightnessCharacteristicIID: 10,
            brightnessAdjustmentRange: .init(minBrightnessValue: 10, maxBrightnessValue: 100), transitionCurve: curve,
            updateInterval: 60_000, notifyIntervalThreshold: 600_000)
        // Two days and some hours later: in the first ramp, in a hold, at a point, in the last ramp.
        for shift in [hour, 5 * hour, 4 * hour, 12 * hour + 30 * 60_000, 15 * hour, 23 * hour] {
            let now = start + 2 * AdaptiveLightingController.dayMillis + shift
            let rotated = try #require(AdaptiveLightingController.rotated(transition, toStartAt: now))
            #expect(rotated.transitionStartMillis == now)
            #expect(rotated.transitionId == transition.transitionId && rotated.id3 == "aabb")
            #expect(rotated.transitionStartBuffer == HAPTLV.hexString(HAPTLV.uint64(UInt64(now - AdaptiveLightingController.epoch2001Millis))))
            let length = rotated.transitionCurve.reduce(0) { $0 + $1.transitionTime + ($1.duration ?? 0) }
            #expect(length == AdaptiveLightingController.dayMillis)
            #expect(rotated.transitionCurve.first?.transitionTime == 0)
            for offset in stride(from: 0, through: AdaptiveLightingController.dayMillis, by: 15 * 60_000) {
                let original = try #require(Self.value(curve, at: (shift + offset) % AdaptiveLightingController.dayMillis))
                let moved = try #require(Self.value(rotated.transitionCurve, at: offset))
                #expect(abs(original.0 - moved.0) < 1e-9 && abs(original.1 - moved.1) < 1e-9, "shift \(shift) offset \(offset)")
            }
        }
    }

    /// Off, the last schedule stays (saved too) and resumes starting now, at the point for this time of day; at a
    /// time a curve shorter than a day does not reach, it does not.
    @Test func resumesTheLastScheduleStartingNow() async throws {
        let lightbulb = Self.lightbulb(hueAndSaturation: true)
        lightbulb.characteristic(.brightness).value = .int(50)
        lightbulb.characteristic(.colorTemperature).onWrite { _ in }
        let clock = Clock()
        let controller = Self.controller(lightbulb, mode: .automatic, clock: clock)
        #expect(lightbulb.adaptiveLighting === controller)
        #expect(!controller.canResumeAdaptiveLighting)
        #expect(!controller.resumeAdaptiveLighting())

        let start = 1_699_999_400_000 + 600_000
        clock.now = start + 30 * 60_000
        try controller.deserialize(Data(Self.serialized.utf8))
        controller.disableAdaptiveLighting()
        #expect(controller.canResumeAdaptiveLighting)
        // Saved while off, the schedule is kept for later.
        let restored = Self.controller(Self.lightbulb(), mode: .automatic, clock: clock)
        try restored.deserialize(try #require(controller.serialize()))
        #expect(!restored.isAdaptiveLightingActive)
        #expect(restored.canResumeAdaptiveLighting)

        // Three days later, five hours in: past the four hours of the curve.
        clock.now = start + 3 * 86_400_000 + 5 * 3_600_000
        #expect(!controller.resumeAdaptiveLighting())
        // Three days later, thirty minutes in: the temperature of thirty minutes in, and a save.
        clock.now = start + 3 * 86_400_000 + 30 * 60_000
        let saves = NIOLockedValueBox(0)
        controller.setupStateChangeDelegate { saves.withLockedValue { $0 += 1 } }
        #expect(controller.resumeAdaptiveLighting())
        #expect(controller.isAdaptiveLightingActive)
        #expect(!controller.canResumeAdaptiveLighting)
        #expect(controller.timeOffset == 600_000)
        #expect(controller.startTimeOfTransition == clock.now - 600_000)
        #expect(lightbulb[.characteristicValueActiveTransitionCount]?.value == .int(1))
        #expect(saves.withLockedValue { $0 } == 1)
        await controller.scheduleNextUpdate(dryRun: true)
        #expect(lightbulb.characteristic(.colorTemperature).value == .int(213))
        controller.disableAdaptiveLighting()
    }

    @Test func colorUtilsMatchesTheLookupTable() {
        #expect(ColorUtils.colorTemperatureToHueAndSaturation(140) == (hue: 237, saturation: 6))
        #expect(ColorUtils.colorTemperatureToHueAndSaturation(500) == (hue: 28, saturation: 64))
        #expect(ColorUtils.colorTemperatureToHueAndSaturation(50) == (hue: 222, saturation: 19))
        #expect(ColorUtils.colorTemperatureToHueAndSaturation(153.5, rounded: false) == (hue: 283.6, saturation: 2.8))
    }
}
