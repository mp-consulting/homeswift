import Foundation
import HomeswiftAI
import HomeswiftNetwork
import NIOSSL
import Testing

@testable import HomeswiftUI

@Suite(.timeLimit(.minutes(1)))
struct HTTPSTests {
    @Test func readsTheHTTPSSettings() throws {
        let configuration = try UIConfiguration(block: ["https": true, "certificate": "~/cert.pem", "privateKey": "~/key.pem"])
        #expect(configuration.https)
        #expect(configuration.scheme == "https")
        #expect(configuration.certificate == "~/cert.pem")
        #expect(throws: UIConfigurationError.self) { try UIConfiguration(block: ["https": true, "certificate": "~/cert.pem"]) }
        #expect(throws: UIConfigurationError.self) { try UIConfiguration(block: ["https": "yes"]) }
        #expect(try UIConfiguration(block: [:]).scheme == "http")
    }

    /// The self-signed certificate parses, names the machine and its addresses, and is a CA for serving.
    @Test func makesACertificateBrowsersAccept() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-tls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = UIConfiguration()
        configuration.https = true
        let made = try UICertificate.load(configuration: configuration, directory: directory, names: ["bridge.local", "localhost"], logger: testLogger)
        let parsed = try NIOSSLCertificate(bytes: Array(made.certificateDER), format: .der)
        #expect(try parsed.toDERBytes() == Array(made.certificateDER))
        _ = try made.sslContext()
        #expect(made.fingerprint.count == 95)

        // Kept: the same names give the same certificate back.
        let again = try UICertificate.load(configuration: configuration, directory: directory, names: ["localhost", "bridge.local"], logger: testLogger)
        #expect(again.certificateDER == made.certificateDER)
        let key = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(UICertificate.keyFile).path)
        #expect((key[.posixPermissions] as? Int) == 0o600)
        // Other names: a new one.
        let renamed = try UICertificate.load(configuration: configuration, directory: directory, names: ["other.local"], logger: testLogger)
        #expect(renamed.certificateDER != made.certificateDER)

        // OpenSSL reads it as browsers would, when it is installed.
        guard let openssl = ["/usr/bin/openssl", "/opt/homebrew/bin/openssl"].first(where: FileManager.default.isExecutableFile(atPath:)) else { return }
        let file = directory.appendingPathComponent("check.pem")
        try Data(made.certificatePEM.utf8).write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = ["x509", "-in", file.path, "-noout", "-text"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(text.contains("DNS:bridge.local"))
        #expect(text.contains("DNS:localhost"))
        #expect(text.contains("CA:TRUE"))
        #expect(text.contains("TLS Web Server Authentication"))
        #expect(text.contains("ecdsa-with-SHA256"))
    }

    /// A name that goes away (a VPN's address) keeps the certificate a phone trusts; a configured file keeps its chain.
    @Test func keepsTheCertificateAndItsChain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-tls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = UIConfiguration()
        configuration.https = true
        let first = try UICertificate.load(configuration: configuration, directory: directory, names: ["bridge.local", "vpn.example", "localhost"], logger: testLogger)
        let fewer = try UICertificate.load(configuration: configuration, directory: directory, names: ["bridge.local", "localhost"], logger: testLogger)
        #expect(fewer.certificateDER == first.certificateDER)

        let other = try UICertificate.load(configuration: configuration, directory: FileManager.default.temporaryDirectory.appendingPathComponent("homeswift-tls-\(UUID().uuidString)"), names: ["ca.local"], logger: testLogger)
        let chainURL = directory.appendingPathComponent("fullchain.pem")
        let keyURL = directory.appendingPathComponent("key.pem")
        try Data((first.certificatePEM + other.certificatePEM).utf8).write(to: chainURL)
        try Data(first.keyPEM.utf8).write(to: keyURL)
        configuration.certificate = chainURL.path
        configuration.privateKey = keyURL.path
        let configured = try UICertificate.load(configuration: configuration, directory: directory, names: [], logger: testLogger)
        #expect(configured.chainDER == [first.certificateDER, other.certificateDER])
        _ = try configured.sslContext()
    }

    /// A dropped file goes where it belongs: a key in the key's field, a certificate in the certificate's.
    @Test func storesDroppedFilesForTheirField() async throws {
        let environment = try UITestEnvironment(auth: .none)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        let made = try UICertificate.load(configuration: UIConfiguration(), directory: environment.directory.appendingPathComponent("made"), names: ["localhost"], logger: testLogger)
        let browser = Browser(base: base)
        let stored = try await browser.post("/api/files", ["field": "certificate", "name": "cert.pem", "content": .string(made.certificatePEM)])
        #expect(stored.status == 200)
        let path = try #require(stored.json?["path"]?.stringValue)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == made.certificatePEM)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
        #expect(try await browser.post("/api/files", ["field": "certificate", "name": "key.pem", "content": .string(made.keyPEM)]).status == 400)
        #expect(try await browser.post("/api/files", ["field": "privateKey", "name": "key.pem", "content": .string(made.keyPEM)]).status == 200)
        #expect(try await browser.post("/api/files", ["field": "../escape", "name": "x.pem", "content": .string(made.keyPEM)]).status == 400)
        #expect(try await browser.post("/api/files", ["field": "certificate", "name": "x.pem", "content": "not a pem"]).status == 400)
    }

    @Test func servesTheUIOverHTTPS() async throws {
        let environment = try UITestEnvironment(https: true)
        let base = try await environment.start()
        defer { Task { await environment.stop() } }
        #expect(base.scheme == "https")
        let client = HTTPClient(tls: .any)
        let page = try await client.send(HTTPRequest(url: base.appendingPathComponent("/")))
        #expect(page.status == 200)
        let fingerprint = try #require(environment.server.certificateFingerprint)
        #expect(page.certificateFingerprint.map(HTTPClient.normalizeFingerprint) == HTTPClient.normalizeFingerprint(fingerprint))
        // The home screen icon is in the page: iOS fetches a linked one without the user's certificate exception.
        let icon = try #require(WebAssets.files["apple-touch-icon.png"]).data.base64EncodedString()
        #expect(String(decoding: page.body, as: UTF8.self).contains(#"<link rel="apple-touch-icon" href="data:image/png;base64,\#(icon)">"#))

        let certificate = try await client.send(HTTPRequest(url: base.appendingPathComponent("homeswift-ui.crt")))
        #expect(certificate.status == 200)
        #expect(certificate.header("content-type") == "application/x-x509-ca-cert")
        #expect(HTTPClient.fingerprint(der: Array(certificate.body)) == HTTPClient.normalizeFingerprint(fingerprint))

        // The session cookie only travels over HTTPS.
        let code = try #require(environment.server.setupCode)
        let setup = try await client.send(HTTPRequest(
            method: "POST", url: base.appendingPathComponent("api/auth/setup"), headers: [("Content-Type", "application/json")],
            body: JSONValue.object(["username": "rosaly", "password": "staple-copper-violet-lantern", "setupCode": .string(code)]).encoded()))
        #expect(setup.status == 200)
        #expect(setup.header("set-cookie")?.contains("; Secure") == true)
    }
}
