import Foundation
import Homeswift
import HomeswiftPlugin

// Homeswift's scenes in the Home app: a scene whose `homeKit` is on is a switch of one "Homeswift Scenes" accessory
// on the main bridge (subtype `scene:<id>`, so its iid stays while the scene does). Turning it on runs the scene,
// leaving out its locks, doors and alarms, as an automation does; turning it off puts back what it changed. The switch
// shows whether the scene is active or can be stopped. The plugins' own scene switches stay as they are.
// docs/scenes-design.md, "Surfaces".

extension HomeswiftCatalog {
    static let sceneSwitchesID = "Homeswift:scenes"

    /// Publishes the switches of the scenes chosen for HomeKit, or removes the accessory when none is.
    func syncSceneSwitches() {
        let server = host.mainBridge.server
        let chosen = home.scenes.value.scenes.filter { $0.homeKit == true }
        let existing = server.accessories.first { $0.id == Self.sceneSwitchesID }
        guard !chosen.isEmpty else {
            if let existing { try? server.remove(existing) }
            return
        }
        // Same scenes under the same names: only the switches' states change.
        if let existing, Set(existing.services.compactMap(\.subtype)) == Set(chosen.map { "scene:" + $0.id }),
           chosen.allSatisfy({ scene in existing.services.first { $0.subtype == "scene:" + scene.id }?[.name]?.value.stringValue == scene.name }) {
            refreshSceneSwitches()
            return
        }
        let catalog = self
        let services = chosen.map { scene in
            let service = Service(.switch, name: scene.name, subtype: "scene:" + scene.id)
            service.characteristic(.on).value = .bool(sceneSwitchIsOn(scene))
            let id = scene.id
            service.characteristic(.on).onWrite { value in
                let on = value.boolValue ?? false
                Task {
                    do {
                        if on { _ = try await catalog.runScene(id, trigger: .homeKit) } else { _ = try await catalog.stopScene(id) }
                    } catch {
                        catalog.logger.warning("The Home app's switch for a scene did not \(on ? "run" : "stop") it: \(error)")
                    }
                    catalog.refreshSceneSwitches()
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
        guard let accessory = host.mainBridge.server.accessories.first(where: { $0.id == Self.sceneSwitchesID }) else { return }
        for scene in home.scenes.value.scenes where scene.homeKit == true {
            guard let on = accessory.services.first(where: { $0.subtype == "scene:" + scene.id })?[.on] else { continue }
            let value = HAPValue.bool(sceneSwitchIsOn(scene))
            if on.value != value { on.value = value }
        }
    }

    private func sceneSwitchIsOn(_ scene: Scene) -> Bool {
        isActive(scene) || home.lightRuns.withLockedValue { $0.values.contains { $0.show.id == "scene:" + scene.id } }
    }
}
