import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// A device that answered a LAN scan, or one config.json gives an address.
struct LANDevice: Sendable, Equatable {
    var device: String
    var ip: String
    var sku: String?
    /// Configured with `customIPAddress` and not heard from yet.
    var isPendingDiscovery = false
    /// Configured with `customIPAddress`: its address never moves.
    var isManual = false
}

/// The UDP sockets of Govee's LAN API: scans go to 239.255.255.250:4001, devices answer on 4002 (scans and
/// status), commands go to the device's port 4003.
protocol LANSocket: Sendable {
    /// Datagrams received on port 4002, with their source address.
    var datagrams: AsyncStream<(data: Data, address: String)> { get }
    func send(_ data: Data, to host: String, port: Int) async throws
    func close() async
}

/// Govee's LAN control (`connection/lan.ts`). Discovery is unauthenticated, so the client trusts only a
/// packet's source address, takes private addresses only, and tracks 256 devices at most.
actor LANClient {
    static let multicastAddress = "239.255.255.250"
    static let scanPort = 4001
    static let receiverPort = 4002
    static let devicePort = 4003
    static let scanSettleTime: Duration = .milliseconds(2000)
    /// A scan ends after this however many replies keep coming (anyone on the LAN can send them).
    static let scanMaximumTime: Duration = .seconds(10)
    static let maximumDevices = 256
    static let maximumLoggedLength = 200

    private(set) var devices: [LANDevice] = []
    private let socket: any LANSocket
    private let logger: Logger
    private let debug: DebugLog
    private let receive: @Sendable (_ deviceId: String, _ data: JSONValue, _ ip: String) async -> Void
    private var latestScanReply = ContinuousClock.now
    private var tasks: [Task<Void, Never>] = []

    init(
        socket: any LANSocket, customAddresses: [String: String], logger: Logger, debug: DebugLog,
        receive: @escaping @Sendable (_ deviceId: String, _ data: JSONValue, _ ip: String) async -> Void
    ) {
        self.socket = socket
        self.logger = logger
        self.debug = debug
        self.receive = receive
        for (device, ip) in customAddresses.sorted(by: { $0.key < $1.key }) {
            devices.append(LANDevice(device: device, ip: ip, isPendingDiscovery: true, isManual: true))
        }
    }

    /// Starts reading the socket.
    func start() {
        let datagrams = socket.datagrams
        tasks.append(Task { [weak self] in
            for await datagram in datagrams { await self?.handle(datagram.data, from: datagram.address) }
        })
    }

    /// Scans, and returns the devices once none has answered for two seconds, or after ten seconds.
    func discover() async -> [LANDevice] {
        await sendScan()
        latestScanReply = .now
        let end = ContinuousClock.now + Self.scanMaximumTime
        // Each reply moves the deadline on, up to the end.
        while true {
            let deadline = min(latestScanReply + Self.scanSettleTime, end)
            guard ContinuousClock.now < deadline else { break }
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { break }
        }
        return devices
    }

    static func isLocalIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil && (0...255).contains($0!) }) else { return false }
        let a = parts[0]!, b = parts[1]!
        return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
    }

    static func isDeviceId(_ id: String) -> Bool {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        return (6...8).contains(parts.count) && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
    }

    private func truncate(_ text: String) -> String {
        text.count > Self.maximumLoggedLength ? String(text.prefix(Self.maximumLoggedLength)) + "..." : text
    }

    func handle(_ data: Data, from address: String) async {
        let text = String(decoding: data, as: UTF8.self)
        guard let message = try? JSONValue(data: data) else {
            debug("[LAN] \(Lang.lanParseError) [\(truncate(text))].")
            return
        }
        guard let command = message["msg"]?["cmd"]?.stringValue, let payload = message["msg"]?["data"], payload.objectValue != nil else {
            debug("[LAN] Ignoring malformed message: \(truncate(text))")
            return
        }
        switch command {
        case "scan":
            await handleScanReply(payload, address: address, text: text)
        case "devStatus":
            if let found = devices.first(where: { $0.ip == address }) {
                await receive(found.device, payload, address)
            } else {
                debug("[LAN] \(Lang.lanUnkDevice) [\(address)].")
            }
        default:
            break
        }
    }

    private func handleScanReply(_ data: JSONValue, address: String, text: String) async {
        latestScanReply = .now
        // Commands go to, and status replies are matched by, the packet's real source address.
        guard let deviceId = data["device"]?.stringValue, Self.isDeviceId(deviceId) else {
            debug("[LAN] Ignoring scan reply with invalid device id: \(truncate(text))")
            return
        }
        let sku = data["sku"]?.stringValue
        guard let index = devices.firstIndex(where: { $0.device == deviceId }) else {
            guard Self.isLocalIPv4(address), devices.count < Self.maximumDevices else {
                debug("[LAN] Ignoring scan reply from \(address): \(truncate(text))")
                return
            }
            debug("[LAN] \(Lang.lanFoundDevice) [isNew=true,isManual=false] [\(truncate(text))] [\(address)].")
            devices.append(LANDevice(device: deviceId, ip: address, sku: sku))
            await receive(deviceId, .object([:]), address)
            return
        }
        let existing = devices[index]
        if existing.isPendingDiscovery {
            // A configured device: keep its address, and record that it answered.
            devices[index] = LANDevice(device: deviceId, ip: existing.ip, sku: sku, isManual: true)
            debug("[LAN] \(Lang.lanFoundDevice) [isNew=true,isManual=true] [\(truncate(text))] [\(address)].")
            await receive(deviceId, .object([:]), existing.ip)
        } else if !existing.isManual, existing.ip != address, Self.isLocalIPv4(address) {
            // A discovered device that moved (a new DHCP lease).
            debug("[LAN] \(Lang.lanFoundDevice) [\(existing.ip) -> \(address)].")
            devices[index].ip = address
            devices[index].sku = sku ?? existing.sku
            await receive(deviceId, .object([:]), address)
        } else {
            debug("[LAN] \(Lang.lanFoundDevice) [isNew=false] [\(truncate(text))] [\(address)].")
        }
    }

    func sendScan() async {
        let scan: JSONValue = ["msg": ["cmd": "scan", "data": ["account_topic": "reserve"]]]
        debug("[LAN] scanning for devices over LAN...")
        do {
            try await socket.send(scan.encoded(), to: Self.multicastAddress, port: Self.scanPort)
        } catch {
            debug.warn("[LAN] scan request failed: \(error).")
        }
    }

    func requestStatus(_ device: LANDevice) async throws {
        let request: JSONValue = ["msg": ["cmd": "devStatus", "data": [:]]]
        try await socket.send(request.encoded(), to: device.ip, port: Self.devicePort)
    }

    /// Sends a command to the device at its known address. A device that fails is forgotten until it
    /// answers a scan again, unless it is configured.
    func updateDevice(id: String, params: LANParams, log: DeviceLog) async throws {
        let message: JSONValue = ["msg": ["cmd": .string(params.cmd), "data": params.data]]
        log.debug("[LAN] \(Lang.sendingUpdate) [\(message.text())]")
        guard let found = devices.first(where: { $0.device == id }) else { throw GoveeAPIError.message(Lang.lanDevNotFound) }
        do {
            try await socket.send(message.encoded(), to: found.ip, port: Self.devicePort)
            log.debug("[LAN] \(Lang.lanCmdSent) \(found.ip)")
        } catch {
            if !found.isManual {
                devices.removeAll { $0.device == id }
                log.debugWarn("[LAN] \(Lang.lanDevRemoved)")
            }
            throw error
        }
    }

    /// Scans every `scanInterval` and asks each device for its status every `refreshInterval`.
    func startPolling(scanInterval: Duration, refreshInterval: Duration) {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: scanInterval)
                guard !Task.isCancelled else { return }
                await self?.sendScan()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: refreshInterval)
                guard !Task.isCancelled, let self else { return }
                await self.pollStatus()
            }
        })
    }

    private func pollStatus() async {
        for device in devices {
            do {
                try await requestStatus(device)
            } catch {
                logger.warning("[\(device.device)] [LAN] \(Lang.lanReqError) \(error).")
            }
        }
    }

    func close() async {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        await socket.close()
    }
}

/// The real sockets: a receiver bound to port 4002 that joined the multicast group, and a sender on an ephemeral
/// port.
struct UDPLANSocket: LANSocket {
    let receiver: UDPSocket
    let sender: UDPSocket

    /// Binds the sockets. Throws when port 4002 is taken (another Govee bridge on this machine).
    static func bind(logger: Logger) async throws -> UDPLANSocket {
        let receiver = try await UDPSocket.bind(port: LANClient.receiverPort, reuseAddress: true, multicastGroup: LANClient.multicastAddress)
        let sender: UDPSocket
        do {
            sender = try await UDPSocket.bind()
        } catch {
            await receiver.close()
            throw error
        }
        logger.debug("[LAN] \(Lang.lanServerStarted) 0.0.0.0:\(receiver.localPort ?? LANClient.receiverPort).")
        return UDPLANSocket(receiver: receiver, sender: sender)
    }

    var datagrams: AsyncStream<(data: Data, address: String)> { receiver.datagrams }

    func send(_ data: Data, to host: String, port: Int) async throws {
        try await sender.send(data, to: host, port: port)
    }

    func close() async {
        await receiver.close()
        await sender.close()
    }
}
