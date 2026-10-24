import Crypto
import Foundation

/// AWS credentials: long-lived keys, or temporary ones from Cognito/STS with a session token.
public struct AWSCredentials: Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

/// AWS Signature Version 4: presigned AWS IoT WebSocket URLs, and signed HTTP requests.
public enum AWSSignatureV4 {
    static let algorithm = "AWS4-HMAC-SHA256"

    /// A presigned `wss://<endpoint>/mqtt` URL for MQTT over WebSocket to AWS IoT Core.
    ///
    /// AWS IoT's own scheme: the query carries the algorithm, credential, date, expiry and signed headers
    /// (`host`), the signature covers the empty payload, and the session token is appended after the
    /// signature, unsigned. Pass it to `MQTTConfiguration.Transport.webSocket(url:)` as a closure so every
    /// connection attempt signs with the current credentials.
    public static func presignIoTURL(
        endpoint: String, region: String, credentials: AWSCredentials, date: Date = Date(), expires: Int = 86400,
        service: String = "iotdevicegateway", path: String = "/mqtt"
    ) -> URL {
        let (amzDate, dateStamp) = timestamps(date)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let parameters = [
            ("X-Amz-Algorithm", algorithm),
            ("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", "host"),
        ].sorted { $0.0 < $1.0 }
        let query = parameters.map { "\(URLEncoding.rfc3986($0.0))=\(URLEncoding.rfc3986($0.1))" }.joined(separator: "&")
        let canonicalRequest = ["GET", path, query, "host:\(endpoint)\n", "host", hexString(SHA256.hash(data: Data()))].joined(separator: "\n")
        let signature = sign(canonicalRequest, amzDate: amzDate, dateStamp: dateStamp, scope: scope, region: region, service: service, secret: credentials.secretAccessKey)
        var url = "wss://\(endpoint)\(path)?\(query)&X-Amz-Signature=\(signature)"
        if let token = credentials.sessionToken { url += "&X-Amz-Security-Token=\(URLEncoding.rfc3986(token))" }
        return URL(string: url)!
    }

    /// The headers that sign a request: `Authorization`, `X-Amz-Date`, and `X-Amz-Security-Token` with
    /// temporary credentials. Every header given is signed, with `Host` (added from the URL when missing).
    public static func signatureHeaders(
        method: String, url: URL, headers: [(name: String, value: String)] = [], body: Data = Data(), service: String, region: String,
        credentials: AWSCredentials, date: Date = Date()
    ) -> [(name: String, value: String)] {
        let (amzDate, dateStamp) = timestamps(date)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        var all = headers.filter { $0.name.lowercased() != "authorization" }
        if !all.contains(where: { $0.name.lowercased() == "host" }), let host = url.host {
            // As `HTTPClient` sends it: `:443` signed but not sent fails the signature.
            let defaultPort = url.scheme?.lowercased() == "http" ? 80 : 443
            all.append(("host", hostHeader(host: host, port: url.port ?? defaultPort, defaultPort: defaultPort)))
        }
        var added: [(name: String, value: String)] = [("X-Amz-Date", amzDate)]
        if let token = credentials.sessionToken { added.append(("X-Amz-Security-Token", token)) }
        all.removeAll { name in added.contains { $0.name.lowercased() == name.name.lowercased() } }
        all += added

        // Canonical headers: lowercase names, sorted, values trimmed with inner runs of spaces collapsed.
        var canonical: [String: String] = [:]
        for header in all {
            let name = header.name.lowercased()
            let value = header.value.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            canonical[name] = canonical[name].map { "\($0),\(value)" } ?? value
        }
        let names = canonical.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(canonical[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")

        let path = url.path(percentEncoded: true)
        let canonicalPath = path.isEmpty ? "/" : path.split(separator: "/", omittingEmptySubsequences: false).map { URLEncoding.rfc3986(String($0)) }.joined(separator: "/")
        var pairs: [(name: String, value: String)] = []
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? [] {
            let name = item.name.removingPercentEncoding ?? item.name
            let raw = item.value ?? ""
            pairs.append((URLEncoding.rfc3986(name), URLEncoding.rfc3986(raw.removingPercentEncoding ?? raw)))
        }
        pairs.sort { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
        let canonicalQuery = pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
        let canonicalRequest = [
            method.uppercased(), canonicalPath, canonicalQuery, canonicalHeaders, signedHeaders, hexString(SHA256.hash(data: body)),
        ].joined(separator: "\n")
        let signature = sign(canonicalRequest, amzDate: amzDate, dateStamp: dateStamp, scope: scope, region: region, service: service, secret: credentials.secretAccessKey)
        let authorization = "\(algorithm) Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return added + [("Authorization", authorization)]
    }

    /// Signs an `HTTPRequest` in place.
    public static func sign(_ request: inout HTTPRequest, service: String, region: String, credentials: AWSCredentials, date: Date = Date()) {
        let headers = signatureHeaders(
            method: request.method, url: request.url, headers: request.headers, body: request.body ?? Data(), service: service, region: region,
            credentials: credentials, date: date
        )
        for header in headers { request.setHeader(header.name, header.value) }
    }

    /// The signing key for a day, region and service (`kSigning`).
    static func signingKey(secret: String, dateStamp: String, region: String, service: String) -> SymmetricKey {
        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for part in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        return key
    }

    private static func sign(
        _ canonicalRequest: String, amzDate: String, dateStamp: String, scope: String, region: String, service: String, secret: String
    ) -> String {
        let stringToSign = [algorithm, amzDate, scope, hexString(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")
        let key = signingKey(secret: secret, dateStamp: dateStamp, region: region, service: service)
        return hexString(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
    }

    /// `20150830T123600Z` and `20150830`, in UTC.
    static func timestamps(_ date: Date) -> (amzDate: String, dateStamp: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let dateStamp = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        return ("\(dateStamp)T" + String(format: "%02d%02d%02dZ", c.hour!, c.minute!, c.second!), dateStamp)
    }
}
