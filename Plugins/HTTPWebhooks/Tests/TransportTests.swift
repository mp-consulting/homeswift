import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging
import Testing

@testable import Homeswift
@testable import HomeswiftHTTPWebhooks

/// The query, the outgoing calls and the server over a real socket on the loopback interface.
@Suite(.timeLimit(.minutes(1)))
struct TransportTests {
    @Test func queriesDecodeAsNodeDoes() {
        let query = WebhookQuery(uri: "/any/path?accessoryId=a+b&state=%74rue&x=1&x=2&empty=&flag#fragment")
        #expect(query["accessoryId"] == "a b")
        #expect(query.isTrue("state"))
        // Repeated: no longer equal to a single value.
        #expect(query["x"] == "1,2")
        #expect(query["empty"] == "")
        #expect(query.nonEmpty("empty") == nil)
        #expect(query["flag"] == "")
        #expect(WebhookQuery(uri: "/").values.isEmpty)
        #expect(!WebhookQuery(uri: "/?state=TRUE").isTrue("state"))
        #expect(WebhookNumber.integer("40abc") == 40)
        #expect(WebhookNumber.integer("abc") == nil)
        #expect(WebhookNumber.parse(" 21.5 ") == 21.5)
        #expect(WebhookNumber.parse("NaN") == nil)
    }

    @Test func placeholdersReplaceTheirFirstOccurrence() {
        let call = OutgoingCall(url: "http://x/%d/%d", method: "POST", body: "v=%d", form: nil, headers: nil, rejectUnauthorized: true)
        let substituted = call.substituting([("%d", "1")], in: .url)
        #expect(substituted.url == "http://x/1/%d")
        #expect(substituted.body == "v=%d")
        #expect(call.substituting([("%d", "2")], in: .all).body == "v=2")
        // A form takes the substitution instead of the body.
        let form = OutgoingCall(url: "http://x", method: "POST", body: "%s", form: #"{"s":"%s"}"#, headers: nil, rejectUnauthorized: true)
        #expect(form.substituting([("%s", "on")], in: .all).form == #"{"s":"on"}"#)
        #expect(form.substituting([("%s", "on")], in: .all).body == "%s")
        #expect(Format.number(21) == "21")
        #expect(Format.number(21.5) == "21.5")
        #expect(LightAccessory.scaled(50, by: 2.55) == 128)
        #expect(LightAccessory.scaled(100, by: 0.03) == 3)
    }

    @Test func callsBecomeRequests() throws {
        let call = OutgoingCall(
            url: "http://user:p%40ss@10.0.0.5:8080/relay?on=1", method: "PUT", body: "ignored", form: #"{"b":"x y","a":1,"c":true}"#,
            headers: #"{"Authorization":"Bearer abc","X-Count":3}"#, rejectUnauthorized: true)
        let request = try call.request(timeout: .seconds(10))
        #expect(request.method == "PUT")
        #expect(request.url.absoluteString == "http://10.0.0.5:8080/relay?on=1")
        // The headers' own Authorization wins over the URL's user name and password.
        #expect(request.header("Authorization") == "Bearer abc")
        #expect(request.header("X-Count") == "3")
        #expect(request.body == Data("a=1&b=x%20y&c=true".utf8))
        #expect(request.header("Content-Type") == "application/x-www-form-urlencoded")
        // No secrets in the log.
        #expect(call.logDescription == "PUT http://10.0.0.5:8080/relay")

        let basic = try OutgoingCall(url: "http://user:p%40ss@host/", method: "GET", body: "x", rejectUnauthorized: true).request(timeout: .seconds(1))
        #expect(basic.header("Authorization") == "Basic " + Data("user:p@ss".utf8).base64EncodedString())
        #expect(basic.body == nil)
        // Only POST, PUT and PATCH, written so, carry a body.
        #expect(try OutgoingCall(url: "http://h/", method: "post", body: "x", rejectUnauthorized: true).request(timeout: .seconds(1)).body == nil)
        #expect(throws: OutgoingCall.Failure.self) {
            try OutgoingCall(url: "http://h/", method: "GET", headers: "not json", rejectUnauthorized: true).request(timeout: .seconds(1))
        }
        #expect(throws: OutgoingCall.Failure.self) { try OutgoingCall(url: "ftp://h/", method: "GET", rejectUnauthorized: true).request(timeout: .seconds(1)) }
    }

    @Test func redirectsOfAGetAreFollowed() async throws {
        let http = FakeHTTP()
        await http.redirect("http://a/start", to: "http://a/next")
        let caller = OutgoingCaller(client: { _ in http }, logger: testLogger)
        try await caller.send(OutgoingCall(url: "http://a/start", method: "GET", rejectUnauthorized: true), timeout: .seconds(5), name: "Test")
        #expect(await http.urls == ["http://a/start", "http://a/next"])
        // Credentials and the entry's headers stay on the host they were given for, and off a downgrade to HTTP.
        let headers = #"{"X-Api-Key":"k","Accept":"text/plain"}"#
        await http.redirect("http://u:p@a/same", to: "http://a/kept")
        await http.redirect("http://a/same", to: "http://a/kept")
        await http.redirect("http://a/away", to: "http://b/elsewhere")
        await http.redirect("https://a/secure", to: "http://a/plain")
        await http.redirect("http://a/port", to: "http://a:8080/other-port")
        for url in ["http://u:p@a/same", "http://u:p@a/away", "https://u:p@a/secure", "http://u:p@a/port"] {
            try await caller.send(OutgoingCall(url: url, method: "GET", headers: headers, rejectUnauthorized: true), timeout: .seconds(5), name: "Test")
        }
        let requests = await http.requests
        func last(_ url: String) -> HTTPRequest? { requests.last { $0.url.absoluteString == url } }
        #expect(last("http://a/kept")?.header("X-Api-Key") == "k")
        #expect(last("http://a/kept")?.header("Authorization") != nil)
        for url in ["http://b/elsewhere", "http://a/plain", "http://a:8080/other-port"] {
            #expect(last(url)?.header("X-Api-Key") == nil, "\(url)")
            #expect(last(url)?.header("Accept") == nil, "\(url)")
            #expect(last(url)?.header("Authorization") == nil, "\(url)")
        }
        await http.answer("http://a/fails", status: 404)
        await #expect(throws: HAPStatusError.self) {
            try await caller.send(OutgoingCall(url: "http://a/fails", method: "GET", rejectUnauthorized: true), timeout: .seconds(5), name: "Test")
        }
    }

    @Test func credentialsAreComparedWhole() {
        let router = WebhookRouter(accessories: [:], credentials: ("hook", "s3cret"), cors: false, logger: testLogger)
        func basic(_ text: String) -> String { "Basic " + Data(text.utf8).base64EncodedString() }
        #expect(router.isAuthorized(basic("hook:s3cret")))
        #expect(!router.isAuthorized(basic("hook:s3cre")))
        #expect(!router.isAuthorized(basic("hook:s3cretX")))
        #expect(!router.isAuthorized(basic("hoo:s3cret")))
        #expect(!router.isAuthorized(basic("hooks3cret")))
        #expect(!router.isAuthorized("Bearer x"))
        #expect(!router.isAuthorized(nil))
        #expect(WebhookRouter(accessories: [:], credentials: nil, cors: false, logger: testLogger).isAuthorized(nil))
    }

    // MARK: Over the loopback interface

    static func client(_ tls: HTTPClient.TLS = .system) -> HTTPClient { HTTPClient(tls: tls) }

    @Test func theServerAnswersOverHTTP() async throws {
        let environment = TestEnvironment()
        var settings = exampleBlock
        settings["webhook_listen_host"] = "127.0.0.1"
        let host = try await environment.start(settings: settings)
        let port = try #require(await environment.plugin?.port)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/hook?accessoryId=switch1&state=true"))
        let unauthorized = try await Self.client().send(HTTPRequest(url: url))
        #expect(unauthorized.status == 401)
        var request = HTTPRequest(method: "POST", url: url, body: Data("ignored=1".utf8))
        request.setHeader("Authorization", TestEnvironment.authorization)
        let response = try await Self.client().send(request)
        #expect(response.status == 200)
        #expect(response.header("Content-Type") == "application/json")
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"success":true}"#)
        #expect(try host.accessory(named: "Switch name 1").service(.switch)?[.on]?.value == .bool(true))
        // A body larger than the server takes is refused.
        var large = HTTPRequest(method: "POST", url: url, body: Data(repeating: 0x61, count: WebhookServer.maximumBodySize + 1))
        large.setHeader("Authorization", TestEnvironment.authorization)
        #expect(try await Self.client().send(large).status == 413)
        await host.stop()
    }

    @Test func theServerAnswersOverHTTPSWithASelfSignedCertificate() async throws {
        let environment = TestEnvironment()
        let host = try await environment.start(settings: [
            "https": true, "webhook_listen_host": "127.0.0.1", "switches": [["id": "s", "name": "S"]],
        ])
        let port = try #require(await environment.plugin?.port)
        let response = try await Self.client(.any).send(HTTPRequest(url: try #require(URL(string: "https://127.0.0.1:\(port)/?accessoryId=s"))))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"success":true,"state":false}"#)
        let fingerprint = try #require(response.certificateFingerprint)
        await host.stop()

        // The certificate is kept for the next launch.
        let again = try await environment.start(settings: [
            "https": true, "webhook_listen_host": "127.0.0.1", "switches": [["id": "s", "name": "S"]],
        ])
        let next = try #require(await environment.plugin?.port)
        let second = try await Self.client(.any).send(HTTPRequest(url: try #require(URL(string: "https://127.0.0.1:\(next)/?accessoryId=s"))))
        #expect(second.certificateFingerprint == fingerprint)
        await again.stop()
    }

    @Test func aSelfSignedCertificateIsMade() throws {
        let made = try WebhookCertificate.make(now: Date())
        #expect(made.certVersion == 2)
        #expect(made.cert.hasPrefix("-----BEGIN CERTIFICATE-----"))
        #expect(made.private.contains("PRIVATE KEY"))
    }
}
