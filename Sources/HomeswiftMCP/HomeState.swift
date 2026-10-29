import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// A value kept in an owner-only JSON file next to config.json: read once, written whole on every change.
/// A file that cannot be read starts from the default and is left alone until the first change.
public final class JSONFileStore<Value: Codable & Sendable>: Sendable {
    public let url: URL
    private let state: NIOLockedValueBox<Value?>
    private let makeDefault: @Sendable () -> Value

    public init(url: URL, default makeDefault: @escaping @Sendable () -> Value) {
        self.url = url
        self.makeDefault = makeDefault
        state = NIOLockedValueBox(nil)
    }

    public var value: Value {
        state.withLockedValue { current in
            if let current { return current }
            let loaded = load()
            current = loaded
            return loaded
        }
    }

    /// Changes the value and writes the file; `change` throwing leaves both as they were.
    @discardableResult
    public func update<T>(_ change: (inout Value) throws -> T) throws -> T {
        try state.withLockedValue { current in
            var next = current ?? load()
            let result = try change(&next)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try OwnerOnlyFile.write(encoder.encode(next), to: url)
            current = next
            return result
        }
    }

    private func load() -> Value {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Value.self, from: data) else { return makeDefault() }
        return value
    }
}

/// What the web UI and the MCP server keep about the home besides config.json: the accessory layout (rooms,
/// hidden accessories, display names, Quick Controls), the scenes and their automations, the notification
/// settings, and the moods that can still be undone. Each is its own owner-only file next to config.json; `HomeswiftCatalog.startHome` runs the
/// automations and the notification sources.
public final class HomeState: Sendable {
    public let layout: JSONFileStore<AccessoryLayout>
    public let scenes: JSONFileStore<SceneFile>
    public let notifications: JSONFileStore<NotificationSettings>
    /// The moods and plugin scenes that set the lights and can still be undone, with what the lights were.
    let heldMoods: JSONFileStore<[SavedHeldMood]>
    let sceneUndo: JSONFileStore<[String: SceneUndo]>
    /// How notifications reach webhooks, ntfy, Pushover, Telegram and push services; tests put a fake here.
    let httpBox: NIOLockedValueBox<any HTTPSending>
    /// The automations' and the notification sources' work while they run.
    let running = NIOLockedValueBox<RunningHome?>(nil)
    /// Scenes running now, so one does not start twice.
    let runningScenes = NIOLockedValueBox<Set<String>>([])
    /// Moods playing on the lights now, by run id.
    let runningMoods = NIOLockedValueBox<[String: MoodRun]>([:])
    /// The last value of each characteristic a scene trigger watches, and when each trigger last fired.
    let watched = NIOLockedValueBox(WatchedValues())
    /// Rate limits and memory of the notification dispatcher.
    let dispatch = NIOLockedValueBox(DispatchState())

    public init(directory: URL) {
        layout = JSONFileStore(url: directory.appendingPathComponent("accessory-layout.json")) { AccessoryLayout() }
        scenes = JSONFileStore(url: directory.appendingPathComponent("scenes.json")) { SceneFile() }
        notifications = JSONFileStore(url: directory.appendingPathComponent("notifications.json")) { NotificationSettings() }
        sceneUndo = JSONFileStore(url: directory.appendingPathComponent("scene-undo.json")) { [:] }
        heldMoods = JSONFileStore(url: directory.appendingPathComponent("held-moods.json")) { [] }
        httpBox = NIOLockedValueBox(HTTPClient())
    }

    public var http: any HTTPSending {
        get { httpBox.withLockedValue { $0 } }
        set { httpBox.withLockedValue { $0 = newValue } }
    }
}

/// The tasks and observations of `startHome`.
struct RunningHome: Sendable {
    var ticker: Task<Void, Never>
    var observations: [Observation]
}

struct WatchedValues: Sendable {
    var values: [String: HAPValue] = [:]
    var fired: [String: Date] = [:]
}

struct DispatchState: Sendable {
    var lastSent: [String: Date] = [:]
    var sent: [Date] = []
    var tests: [Date] = []
    /// Accessories seen unavailable, since when, and whether that was notified.
    var offline: [String: (since: Date, notified: Bool)] = [:]
    /// The local day the digest was last sent.
    var digestDay: String?
    /// The last minute the automations ran for, so a late wake-up never runs one twice.
    var lastTick: Date?
}
