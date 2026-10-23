import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers
import Testing

@testable import HomeswiftDolphinPoolCleaner

/// The sign-in and the cloud against fake Cognito, MyDolphin and AWS IoT endpoints, as the Homebridge
/// plugin's API tests run them.
@Suite(.timeLimit(.minutes(1)))
struct CloudTests {
    let server = FakeCloudServer()
    let broker = FakeBroker()
    let log = LogRecorder()

    func cloud(refreshToken: String? = nil, email: String? = "owner@example.com", password: String? = "secret", region: String? = "eu-west-1") -> MaytronicsCloud {
        MaytronicsCloud(
            settings: AccountSettings(email: email, password: password, refreshToken: refreshToken, iotRegion: region), transport: server, mqtt: broker.factory,
            timing: .fast, logger: log.logger)
    }

    // MARK: Sign-in

    @Test func signsInFetchesCredentialsAndConnects() async throws {
        let cloud = cloud()
        let result = try await cloud.login()
        #expect(result == LoginResult(serialNumber: "E3086OFG2M", robotName: "Pool Bot", deviceType: 62))

        let cognito = try #require(server.requests(to: "InitiateAuth").first)
        #expect(cognito.url.absoluteString == "https://cognito-idp.us-west-2.amazonaws.com/")
        #expect(cognito.header("X-Amz-Target") == "AWSCognitoIdentityProviderService.InitiateAuth")
        #expect(cognito.header("Content-Type") == "application/x-amz-json-1.1")
        let body = try #require(server.json(of: cognito))
        #expect(body["AuthFlow"] == "USER_PASSWORD_AUTH")
        #expect(body["ClientId"] == "4ed12eq01o6n0tl5f0sqmkq2na")
        #expect(body["AuthParameters"] == ["USERNAME": "owner@example.com", "PASSWORD": "secret"])

        let authenticate = try #require(server.requests(to: "/mobapi/user/authenticate-user/").first)
        #expect(authenticate.method == "POST")
        #expect(authenticate.header("Authorization") == "Bearer id-token")
        #expect(authenticate.header("AppKey") == Maytronics.appKey)
        #expect(authenticate.header("Content-Type") == "application/x-www-form-urlencoded")

        let token = try #require(server.requests(to: "/mt-sso/aws/getToken/").first)
        let query = URLComponents(url: token.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "sernum" }?.value == "E3086OFG2M")
        #expect(query.first { $0.name == "device_type" }?.value == "62")
        #expect(token.header("Authorization") == "Bearer id-token")

        #expect(broker.connectCount == 1)
        #expect(await cloud.authentication.awsCredentials == IoTCredentials(accessKeyID: "AKIA", secretAccessKey: "secret", sessionToken: "session", expiration: Date(timeIntervalSince1970: 4_070_908_800)))
        let url = try await broker.presignedURL()
        #expect(url.host == Maytronics.iotEndpoints["eu-west-1"])
        #expect(url.absoluteString.contains("X-Amz-Credential=AKIA%2F"))
        #expect(url.absoluteString.contains("X-Amz-Security-Token=session"))
        #expect(log.contains(.info, "MQTT connected for robot E3086OFG2M"))
        await cloud.disconnect()
    }

    @Test func refreshTokenComesFirst() async throws {
        _ = try await cloud(refreshToken: "refresh-token").login()
        let body = try #require(server.requests(to: "InitiateAuth").first.flatMap(server.json(of:)))
        #expect(body["AuthFlow"] == "REFRESH_TOKEN_AUTH")
        #expect(body["AuthParameters"] == ["REFRESH_TOKEN": "refresh-token"])
    }

    @Test func badCredentials() async {
        server.cognitoError("InitiateAuth", type: "NotAuthorizedException", message: "Incorrect username or password.")
        await #expect(throws: DolphinError.invalidCredentials("Invalid email or password")) { try await cloud().login() }
    }

    @Test func expiredRefreshToken() async {
        server.cognitoError("InitiateAuth", type: "com.amazonaws.cognito#NotAuthorizedException", message: "Refresh Token has expired")
        await #expect(throws: DolphinError.tokenExpired("Refresh token expired. Please re-authenticate through the plugin settings.")) {
            try await cloud(refreshToken: "old-token").login()
        }
    }

    @Test func unknownUser() async {
        server.cognitoError("InitiateAuth", type: "UserNotFoundException", message: "User does not exist.")
        await #expect(throws: DolphinError.invalidCredentials("User not found. Please check your email address.")) { try await cloud().login() }
    }

    @Test func noCredentials() async {
        await #expect(throws: DolphinError.self) { try await cloud(email: nil, password: nil).login() }
        #expect(server.requests.isEmpty)
    }

    @Test func backendRefusesTheUser() async {
        server.set("/mobapi/user/authenticate-user/", .init(body: ["Status": "0", "Alert": "Account locked"]))
        await #expect(throws: DolphinError.myDolphinFailed("Authentication failed: Account locked")) { try await cloud().login() }
    }

    @Test func backendHTTPError() async {
        server.set("/mt-sso/aws/getToken/", .init(status: 503, body: [:]))
        await #expect(throws: DolphinError.awsCredentialsFailed("Failed to get AWS IoT credentials")) { try await cloud().login() }
    }

    @Test func cognitoOutage() async {
        server.set("InitiateAuth", .init(status: 503, body: [:]))
        await #expect(throws: DolphinError.cognitoFailed("Failed to authenticate with AWS Cognito")) { try await cloud().login() }
    }

    @Test func unknownRegionFallsBack() async throws {
        _ = try await cloud(region: "mars-north-1").login()
        let url = try await broker.presignedURL()
        #expect(url.host == Maytronics.iotEndpoints["eu-west-1"])
        #expect(url.absoluteString.contains("%2Feu-west-1%2Fiotdevicegateway%2Faws4_request"))
        #expect(log.contains(.warning, "Unknown IoT region \"mars-north-1\""))
    }

    // MARK: Concurrency

    @Test func concurrentRequestsShareOneSignInAndConnection() async throws {
        let cloud = cloud()
        async let first = cloud.thingShadow(serialNumber: "E3086OFG2M")
        async let second = cloud.thingShadow(serialNumber: "E3086OFG2M")
        let (a, b) = await (first, second)
        #expect(a?["version"] == 3)
        #expect(b?["version"] == 3)
        #expect(server.requests(to: "InitiateAuth").count == 1)
        #expect(broker.connectCount == 1)
        await cloud.disconnect()
    }

    @Test func reconnectsWithoutSigningInAgain() async throws {
        let cloud = cloud()
        _ = try await cloud.login()
        broker.connections[0].giveUp()
        // The connection gave up; the next request opens a new one with the same credentials.
        try await Task.sleep(for: .milliseconds(20))
        #expect(await cloud.thingShadow(serialNumber: "E3086OFG2M") != nil)
        #expect(server.requests(to: "InitiateAuth").count == 1)
        #expect(broker.connectCount == 2)
        await cloud.disconnect()
    }

    @Test func expiringCredentialsAreRenewed() async throws {
        server.set("/mt-sso/aws/getToken/", .init(body: [
            "Status": "1", "Data": ["AccessKeyId": "AKIA", "SecretAccessKey": "secret", "Token": "session", "TokenExpiration": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(600)))],
        ]))
        let cloud = cloud()
        _ = try await cloud.login()
        _ = await cloud.thingShadow(serialNumber: "E3086OFG2M")
        // Ten minutes left is within the hour's margin: the sign-in runs again.
        #expect(server.requests(to: "InitiateAuth").count == 2)
        await cloud.disconnect()
    }

    @Test func pushedShadowsReachObservers() async throws {
        let cloud = cloud()
        let received = LockedValues<JSONValue>()
        _ = await cloud.addShadowObserver { received.append($0) }
        _ = try await cloud.login()
        broker.connections[0].deliver(topic: "$aws/things/E3086OFG/shadow/update/accepted", payload: ["version": 9, "state": ["reported": ["systemState": ["pwsState": "cleaning"]]]])
        #expect(await eventually { received.values.count == 1 })
        #expect(await cloud.lastShadowReceivedAt() != nil)
        await cloud.disconnect()
    }

    // MARK: Robots

    @Test func describesTheRobot() async throws {
        let cloud = cloud()
        _ = try await cloud.login()
        #expect(await cloud.robots() == [RobotInfo(serialNumber: "E3086OFG2M", name: "Pool Bot", model: "Dolphin M400", deviceType: 62, features: ["Temperature"])])
        let details = try #require(server.requests(to: "/mobapi/serial-numbers/getRobotDetailsByRobotSN/").first)
        #expect(details.body.map { String(decoding: $0, as: UTF8.self) } == "SERNUM=E3086OFG2M")
        await cloud.disconnect()
    }

    @Test func robotStaysListedWhenItsDetailsFail() async throws {
        let cloud = cloud()
        _ = try await cloud.login()
        server.set("/mobapi/serial-numbers/getRobotDetailsByRobotSN/", .init(status: 500, body: [:]))
        // An empty list would make the plugin remove the accessory.
        let robots = await cloud.robots()
        #expect(robots.map(\.serialNumber) == ["E3086OFG2M"])
        #expect(robots.first?.name == "Pool Bot")
        #expect(robots.first?.deviceType == 62)
        await cloud.disconnect()
    }

    @Test func noRobotsBeforeSigningIn() async {
        #expect(await cloud().robots().isEmpty)
    }

    // MARK: Commands

    @Test func startAndStopAreShadowUpdates() async throws {
        let cloud = cloud()
        _ = try await cloud.login()
        #expect(await cloud.startRobot(serialNumber: "E3086OFG2M"))
        #expect(await cloud.stopRobot(serialNumber: "E3086OFG2M"))
        #expect(await cloud.setCleaningMode(serialNumber: "E3086OFG2M", mode: "floor"))
        #expect(broker.published.map(\.topic) == Array(repeating: "$aws/things/E3086OFG/shadow/update", count: 3))
        #expect(broker.published.map(\.desired) == [["systemState": ["pwsState": "on"]], ["systemState": ["pwsState": "off"]], ["cleaningMode": ["mode": "floor"]]])
        await cloud.disconnect()
    }

    @Test func unreachableCloudGivesFalse() async {
        server.set("InitiateAuth", .init(status: 502, body: [:]))
        #expect(await cloud().setCleaningMode(serialNumber: "E3086OFG2M", mode: "floor") == false)
        #expect(log.contains(.error, "Failed: Set cleaning mode to floor"))
    }

    // MARK: Encoding

    @Test func formEncoding() {
        #expect(URLEncoding.form("a b&c=d/é*-._~") == "a+b%26c%3Dd%2F%C3%A9*-._%7E")
        #expect(CognitoClient.errorName("NotAuthorizedException:http://internal.amazon.com/coral") == "NotAuthorizedException")
        #expect(AuthenticationManager.deviceType("60") == 60)
        #expect(AuthenticationManager.deviceType("x") == 62)
        #expect(AuthenticationManager.deviceType(nil) == 62)
        #expect(AuthenticationManager.parseDate("2099-01-01T00:00:00.000Z") == Date(timeIntervalSince1970: 4_070_908_800))
    }
}

/// Values appended from any task.
final class LockedValues<Value: Sendable>: Sendable {
    private let stored = NIOLockedValueBox<[Value]>([])
    var values: [Value] { stored.withLockedValue { $0 } }
    func append(_ value: Value) { stored.withLockedValue { $0.append(value) } }
}
