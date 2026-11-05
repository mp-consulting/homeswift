import Crypto
import Foundation
import HomeswiftNetwork
import NIOConcurrencyHelpers

@testable import HomeswiftTapo

/// The TP-Link cloud in memory (docs/clean-room/TapoCloudEvents.md): signed v2 calls checked (Content-MD5 and the
/// HMAC-SHA1 signature), the login with an e-mail code for an unknown terminal, the token and its refresh, the camera
/// list and the notification inbox.
final class FakeTapoCloud: HTTPSending, @unchecked Sendable {
    struct State {
        var username = "user@example.com"
        var password = "password123"
        var requiresCode = false
        var code = "123456"
        var trustedTerminals: Set<String> = []
        var token = "token-1"
        var tokenCount = 1
        /// The next authorized calls answer -20651 (token expired).
        var expireNext = 0
        var cameras: [[String: Any]] = [["deviceId": "CLOUDID0001", "alias": Data("Garden".utf8).base64EncodedString(), "deviceModel": "C675D",
                                         "deviceMac": "10-5A-95-2F-AD-17", "deviceType": "SMART.IPCAMERA"]]
        var notifications: [[String: Any]] = []
        var paths: [String] = []
        var badSignatures = 0
        var codesSent = 0
        var lastSince: Int?
    }

    let state = NIOLockedValueBox(State())

    var paths: [String] { state.withLockedValue { $0.paths } }
    var logins: Int { paths.filter { $0 == "/api/v2/account/login" }.count }

    /// A message as the real inbox has it: type, id and time (milliseconds) at the top, the camera in `attachments`.
    func notify(deviceID: String = "CLOUDID0001", type: String = "Motion", time: Date = Date()) {
        state.withLockedValue { state in
            let seconds = Int(time.timeIntervalSince1970)
            state.notifications.append([
                "msgId": "m\(state.notifications.count + 1)", "msgType": type, "time": seconds * 1000 + 123, "title": "Garden", "content": "Motion detected",
                "attachments": ["deviceId": deviceID, "chnId": "0", "deviceModel": "C675D", "msgType": type, "time": String(seconds)],
            ])
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        let body = request.body ?? Data()
        let headers = Dictionary(request.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        // The signature, recomputed as the spec says.
        var signed = false
        if let md5 = headers["content-md5"], let authorization = headers["x-authorization"] {
            let fields = Dictionary(authorization.components(separatedBy: ", ").compactMap { part -> (String, String)? in
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                return pair.count == 2 ? (pair[0], pair[1]) : nil
            }, uniquingKeysWith: { first, _ in first })
            let message = "\(md5)\n\(fields["Timestamp"] ?? "")\n\(fields["Nonce"] ?? "")\n\(path)"
            let expected = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data("6ed7d97f3e73467f8a5bab90b577ba4c".utf8))))
                .map { String(format: "%02x", $0) }.joined()
            signed = md5 == Data(Insecure.MD5.hash(data: body)).base64EncodedString() && fields["Signature"] == expected
                && fields["AccessKey"] == "4d11b6b9d5ea4d19a829adbb9714b057"
        }
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let token = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value
        let terminal = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "termID" }?.value ?? ""
        let answer: [String: Any] = state.withLockedValue { state in
            state.paths.append(path)
            guard signed else {
                state.badSignatures += 1
                return ["error_code": -10304]
            }
            func tokenResult() -> [String: Any] {
                state.tokenCount += 1
                state.token = "token-\(state.tokenCount)"
                return ["error_code": 0, "result": ["token": state.token, "refreshToken": "refresh-\(state.tokenCount)", "appServerUrl": "https://n-euw1-wap-gw.example"]]
            }
            switch path {
            case "/api/v2/account/getAccountStatusAndUrl":
                return ["error_code": 0, "result": ["appServerUrl": "https://n-euw1-wap-gw.example"]]
            case "/api/v2/account/login":
                guard json["cloudUserName"] as? String == state.username, json["cloudPassword"] as? String == state.password else {
                    return ["error_code": 0, "result": ["errorCode": "-20601", "errorMsg": "Incorrect"]]
                }
                if state.requiresCode, !state.trustedTerminals.contains(json["terminalUUID"] as? String ?? "") {
                    return ["error_code": 0, "result": ["MFAProcessId": "process-1", "supportedMFATypes": [1, 2]]]
                }
                return tokenResult()
            case "/api/v2/account/getEmailVC4TerminalMFA":
                state.codesSent += 1
                return ["error_code": 0, "result": [:]]
            case "/api/v2/account/checkMFACodeAndLogin":
                guard json["code"] as? String == state.code, json["MFAProcessId"] as? String == "process-1" else { return ["error_code": -20607] }
                if json["terminalBindEnabled"] as? Bool == true { state.trustedTerminals.insert(terminal) }
                return tokenResult()
            case "/api/v2/account/refreshToken":
                guard json["refreshToken"] as? String == "refresh-\(state.tokenCount)" else { return ["error_code": -20655] }
                return tokenResult()
            default:
                guard token == state.token else { return ["error_code": -20651] }
                if state.expireNext > 0 {
                    state.expireNext -= 1
                    return ["error_code": -20651]
                }
                switch path {
                case "/api/v2/common/getDeviceListByPage":
                    return ["error_code": 0, "result": ["deviceList": state.cameras]]
                case "/api/v2/common/getAppNotificationByPage":
                    // `indexTime` in milliseconds, as the messages' `time`.
                    let since = json["indexTime"] as? Int ?? 0
                    state.lastSince = since
                    let wanted = Set(json["msgTypes"] as? [String] ?? [])
                    let list = state.notifications.filter { ($0["time"] as? Int ?? 0) >= since && wanted.contains($0["msgType"] as? String ?? "") }
                    return ["error_code": 0, "result": ["notifications": list, "hasNextPage": false]]
                default:
                    return ["error_code": -20104]
                }
            }
        }
        return HTTPResponse(status: 200, body: try JSONSerialization.data(withJSONObject: answer))
    }
}
