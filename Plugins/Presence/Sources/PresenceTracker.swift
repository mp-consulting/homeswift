import Foundation

/// A Person as their Accessory Settings describe them.
struct Person: Sendable, Equatable {
    /// Their Device Id (`person-…`).
    var id: String
    var name: String
    /// Their devices' MACs (`MACAddress.canonical`).
    var devices: Set<String>
    /// The web UI user they are, when linked.
    var user: String?
}

/// Where one Person stands, kept across restarts so a restart within the grace period changes nothing.
struct PersonState: Codable, Sendable, Equatable {
    var isHome: Bool
    /// Since when home or away.
    var since: Date?
    /// The last time one of their devices was on the network.
    var lastSeen: Date?
}

/// Who is home (GLOSSARY.md, "Person"): a Person is home from the first check that sees one of their devices, and away
/// once none was seen for the grace period, from the last time one was. A Person never checked yet is away.
struct PresenceTracker: Sendable {
    var grace: TimeInterval
    private(set) var states: [String: PersonState]

    init(grace: TimeInterval, states: [String: PersonState] = [:]) {
        self.grace = grace
        self.states = states
    }

    func state(of id: String) -> PersonState {
        states[id] ?? PersonState(isHome: false)
    }

    /// Takes in a check made at `now` that saw `seen` (MACs); answers the Persons whose home or away changed, and whether
    /// any state needs saving.
    mutating func update(_ persons: [Person], seen: Set<String>, at now: Date) -> (changed: [String], dirty: Bool) {
        var changed: [String] = []
        var dirty = false
        for person in persons {
            var state = state(of: person.id)
            let before = state
            if !person.devices.isDisjoint(with: seen) {
                state.lastSeen = now
                if !state.isHome || state.since == nil {
                    state.isHome = true
                    state.since = now
                }
            } else if state.isHome, now.timeIntervalSince(state.lastSeen ?? .distantPast) >= grace {
                state.isHome = false
                state.since = state.lastSeen ?? now
            } else if state.since == nil {
                // Checked for the first time, and none of their devices was there.
                state.since = now
            }
            if state.isHome != before.isHome || states[person.id] == nil { changed.append(person.id) }
            if state != before { dirty = true }
            states[person.id] = state
        }
        // Persons no longer in the settings.
        let kept = Set(persons.map(\.id))
        if states.keys.contains(where: { !kept.contains($0) }) {
            states = states.filter { kept.contains($0.key) }
            dirty = true
        }
        return (changed, dirty)
    }
}
