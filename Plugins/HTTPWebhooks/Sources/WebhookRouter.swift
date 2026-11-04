import Foundation
import Homeswift
import Logging

/// An HTTP response of the webhook server.
struct WebhookHTTPResponse: Sendable, Equatable {
    var status: Int
    var contentType: String?
    var body: String
    var headers: [String: String] = [:]
}

/// What the webhook server answers, whatever the method and path: Basic authentication when it is configured, CORS
/// when it is on, then the accessory the query's `accessoryId` names (the first in the block's order) handles the
/// parameters. The texts of the errors are the Homebridge plugin's, so scripts that read them keep working.
struct WebhookRouter: Sendable {
    let accessories: [String: any WebhookAccessory]
    let credentials: (user: [UInt8], password: [UInt8])?
    let cors: Bool
    let logger: Logger

    static let realm = "Auth required"
    static let corsHeaders = [
        "Access-Control-Allow-Origin": "*", "Access-Control-Request-Method": "*", "Access-Control-Allow-Methods": "OPTIONS, GET, POST",
        "Access-Control-Allow-Headers": "*",
    ]

    init(accessories: [String: any WebhookAccessory], credentials: (user: String, password: String)?, cors: Bool, logger: Logger) {
        self.accessories = accessories
        self.credentials = credentials.map { (Array($0.user.utf8), Array($0.password.utf8)) }
        self.cors = cors
        self.logger = logger
    }

    func respond(method: String, uri: String, authorization: String?) -> WebhookHTTPResponse {
        guard isAuthorized(authorization) else {
            return WebhookHTTPResponse(
                status: 401, contentType: "text/plain; charset=utf-8", body: "401 Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"\(Self.realm)\""])
        }
        var response = route(method: method, uri: uri)
        if cors { response.headers.merge(Self.corsHeaders) { $1 } }
        return response
    }

    private func route(method: String, uri: String) -> WebhookHTTPResponse {
        if cors, method == "OPTIONS" { return WebhookHTTPResponse(status: 200, contentType: nil, body: "") }
        let query = WebhookQuery(uri: uri)
        guard let id = query.nonEmpty("accessoryId") else { return error("[ERROR Http WebHook Server] No accessoryId in request.") }
        guard let accessory = accessories[id] else { return error("[ERROR Http WebHook Server] AccessoryId '\(id)' not found.") }
        return WebhookHTTPResponse(status: 200, contentType: "application/json", body: accessory.handle(query).json)
    }

    private func error(_ message: String) -> WebhookHTTPResponse {
        logger.warning("\(message)")
        return WebhookHTTPResponse(status: 404, contentType: "text/plain", body: message)
    }

    /// Basic credentials equal to the configured ones, compared in constant time (both, whatever the first gave).
    func isAuthorized(_ authorization: String?) -> Bool {
        guard let credentials else { return true }
        guard let authorization, authorization.count < 4096 else { return false }
        let parts = authorization.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "basic",
            let decoded = Data(base64Encoded: String(parts[1]).trimmingCharacters(in: .whitespaces)),
            let colon = decoded.firstIndex(of: UInt8(ascii: ":"))
        else { return false }
        let user = Secrets.constantTimeEqual(decoded[decoded.startIndex..<colon], credentials.user)
        let password = Secrets.constantTimeEqual(decoded[decoded.index(after: colon)...], credentials.password)
        return user && password
    }
}
