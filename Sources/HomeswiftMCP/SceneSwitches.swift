import Foundation
import Homeswift
import HomeswiftPlugin

// Homeswift's scenes in the Home app: a scene whose `homeKit` is on is a switch of one "Homeswift Scenes" accessory
// on the main bridge (subtype `scene:<id>`, so its iid stays while the scene does). Turning it on runs the scene,
// leaving out its locks, doors and alarms, as an automation does; turning it off puts back what it changed. The switch
// shows whether the scene is active or can be stopped. The plugins' own scene switches stay as they are.
// docs/scenes-design.md, "Surfaces".
//
// Each switch carries the scene's name in Name and Configured Name: the Home app keeps its own name for a paired
// accessory's services and does not follow Name, but it follows Configured Name, and writes it when the switch is
// renamed there, which renames the scene (homebridge-plugin-utils's `setServiceName` sets both the same way).

extension HomeswiftCatalog {
    static let sceneSwitchesID = "Homeswift:scenes"

    /// Publishes the switches of the scenes chosen for HomeKit, or removes the accessory when none is.
    func syncSceneSwitches() {
        let server = host.mainBridge.server
        let chosen = home.scenes.value.scenes.filter { $0.homeKit == true }
        let existing = server.accessory(id: Self.sceneSwitchesID)
        guard !chosen.isEmpty else {
            if let existing { try? server.remove(existing) }
            return
        }
        // Same scenes, each switch with its Configured Name: a renamed scene's switch is renamed in place, so the
        // controllers following it get the new name as an event, and only the switches' states change.
        if let existing, Set(existing.services.compactMap(\.subtype)) == Set(chosen.map { "scene:" + $0.id }),
           existing.services.allSatisfy({ $0.subtype == nil || $0[.configuredName] != nil }) {
            for scene in chosen {
                guard let service = existing.services.first(where: { $0.subtype == "scene:" + scene.id }) else { continue }
                for name in [service[.name], service[.configuredName]].compactMap({ $0 }) where name.value != .string(scene.name) {
                    name.value = .string(scene.name)
                }
            }
            refreshSceneSwitches()
            return
        }
        let catalog = self
        let services = chosen.map { scene in
            let service = Service(.switch, name: scene.name, subtype: "scene:" + scene.id, optional: [.configuredName])
            service.characteristic(.configuredName).value = .string(scene.name)
            service.characteristic(.on).value = .bool(sceneSwitchIsOn(scene))
            let id = scene.id
            // Renamed in the Home app: the scene takes the name.
            service.characteristic(.configuredName).onWrite { value in
                guard let name = value.stringValue.flatMap(AccessoryNaming.cleaned) else { return }
                do {
                    try catalog.renameSavedScene(id, to: name)
                } catch {
                    catalog.logger.warning("The Home app's name for a scene's switch was not kept: \(error)")
                }
            }
            // A run or a stop refreshes the switches itself; a failure sets this one back.
            service.characteristic(.on).onWrite { value in
                let on = value.boolValue ?? false
                Task {
                    do {
                        if on { _ = try await catalog.runScene(id, trigger: .homeKit) } else { _ = try await catalog.stopScene(id) }
                    } catch {
                        catalog.logger.warning("The Home app's switch for a scene did not \(on ? "run" : "stop") it: \(error)")
                        catalog.refreshSceneSwitches()
                    }
                }
            }
            return service
        }
        let accessory = Accessory(id: Self.sceneSwitchesID, name: "Homeswift Scenes", manufacturer: "Homeswift", model: "Scenes", category: .switch, services: services)
        do {
            try server.add(accessory)
        } catch {
            logger.warning("Could not publish the scenes' switches: \(error)")
        }
    }

    /// Shows on each switch whether its scene is active, or can still be stopped.
    func refreshSceneSwitches() {
        guard let accessory = host.mainBridge.server.accessory(id: Self.sceneSwitchesID) else { return }
        let switches = Dictionary(accessory.services.compactMap { service in service.subtype.map { ($0, service) } }, uniquingKeysWith: { first, _ in first })
        withLookup {
            for scene in home.scenes.value.scenes where scene.homeKit == true {
                guard let on = switches["scene:" + scene.id]?[.on] else { continue }
                let value = HAPValue.bool(sceneSwitchIsOn(scene))
                if on.value != value { on.value = value }
            }
        }
    }

    /// Renames a saved scene, as the Home app does through its switch's Configured Name; its switch follows.
    func renameSavedScene(_ id: String, to name: String) throws {
        let renamed = try home.scenes.update { file -> Bool in
            guard let index = file.scenes.firstIndex(where: { $0.id == id }) else { throw CatalogError("No scene \(id)", notFound: true) }
            guard file.scenes[index].name != name else { return false }
            file.scenes[index].name = name
            return true
        }
        guard renamed else { return }
        logger.info("Renamed a scene from the Home app", metadata: ["scene": "\(id)", "name": "\(name)"])
        syncSceneSwitches()
    }

    private func sceneSwitchIsOn(_ scene: Scene) -> Bool {
        isActive(scene) || !lightRuns(of: scene.id).isEmpty
    }
}
