import Foundation
import Homeswift

extension PluginContext {
    /// Where the Eve histories the runtime keeps for its accessories are: a file per accessory, by its id in base64url.
    var energyHistoryDirectory: URL { storageURL.appendingPathComponent("eve-energy", isDirectory: true) }

    /// Gives an accessory that measures power (Eve's Current Consumption) and has no Eve history of its plugin's the
    /// Eve app's energy history, kept by the runtime (docs/adr/0004-meters-and-consumption-history.md): the Eve app graphs
    /// its power as it does a plug's of its own, whatever plugin made it. The history is fed by the accessory's power as
    /// it changes (repeated each ten minutes while it does not), kept in the plugin's storage, and saved when the plugin
    /// stops. Its service has the accessory's iids from one launch to the next: its type and subtype stay.
    func attachEnergyHistory(to accessory: Accessory) {
        guard !accessory.services.contains(where: { $0.type.uuid == ServiceType.eveHistory.uuid }),
              let power = accessory.services.lazy.flatMap(\.characteristics).first(where: { $0.type.uuid == EveCharacteristic.currentConsumption.uuid })
        else { return }
        // One history per accessory: one the plugin adds again (a reload, a new object for the same device) keeps it.
        let (history, first) = energyHistories.withLockedValue { histories -> (EveHistory, Bool) in
            if let known = histories[accessory.id] { return (known, false) }
            let file = energyHistoryDirectory.appendingPathComponent("\(Secrets.base64URL(Data(accessory.id.utf8))).json")
            let made = EveHistory(.energy, accessoryName: accessory.name, size: 4032, storageURL: file)
            let isFirst = histories.isEmpty
            histories[accessory.id] = made
            return (made, isFirst)
        }
        accessory.append(history.service)
        _ = power.observe { [weak history] change in
            if let watts = change.newValue.doubleValue { history?.add(EveHistory.Entry(power: watts)) }
        }
        // Saved when the plugin stops: every history, once.
        if first {
            storeFlushes.withLockedValue { $0.append((isAlive: { true }, flush: { [weak self] in
                for history in self?.energyHistories.withLockedValue({ Array($0.values) }) ?? [] { history.flush() }
            })) }
        }
    }
}
