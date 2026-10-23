import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// The HomeKit accessory of one Daikin device: an air conditioner (its climate control) or an Altherma heat
/// pump (its climate control and hot water tank), with the information the gateway reports.
final class DaikinAccessory: @unchecked Sendable {
    let device: DaikinCloudDevice
    let profile: DeviceProfile
    let accessory: Accessory
    let climateControl: ClimateControlService?
    let hotWaterTank: HotWaterTankService?

    enum BuildError: Error, CustomStringConvertible {
        case unsupported(String)
        var description: String {
            switch self {
            case .unsupported(let model): "Unsupported device type: \(model). Device has no climate control management point."
            }
        }
    }

    /// The name the Onecta app shows: the climate control's name, else the model.
    static func displayName(_ device: DaikinCloudDevice) -> String {
        let climate = device.managementPointID(type: "climateControl") ?? "climateControl"
        if let name = device.data(climate, "name").string, !name.isEmpty { return name }
        return device.deviceModel
    }

    static func id(_ device: DaikinCloudDevice) -> String { "\(DaikinCloudPlugin.platform):\(device.id)" }

    /// Builds the accessory; `previous` keeps the separate Fan tile as it was first built.
    init(device: DaikinCloudDevice, context: ServiceContext, previous: DaikinAccessory? = nil) throws {
        self.device = device
        profile = DeviceProfile.match(device)
        let name = Self.displayName(device)
        let logger = context.logger
        let gateway = Self.managementPoint(device, type: "gateway", logger: logger)
        let model = gateway.flatMap { device.data($0, "modelInfo").string }.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown"
        let serial = gateway.map { device.data($0, "serialNumber").string.flatMap { $0.isEmpty ? nil : $0 } ?? "NOT_AVAILABLE" } ?? "NOT_AVAILABLE"
        // Daikin writes versions as 4_0_3; HomeKit wants dotted revisions.
        let firmware = gateway.flatMap { device.data($0, "firmwareVersion").string }.flatMap { $0.isEmpty ? nil : $0 }?.replacingOccurrences(of: "_", with: ".") ?? "0.0.0"
        // The raw Daikin id is what excludedDevicesByDeviceId takes, so the log shows it.
        logger.info("[Platform] Device found with id: \(device.id)")
        logger.info("[Platform]     id: \(device.id)")
        logger.info("[Platform]     name: \(name)")
        logger.info("[Platform]     last updated: \(device.lastUpdated)")
        logger.info("[Platform]     modelInfo: \(model)")
        logger.info("[Platform]     deviceModel: \(device.deviceModel)")
        logger.debug("[AccessoryFactory] Creating accessory for device type: \(profile.rawValue), model: \(device.deviceModel), display name: \(profile.displayName)")

        let climateID = Self.managementPoint(device, type: "climateControl", logger: logger)
        var services: [Service] = []
        switch profile {
        case .altherma:
            if let climateID {
                climateControl = ClimateControlService(device: device, managementPointID: climateID, name: name, context: context, separateFanShape: previous?.climateControl?.separateFanShape)
            } else {
                logger.warning("[\(name)] No climate control management point found")
                climateControl = nil
            }
            if let tankID = Self.managementPoint(device, type: "domesticHotWaterTank", logger: logger) {
                hotWaterTank = HotWaterTankService(device: device, managementPointID: tankID, accessoryName: name, context: context)
            } else {
                logger.warning("[\(name)] No domestic hot water tank management point found")
                hotWaterTank = nil
            }
        case .airConditioning, .unknown:
            // Unknown devices with a climate control are run as air conditioners.
            guard let climateID else { throw BuildError.unsupported(device.deviceModel) }
            climateControl = ClimateControlService(device: device, managementPointID: climateID, name: name, context: context, separateFanShape: previous?.climateControl?.separateFanShape)
            hotWaterTank = nil
        }
        if let climateControl {
            logger.info("[Platform]     capabilities: \(climateControl.features.capabilities.summary)")
            logger.debug("[Platform]     operation modes: \(climateControl.features.capabilities.supportedOperationModes.joined(separator: ", "))")
            services += climateControl.services
        }
        if let hotWaterTank { services += hotWaterTank.services }
        accessory = Accessory(
            id: Self.id(device), name: name, manufacturer: "Daikin", model: model, serialNumber: serial, firmwareRevision: firmware,
            category: profile == .altherma ? .thermostat : .airConditioner, services: services)
    }

    /// Pushes the device's state to HomeKit.
    func refreshValues() {
        climateControl?.refreshValues()
        hotWaterTank?.refreshValues()
    }

    /// The operation mode changed in a way RotationSpeed must follow (it appears, goes, or changes step).
    var needsRebuild: Bool { climateControl?.needsRebuild ?? false }

    /// The first management point of a type; a second one is logged, as the Homebridge plugin asks.
    static func managementPoint(_ device: DaikinCloudDevice, type: String, logger: Logger) -> String? {
        let ids = device.managementPointIDs(type: type)
        guard let first = ids.first else {
            logger.error("[Platform] No management point found for managementPointType \(type)")
            return nil
        }
        if ids.count >= 2 {
            logger.warning("[Platform] Found more than one management point for managementPointType \(type), using first one. Please open an issue on https://github.com/mp-consulting/homebridge-daikin-cloud/issues")
        }
        return first
    }
}
