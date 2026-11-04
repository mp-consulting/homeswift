import Foundation
import Homeswift
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): nothing to sign in to. An ECU is a device found at an address of `ecus` (the ECU has no
// Bonjour announcement), confirmed by the system query, whose answer gives its Device Id, the ECU id; each inverter it
// reports is a device too (Device Id its UID), which can be Excluded. The page and the Assistant check an address before
// it goes in `ecus` (`probe`).
extension APsystemsECUPlugin {
    /// How long Setup's check of an address may take, retries included.
    static let probeTimeout: Duration = .seconds(6)

    /// The ECUs of `ecus` (by their id once one answered, else by their address, not responding), then the inverters they
    /// reported.
    public func discover() async throws -> [DiscoveredDevice] {
        var devices: [DiscoveredDevice] = []
        for key in order {
            guard let ecu = ecus[key] else { continue }
            var id = ecu.ecuID
            var reachable = ecu.failures == 0
            if id == nil {
                id = try? await probe(host: ecu.host, port: ecu.port).ecuID
                reachable = id != nil
            }
            let address = ecu.address
            guard let id else {
                var device = DiscoveredDevice(deviceID: "address:\(address)", name: ecu.configuredName ?? address, model: "APsystems ECU", address: address, kind: Self.ecuKind)
                device.isReachable = false
                devices.append(device)
                continue
            }
            var device = DiscoveredDevice(
                deviceID: id, name: Self.defaultName(ecuID: id, configured: ecu.configuredName), model: ECUProtocol.ecuModel(id), address: address, isSetUp: true,
                kind: Self.ecuKind)
            device.isReachable = reachable
            devices.append(device)
        }
        for (uid, reading) in inverterReadings.sorted(by: { $0.key < $1.key }) where !reading.record.isRegisteredOnly || inverterServices[uid] != nil {
            devices.append(DiscoveredDevice(
                deviceID: uid, name: Self.inverterName(uid), model: ECUProtocol.inverterModel(uid), isSetUp: configuration.inverters != false,
                excludedBySettings: configuration.inverters == false, kind: Self.inverterKind))
        }
        return devices
    }

    /// Asks the ECU at an address who it is: the system query, once, within `probeTimeout`.
    func probe(host: String, port: Int) async throws -> ECUProtocol.SystemInfo {
        let exchanger = dependencies.exchange ?? ECUClient(retries: 1, connectTimeout: .seconds(3), readTimeout: .seconds(3))
        let frame = try await exclusively(Self.key(host: host, port: port)) {
            try await ECUClient.withTimeout(Self.probeTimeout) {
                try await exchanger.exchange(ECUProtocol.systemRequest, host: host, port: port)
            }
        }
        return try ECUProtocol.parseSystem(try ECUProtocol.validate(frame, expecting: .system))
    }

    // MARK: The page and the Assistant

    public func handleWebRequest(_ request: PluginWebRequest) async throws -> PluginWebResponse {
        switch (request.method, request.path) {
        case ("GET", "status"): return PluginWebResponse(status())
        case ("GET", "probe"):
            guard let host = request.query["host"]?.trimmingCharacters(in: .whitespaces), !host.isEmpty, host.count <= 253,
                  !host.contains(where: { $0.isWhitespace || $0 == "/" }) else { return .error(400, "host is required") }
            let port = request.query["port"].flatMap { Int($0) } ?? ECUProtocol.port
            guard (1...65535).contains(port) else { return .error(400, "port must be between 1 and 65535") }
            do {
                let system = try await probe(host: host, port: port)
                return PluginWebResponse([
                    "ecuID": .string(system.ecuID), "model": .string(ECUProtocol.ecuModel(system.ecuID)), "firmware": .string(system.firmware),
                    "inverters": .number(Double(system.inverters)), "host": .string(host), "port": .number(Double(port)),
                ])
            } catch {
                return .error(502, "No ECU answered at \(host):\(port): \(error)")
            }
        default: return .error(404, "APsystems ECU has no web API at \(request.path)")
        }
    }

    /// The ECUs and their inverters as last read, for the page.
    func status() -> JSONValue {
        let readings = Dictionary(grouping: inverterReadings, by: \.value.ecuID)
        let ecuList: [JSONValue] = order.compactMap { key in
            guard let ecu = ecus[key] else { return nil }
            var fields: [String: JSONValue] = [
                "host": .string(ecu.host), "port": .number(Double(ecu.port)), "address": .string(ecu.address), "failures": .number(Double(ecu.failures)),
                "meterFailing": .bool(ecu.meterFailing),
            ]
            if let id = ecu.ecuID {
                fields["ecuID"] = .string(id)
                fields["model"] = .string(ECUProtocol.ecuModel(id))
                fields["accessoryID"] = .string(Self.accessoryID(deviceID: id))
                fields["name"] = .string(context.accessorySettings(for: id).name ?? Self.defaultName(ecuID: id, configured: ecu.configuredName))
            }
            if let system = ecu.system {
                fields["power"] = .number(Double(system.currentPower))
                fields["today"] = .number(system.todayEnergy)
                fields["lifetime"] = .number(system.lifetimeEnergy)
                fields["inverters"] = .number(Double(system.inverters))
                fields["online"] = .number(Double(system.invertersOnline))
                fields["firmware"] = .string(system.firmware)
            }
            if let updated = ecu.lastSuccess { fields["updated"] = .string(Timestamp.iso8601(updated)) }
            if let grid = ecu.meter?.gridPower { fields["grid"] = .number(grid) }
            if let home = ecu.meter?.homePower { fields["home"] = .number(home) }
            let inverters: [JSONValue] = (ecu.ecuID.flatMap { readings[$0] } ?? []).sorted { $0.key < $1.key }.map { uid, reading in
                var inverter: [String: JSONValue] = [
                    "uid": .string(uid), "model": .string(ECUProtocol.inverterModel(uid)), "online": .bool(reading.record.online),
                    "current": .bool(reading.current), "registeredOnly": .bool(reading.record.isRegisteredOnly),
                    "power": .number(Double(reading.record.power)), "powers": .array(reading.record.powers.map { .number(Double($0)) }),
                    "voltages": .array(reading.record.voltages.map { .number(Double($0)) }), "updated": .string(Timestamp.iso8601(reading.updated)),
                ]
                if inverterServices[uid] != nil { inverter["accessoryID"] = .string(Self.accessoryID(deviceID: uid)) }
                if reading.record.online, let temperature = reading.record.temperature { inverter["temperature"] = .number(Double(temperature)) }
                if reading.record.online, let frequency = reading.record.frequency { inverter["frequency"] = .number(frequency) }
                if let signal = reading.signal { inverter["signal"] = .number(Double(ECUProtocol.signalPercent(signal))) }
                return .object(inverter)
            }
            fields["inverterList"] = .array(inverters)
            return .object(fields)
        }
        return .object(["ecus": .array(ecuList), "pollInterval": .number(Double(pollSeconds))])
    }

    public static let assistantActions: [AssistantAction] = [
        AssistantAction(
            name: "status", title: "Look at the production",
            description: "Each configured ECU with its address, ECU id, model, firmware, current power (W), today's and lifetime energy (kWh), "
                + "inverters online, an ECU-C's grid and home power from its CT clamps, and each inverter's power, channel powers, voltages, "
                + "frequency, temperature and signal (percent).",
            path: "status", access: .read),
        AssistantAction(
            name: "probe", title: "Check an address",
            description: "Asks the ECU at an address for its system info (TCP port 8899): its ECU id, model, firmware and inverter count. "
                + "To add it, append {\"host\": <address>} to the Plugin Setting ecus with update_settings (plugin {\"platform\": \"APsystemsECU\"}, "
                + "settings {\"ecus\": [entries]}, which replaces the whole list: read it with get_settings first and keep its entries).",
            path: "probe", access: .configure,
            inputSchema: [
                "type": "object", "required": ["host"],
                "properties": ["host": ["type": "string", "description": "IP address or host name"], "port": ["type": "integer", "minimum": 1, "maximum": 65535]],
            ]),
    ]

    public static let assistantBackground: String? = [
        "The Homeswift plugin reads APsystems solar microinverters from their ECU gateway (ECU-C, ECU-R, ECU-R-Pro, ECU-B) on the local",
        "network: there is no account and nothing is ever written to the ECU. It sends three requests per poll on TCP port 8899, each on its",
        "own connection (system info, real-time data, signal levels), every pollInterval seconds (300 by default, 60 to 3600; every 15 minutes",
        "while no inverter is online). An ECU-C's CT clamps are read from its local web page /index.php/meter/old_meter_power_graph; recent",
        "ECU-C firmware (C1.2.24B) removed or broke that page and the real-time data, so \"The ECU-C's meter did not answer\" only leaves the",
        "grid and home readings unknown. \"Cannot read the ECU at <host>\" means the system query failed: a refused connection or a timeout",
        "is a wrong address, an ECU that is rebooting or in its late-evening maintenance (it syncs with the EMA cloud then), or one that froze;",
        "the plugin keeps the last values with Status Active off and retries, less often after three failures. An ECU that has not answered",
        "for an hour usually needs a power cycle. Give the ECU a fixed address (a DHCP reservation); it shows as an Espressif device in a",
        "router's list. At night the ECU answers with 0 W and inverters offline, which is normal.",
    ].joined(separator: " ")
}
