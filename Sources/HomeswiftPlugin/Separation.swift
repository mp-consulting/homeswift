import Foundation
import Homeswift

/// Separate Functions (GLOSSARY.md; docs/adr/0006-the-bridge-separates-functions.md): what the bridge publishes in place
/// of a plugin's accessory whose Functions a person separated. The device's own accessory keeps its id, its aid and its
/// identity, with its main Function and what describes it; each other Function becomes an accessory of its own,
/// `<id>:<function>`, with the identity's values, a copy of the battery, and Identify forwarded. The plugin's services
/// themselves move, so their handlers and events go on working; the plugin's accessory is left as it is (the cache and
/// Matter keep it whole).
public struct Separation: Sendable {
    /// The accessory published under the plugin's id.
    public let main: Accessory
    /// One accessory per other Function, or set of Functions kept together.
    public let parts: [Accessory]
    /// The observations keeping the copied batteries in step, to remove when it is separated again or joined.
    let observations: [(Characteristic, Int)]

    /// Stops keeping the copies in step.
    func end() {
        for (characteristic, token) in observations { characteristic.removeObserver(token) }
    }

    /// The Functions of `accessory` grouped as they would be separated, the main one first; nil when there is nothing
    /// to separate: fewer than two groups, a mirrored accessory, a camera, a doorbell or a television.
    public static func groups(of accessory: Accessory) -> [[Service]]? {
        guard accessory.mirroredFrom == nil, accessory.separatedFrom == nil else { return nil }
        let whole: Set<HAPUUID> = [
            ServiceType.cameraRTPStreamManagement.uuid, ServiceType.doorbell.uuid, ServiceType.television.uuid,
        ]
        guard !accessory.services.contains(where: { whole.contains($0.type.uuid) }) else { return nil }
        let functions = Functions.of(accessory)
        guard functions.count > 1 else { return nil }
        var groups = functions.map { [$0] }
        func merge(_ services: [Service]) {
            let ids = Set(services.map(ObjectIdentifier.init))
            let joined = groups.filter { $0.contains { ids.contains(ObjectIdentifier($0)) } }
            guard joined.count > 1 else { return }
            let first = groups.firstIndex { $0.contains { ids.contains(ObjectIdentifier($0)) } }!
            let merged = joined.flatMap { $0 }
            groups.removeAll { $0.contains { ids.contains(ObjectIdentifier($0)) } }
            groups.insert(merged, at: min(first, groups.count))
        }
        for together in accessory.functionsKeptTogether { merge(together) }
        // A remote's buttons are one: their labels number them on one accessory.
        if accessory[.serviceLabel] != nil { merge(functions.filter { $0.type.uuid == ServiceType.statelessProgrammableSwitch.uuid }) }
        guard groups.count > 1 else { return nil }
        let main = AccessoryNaming.primaryService(of: accessory).flatMap { primary in groups.firstIndex { $0.contains { $0 === primary } } } ?? 0
        if main != 0 { groups.insert(groups.remove(at: main), at: 0) }
        return groups
    }

    /// What to publish for `accessory` with its Functions separated; nil when there is nothing to separate.
    public static func of(_ accessory: Accessory) -> Separation? {
        guard let groups = groups(of: accessory) else { return nil }
        let moved = Set(groups.dropFirst().flatMap { $0 }.map(ObjectIdentifier.init))
        let battery = accessory.services.filter { $0.type.uuid == ServiceType.battery.uuid }
        let main = Accessory(
            id: accessory.id, information: accessory.information, supportsIdentify: accessory.supportsIdentify, category: accessory.category,
            services: accessory.services.filter { !moved.contains(ObjectIdentifier($0)) })
        main.separatedFrom = accessory
        main.suggestedRoom = accessory.suggestedRoom
        let information = accessory.information
        let value = { (type: CharacteristicType) in information[type]?.value.stringValue }
        var observations: [(Characteristic, Int)] = []
        var keys: Set<String> = []
        let parts = groups.dropFirst().map { group -> Accessory in
            let function = group[0]
            let key = uniqueKey(for: function, taken: &keys)
            var services = group
            for service in battery {
                let (copy, kept) = Self.copy(service)
                services.append(copy)
                observations += kept
            }
            let part = Accessory(
                id: "\(accessory.id):\(key)", name: name(of: function, in: accessory),
                manufacturer: value(.manufacturer) ?? "Homeswift", model: value(.model) ?? "Accessory",
                serialNumber: value(.serialNumber), firmwareRevision: value(.firmwareRevision) ?? "1.0.0",
                category: Functions.category(of: function.type), services: services,
                onIdentify: accessory.supportsIdentify ? { @Sendable [weak accessory] in await accessory?.identify() } : nil)
            part.separatedFrom = accessory
            part.suggestedRoom = accessory.suggestedRoom
            return part
        }
        return Separation(main: main, parts: parts, observations: observations)
    }

    /// A Function's key in its accessory's id: its subtype, else its type, made unique.
    static func uniqueKey(for service: Service, taken: inout Set<String>) -> String {
        let base = (service.subtype?.isEmpty == false ? service.subtype! : service.type.name).lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        var key = base, number = 1
        while !taken.insert(key).inserted {
            number += 1
            key = "\(base)-\(number)"
        }
        return key
    }

    /// The name a separated Function goes by: its own when it has one other than the accessory's, else the accessory's
    /// and what it does ("Desk Lamp Motion Sensor").
    public static func name(of service: Service, in accessory: Accessory) -> String {
        let own = (service[.configuredName] ?? service[.name])?.value.stringValue?.trimmingCharacters(in: .whitespaces)
        if let own, !own.isEmpty, own != accessory.name { return own }
        return "\(accessory.name) \(spaced(service.type.name))"
    }

    /// "MotionSensor" as "Motion Sensor".
    static func spaced(_ name: String) -> String {
        var words = ""
        for character in name {
            if character.isUppercase, let last = words.last, last.isLowercase { words.append(" ") }
            words.append(character)
        }
        return words
    }

    /// A copy of a service (the battery) whose values follow the original's.
    static func copy(_ service: Service) -> (Service, [(Characteristic, Int)]) {
        let pairs = service.characteristics.map { ($0, Characteristic($0.type, value: $0.value)) }
        let copy = Service(service.type, subtype: service.subtype, extra: pairs.map(\.1))
        let tokens = pairs.map { original, copied in
            (original, original.observe { [weak copied] change in copied?.value = change.newValue })
        }
        return (copy, tokens)
    }
}
