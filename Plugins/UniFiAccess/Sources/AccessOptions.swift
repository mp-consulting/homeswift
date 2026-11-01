import HomeswiftPlugin

/// The plugin's feature options (`access-options.ts`): the same categories, names, defaults and descriptions,
/// since users have them in the `options` array of their block.
enum AccessOptions {
    static let categories: [FeatureCategory] = [
        FeatureCategory(name: "Device", description: "Device feature options.", modelKey: ["all"]),
        FeatureCategory(name: "Controller", description: "Controller feature options.", modelKey: ["controller"]),
        FeatureCategory(name: "Hub", description: "Hub feature options.", hasCapability: ["is_hub"], modelKey: ["all"]),
        FeatureCategory(name: "AccessMethod", description: "Access method feature options.", hasCapability: ["is_reader"], modelKey: ["all"]),
        FeatureCategory(name: "Log", description: "Logging feature options.", modelKey: ["all"]),
    ]

    static let options: [String: [FeatureOptionEntry]] = [
        "AccessMethod": [
            FeatureOptionEntry(
                "SeparateAccessory", default: false,
                description: "Put the access method switches on a HomeKit accessory of their own, so that they get their own tile instead of sharing one with the lock. The switches stay grouped together on that tile. Enabling this changes the identity of the switches in HomeKit, so any automations, room assignments, or names you have set for them will need to be set again."),
            FeatureOptionEntry("Face", default: true, description: "Add a switch accessory to control the face unlock access method.", hasCapability: ["identity_face_unlock"]),
            FeatureOptionEntry("Hand", default: true, description: "Add a switch accessory to control the hand wave unlock access method.", hasCapability: ["hand_wave"]),
            FeatureOptionEntry(
                "Mobile", default: true, description: "Add a switch accessory to control the mobile unlock access method.", hasCapability: ["mobile_unlock_ver2", "support_mobile_unlock"]),
            FeatureOptionEntry("NFC", default: true, description: "Add a switch accessory to control the NFC card access method.", hasCapability: ["nfc_card_easy_provision"]),
            FeatureOptionEntry("PIN", default: true, description: "Add a switch accessory to control the PIN unlock access method.", hasCapability: ["pin_code"]),
            FeatureOptionEntry("QR", default: true, description: "Add a switch accessory to control the QR unlock access method.", hasCapability: ["qr_code"]),
            FeatureOptionEntry("TouchPass", default: true, description: "Add a switch accessory to control the Touch Pass access method.", hasCapability: ["support_apple_pass"]),
        ],
        "Controller": [
            FeatureOptionEntry(
                "DelayDeviceRemoval", default: true, defaultValue: Double(AccessSettings.deviceRemovalDelay),
                description: "Delay, in seconds, before removing devices that are no longer detected on the Access controller. Set this to 0 to remove devices as soon as they disappear."),
            FeatureOptionEntry("Publish.Telemetry", default: false, description: "Publish all the realtime telemetry received from the Access controller to MQTT."),
        ],
        "Device": [
            FeatureOptionEntry("", default: true, description: "Make this device available in HomeKit."),
            FeatureOptionEntry(
                "SyncName", default: true,
                description: "Synchronize the UniFi Access name of this device with HomeKit. Synchronization is one-way only, syncing the device name from UniFi Access to HomeKit."),
        ],
        "Hub": [
            FeatureOptionEntry(
                "Door.UseLock", default: false, description: "Use a lock accessory instead of a garage door opener accessory for the gate.",
                modelKey: DeviceCatalog.modelsDefaultGarageDoor),
            FeatureOptionEntry(
                "Door.UseGarageOpener", default: false,
                description: "Use a garage door opener accessory instead of a lock accessory. This is a visual preference only within HomeKit; the underlying lock behavior and feature options remain the same.",
                modelKey: DeviceCatalog.modelsDefaultLock),
            FeatureOptionEntry(
                "GateDirectionDuration", default: false, defaultValue: Double(AccessSettings.gateDirectionDuration),
                description: "Duration, in seconds, of the full gate cycle (open, hold, and close). This time is split into three equal phases — Opening, Open, and Closing — to show the gate status in HomeKit. The door position sensor confirms the final Closed state. Adjust this to match your gate's actual cycle time.",
                modelKey: DeviceCatalog.modelsDefaultGarageDoor),
            FeatureOptionEntry(
                "LockDelayInterval", default: false, defaultValue: Double(AccessSettings.deviceUnlockInterval),
                description: "Delay, in minutes, before locking the door lock relay once it's been unlocked by HomeKit. If set to 0, it will remain unlocked indefinitely. This applies regardless of whether you use a lock or garage door opener accessory. By default, the door lock relay will lock five seconds after unlocking."),
            FeatureOptionEntry(
                "Lock.Trigger", default: false,
                description: "Add a switch accessory to control the door lock relay. This can be useful in automation scenarios where you want to work around HomeKit's security restrictions and trigger events when a lock or unlock event occurs. This works with both lock and garage door opener accessories."),
            FeatureOptionEntry("Doorbell", default: true, description: "Add a doorbell accessory to handle doorbell ring events in HomeKit.", hasCapability: ["door_bell"]),
            FeatureOptionEntry(
                "Doorbell.Trigger", default: false,
                description: "Add a switch accessory for automation scenarios to reflect (but not trigger) doorbell ring events on an Access doorbell.", hasCapability: ["door_bell"]),
            FeatureOptionEntry(
                "Doorbell.SeparateAccessory", default: false,
                description: "Put the doorbell, and its automation trigger if you use one, on a HomeKit accessory of their own so that they get their own tile instead of sharing one with the lock. The doorbell is the primary service of whichever accessory it sits on, so leaving it here is what makes the hub tile a doorbell rather than a lock. Enabling this changes the identity of the doorbell in HomeKit, so any automations, room assignments, or names you have set for it will need to be set again.",
                group: "Doorbell", hasCapability: ["door_bell"]),
            FeatureOptionEntry(
                "Sensors.SeparateAccessory", default: false,
                description: "Give each door sensor its own HomeKit accessory so that it appears as a dedicated tile, instead of grouping the sensors with the lock on a single tile. Enabling this changes the identity of the sensors in HomeKit, so any automations, room assignments, or names you have set for them will need to be set again.",
                modelKey: DeviceCatalog.modelsSensors),
            FeatureOptionEntry("DPS", default: true, description: "Add a contact sensor accessory for the door position sensor.", modelKey: DeviceCatalog.modelsDps),
            FeatureOptionEntry("REL", default: true, description: "Add a contact sensor accessory for the remote release.", modelKey: DeviceCatalog.modelsRel),
            FeatureOptionEntry("REN", default: true, description: "Add a contact sensor accessory for the request to enter sensor.", modelKey: DeviceCatalog.modelsRen),
            FeatureOptionEntry("REX", default: true, description: "Add a contact sensor accessory for the request to exit sensor.", modelKey: DeviceCatalog.modelsRex),
            FeatureOptionEntry(
                "SideDoor", default: true, description: "Add a lock accessory for the side door (pedestrian gate) on UniFi Access Gate Hub devices.",
                modelKey: DeviceCatalog.modelsSideDoor),
            FeatureOptionEntry(
                "SideDoor.DPS", default: true, description: "Add a contact sensor accessory for the side door position sensor.", group: "SideDoor",
                modelKey: DeviceCatalog.modelsSideDoor),
            FeatureOptionEntry(
                "SideDoor.SeparateAccessory", default: false,
                description: "Put the side door, with its position sensor and lock trigger, on a HomeKit accessory of its own so that it gets its own tile instead of sharing the gate's. Enabling this changes the identity of the side door in HomeKit, so any automations, room assignments, or names you have set for it will need to be set again.",
                group: "SideDoor", modelKey: DeviceCatalog.modelsSideDoor),
            FeatureOptionEntry(
                "SideDoor.Lock.Trigger", default: false,
                description: "Add a switch accessory to control the side door lock. This can be useful in automation scenarios where you want to work around HomeKit's security restrictions for controlling locks.",
                group: "SideDoor", modelKey: DeviceCatalog.modelsSideDoor),
        ],
        "Log": [
            FeatureOptionEntry("Doorbell", default: true, description: "Log doorbell ring events in Homebridge.", hasCapability: ["door_bell"]),
            FeatureOptionEntry("DPS", default: true, description: "Log door position sensor events in Homebridge.", modelKey: DeviceCatalog.modelsDps),
            FeatureOptionEntry("REL", default: true, description: "Log door remote release events in Homebridge.", modelKey: DeviceCatalog.modelsRel),
            FeatureOptionEntry("REN", default: true, description: "Log door request to enter events in Homebridge.", modelKey: DeviceCatalog.modelsRen),
            FeatureOptionEntry("REX", default: true, description: "Log door request to exit events in Homebridge.", modelKey: DeviceCatalog.modelsRex),
            FeatureOptionEntry("Lock", default: true, description: "Log lock events in Homebridge.", hasCapability: ["is_hub"]),
        ],
    ]

    /// The feature options of a block.
    static func make(_ configured: [String]) -> FeatureOptions {
        FeatureOptions(categories: categories, options: options, configured: configured) { AccessSettings.isAccessIdentifier($0) }
    }

    /// The categories and options for the settings page, shaped like the Homebridge plugin's `/getOptions`.
    static var json: JSONValue {
        func strings(_ values: [String]?) -> JSONValue? { values.map { .array($0.map(JSONValue.string)) } }
        let categoryList: [JSONValue] = categories.map { category in
            var object: [String: JSONValue] = ["name": .string(category.name), "description": .string(category.description)]
            if let capability = strings(category.hasCapability) { object["hasCapability"] = capability }
            if let models = strings(category.modelKey) { object["modelKey"] = models }
            return .object(object)
        }
        var optionMap: [String: JSONValue] = [:]
        for (category, entries) in options {
            optionMap[category] = .array(entries.map { entry in
                var object: [String: JSONValue] = ["name": .string(entry.name), "default": .bool(entry.default), "description": .string(entry.description)]
                if let value = entry.defaultValue { object["defaultValue"] = .number(value) }
                if let group = entry.group { object["group"] = .string(group) }
                if let capability = strings(entry.hasCapability) { object["hasCapability"] = capability }
                if let models = strings(entry.modelKey) { object["modelKey"] = models }
                return .object(object)
            })
        }
        return ["categories": .array(categoryList), "options": .object(optionMap)]
    }
}
