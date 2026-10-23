import Foundation
import Testing

@testable import HomeswiftNetwork

@Suite("AWS Signature V4")
struct AWSSignatureTests {
    /// The temporary credentials of the vectors below; the token has characters that need encoding.
    let credentials = AWSCredentials(
        accessKeyID: "ASIAEXAMPLEKEY123456", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        sessionToken: "IQoJb3JpZ2luX2VjE+/token=with*special(chars)!"
    )
    /// 2026-10-22T08:05:09Z
    let date = Date(timeIntervalSince1970: 1_792_656_309)

    /// AWS's test suite, `get-vanilla`.
    @Test func awsTestSuiteGetVanilla() {
        let headers = AWSSignatureV4.signatureHeaders(
            method: "GET", url: URL(string: "https://example.amazonaws.com/")!, service: "service", region: "us-east-1",
            credentials: AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            date: Date(timeIntervalSince1970: 1_440_938_160)
        )
        #expect(headers.first { $0.name == "X-Amz-Date" }?.value == "20150830T123600Z")
        #expect(
            headers.first { $0.name == "Authorization" }?.value
                == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
        )
    }

    /// The URL homebridge-dolphin-pool-cleaner's `getSignedWebSocketUrl` builds for the same inputs (run in Node).
    @Test func presignedIoTURLMatchesTheDolphinPlugin() {
        let url = AWSSignatureV4.presignIoTURL(
            endpoint: "a1b2c3d4e5f6g7-ats.iot.eu-west-1.amazonaws.com", region: "eu-west-1", credentials: credentials, date: date
        )
        #expect(
            url.absoluteString
                == "wss://a1b2c3d4e5f6g7-ats.iot.eu-west-1.amazonaws.com/mqtt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=ASIAEXAMPLEKEY123456%2F20261022%2Feu-west-1%2Fiotdevicegateway%2Faws4_request&X-Amz-Date=20261022T080509Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=01d3c57072d9246191bfc28d91e98e2a53c9751fdfb8b44ebb49edbde5426517&X-Amz-Security-Token=IQoJb3JpZ2luX2VjE%2B%2Ftoken%3Dwith%2Aspecial%28chars%29%21"
        )
    }

    /// The same request signed by the AWS SDK's `@smithy/signature-v4` (run in Node).
    @Test func signedRequestMatchesTheAWSSDK() {
        var request = HTTPRequest(
            method: "POST", url: URL(string: "https://api.example.com/prod/devices/shadow?b=2&a=x%20y")!,
            headers: [
                ("Content-Type", "application/json"),
                ("x-amz-content-sha256", "9d4d1b910994ac1ec4898824e1d69033ad15e2ea1ddcba20224c3368c7d8768e"),
            ],
            body: Data(#"{"state":{"desired":{"on":true}}}"#.utf8)
        )
        AWSSignatureV4.sign(&request, service: "execute-api", region: "eu-west-1", credentials: credentials, date: date)
        #expect(request.header("X-Amz-Date") == "20261022T080509Z")
        #expect(request.header("X-Amz-Security-Token") == credentials.sessionToken)
        #expect(
            request.header("Authorization")
                == "AWS4-HMAC-SHA256 Credential=ASIAEXAMPLEKEY123456/20261022/eu-west-1/execute-api/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature=b02dcdcb70c0d9caad79aa021b673e9c3ee49331baedc4d6bf04ca9828cb63f7"
        )
    }

    @Test func uriEncodingIsRFC3986() {
        #expect(URLEncoding.rfc3986("a b/c~d_e.f-g!'()*+=") == "a%20b%2Fc~d_e.f-g%21%27%28%29%2A%2B%3D")
    }
}
