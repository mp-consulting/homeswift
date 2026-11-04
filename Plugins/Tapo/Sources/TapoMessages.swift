import Foundation
import HomeswiftAI

/// What went wrong talking to a device.
enum TapoError: Error, CustomStringConvertible, Equatable {
    /// The device answered with this HTTP status.
    case http(Int)
    /// The device does not know the account's credentials: KLAP's server hash did not match, or the login was refused.
    case invalidCredentials
    /// A non-zero `error_code`.
    case device(Int)
    case invalidResponse(String)
    /// The device ended the session again right after a new handshake.
    case sessionRefused
    /// The block has no `username` or `password`, and Setup kept none.
    case noCredentials

    var description: String {
        switch self {
        case .http(let status): "the device answered HTTP \(status)"
        case .invalidCredentials:
            "the device refused the Tapo account's email and password (check them, and that Third-Party Compatibility is on in the Tapo app)"
        case .device(let code): "error \(code) (\(Self.meaning(of: code)))"
        case .invalidResponse(let what): "an unexpected response: \(what)"
        case .sessionRefused: "the device ended the session right after signing in"
        case .noCredentials: "no Tapo account: set username and password, or sign in through Add accessories"
        }
    }

    /// The meanings of the device's error codes (docs/clean-room/Tapo.md, 4.5).
    static func meaning(of code: Int) -> String {
        meanings[code] ?? "unknown error"
    }

    private static let meanings: [Int: String] = [
        0: "success", -1010: "invalid public key length", -1012: "invalid terminalUUID", -1501: "invalid request or credentials",
        1002: "incorrect request", -1003: "JSON formatting error", 9999: "session timeout", -1301: "device error", 1100: "handshake failed",
        1111: "login failed", 1112: "HTTP transport failed", 1200: "multiple requests failed", -1004: "JSON encode failed",
        -1005: "AES decode failed", -1006: "request length error", -2101: "account error", -1: "common failure", 1000: "null transport",
        1001: "command cancelled", -1001: "unspecific error", -1002: "unknown method", -1007: "cloud failed", -1008: "bad parameters",
        -1101: "session parameter error", -1201: "quick setup error", -1302: "device next event error", -1401: "firmware error",
        -1402: "firmware version error", -1601: "time error", -1602: "system time error", -1603: "time save error", -1701: "wireless error",
        -1702: "wireless unsupported", -1801: "schedule error", -1802: "schedule full", -1803: "schedule conflict", -1804: "schedule save error",
        -1805: "schedule index error", -1901: "countdown error", -1902: "countdown conflict", -1903: "countdown save error",
        -2001: "anti-theft error", -2002: "anti-theft conflict", -2003: "anti-theft save error", -2201: "statistics error",
        -2202: "statistics save error", -2301: "daylight saving error", -2302: "daylight saving save error", 1003: "the device wants KLAP",
    ]
}

/// The JSON texts devices take and answer.
enum TapoMessage {
    /// The session expired on the device: a new handshake, then the request once more.
    static let sessionTimeout = 9999
    /// Invalid request or credentials: the session's credentials no longer hold, a new handshake, then the request once
    /// more before it is reported.
    static let invalidCredentials = -1501
    /// The answer of securePassthrough's handshake on a device that speaks KLAP.
    static let wantsKLAP = 1003

    /// A request: `method`, its `params`, `requestTimeMils` (milliseconds times 1000, as the devices were sent) and, for
    /// on and off, `terminalUUID`.
    static func request(_ method: String, params: [String: JSONValue]? = nil, terminalUUID: String? = nil, now: Date = Date()) -> Data {
        var fields: [String: JSONValue] = ["method": .string(method), "requestTimeMils": .number((now.timeIntervalSince1970 * 1000).rounded() * 1000)]
        if let params { fields["params"] = .object(params) }
        if let terminalUUID { fields["terminalUUID"] = .string(terminalUUID) }
        return JSONValue.object(fields).encoded()
    }

    /// A response, read leniently: some firmware writes `error_code` as a number with a leading zero (`-0301`) or a
    /// character after it, which is not JSON; it is rewritten as a plain integer first.
    static func parse(_ data: Data) throws -> JSONValue {
        if let json = try? JSONValue(data: data) { return json }
        do {
            return try JSONValue(string: repairingErrorCode(String(decoding: data, as: UTF8.self)))
        } catch {
            throw TapoError.invalidResponse("a response that is not JSON (\(data.count) bytes)")
        }
    }

    /// `"error_code": -0301x` → `"error_code":-301`: the sign and the digits without their leading zeros, and nothing
    /// else up to the next `,`, `}` or `]`.
    static func repairingErrorCode(_ text: String) -> String {
        let key = "\"error_code\""
        guard let found = text.range(of: key) else { return text }
        var index = found.upperBound
        func skip(_ allowed: (Character) -> Bool) {
            while index < text.endIndex, allowed(text[index]) { index = text.index(after: index) }
        }
        skip(\.isWhitespace)
        guard index < text.endIndex, text[index] == ":" else { return text }
        index = text.index(after: index)
        skip { $0.isWhitespace || $0 == "\"" }
        var number = ""
        if index < text.endIndex, text[index] == "-" {
            number = "-"
            index = text.index(after: index)
        }
        let digitsStart = index
        skip { $0.isASCII && $0.isNumber }
        let digits = text[digitsStart..<index].drop { $0 == "0" }
        number += digits.isEmpty ? "0" : String(digits)
        guard index > digitsStart else { return text }
        skip { $0 != "," && $0 != "}" && $0 != "]" }
        return String(text[..<found.lowerBound]) + key + ":" + (number == "-0" ? "0" : number) + text[index...]
    }

    /// `error_code` as an integer, a number or a numeric string; nil when there is none.
    static func errorCode(of response: JSONValue) -> Int? {
        switch response["error_code"] {
        case .number(let value): Int(exactly: value)
        case .string(let text): Int(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// The `result` of a response whose `error_code` is 0; throws the device's error otherwise.
    static func result(of response: JSONValue) throws -> JSONValue {
        guard let code = errorCode(of: response) else { throw TapoError.invalidResponse("no error_code") }
        guard code == 0 else { throw TapoError.device(code) }
        return response["result"] ?? .null
    }
}
