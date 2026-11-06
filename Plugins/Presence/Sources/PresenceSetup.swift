import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

// Setup (GLOSSARY.md, "Setup"): a Person is added as a device by Add by address, which this plugin calls "Add a
// Person": the first step asks their name and, when the web UI has users, which one they are; the second picks their
// devices among those on the network, with a word on private Wi-Fi addresses. Done, the Person's Device Id is new
// (`person-` and eight hex digits) and their Accessory Settings hold the rest. Anyone Home is always there, set up.
extension PresencePlugin {
    /// The Persons, and Anyone Home.
    public func discover() async throws -> [DiscoveredDevice] {
        var found = [DiscoveredDevice(deviceID: Self.anyoneID, name: context.accessorySettings(for: Self.anyoneID).name ?? "Anyone Home", model: "Anyone Home", isSetUp: true, kind: Self.anyoneKind)]
        for (id, settings) in context.allAccessorySettings where Self.isPerson(id) {
            var person = DiscoveredDevice(deviceID: id, name: settings.name ?? id, model: "Person", isSetUp: true, kind: Self.personKind)
            person.isExcluded = settings.excluded
            found.append(person)
        }
        return found.sorted { ($0.deviceID == Self.anyoneID ? 0 : 1, $0.name) < ($1.deviceID == Self.anyoneID ? 0 : 1, $1.name) }
    }

    static let privateAddressWarning = "Set the phone's Private Wi-Fi Address to Fixed for this network (on Android: use device MAC). A Rotating one "
        + "changes, and Presence loses the phone."

    /// Add a Person: their name and user, then their devices.
    public func authorize(_ request: SetupRequest) async throws -> SetupStep {
        guard request.isNewDevice else { return .done(SetupOutcome()) }
        guard let name = request.state["name"]?.stringValue ?? request.answer("name") else {
            var fields = [SetupField("name", label: "Name")]
            let users = context.webUsers
            if !users.isEmpty {
                fields.append(.choice("user", label: "Web UI user", options: users.map { SetupOption($0.username, label: $0.name, detail: $0.name == $0.username ? nil : $0.username) },
                                      optional: true))
            }
            return .ask(SetupPrompt(message: "Who is this Person? Linked to a web UI user, their pages say when they are home.", fields: fields))
        }
        guard name.count <= 64 else { throw SetupError("The name is too long: 64 characters at most") }
        let user = request.state["user"]?.stringValue ?? request.answer("user")
        if let user, !context.webUsers.contains(where: { $0.username == user }) { throw SetupError("There is no web UI user \(user)") }
        // Kept from the first step to the second, then the Person's Accessory Settings with their devices.
        var settings: [String: JSONValue] = ["name": .string(name)]
        if let user { settings["user"] = .string(user) }

        let picked = request.choices("devices").compactMap(MACAddress.canonical)
        guard !picked.isEmpty else {
            let devices = await dependencies.source.devices()
            guard !devices.isEmpty else { throw SetupError("No device answered on the network: check that the bridge runs on the same network as the phones (in Docker, with host networking)") }
            let options = devices.map { device in
                SetupOption(device.mac, label: device.name ?? device.address,
                            detail: [device.name == nil ? nil : device.address, device.mac].compactMap { $0 }.joined(separator: " · "),
                            badge: device.isPrivate ? "Private address" : nil)
            }
            return .ask(SetupPrompt(message: "Pick {name}'s devices: those they carry, such as their phone or their watch.", values: ["name": name],
                                    fields: [.choices("devices", label: "Devices", options: options)], warning: Self.privateAddressWarning),
                        state: .object(settings))
        }
        settings["devices"] = .array(picked.map(JSONValue.string))
        let id = Self.personPrefix + String(format: "%08x", UInt32.random(in: .min ... .max))
        logger.info("Added the Person \(name)")
        return .done(SetupOutcome(settings: settings, deviceID: id))
    }
}
