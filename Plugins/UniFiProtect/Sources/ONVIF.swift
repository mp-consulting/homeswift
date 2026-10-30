import Crypto
import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The ONVIF discovery of the settings page (ui/onvif.js of the Homebridge plugin): given a third-party
/// camera's address and credentials, its media profiles with their RTSP and snapshot URLs, to fill a camera
/// override. GetCapabilities, GetProfiles, GetStreamUri and GetSnapshotUri over SOAP with a WS-Security
/// password digest; credentials are only ever added to URLs on the host the user entered.
enum ONVIF {
    static let defaultPorts = [80, 8000, 8080, 2020, 8899]
    static let defaultServicePath = "/onvif/device_service"
    static let soapTimeout: Duration = .seconds(5)
    static let soapMaxBytes = 1024 * 1024

    struct Profile: Sendable, Equatable {
        var token: String
        var name: String?
        var encoding: String?
        var width: Int?
        var height: Int?
        var rtspUrl: String?
        var snapshotUrl: String?
        var credentialsWithheld = false

        var json: JSONValue {
            var object: [String: JSONValue] = [
                "token": .string(token), "name": name.map(JSONValue.string) ?? .null, "encoding": encoding.map(JSONValue.string) ?? .null,
                "rtspUrl": rtspUrl.map(JSONValue.string) ?? .null, "snapshotUrl": snapshotUrl.map(JSONValue.string) ?? .null,
                "credentialsWithheld": .bool(credentialsWithheld),
            ]
            if let width, let height { object["resolution"] = ["width": .number(Double(width)), "height": .number(Double(height))] } else { object["resolution"] = .null }
            return .object(object)
        }
    }

    struct Result: Sendable {
        var profiles: [Profile]
        var warnings: [String]
        var attempts: [(port: Int, error: String)]
        var port: Int
        var servicePath: String
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: SOAP

    static func escapeXML(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "&": result += "&amp;"
            case "'": result += "&apos;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    /// The WS-Security UsernameToken: Base64(SHA1(nonce + created + password)).
    static func securityHeader(username: String, password: String, nonce: [UInt8] = Array(Secrets.randomBytes(16)), created: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let createdText = formatter.string(from: created)
        let digest = Data(Insecure.SHA1.hash(data: Data(nonce) + Data(createdText.utf8) + Data(password.utf8))).base64EncodedString()
        return "<wsse:Security xmlns:wsse=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd\""
            + " xmlns:wsu=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd\">"
            + "<wsse:UsernameToken><wsse:Username>\(escapeXML(username))</wsse:Username>"
            + "<wsse:Password Type=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest\">\(digest)</wsse:Password>"
            + "<wsse:Nonce EncodingType=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary\">\(Data(nonce).base64EncodedString())</wsse:Nonce>"
            + "<wsu:Created>\(createdText)</wsu:Created></wsse:UsernameToken></wsse:Security>"
    }

    static func envelope(_ body: String, username: String, password: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"><s:Header>"
            + securityHeader(username: username, password: password) + "</s:Header><s:Body>" + body + "</s:Body></s:Envelope>"
    }

    /// The XML without namespace prefixes on element names, as the regexes below expect.
    static func stripNamespaces(_ xml: String) -> String {
        xml.replacingOccurrences(of: "<(/?)[a-zA-Z0-9]+:", with: "<$1", options: .regularExpression)
    }

    /// The text of the first `<tag>…</tag>`, its entities decoded (a stream URI's query has `&amp;`).
    static func extractTag(_ xml: String, _ tag: String) -> String? {
        guard let match = xml.range(of: "<\(tag)(?:\\s[^>]*)?>([^<]+)</\(tag)>", options: .regularExpression) else { return nil }
        let element = String(xml[match])
        guard let open = element.firstIndex(of: ">"), let close = element.range(of: "</\(tag)>", options: .backwards) else { return nil }
        return unescapeXML(String(element[element.index(after: open)..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The text of XML character data: the five predefined entities and numeric references decoded.
    static func unescapeXML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            rest = rest[ampersand...]
            guard let semicolon = rest.prefix(12).firstIndex(of: ";") else { break }
            let name = rest[rest.index(after: rest.startIndex)..<semicolon]
            let decoded: String? = switch name {
            case "amp": "&"
            case "lt": "<"
            case "gt": ">"
            case "quot": "\""
            case "apos": "'"
            default:
                if name.hasPrefix("#x") || name.hasPrefix("#X") { UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) } }
                else if name.hasPrefix("#") { UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) } }
                else { nil }
            }
            guard let decoded else {
                result += "&"
                rest = rest.dropFirst()
                continue
            }
            result += decoded
            rest = rest[rest.index(after: semicolon)...]
        }
        return result + rest
    }

    /// The inner XML of each `<tag …>…</tag>`, with its attributes.
    static func blocks(_ xml: String, _ tag: String) -> [(attributes: String, inner: String)] {
        guard let regex = try? NSRegularExpression(pattern: "<\(tag)\\b([^>]*)>([\\s\\S]*?)</\(tag)>") else { return [] }
        let text = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: text.length)).map {
            (text.substring(with: $0.range(at: 1)), text.substring(with: $0.range(at: 2)))
        }
    }

    /// A SOAP request. With `connectTo`, the connection goes to that vetted address and the URL's host is
    /// sent as `Host`, so the name is not resolved a second time.
    static func post(_ url: String, action: String, body: String, connectTo address: String? = nil, transport: any ProtectHTTPTransport) async throws -> String {
        guard var components = URLComponents(string: url), components.url != nil else { throw Failure(description: "Invalid ONVIF URL: \(url)") }
        let hostHeader = (components.host.map { AddressValidation.ipv6Bytes($0) != nil ? "[\($0)]" : $0 } ?? "") + (components.port.map { ":\($0)" } ?? "")
        if let address { components.host = AddressValidation.ipv6Bytes(address) != nil ? "[\(address)]" : address }
        guard let target = components.url else { throw Failure(description: "Invalid ONVIF URL: \(url)") }
        let payload = Data(body.utf8)
        var request = HTTPRequest(method: "POST", url: target, body: payload, timeout: soapTimeout)
        request.setHeader("Content-Type", "application/soap+xml; charset=utf-8; action=\"\(action)\"")
        if address != nil { request.setHeader("Host", hostHeader) }
        let response: HTTPResponse
        do {
            response = try await transport.send(request, tls: .any)
        } catch HTTPClientError.timeout {
            throw Failure(description: "ONVIF request timed out")
        } catch HTTPClientError.responseTooLarge {
            throw Failure(description: "ONVIF response exceeded \(soapMaxBytes / (1024 * 1024)) MB and was aborted.")
        } catch let error as HTTPClientError {
            if case .cannotConnect(_, _, let code, let reason) = error, code == ECONNREFUSED { throw Failure(description: "connect ECONNREFUSED (\(reason))") }
            throw Failure(description: "\(error)")
        }
        let text = String(decoding: response.body.prefix(soapMaxBytes), as: UTF8.self)
        guard response.isSuccess else {
            let stripped = stripNamespaces(text)
            let detail = text.isEmpty ? "" : ": " + (extractTag(stripped, "Reason") ?? extractTag(stripped, "Text") ?? logExcerpt(text) ?? "")
            throw Failure(description: "HTTP \(response.status)\(detail)")
        }
        return text
    }

    // MARK: URLs and hosts

    /// A host for comparison: lower case, no IPv6 brackets.
    static func normalizeHost(_ host: String?) -> String? {
        let trimmed = (host ?? "").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !trimmed.isEmpty else { return nil }
        return AddressValidation.canonicalHostname(AddressValidation.ipv6Bytes(trimmed) != nil ? "[\(trimmed)]" : trimmed)
    }

    /// Whether a URL the camera returned points at the host the user entered (ports may differ).
    static func urlMatchesHost(_ uri: String, host: String) -> Bool {
        guard let expected = normalizeHost(host), let components = URLComponents(string: uri), let actual = normalizeHost(components.host) else { return false }
        return expected == actual
    }

    /// Adds the credentials to a URL on the user's host; strips any from a URL elsewhere.
    static func injectCredentials(_ uri: String?, username: String, password: String, host: String) -> (url: String?, credentialsWithheld: Bool) {
        guard let uri, !uri.isEmpty, var components = URLComponents(string: uri), components.scheme != nil else { return (uri, false) }
        guard urlMatchesHost(uri, host: host) else {
            components.user = nil
            components.password = nil
            return (components.string ?? uri, !username.isEmpty)
        }
        if !username.isEmpty {
            var allowed = CharacterSet.urlUserAllowed
            allowed.remove(charactersIn: ":@/?#[]")
            components.percentEncodedUser = username.addingPercentEncoding(withAllowedCharacters: allowed)
            components.percentEncodedPassword = password.addingPercentEncoding(withAllowedCharacters: allowed)
        }
        return (components.string ?? uri, false)
    }

    /// The media service to talk to: as advertised on the user's host, else its path on the user's host and
    /// the port that answered (a NAT'd camera, or one trying to redirect us).
    static func resolveMediaServiceURL(_ xAddr: String, host: String, port: Int) -> (url: String, rewritten: Bool) {
        if urlMatchesHost(xAddr, host: host) { return (xAddr, false) }
        var path = "/onvif/media_service"
        if let components = URLComponents(string: xAddr), components.scheme != nil {
            path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        }
        let normalized = normalizeHost(host) ?? host
        let hostPart = AddressValidation.ipv6Bytes(normalized) != nil ? "[\(normalized)]" : host
        return ("http://\(hostPart):\(port)\(path)", true)
    }

    // MARK: Discovery

    /// The camera's profiles. Its address goes through `AddressValidation` first: the page cannot make the
    /// bridge POST to loopback or link-local addresses, and the vetted address is the one connected to.
    static func discover(host: String?, port: Int?, servicePath: String?, username: String?, password: String, transport: any ProtectHTTPTransport = NetworkHTTPTransport(),
                         resolve: @Sendable (String) async throws -> [String] = AddressValidation.systemResolve) async throws -> Result {
        guard let host = host?.trimmingCharacters(in: .whitespaces), !host.isEmpty, let username = username?.trimmingCharacters(in: .whitespaces), !username.isEmpty else {
            throw Failure(description: "host and username are required.")
        }
        let vetted: AddressValidation.Vetted
        do {
            vetted = try await AddressValidation.resolveAllowed(host, resolve: resolve)
        } catch {
            throw Failure(description: "\(error)")
        }
        var path = servicePath?.trimmingCharacters(in: .whitespaces).nonEmpty ?? defaultServicePath
        if !path.hasPrefix("/") { path = "/" + path }
        let ports = port.map { first in [first] + defaultPorts.filter { $0 != first } } ?? defaultPorts
        var attempts: [(port: Int, error: String)] = []
        for candidate in ports {
            do {
                let (profiles, warnings) = try await discover(host: host, address: vetted.address, port: candidate, servicePath: path, username: username, password: password,
                                                              transport: transport)
                return Result(profiles: profiles, warnings: warnings, attempts: attempts, port: candidate, servicePath: path)
            } catch {
                let message = "\(error)"
                attempts.append((candidate, message))
                if message.range(of: "sender not authorized|notauthorized|unauthorized|wsse|password", options: [.regularExpression, .caseInsensitive]) != nil {
                    throw error
                }
            }
        }
        let summary = attempts.map { "port \($0.port): \($0.error)" }.joined(separator: "; ")
        throw Failure(description: "No reachable ONVIF service on \(host)\(path) (\(summary)).")
    }

    private static func discover(host: String, address: String, port: Int, servicePath: String, username: String, password: String,
                                 transport: any ProtectHTTPTransport) async throws -> ([Profile], [String]) {
        let hostPart = AddressValidation.ipv6Bytes(host) != nil ? "[\(host)]" : host
        let deviceService = "http://\(hostPart):\(port)\(servicePath)"
        var warnings: [String] = []
        let capabilities = try await post(deviceService, action: "http://www.onvif.org/ver10/device/wsdl/GetCapabilities",
            body: envelope("<tds:GetCapabilities xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\"><tds:Category>Media</tds:Category></tds:GetCapabilities>",
                           username: username, password: password), connectTo: address, transport: transport)
        guard let media = blocks(stripNamespaces(capabilities), "Media").first else { throw Failure(description: "Camera did not return a Media service capability.") }
        guard let xAddr = extractTag(media.inner, "XAddr") else { throw Failure(description: "Camera did not return a Media service XAddr.") }
        let mediaService = resolveMediaServiceURL(xAddr, host: host, port: port)
        if mediaService.rewritten { warnings.append("The camera advertised its media service on a different host. Using \(host) instead.") }
        let profilesXML = try await post(mediaService.url, action: "http://www.onvif.org/ver10/media/wsdl/GetProfiles",
            body: envelope("<trt:GetProfiles xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\"/>", username: username, password: password), connectTo: address, transport: transport)
        var profiles: [Profile] = []
        for block in blocks(stripNamespaces(profilesXML), "Profiles") {
            guard let tokenRange = block.attributes.range(of: "\\btoken=\"([^\"]+)\"", options: .regularExpression) else { continue }
            let token = block.attributes[tokenRange].dropFirst("token=\"".count).dropLast()
            let encoder = blocks(block.inner, "VideoEncoderConfiguration").first?.inner ?? ""
            let resolution = blocks(encoder, "Resolution").first?.inner ?? ""
            profiles.append(Profile(token: String(token), name: extractTag(block.inner, "Name"), encoding: extractTag(encoder, "Encoding"),
                                    width: extractTag(resolution, "Width").flatMap(Int.init), height: extractTag(resolution, "Height").flatMap(Int.init)))
        }
        guard !profiles.isEmpty else { throw Failure(description: "Camera returned no media profiles.") }
        for index in profiles.indices {
            let token = escapeXML(profiles[index].token)
            let rtsp = try? await post(mediaService.url, action: "http://www.onvif.org/ver10/media/wsdl/GetStreamUri", body: envelope(
                "<trt:GetStreamUri xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\"><trt:StreamSetup><tt:Stream xmlns:tt=\"http://www.onvif.org/ver10/schema\">RTP-Unicast</tt:Stream>"
                    + "<tt:Transport xmlns:tt=\"http://www.onvif.org/ver10/schema\"><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup>"
                    + "<trt:ProfileToken>\(token)</trt:ProfileToken></trt:GetStreamUri>", username: username, password: password), connectTo: address, transport: transport)
            let snapshot = try? await post(mediaService.url, action: "http://www.onvif.org/ver10/media/wsdl/GetSnapshotUri", body: envelope(
                "<trt:GetSnapshotUri xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\"><trt:ProfileToken>\(token)</trt:ProfileToken></trt:GetSnapshotUri>",
                username: username, password: password), connectTo: address, transport: transport)
            let rtspURL = injectCredentials(rtsp.flatMap { extractTag(stripNamespaces($0), "Uri") }, username: username, password: password, host: host)
            let snapshotURL = injectCredentials(snapshot.flatMap { extractTag(stripNamespaces($0), "Uri") }, username: username, password: password, host: host)
            profiles[index].rtspUrl = rtspURL.url
            profiles[index].snapshotUrl = snapshotURL.url
            profiles[index].credentialsWithheld = rtspURL.credentialsWithheld || snapshotURL.credentialsWithheld
        }
        if profiles.contains(where: \.credentialsWithheld) {
            warnings.append("The camera returned stream or snapshot URLs on a different host than \(host). Credentials were not added to those URLs.")
        }
        return (profiles, warnings)
    }
}
