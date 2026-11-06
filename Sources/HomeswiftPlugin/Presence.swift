import Foundation
import NIOConcurrencyHelpers

// Presence (GLOSSARY.md, "Presence"): who of the Persons is home, as the Presence plugin finds it, kept by the host
// for everyone else that reads it: the web UI ("you are home"), Automations (a Person arriving or leaving, Anyone Home
// changing, as Triggers) and notifications (the browsers of the user a Person is). The plugin publishes; the board says
// what changed to whoever follows it.

/// One Person and where they are.
public struct PersonPresence: Sendable, Equatable, Codable {
    /// Their accessory's id (`Presence:<Device Id>`): the one name a Person goes by in settings and Triggers.
    public var id: String
    public var name: String
    public var isHome: Bool
    /// Since when they are home or away; nil before the first check after the bridge started, with nothing saved.
    public var since: Date?
    /// The web UI user this Person is, when someone linked them: whose pages say "you are home", whose browsers a
    /// notification about them can reach.
    public var user: String?

    public init(id: String, name: String, isHome: Bool, since: Date? = nil, user: String? = nil) {
        self.id = id
        self.name = name
        self.isHome = isHome
        self.since = since
        self.user = user
    }
}

/// What changed on the board.
public enum PresenceEvent: Sendable, Equatable {
    /// A Person came home.
    case arrived(PersonPresence)
    /// A Person left, their grace period over.
    case left(PersonPresence)
    /// Anyone Home changed: true once the first Person is home, false once the last one has left.
    case anyoneHome(Bool)
}

/// The Persons the Presence plugin follows, for the rest of the bridge (`PluginHost.presence`, `PluginContext.presence`).
public final class PresenceBoard: Sendable {
    private struct State {
        /// By id, as the plugin last published them; nil before it published anything, and once it stopped.
        var persons: [String: PersonPresence]?
        /// The last ones published, kept when the plugin stops: a reload's first publish is compared with them, so a
        /// Person who came or went meanwhile is still told.
        var last: [String: PersonPresence]?
        var observers: [UUID: @Sendable (PresenceEvent) -> Void] = [:]
    }

    private let state = NIOLockedValueBox(State())

    public init() {}

    /// Every Person, by name; empty when no Presence plugin runs.
    public var persons: [PersonPresence] {
        state.withLockedValue { $0.persons.map { Array($0.values) } ?? [] }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// Whether at least one Person is home; nil when no Presence plugin publishes.
    public var anyoneHome: Bool? {
        state.withLockedValue { $0.persons.map { $0.values.contains(where: \.isHome) } }
    }

    /// The Persons a web UI user is linked to.
    public func persons(of user: String) -> [PersonPresence] {
        persons.filter { $0.user == user }
    }

    /// The plugin's Persons as they are now: each one that arrives or leaves is told to the observers, then Anyone Home
    /// when it changes. A Person new to the board, or one taken off it, is no arrival or departure.
    public func publish(_ persons: [PersonPresence]) {
        let (events, observers) = state.withLockedValue { state -> ([PresenceEvent], [@Sendable (PresenceEvent) -> Void]) in
            let before = state.persons ?? state.last
            let after = Dictionary(persons.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            state.persons = after
            state.last = after
            guard let before else { return ([], []) }
            var events: [PresenceEvent] = []
            for person in persons {
                guard let earlier = before[person.id], earlier.isHome != person.isHome else { continue }
                events.append(person.isHome ? .arrived(person) : .left(person))
            }
            let wasHome = before.values.contains(where: \.isHome), isHome = after.values.contains(where: \.isHome)
            if wasHome != isHome { events.append(.anyoneHome(isHome)) }
            return (events, Array(state.observers.values))
        }
        for event in events {
            for observer in observers { observer(event) }
        }
    }

    /// Takes the plugin's Persons off the board: it stopped. The next publish (the plugin reloaded) is still compared with
    /// them.
    public func clear() {
        state.withLockedValue { $0.persons = nil }
    }

    /// Follows arrivals, departures and Anyone Home; `cancel()` the observation to stop.
    public func observe(_ observer: @escaping @Sendable (PresenceEvent) -> Void) -> Observation {
        let id = UUID()
        state.withLockedValue { $0.observers[id] = observer }
        return Observation { [state] in _ = state.withLockedValue { $0.observers.removeValue(forKey: id) } }
    }
}

/// A web UI user, for a plugin that links something to one (a Person): the name they sign in with, and their own.
public struct WebUser: Sendable, Equatable {
    public var username: String
    public var name: String

    public init(username: String, name: String) {
        self.username = username
        self.name = name
    }
}
