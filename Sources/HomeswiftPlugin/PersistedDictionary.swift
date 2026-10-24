import Foundation
import Homeswift
import Logging
import NIOConcurrencyHelpers

/// Values a plugin keeps across launches by key (an accessory's last state, a device's address), in one
/// owner-only JSON file: read on first use, written only when a value changed. Changes are written together
/// `autosave` after the first of a burst, or only by `flush()` when `autosave` is nil.
public final class PersistedDictionary<Value: Codable & Equatable & Sendable>: Sendable {
    public let url: URL
    private let autosave: Duration?
    private let logger: Logger?

    private struct State {
        var values: [String: Value]?
        var dirty = false
        var saveScheduled = false
    }

    private let state = NIOLockedValueBox(State())

    /// `logger` reports the autosaves that fail; `flush()` throws instead.
    public init(url: URL, autosave: Duration? = .milliseconds(200), logger: Logger? = nil) {
        self.url = url
        self.autosave = autosave
        self.logger = logger
    }

    /// Every value, by key.
    public var values: [String: Value] { loaded { $0 } }

    public subscript(key: String) -> Value? {
        get { loaded { $0[key] } }
        set { update(key) { $0 = newValue } }
    }

    /// Changes the value of `key` in place (`body` must not use the store). Returns whether it changed; an
    /// unchanged value writes nothing.
    @discardableResult
    public func update(_ key: String, _ body: (inout Value?) -> Void) -> Bool {
        let schedule = state.withLockedValue { state -> Bool? in
            Self.load(&state, from: url)
            var value = state.values?[key]
            body(&value)
            guard value != state.values?[key] else { return nil }
            state.values?[key] = value
            state.dirty = true
            guard autosave != nil, !state.saveScheduled else { return false }
            state.saveScheduled = true
            return true
        }
        guard let schedule else { return false }
        if schedule, let autosave {
            // Holds the store until it has written: a store let go of within `autosave` still saves its change.
            Task {
                try? await Task.sleep(for: autosave)
                self.autosaveNow()
            }
        }
        return true
    }

    @discardableResult
    public func removeValue(forKey key: String) -> Value? {
        var old: Value?
        update(key) { value in
            old = value
            value = nil
        }
        return old
    }

    /// Writes the pending changes now, if there are any.
    public func flush() throws {
        try state.withLockedValue { state in
            state.saveScheduled = false
            guard state.dirty, let values = state.values else { return }
            // Under the lock, so two flushes cannot land out of order.
            try OwnerOnlyFile.write(JSONFile<[String: Value]>.encoder.encode(values), to: url)
            state.dirty = false
        }
    }

    private func autosaveNow() {
        do {
            try flush()
        } catch {
            logger?.warning("Could not save \(url.lastPathComponent)", metadata: ["path": "\(url.path)", "error": "\(error)"])
        }
    }

    private func loaded<T>(_ body: ([String: Value]) -> T) -> T {
        state.withLockedValue { state in
            Self.load(&state, from: url)
            return body(state.values ?? [:])
        }
    }

    private static func load(_ state: inout State, from url: URL) {
        guard state.values == nil else { return }
        state.values = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Value].self, from: $0) } ?? [:]
    }
}

/// One JSON file of a plugin's own (`PluginContext.jsonFile`): read it, write it owner-only.
public struct JSONFile<Value: Codable>: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// The stored value; nil when the file is missing or does not decode.
    public func load() -> Value? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    public func save(_ value: Value) throws {
        try OwnerOnlyFile.write(Self.encoder.encode(value), to: url)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension PluginContext {
    /// A JSON file in the storage directory, by name (`context.jsonFile("devices.json", as: [Device].self)`).
    public func jsonFile<Value: Codable>(_ name: String, as type: Value.Type = Value.self) -> JSONFile<Value> {
        JSONFile(url: storageFile(name))
    }

    /// A keyed store in the storage directory, by name: see `PersistedDictionary`.
    public func persistedDictionary<Value: Codable & Equatable & Sendable>(
        _ name: String, of type: Value.Type = Value.self, autosave: Duration? = .milliseconds(200)
    ) -> PersistedDictionary<Value> {
        let store = PersistedDictionary<Value>(url: storageFile(name), autosave: autosave, logger: logger)
        let logger = logger
        storeFlushes.withLockedValue { flushes in
            flushes.removeAll { !$0.isAlive() }
            flushes.append((isAlive: { [weak store] in store != nil }, flush: { [weak store] in
                do { try store?.flush() } catch { logger.warning("Could not save \(name)", metadata: ["error": "\(error)"]) }
            }))
        }
        return store
    }

    /// A file directly in the storage directory: a name made from a device's or a cloud's id (`"\(serial).json"`)
    /// never reaches outside it, its slashes and a `..` being replaced.
    func storageFile(_ name: String) -> URL {
        var safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        if safe.isEmpty || safe == "." || safe == ".." { safe = "_" + safe }
        return storageDirectory.appendingPathComponent(safe)
    }
}
