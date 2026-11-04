import Foundation
import Homeswift
import HomeswiftPlugin

/// What a motion or doorbell trigger answered: the HTTP API's body (section 6).
struct TriggerResult: Sendable, Equatable {
    var error: Bool
    var message: String
    /// Only for a motion trigger that switched motion on: whether a timer was already running.
    var cooldownActive: Bool?

    static func failure(_ message: String) -> TriggerResult { TriggerResult(error: true, message: message) }

    /// The JSON body, its keys in the original's order.
    var json: String {
        var text = #"{"error":\#(error),"message":\#(JSONValue.string(message).text())"#
        if let cooldownActive { text += #","cooldownActive":\#(cooldownActive)"# }
        return text + "}"
    }

}

/// A camera's motion sensor, doorbell and trigger switches, with their two timers (sections 6.1 to 6.3).
actor CameraTriggers {
    let log: CameraLog
    /// `motionTimeout`, nil when absent.
    let motionTimeout: Int?
    let motionDoorbell: Bool
    /// Multiplies the timers (tests shorten them).
    let timeScale: Double
    let motionSensor: Service?
    let motionSwitch: Service?
    let doorbell: Service?
    let doorbellSwitch: Service?

    private var motionTimer: Task<Void, Never>?
    private var doorbellTimer: Task<Void, Never>?
    private var motionGeneration = 0
    private var doorbellGeneration = 0

    init(log: CameraLog, motionTimeout: Int?, motionDoorbell: Bool, timeScale: Double,
         motionSensor: Service?, motionSwitch: Service?, doorbell: Service?, doorbellSwitch: Service?) {
        self.log = log
        self.motionTimeout = motionTimeout
        self.motionDoorbell = motionDoorbell
        self.timeScale = timeScale
        self.motionSensor = motionSensor
        self.motionSwitch = motionSwitch
        self.doorbell = doorbell
        self.doorbellSwitch = doorbellSwitch
    }

    /// Motion on or off; `minimumTimeout` is 1 for the trigger switch (it always resets) and 0 for MQTT and HTTP.
    @discardableResult
    func motion(_ active: Bool, minimumTimeout: Int) -> TriggerResult {
        guard let motionSensor else { return .failure("Motion is not enabled for this camera.") }
        log.debug("Switch motion detect \(active ? "on" : "off").")
        let hadTimer = motionTimer != nil
        motionTimer?.cancel()
        motionTimer = nil
        motionGeneration += 1
        guard active else {
            setMotion(false, on: motionSensor)
            if motionDoorbell { doorbell(false) }
            return TriggerResult(error: false, message: "Motion switched off.")
        }
        setMotion(true, on: motionSensor)
        if !hadTimer, motionDoorbell { doorbell(true) }
        let timeout = max(motionTimeout ?? 1, minimumTimeout)
        if timeout > 0 {
            let generation = motionGeneration
            motionTimer = Task { [weak self, timeScale] in
                guard (try? await Task.sleep(for: .seconds(timeout) * timeScale)) != nil else { return }
                await self?.motionExpired(generation)
            }
        }
        return TriggerResult(error: false, message: "Motion switched on.", cooldownActive: hadTimer)
    }

    private func setMotion(_ detected: Bool, on sensor: Service) {
        sensor.characteristic(.motionDetected).value = .bool(detected)
        motionSwitch?.characteristic(.on).value = .bool(detected)
    }

    private func motionExpired(_ generation: Int) {
        guard generation == motionGeneration, let motionSensor else { return }
        motionTimer = nil
        log.debug("Motion handler timeout.")
        setMotion(false, on: motionSensor)
    }

    /// Rings the doorbell, or turns its trigger switch off.
    @discardableResult
    func doorbell(_ active: Bool = true) -> TriggerResult {
        guard let doorbell else { return .failure("Doorbell is not enabled for this camera.") }
        log.debug("Switch doorbell \(active ? "on" : "off").")
        doorbellTimer?.cancel()
        doorbellTimer = nil
        doorbellGeneration += 1
        guard active else {
            doorbellSwitch?.characteristic(.on).value = .bool(false)
            return TriggerResult(error: false, message: "Doorbell switched off.")
        }
        doorbell.characteristic(.programmableSwitchEvent).sendEvent(.int(HAPConstants.ProgrammableSwitchEvent.singlePress))
        if let doorbellSwitch {
            doorbellSwitch.characteristic(.on).value = .bool(true)
            let timeout = max(motionTimeout ?? 1, 1)
            let generation = doorbellGeneration
            doorbellTimer = Task { [weak self, timeScale] in
                guard (try? await Task.sleep(for: .seconds(timeout) * timeScale)) != nil else { return }
                await self?.doorbellExpired(generation)
            }
        }
        return TriggerResult(error: false, message: "Doorbell switched on.")
    }

    private func doorbellExpired(_ generation: Int) {
        guard generation == doorbellGeneration else { return }
        doorbellTimer = nil
        log.debug("Doorbell handler timeout.")
        doorbellSwitch?.characteristic(.on).value = .bool(false)
    }

    /// Cancels the timers: the plugin is stopping.
    func cancel() {
        motionTimer?.cancel()
        doorbellTimer?.cancel()
        motionTimer = nil
        doorbellTimer = nil
        motionGeneration += 1
        doorbellGeneration += 1
    }
}
extension TriggerResult: Error {}
