import Foundation
import HomeswiftPlugin
import Testing

@testable import HomeswiftDolphinPoolCleaner

/// The Homebridge plugin's parser tests, with its fixtures.
@Suite struct ShadowParserTests {
    func fixture(_ text: String) throws -> JSONValue { try JSONValue(string: text) }

    @Test func idleRobot() throws {
        let state = ShadowParser.parse(try fixture(Fixtures.idleShadow))
        #expect(state.connected)
        #expect(!state.isCleaning)
        #expect(state.cleaningMode == "all")
        #expect(state.nextCycleMode == "all")
        #expect(state.cycleTime == 150)
        #expect(state.filterStatus == .ok)
    }

    @Test func cleaningRobotWithAFullFilter() throws {
        let state = ShadowParser.parse(try fixture(Fixtures.cleaningShadow))
        #expect(state.isCleaning)
        #expect(state.filterStatus == .needsCleaning)
    }

    @Test func errorFromAnEarlierSessionIsIgnored() throws {
        // The fixture's robotError has turnOnCount 645, the robot is on its 656th run.
        let state = ShadowParser.parse(try fixture(Fixtures.cleaningShadow))
        #expect(state.faultCode == nil)
    }

    @Test func partialPushKeepsTheFilterStatus() {
        let full = ShadowParser.parse(["version": 1, "state": ["reported": ["filterBagIndication": ["state": 95]]]])
        let afterPush = ShadowParser.parse(["version": 2, "state": ["reported": ["inwatTemperature": ["temperature": 24]]]], existing: full)
        #expect(afterPush.filterStatus == .needsCleaning)
        #expect(afterPush.temperature == 24)
    }

    @Test func desiredOnlyDocumentChangesNothing() {
        var existing = RobotState()
        existing.isCleaning = true
        existing.filterStatus = .needsCleaning
        let state = ShadowParser.parse(["version": 9, "state": ["desired": ["systemState": ["pwsState": "off"]]]], existing: existing)
        #expect(state == existing)
    }

    @Test func invalidInputGivesTheDefaults() {
        #expect(ShadowParser.parse(nil) == RobotState())
        #expect(ShadowParser.parse("garbage") == RobotState())
    }

    @Test func recentCycleIsCleaning() {
        let now = Date(timeIntervalSince1970: 1_767_268_800)  // 2026-01-01T12:00:00Z
        let startedTenMinutesAgo = now.timeIntervalSince1970 - 600
        let state = ShadowParser.parse(
            ["state": ["reported": ["cycleInfo": ["cycleStartTimeUTC": .number(startedTenMinutesAgo), "cleaningMode": ["cycleTime": 120]]]]], now: now)
        #expect(state.isCleaning)
        #expect(abs(state.cycleTimeRemaining - 110) < 0.01)
        #expect(state.cycleStartTime == Date(timeIntervalSince1970: startedTenMinutesAgo))
    }

    @Test func legacyBLEFormat() {
        let state = ShadowParser.parse(["state": ["reported": ["mu_state": 3, "cleaning_mode": 2, "temperature": 255, "filter_state": 1, "faults": "04", "is_smart": true]]])
        #expect(state.isCleaning)
        #expect(state.muState == RobotStates.cleaning)
        #expect(state.isSmartMode == true)
        #expect(ShadowParser.parse(["state": ["reported": ["mu_state": 6]]]).muState == RobotStates.endOfCycle)
        #expect(ShadowParser.parse(["state": ["reported": [:]]]).muState == RobotStates.off)
        #expect(ShadowParser.parse(["state": ["reported": [:]]]).isSmartMode == nil)
        #expect(state.cleaningMode == "floor")
        #expect(state.temperature == 25.5)
        #expect(state.filterStatus == .needsCleaning)
        #expect(state.faultCode == 4)
        #expect(state.faultDescription == "Filter blocked")
    }

    @Test func legacyCycleInfoGivesTheTimeRemaining() {
        let state = ShadowParser.parse(["state": ["reported": ["cycle_info": "001E0000"]]])
        #expect(state.cycleTimeRemaining == 90)
    }

    @Test func otherFormats() {
        let state = ShadowParser.parse(["state": ["reported": [
            "robotState": ["isOn": true, "pwsState": "holdWeekly"], "led": ["ledEnable": true, "ledIntensity": 80],
            "weeklyTimer": ["enabled": true], "delayedOperation": ["enabled": true, "time": ["hours": 1, "minutes": 30]],
            "cycleInfo": ["cycleTimeRemaining": ["hours": 1, "minutes": 5]],
        ]]])
        #expect(state.isCleaning)
        #expect(state.pwsState == PWSStates.idle)
        #expect(state.ledEnabled == true)
        #expect(state.ledIntensity == 80)
        #expect(state.weeklyEnabled == true)
        #expect(state.delayEnabled == true)
        #expect(state.delayTime == 90)
        #expect(state.cycleTimeRemaining == 65)
    }

    @Test func powerSupplyStatesComeFirst() {
        let idle = ShadowParser.parse(["state": ["reported": ["systemState": ["pwsState": "idle"]]]])
        #expect(!idle.isCleaning)
        #expect(idle.pwsState == PWSStates.idle)
        let cleaning = ShadowParser.parse(["state": ["reported": ["systemState": ["pwsState": "cleaning"]]]])
        #expect(cleaning.isCleaning)
        #expect(cleaning.pwsState == PWSStates.cleaning)
        let finished = ShadowParser.parse(["state": ["reported": ["systemState": ["pwsState": "on", "robotState": "finished"]]]])
        #expect(!finished.isCleaning)
    }

    @Test(arguments: [
        (JSONValue.string("regular"), "all"), (.string("Standard"), "all"), (.string("fast"), "short"), (.string("walls"), "wall"),
        (.string("waterline"), "water"), (.string("cove"), "cove"), (.number(7), "spot"), (.number(99), "all"), (.null, "all"),
    ])
    func cleaningModes(input: JSONValue, expected: String) {
        #expect(ShadowParser.cleaningMode(input.nonNull) == expected)
    }

    /// Numbers far outside Int's range clamp instead of trapping; sums that overflow are ignored.
    @Test func hugeNumbers() {
        let state = ShadowParser.parse(["version": 1e300, "state": ["reported": [
            "mu_state": 1e300, "sm_state": -1e300, "cleaning_mode": 1e300,
            "cycleInfo": ["cycleTimeRemaining": ["hours": 1e308, "minutes": 1]],
            "delayedOperation": ["time": ["hours": -1e308, "minutes": 1]],
            "robotError": ["errorCode": 1e300, "turnOnCount": 1e300], "systemState": ["rTurnOnCount": 1e300],
        ]]])
        #expect(!state.isCleaning)
        #expect(state.pwsState == Int.min)
        #expect(state.cleaningMode == "all")
        #expect(state.cycleTimeRemaining.isFinite)
        #expect(state.delayTime == nil)
        #expect(state.faultCode == Int.max)
        #expect(ShadowParser.version(of: ["version": 1e300]) == Int.max)
        #expect(ShadowParser.cleaningMode(.number(-1e300)) == "all")
    }

    @Test func versions() {
        #expect(ShadowParser.version(of: ["version": 4]) == 4)
        #expect(ShadowParser.version(of: [:]) == nil)
        #expect(ShadowParser.version(of: nil) == nil)
    }
}

@Suite struct FilterParserTests {
    @Test(arguments: [
        (["state": 81], .needsCleaning), (["state": 80], .ok), (["filterState": "Dirty"], .needsCleaning),
        (["filterState": "clean"], .ok), (["filterLevel": 2], .needsCleaning), (["filterLevel": 0], .ok), ([:], .ok),
    ] as [(JSONValue, FilterStatus)])
    func status(data: JSONValue, expected: FilterStatus) {
        #expect(FilterParser.status(bag: data, indicator: nil) == expected)
    }

    @Test func noFilterDataIsNoStatus() {
        #expect(FilterParser.status(bag: nil, indicator: nil) == nil)
    }

    @Test func fallsBackToTheIndicator() {
        #expect(FilterParser.status(bag: nil, indicator: ["filterState": "full"]) == .needsCleaning)
    }

    @Test func legacyNumber() {
        #expect(FilterParser.legacyStatus(nil) == .ok)
        #expect(FilterParser.legacyStatus(0) == .ok)
        #expect(FilterParser.legacyStatus(3) == .needsCleaning)
    }
}

@Suite struct FaultParserTests {
    @Test func noErrorCodes() {
        #expect([0, 255, 65535, nil].map(FaultParser.isRealErrorCode) == [false, false, false, false])
        #expect(FaultParser.isRealErrorCode(2))
    }

    @Test func currentSessionOnly() {
        #expect(FaultParser.isCurrentSessionError(10, 10))
        #expect(!FaultParser.isCurrentSessionError(9, 10))
        #expect(FaultParser.isCurrentSessionError(nil, 10))
        #expect(FaultParser.isCurrentSessionError(65535, 10))
    }

    @Test func robotErrorBeforeThePowerSupply() {
        let fault = FaultParser.all(
            robotError: ["errorCode": 2, "turnOnCount": 10], pwsError: ["errorCode": 6, "turnOnCount": 10], faultCodes: nil, systemState: ["rTurnOnCount": 10])
        #expect(fault?.code == 2)
        #expect(fault?.description == "Robot out of water")
    }

    @Test func staleRobotErrorWhileThePowerSupplyIsInError() {
        let fault = FaultParser.all(robotError: ["errorCode": 1, "turnOnCount": 3], pwsError: nil, faultCodes: nil, systemState: ["rTurnOnCount": 10, "pwsState": "error"])
        #expect(fault?.code == 1)
    }

    @Test func powerSupplyThenLegacyCodes() {
        #expect(FaultParser.all(robotError: nil, pwsError: ["errorCode": 6], faultCodes: nil, systemState: nil)?.description == "Overheating")
        let legacy = FaultParser.all(robotError: nil, pwsError: nil, faultCodes: ["faultCode": 42, "faultDescription": "Custom"], systemState: nil)
        #expect(legacy?.code == 42)
        #expect(legacy?.description == "Custom")
        #expect(FaultParser.all(robotError: nil, pwsError: nil, faultCodes: nil, systemState: nil) == nil)
    }

    @Test func legacyHexString() {
        #expect(FaultParser.hexString("00") == nil)
        #expect(FaultParser.hexString("99")?.description == "Unknown fault (153)")
        #expect(FaultParser.hexString(nil) == nil)
    }
}

@Suite struct CatalogTests {
    @Test func knownAndUnknownTypes() {
        #expect(DeviceCatalog.features(deviceType: 62).hasLEDControl)
        // Not all M400/M600 have a temperature sensor, so the catalog leaves it off.
        #expect(!DeviceCatalog.features(deviceType: 62).hasTemperatureSensor)
        #expect(DeviceCatalog.features(deviceType: 62).supportedCleaningModes.contains("regular"))
        #expect(DeviceCatalog.features(deviceType: 99999) == DeviceCatalog.baseFeatures)
        #expect(DeviceCatalog.modelName(deviceType: 62).contains("Dolphin"))
        #expect(DeviceCatalog.modelName(deviceType: 99999) == "Unknown Dolphin (Type 99999)")
        #expect(DeviceCatalog.modelName(deviceType: 62) != DeviceCatalog.modelName(deviceType: 60))
        #expect(DeviceCatalog.isSupported(deviceType: 65))
        #expect(!DeviceCatalog.isSupported(deviceType: 1))
        #expect(DeviceCatalog.supportedDeviceTypes == [60, 61, 62, 65])
    }

    @Test func constants() {
        #expect(Maytronics.iotEndpoints[Maytronics.defaultIoTRegion]?.contains(".iot.eu-west-1.amazonaws.com") == true)
        #expect(Maytronics.iotEndpoints["eu-central-1"]?.contains(".iot.eu-central-1.amazonaws.com") == true)
        #expect(Maytronics.iotEndpoints["us-east-2"]?.contains(".iot.us-east-2.amazonaws.com") == true)
        #expect(Maytronics.userAgent.contains("MyDolphin"))
        #expect(CleaningMode.all["all"]?.name == "All Surfaces")
        #expect(CleaningMode.all["short"]?.name == "Fast Mode")
        #expect(CleaningMode.all.values.allSatisfy { $0.duration > 0 })
    }

    @Test(arguments: [("all", "all"), ("regular", "all"), ("Fast", "short"), ("tictac", "tictac"), ("turbo", nil), ("constructor", nil)] as [(String, String?)])
    func resolveCleaningMode(input: String, expected: String?) {
        #expect(DolphinDevice.resolveCleaningMode(input) == expected)
    }
}
