import Foundation

/// Schema-checked JSON output: ask, validate, and give the model one chance to repair.
public struct JSONGenerationError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let text: String
    public let errors: [String]
    public var description: String { message }
}

public struct JSONGenerationResult: Sendable {
    public var data: JSONValue
    public var text: String
    public var usage: TokenUsage
}

public enum JSONGeneration {
    /// The JSON value in a model reply, tolerating code fences and prose around it.
    public static func extract(_ text: String) throws -> JSONValue {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = try? NSRegularExpression(pattern: "```(?:json)?\\s*([\\s\\S]*?)```", options: [.caseInsensitive]),
            let match = fence.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
            let range = Range(match.range(at: 1), in: candidate)
        {
            candidate = String(candidate[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = try? JSONValue(string: candidate) { return value }
        guard let start = candidate.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            throw JSONGenerationError(message: "the reply contains no JSON", text: text, errors: [])
        }
        let end = max(candidate.lastIndex(of: "}") ?? candidate.startIndex, candidate.lastIndex(of: "]") ?? candidate.startIndex)
        guard end > start else { throw JSONGenerationError(message: "the reply contains no JSON", text: text, errors: []) }
        do {
            return try JSONValue(string: String(candidate[start...end]))
        } catch {
            throw JSONGenerationError(message: "the reply is not valid JSON (\(error))", text: text, errors: [])
        }
    }

    /// Asks for JSON matching `schema`; on a parse or validation failure, asks once more with the errors.
    public static func generate(
        provider: any Provider, schema: JSONValue, prompt: String, system: String? = nil,
        maxOutputTokens: Int? = nil, onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> JSONGenerationResult {
        let system = "\(system ?? Prompts.base)\nReply with JSON only (no prose, no code fences) matching this JSON Schema:\n\(schema.text())"
        // Redacted here, whatever the caller did: the rule is the mechanism's, not each feature's.
        var messages: [ChatMessage] = [.user(Redaction.redactText(prompt))]
        var usage = TokenUsage.zero
        var errors: [String] = []
        var text = ""
        for _ in 0..<2 {
            let result = try await complete(provider, ChatRequest(system: system, messages: messages, maxOutputTokens: maxOutputTokens), onChunk: onChunk)
            usage += result.usage
            text = result.text
            do {
                let data = try extract(text)
                errors = JSONSchema.validate(data, against: schema)
                if errors.isEmpty { return JSONGenerationResult(data: data, text: text, usage: usage) }
            } catch let error as JSONGenerationError {
                errors = [error.message]
            }
            // A reply cut off at the output limit cannot be repaired by asking again.
            if result.stopReason == .maxTokens {
                let limit = maxOutputTokens.map { "the \($0)-token output limit" } ?? "its output limit"
                throw JSONGenerationError(message: "The answer was cut off at \(limit). Raise the maximum answer length, or ask for less at once.", text: text, errors: errors)
            }
            messages.append(.assistant(text.isEmpty ? "(empty reply)" : text))
            messages.append(.user(Prompts.repairJSON(errors.joined(separator: "; "))))
        }
        throw JSONGenerationError(message: "The model did not return valid JSON: \(errors.joined(separator: "; "))", text: text, errors: errors)
    }

    private static let droppedSchemaKeys: Set<String> = ["$schema", "condition", "placeholder", "x-collapsible", "functionBody", "layout", "form", "display"]

    /// Turns a Homebridge `config.schema.json` `schema` (which allows `required: true` on a property, and
    /// UI-only keys) into standard JSON Schema. For checking a saved block (`forChecking`), a property with a
    /// default or a condition is not required: the plugin falls back on its default, and the form asks for a
    /// conditional one only when it shows it.
    public static func normalizePluginSchema(_ schema: JSONValue, forChecking: Bool = false) -> JSONValue {
        switch schema {
        case .array(let items):
            return .array(items.map { normalizePluginSchema($0, forChecking: forChecking) })
        case .object(let object):
            var out: [String: JSONValue] = [:]
            var required: [String] = object["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            for (key, value) in object {
                if droppedSchemaKeys.contains(key) { continue }
                if key == "required" { continue }
                if key == "properties", let properties = value.objectValue {
                    out["properties"] = .object(properties.mapValues { normalizePluginSchema($0, forChecking: forChecking) })
                    for (name, property) in properties where property["required"] == .bool(true)
                        && !(forChecking && (property["default"] != nil || property["condition"] != nil)) {
                        if !required.contains(name) { required.append(name) }
                    }
                } else {
                    out[key] = normalizePluginSchema(value, forChecking: forChecking)
                }
            }
            if !required.isEmpty { out["required"] = .array(required.sorted().map(JSONValue.string)) }
            return .object(out)
        default:
            return schema
        }
    }
}

/// The subset of JSON Schema the Assistant's own schemas and plugin config schemas use: `type`,
/// `required`, `properties`, `additionalProperties`, `items`, `enum`, `const`, `anyOf`, `oneOf`, numeric
/// and string bounds. Homebridge's `password` type is a string; a type it does not know matches anything.
public enum JSONSchema {
    /// A step from a value into one of its parts: an object's key or an array's index.
    public enum PathComponent: Hashable, Sendable {
        case key(String)
        case index(Int)

        public var json: JSONValue {
            switch self {
            case .key(let key): .string(key)
            case .index(let index): .number(Double(index))
            }
        }
    }

    /// What is wrong, and where: `path` from the value checked, `message` without the place.
    public struct Problem: Equatable, Sendable, CustomStringConvertible {
        public var path: [PathComponent]
        public var message: String

        public init(path: [PathComponent], message: String) {
            self.path = path
            self.message = message
        }

        /// `lights[0].port`, or `(root)`.
        public var location: String { Self.location(path) }
        public var description: String { "\(location) \(message)" }

        public static func location(_ path: [PathComponent]) -> String {
            guard !path.isEmpty else { return "(root)" }
            var text = ""
            for component in path {
                switch component {
                case .key(let key): text += text.isEmpty ? key : ".\(key)"
                case .index(let index): text += "[\(index)]"
                }
            }
            return text
        }
    }

    public static func validate(_ value: JSONValue, against schema: JSONValue) -> [String] {
        problems(value, against: schema).map(\.description)
    }

    public static func problems(_ value: JSONValue, against schema: JSONValue, path: [PathComponent] = []) -> [Problem] {
        guard let object = schema.objectValue else { return [] }
        var problems: [Problem] = []
        func problem(_ message: String, at place: [PathComponent]? = nil) { problems.append(Problem(path: place ?? path, message: message)) }

        if let type = object["type"] {
            let types = type.arrayValue?.compactMap(\.stringValue) ?? type.stringValue.map { [$0] } ?? []
            if !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) {
                problem("must be \(types.map { $0 == "password" ? "string" : $0 }.joined(separator: " or "))")
                return problems
            }
        }
        if let allowed = object["enum"]?.arrayValue, !allowed.contains(value) {
            problem("must be one of \(allowed.map { $0.text() }.joined(separator: ", "))")
        }
        if let constant = object["const"], constant != value {
            problem("must be \(constant.text())")
        }
        for keyword in ["anyOf", "oneOf"] {
            guard let options = object[keyword]?.arrayValue, !options.contains(where: { Self.problems(value, against: $0, path: path).isEmpty }) else { continue }
            // Homebridge's choices are a oneOf of titled enums: name the values, as a select would show them.
            let choices = options.compactMap { $0["enum"]?.arrayValue?.count == 1 ? $0["enum"]?.arrayValue?.first : $0["const"] }
            problem(choices.count == options.count ? "must be one of \(choices.map { $0.text() }.joined(separator: ", "))" : "matches none of the allowed shapes")
        }
        if let fields = value.objectValue {
            // At the missing key's own path, so a check of what changed can tell a key just removed from one never there.
            for name in object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where fields[name] == nil {
                problem("is required", at: path + [.key(name)])
            }
            let properties = object["properties"]?.objectValue ?? [:]
            for (name, property) in properties.sorted(by: { $0.key < $1.key }) {
                if let field = fields[name] {
                    problems += Self.problems(field, against: property, path: path + [.key(name)])
                }
            }
            if object["additionalProperties"] == .bool(false) {
                for name in fields.keys.sorted() where properties[name] == nil {
                    problem("is not allowed here", at: path + [.key(name)])
                }
            }
        }
        if let items = value.arrayValue {
            if let itemSchema = object["items"] {
                for (index, item) in items.enumerated() {
                    problems += Self.problems(item, against: itemSchema, path: path + [.index(index)])
                }
            }
            if let minimum = object["minItems"]?.intValue, items.count < minimum { problem("must have at least \(minimum) items") }
            if let maximum = object["maxItems"]?.intValue, items.count > maximum { problem("must have at most \(maximum) items") }
        }
        if let number = value.doubleValue {
            if let minimum = object["minimum"]?.doubleValue, number < minimum { problem("must be >= \(number: minimum)") }
            if let maximum = object["maximum"]?.doubleValue, number > maximum { problem("must be <= \(number: maximum)") }
        }
        if let string = value.stringValue {
            if let minimum = object["minLength"]?.intValue, string.count < minimum { problem("must be at least \(minimum) characters") }
            if let maximum = object["maxLength"]?.intValue, string.count > maximum { problem("must be at most \(maximum) characters") }
        }
        return problems
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("password", .string), ("boolean", .bool), ("null", .null), ("number", .number): true
        case ("integer", .number(let number)): number.rounded() == number
        case ("object", _), ("array", _), ("string", _), ("password", _), ("boolean", _), ("null", _), ("number", _), ("integer", _): false
        default: true
        }
    }
}

private extension String.StringInterpolation {
    /// A bound as the schema wrote it: 250, not 250.0.
    mutating func appendInterpolation(number: Double) {
        appendLiteral(number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number))
    }
}
