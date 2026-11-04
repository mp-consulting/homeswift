import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// Where pushes come from: the FCM receiver, or a fake in tests.
protocol RingPushSource: Sendable {
    var events: AsyncStream<FCMReceiver.Event> { get }
    var token: String? { get async }
    func start() async
    func stop() async
}

extension FCMReceiver: RingPushSource {}

/// Ring's pushes (docs/clean-room/Ring.md, 3.6 and 11): an FCM client of Ring's Android app's Firebase project.
enum RingPush {
    /// Public identifiers embedded in Ring's Android app (not secrets): its Firebase project.
    static let configuration = FCMReceiver.Configuration(
        apiKey: "AIzaSyCv-hdFBmmdBBJadNy-TFwB-xN_H5m3Bk8", projectID: "ring-17770", appID: "1:876313859327:android:e10ec6ddb3c81f39",
        messagingSenderID: "876313859327")

    enum Route: Equatable {
        case notification(RingNotification)
        case intercomUnlocked(deviceID: String)
        case ignored
    }

    /// Where a push goes: a camera's or an intercom's ding or motion (v2, with `android_config`), or an intercom
    /// unlocked from the app (v1, `gcmData.alarm_meta`).
    static func route(_ data: [String: String]) -> Route {
        var parsed: [String: JSONValue] = [:]
        for (key, value) in data { parsed[key] = (try? JSONValue(string: quotingLargeIntegers(value))) ?? .string(value) }
        if let android = parsed["android_config"], let category = android["category"]?.stringValue {
            guard let deviceID = parsed["data"]?["device"]?["id"]?.idString else { return .ignored }
            let ding = parsed["data"]?["event"]?["ding"]
            let uuid = parsed["img"]?["snapshot_uuid"]?.stringValue.map { String($0.prefix { $0 != ":" }) }
            return .notification(RingNotification(deviceID: deviceID, category: category, dingID: ding?["id"]?.idString, snapshotUUID: uuid))
        }
        if let gcm = parsed["data"]?["gcmData"], let device = gcm["alarm_meta"]?["device_zid"]?.idString {
            if gcm["action"]?.stringValue == "com.ring.push.INTERCOM_UNLOCK_FROM_APP" { return .intercomUnlocked(deviceID: device) }
        }
        return .ignored
    }

    /// JSON with every integer too large for a double (ding ids exceed 2^53) turned into a string, so it keeps its digits.
    static func quotingLargeIntegers(_ json: String) -> String {
        var output = ""
        output.reserveCapacity(json.count)
        var inString = false, escaped = false
        var number = ""
        func flush() {
            guard !number.isEmpty else { return }
            let digits = number.filter(\.isNumber)
            let integer = !number.contains(where: { ".eE".contains($0) })
            output += integer && digits.count > 15 ? "\"\(number)\"" : number
            number = ""
        }
        for character in json {
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            if character.isNumber || "-+.eE".contains(character), character.isASCII {
                number.append(character)
                continue
            }
            flush()
            if character == "\"" { inString = true }
            output.append(character)
        }
        flush()
        return output
    }
}
