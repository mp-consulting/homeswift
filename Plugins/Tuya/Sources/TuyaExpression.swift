import Foundation
import HomeswiftAI

/// The `onGet` and `onSet` expressions of a DP override. homebridge-tuya-platform runs them as JavaScript; this reads the
/// part of JavaScript its documentation shows, and nothing that could act: literals, `value` and `device`, arithmetic,
/// comparisons, `! && ||`, `? :`, `Math.round/floor/ceil/min/max/abs/trunc`, member access and
/// `device.status.find(s => s.code === 'x')`. There are no assignments, loops or calls other than those, and an
/// expression is bounded in length and depth. Statements separated by `;` are run in turn; the last one's value is the
/// result.
struct TuyaExpression: Sendable {
    /// A JavaScript value, as far as these expressions need.
    indirect enum Value: Sendable, Equatable {
        case undefined
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([Value])
        case object([String: Value])
        case function(parameter: String, body: Node)
        case builtin(String)

        init(_ json: JSONValue?) {
            switch json {
            case nil: self = .undefined
            case .null?: self = .null
            case .bool(let value)?: self = .bool(value)
            case .number(let value)?: self = .number(value)
            case .string(let value)?: self = .string(value)
            case .array(let items)?: self = .array(items.map { Value($0) })
            case .object(let fields)?: self = .object(fields.mapValues { Value($0) })
            }
        }

        /// The JSON for a result: nil for `undefined` (a command dropped).
        var json: JSONValue? {
            switch self {
            case .undefined, .function, .builtin: nil
            case .null: .null
            case .bool(let value): .bool(value)
            case .number(let value): value.isFinite ? .number(value) : nil
            case .string(let value): .string(value)
            case .array(let items): .array(items.map { $0.json ?? .null })
            case .object(let fields): .object(fields.compactMapValues(\.json))
            }
        }

        var isTruthy: Bool {
            switch self {
            case .undefined, .null: false
            case .bool(let value): value
            case .number(let value): value != 0 && !value.isNaN
            case .string(let value): !value.isEmpty
            default: true
            }
        }

        var number: Double {
            switch self {
            case .undefined: .nan
            case .null: 0
            case .bool(let value): value ? 1 : 0
            case .number(let value): value
            case .string(let text):
                text.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : Double(text.trimmingCharacters(in: .whitespaces)) ?? .nan
            default: .nan
            }
        }

        var text: String {
            switch self {
            case .undefined: "undefined"
            case .null: "null"
            case .bool(let value): value ? "true" : "false"
            case .number(let value):
                if value.rounded() == value, abs(value) < 1e21 { String(format: "%.0f", value) } else { "\(value)" }
            case .string(let value): value
            case .array(let items): items.map(\.text).joined(separator: ",")
            default: "[object Object]"
            }
        }
    }

    /// The parsed expression.
    indirect enum Node: Sendable, Equatable {
        case literal(Value)
        case identifier(String)
        case member(Node, String)
        case index(Node, Node)
        case call(Node, [Node])
        case unary(String, Node)
        case binary(String, Node, Node)
        case logical(String, Node, Node)
        case conditional(Node, Node, Node)
        case arrow(String, Node)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static let maximumLength = 1000
    static let maximumDepth = 48

    let source: String
    private let statements: [Node]
    /// Whether it reads `device`, which is only built then.
    private let usesDevice: Bool

    init(_ source: String) throws {
        guard source.count <= Self.maximumLength else { throw Failure("longer than \(Self.maximumLength) characters") }
        self.source = source
        let tokens = try Lexer.tokens(source)
        usesDevice = tokens.contains(.identifier("device"))
        var parser = Parser(tokens: tokens)
        statements = try parser.program()
    }

    /// The expression's value for `value` and a device (`device.id`, `online`, `status` as `{code, value}`…).
    func evaluate(value: Value, device: @autoclosure () -> Value) throws -> Value {
        var evaluator = Evaluator(scope: ["value": value, "device": usesDevice ? device() : .undefined, "Math": .object(Evaluator.math)])
        var result = Value.undefined
        for statement in statements { result = try evaluator.evaluate(statement, depth: 0) }
        return result
    }

    // MARK: Lexer

    enum Token: Equatable {
        case number(Double)
        case string(String)
        case identifier(String)
        case symbol(String)
    }

    enum Lexer {
        static let symbols = ["===", "!==", "=>", "==", "!=", "<=", ">=", "&&", "||", "+", "-", "*", "/", "%", "<", ">", "!", "?", ":", "(", ")",
                              "[", "]", ".", ",", ";"]

        static func tokens(_ source: String) throws -> [Token] {
            let characters = Array(source)
            var tokens: [Token] = []
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace { index += 1; continue }
                if character.isNumber || (character == "." && index + 1 < characters.count && characters[index + 1].isNumber) {
                    var end = index
                    while end < characters.count, characters[end].isNumber || characters[end] == "." || characters[end] == "e" || characters[end] == "E"
                        || ((characters[end] == "+" || characters[end] == "-") && end > index && (characters[end - 1] == "e" || characters[end - 1] == "E")) {
                        end += 1
                    }
                    guard let number = Double(String(characters[index..<end])) else { throw Failure("unreadable number") }
                    tokens.append(.number(number))
                    index = end
                    continue
                }
                if character == "'" || character == "\"" || character == "`" {
                    var text = ""
                    var end = index + 1
                    while end < characters.count, characters[end] != character {
                        if characters[end] == "\\", end + 1 < characters.count {
                            end += 1
                            switch characters[end] {
                            case "n": text.append("\n")
                            case "t": text.append("\t")
                            default: text.append(characters[end])
                            }
                        } else {
                            if character == "`", characters[end] == "$" { throw Failure("template strings are not supported") }
                            text.append(characters[end])
                        }
                        end += 1
                    }
                    guard end < characters.count else { throw Failure("unterminated string") }
                    tokens.append(.string(text))
                    index = end + 1
                    continue
                }
                if character.isLetter || character == "_" || character == "$" {
                    var end = index
                    while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" || characters[end] == "$" {
                        end += 1
                    }
                    tokens.append(.identifier(String(characters[index..<end])))
                    index = end
                    continue
                }
                guard let symbol = symbols.first(where: { symbol in
                    let length = symbol.count
                    return index + length <= characters.count && String(characters[index..<(index + length)]) == symbol
                }) else { throw Failure("unexpected \(character)") }
                tokens.append(.symbol(symbol))
                index += symbol.count
            }
            return tokens
        }
    }

    // MARK: Parser

    struct Parser {
        let tokens: [Token]
        var position = 0
        var depth = 0

        init(tokens: [Token]) { self.tokens = tokens }

        var current: Token? { position < tokens.count ? tokens[position] : nil }

        mutating func accept(_ symbol: String) -> Bool {
            if current == .symbol(symbol) { position += 1; return true }
            return false
        }

        mutating func expect(_ symbol: String) throws {
            guard accept(symbol) else { throw Failure("expected \(symbol)") }
        }

        mutating func program() throws -> [Node] {
            var statements: [Node] = []
            while current != nil {
                if accept(";") { continue }
                statements.append(try expression())
                guard current == nil || accept(";") else { throw Failure("unexpected text after an expression") }
            }
            guard !statements.isEmpty else { throw Failure("empty expression") }
            return statements
        }

        mutating func expression() throws -> Node {
            depth += 1
            defer { depth -= 1 }
            guard depth <= TuyaExpression.maximumDepth else { throw Failure("nested too deeply") }
            // `x => body` and `(x) => body`.
            if case .identifier(let name)? = current, position + 1 < tokens.count, tokens[position + 1] == .symbol("=>") {
                position += 2
                return .arrow(name, try expression())
            }
            if current == .symbol("("), position + 3 < tokens.count, case .identifier(let name) = tokens[position + 1],
               tokens[position + 2] == .symbol(")"), tokens[position + 3] == .symbol("=>") {
                position += 4
                return .arrow(name, try expression())
            }
            let test = try binary(0)
            guard accept("?") else { return test }
            let yes = try expression()
            try expect(":")
            return .conditional(test, yes, try expression())
        }

        static let levels: [[String]] = [["||"], ["&&"], ["===", "!==", "==", "!="], ["<", "<=", ">", ">="], ["+", "-"], ["*", "/", "%"]]

        mutating func binary(_ level: Int) throws -> Node {
            guard level < Self.levels.count else { return try unary() }
            var left = try binary(level + 1)
            while case .symbol(let symbol)? = current, Self.levels[level].contains(symbol) {
                position += 1
                let right = try binary(level + 1)
                left = level < 2 ? .logical(symbol, left, right) : .binary(symbol, left, right)
            }
            return left
        }

        mutating func unary() throws -> Node {
            for symbol in ["!", "-", "+"] where accept(symbol) {
                depth += 1
                defer { depth -= 1 }
                guard depth <= TuyaExpression.maximumDepth else { throw Failure("nested too deeply") }
                return .unary(symbol, try unary())
            }
            return try postfix()
        }

        mutating func postfix() throws -> Node {
            var node = try primary()
            while true {
                if accept(".") {
                    guard case .identifier(let name)? = current else { throw Failure("expected a name after .") }
                    position += 1
                    node = .member(node, name)
                } else if accept("[") {
                    let index = try expression()
                    try expect("]")
                    node = .index(node, index)
                } else if accept("(") {
                    var arguments: [Node] = []
                    if !accept(")") {
                        repeat { arguments.append(try expression()) } while accept(",")
                        try expect(")")
                    }
                    node = .call(node, arguments)
                } else {
                    return node
                }
            }
        }

        mutating func primary() throws -> Node {
            guard let token = current else { throw Failure("unexpected end") }
            position += 1
            switch token {
            case .number(let number): return .literal(.number(number))
            case .string(let text): return .literal(.string(text))
            case .identifier(let name):
                switch name {
                case "true": return .literal(.bool(true))
                case "false": return .literal(.bool(false))
                case "undefined": return .literal(.undefined)
                case "null": return .literal(.null)
                case "NaN": return .literal(.number(.nan))
                case "value", "device", "Math": return .identifier(name)
                default:
                    // A name is a parameter of an arrow function; anything else (`require`, `process`) is unknown.
                    return .identifier(name)
                }
            case .symbol("("):
                let node = try expression()
                try expect(")")
                return node
            case .symbol(let symbol): throw Failure("unexpected \(symbol)")
            }
        }
    }

    // MARK: Evaluator

    struct Evaluator {
        var scope: [String: Value]

        static let math: [String: Value] = Dictionary(uniqueKeysWithValues: ["round", "floor", "ceil", "min", "max", "abs", "trunc"].map {
            ($0, Value.builtin($0))
        })

        mutating func evaluate(_ node: Node, depth: Int) throws -> Value {
            guard depth <= TuyaExpression.maximumDepth * 2 else { throw Failure("nested too deeply") }
            switch node {
            case .literal(let value): return value
            case .identifier(let name):
                guard let value = scope[name] else { throw Failure("\(name) is not supported") }
                return value
            case .member(let object, let name):
                return try member(try evaluate(object, depth: depth + 1), name)
            case .index(let object, let index):
                let base = try evaluate(object, depth: depth + 1)
                let key = try evaluate(index, depth: depth + 1)
                if case .array(let items) = base {
                    let number = key.number
                    guard number.rounded() == number, number >= 0, number < Double(items.count) else { return .undefined }
                    return items[Int(number)]
                }
                return try member(base, key.text)
            case .call(let callee, let arguments):
                return try call(callee, arguments, depth: depth)
            case .unary(let symbol, let operand):
                let value = try evaluate(operand, depth: depth + 1)
                switch symbol {
                case "!": return .bool(!value.isTruthy)
                case "-": return .number(-value.number)
                default: return .number(value.number)
                }
            case .logical(let symbol, let left, let right):
                let first = try evaluate(left, depth: depth + 1)
                if symbol == "&&" { return first.isTruthy ? try evaluate(right, depth: depth + 1) : first }
                return first.isTruthy ? first : try evaluate(right, depth: depth + 1)
            case .binary(let symbol, let left, let right):
                return try Self.binary(symbol, try evaluate(left, depth: depth + 1), try evaluate(right, depth: depth + 1))
            case .conditional(let test, let yes, let no):
                return try evaluate(test, depth: depth + 1).isTruthy ? try evaluate(yes, depth: depth + 1) : try evaluate(no, depth: depth + 1)
            case .arrow(let parameter, let body):
                return .function(parameter: parameter, body: body)
            }
        }

        func member(_ base: Value, _ name: String) throws -> Value {
            switch base {
            case .undefined, .null: throw Failure("cannot read \(name) of \(base.text)")
            case .object(let fields): return fields[name] ?? .undefined
            case .array(let items): return name == "length" ? .number(Double(items.count)) : name == "find" ? .builtin("find") : .undefined
            case .string(let text): return name == "length" ? .number(Double(text.count)) : .undefined
            default: return .undefined
            }
        }

        mutating func call(_ callee: Node, _ arguments: [Node], depth: Int) throws -> Value {
            guard case .member(let objectNode, let name) = callee else { throw Failure("only Math functions and find can be called") }
            let object = try evaluate(objectNode, depth: depth + 1)
            if case .array(let items) = object, name == "find" {
                guard arguments.count == 1, case .arrow(let parameter, let body) = arguments[0] else { throw Failure("find takes one arrow function") }
                let saved = scope[parameter]
                defer { scope[parameter] = saved }
                for item in items {
                    scope[parameter] = item
                    if try evaluate(body, depth: depth + 1).isTruthy { return item }
                }
                return .undefined
            }
            guard case .builtin(let function) = try member(object, name), function != "find" else { throw Failure("\(name) cannot be called") }
            let values = try arguments.map { try evaluate($0, depth: depth + 1).number }
            switch function {
            case "round": return .number(values.first.map { ($0 + 0.5).rounded(.down) } ?? .nan)
            case "floor": return .number(values.first.map { $0.rounded(.down) } ?? .nan)
            case "ceil": return .number(values.first.map { $0.rounded(.up) } ?? .nan)
            case "trunc": return .number(values.first.map { $0.rounded(.towardZero) } ?? .nan)
            case "abs": return .number(values.first.map(Swift.abs) ?? .nan)
            case "min": return .number(values.contains(where: \.isNaN) ? .nan : values.min() ?? .infinity)
            case "max": return .number(values.contains(where: \.isNaN) ? .nan : values.max() ?? -.infinity)
            default: throw Failure("\(function) is not supported")
            }
        }

        static func binary(_ symbol: String, _ left: Value, _ right: Value) throws -> Value {
            switch symbol {
            case "===": return .bool(strictlyEqual(left, right))
            case "!==": return .bool(!strictlyEqual(left, right))
            case "==": return .bool(looselyEqual(left, right))
            case "!=": return .bool(!looselyEqual(left, right))
            case "<", "<=", ">", ">=":
                if case .string(let a) = left, case .string(let b) = right {
                    switch symbol {
                    case "<": return .bool(a < b)
                    case "<=": return .bool(a <= b)
                    case ">": return .bool(a > b)
                    default: return .bool(a >= b)
                    }
                }
                let a = left.number, b = right.number
                switch symbol {
                case "<": return .bool(a < b)
                case "<=": return .bool(a <= b)
                case ">": return .bool(a > b)
                default: return .bool(a >= b)
                }
            case "+":
                if case .string = left { return .string(left.text + right.text) }
                if case .string = right { return .string(left.text + right.text) }
                return .number(left.number + right.number)
            case "-": return .number(left.number - right.number)
            case "*": return .number(left.number * right.number)
            case "/": return .number(left.number / right.number)
            case "%": return .number(left.number.truncatingRemainder(dividingBy: right.number))
            default: throw Failure("\(symbol) is not supported")
            }
        }

        static func strictlyEqual(_ left: Value, _ right: Value) -> Bool {
            switch (left, right) {
            case (.undefined, .undefined), (.null, .null): true
            case (.bool(let a), .bool(let b)): a == b
            case (.number(let a), .number(let b)): a == b
            case (.string(let a), .string(let b)): a == b
            default: false
            }
        }

        static func looselyEqual(_ left: Value, _ right: Value) -> Bool {
            switch (left, right) {
            case (.undefined, .null), (.null, .undefined): return true
            case (.undefined, _), (.null, _), (_, .undefined), (_, .null): return strictlyEqual(left, right)
            case (.string(let a), .string(let b)): return a == b
            default: return left.number == right.number
            }
        }
    }
}
