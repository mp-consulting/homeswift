import Foundation
import HomeswiftPlugin

// An animated scene's effect played the way the eWeLink app does: a SONOFF L2 strip (UIID 137) has scenes of its own,
// chosen by `mode` (homebridge-ewelink's light-rgb-cct.js lists them: 9 Sunrise, 13 Candle, 24 Rainbow, 26 Sunset…;
// 4 follows the music). Other eWeLink lights have none: Homeswift's player plays them. Stopping goes back to the
// colour mode (1); Homeswift then puts the values back.

extension EWeLinkPlugin {
    /// The L2's scene for each style it has one for.
    static let l2Modes: [LightEffect.Style: Int] = [
        .candle: 13, .sunrise: 9, .sunset: 26, .prism: 24, .palette: 24, .underwater: 19, .cosmos: 25, .sunbeam: 10, .enchant: 12, .music: 4,
    ]
    static let l2UIID = 137

    public func animate(_ effect: LightEffect, accessoryIDs: [String]) async -> Set<String> {
        guard let mode = Self.l2Modes[effect.style], let core = await platformCore() else { return [] }
        // Music in its Classic rhythm, as the app starts it.
        var params: DeviceParams = ["switch": "on", "mode": .number(Double(mode))]
        if effect.style == .music { (params["rhythmMode"], params["rhythmSensitive"]) = (0, 0) }
        return await core.sendToL2(accessoryIDs, params)
    }

    public func stopAnimation(accessoryIDs: [String]) async {
        guard let core = await platformCore() else { return }
        _ = await core.sendToL2(accessoryIDs, ["mode": 1])
    }
}

extension EWeLinkPlatform {
    /// Sends the same command to those of these accessories that are L2 strips; answers those it reached.
    func sendToL2(_ accessoryIDs: [String], _ params: DeviceParams) async -> Set<String> {
        var reached: Set<String> = []
        for id in accessoryIDs {
            let prefix = "\(EWeLinkPlugin.platform):"
            guard id.hasPrefix(prefix) else { continue }
            let deviceID = String(id.dropFirst(prefix.count))
            guard registry.device(deviceID)?.uiid == EWeLinkPlugin.l2UIID, await sendDeviceCommand(deviceID, params) else { continue }
            reached.insert(id)
        }
        return reached
    }
}
