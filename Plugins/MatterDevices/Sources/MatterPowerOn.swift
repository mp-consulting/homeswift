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

    private static func path(_ endpoint: EndpointNumber, _ cluster: ClusterID, _ attribute: AttributeID) -> AttributePath {
        AttributePath(endpoint: endpoint, cluster: cluster, attribute: attribute)
    }

    public func powerOnSupport(of accessoryID: String) async -> PowerOnSupport? {
        guard let light = powerOnLight(accessoryID) else { return nil }
        if powerOnCapabilities[accessoryID] == nil {
            // Asked once: whether it keeps a StartUpOnOff, and its whites.
            var paths = [Self.path(light.endpoint, OnOffCluster.id, OnOffCluster.Attribute.startUpOnOff)]
            if light.colour {
                paths += [Self.path(light.endpoint, ColorControlCluster.id, ColorControlCluster.Attribute.colorTempPhysicalMinMireds),
                          Self.path(light.endpoint, ColorControlCluster.id, ColorControlCluster.Attribute.colorTempPhysicalMaxMireds)]
            }
            guard let values = try? await light.link.read(paths) else { return nil }
            let low = values[ConcreteAttribute(light.endpoint, ColorControlCluster.id, ColorControlCluster.Attribute.colorTempPhysicalMinMireds)]?.uint
            let high = values[ConcreteAttribute(light.endpoint, ColorControlCluster.id, ColorControlCluster.Attribute.colorTempPhysicalMaxMireds)]?.uint
            let white = low.flatMap { low in high.flatMap { high in low > 0 && high >= low ? Int(low)...Int(high) : nil } }
            powerOnCapabilities[accessoryID] = (values[ConcreteAttribute(light.endpoint, OnOffCluster.id, OnOffCluster.Attribute.startUpOnOff)] != nil, white)
        }
        guard let capabilities = powerOnCapabilities[accessoryID], capabilities.startUp else { return nil }
        let white = capabilities.white.map { PowerOn.kelvin(mirek: $0.upperBound)...PowerOn.kelvin(mirek: $0.lowerBound) }
        return PowerOnSupport(behaviours: (white != nil ? [.natural] : []) + [.lastOn, .powerLoss, .off, .custom], brightness: light.level, white: white)
    }

    public func powerOn(of accessoryID: String) async throws -> PowerOn? {
        guard let light = powerOnLight(accessoryID) else { return nil }
        let onOff = Self.path(light.endpoint, OnOffCluster.id, OnOffCluster.Attribute.startUpOnOff)
        let level = Self.path(light.endpoint, LevelControlCluster.id, LevelControlCluster.Attribute.startUpCurrentLevel)
        let white = Self.path(light.endpoint, ColorControlCluster.id, ColorControlCluster.Attribute.startUpColorTemperatureMireds)
        let values = try await light.link.read([onOff] + (light.level ? [level] : []) + (powerOnCapabilities[accessoryID]?.white != nil ? [white] : []))
        func value(_ path: AttributePath) -> UInt64? { path.endpoint.flatMap { endpoint in values[ConcreteAttribute(endpoint, path.cluster!, path.attribute!)]?.uint } }
        let brightness = value(level).flatMap { $0 == 0 ? nil : LevelControlCluster.percent(level: $0) }
        let kelvin = value(white).flatMap { $0 == 0 ? nil : PowerOn.kelvin(mirek: Int($0)) }
        switch value(onOff) {
        case nil: return PowerOn(.powerLoss)
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
        var writes = [(Self.path(light.endpoint, OnOffCluster.id, OnOffCluster.Attribute.startUpOnOff), onOff)]
        if value.behaviour != .off {
            if light.level {
                let level: TLVValue = value.behaviour == .custom ? value.brightness.map { .unsigned(UInt64(LevelControlCluster.level(percent: Double($0)))) } ?? .null : .null
                writes.append((Self.path(light.endpoint, LevelControlCluster.id, LevelControlCluster.Attribute.startUpCurrentLevel), level))
            }
            if let whites {
                let mirek = [.custom, .natural].contains(value.behaviour) ? value.mirek.map { min(whites.upperBound, max(whites.lowerBound, $0)) } : nil
                writes.append((Self.path(light.endpoint, ColorControlCluster.id, ColorControlCluster.Attribute.startUpColorTemperatureMireds),
                               mirek.map { .unsigned(UInt64($0)) } ?? .null))
            }
        }
        try await light.link.write(writes)
    }
}
