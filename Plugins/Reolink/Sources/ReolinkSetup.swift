import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers

// Setup (GLOSSARY.md, "Setup"; 2.5): each host is a device authorized with an Account Login, a local user of the device.
// Its Device Id is its host id (the P2P UID, else its MAC); a camera on its own is that device, an NVR's or a hub's
// channels are devices of their own (`<host id>:<channel UID>`) that come with it and need nothing more. The login goes
// in the vault under the host's Device Id and its address in its Accessory Settings (`host`), as UniFi Protect's
// controllers. Hosts the network shows are those of the ARP table with Reolink's MAC prefix that accept Baichuan's port;
// any other is added by its address.
extension ReolinkPlugin {
    /// Reolink's MAC prefix (Home Assistant's manifest).
    static let macPrefix = "EC:71:DB"
    /// The entry that adds a host by its address.
    static let byAddressID = "address:"

    public func discover() async throws -> [DiscoveredDevice] {
        var found: [DiscoveredDevice] = []
        var addresses = Set<String>()
        let known = hostsFile.load() ?? [:]
        for entry in hostEntries() {
            let address = entry.host.lowercased()
            addresses.insert(address)
            if let runtime = runtimes[entry.host], let info = runtime.info, let hostID = runtime.hostID {
                found += devices(of: info, hostID: hostID, address: entry.host, channels: await runtime.host.channels)
                continue
            }
            // Configured, not reached: from what it was last time, or by its address.
            var device = DiscoveredDevice(deviceID: known[address] ?? "\(Self.byAddressID)\(entry.host)", name: entry.host, model: "Reolink",
                                          address: entry.host, authorization: .accountLogin, isSetUp: !entry.password.isEmpty, excludedBySettings: false,
                                          kind: Self.cameraKind)
            device.isReachable = runtimes[entry.host] == nil
            found.append(device)
        }
        // Reolink devices on the network that are not set up.
        for ip in await networkCandidates(excluding: addresses) {
            found.append(DiscoveredDevice(deviceID: "\(Self.byAddressID)\(ip)", name: "Reolink device at \(ip)", model: "Reolink", address: ip,
                                          authorization: .accountLogin, isSetUp: false, excludedBySettings: false, kind: Self.cameraKind))
        }
        found.append(DiscoveredDevice(deviceID: Self.byAddressID, name: "A Reolink device by its address", model: "Reolink", authorization: .accountLogin,
                                      isSetUp: false, excludedBySettings: false, kind: Self.cameraKind))
        return found
    }

    /// The addresses of the ARP table with Reolink's MAC prefix, not in `addresses`, that accept Baichuan's port: those
    /// that answered within `networkSearchTime`. Discovery never waits longer for the network (a camera that drops the
    /// connection, an `arp` that hangs), so a Devices list or the Add accessories page is not held up by it.
    private func networkCandidates(excluding addresses: Set<String>) async -> [String] {
        let neighbours = dependencies.neighbours, accepts = dependencies.accepts, timeout = dependencies.networkSearchTime
        let answered = NIOLockedValueBox<[String]>([])
        let finished = NIOLockedValueBox<CheckedContinuation<Void, Never>?>(nil)
        let finish: @Sendable () -> Void = { finished.withLockedValue { continuation in continuation?.resume(); continuation = nil } }
        await withCheckedContinuation { continuation in
            finished.withLockedValue { $0 = continuation }
            let search = Task {
                let candidates = await neighbours().filter { $0.mac.uppercased().hasPrefix(Self.macPrefix) && !addresses.contains($0.ip.lowercased()) }
                await withTaskGroup(of: Void.self) { group in
                    for candidate in candidates.prefix(32) {
                        group.addTask { if await accepts(candidate.ip, 9000) { answered.withLockedValue { $0.append(candidate.ip) } } }
                    }
                }
                finish()
            }
            Task {
                try? await Task.sleep(for: timeout)
                search.cancel()
                finish()
            }
        }
        return answered.withLockedValue { $0 }.sorted()
    }

    /// A connected host's devices: itself (an NVR or a hub) and its channels.
    private func devices(of info: ReolinkHostInfo, hostID: String, address: String, channels: [Int: ReolinkChannel]) -> [DiscoveredDevice] {
        var list: [DiscoveredDevice] = []
        if info.isMultiChannel {
            list.append(DiscoveredDevice(deviceID: hostID, name: info.name.nonEmptyText ?? info.model, model: info.model, address: address,
                                         authorization: .accountLogin, isSetUp: true, excludedBySettings: false, kind: Self.nvrKind))
        }
        for channel in channels.values.sorted(by: { $0.channel < $1.channel }) {
            let deviceID = Self.deviceID(hostID: hostID, info: info, channel: channel)
            list.append(DiscoveredDevice(deviceID: deviceID, name: channel.name, model: channel.model, address: info.isMultiChannel ? nil : address,
                                         authorization: info.isMultiChannel ? .none : .accountLogin, isSetUp: true, excludedBySettings: false,
                                         kind: Self.cameraKind))
        }
        return list
    }

    public func deviceKind(of deviceID: String) async -> String? {
        for runtime in runtimes.values where runtime.hostID == deviceID { return runtime.info?.isMultiChannel == true ? Self.nvrKind : Self.cameraKind }
        return Self.cameraKind
    }

    /// A host: its address (when the device has none), then the user name and password of a local user, checked with a
    /// login, `GetDevInfo` and `GetChannelstatus` before they are kept. Its host id is its Device Id.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        let device = try request.device()
        guard device.authorization == .accountLogin else { return .done(SetupOutcome()) }
        let address = device.address?.nonEmptyText ?? request.answer("host")?.trimmingCharacters(in: .whitespaces).nonEmptyText
            ?? request.state["host"]?.stringValue
        guard let address, let password = request.secret("password") else {
            var fields: [SetupField] = []
            if device.address == nil { fields.append(SetupField("host", label: "Address", value: request.state["host"]?.stringValue)) }
            fields += [SetupField("username", label: "User name", value: request.answer("username") ?? "admin"),
                       SetupField("password", label: "Password", kind: .secret)]
            return .ask(SetupPrompt(
                message: "Sign in to the Reolink device with a local user (an administrator, for floodlights, sirens and IR lights).", fields: fields),
                state: address.map { ["host": .string($0)] } ?? .null)
        }
        let username = request.answer("username")?.nonEmptyText ?? "admin"
        guard var entry = Device(json: ["host": .string(address), "username": .string(username), "password": .string(password)]) else {
            throw SetupError("Enter the device's address")
        }
        entry.pushEvents = false
        let host = makeHost(entry, trustingAgain: true)
        do {
            try await host.connect()
        } catch ReolinkError.credentials(let detail) {
            await host.stop()
            throw SetupError("The device refused the user name or password (\(detail))")
        } catch {
            await host.stop()
            throw SetupError("Could not read the device at \(address): \(error)")
        }
        let info = await host.info
        let channels = await host.channels.count
        await host.stop()
        guard let hostID = info.hostID ?? info.serial.nonEmptyText else { throw SetupError("The device at \(address) gave no serial number") }
        var known = hostsFile.load() ?? [:]
        known[address.lowercased()] = hostID
        try? hostsFile.save(known)
        logger.info("Signed in to the \(info.model.nonEmptyText ?? "Reolink device") at \(address) through Setup (\(channels) channel\(channels == 1 ? "" : "s")).")
        return .done(try SetupOutcome(encoding: Login(username: username, password: password), settings: ["host": .string(address)], deviceID: hostID))
    }

    /// The block in its canonical shape: a `devices` entry's `cameras` options move into the Accessory Settings of their
    /// channel, by Device Id, once the host is known; the entry keeps its address and login.
    public func canonicalSettings(_ block: JSONValue) async -> JSONValue {
        guard var fields = block.objectValue, let devices = fields["devices"]?.arrayValue else { return block }
        var entries = AccessoryEntries(fields["_accessories"]?.objectValue ?? [:])
        var changed = false
        var rewritten: [JSONValue] = []
        for item in devices {
            guard var object = item.objectValue, let address = object["host"]?.stringValue, let cameras = object["cameras"]?.objectValue,
                  let runtime = runtimes[address], let info = runtime.info, let hostID = runtime.hostID else {
                rewritten.append(item)
                continue
            }
            let channels = await runtime.host.channels
            var left: [String: JSONValue] = [:]
            for (key, options) in cameras {
                guard let number = Int(key), let channel = channels[number], let values = options.objectValue else {
                    left[key] = options
                    continue
                }
                let deviceID = Self.deviceID(hostID: hostID, info: info, channel: channel)
                for (name, value) in values {
                    if name == "name" || CameraOptions.settingKeys.contains(name) { entries.setIfAbsent(name, value, on: deviceID) }
                }
                changed = true
            }
            if left.isEmpty { object.removeValue(forKey: "cameras") } else { object["cameras"] = .object(left) }
            rewritten.append(.object(object))
        }
        guard changed else { return block }
        fields["devices"] = .array(rewritten)
        entries.write(into: &fields)
        return .object(fields)
    }
}
