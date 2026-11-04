import Foundation
import HomeswiftNetwork
import HomeswiftPlugin

/// Sends a push notification; answers nil when it went, or what the service said when it refused it.
protocol DummyNotifying: Sendable {
    func send(_ notification: NotificationConfig, title: String?, text: String) async throws -> String?
}

/// Notify! (getnotifyapp.com) and Pushover, over HTTPS (spec 11). Pushover needs the user's own application token
/// (`notification.id`): the bridge has none of its own.
struct PushNotifier: DummyNotifying {
    let http: any HTTPSending

    static let notifyIcon = "https://icons.getnotifyapp.com/icons/mt1lwzhb-coo64058.png"

    func request(_ notification: NotificationConfig, title: String?, text: String) -> HTTPRequest? {
        var components: URLComponents
        var body: Data?
        switch notification.api {
        case .notify:
            guard let id = notification.id, let base = URLComponents(string: "https://push.getnotifyapp.com/notify-json/\(URLEncoding.rfc3986(id))") else { return nil }
            components = base
            components.percentEncodedQueryItems = [URLQueryItem(name: "token", value: URLEncoding.rfc3986(notification.token))]
            var fields: [String: JSONValue] = ["text": .string(text), "iconUrl": .string(notification.iconURL ?? Self.notifyIcon)]
            if let title { fields["title"] = .string(title) }
            if let groupType = notification.groupType { fields["groupType"] = .string(groupType) }
            body = JSONValue.object(fields).encoded()
        case .pushover:
            guard let application = notification.id else { return nil }
            components = URLComponents(string: "https://api.pushover.net/1/messages.json")!
            var items = [("token", application), ("user", notification.token), ("message", text)]
            if let title { items.append(("title", title)) }
            components.percentEncodedQueryItems = items.map { URLQueryItem(name: $0.0, value: URLEncoding.rfc3986($0.1)) }
        }
        guard let url = components.url else { return nil }
        return HTTPRequest(method: "POST", url: url, headers: [("Content-Type", "application/json")], body: body, timeout: .seconds(10))
    }

    func send(_ notification: NotificationConfig, title: String?, text: String) async throws -> String? {
        guard let request = request(notification, title: title, text: text) else { return "the notification has no address" }
        let response = try await http.send(request)
        guard response.status != 200 else { return nil }
        let reply = try? JSONValue(data: response.body)
        if let message = reply?["message"]?.stringValue ?? reply?["error"]?.stringValue { return message }
        if let errors = reply?["errors"]?.arrayValue?.compactMap(\.stringValue), !errors.isEmpty { return errors.joined(separator: ", ") }
        return "unknown error"
    }
}
