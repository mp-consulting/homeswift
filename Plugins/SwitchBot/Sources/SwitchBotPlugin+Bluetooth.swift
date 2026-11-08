import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// How a device is reached (`connectionType`, docs/clean-room/SwitchBotBLE.md §1): `BLE` over Bluetooth only, `OpenAPI`
/// over the cloud only, `BLE/OpenAPI` over Bluetooth with the cloud as its fallback, `Disabled` not at all.
struct Route: Sendable {
    var bluetooth: BLEDevice?
    var cloud: Bool
    var reason = ""

    var usable: Bool { bluetooth != nil || cloud }
}

/// What a poll over Bluetooth decided.
enum BluetoothPoll {
    case next(Duration)
    case stop
    /// Bluetooth did not answer: the cloud's status, when the device has the cloud.
    case cloud
}

extension SwitchBotPlugin {
    /// The device's `connectionType`: the block's, else 5.x's `connectionPreference` (`ble`, `openapi`, `auto`), else
    /// `OpenAPI` with a token and `BLE` without.
    func connectionType(_ options: DeviceOptions) -> String {
        if let type = options.string("connectionType") { return type }
        if let preference = options.string("connectionPreference")?.lowercased(),
           let type = ["ble": "BLE", "openapi": "OpenAPI", "auto": "BLE/OpenAPI"][preference] {
            return type
        }
        return keys == nil ? "BLE" : "OpenAPI"
    }

    func route(_ info: DeviceInfo) -> Route {
        let connection = connectionType(info.options)
        if info.isRemote {
            return connection == "OpenAPI" ? Route(cloud: true) : Route(cloud: false, reason: "its connectionType is \(connection)")
        }
        if connection == "Disabled" { return Route(cloud: false, reason: "its connectionType is Disabled") }
        let served = info.options.bool("enableCloudService") != false
        let cloudReason = keys == nil ? "there is no OpenAPI token" : "Cloud Services is off for it in the SwitchBot app"
        var route = Route(cloud: (connection == "OpenAPI" || connection == "BLE/OpenAPI") && served && keys != nil)
        guard connection == "BLE" || connection == "BLE/OpenAPI" else {
            if !route.cloud { route.reason = cloudReason }
            return route
        }
        switch bleDevice(info) {
        case .success(let device):
            route.bluetooth = device
        case .failure(let problem):
            if connection == "BLE" {
                // A configuration error, logged once; the cloud takes the device when it can (§10).
                route.cloud = served && keys != nil
                if bluetoothWarned.insert(info.deviceID).inserted {
                    logger.warning("\(info.type) \(info.name): \(problem)\(route.cloud ? "; using the cloud" : "")")
                }
            } else if bluetoothWarned.insert(info.deviceID).inserted {
                logger.debug("\(info.type) \(info.name): \(problem); using the cloud")
            }
            if !route.cloud { route.reason = "\(problem), and \(cloudReason)" }
        }
        return route
    }

    struct BluetoothProblem: Error, CustomStringConvertible {
        var description: String
    }

    /// What a device reached over Bluetooth asks Setup for: a lock's key, a Bot's password; nil for one that asks nothing
    /// or is not reached over Bluetooth.
    func bluetoothSecretKind(_ info: DeviceInfo) -> BluetoothSecrets.Kind? {
        guard !info.isRemote, ["BLE", "BLE/OpenAPI"].contains(connectionType(info.options)),
              configuration.enableBLE != false, !info.options.flag("disablePlatformBLE"),
              let model = BLEModel(deviceType: info.type) else { return nil }
        return Self.secretKind(model)
    }

    /// A device's key and key id: Setup's, in the vault, else its options' (`encryptionKey`, `encryptionKeyId` or
    /// `keyId`). Throws for a key or key id of the wrong form; nil when there is none.
    func bluetoothKey(_ info: DeviceInfo) throws(BluetoothProblem) -> BLEKey? {
        let stored = context.credentials(for: info.deviceID, as: BluetoothSecrets.self)
        let keyText: String?, keyID: String?
        if let key = stored?.encryptionKey, let id = stored?.encryptionKeyId {
            (keyText, keyID) = (key, id)
        } else {
            (keyText, keyID) = (info.options.string("encryptionKey"), info.options.string("encryptionKeyId", "keyId"))
        }
        guard keyText != nil || keyID != nil else { return nil }
        guard let keyText, let keyID, let parsed = BLEKey(key: keyText, id: keyID) else {
            throw BluetoothProblem(description: "its encryption key must be 32 hex digits and its key id 2")
        }
        return parsed
    }

    /// A Bot's password: Setup's, in the vault (none when Setup was given none), else its options' `botPassword`.
    func botPassword(_ info: DeviceInfo) -> String? {
        if let stored = context.credentials(for: info.deviceID, as: BluetoothSecrets.self) { return stored.botPassword }
        return info.options.string("botPassword")
    }

    /// The device on Bluetooth, from its options: its model (a type the spec pins), its MAC (`customBLEaddress`, else the
    /// cloud's id), its key (a lock needs it, `bluetoothKey`), a Bot's password (`botPassword`) and `maxRetry`.
    func bleDevice(_ info: DeviceInfo) -> Result<BLEDevice, BluetoothProblem> {
        let options = info.options
        if configuration.enableBLE == false || options.flag("disablePlatformBLE") {
            return .failure(BluetoothProblem(description: "Bluetooth is turned off (enableBLE, disablePlatformBLE)"))
        }
        guard let model = BLEModel(deviceType: info.type) else {
            return .failure(BluetoothProblem(description: "a \(info.type) is not reachable over Bluetooth by this plugin"))
        }
        let address = options.string("customBLEaddress") ?? info.id
        guard let mac = bluetoothMAC(address) else {
            return .failure(BluetoothProblem(description: "its Bluetooth address is not a MAC address (customBLEaddress)"))
        }
        let key: BLEKey?
        do {
            key = try bluetoothKey(info)
        } catch {
            return .failure(error)
        }
        if model.isLock && key == nil {
            return .failure(BluetoothProblem(description: "a lock needs its encryption key and key id from the SwitchBot app (Setup, Set up again)"))
        }
        var password: String?
        if model == .bot, let text = botPassword(info) {
            guard validBotPassword(text) else { return .failure(BluetoothProblem(description: "its Bot password must be 4 letters or digits")) }
            password = text
        }
        let attempts = min(max(Int(saturating: options.number("maxRetry") ?? 5) ?? 5, 1), 10)
        return .success(BLEDevice(name: info.name, model: model, mac: mac, key: key, password: password, attempts: attempts))
    }

    /// Without a token: the block's devices that name their type (`configDeviceType`), as the cloud would list them (§4.3).
    func localDeviceList() -> DeviceList? {
        let devices: [[String: JSONValue]] = (configuration.deviceEntries ?? []).compactMap { entry in
            guard let id = entry.deviceID, let type = entry.string("configDeviceType") else { return nil }
            return ["deviceId": .string(id), "deviceType": .string(type), "deviceName": .string(entry.string("configDeviceName") ?? id)]
        }
        return devices.isEmpty ? nil : DeviceList(devices: devices)
    }

    /// Opens the shared adapter and starts the scan, the first time a device needs Bluetooth.
    func openBluetooth() async {
        guard !bluetoothTried else { return }
        bluetoothTried = true
        let central: (any BLECentral)?
        do {
            central = try dependencies.bleCentral(logger)
        } catch {
            logger.warning("[BLE] disabled: \(Bluetooth.isMissing(error) ? "no Bluetooth adapter on this system" : "\(error)")")
            return
        }
        guard let central else {
            logger.warning("[BLE] disabled: this process may not use Bluetooth")
            return
        }
        let client = SwitchBotBluetooth(central: central, logger: logger, timing: dependencies.bleTiming)
        do {
            try await client.startScanning { [weak self] reading in
                Task { await self?.handle(reading) }
            }
        } catch {
            logger.warning("[BLE] disabled: could not scan: \(error)")
            return
        }
        bluetooth = client
        logger.info("[BLE] scanning for SwitchBot devices")
    }

    /// An advertisement of a device on Bluetooth: shown as its status, and a Lock's new sequence number reads its info.
    func handle(_ reading: BLEReading) {
        guard let mac = reading.mac, let deviceID = byMAC[mac], let entry = entries[deviceID], let ble = entry.ble,
              ble.model.family == reading.model.family else { return }
        markUnreachable(deviceID, false)
        if failing.remove(deviceID) != nil { entry.accessory.logger.info("\(entry.info.type) \(entry.info.name) advertises again") }
        if !reading.status.isEmpty { show(reading.status, on: entry, webhook: false) }
        if let sequence = reading.sequence {
            let previous = sequences.updateValue(sequence, forKey: mac)
            // The Lock's advertised state is not trusted (§3.7): its connected info read is.
            if ble.model == .lock, previous != nil, previous != sequence, !entry.accessory.isWriting {
                startPolling(deviceID, after: .zero)
            }
        }
    }

    /// Sends commands over Bluetooth: true when the device took them, false when it refused one (logged); nil when the
    /// cloud should send them instead (Bluetooth failed, or cannot carry them, and the device has the cloud). Throws
    /// when nothing reaches the device.
    func sendOverBluetooth(_ commands: [Command], entry: Entry) async throws -> Bool? {
        guard let ble = entry.ble else { return nil }
        let info = entry.info, logger = entry.accessory.logger
        let cloudAvailable = entry.cloud && client != nil
        guard let bluetooth else {
            if cloudAvailable { return nil }
            throw HAPStatusError(.serviceCommunicationFailure)
        }
        do {
            let brightness = (entry.accessory as? LightAccessory)?.lightbulb.characteristic(.brightness).value.intValue ?? 100
            let requests = try commands.map {
                try BLEFrames.request(for: $0, model: ble.model, password: ble.password, brightness: brightness, cloudAvailable: cloudAvailable)
            }
            _ = try await bluetooth.send(requests, to: ble)
            markUnreachable(info.deviceID, false)
            logger.debug("\(info.type) \(info.name): sent \(commands.map(\.description).joined(separator: ", ")) over Bluetooth")
            // A read shortly after, to show what the device did (a lock's info, a light's colour).
            if ble.model.hasRead { startPolling(info.deviceID, after: scaled(2)) }
            return true
        } catch {
            // A Bot asking for its password, or refusing the one given: Setup asks for it.
            if ble.model == .bot, let status = error as? BLEStatus, status.code == 0x07 || status.code == 0x09 {
                botPasswordRefused.insert(info.deviceID)
            }
            if cloudAvailable {
                logger.debug("\(info.type) \(info.name): Bluetooth failed (\(error)); sending through the cloud")
                return nil
            }
            logger.error("\(info.type) \(info.name): \(commands.map(\.description).joined(separator: ", ")) failed over Bluetooth: \(error)")
            if error is BLEStatus { return false }
            markUnreachable(info.deviceID, true)
            throw HAPStatusError(.serviceCommunicationFailure)
        }
    }

    /// A poll of a device on Bluetooth: a connected read where its type has one, else whether it advertised within its
    /// interval. A device with the cloud falls back to it when Bluetooth does not answer.
    func pollOverBluetooth(_ entry: Entry) async -> BluetoothPoll {
        guard let ble = entry.ble else { return .cloud }
        let deviceID = entry.info.deviceID
        guard let bluetooth else { return entry.cloud ? .cloud : .next(entry.interval) }
        if ble.model.hasRead {
            if await refreshOverBluetooth(deviceID) { return entry.blePolling ? .next(entry.bleInterval) : .stop }
            return entry.cloud ? .cloud : (entry.blePolling ? .next(entry.bleInterval) : .stop)
        }
        if await bluetooth.heard(ble.mac, within: entry.interval) { return .next(entry.interval) }
        if entry.cloud { return .cloud }
        if failing.insert(deviceID).inserted {
            entry.accessory.logger.error("\(entry.info.type) \(entry.info.name): not heard over Bluetooth for \(entry.interval)")
        }
        markUnreachable(deviceID, true)
        return .next(entry.interval)
    }

    /// The connected read of a device's state, shown; false when Bluetooth did not answer.
    @discardableResult
    func refreshOverBluetooth(_ deviceID: String) async -> Bool {
        guard let entry = entries[deviceID], let ble = entry.ble, let bluetooth, let request = BLEFrames.read(ble.model) else { return false }
        let logger = entry.accessory.logger
        do {
            let exchanges = try await bluetooth.send([request], to: ble)
            if let reply = exchanges.first?.reply, let status = BLEFrames.status(ofReply: reply, to: request, model: ble.model),
               let current = entries[deviceID] {
                show(status, on: current, webhook: false)
            }
            markUnreachable(deviceID, false)
            if failing.remove(deviceID) != nil { logger.info("\(entry.info.type) \(entry.info.name) answers over Bluetooth again") }
            return true
        } catch {
            if failing.insert(deviceID).inserted { logger.error("\(entry.info.type) \(entry.info.name): Bluetooth: \(error)") }
            if !entry.cloud { markUnreachable(deviceID, true) }
            return false
        }
    }
}
