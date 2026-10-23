import Foundation

/// JSON built a member at a time, for a shape written once and wanted either as a `JSONValue` (`JSONValueBuilder`)
/// or straight as bytes (`JSONBytesWriter`). Objects get their keys in `encoded()`'s order, by UTF-8 bytes, so the
/// bytes are those the value encodes to.
public protocol JSONBuilding {
    mutating func object(_ body: (inout Self) -> Void)
    mutating func array(_ body: (inout Self) -> Void)
    /// The key of the next member, inside `object`.
    mutating func key(_ name: String)
    mutating func value(_ value: JSONValue)
}

extension JSONBuilding {
    public mutating func field(_ name: String, _ value: JSONValue) {
        key(name)
        self.value(value)
    }
}

/// Builds the `JSONValue`.
public struct JSONValueBuilder: JSONBuilding {
    public private(set) var result: JSONValue = .null
    // The open containers, innermost last: whether each is an object, then the objects with their pending keys
    // and the arrays, so members go in place rather than through copies.
    private var kinds: [Bool] = []
    private var objects: [[String: JSONValue]] = []
    private var keys: [String] = []
    private var arrays: [[JSONValue]] = []

    public init() {}

    public mutating func object(_ body: (inout Self) -> Void) {
        kinds.append(true)
        objects.append([String: JSONValue](minimumCapacity: 12))
        keys.append("")
        body(&self)
        kinds.removeLast()
        keys.removeLast()
        value(.object(objects.removeLast()))
    }

    public mutating func array(_ body: (inout Self) -> Void) {
        kinds.append(false)
        arrays.append([])
        body(&self)
        kinds.removeLast()
        value(.array(arrays.removeLast()))
    }

    public mutating func key(_ name: String) {
        keys[keys.count - 1] = name
    }

    public mutating func value(_ value: JSONValue) {
        guard let isObject = kinds.last else {
            result = value
            return
        }
        if isObject {
            objects[objects.count - 1][keys[keys.count - 1]] = value
        } else {
            arrays[arrays.count - 1].append(value)
        }
    }
}

/// Writes compact JSON bytes as it goes: no tree, no key sorting.
public struct JSONBytesWriter: JSONBuilding {
    public private(set) var bytes: [UInt8] = []
    /// One per open container: true until its first member.
    private var empty: [Bool] = []
    private var afterKey = false

    public init(capacity: Int = 1024) {
        bytes.reserveCapacity(capacity)
    }

    private mutating func separate() {
        if afterKey {
            afterKey = false
        } else if let first = empty.last {
            if first { empty[empty.count - 1] = false } else { bytes.append(UInt8(ascii: ",")) }
        }
    }

    public mutating func object(_ body: (inout Self) -> Void) {
        separate()
        bytes.append(UInt8(ascii: "{"))
        empty.append(true)
        body(&self)
        empty.removeLast()
        bytes.append(UInt8(ascii: "}"))
    }

    public mutating func array(_ body: (inout Self) -> Void) {
        separate()
        bytes.append(UInt8(ascii: "["))
        empty.append(true)
        body(&self)
        empty.removeLast()
        bytes.append(UInt8(ascii: "]"))
    }

    public mutating func key(_ name: String) {
        separate()
        JSONValue.appendQuoted(name, to: &bytes)
        bytes.append(UInt8(ascii: ":"))
        afterKey = true
    }

    public mutating func value(_ value: JSONValue) {
        separate()
        value.writeCompact(to: &bytes)
    }
}
