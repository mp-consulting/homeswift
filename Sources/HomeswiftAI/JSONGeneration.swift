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
    /// UI-only keys) into standard JSON Schema.
    public static func normalizePluginSchema(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case .array(let items):
            return .array(items.map(normalizePluginSchema))
        case .object(let object):
            var out: [String: JSONValue] = [:]
            var required: [String] = object["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            for (key, value) in object {
                if droppedSchemaKeys.contains(key) { continue }
                if key == "required" { continue }
                if key == "properties", let properties = value.objectValue {
                    out["properties"] = .object(properties.mapValues(normalizePluginSchema))
                    for (name, property) in properties where property["required"] == .bool(true) {
                        if !required.contains(name) { required.append(name) }
                    }
                } else {
                    out[key] = normalizePluginSchema(value)
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
/// and string bounds.
public enum JSONSchema {
    public static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "") -> [String] {
        guard let object = schema.objectValue else { return [] }
        var errors: [String] = []
        let location = path.isEmpty ? "(root)" : path

        if let type = object["type"] {
            let types = type.arrayValue?.compactMap(\.stringValue) ?? type.stringValue.map { [$0] } ?? []
            if !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) {
                errors.append("\(location) must be \(types.joined(separator: " or "))")
                return errors
            }
        }
        if let allowed = object["enum"]?.arrayValue, !allowed.contains(value) {
            errors.append("\(location) must be one of \(allowed.map { $0.text() }.joined(separator: ", "))")
        }
        if let constant = object["const"], constant != value {
            errors.append("\(location) must be \(constant.text())")
        }
        for keyword in ["anyOf", "oneOf"] {
            if let options = object[keyword]?.arrayValue, !options.contains(where: { validate(value, against: $0, path: path).isEmpty }) {
                errors.append("\(location) matches none of the allowed shapes")
            }
        }
        if let fields = value.objectValue {
            for name in object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where fields[name] == nil {
                errors.append("\(location) must have required property '\(name)'")
            }
            let properties = object["properties"]?.objectValue ?? [:]
            for (name, property) in properties {
                if let field = fields[name] {
                    errors += validate(field, against: property, path: path.isEmpty ? name : "\(path).\(name)")
                }
            }
            if object["additionalProperties"] == .bool(false) {
                for name in fields.keys.sorted() where properties[name] == nil {
                    errors.append("\(location) must not have additional property '\(name)'")
                }
            }
        }
        if let items = value.arrayValue {
            if let itemSchema = object["items"] {
                for (index, item) in items.enumerated() {
                    errors += validate(item, against: itemSchema, path: "\(path)[\(index)]")
                }
            }
            if let minimum = object["minItems"]?.intValue, items.count < minimum { errors.append("\(location) must have at least \(minimum) items") }
            if let maximum = object["maxItems"]?.intValue, items.count > maximum { errors.append("\(location) must have at most \(maximum) items") }
        }
        if let number = value.doubleValue {
            if let minimum = object["minimum"]?.doubleValue, number < minimum { errors.append("\(location) must be >= \(minimum)") }
            if let maximum = object["maximum"]?.doubleValue, number > maximum { errors.append("\(location) must be <= \(maximum)") }
        }
        if let string = value.stringValue {
            if let minimum = object["minLength"]?.intValue, string.count < minimum { errors.append("\(location) must be at least \(minimum) characters") }
            if let maximum = object["maxLength"]?.intValue, string.count > maximum { errors.append("\(location) must be at most \(maximum) characters") }
        }
        return errors
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null), ("number", .number): true
        case ("integer", .number(let number)): number.rounded() == number
        default: false
        }
    }
}
