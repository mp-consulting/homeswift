import Foundation

/// A button of a remote: the `action` values that are its single, double and long presses, and its Service Label Index.
/// Built from the values by section 13 of docs/clean-room/Zigbee2MQTT.md.
struct ButtonMapping: Sendable, Equatable {
    var identifier: String?
    /// 1 for the triple and quadruple presses, a button of their own.
    var extension_ = 0
    var single: String?
    var double: String?
    var long: String?
    var label: Int?

    /// The part of the service's subtype that comes from the mapping (`button_1`, `button_1#ext1`, `#ext1`).
    var subtype: String? { extension_ == 0 ? identifier : "\(identifier ?? "")#ext\(extension_)" }
    var hasValues: Bool { single != nil || double != nil || long != nil }

    struct Failure: Error, CustomStringConvertible, Equatable {
        let description: String
    }

    private enum Slot { case single, double, long, triple, quadruple, ignored }

    private static let words: [(word: String, slot: Slot)] = [
        ("release", .ignored), ("hold-release", .ignored), ("single", .single), ("click", .single), ("press", .single), ("double", .double),
        ("hold", .long), ("long", .long), ("triple", .triple), ("tripple", .triple), ("quadruple", .quadruple),
    ]

    private static func slot(of word: String) -> Slot? { words.first { $0.word == word.lowercased() }?.slot }

    private static func mapping(_ value: String, slot: Slot, identifier: String?) -> ButtonMapping {
        var mapping = ButtonMapping(identifier: identifier)
        switch slot {
        case .single: mapping.single = value
        case .double: mapping.double = value
        case .long: mapping.long = value
        case .triple: (mapping.extension_, mapping.single) = (1, value)
        case .quadruple: (mapping.extension_, mapping.double) = (1, value)
        case .ignored: break
        }
        return mapping
    }

    private static func isSeparator(_ character: Character) -> Bool { character == "_" || character == "-" }

    /// The mapping of one value (step 1).
    private static func mapping(of value: String) throws -> ButtonMapping {
        if value.contains("*") { throw Failure(description: "a wildcard cannot be mapped: \(value)") }
        if let slot = slot(of: value), slot != .ignored { return mapping(value, slot: slot, identifier: nil) }
        if value == "release" || value == "hold-release" { return ButtonMapping() }
        var identifier = Substring(value)
        var leading: Slot?
        for (word, slot) in words {
            let lowered = identifier.lowercased()
            guard lowered.hasPrefix(word), lowered.count > word.count else { continue }
            let index = identifier.index(identifier.startIndex, offsetBy: word.count)
            if isSeparator(identifier[index]) {
                identifier = identifier[identifier.index(after: index)...]
                leading = slot
                break
            }
        }
        var trailing: Slot?
        for index in identifier.indices where isSeparator(identifier[index]) {
            if let slot = slot(of: String(identifier[identifier.index(after: index)...])) {
                trailing = slot
                identifier = identifier[..<index]
                break
            }
        }
        let id = String(identifier)
        if id == value { return mapping(value, slot: .single, identifier: id) }
        if let leading, leading != .ignored { return mapping(value, slot: leading, identifier: id) }
        if let trailing, trailing != .ignored { return mapping(value, slot: trailing, identifier: id) }
        return ButtonMapping(identifier: id)
    }

    /// The buttons of an `action` entry's values, sorted and labelled; throws when two values claim one press, a value
    /// has a wildcard, or the labels run out.
    static func mappings(for values: [String]) throws -> [ButtonMapping] {
        // Steps 1 and 2: one mapping per subtype, in the order they first appear.
        var merged: [ButtonMapping] = []
        for value in values {
            let mapping = try mapping(of: value)
            if let index = merged.firstIndex(where: { $0.subtype == mapping.subtype }) {
                merged[index] = try merged[index].merging(mapping)
            } else {
                merged.append(mapping)
            }
        }
        // Steps 3 and 4.
        var sorted = merged.filter(\.hasValues)
        sorted = sorted.enumerated().sorted { a, b in
            let order = compare(a.element, b.element)
            return order == 0 ? a.offset < b.offset : order < 0
        }.map(\.element)
        // Step 5.
        let numbers = sorted.compactMap { firstNumber(key($0)) }.filter { $0 <= 9 }
        var counts: [Int: Int] = [:]
        for number in numbers { counts[number, default: 0] += 1 }
        let maxCount = counts.values.max() ?? 0
        let highest = numbers.max() ?? 0
        let multiplier = maxCount <= 1 ? 1 : 10
        let incremental = maxCount > 10
        let start = incremental ? 1 : (highest + 1) * multiplier
        var used = Set<Int>()
        for index in sorted.indices {
            var candidate = start, bound = 255
            if !incremental, let number = firstNumber(key(sorted[index])), (1...9).contains(number) {
                candidate = number * multiplier
                bound = number * multiplier + multiplier - 1
            }
            while used.contains(candidate) {
                candidate += 1
                if candidate > bound { throw Failure(description: "service label index out of range") }
            }
            used.insert(candidate)
            sorted[index].label = candidate
        }
        // Step 6.
        return sorted.filter { $0.label != nil && $0.hasValues }
    }

    private func merging(_ other: ButtonMapping) throws -> ButtonMapping {
        func pick(_ a: String?, _ b: String?) throws -> String? {
            if let a, let b, a != b { throw Failure(description: "\(a) and \(b) map to the same press") }
            return a ?? b
        }
        var result = self
        result.single = try pick(single, other.single)
        result.double = try pick(double, other.double)
        result.long = try pick(long, other.long)
        return result
    }

    private static func key(_ mapping: ButtonMapping) -> String {
        (mapping.identifier ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The value of the first run of digits, at most three of them.
    static func firstNumber(_ text: String) -> Int? {
        guard let start = text.firstIndex(where: \.isASCIIDigit) else { return nil }
        return Int(String(text[start...].prefix { $0.isASCIIDigit }.prefix(3)))
    }

    private static func separatorRuns(_ text: String) -> Int {
        var runs = 0, inRun = false
        for character in text {
            if isSeparator(character) {
                if !inRun { runs += 1 }
                inRun = true
            } else {
                inRun = false
            }
        }
        return runs
    }

    /// Negative when `a` goes first (step 4).
    private static func compare(_ a: ButtonMapping, _ b: ButtonMapping) -> Int {
        let x = key(a), y = key(b)
        if x == y { return a.extension_ - b.extension_ }
        switch (firstNumber(x), firstNumber(y)) {
        case (_?, nil): return -1
        case (nil, _?): return 1
        case let (m?, n?) where m != n:
            if m == 0 { return 1 }
            if n == 0 { return -1 }
            return m < n ? -1 : 1
        default: break
        }
        if x.isEmpty != y.isEmpty { return x.isEmpty ? -1 : 1 }
        let runs = separatorRuns(x) - separatorRuns(y)
        if runs != 0 { return runs }
        return x.utf16.lexicographicallyPrecedes(y.utf16) ? -1 : 1
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
