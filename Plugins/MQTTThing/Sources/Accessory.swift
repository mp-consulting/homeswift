import Foundation
import Homeswift
import HomeswiftPlugin

extension Thing {
    /// The accessory of the block (section 2), or nil when it makes no services; its start-up publishes are queued.
    func build() -> Accessory? {
        var services: [Service] = []
        if config.type == "custom" {
            for item in config["services"]?.arrayValue ?? [] {
                guard let object = item.objectValue else { continue }
                var entryConfig = config.overlaid(with: object)
                if entryConfig.subtype == nil { entryConfig.values["subtype"] = .string(entryConfig.name) }
                services += servicesOfEntry(entryConfig)
            }
        } else {
            services = servicesOfEntry(config)
        }
        guard !services.isEmpty else {
            logger.error("\(config.name): no services created")
            return nil
        }
        startPublishing()
        return Accessory(
            id: id, name: config.name, manufacturer: config.string("manufacturer") ?? "mqttthing", model: config.string("model") ?? config.rawType,
            serialNumber: config.string("serialNumber") ?? "\(dependencies.hostName)-\(config.name)",
            firmwareRevision: config.string("firmwareRevision") ?? PluginHost.version, category: Self.category(config.type), services: services)
    }

    private func servicesOfEntry(_ entryConfig: Config) -> [Service] {
        guard entryConfig.hasTopics || entryConfig.type == "irrigationSystem" else {
            logger.error("\(entryConfig.name): no topics, so no services (\"topics\" is required)")
            return []
        }
        let entry = Entry(config: entryConfig, online: OnlineState())
        entry.history = makeHistory(entryConfig)
        if let history = entry.history { keep.append(history) }
        return services(for: entry)
    }

    /// `startPub`, as a list of `{topic, message}` or the older object of topic to message (section 6.6).
    private func startPublishing() {
        var messages: [(String, String)] = []
        switch config["startPub"] {
        case .array(let items)?:
            for item in items {
                guard let topic = item["topic"]?.stringValue, !topic.isEmpty else { continue }
                messages.append((topic, JS.truthy(item["message"]) ? item["message"].map(JS.text) ?? "" : ""))
            }
        case .object(let object)?:
            for topic in object.keys.sorted() where !topic.isEmpty {
                messages.append((topic, JS.truthy(object[topic]) ? object[topic].map(JS.text) ?? "" : ""))
            }
        default:
            break
        }
        for (topic, message) in messages {
            if let codec {
                codecEncode(codec, topic: topic, property: "startPub", value: .string(message))
            } else {
                publish(topic: topic, payload: message)
            }
        }
    }

    static func category(_ type: String) -> AccessoryCategory {
        switch type {
        case "lightbulb": .lightbulb
        case "switch": .switch
        case "outlet": .outlet
        case "fan", "fanv2": .fan
        case "garageDoorOpener": .garageDoorOpener
        case "lockMechanism": .doorLock
        case "thermostat": .thermostat
        case "heaterCooler": .airConditioner
        case "dehumidifier": .dehumidifier
        case "airPurifier": .airPurifier
        case "securitySystem": .securitySystem
        case "door": .door
        case "window": .window
        case "television": .television
        case "speaker", "microphone": .speaker
        case "doorbell": .videoDoorbell
        case "statelessProgrammableSwitch": .programmableSwitch
        case "valve", "irrigationSystem": .sprinkler
        case "custom", "battery": .other
        default: .sensor
        }
    }
}
