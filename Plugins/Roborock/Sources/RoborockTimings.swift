import Foundation
import HomeswiftNetwork

/// The plugin's fixed timings (sections 1, 4, 6, 7, 8); tests shorten them.
struct RoborockTimings: Sendable {
    var requestTimeout: Duration = .seconds(10)
    var reconnect: Duration = .seconds(60)
    var handshake: Duration = .seconds(3)
    var probe: Duration = .seconds(3)
    var keepalive: Duration = .seconds(30)
    var mqttUpWarning: Duration = .seconds(30)
    var mqttForcedReconnect: Duration = .seconds(3 * 3600)
    var methodPause: Duration = .seconds(30 * 60)
    var localCooldown: Duration = .seconds(5 * 60)
    var networkInfoInterval: Duration = .seconds(60)
    var homeRefresh: Duration = .seconds(180)
    var activePoll: Duration = .seconds(15)
    var scenePoll: Duration = .seconds(15)
    var sceneStartWindow: Duration = .seconds(5 * 60)
    var sceneMaximum: Duration = .seconds(4 * 3600)
    var sceneSwitchReset: Duration = .seconds(1)
    /// A live value older than this gives way to the home data's.
    var liveStatusAge: Duration = .seconds(540)
    var udpListen: Duration = .seconds(5)
    var transientLogInterval: Duration = .seconds(10 * 60)
    var clockSkewLogInterval: Duration = .seconds(10 * 60)
    /// The silent MQTT restart: 30 minutes, doubled for each restart since traffic was last seen, at most 6 hours.
    var mqttRestart = Backoff(initial: .seconds(30 * 60), factor: 2, maximum: .seconds(6 * 3600))
    /// A device that keeps failing to connect waits longer, from the minute the spec says up to ten.
    var reconnectBackoff: Backoff { Backoff(initial: reconnect, factor: 2, maximum: reconnect * 10, jitter: .proportional(0.1)) }

    static let standard = RoborockTimings()
}
