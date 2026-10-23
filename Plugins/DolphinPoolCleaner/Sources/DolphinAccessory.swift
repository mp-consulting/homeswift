import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// A robot in HomeKit: a switch that starts and stops cleaning, the water temperature on models with a
/// sensor, and the filter bag as a filter maintenance indicator. Each sensor can be turned off per robot.
final class DolphinAccessory: Sendable {
    let accessory: Accessory
    let switchService: Service
    let temperatureService: Service?
    let filterService: Service?
    private let device: DolphinDevice
    private let name: String
    private let cleaningMode: String
    /// The last water temperature of each robot, kept in the plugin's directory so HomeKit has a reading after
    /// a restart while the robot is out of the water.
    private let temperatures: PersistedDictionary<Double>
    private let gracePeriod: Duration
    private let logger: Logger
    /// When the last command was sent: switch updates from the robot are ignored for `gracePeriod` after it.
    private let lastCommand = NIOLockedValueBox<ContinuousClock.Instant?>(nil)

    /// `accessoryName` is the robot's name in the account (the accessory's), `device.name` the configured
    /// one (its services'). `temperatureSensor` overrides the catalog, for tests.
    init(
        device: DolphinDevice, accessoryName: String, configuration: DolphinPoolCleanerPlugin.Configuration.Device?, idPrefix: String,
        temperatures: PersistedDictionary<Double>, timing: DolphinTiming = .standard, logger: Logger, temperatureSensor: Bool? = nil
    ) async {
        let name = device.name
        let serialNumber = device.serialNumber
        let state = await device.state
        self.device = device
        self.name = name
        cleaningMode = configuration?.cleaningMode.nonEmpty ?? "all"
        self.temperatures = temperatures
        gracePeriod = timing.commandGracePeriod
        self.logger = logger

        let switchService = Service(
            .switch, name: name, subtype: "robot-switch", extra: [Characteristic(.configuredName, value: .string(name))], isPrimary: true)
        switchService.characteristic(.on).value = .bool(state.isCleaning)
        self.switchService = switchService

        if temperatureSensor ?? device.features.hasTemperatureSensor, configuration?.enableTemperature != false {
            let label = "\(name) Water Temperature"
            let service = Service(.temperatureSensor, name: label, subtype: "water-temperature", extra: [Characteristic(.configuredName, value: .string(label))])
            if let known = state.temperature ?? temperatures[serialNumber] {
                service.characteristic(.currentTemperature).value = .double(known)
            }
            temperatureService = service
        } else {
            temperatureService = nil
        }

        if configuration?.enableFilterStatus != false {
            let label = "\(name) Filter"
            let service = Service(.filterMaintenance, name: label, subtype: "filter-maintenance", extra: [Characteristic(.configuredName, value: .string(label))])
            service.characteristic(.filterChangeIndication).value = .int(Self.filterIndication(state.filterStatus))
            filterService = service
        } else {
            filterService = nil
        }

        accessory = Accessory(
            id: "\(idPrefix):\(serialNumber)", name: accessoryName, manufacturer: "Maytronics", model: device.modelName,
            serialNumber: serialNumber, firmwareRevision: "1.0.0", category: .switch,
            services: [switchService] + [temperatureService, filterService].compactMap { $0 })

        switchService.characteristic(.on)
            .onRead { [device] in .bool(await device.state.isCleaning) }
            .onWrite { [weak self] value in try await self?.setOn(value.boolValue == true) }
        temperatureService?.characteristic(.currentTemperature).onRead { [weak self] in
            guard let self else { throw HAPStatusError(.serviceCommunicationFailure) }
            return .double(try await self.temperature())
        }
        filterService?.characteristic(.filterChangeIndication).onRead { [device] in
            .int(Self.filterIndication(await device.state.filterStatus))
        }
        logger.debug("Accessory initialized: \(name)")
    }

    static func filterIndication(_ status: FilterStatus) -> Int { status == .needsCleaning ? 1 : 0 }

    /// The robot's state reached HomeKit: the switch (unless a command was just sent), the temperature and
    /// the filter.
    func handleStateChange(_ state: RobotState) {
        logger.debug("State change received: isCleaning=\(state.isCleaning), mode=\(state.cleaningMode), temp=\(state.temperature.map { "\($0)" } ?? "undefined")")
        let inGracePeriod = lastCommand.withLockedValue { $0.map { ContinuousClock.now - $0 < gracePeriod } ?? false }
        if !inGracePeriod {
            switchService.characteristic(.on).value = .bool(state.isCleaning)
        }
        if let temperature = state.temperature {
            // Remembered across restarts, so HomeKit can show the last reading.
            temperatures[device.serialNumber] = temperature
            temperatureService?.characteristic(.currentTemperature).value = .double(temperature)
        }
        filterService?.characteristic(.filterChangeIndication).value = .int(Self.filterIndication(state.filterStatus))
    }

    /// Starts or stops cleaning. A command the cloud does not take puts the switch back and fails the write.
    func setOn(_ on: Bool) async throws {
        let isCleaning = await device.state.isCleaning
        logger.debug("Set On: \(on) (current: \(isCleaning))")
        guard on != isCleaning else { return }
        lastCommand.withLockedValue { $0 = .now }
        let succeeded = on ? await device.startCleaning(mode: cleaningMode) : await device.stopCleaning()
        guard succeeded else {
            // The cloud can refuse a command (sustained throttling) without an error: the robot never got it.
            logger.warning("The MyDolphin cloud did not accept the \(on ? "start" : "stop") command for \(name)")
            lastCommand.withLockedValue { $0 = nil }
            switchService.characteristic(.on).value = .bool(!on)
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    /// The water temperature, or the last reading. Without either the read fails rather than inventing one.
    func temperature() async throws -> Double {
        guard let temperature = await device.state.temperature ?? temperatures[device.serialNumber] else {
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        logger.debug("Get Temperature: \(temperature)°C")
        return temperature
    }
}
