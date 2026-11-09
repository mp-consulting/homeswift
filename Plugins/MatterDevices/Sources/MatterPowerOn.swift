import Foundation
import HomeswiftPlugin
import Matter

// Power On (GLOSSARY.md, the bridge's `PowerOn.swift`): what a Matter light does when its power comes back, its StartUp
// attributes (Application Clusters §1.5.6.6, §1.6.6.15, §3.2.7.23): On/Off's StartUpOnOff (0 off, 1 on, 2 toggle, null
// as it was), Level Control's StartUpCurrentLevel (null its last) and Color Control's StartUpColorTemperatureMireds (null
// its last). The bridge's Natural Light is as it was, at the white it gives. Homeswift's fabric is an administrator's, so
// it may write them (Manage).
extension MatterDevicesPlugin {
    /// The light an accessory stands for: its node's link, its endpoint, and whether it dims and has Color Control.
    private func powerOnLight(_ accessoryID: String) -> (link: MatterNodeLink, endpoint: EndpointNumber, level: Bool, colour: Bool)? {
        for node in nodes.values {
            guard let accessory = node.plan.accessories.first(where: { $0.id == accessoryID }), let structure = node.structure else { continue }
            guard let subtype = accessory.services.first(where: { $0.type == .lightbulb })?.subtype, subtype.hasPrefix("light:"),
                  let number = EndpointNumber(subtype.dropFirst("light:".count)), let endpoint = structure.endpoint(number) else { return nil }
            return (node.link, number, endpoint.has(LevelControlCluster.id), endpoint.has(ColorControlCluster.id))
        }
        return nil
    }

    /// Reads attributes of the light's endpoint: each one's value by cluster and attribute, nil for one it did not give.
    private func read(_ light: (link: MatterNodeLink, endpoint: EndpointNumber, level: Bool, colour: Bool),
                      _ attributes: [(ClusterID, AttributeID)]) async throws -> (ClusterID, AttributeID) -> TLVValue? {
        let keys = attributes.map { ConcreteAttribute(light.endpoint, $0.0, $0.1) }
        let values = try await light.link.read(keys.map(\.path))
        return { cluster, attribute in values[ConcreteAttribute(light.endpoint, cluster, attribute)] }
    }

    public func powerOnSupport(of accessoryID: String) async -> PowerOnSupport? {
        guard let light = powerOnLight(accessoryID) else { return nil }
        if powerOnCapabilities[accessoryID] == nil {
            // Asked once: whether it keeps a StartUpOnOff, and its whites.
            let whites = [(ColorControlCluster.id, ColorControlCluster.Attribute.colorTempPhysicalMinMireds), (ColorControlCluster.id, ColorControlCluster.Attribute.colorTempPhysicalMaxMireds)]
            guard let value = try? await read(light, [(OnOffCluster.id, OnOffCluster.Attribute.startUpOnOff)] + (light.colour ? whites : [])) else { return nil }
            let low = value(whites[0].0, whites[0].1)?.uint, high = value(whites[1].0, whites[1].1)?.uint
            let white = low.flatMap { low in high.flatMap { high in low > 0 && high >= low ? Int(low)...Int(high) : nil } }
            powerOnCapabilities[accessoryID] = (value(OnOffCluster.id, OnOffCluster.Attribute.startUpOnOff) != nil, white)
        }
        guard let capabilities = powerOnCapabilities[accessoryID], capabilities.startUp else { return nil }
        return PowerOnSupport(behaviours: (capabilities.white != nil ? [.natural] : []) + [.lastOn, .powerLoss, .off, .custom],
                              brightness: light.level, mirek: capabilities.white)
    }

    public func powerOn(of accessoryID: String) async throws -> PowerOn? {
        guard let light = powerOnLight(accessoryID) else { return nil }
        let onOff = (OnOffCluster.id, OnOffCluster.Attribute.startUpOnOff)
        let level = (LevelControlCluster.id, LevelControlCluster.Attribute.startUpCurrentLevel)
        let white = (ColorControlCluster.id, ColorControlCluster.Attribute.startUpColorTemperatureMireds)
        let value = try await read(light, [onOff] + (light.level ? [level] : []) + (powerOnCapabilities[accessoryID]?.white != nil ? [white] : []))
        // StartUpCurrentLevel 0 is the light's lowest level; null, its last (Application Clusters §1.6.6.15).
        let brightness = value(level.0, level.1)?.uint.map { $0 == 0 ? 1 : LevelControlCluster.percent(level: $0) }
        let kelvin = value(white.0, white.1)?.uint.flatMap { $0 == 0 ? nil : PowerOn.kelvin(mirek: Int($0)) }
        switch value(onOff.0, onOff.1)?.uint {
        case nil: return PowerOn(.powerLoss, temperature: kelvin)
        case 0: return PowerOn(.off)
        case 1: return brightness == nil && kelvin == nil ? PowerOn(.lastOn) : PowerOn(.custom, brightness: brightness, temperature: kelvin)
        default: return nil
        }
    }

    public func setPowerOn(_ value: PowerOn, of accessoryID: String) async throws {
        guard let light = powerOnLight(accessoryID) else { throw PowerOnError("This Matter light keeps no Power On") }
        let whites = powerOnCapabilities[accessoryID]?.white
        let onOff: TLVValue = switch value.behaviour {
        case .off: .unsigned(0)
        case .lastOn, .custom: .unsigned(1)
        case .powerLoss, .natural: .null
        case .default: throw PowerOnError("A Matter light has no default of its own to come back in")
        }
        var writes = [(ConcreteAttribute(light.endpoint, OnOffCluster.id, OnOffCluster.Attribute.startUpOnOff).path, onOff)]
        if value.behaviour != .off {
            if light.level {
                let level: TLVValue = value.behaviour == .custom ? value.brightness.map { .unsigned(UInt64(LevelControlCluster.level(percent: Double($0)))) } ?? .null : .null
                writes.append((ConcreteAttribute(light.endpoint, LevelControlCluster.id, LevelControlCluster.Attribute.startUpCurrentLevel).path, level))
            }
            if let whites {
                let mirek = [.custom, .natural].contains(value.behaviour) ? value.mirek.map { min(whites.upperBound, max(whites.lowerBound, $0)) } : nil
                writes.append((ConcreteAttribute(light.endpoint, ColorControlCluster.id, ColorControlCluster.Attribute.startUpColorTemperatureMireds).path,
                               mirek.map { .unsigned(UInt64($0)) } ?? .null))
            }
        }
        try await light.link.write(writes)
    }
}
