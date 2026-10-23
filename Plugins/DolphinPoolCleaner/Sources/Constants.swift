import Foundation
import HomeswiftNetwork

/// The MyDolphin Plus cloud, with the values of the iOS app as the Homebridge plugin has them.
enum Maytronics {
    static let baseURL = URL(string: "https://apps.maytronics.com")!
    static let appKey = "346BDE92-53D1-4829-8A2E-B496014B586C"
    static let userAgent = "MyDolphin Plus/346 CFNetwork/3860.300.31 Darwin/25.2.0"

    /// The app's Cognito user pool client (no secret, so no SECRET_HASH).
    static let cognitoClientID = "4ed12eq01o6n0tl5f0sqmkq2na"
    static let cognitoRegion = "us-west-2"

    /// AWS IoT endpoints by region, from the iOS app's Configuration.plist. Production is eu-west-1 wherever
    /// the user lives; the endpoint and the signing region always come from the same entry.
    static let iotEndpoints: [String: String] = [
        "eu-west-1": "a12rqfdx55bdbv-ats.iot.eu-west-1.amazonaws.com",
        "eu-central-1": "a2tgkimxdrkpxm-ats.iot.eu-central-1.amazonaws.com",
        "us-east-2": "awqf0dif0s78s-ats.iot.us-east-2.amazonaws.com",
    ]
    static let defaultIoTRegion = "eu-west-1"

    /// `connectVia` of an M400/M600, the default when the cloud gives none.
    static let defaultDeviceType = 62
    /// AWS IoT knows a robot by the first 8 characters of its serial number.
    static let thingNameLength = 8
    /// AWS IoT credentials are renewed this long before they expire.
    static let credentialRefreshMargin: TimeInterval = 60 * 60
    static let requestTimeout: Duration = .seconds(15)
    /// The setup page's requests: Cognito sessions are short, the page gives up after 30 seconds.
    static let setupRequestTimeout: Duration = .seconds(30)
}

/// A cleaning mode: its name, its duration in minutes and the value the shadow takes.
struct CleaningMode: Sendable, Equatable {
    var name: String
    var duration: Int
    var apiMode: String

    /// Every mode a robot may accept, by the key config.json uses.
    static let all: [String: CleaningMode] = [
        "all": .init(name: "All Surfaces", duration: 120, apiMode: "all"),
        "short": .init(name: "Fast Mode", duration: 60, apiMode: "short"),
        "floor": .init(name: "Floor Only", duration: 120, apiMode: "floor"),
        "wall": .init(name: "Walls Only", duration: 120, apiMode: "wall"),
        "water": .init(name: "Waterline", duration: 120, apiMode: "water"),
        "ultra": .init(name: "Ultra Clean", duration: 120, apiMode: "ultra"),
        "cove": .init(name: "Cove", duration: 120, apiMode: "cove"),
        "spot": .init(name: "Spot Clean", duration: 120, apiMode: "spot"),
        "tictac": .init(name: "TicTac", duration: 600, apiMode: "tictac"),
        "pickup": .init(name: "Pickup", duration: 5, apiMode: "pickup"),
        "custom": .init(name: "Custom", duration: 120, apiMode: "custom"),
        "stairs": .init(name: "Stairs", duration: 120, apiMode: "stairs"),
    ]
}

/// The robot's motor unit states (legacy `mu_state`).
enum RobotStates {
    static let off = 0x00
    static let initializing = 0x01
    static let scanning = 0x02
    static let cleaning = 0x03
    static let fault = 0x04
    static let programming = 0x05
    static let endOfCycle = 0x06
    static let pickup = 0x07
    static let remoteControl = 0x08
    static let cleaningPause = 0x0B
}

/// The power supply's states (legacy `sm_state`, and `systemState.pwsState` mapped to numbers).
enum PWSStates {
    static let off = 0x00
    static let holdDelay = 0x01
    static let holdWeekly = 0x02
    static let programming = 0x03
    static let error = 0x04
    static let cleaning = 0x05
    static let idle = 0x06
}

/// How a throttled shadow operation is retried.
struct RetryPolicy: Sendable, Equatable {
    var attempts: Int
    var baseDelay: Duration
}

/// Every delay the plugin waits, in one place so tests can shrink them.
struct DolphinTiming: Sendable {
    /// How long a shadow request waits for its answer.
    var shadowTimeout: Duration = .seconds(10)
    /// The MyDolphin AWS account is shared by every user, so shadow operations are throttled (429
    /// TOO_MANY_REQUESTS) at any time: requests are spaced out, retried with exponential backoff, and only
    /// reported once the retries are exhausted.
    var minimumRequestInterval: Duration = .seconds(1)
    var pollRetry = RetryPolicy(attempts: 3, baseDelay: .seconds(2))
    /// Commands are awaited by HomeKit, which gives up on a slow write and shows "No Response", so they retry
    /// fewer times and back off faster than polling.
    var commandRetry = RetryPolicy(attempts: 2, baseDelay: .milliseconds(750))
    var maximumRetryDelay: Duration = .seconds(15)
    var retryJitter: Duration = .milliseconds(500)
    /// At most one throttling warning this often.
    var throttleLogInterval: Duration = .seconds(600)
    var mqttConnectTimeout: Duration = .seconds(30)
    /// The shadow is read again this long after a command, once the robot has reacted.
    var stateRefreshDelay: Duration = .seconds(3)
    /// After a command, switch updates are ignored this long: the robot needs the time to update its shadow
    /// before the messages it pushes can be trusted again.
    var commandGracePeriod: Duration = .seconds(15)
    /// Discovery retries when the cloud is unreachable at startup: 30 s, doubled up to 10 min.
    var discoveryRetryBase: Duration = .seconds(30)
    var discoveryRetryMaximum: Duration = .seconds(600)

    static let standard = DolphinTiming()

    /// Exponential backoff with jitter, so retries from several clients spread out.
    /// `attempt` counts from 1.
    func backoff(attempt: Int, policy: RetryPolicy) -> Duration {
        Backoff(initial: policy.baseDelay, maximum: maximumRetryDelay, jitter: .additive(retryJitter)).delay(attempt: attempt - 1)
    }

    /// Discovery's delay after `failures` failed attempts.
    func discoveryRetryDelay(after failures: Int) -> Duration {
        Backoff(initial: discoveryRetryBase, maximum: discoveryRetryMaximum).delay(attempt: failures)
    }
}

/// What went wrong, with the codes of the Homebridge plugin's errors.
enum DolphinError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidCredentials(String)
    case tokenExpired(String)
    case cognitoFailed(String)
    case myDolphinFailed(String)
    case awsCredentialsFailed(String)
    case mqttConnectionFailed(String)
    case notConnected(String)
    case shadowTimeout
    case shadowRejected(String)
    case shadowRateLimited(String)
    case requestFailed(String)
    case invalidResponse(String)

    var code: String {
        switch self {
        case .invalidCredentials: "AUTH_INVALID_CREDENTIALS"
        case .tokenExpired: "AUTH_TOKEN_EXPIRED"
        case .cognitoFailed: "AUTH_COGNITO_FAILED"
        case .myDolphinFailed: "AUTH_MYDOLPHIN_FAILED"
        case .awsCredentialsFailed: "AUTH_AWS_CREDENTIALS_FAILED"
        case .mqttConnectionFailed: "MQTT_CONNECTION_FAILED"
        case .notConnected: "MQTT_NOT_CONNECTED"
        case .shadowTimeout: "MQTT_SHADOW_TIMEOUT"
        case .shadowRejected: "MQTT_SHADOW_REJECTED"
        case .shadowRateLimited: "MQTT_SHADOW_RATE_LIMITED"
        case .requestFailed: "API_REQUEST_FAILED"
        case .invalidResponse: "API_INVALID_RESPONSE"
        }
    }

    var description: String {
        switch self {
        case .invalidCredentials(let message), .tokenExpired(let message), .cognitoFailed(let message), .myDolphinFailed(let message),
            .awsCredentialsFailed(let message), .mqttConnectionFailed(let message), .notConnected(let message), .shadowRejected(let message),
            .shadowRateLimited(let message), .requestFailed(let message), .invalidResponse(let message):
            message
        case .shadowTimeout: "Shadow operation timeout"
        }
    }

    /// Bad credentials do not fix themselves: discovery does not retry after these.
    var isPermanent: Bool {
        switch self {
        case .invalidCredentials, .tokenExpired: true
        default: false
        }
    }

    /// Shadow failures that resolve on their own and warrant no error in the log.
    var isTransient: Bool {
        switch self {
        case .shadowRateLimited, .notConnected: true
        default: false
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
