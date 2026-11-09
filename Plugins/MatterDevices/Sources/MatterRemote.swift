import Foundation
import Homeswift
import HomeswiftPlugin
import Matter

/// A remote's wheel or rocker channel (BILRESA's, GLOSSARY.md "Channel"): two rotary Switch endpoints, one for each
/// direction, and the button that usually follows them.
struct WheelChannel: Sendable, Equatable {
    var number: Int
    var up: EndpointNumber
    var down: EndpointNumber
    var press: EndpointNumber?

    /// A remote's channels, in endpoint order: two rotary endpoints in a row make one, with the button after them.
    static func channels(_ structure: NodeStructure) -> [WheelChannel] {
        let switches = structure.switches
        var channels: [WheelChannel] = []
        var index = 0
        while index + 1 < switches.count {
            let first = switches[index], second = switches[index + 1]
            guard first.isRotary, second.isRotary else { index += 1; continue }
            var channel = WheelChannel(number: channels.count + 1, up: first.id, down: second.id)
            if index + 2 < switches.count, !switches[index + 2].isRotary {
                channel.press = switches[index + 2].id
                index += 3
            } else {
                index += 2
            }
            channels.append(channel)
        }
        return channels
    }
}

/// Turns a Wheel's Switch events into notches (Application Clusters §1.13.6, §1.13.8): a turn reports MultiPressOngoing
/// with the presses counted so far, about twice a second, then MultiPressComplete; each new press is a notch.
struct WheelGestures: Sendable {
    /// Presses already counted of the turn going on, by endpoint.
    private var applied: [EndpointNumber: Int] = [:]

    /// The notches a Switch event of a Wheel's direction adds, up when positive; nil for none.
    mutating func notches(_ event: EventID, data: TLVValue, endpoint: EndpointNumber, up: Bool) -> Int? {
        let total: Int
        switch event {
        case SwitchCluster.Event.initialPress where applied[endpoint] == nil:
            applied[endpoint] = 0
            return nil
        case SwitchCluster.Event.shortRelease:
            // A turn's first ShortRelease counts one before any MultiPressOngoing.
            total = max(applied[endpoint] ?? 0, 1)
        case SwitchCluster.Event.multiPressOngoing, SwitchCluster.Event.multiPressComplete:
            // The running count of this turn, as the remote reports it.
            total = Int(data[1]?.uint ?? 0)
        default:
            return nil
        }
        var done = applied[endpoint] ?? 0
        // A count lower than what was applied is a new turn whose start was missed (its MultiPressComplete lost with a
        // subscription): it counts from nothing.
        if total < done { done = 0 }
        applied[endpoint] = event == SwitchCluster.Event.multiPressComplete ? nil : max(done, total)
        let notches = total - done
        return notches > 0 ? (up ? notches : -notches) : nil
    }
}

/// A Matter remote as the bridge's Remotes have it (`RemoteLayout`): each channel's Wheel and Button, then the other Switch
/// endpoints as Buttons, each part named by its Stateless Programmable Switch (`button:<endpoint>`).
enum MatterRemote {
    static func part(button endpoint: EndpointNumber) -> String { "button:\(endpoint)" }
    static func part(wheel channel: WheelChannel) -> String { "wheel:\(channel.up)" }

    /// The layout of one of the node's accessories, nil when it has no button.
    static func layout(of accessory: Accessory, channels: [WheelChannel]) -> RemoteLayout? {
        let buttons = accessory.services.filter { $0.type == .statelessProgrammableSwitch }.compactMap(\.subtype)
        guard !buttons.isEmpty else { return nil }
        var parts: [RemotePart] = []
        for channel in channels where buttons.contains(part(button: channel.up)) {
            parts.append(RemotePart(id: part(wheel: channel), kind: .wheel, name: "Channel \(channel.number) wheel", channel: channel.number,
                                    services: [part(button: channel.up), part(button: channel.down)]))
            if let press = channel.press {
                parts.append(.button(part(button: press), name: "Channel \(channel.number) button", channel: channel.number))
            }
        }
        let taken = Set(parts.flatMap(\.services))
        for button in buttons where !taken.contains(button) { parts.append(.button(button)) }
        return RemoteLayout(parts: parts)
    }

    /// The moment a Switch event of a Button is (`buttonEvent`'s press for its presses; LongPress and LongRelease hold).
    static func moment(_ event: EventID, press: Int?) -> RemoteMoment? {
        switch event {
        case SwitchCluster.Event.longPress: return .holdStart
        case SwitchCluster.Event.longRelease: return .holdEnd
        default: break
        }
        return switch press {
        case HAPConstants.ProgrammableSwitchEvent.singlePress: .press
        case HAPConstants.ProgrammableSwitchEvent.doublePress: .doublePress
        default: nil
        }
    }
}
