import Foundation
import HomeswiftPlugin

// A light's Power On (GLOSSARY.md), for its sheet on the bridge's pages and for the Assistant: what its device can do,
// what it does now, and Natural Light, the bridge's own (`PowerOn.swift`). The device's own behaviours are written to
// the device; Natural Light is the Core Accessory Setting `naturalLight` (cleared: on), which the bridge runs.

extension HomeswiftCatalog {
    /// A light's Power On: its device's `support`, its `behaviour` and `current` value, and `naturalWhite`, the white
    /// Natural Light gives it now.
    public func powerOnJSON(_ id: String, now: Date = Date()) async throws -> JSONValue {
        guard let located = find(id: id) else { throw CatalogError("No accessory \(id)", notFound: true) }
        guard let state = try await host.powerOn(of: id) else {
            throw CatalogError("\(located.accessory.name) keeps no Power On: its plugin cannot set what it does when its power comes on", notFound: true)
        }
        let white = state.support.white.map { range in
            min(range.upperBound, max(range.lowerBound, NaturalLight.temperature(at: now, location: host.configuration.location)))
        }
        let current = state.natural ? PowerOn(.natural, temperature: white) : state.device
        return ["accessory": .string(id), "name": .string(located.accessory.name), "support": state.support.json,
                "behaviour": current.map { .string($0.behaviour.rawValue) } ?? .null, "current": current?.json ?? .null,
                "naturalWhite": white.map { .number(Double($0)) } ?? .null]
    }

    /// Gives a light a Power On: Natural Light (the bridge's), or one of its device's own, written to the device. Answers
    /// `powerOnJSON`.
    public func setPowerOn(_ value: PowerOn, of id: String, dryRun: Bool = false, by writer: ConfigWriter = .person, who: String = "web UI") async throws -> JSONValue {
        guard let located = find(id: id) else { throw CatalogError("No accessory \(id)", notFound: true) }
        guard let state = try await host.powerOn(of: id) else {
            throw CatalogError("\(located.accessory.name) keeps no Power On: its plugin cannot set what it does when its power comes on", notFound: true)
        }
        guard state.support.behaviours.contains(value.behaviour) else {
            throw CatalogError("\(located.accessory.name) can come back: \(state.support.behaviours.map(\.rawValue).joined(separator: ", "))")
        }
        var value = value
        if value.behaviour == .custom {
            if value.brightness != nil, !state.support.brightness { throw CatalogError("\(located.accessory.name) takes no power-on brightness") }
            if let kelvin = value.temperature {
                guard let range = state.support.white else { throw CatalogError("\(located.accessory.name) has no white to come back in") }
                value.temperature = min(range.upperBound, max(range.lowerBound, kelvin))
            }
        }
        if dryRun { return try await powerOnJSON(id) }
        if value.behaviour == .natural {
            if !state.natural { _ = try await updateAccessorySettings([(id, ["naturalLight": .null])], by: writer, who: who) }
            await host.refreshNaturalLight(of: id)
        } else {
            try await host.setDevicePowerOn(value, of: id)
            if state.natural { _ = try await updateAccessorySettings([(id, ["naturalLight": false])], by: writer, who: who) }
        }
        return try await powerOnJSON(id)
    }

    var powerOnTools: [MCPTool] {
        let catalog = self
        let behaviours = JSONValue.array(PowerOn.Behaviour.allCases.map { .string($0.rawValue) })
        return [
            MCPTool(
                name: "power_on", title: "A light's Power On",
                description: "What a light does when its power comes back, from a wall switch or after a power cut (its Power On): what its device can do "
                    + "(support: behaviours, a brightness, its whites in Kelvin), what it does now, and the white Natural Light gives it now. Behaviours: natural "
                    + "(the bridge's Natural Light: as it was, on or off, in the white for the time of day, every light's that can have it unless given another), "
                    + "default (its device's default), lastOn (on, last colour and brightness), powerLoss (as it was before the power went), off, custom "
                    + "(on at a brightness and white).",
                inputSchema: ["type": "object", "required": ["accessory"], "properties": ["accessory": ["type": "string", "maxLength": 200, "description": "The light's accessory id"]]],
                scope: .read, idempotent: true
            ) { call in
                .json(try await catalog.powerOnJSON(try call.string("accessory")))
            },
            MCPTool(
                name: "set_power_on", title: "Set a light's Power On",
                description: "Sets what a light does when its power comes back (power_on says what its device can do): natural (the bridge keeps it in the "
                    + "white for the time of day, as it was, on or off), or one of its device's own, written to the device: default, lastOn, powerLoss, off, or "
                    + "custom with brightness (1-100 %) and temperature (Kelvin, within its whites). dryRun checks without changing anything.",
                inputSchema: ["type": "object", "required": ["accessory", "behaviour"], "properties": [
                    "accessory": ["type": "string", "maxLength": 200, "description": "The light's accessory id"],
                    "behaviour": ["type": "string", "enum": behaviours],
                    "brightness": ["type": "integer", "minimum": 1, "maximum": 100], "temperature": ["type": "integer", "minimum": 1000, "maximum": 10000],
                ]],
                scope: .admin, supportsDryRun: true
            ) { call in
                let value: PowerOn
                do { value = try PowerOn(json: call.arguments) } catch let error as PowerOnError { throw CatalogError(error.description) }
                let who = "MCP \(call.session.clientInfo?.name ?? "client")"
                return .json(try await catalog.setPowerOn(value, of: try call.string("accessory"), dryRun: call.isDryRun, by: .client, who: who))
            },
        ]
    }
}
