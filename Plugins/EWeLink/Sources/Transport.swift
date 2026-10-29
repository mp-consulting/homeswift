import Foundation
import Homeswift
import HomeswiftNetwork

extension HTTPClient {
    /// The cloud: public certificates, the system's roots; an account's device list fits easily.
    static let eWeLinkCloud = HTTPClient(maximumBodySize: 16 * 1024 * 1024)
    /// Devices on the LAN speak plain HTTP and answer a few bytes of JSON: whatever answers at an address mDNS
    /// gave cannot make the bridge hold more, or follow it elsewhere (no redirects).
    static let eWeLinkLAN = HTTPClient(maximumBodySize: 64 * 1024)
}

/// Time for the plugin's timers and timestamps. Tests run it faster (`scale` 0.01 makes a 10 s timer last
/// 100 ms) and read the matching virtual time from `now`.
struct EWeLinkClock: Sendable {
    let scale: Double
    private let originDate: Date
    private let originInstant: ContinuousClock.Instant
    /// What a test did to plugin time: stopped it, moved it on.
    private let control = Control()

    private final class Control: @unchecked Sendable {
        let lock = NSLock()
        var frozen: Double?
        var offset = 0.0
    }

    init(scale: Double = 1) {
        self.scale = scale
        originDate = Date()
        originInstant = ContinuousClock.now
    }

    /// Tests: plugin time stops where it is (sleeps still pass), until `advance` moves it on.
    func freeze() {
        let now = running
        control.lock.withLock { if control.frozen == nil { control.frozen = now - control.offset } }
    }

    /// Tests: moves plugin time on at once.
    func advance(milliseconds: Double) {
        control.lock.withLock { control.offset += milliseconds }
    }

    /// Sleeps for `milliseconds` of plugin time; throws when the task is cancelled. A delay from a device, the
    /// cloud or the configuration that is negative, NaN or huge sleeps 0 or as long as `Int64` allows.
    func sleep(milliseconds: Double) async throws {
        let microseconds = Int64(saturating: (milliseconds * scale * 1000).rounded()) ?? 0
        try await Task.sleep(for: .microseconds(max(0, microseconds)))
    }

    /// Milliseconds since 1970, in plugin time.
    var nowMilliseconds: Double {
        let (frozen, offset) = control.lock.withLock { (control.frozen, control.offset) }
        return (frozen ?? running) + offset
    }

    private var running: Double {
        if scale == 1 { return Date().timeIntervalSince1970 * 1000 }
        let elapsed = ContinuousClock.now - originInstant
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return originDate.timeIntervalSince1970 * 1000 + seconds * 1000 / scale
    }

    var now: Date { Date(timeIntervalSince1970: nowMilliseconds / 1000) }
}

extension Backoff {
    /// The delay before retry `attempt` (from 0) in whole milliseconds, rounded as JavaScript's `Math.round`.
    func milliseconds(attempt: Int, random: Double) -> Double {
        let delay = delay(attempt: attempt, random: random).components
        return jsRound(Double(delay.seconds) * 1000 + Double(delay.attoseconds) / 1e15)
    }
}

/// JSON text the way `JSON.stringify` writes a string, so a signed body is the bytes that are sent.
func javaScriptStringLiteral(_ text: String) -> String {
    var result = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        case "\u{08}": result += "\\b"
        case "\u{0C}": result += "\\f"
        default:
            if scalar.value < 0x20 || (0xD800...0xDFFF).contains(scalar.value) {
                result += String(format: "\\u%04x", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }
    return result + "\""
}

/// Node's lenient base64 decoding: standard or URL-safe alphabet, missing padding, other characters skipped.
func lenientBase64Decode(_ text: String) -> Data? {
    var cleaned = ""
    for character in text {
        switch character {
        case "-": cleaned.append("+")
        case "_": cleaned.append("/")
        case "=": break
        default:
            if character.isASCII, character.isLetter || character.isNumber || character == "+" || character == "/" {
                cleaned.append(character)
            }
        }
    }
    // A trailing single character carries no full byte; Node drops it.
    if cleaned.count % 4 == 1 { cleaned.removeLast() }
    while cleaned.count % 4 != 0 { cleaned.append("=") }
    return Data(base64Encoded: cleaned)
}
