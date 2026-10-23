import Foundation
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import Homeswift
@testable import HomeswiftDolphinPoolCleaner

/// The Homebridge plugin's device and accessory tests.
@Suite(.timeLimit(.minutes(1)))
struct DeviceTests {
    let cloud = FakeCloud()
    let log = LogRecorder()

    func device(interval: Duration = .milliseconds(150), deviceType: Int = 62) -> DolphinDevice {
        DolphinDevice(serialNumber: "E3086OFG2M", name: "Pool", deviceType: deviceType, pollingInterval: interval, cloud: cloud, timing: .fast, logger: log.logger)
    }

    @Test func identityAndCatalog() async {
        let device = device()
        #expect(device.serialNumber == "E3086OFG2M")
        #expect(device.modelName == "Dolphin M400/M600")
        #expect(!device.features.hasTemperatureSensor)
        #expect(await device.state.connected == false)
        #expect(await device.state.isCleaning == false)
        #expect(log.contains(.info, "Device created: Pool (Dolphin M400/M600) - S/N: E3086OFG2M"))
    }

    // MARK: Polling

    @Test func pollingSkipsWhileShadowsArePushed() async {
        cloud.configure { $0.lastPush = .now + .seconds(3600) }
        let device = device()
        await device.start()
        #expect(cloud.count("shadow") == 1)  // the first read
        try? await Task.sleep(for: .milliseconds(400))
        #expect(cloud.count("shadow") == 1)
        #expect(log.contains(.debug, "Skipping poll for Pool"))
        await device.stop()
    }

    @Test func pollsWhenNothingWasPushed() async {
        let device = device()
        await device.start()
        #expect(await eventually { cloud.count("shadow") >= 2 })
        await device.stop()
    }

    @Test func pushedShadowUpdatesTheState() async {
        cloud.configure { $0.lastPush = .now + .seconds(3600) }
        let device = device()
        let changes = LockedValues<RobotState>()
        await device.setStateHandler { changes.append($0) }
        await device.start()
        let before = changes.values.count
        await cloud.push(["version": 42, "state": ["reported": ["systemState": ["pwsState": "on", "robotState": "cleaning"]]]])
        #expect(changes.values.count == before + 1)
        #expect(await device.state.isCleaning)
        await device.stop()
    }

    @Test func stoppingStopsListening() async {
        let device = device()
        await device.start()
        #expect(cloud.observerCount == 1)
        await device.stop()
        #expect(cloud.observerCount == 0)
    }

    @Test func sameVersionNotifiesOnce() async {
        cloud.configure { $0.shadow = ["version": 5, "state": ["reported": ["systemState": ["pwsState": "cleaning"]]]] }
        let device = device()
        let changes = LockedValues<RobotState>()
        await device.setStateHandler { changes.append($0) }
        await device.refreshState()
        await device.refreshState()
        #expect(changes.values.count == 1)
        #expect(await device.state.isCleaning)
    }

    @Test func noTemperatureWithoutASensor() async {
        let device = device()
        await device.apply(["version": 1, "state": ["reported": ["inwatTemperature": ["temperature": 24]]]])
        #expect(await device.state.temperature == nil)
    }

    // MARK: Commands

    @Test func setsTheModeThenStarts() async {
        let device = device()
        #expect(await device.startCleaning(mode: "floor"))
        #expect(cloud.calls == ["mode floor", "start E3086OFG2M"])
        #expect(await device.state.isCleaning)
        #expect(await device.state.cleaningMode == "floor")
        #expect(log.contains(.info, "Started cleaning for Pool (mode: floor)"))
    }

    @Test func regularIsAll() async {
        let device = device()
        _ = await device.startCleaning(mode: "regular")
        #expect(cloud.calls.first == "mode all")
    }

    @Test func queuedModeIsNotSentAgain() async {
        cloud.configure { $0.shadow = ["version": 1, "state": ["reported": ["nextCycleInfo": ["cleaningMode": ["mode": "floor"]]]]] }
        let device = device()
        await device.refreshState()
        _ = await device.startCleaning(mode: "floor")
        #expect(cloud.count("mode") == 0)
        #expect(cloud.count("start") == 1)
    }

    @Test func modeIsSentOnce() async {
        let device = device()
        _ = await device.startCleaning(mode: "wall")
        _ = await device.startCleaning(mode: "wall")
        #expect(cloud.count("mode") == 1)
    }

    @Test func startsWhenTheModeCannotBeSet() async {
        cloud.configure { $0.acceptsMode = false }
        let device = device()
        #expect(await device.startCleaning(mode: "floor"))
        #expect(cloud.count("start") == 1)
        #expect(log.contains(.warning, "Could not set cleaning mode floor"))
    }

    @Test func unknownModeStartsWithTheCurrentOne() async {
        let device = device()
        _ = await device.startCleaning(mode: "toString")
        #expect(cloud.count("mode") == 0)
        #expect(cloud.count("start") == 1)
        #expect(log.contains(.warning, "Unknown cleaning mode \"toString\""))
    }

    @Test func refusedStartChangesNothing() async {
        cloud.configure { $0.accepts = false }
        let device = device()
        #expect(await device.startCleaning(mode: "all") == false)
        #expect(await device.state.isCleaning == false)
    }

    @Test func oneRefreshAfterABurst() async {
        let device = device(interval: .seconds(3600))
        _ = await device.startCleaning(mode: "all")
        _ = await device.stopCleaning()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(cloud.count("shadow") == 1)
    }

    @Test func stoppingCancelsAPendingRefresh() async {
        let device = device(interval: .seconds(3600))
        _ = await device.stopCleaning()
        await device.stop()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(cloud.count("shadow") == 0)
    }

    @Test func setCleaningModeRejectsUnknownModes() async {
        let device = device()
        #expect(await device.setCleaningMode("turbo") == false)
        #expect(await device.setCleaningMode("cove"))
        #expect(cloud.count("mode") == 1)
        #expect(await device.state.cleaningMode == "cove")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AccessoryTests {
    let cloud = FakeCloud()
    let log = LogRecorder()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-dolphin-accessory-\(UUID().uuidString)/last-temperatures.json")
    var temperatures: PersistedDictionary<Double> { PersistedDictionary(url: file, autosave: nil) }

    /// A model with a temperature sensor, which the catalog does not list: the accessory tests need one.
    func device() -> DolphinDevice {
        DolphinDevice(serialNumber: "E3086OFG2M", name: "Dolphin M400", deviceType: 62, pollingInterval: .seconds(3600), cloud: cloud, timing: .fast, logger: log.logger)
    }

    func accessory(
        _ device: DolphinDevice, _ configuration: DolphinPoolCleanerPlugin.Configuration.Device? = nil, sensor: Bool = true,
        temperatures: PersistedDictionary<Double>? = nil
    ) async -> DolphinAccessory {
        let binding = await DolphinAccessory(
            device: device, accessoryName: "Pool Bot", configuration: configuration, idPrefix: "DolphinPoolCleaner",
            temperatures: temperatures ?? self.temperatures, timing: .fast, logger: log.logger, temperatureSensor: sensor)
        await device.setStateHandler { binding.handleStateChange($0) }
        return binding
    }

    @Test func servicesByDefault() async {
        let binding = await accessory(device())
        let accessory = binding.accessory
        #expect(accessory.id == "DolphinPoolCleaner:E3086OFG2M")
        #expect(accessory.category == .switch)
        #expect(accessory.name == "Pool Bot")
        #expect(accessory.information.characteristic(.manufacturer).value == .string("Maytronics"))
        #expect(accessory.information.characteristic(.model).value == .string("Dolphin M400/M600"))
        #expect(accessory.information.characteristic(.serialNumber).value == .string("E3086OFG2M"))
        #expect(accessory.service(.switch)?.characteristic(.configuredName).value == .string("Dolphin M400"))
        #expect(accessory.service(.temperatureSensor)?.characteristic(.name).value == .string("Dolphin M400 Water Temperature"))
        #expect(accessory.service(.filterMaintenance)?.characteristic(.name).value == .string("Dolphin M400 Filter"))
    }

    @Test func disabledSensorsAreLeftOut() async {
        let binding = await accessory(device(), .init(serialNumber: "E3086OFG2M", enableTemperature: false, enableFilterStatus: false))
        #expect(binding.accessory.service(.temperatureSensor) == nil)
        #expect(binding.accessory.service(.filterMaintenance) == nil)
    }

    @Test func noTemperatureSensorWithoutOne() async {
        let binding = await accessory(device(), sensor: false)
        #expect(binding.accessory.service(.temperatureSensor) == nil)
    }

    @Test func temperatureIsRemembered() async throws {
        let device = device()
        let temperatures = temperatures
        let binding = await accessory(device, temperatures: temperatures)
        binding.handleStateChange({ var state = RobotState(); state.temperature = 26; return state }())
        try temperatures.flush()
        #expect(self.temperatures["E3086OFG2M"] == 26)
        #expect(binding.temperatureService?.characteristic(.currentTemperature).value == .double(26))
        // Without a reading from the robot, the last one.
        #expect(try await binding.temperature() == 26)
    }

    @Test func noReadingIsAnError() async {
        let binding = await accessory(device())
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await binding.temperature() }
    }

    @Test func stateChangesReachHomeKit() async {
        let device = device()
        let binding = await accessory(device)
        await device.apply(["version": 1, "state": ["reported": ["systemState": ["pwsState": "cleaning"], "filterBagIndication": ["state": 95]]]])
        #expect(binding.switchService.characteristic(.on).value == .bool(true))
        #expect(binding.filterService?.characteristic(.filterChangeIndication).value == .int(1))
    }

    @Test func switchHoldsDuringTheGracePeriod() async throws {
        let device = device()
        let binding = await accessory(device)
        try await binding.switchService.characteristic(.on).write(.bool(true))
        // A stale shadow arrives before the robot reported the start.
        binding.handleStateChange(RobotState())
        #expect(binding.switchService.characteristic(.on).value == .bool(true))
    }

    @Test func startsInTheConfiguredMode() async throws {
        let device = device()
        let binding = await accessory(device, .init(serialNumber: "E3086OFG2M", cleaningMode: "floor"))
        try await binding.setOn(true)
        #expect(cloud.calls == ["mode floor", "start E3086OFG2M"])
    }

    @Test func startsInAllByDefault() async throws {
        let device = device()
        let binding = await accessory(device)
        try await binding.setOn(true)
        #expect(cloud.calls.first == "mode all")
    }

    @Test func noCommandWhenAlreadyThere() async throws {
        let binding = await accessory(device())
        try await binding.setOn(false)
        #expect(cloud.calls.isEmpty)
    }

    @Test func refusedCommandPutsTheSwitchBack() async {
        cloud.configure { $0.accepts = false }
        let binding = await accessory(device())
        await #expect(throws: HAPStatusError(.serviceCommunicationFailure)) { try await binding.switchService.characteristic(.on).write(.bool(true)) }
        #expect(binding.switchService.characteristic(.on).value == .bool(false))
        #expect(log.contains(.warning, "did not accept the start command"))
        // The grace period is over: the robot's state shows again.
        binding.handleStateChange({ var state = RobotState(); state.isCleaning = true; return state }())
        #expect(binding.switchService.characteristic(.on).value == .bool(true))
    }

    @Test func acceptedCommandLeavesTheSwitchOn() async throws {
        let binding = await accessory(device())
        try await binding.switchService.characteristic(.on).write(.bool(true))
        #expect(binding.switchService.characteristic(.on).value == .bool(true))
        #expect(log.warnings.isEmpty)
    }

    @Test func filterStatusReads() async throws {
        let device = device()
        let binding = await accessory(device)
        let read = try #require(binding.filterService?.characteristic(.filterChangeIndication).readHandler)
        #expect(try await read() == .int(0))
        await device.apply(["version": 2, "state": ["reported": ["filterBagIndication": ["state": 100]]]])
        #expect(try await read() == .int(1))
    }
}
