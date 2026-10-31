import Foundation
import HomeswiftAI

/// The walk resolution, the migration, the vault's listing of users and the masking share (docs/vault-design.md): the
/// strings and numbers under a secret-named key (`Redaction.isSecretKey`, a key's whole subtree counts), each with its
/// path in the block and the secret-named key above it.
public enum SecretWalk {
    public enum Part: Equatable, Sendable {
        case key(String)
        case index(Int)
    }

    /// `password`, `devices[0].localKey`.
    public static func text(_ path: [Part]) -> String {
        path.reduce(into: "") { text, part in
            switch part {
            case .key(let key): text += text.isEmpty ? key : ".\(key)"
            case .index(let index): text += "[\(index)]"
            }
        }
    }

    /// Calls `body` with each secret's path, the secret-named key above it and its value; the subtrees of `skipping`
    /// keys are left out.
    public static func forEach(_ value: JSONValue, skipping: Set<String> = [], _ body: (_ path: [Part], _ key: String, _ value: JSONValue) -> Void) {
        func walk(_ value: JSONValue, _ path: [Part], _ key: String?) {
            switch value {
            case .string, .number:
                if let key { body(path, key, value) }
            case .array(let items):
                for (index, item) in items.enumerated() { walk(item, path + [.index(index)], key) }
            case .object(let object):
                for (name, item) in object.sorted(by: { $0.key < $1.key }) where !skipping.contains(name) {
                    walk(item, path + [.key(name)], key ?? (Redaction.isSecret(key: name, value: item) ? name : nil))
                }
            default:
                break
            }
        }
        walk(value, [], nil)
    }

    /// `value` with each secret replaced by what `transform` answers for it; nil keeps it.
    public static func map(_ value: JSONValue, _ transform: (_ path: [Part], _ value: JSONValue) -> JSONValue?) -> JSONValue {
        var result = value
        forEach(value) { path, _, secret in
            if let next = transform(path, secret) { result = replacing(result, at: path, with: next) }
        }
        return result
    }

    /// The value at `path`, or nil.
    public static func value(at path: [Part], in value: JSONValue) -> JSONValue? {
        path.reduce(Optional(value)) { current, part in
            switch (part, current) {
            case (.key(let key), .object(let object)?): object[key]
            case (.index(let index), .array(let items)?): items.indices.contains(index) ? items[index] : nil
            default: nil
            }
        }
    }

    /// `value` with `new` at `path`; a path that does not lead anywhere changes nothing.
    public static func replacing(_ value: JSONValue, at path: [Part], with new: JSONValue) -> JSONValue {
        guard let first = path.first else { return new }
        let rest = Array(path.dropFirst())
        switch (first, value) {
        case (.key(let key), .object(var object)) where object[key] != nil:
            object[key] = replacing(object[key]!, at: rest, with: new)
            return .object(object)
        case (.index(let index), .array(var items)) where items.indices.contains(index):
            items[index] = replacing(items[index], at: rest, with: new)
            return .array(items)
        default:
            return value
        }
    }
}
