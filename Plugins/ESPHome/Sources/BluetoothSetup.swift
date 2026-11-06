import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin

// Setup of Bluetooth sensors (GLOSSARY.md, "Setup"): each sender the proxies hear in a known format is a Discovered
// Device of the Device Kind `sensor`, its Device Id its MAC. A Govee thermometer or an open BTHome sensor asks nothing; a
// Xiaomi sensor or an encrypted BTHome one asks for its bindkey (API Key), checked against the last advertisement heard
// and kept in the vault. What Setup writes in its Accessory Settings is its `format`, which makes it an accessory.
extension ESPHomePlugin {
    /// The sensors heard, and those set up whether heard or not.
    func bluetoothDevices() async -> [DiscoveredDevice] {
        let heard = await bluetooth.heard
        var found: [String: DiscoveredDevice] = [:]
        for entry in heard.values {
            var device = DiscoveredDevice(
                deviceID: entry.mac, name: context.accessorySettings(for: entry.mac).name ?? Self.sensorName(entry.recognition, mac: entry.mac),
                model: entry.recognition.model, authorization: entry.recognition.encrypted ? .apiKey : .none, kind: Self.sensorKind)
            device.isReachable = await bluetooth.isReachable(entry.mac)
            found[entry.mac] = device
        }
        for setup in bluetoothSetups() {
            var device = found[setup.mac] ?? DiscoveredDevice(
                deviceID: setup.mac, name: context.accessorySettings(for: setup.mac).name ?? Self.sensorName(
                    BluetoothRecognition(format: setup.format, model: nil, encrypted: setup.key != nil), mac: setup.mac),
                authorization: setup.key != nil ? .apiKey : .none, kind: Self.sensorKind)
            if found[setup.mac] == nil { device.isReachable = false }
            device.isSetUp = true
            found[setup.mac] = device
        }
        return Array(found.values)
    }

    /// `LYWSD03MMC 3456`: the model, else the format, and the end of the MAC.
    static func sensorName(_ recognition: BluetoothRecognition, mac: String) -> String {
        let format = switch recognition.format {
        case .bthome: "BTHome sensor"
        case .xiaomi: "Xiaomi sensor"
        case .govee: "Govee sensor"
        }
        let kind = recognition.model ?? format
        return "\(kind) \(mac.replacingOccurrences(of: ":", with: "").suffix(4))"
    }

    /// Whether a Setup step is for a Bluetooth sensor rather than an ESPHome device.
    func isBluetoothSensor(_ device: DiscoveredDevice) async -> Bool {
        if device.kind == Self.sensorKind { return true }
        guard let mac = MACAddress.canonical(device.deviceID) else { return false }
        return await deviceKind(of: mac) == Self.sensorKind
    }

    /// The bindkey asked when the sensor encrypts, checked against what it sent last; the format in its settings.
    func authorizeBluetooth(_ request: SetupRequest, device: DiscoveredDevice) async throws -> SetupStep {
        guard let mac = MACAddress.canonical(device.deviceID) else { throw SetupError("That is not a Bluetooth address") }
        guard let recognition = await bluetooth.heard[mac]?.recognition else {
            throw SetupError("No Bluetooth proxy has heard the sensor lately: bring it nearer to one, then find it again")
        }
        let settings: [String: JSONValue] = ["format": .string(recognition.format.rawValue)]
        guard recognition.encrypted else { return .done(SetupOutcome(settings: settings)) }
        guard let text = request.secret("encryptionKey")?.trimmingCharacters(in: .whitespacesAndNewlines) else { return .ask(Self.bindkeyPrompt) }
        guard let key = Hex.bytes(text), key.count == 16 else {
            throw SetupError("That is not a bindkey: it is 32 hexadecimal characters")
        }
        do {
            _ = try await bluetooth.check(key: key, for: mac)
        } catch BluetoothDecodeError.wrongKey {
            throw SetupError("The sensor's advertisements do not open with that bindkey")
        } catch {
            throw SetupError("The sensor sends a frame the plugin cannot read")
        }
        let credentials = ESPHomeCredentials(encryptionKey: key.map { String(format: "%02x", $0) }.joined())
        return .done(try SetupOutcome(encoding: credentials, settings: settings, deviceID: mac))
    }

    static let bindkeyPrompt = SetupPrompt(
        message: "Enter the sensor's bindkey: the 32 hexadecimal characters its encryption key is, from its maker's app or the BTHome firmware's settings.",
        fields: [SetupField("encryptionKey", label: "Bindkey", kind: .secret)])
}

