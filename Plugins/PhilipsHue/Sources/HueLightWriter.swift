import Foundation
import Homeswift
import HomeswiftPlugin

/// A light's gathered changes (`LightChangeBatcher`) as the one PUT the bridge takes them in, with the transition.
/// Hue needs saturation to make a colour, so a hue or saturation alone takes the other from the lightbulb.
final class HueLightCommand: @unchecked Sendable {
    let lightID: String
    private let gamut: HueGamut
    private let transitionMs: Int
    /// The lightbulb's current hue and saturation, for a change that has only one of them.
    private let currentColour: @Sendable () -> (hue: Double, saturation: Double)
    private let lock = NSLock()
    private var sentColour: (xy: HueXY, hue: Double, saturation: Double)?

    init(lightID: String, gamut: HueGamut, transitionMs: Int, currentColour: @escaping @Sendable () -> (hue: Double, saturation: Double)) {
        self.lightID = lightID
        self.gamut = gamut
        self.transitionMs = transitionMs
        self.currentColour = currentColour
    }

    /// The last colour sent, and the hue and saturation it came from: the gamut moves a colour a little (pure red is
    /// about 9° on gamut C), so while the light reports that colour HomeKit keeps the values it asked for.
    var lastColour: (xy: HueXY, hue: Double, saturation: Double)? { lock.withLock { sentColour } }

    /// The PUT body: on, dimming, the colour or the white, and the transition.
    func body(for changes: LightChangeBatcher.Changes) -> JSONValue {
        var body: [String: JSONValue] = [:]
        if let on = changes.on { body["on"] = ["on": .bool(on)] }
        if let brightness = changes.brightness { body["dimming"] = ["brightness": .number(min(max(brightness, 0), 100))] }
        if changes.hue != nil || changes.saturation != nil {
            let current = currentColour()
            let (hue, saturation) = (changes.hue ?? current.hue, changes.saturation ?? current.saturation)
            let point = HueColor.xy(hue: hue, saturation: saturation, gamut: gamut)
            let xy = HueXY(x: Self.round(point.x), y: Self.round(point.y))
            lock.withLock { sentColour = (xy, hue, saturation) }
            body["color"] = ["xy": ["x": .number(xy.x), "y": .number(xy.y)]]
        } else if let mirek = changes.mirek {
            body["color_temperature"] = ["mirek": .number(Double(mirek))]
        }
        // A light switched off goes off at once; everything else takes the transition.
        if changes.on != false || body.count > 1 { body["dynamics"] = ["duration": .number(Double(transitionMs))] }
        return .object(body)
    }

    static func round(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }
}
