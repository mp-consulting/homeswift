import Foundation
import HomeswiftPlugin

/// The ThinQ app's identifiers and LG's endpoints, as the Homebridge plugin has them (reversed from LG's app).
enum ThinQConstants {
    static let gatewayURL = "https://route.lgthinq.com:46030/v1/service/application/gateway-uri"
    static let svcCode = "SVC202"
    static let clientID = "LGAO221A02"
    static let oauthSecretKey = "c053c2a6ddeb7ad97cb0eed0dcb31cf8"
    static let oauthClientKey = "LGAO722A02"
    static let apiKey = "VGhpblEyLjAgU0VSVklDRQ=="
    static let apiClientID = "c713ea8e50f657534ff8b9d373dfebfc2ed70b88285c26b8ade49868c0b164d9"
    /// For the legacy (SPX) sign-in.
    static let applicationKey = "6V1V8H2BN5P9ZQGOI5DAQ92YZBDO3EK9"
    /// LG answers 403 to the account endpoints in some regions unless the client looks like its app.
    static let empUserAgent = "LG ThinQ/5.0.11861 (iPhone; iOS 17.1; Scale/3.00)"

    /// The lgemembers.com account system that replaced the EMP session flow: the user id travels encrypted
    /// with this key (RSA, PKCS#1 v1.5).
    static let accountBaseHost = "lgemembers.com"
    static let accountRedirectURI = "lgaccount.lgsmartthinq:/"
    static let accountPublicKey = """
        -----BEGIN PUBLIC KEY-----
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkb2bcfvV5Q2Ag0UI6Mj3
        oDmS0b2I9RTIRFhIVqrO47FRKQaFQpjiKkgxMcbLqK+ACTORrt6eA6srX/HKGtN9
        aJvM/8ZzqAe1tztli/yQtm6MezKExTtSAxYkawaV2s+pj7RkOes+BsJ0ahL/HC1x
        divxU4M0DN7AKdOyQM3XJnAfIimb1yhI5VeQkSBLDeAY9OTjRdAn4N6aRXaIwtck
        hQYDs7t120uhRvtRX8WVY+YiROCKTgK9PPcvaGgWublxLnSPFFb4BGYDan2Ro0DL
        b0DD1It4vqePBDWZD9MByhRJ67mQGXOJ/u3EEbctHB7TZkejjWn5sArU6K1jP0LB
        hwIDAQAB
        -----END PUBLIC KEY-----
        """

    // Timing.
    static let deviceDiscoveryDelay: Duration = .seconds(30)
    static let mqttRetryDelay: Duration = .seconds(5)
    static let mqttReconnectDelay: Duration = .seconds(60)
    /// After the quick start-up retries, MQTT keeps being tried at this pace.
    static let mqttSlowRetryDelay: Duration = .seconds(300)
    /// ThinQ2 devices are pushed over MQTT; this REST poll only reconciles, slowly, so LG does not rate-limit the
    /// account (HTTP 429 / resultCode 9012), which silently breaks control commands.
    static let thinq2PollInterval: Duration = .seconds(300)
    static let rateLimitBase: Duration = .seconds(60)
    static let rateLimitMax: Duration = .seconds(1800)
}

/// LG's device types, by the numbers the API reports.
enum DeviceType {
    static let names: [Int: String] = [
        101: "REFRIGERATOR", 102: "KIMCHI_REFRIGERATOR", 103: "WATER_PURIFIER",
        201: "WASHER", 221: "WASHER_NEW", 222: "WASH_TOWER", 223: "WASH_TOWER_2", 202: "DRYER", 203: "STYLER", 204: "DISHWASHER",
        301: "OVEN", 302: "MICROWAVE", 303: "COOKTOP", 304: "HOOD",
        401: "AC", 402: "AIR_PURIFIER", 403: "DEHUMIDIFIER", 410: "AERO_TOWER",
        501: "ROBOT_KING", 701: "TV", 801: "BOILER", 901: "SPEAKER", 902: "HOMEVU", 1001: "ARCH",
        3001: "MISSG", 3002: "SENSOR", 3102: "SOLAR_SENSOR", 3003: "IOT_LIGHTING", 3004: "IOT_MOTION_SENSOR", 3005: "IOT_SMART_PLUG",
        3006: "IOT_DUST_SENSOR", 4001: "EMS_AIR_STATION", 4003: "AIR_SENSOR", 4004: "PURICARE_AIR_DETECTOR", 6001: "V2PHONE", 9000: "HOMEROBOT",
    ]

    /// The code of a reported `deviceType` (a number or a numeric string), as `DeviceType[value]` looks it up:
    /// nil for a missing, fractional or non-numeric one.
    static func code(_ value: JSONValue?) -> Int? {
        Int(exactly: JS.number(value))
    }
}

enum PlatformType {
    static let thinq1 = "thinq1"
    static let thinq2 = "thinq2"
}
