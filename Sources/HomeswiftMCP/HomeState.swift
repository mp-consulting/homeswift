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
/// hidden accessories, display names, Quick Controls), the wall's order and sizes, the scenes, the automations, the notification
/// settings, and the shows that can still be undone. Each is its own owner-only file next to config.json; `HomeswiftCatalog.startHome` runs the
/// automations and the notification sources.
public final class HomeState: Sendable {
    public let layout: JSONFileStore<AccessoryLayout>
    /// What links the Rooms, Zones and Groups to the Home's (`home.json`), and the Pending Changes.
    public let homeLink: JSONFileStore<HomeLinkFile>
    /// The Home Link's work, one piece after the other.
    let homeLinkWork = SerialTasks()
    /// Whether a follow of the Home waits behind the one running: another call then makes none (`followHome`).
    let followQueued = NIOLockedValueBox(false)
    /// What the Home Link last said.
    let lastHome = NIOLockedValueBox<LastHome?>(nil)
    /// The Accessories page's wall: order, sizes, grouping (`ui-layout.json`).
    public let wall: WallLayout
    /// Who follows changes to the rooms and the wall, from any writer (the pages, the chat, an MCP client).
    let layoutObservers = NIOLockedValueBox<[UUID: @Sendable () -> Void]>([:])
    public let scenes: JSONFileStore<SceneFile>
    /// What the bridge does on its own (`Automations.swift`).
    public let automations: JSONFileStore<AutomationFile>
    /// The Automations running now, by id.
    let automationRuns = NIOLockedValueBox<[String: AutomationRunning]>([:])
    /// The `stays` triggers counting, by automation and trigger.
    let staysTimers = NIOLockedValueBox<[String: Task<Void, Never>]>([:])
    /// How an Automation's waits are counted; tests make them shorter.
    public let automationTimeScale = NIOLockedValueBox(1.0)
    public let notifications: JSONFileStore<NotificationSettings>
    /// The notifications with buttons, while their tokens last (`NotificationActions.swift`).
    let notificationActions = NIOLockedValueBox<[String: PendingNotification]>([:])
    /// Reads the Telegram bot's button presses while one waits.
    let telegramPoller = NIOLockedValueBox<Task<Void, Never>?>(nil)
    /// The web UI's address, for notifications' links; set by the web UI as it starts.
    let uiAddress = NIOLockedValueBox<String?>(nil)
    /// A user's Language as their account chose it, nil for "auto"; set by the web UI, whose Preferences keep it.
    let userLanguages = NIOLockedValueBox<(@Sendable (String) -> String?)?>(nil)
    /// The shows and plugin scenes that set the lights and can still be undone, with what the lights were.
    let heldLights: JSONFileStore<[SavedHeldLights]>
    let sceneUndo: JSONFileStore<[String: SceneUndo]>
    /// How notifications reach webhooks, ntfy, Pushover, Telegram and push services; tests put a fake here.
    let httpBox: NIOLockedValueBox<any HTTPSending>
    /// The automations' and the notification sources' work while they run.
    let running = NIOLockedValueBox<RunningHome?>(nil)
    /// Scenes running now, so one does not start twice.
    let runningScenes = NIOLockedValueBox<Set<String>>([])
    /// Light shows playing on the lights now, by run id.
    let lightRuns = NIOLockedValueBox<[String: LightRun]>([:])
    /// The lights each scene's effect plays natively (their plugins animate them), by scene id: told to stop with it.
    let nativeAnimations = NIOLockedValueBox<[String: [String]]>([:])
    /// The plans tried from the web UI (a template, a description), by run id, while they can be stopped.
    let planRuns = NIOLockedValueBox<[String: PlanRun]>([:])
    /// The last value of each characteristic a scene trigger watches, and when each trigger last fired.
    let watched = NIOLockedValueBox(WatchedValues())
    /// Rate limits and memory of the notification dispatcher.
    let dispatch = NIOLockedValueBox(DispatchState())

    public init(directory: URL) {
        layout = JSONFileStore(url: directory.appendingPathComponent("accessory-layout.json")) { AccessoryLayout() }
        homeLink = JSONFileStore(url: directory.appendingPathComponent("home.json")) { HomeLinkFile() }
        let observers = layoutObservers
        wall = WallLayout(url: directory.appendingPathComponent("ui-layout.json")) { Self.notify(observers) }
        scenes = JSONFileStore(url: directory.appendingPathComponent("scenes.json")) { SceneFile() }
        automations = JSONFileStore(url: directory.appendingPathComponent("automations.json")) { AutomationFile() }
        notifications = JSONFileStore(url: directory.appendingPathComponent("notifications.json")) { NotificationSettings() }
        sceneUndo = JSONFileStore(url: directory.appendingPathComponent("scene-undo.json")) { [:] }
        heldLights = JSONFileStore(url: directory.appendingPathComponent("held-lights.json")) { [] }
        // Moods kept their undo there before they became scenes; what it held has no run to undo now.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("held-moods.json"))
        httpBox = NIOLockedValueBox(HTTPClient())
    }

    /// Calls `observer` after each change to the rooms or the wall, until the observation is cancelled.
    public func observeLayout(_ observer: @escaping @Sendable () -> Void) -> Observation {
        let id = UUID()
        layoutObservers.withLockedValue { $0[id] = observer }
        return Observation { [layoutObservers] in _ = layoutObservers.withLockedValue { $0.removeValue(forKey: id) } }
    }

    func layoutChanged() { Self.notify(layoutObservers) }

    private static func notify(_ observers: NIOLockedValueBox<[UUID: @Sendable () -> Void]>) {
        for observer in observers.withLockedValue({ Array($0.values) }) { observer() }
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
