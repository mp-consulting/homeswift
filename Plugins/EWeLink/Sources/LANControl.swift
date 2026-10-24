import Crypto
import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import _CryptoExtras

/// A device reachable on the LAN (eWeLink's "LAN mode", the DIY firmware API).
struct LANDevice: Sendable, Equatable {
    var deviceID: String
    var ip: String
    var port: Int
    /// The device wants AES-128-CBC payloads keyed with MD5 of its device key.
    var encrypt: Bool
    var iv: String?
    var deviceKey: String?
}

/// What LAN control needs from the network; tests replace it.
protocol LANNetwork: Sendable {
    /// `_ewelink._tcp` services as they come and go.
    func browse(logger: Logger) -> AsyncStream<LANServiceEvent>
    /// Datagrams to a UDP port, with the sender's address.
    func listen(port: Int, logger: Logger) async throws -> any LANDatagramListener
    /// POSTs JSON and returns the body.
    func post(_ url: URL, body: Data, timeout: Int) async throws -> Data
}

enum LANServiceEvent: Sendable, Equatable {
    case found(name: String, addresses: [String], port: Int, txt: [String: String])
    case lost(name: String)
}

protocol LANDatagramListener: Sendable {
    var datagrams: AsyncStream<(data: Data, address: String)> { get }
    func close() async
}

/// LAN control: finds devices over mDNS (`_ewelink._tcp`, which mDNS proxies and reflectors carry across
/// VLANs), listens for the updates devices send to UDP port 8082, and sends commands to
/// `http://<ip>:<port>/zeroconf/switch`, encrypted for devices that announce `encrypt=true`.
///
/// A device whose commands fail three times in a row, or whose service goes away, is skipped for a minute so
/// commands go straight to the cloud.
actor LANControl {
    struct Dependencies: Sendable {
        var network: any LANNetwork
        var clock: EWeLinkClock
    }

    private let dependencies: Dependencies
    private let logger: Logger
    private let selfAPIKey: @Sendable () async -> String
    /// The name and device key of a device in the platform's cache.
    private let deviceInfo: @Sendable (String) async -> (name: String, deviceKey: String?)?
    /// Every device id in the platform's cache with its name, for the discovery report.
    private let knownDevices: @Sendable () async -> [(id: String, name: String)]
    private let onUpdate: @Sendable (String, DeviceParams) async -> Void

    private(set) var devices: [String: LANDevice] = [:]
    private var failureCounts: [String: Int] = [:]
    private var cooldownUntil: [String: Double] = [:]
    /// Devices that announced `encrypt=true`: an announcement without it later is not believed, since anyone on
    /// the LAN can announce a device's name, and plaintext would open its updates to spoofing.
    private var announcedEncrypted: Set<String> = []
    private var running = false
    private var browser: Task<Void, Never>?
    private var listener: (any LANDatagramListener)?
    private var udpTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?

    init(
        dependencies: Dependencies, logger: Logger, selfAPIKey: @escaping @Sendable () async -> String,
        deviceInfo: @escaping @Sendable (String) async -> (name: String, deviceKey: String?)?,
        knownDevices: @escaping @Sendable () async -> [(id: String, name: String)],
        onUpdate: @escaping @Sendable (String, DeviceParams) async -> Void
    ) {
        self.dependencies = dependencies
        self.logger = logger
        self.selfAPIKey = selfAPIKey
        self.deviceInfo = deviceInfo
        self.knownDevices = knownDevices
        self.onUpdate = onUpdate
    }

    private func name(_ deviceID: String) async -> String { await deviceInfo(deviceID)?.name ?? deviceID }

    /// Registers a device at the address the cloud gave, before mDNS finds it. An entry that exists keeps its
    /// address and `encrypt` flag (mDNS is authoritative) but gets a device key it did not have.
    func registerDevice(_ deviceID: String, ip: String, port: Int, deviceKey: String, encrypt: Bool = true) async {
        guard !ip.isEmpty, port != 0 else { return }
        if var existing = devices[deviceID] {
            if (existing.deviceKey ?? "").isEmpty, !deviceKey.isEmpty {
                existing.deviceKey = deviceKey
                devices[deviceID] = existing
                let display = await name(deviceID)
                logger.debug("[LAN] Filled missing device key for \(display)")
            }
            return
        }
        devices[deviceID] = LANDevice(deviceID: deviceID, ip: ip, port: port, encrypt: encrypt, deviceKey: deviceKey)
        let display = await name(deviceID)
        logger.debug("[LAN] Registered \(display) at \(ip):\(port) from API")
    }

    func start() async {
        guard !running else { return }
        running = true
        logger.info("Starting LAN control (mDNS discovery)...")
        let events = dependencies.network.browse(logger: logger)
        browser = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        logger.debug("[LAN] Bonjour browser started for _ewelink._tcp services")
        await startUDPListener()
        // `stop()` ran while the socket opened.
        guard running else { return }
        logger.info("LAN control started - listening for device announcements")
        let clock = dependencies.clock
        reportTask = Task { [weak self] in
            do { try await clock.sleep(milliseconds: Double(Timing.lanDiscoveryReport)) } catch { return }
            await self?.logDiscoveryStatus()
        }
    }

    func stop() async {
        running = false
        browser?.cancel()
        browser = nil
        reportTask?.cancel()
        reportTask = nil
        udpTask?.cancel()
        udpTask = nil
        await listener?.close()
        listener = nil
        devices.removeAll()
        failureCounts.removeAll()
        cooldownUntil.removeAll()
        announcedEncrypted.removeAll()
        logger.debug("LAN control stopped")
    }

    private func logDiscoveryStatus() async {
        if devices.isEmpty {
            logger.warning("LAN discovery: No devices found via mDNS after 10 seconds. This is normal if your devices don't support LAN mode or are on a different network segment. Commands will use cloud (WebSocket) instead.")
            return
        }
        logger.info("LAN discovery: Found \(devices.count) device(s) available for local control")
        for (deviceID, device) in devices.sorted(by: { $0.key < $1.key }) {
            let display = await name(deviceID)
            logger.info("  - \(display) at \(device.ip):\(device.port)")
        }
        let missing = await knownDevices().filter { devices[$0.id] == nil }.map(\.name)
        if !missing.isEmpty {
            logger.debug("Devices NOT available via LAN (will use cloud): \(missing.joined(separator: ", "))")
        }
    }

    /// `eWeLink_1001edbf36` is device `1001edbf36`.
    static func deviceID(fromServiceName name: String) -> String? {
        guard let range = name.range(of: "eWeLink_[0-9a-fA-F]+", options: .regularExpression) else { return nil }
        return String(name[range].dropFirst("eWeLink_".count))
    }

    func handle(_ event: LANServiceEvent) async {
        switch event {
        case .found(let serviceName, let addresses, let port, let txt):
            guard let deviceID = Self.deviceID(fromServiceName: serviceName) else {
                logger.debug("[LAN] Ignoring service without device ID: \(serviceName)")
                return
            }
            guard let ip = addresses.first(where: { !$0.contains(":") }) ?? addresses.first else {
                logger.debug("[LAN] No IP address for device \(deviceID)")
                return
            }
            let port = port == 0 ? Timing.lanHTTPPort : port
            var encrypt = txt["encrypt"] == "true"
            if encrypt {
                announcedEncrypted.insert(deviceID)
            } else if announcedEncrypted.contains(deviceID) {
                logger.debug("[LAN] \(serviceName) announced without encryption after announcing it: kept encrypted")
                encrypt = true
            }
            let info = await deviceInfo(deviceID)
            // The device announced itself: LAN is worth trying again.
            resetHealth(deviceID)
            if var existing = devices[deviceID], existing.ip == ip, existing.port == port {
                if (existing.deviceKey ?? "").isEmpty, let key = info?.deviceKey, !key.isEmpty {
                    existing.deviceKey = key
                    devices[deviceID] = existing
                }
                return
            }
            let key = info?.deviceKey.flatMap { $0.isEmpty ? nil : $0 } ?? devices[deviceID]?.deviceKey
            devices[deviceID] = LANDevice(deviceID: deviceID, ip: ip, port: port, encrypt: encrypt, iv: txt["iv"], deviceKey: key)
            logger.debug("[LAN] Discovered device: \(info?.name ?? deviceID) at \(ip):\(port)")
        case .lost(let serviceName):
            guard let deviceID = Self.deviceID(fromServiceName: serviceName) else { return }
            let display = await name(deviceID)
            logger.debug("[LAN] Device went offline: \(display)")
            // It may still answer: keep the entry, skip it until it is announced again.
            startCooldown(deviceID, reason: "mDNS down event")
        }
    }

    private func startUDPListener() async {
        do {
            let listener = try await dependencies.network.listen(port: Timing.lanUDPPort, logger: logger)
            guard running else { return await listener.close() }
            self.listener = listener
            udpTask = Task { [weak self] in
                for await datagram in listener.datagrams {
                    await self?.handleDatagram(datagram.data, from: datagram.address)
                }
            }
            logger.debug("UDP listener started on port \(Timing.lanUDPPort)")
        } catch {
            // LAN control works without it.
            logger.error("Failed to start UDP listener: \(error)")
        }
    }

    /// An `update` a device sent over UDP. An encrypted device's update must decrypt with its key, which
    /// authenticates its content (from any address); a plaintext update counts only from the known address.
    /// A datagram never moves the address commands go to: anyone on the LAN can replay a captured encrypted
    /// update from another host, so the address comes from mDNS (which a device announces again when its
    /// address changes) and the cloud.
    func handleDatagram(_ data: Data, from address: String) async {
        guard let message = try? JSONValue(data: data) else {
            logger.debug("Error parsing UDP message")
            return
        }
        guard let deviceID = message["deviceid"]?.stringValue, message["action"]?.stringValue == "update", let device = devices[deviceID] else { return }
        var params = message["params"]?.objectValue
        if device.encrypt {
            let key = await resolveDeviceKey(deviceID)
            guard message["encrypt"]?.boolValue == true, let key else {
                logger.debug("[LAN] Dropping unencrypted UDP update for encrypted device \(deviceID)")
                return
            }
            guard let payload = message["data"]?.stringValue, let iv = message["iv"]?.stringValue,
                let decrypted = Self.decrypt(payload, deviceKey: key, iv: iv)
            else {
                logger.debug("[LAN] Dropping UDP update for \(deviceID): decryption failed")
                return
            }
            params = decrypted
            if let known = devices[deviceID]?.ip, known != address {
                logger.debug("[LAN] Encrypted UDP update for \(deviceID) from \(address), not its address \(known): commands still go to \(known)")
            }
        } else if !device.ip.isEmpty, address != device.ip {
            logger.debug("[LAN] Ignoring UDP update for \(deviceID) from unexpected address \(address)")
            return
        }
        guard let params else { return }
        resetHealth(deviceID)
        await onUpdate(deviceID, params)
    }

    /// Sends a command; false when the device is not on the LAN, in cooldown, its key is unknown, or the
    /// command failed (the dispatcher then uses the cloud).
    func sendCommand(_ deviceID: String, params: DeviceParams) async -> Bool {
        let parent = DeviceLimits.parentDeviceID(deviceID)
        let display = await deviceInfo(parent)?.name ?? deviceID
        guard let device = devices[parent] else {
            logger.debug("[\(display)] Not available via LAN, falling back to cloud")
            return false
        }
        if isInCooldown(parent) {
            logger.debug("[\(display)] LAN in cooldown after recent failures, using cloud")
            return false
        }
        let key = await resolveDeviceKey(parent)
        if device.encrypt, key == nil {
            logger.debug("[\(display)] No device key for encrypted LAN control yet, using cloud")
            return false
        }
        logger.debug("[\(display)] Sending command via LAN to \(device.ip):\(device.port)")
        var latest = device
        latest.deviceKey = key
        let payload = Self.payload(for: latest, params: params, sequence: dependencies.clock.nowMilliseconds.rounded(.down).jsDescription, selfAPIKey: await selfAPIKey())
        guard let url = URL(string: "http://\(device.ip):\(device.port)/zeroconf/switch") else { return false }
        do {
            let body = try await dependencies.network.post(url, body: payload.encoded(), timeout: Timing.lanRequest)
            let response = try? JSONValue(data: body)
            if response?["error"]?.jsNumber == 0 {
                logger.debug("[\(display)] LAN command successful")
                resetHealth(parent)
                return true
            }
            if let code = response?["error"] {
                logger.debug("[\(display)] LAN command failed with error code: \(code.jsString ?? "\(code)")")
            } else {
                logger.debug("[\(display)] LAN command failed: no response")
            }
        } catch {
            logger.debug("[\(display)] LAN command failed: \(error), falling back to cloud")
        }
        recordFailure(parent)
        return false
    }

    /// The device key, filled lazily from the platform's cache when the entry was made before the cloud login.
    private func resolveDeviceKey(_ deviceID: String) async -> String? {
        guard var device = devices[deviceID] else { return nil }
        if (device.deviceKey ?? "").isEmpty, let key = await deviceInfo(deviceID)?.deviceKey, !key.isEmpty {
            device = devices[deviceID] ?? device
            device.deviceKey = key
            devices[deviceID] = device
        }
        return devices[deviceID]?.deviceKey.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func recordFailure(_ deviceID: String) {
        let failures = (failureCounts[deviceID] ?? 0) + 1
        if failures >= Timing.lanMaxConsecutiveFailures {
            startCooldown(deviceID, reason: "\(failures) consecutive failures")
        } else {
            failureCounts[deviceID] = failures
        }
    }

    private func startCooldown(_ deviceID: String, reason: String) {
        failureCounts[deviceID] = nil
        cooldownUntil[deviceID] = dependencies.clock.nowMilliseconds + Double(Timing.lanCooldown)
        logger.debug("[LAN] \(deviceID) unavailable (\(reason)), using cloud for \(Timing.lanCooldown / 1000)s")
    }

    private func resetHealth(_ deviceID: String) {
        failureCounts[deviceID] = nil
        cooldownUntil[deviceID] = nil
    }

    func isInCooldown(_ deviceID: String) -> Bool {
        guard let until = cooldownUntil[deviceID] else { return false }
        if dependencies.clock.nowMilliseconds >= until {
            cooldownUntil[deviceID] = nil
            return false
        }
        return true
    }

    func lanDevice(_ deviceID: String) -> LANDevice? { devices[deviceID] }
    func isDeviceAvailable(_ deviceID: String) -> Bool { devices[deviceID] != nil }

    // MARK: Payloads

    /// The request body: the parameters in clear, or encrypted with a fresh IV.
    static func payload(for device: LANDevice, params: DeviceParams, sequence: String, selfAPIKey: String) -> JSONValue {
        if device.encrypt, let key = device.deviceKey, !key.isEmpty {
            let iv = Secrets.randomBytes(16)
            if let data = encrypt(params, deviceKey: key, iv: iv) {
                return [
                    "sequence": .string(sequence), "deviceid": .string(device.deviceID), "selfApikey": .string(selfAPIKey),
                    "iv": .string(iv.base64EncodedString()), "encrypt": true, "data": .string(data),
                ]
            }
        }
        return ["sequence": .string(sequence), "deviceid": .string(device.deviceID), "selfApikey": .string(selfAPIKey), "data": .object(params)]
    }

    /// AES-128-CBC with PKCS#7 padding, keyed with MD5 of the device key; base64.
    static func encrypt(_ params: DeviceParams, deviceKey: String, iv: Data) -> String? {
        let key = SymmetricKey(data: Data(Insecure.MD5.hash(data: Data(deviceKey.utf8))))
        guard let vector = try? AES._CBC.IV(ivBytes: iv),
            let sealed = try? AES._CBC.encrypt(JSONValue.object(params).encoded(), using: key, iv: vector)
        else { return nil }
        return sealed.base64EncodedString()
    }

    static func decrypt(_ data: String, deviceKey: String, iv: String) -> DeviceParams? {
        let key = SymmetricKey(data: Data(Insecure.MD5.hash(data: Data(deviceKey.utf8))))
        guard let ciphertext = lenientBase64Decode(data), let ivBytes = lenientBase64Decode(iv), let vector = try? AES._CBC.IV(ivBytes: ivBytes),
            let plaintext = try? AES._CBC.decrypt(ciphertext, using: key, iv: vector)
        else { return nil }
        return (try? JSONValue(data: plaintext))?.objectValue
    }
}
