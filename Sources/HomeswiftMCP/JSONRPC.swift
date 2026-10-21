import Foundation
import HomeswiftAI

/// A JSON-RPC 2.0 error, the shape MCP uses for protocol failures.
public struct JSONRPCError: Error, Sendable, Equatable, CustomStringConvertible {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func invalidParams(_ message: String) -> JSONRPCError { JSONRPCError(code: invalidParams, message: message) }
    public static func methodNotFound(_ method: String) -> JSONRPCError { JSONRPCError(code: methodNotFound, message: "Method not found: \(method)") }
    public static func invalidRequest(_ message: String) -> JSONRPCError { JSONRPCError(code: invalidRequest, message: message) }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { object["data"] = data }
        return .object(object)
    }

    public var description: String { "\(message) (\(code))" }
}

/// One JSON-RPC 2.0 message, as MCP exchanges them.
public enum JSONRPCMessage: Sendable, Equatable {
    case request(id: JSONValue, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: JSONValue, result: JSONValue)
    case failure(id: JSONValue, error: JSONRPCError)

    /// Parses one message. A malformed one is an `invalidRequest` error.
    public static func parse(_ value: JSONValue) throws(JSONRPCError) -> JSONRPCMessage {
        guard let object = value.objectValue else { throw .invalidRequest("a JSON-RPC message is an object") }
        guard object["jsonrpc"] == "2.0" else { throw .invalidRequest("jsonrpc must be \"2.0\"") }
        let id = object["id"].flatMap { $0.isNull ? nil : $0 }
        if let id, !(id.stringValue != nil || id.doubleValue != nil) {
            throw .invalidRequest("id must be a string or a number")
        }
        if let method = object["method"] {
            guard let name = method.stringValue else { throw .invalidRequest("method must be a string") }
            let params = object["params"].flatMap { $0.isNull ? nil : $0 }
            if let params, params.objectValue == nil, params.arrayValue == nil { throw .invalidRequest("params must be an object or an array") }
            return id.map { .request(id: $0, method: name, params: params) } ?? .notification(method: name, params: params)
        }
        guard let id else { throw .invalidRequest("a response needs an id") }
        if let error = object["error"] {
            guard let code = error["code"]?.intValue else { throw .invalidRequest("error.code must be an integer") }
            return .failure(id: id, error: JSONRPCError(code: code, message: error["message"]?.stringValue ?? "", data: error["data"]))
        }
        guard let result = object["result"] else { throw .invalidRequest("a response needs a result or an error") }
        return .response(id: id, result: result)
    }

    /// Parses JSON text holding one message or a batch.
    public static func parse(data: Data) throws(JSONRPCError) -> [JSONRPCMessage] {
        let value: JSONValue
        do {
            value = try JSONValue(data: data)
        } catch {
            throw JSONRPCError(code: JSONRPCError.parseError, message: "Parse error")
        }
        if let batch = value.arrayValue {
            guard !batch.isEmpty else { throw .invalidRequest("an empty batch") }
            var messages: [JSONRPCMessage] = []
            for item in batch { messages.append(try parse(item)) }
            return messages
        }
        return [try parse(value)]
    }

    public var json: JSONValue {
        switch self {
        case .request(let id, let method, let params):
            var object: [String: JSONValue] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
            if let params { object["params"] = params }
            return .object(object)
        case .notification(let method, let params):
            var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
            if let params { object["params"] = params }
            return .object(object)
        case .response(let id, let result):
            return ["jsonrpc": "2.0", "id": id, "result": result]
        case .failure(let id, let error):
            return ["jsonrpc": "2.0", "id": id, "error": error.json]
        }
    }

    public var id: JSONValue? {
        switch self {
        case .request(let id, _, _), .response(let id, _), .failure(let id, _): id
        case .notification: nil
        }
    }

    public var isRequest: Bool {
        if case .request = self { return true }
        return false
    }

    public var isResponse: Bool {
        switch self {
        case .response, .failure: true
        default: false
        }
    }
}

/// A key for an id, so `1` and `"1"` are kept apart.
func idKey(_ id: JSONValue) -> String { id.text() }
