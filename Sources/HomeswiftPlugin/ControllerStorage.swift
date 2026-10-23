import Foundation
import Homeswift
import NIOConcurrencyHelpers

/// The saved states of the controllers of one platform instance (Adaptive Lighting schedules, camera recording
/// settings), HAP-NodeJS's ControllerStorage: `controllers/<platform>-<name>.json` next to the accessory cache,
/// keyed by accessory id, then controller id.
final class ControllerStorage: Sendable {
    var url: URL { states.url }
    private let states: PersistedDictionary<[String: Data]>

    init(url: URL) { states = PersistedDictionary(url: url, autosave: nil) }

    func state(accessoryID: String, controllerID: String) -> Data? {
        states[accessoryID]?[controllerID]
    }

    /// Writes the file when the state changed.
    func save(_ data: Data?, accessoryID: String, controllerID: String) throws {
        let changed = states.update(accessoryID) { controllers in
            var updated = controllers ?? [:]
            updated[controllerID] = data
            controllers = updated.isEmpty ? nil : updated
        }
        guard changed else { return }
        try states.flush()
    }
}

extension PluginContext {
    /// The controller storage of this instance, next to its accessory cache.
    var controllerStorage: ControllerStorage {
        controllerStorages.withLockedValue { storages in
            if let existing = storages[cache.url.path] { return existing }
            let directory = cache.url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("controllers")
            let storage = ControllerStorage(url: directory.appendingPathComponent(cache.url.lastPathComponent))
            storages[cache.url.path] = storage
            return storage
        }
    }

    /// Restores a controller's saved state (an Adaptive Lighting schedule, a camera's recording settings) and saves
    /// it on every change, as Homebridge's `accessory.configureController`. Call it when the accessory is built,
    /// with the accessory's id; the state follows the accessory across launches.
    public func configureController(_ controller: some SerializableController, accessoryID: String) {
        let storage = controllerStorage
        let controllerID = controller.controllerID
        if let saved = storage.state(accessoryID: accessoryID, controllerID: controllerID) {
            do {
                try controller.deserialize(saved)
            } catch {
                logger.warning("Ignoring an unreadable controller state", metadata: ["accessory": "\(accessoryID)", "controller": "\(controllerID)", "error": "\(error)"])
            }
        }
        let logger = logger
        controller.setupStateChangeDelegate { [weak controller] in
            guard let controller else { return }
            do {
                try storage.save(controller.serialize(), accessoryID: accessoryID, controllerID: controllerID)
            } catch {
                logger.warning("Could not save a controller state", metadata: ["path": "\(storage.url.path)", "error": "\(error)"])
            }
        }
    }
}

/// One storage per file, shared by the contexts of an instance (a reload creates a new context).
let controllerStorages = NIOLockedValueBox<[String: ControllerStorage]>([:])
