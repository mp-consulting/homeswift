import Foundation
import Homeswift
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// A TV (docs/clean-room/SmartThings.md, section 9): a Television with its inputs and speaker, published on its own
/// (`context.publishExternal`) unless `publishTVsAsExternal` is false.
enum TelevisionDetection {
    static func isTelevision(_ device: SmartThingsDevice) -> Bool {
        if device.mainCategory == "Television" { return true }
        let groups: [[String]] = [["samsungvd.deviceCategory"], ["samsungvd.mediaInputSource"], ["audioVolume", "audioMute"], ["tvChannel"]]
        return groups.filter { group in group.contains(where: device.has) }.count >= 2
    }
}

struct TVInput: Sendable, Equatable {
    var id: String
    var name: String
    var type: Int
    var isApp: Bool

    static func type(of id: String) -> Int {
        let lower = id.lowercased()
        if lower == "dtv" || lower == "digitaltv" { return HAPConstants.InputSourceType.tuner }
        if lower.hasPrefix("hdmi") { return HAPConstants.InputSourceType.hdmi }
        if lower == "usb" { return HAPConstants.InputSourceType.usb }
        if lower == "component" { return HAPConstants.InputSourceType.componentVideo }
        if lower == "composite" { return HAPConstants.InputSourceType.compositeVideo }
        return HAPConstants.InputSourceType.other
    }

    /// The TV's inputs (section 9.2): Samsung's map (the longer name of a repeated id), else the standard list, else
    /// Live TV and four HDMI; then one per `tvApps` entry.
    static func inputs(status: DeviceStatus, apps: [String]) -> [TVInput] {
        var list: [TVInput] = []
        if let map = status.value("main", "samsungvd.mediaInputSource", "supportedInputSourcesMap")?.arrayValue, !map.isEmpty {
            for entry in map {
                guard let id = entry["id"]?.stringValue, !id.isEmpty else { continue }
                let name = entry["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? id
                if let index = list.firstIndex(where: { $0.id == id }) {
                    if name.count > list[index].name.count { list[index].name = name }
                } else {
                    list.append(TVInput(id: id, name: name, type: type(of: id), isApp: false))
                }
            }
        } else if let sources = status.strings("main", "mediaInputSource", "supportedInputSources"), !sources.isEmpty {
            for id in sources where !list.contains(where: { $0.id == id }) { list.append(TVInput(id: id, name: id, type: type(of: id), isApp: false)) }
        } else {
            list = [TVInput(id: "dtv", name: "Live TV", type: HAPConstants.InputSourceType.tuner, isApp: false)]
                + (1...4).map { TVInput(id: "HDMI\($0)", name: "HDMI\($0)", type: HAPConstants.InputSourceType.hdmi, isApp: false) }
        }
        for app in apps where !list.contains(where: { $0.id == app }) {
            list.append(TVInput(id: app, name: SmartThingsSettings.tvAppNames[app] ?? app, type: HAPConstants.InputSourceType.application, isApp: true))
        }
        return list
    }
}

extension AccessoryBuilder {
    /// The TV's capabilities on `main` that the Television takes (section 9.1).
    static let televisionCapabilities = [
        "switch", "samsungvd.deviceCategory", "samsungvd.mediaInputSource", "mediaInputSource", "custom.launchapp", "audioVolume", "audioMute", "tvChannel",
        "mediaPlayback", "mediaTrackControl", "keypadInput", "custom.picturemode", "custom.soundmode",
    ]

    mutating func television() {
        kind = "television"
        category = .television
        let main = device.main
        func has(_ capability: String) -> Bool { main?.has(capability) ?? false }
        let inputs = TVInput.inputs(status: status, apps: settings.tvApps)
        let hidden = Swift.Set(options.hiddenInputs)
        let writer = writer
        let box = box
        let inputServices = inputs.enumerated().map { index, input -> Service in
            let service = Service(.inputSource, name: input.name, subtype: "main/input.\(input.id)", optional: [.identifier, .targetVisibilityState])
            service.characteristic(.configuredName).value = .string(input.name)
            service.characteristic(.inputSourceType).value = .int(input.type)
            service.characteristic(.isConfigured).value = .int(HAPConstants.IsConfigured.configured)
            let visibility = hidden.contains(input.id) ? HAPConstants.CurrentVisibilityState.hidden : HAPConstants.CurrentVisibilityState.shown
            service.characteristic(.currentVisibilityState).value = .int(visibility)
            service.characteristic(.targetVisibilityState).value = .int(visibility)
            service.characteristic(.identifier).value = .int(index + 1)
            service.characteristic(.targetVisibilityState).onWrite { value in
                service.characteristic(.currentVisibilityState).value = .int(value.intValue == 1 ? 1 : 0)
            }
            return service
        }
        let speaker = Service(.televisionSpeaker, name: serviceName("main", "Speaker"), subtype: "main/speaker",
                              optional: [.active, .volumeControlType, .volumeSelector] + (has("audioVolume") ? [.volume] : []))
        speaker.characteristic(.active).value = .int(1)
        speaker.characteristic(.volumeControlType).value = .int(has("audioVolume") ? HAPConstants.VolumeControlType.absolute : HAPConstants.VolumeControlType.relative)
        let hasVolume = has("audioVolume")
        speaker.characteristic(.mute).onWrite { value in
            let muted = value.boolValue == true
            do {
                try await writer.send([DeviceCommand("main", "audioMute", "setMute", [.string(muted ? "muted" : "unmuted")])], set: [("main", "audioMute", "mute", .string(muted ? "muted" : "unmuted"))])
            } catch let error as HAPStatusError where error.status == .invalidValueInRequest {
                try await writer.send([DeviceCommand("main", "audioMute", muted ? "mute" : "unmute")], set: [("main", "audioMute", "mute", .string(muted ? "muted" : "unmuted"))])
            }
        }
        speaker.characteristic(.volumeSelector).onWrite { value in
            guard hasVolume else { return }
            try await writer.send([DeviceCommand("main", "audioVolume", value.intValue == 0 ? "volumeUp" : "volumeDown")])
        }
        @Sendable func setVolume(_ level: Int) async throws {
            guard await writer.isLatest("main/volume") else { return }
            var commands: [DeviceCommand] = []
            var set: Writer.Set = [("main", "audioVolume", "volume", .number(Double(level)))]
            if level > 0, box.status.string("main", "audioMute", "mute") == "muted" {
                commands.append(DeviceCommand("main", "audioMute", "unmute"))
                set.append(("main", "audioMute", "mute", "unmuted"))
            }
            commands.append(DeviceCommand("main", "audioVolume", "setVolume", [.number(Double(level))]))
            try await writer.send(commands, set: set)
        }
        if hasVolume {
            speaker.characteristic(.volume).onWrite(changesOnly: true) { value in try await setVolume(Convert.percent(value.doubleValue) ?? 0) }
        }
        let television = Service(.television, name: name, subtype: "main/television", optional: [.pictureMode], linked: inputServices + [speaker], isPrimary: true)
        primary = television
        television.characteristic(.configuredName).value = .string(name)
        television.characteristic(.sleepDiscoveryMode).value = .int(HAPConstants.SleepDiscoveryMode.alwaysDiscoverable)
        bindOn(television, "main", characteristic: .active)
        let hasSamsungInputs = has("samsungvd.mediaInputSource")
        television.characteristic(.activeIdentifier).onWrite { value in
            let index = (value.intValue ?? 1) - 1
            guard inputs.indices.contains(index) else { throw HAPStatusError(.invalidValueInRequest) }
            let input = inputs[index]
            if input.isApp {
                try await writer.send([DeviceCommand("main", "custom.launchapp", "launchApp", [.string(input.id)])])
            } else if hasSamsungInputs {
                do {
                    try await writer.send([DeviceCommand("main", "samsungvd.mediaInputSource", "setInputSource", [.string(input.id)])],
                                          set: [("main", "samsungvd.mediaInputSource", "inputSource", .string(input.id))])
                } catch {
                    try await writer.send([DeviceCommand("main", "mediaInputSource", "setInputSource", [.string(input.id)])],
                                          set: [("main", "mediaInputSource", "inputSource", .string(input.id))])
                }
            } else {
                try await writer.send([DeviceCommand("main", "mediaInputSource", "setInputSource", [.string(input.id)])],
                                      set: [("main", "mediaInputSource", "inputSource", .string(input.id))])
            }
        }
        let keypad = has("keypadInput"), playback = has("mediaPlayback"), tracks = has("mediaTrackControl"), channels = has("tvChannel")
        television.characteristic(.remoteKey).onWrite { value in
            let status = box.status
            let supported = status.strings("main", "keypadInput", "supportedKeyCodes")
            func keyCommand(_ key: String) -> DeviceCommand? {
                guard keypad, supported?.contains(key) ?? true else { return nil }
                return DeviceCommand("main", "keypadInput", "sendKey", [.string(key)])
            }
            let command: DeviceCommand? = switch value.intValue ?? -1 {
            case HAPConstants.RemoteKey.arrowUp: keyCommand("UP")
            case HAPConstants.RemoteKey.arrowDown: keyCommand("DOWN")
            case HAPConstants.RemoteKey.arrowLeft: keyCommand("LEFT")
            case HAPConstants.RemoteKey.arrowRight: keyCommand("RIGHT")
            case HAPConstants.RemoteKey.select: keyCommand("SELECT")
            case HAPConstants.RemoteKey.back: keyCommand("BACK")
            case HAPConstants.RemoteKey.exit: keyCommand("EXIT")
            case HAPConstants.RemoteKey.information: keyCommand("MENU") ?? keyCommand("SETTINGS")
            case HAPConstants.RemoteKey.playPause:
                playback ? DeviceCommand("main", "mediaPlayback", status.string("main", "mediaPlayback", "playbackStatus") == "playing" ? "pause" : "play") : nil
            case HAPConstants.RemoteKey.rewind: playback ? DeviceCommand("main", "mediaPlayback", "rewind") : nil
            case HAPConstants.RemoteKey.fastForward: playback ? DeviceCommand("main", "mediaPlayback", "fastForward") : nil
            case HAPConstants.RemoteKey.nextTrack:
                tracks ? DeviceCommand("main", "mediaTrackControl", "nextTrack") : channels ? DeviceCommand("main", "tvChannel", "channelUp") : nil
            case HAPConstants.RemoteKey.previousTrack:
                tracks ? DeviceCommand("main", "mediaTrackControl", "previousTrack") : channels ? DeviceCommand("main", "tvChannel", "channelDown") : nil
            default: nil
            }
            // A key the TV does not have does nothing, without an error (section 9.2).
            guard let command else { return }
            try await writer.send([command])
        }
        if has("custom.picturemode") {
            television.characteristic(.pictureMode).onWrite { value in
                let mode = value.intValue == 6 ? "Dynamic" : "Standard"
                try await writer.send([DeviceCommand("main", "custom.picturemode", "setPictureMode", [.string(mode)])], set: [("main", "custom.picturemode", "pictureMode", .string(mode))])
            }
        }
        services = [television] + inputServices + [speaker]
        if settings.registerVolumeSlider {
            let slider = Service(.lightbulb, name: serviceName("main", "Volume"), subtype: "main/volume", optional: [.brightness])
            slider.characteristic(.on).onWrite { value in
                let muted = value.boolValue != true
                try await writer.send([DeviceCommand("main", "audioMute", muted ? "mute" : "unmute")], set: [("main", "audioMute", "mute", .string(muted ? "muted" : "unmuted"))])
            }
            if hasVolume { slider.characteristic(.brightness).onWrite(changesOnly: true) { value in try await setVolume(Convert.percent(value.doubleValue) ?? 0) } }
            services.append(slider)
            update { status in
                slider.set(.on, status.string("main", "audioMute", "mute").map { .bool($0 != "muted") })
                slider.set(.brightness, Convert.percent(status.number("main", "audioVolume", "volume")).map { .int($0) })
            }
        }
        update { status in
            // A TV fully off reports OFFLINE: Active 0, not an error (section 9.2).
            let on = status.health != "OFFLINE" && status.string("main", "switch", "switch") == "on"
            television.set(.active, .int(on ? 1 : 0))
            let source = status.string("main", "samsungvd.mediaInputSource", "inputSource") ?? status.string("main", "mediaInputSource", "inputSource")
            let app = status.string("main", "custom.launchapp", "appId")
            if let index = inputs.firstIndex(where: { (!$0.isApp && $0.id == source) || ($0.isApp && $0.id == app) }) {
                television.set(.activeIdentifier, .int(index + 1))
            }
            speaker.set(.mute, status.string("main", "audioMute", "mute").map { .bool($0 == "muted") })
            if hasVolume { speaker.set(.volume, Convert.percent(status.number("main", "audioVolume", "volume")).map { .int($0) }) }
            if let mode = status.string("main", "custom.picturemode", "pictureMode") { television.set(.pictureMode, .int(mode == "Dynamic" ? 6 : 4)) }
        }
        consume("main", Self.televisionCapabilities)
    }
}
