import Foundation
import HomeswiftNetwork
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import HomeswiftDaikinCloud

/// The curl transport (the Homebridge plugin's http-transport tests), errors in errno terms, and the callback
/// server's certificate and HTTPS.
@Suite(.timeLimit(.minutes(1)))
struct TransportTests {
    let directory = temporaryDirectory("daikin-transport")

    @Test func parsesCurlOutput() throws {
        let simple = try CurlTransport.parse(Data("HTTP/1.1 403 Forbidden\r\ncontent-type: application/json\r\n\r\n{\"error\":\"invalid_client\"}".utf8))
        #expect(simple.status == 403)
        #expect(simple.header("Content-Type") == "application/json")
        #expect(simple.text == #"{"error":"invalid_client"}"#)
        let http2 = try CurlTransport.parse(Data("HTTP/2 200\r\ncontent-type: text/plain\r\n\r\nok".utf8))
        #expect(http2.status == 200 && http2.text == "ok")
        let cookies = try CurlTransport.parse(Data("HTTP/1.1 200 OK\r\nset-cookie: gig_canary=a; Path=/\r\nset-cookie: gig_b=c; Path=/\r\n\r\n{}".utf8))
        #expect(cookies.values(of: "Set-Cookie") == ["gig_canary=a; Path=/", "gig_b=c; Path=/"])
        let interim = try CurlTransport.parse(Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nlocation: /x\r\n\r\ndone".utf8))
        #expect(interim.status == 201 && interim.header("Location") == "/x" && interim.text == "done")
        let redirect = try CurlTransport.parse(Data("HTTP/1.1 302 Found\r\nlocation: daikinunified://cdc/?code=abc\r\n\r\n".utf8))
        #expect(redirect.status == 302 && redirect.header("location") == "daikinunified://cdc/?code=abc")
        #expect(throws: DaikinNetworkError.self) { try CurlTransport.parse(Data("garbage".utf8)) }
    }

    @Test func curlConfiguration() throws {
        #expect(try CurlTransport.quote(#"a"b\c"#) == #""a\"b\\c""#)
        for bad in ["a\nb", "a\rb", "a\0b", "a\r\nb"] { #expect(throws: DaikinNetworkError.self) { try CurlTransport.quote(bad) } }
        var request = HTTPRequest(method: "POST", url: URL(string: "https://h/")!, body: Data("abc".utf8), timeout: .seconds(30))
        request.setHeader("Content-Length", "3")
        let config = try CurlTransport.config(for: request, bodyFile: "/tmp/body")
        #expect(config.split(separator: "\n").first == #"proto = "=https""#)
        #expect(!config.lowercased().contains("content-length"))
        #expect(config.contains(#"data-binary = "@/tmp/body""#))
        #expect(config.contains(#"header = "User-Agent: okhttp/4.12.0""#))
        #expect(config.contains("max-time = 30"))
        #expect(config.contains("max-filesize = 10485760"))
    }

    /// A stand-in for curl: checks how it is called, then answers or fails.
    func fakeCurl(exit code: Int, stdout: String = "", stderr: String = "") throws -> String {
        let url = directory.appendingPathComponent("curl-\(UUID().uuidString).sh")
        let script = """
            #!/bin/sh
            [ "$1" = "-q" ] || { echo "-q must come first" >&2; exit 99; }
            [ "$2" = "--config" ] || exit 98
            cp "$3" "\(directory.path)/last.conf"
            printf '%s' "$3" > "\(directory.path)/last.path"
            printf '\(stdout)'
            printf '%s' '\(stderr)' >&2
            exit \(code)
            """
        // Through a close-on-exec descriptor: a process another test spawns meanwhile would otherwise keep the file open for
        // writing, and Linux refuses to run it (ETXTBSY, which CurlTransport reports as a missing curl).
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o700)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bytes = Array(script.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == bytes.count else { throw POSIXError(.EIO) }
        return url.path
    }

    @Test func runsCurl() async throws {
        let curl = CurlTransport(executable: try fakeCurl(exit: 0, stdout: "HTTP/1.1 200 OK\\r\\nx-test: 1\\r\\n\\r\\nhello"))
        var request = HTTPRequest(method: "POST", url: URL(string: "https://api.example.com/x")!, body: Data("secret body".utf8))
        request.setHeader("Authorization", "Bearer secret-token")
        let response = try await curl.send(request)
        #expect(response.status == 200)
        #expect(response.text == "hello")
        // The secrets went through the 0600 config file, which is gone with its directory.
        let config = try String(contentsOf: directory.appendingPathComponent("last.conf"), encoding: .utf8)
        #expect(config.contains(#"header = "Authorization: Bearer secret-token""#))
        #expect(config.contains(#"url = "https://api.example.com/x""#))
        let used = try String(contentsOf: directory.appendingPathComponent("last.path"), encoding: .utf8)
        #expect(used.contains("daikin-curl-"))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: used).deletingLastPathComponent().path))
    }

    @Test(arguments: [(28, "ETIMEDOUT"), (7, "ECONNREFUSED"), (6, "ENOTFOUND"), (35, "ECONNRESET"), (97, "ECURL")])
    func curlExitCodes(_ code: Int, _ expected: String) async throws {
        let curl = CurlTransport(executable: try fakeCurl(exit: code, stderr: "curl: failure"))
        do {
            _ = try await curl.send(HTTPRequest(url: URL(string: "https://api.example.com/")!))
            Issue.record("no error")
        } catch let error as DaikinNetworkError {
            #expect(error.code == expected)
            #expect(error.message.contains("exit \(code)"))
            #expect(error.message.contains("curl: failure"))
        }
    }

    /// Repeated rapid exits exercise termination observation being installed before Process.run().
    @Test func concurrentShortLivedCurlProcesses() async throws {
        let executable = try fakeCurl(exit: 0, stdout: "HTTP/1.1 200 OK\\r\\n\\r\\nhello")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<10 {
                        let response = try await CurlTransport(executable: executable).send(HTTPRequest(url: URL(string: "https://api.example.com/")!))
                        #expect(response.text == "hello")
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// Stderr exceeds pipe capacity before stdout closes: sequential draining used to deadlock.
    @Test func drainsBothCurlPipesConcurrently() async throws {
        let executable = try fakeCurl(exit: 0, stdout: "HTTP/1.1 200 OK\\r\\n\\r\\nhello", stderr: String(repeating: "x", count: 262_144))
        let response = try await CurlTransport(executable: executable).send(HTTPRequest(url: URL(string: "https://api.example.com/")!))
        #expect(response.text == "hello")
    }

    @Test func missingCurl() async throws {
        let curl = CurlTransport(executable: "/nonexistent/curl")
        await #expect(throws: DaikinNetworkError.self) { try await curl.send(HTTPRequest(url: URL(string: "https://api.example.com/")!)) }
        do {
            _ = try await CurlTransport(executable: "daikin-no-such-curl").send(HTTPRequest(url: URL(string: "https://api.example.com/")!))
        } catch let error as DaikinNetworkError {
            #expect(error.code == "ENOENT")
            #expect(error.message.contains("requires the curl binary"))
        }
    }

    @Test func refusesLineBreaksAndNeverRunsCurl() async throws {
        let curl = CurlTransport(executable: try fakeCurl(exit: 0, stdout: "HTTP/1.1 200 OK\\r\\n\\r\\n"))
        var request = HTTPRequest(url: URL(string: "https://api.example.com/")!)
        request.setHeader("X-Test", "a\nupload-file = \"/etc/passwd\"")
        await #expect(throws: DaikinNetworkError(code: "ECURL", message: "Refusing to pass a value containing CR, LF or NUL to curl")) { try await curl.send(request) }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("last.conf").path))
    }

    @Test func networkErrorsInErrnoTerms() {
        #expect(DaikinNetworkError(HTTPClientError.timeout, timeout: .seconds(30)) == DaikinNetworkError(code: "ETIMEDOUT", message: "no response after 30000ms"))
        #expect(DaikinNetworkError(HTTPClientError.cannotConnect(host: "h", port: 443, code: ECONNREFUSED, reason: "connection refused"), timeout: .seconds(1)).code == "ECONNREFUSED")
        #expect(DaikinNetworkError(HTTPClientError.connectionClosed, timeout: .seconds(1)).code == "ECONNRESET")
        #expect(DaikinNetworkError(code: "ETIMEDOUT", message: "").isRetryable)
        #expect(!DaikinNetworkError(code: "EPROTO", message: "").isRetryable)
        #expect(URLEncoding.form([("a b", "c&d=é")]) == "a+b=c%26d%3D%C3%A9")
        #expect(URLEncoding.uriComponent("a/b?c#d e") == "a%2Fb%3Fc%23d%20e")
        #expect(URLQuery.parameter("code", in: "https://h:1/?code=a%2Fb&state=s#x") == "a/b")
        #expect(URLQuery.parameter("state", in: "https://h:1/?code=a%2Fb&state=s#x") == "s")
        #expect(URLQuery.parameter("nope", in: "https://h:1/?code=a") == nil)
        #expect(URLQuery.match("code", in: "daikinunified://login?code=auth-code-456&x=1") == "auth-code-456")
    }

    // MARK: The callback server

    @Test func selfSignedCertificate() throws {
        for host in ["192.168.1.100", "homeswift.local", "fe80::1"] {
            let material = try SelfSignedCertificate.make(hostname: host)
            let certificate = try NIOSSLCertificate(bytes: material.certificateDER, format: .der)
            let names = Array(certificate._subjectAlternativeNames())
            #expect(names.count == 1, "\(host)")
            #expect(try NIOSSLCertificate(bytes: Array(material.certificatePEM.utf8), format: .pem) == certificate)
            _ = try NIOSSLPrivateKey(bytes: Array(material.privateKeyPEM.utf8), format: .pem)
        }
        #expect(throws: DaikinError("Invalid hostname: contains disallowed characters")) { try SelfSignedCertificate.validate("a b; rm -rf /") }
        #expect(throws: DaikinError("Hostname is required")) { try SelfSignedCertificate.validate("") }
        // Kept and reused for the same address, made again for another.
        let first = try SelfSignedCertificate.load(for: "192.168.1.100", in: directory)
        #expect(try SelfSignedCertificate.load(for: "192.168.1.100", in: directory).certificatePEM == first.certificatePEM)
        #expect(try SelfSignedCertificate.load(for: "192.168.1.101", in: directory).certificatePEM != first.certificatePEM)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("server.key").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func callbackServerAnswersOverHTTPS() async throws {
        let server = CallbackServer(logger: testLogger)
        let port = Int.random(in: 40000...60000)
        try await server.start(port: port, hostname: "127.0.0.1", bindAddress: "127.0.0.1", certificateDirectory: directory, lifetime: .seconds(30)) { uri in
            (200, CallbackServer.page(success: true, message: "Got \(uri) <script>"))
        }
        #expect(server.isRunning)
        let client = HTTPClient(tls: .any)
        let response = try await client.send(HTTPRequest(url: URL(string: "https://127.0.0.1:\(port)/?code=abc&state=xyz")!))
        #expect(response.status == 200)
        #expect(response.text.contains("Got /?code=abc&amp;state=xyz &lt;script&gt;"))
        #expect(response.header("Content-Security-Policy") == "default-src 'none'; style-src 'unsafe-inline'")
        #expect(response.certificateFingerprint != nil)
        await server.stop()
        #expect(!server.isRunning)
        await #expect(throws: (any Error).self) { try await client.send(HTTPRequest(url: URL(string: "https://127.0.0.1:\(port)/")!, timeout: .seconds(2))) }
    }

    @Test func callbackServerStopsByItself() async throws {
        let server = CallbackServer(logger: testLogger)
        try await server.start(port: Int.random(in: 40000...60000), hostname: "127.0.0.1", bindAddress: "127.0.0.1", certificateDirectory: directory, lifetime: .milliseconds(100)) { _ in (200, "") }
        #expect(await eventually { !server.isRunning })
    }

    /// A browser that offers only TLS 1.0/1.1 gets no handshake; 1.2 does.
    @Test(arguments: [(TLSVersion.tlsv1, false), (TLSVersion.tlsv11, false), (TLSVersion.tlsv12, true)])
    func callbackServerNeedsTLS12(_ version: TLSVersion, _ accepted: Bool) async throws {
        let server = CallbackServer(logger: testLogger)
        let port = Int.random(in: 40000...60000)
        try await server.start(port: port, hostname: "127.0.0.1", bindAddress: "127.0.0.1", certificateDirectory: directory, lifetime: .seconds(30)) { _ in (200, "ok") }
        defer { Task { await server.stop() } }
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .none
        configuration.minimumTLSVersion = .tlsv1
        configuration.maximumTLSVersion = version
        let context = try NIOSSLContext(configuration: configuration)
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: nil)) }
            }
            .connect(host: "127.0.0.1", port: port).get()
        defer { channel.close(promise: nil) }
        // Writes wait for the handshake and fail with it.
        let written: Bool
        do {
            try await channel.writeAndFlush(ByteBuffer(string: "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")).get()
            written = true
        } catch {
            written = false
        }
        #expect(written == accepted)
    }

    /// A stop while the start waits for a busy port leaves nothing listening once the port frees up.
    @Test func aStopDuringTheStartLeavesNothingRunning() async throws {
        let port = Int.random(in: 40000...60000)
        let occupier = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: port).get()
        let server = CallbackServer(logger: testLogger)
        let directory = directory
        let start = Task {
            try await server.start(port: port, hostname: "127.0.0.1", bindAddress: "127.0.0.1", certificateDirectory: directory, lifetime: .seconds(30)) { _ in (200, "") }
        }
        try await Task.sleep(for: .milliseconds(300))
        await server.stop()
        try await occupier.close()
        await #expect(throws: CallbackServer.Superseded.self) { try await start.value }
        #expect(!server.isRunning)
        // The port is free: nothing bound it behind the stop.
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: port).get()
        try await probe.close()
    }

    @Test func loopbackAndBindAddresses() {
        // `isNumber` digits Int cannot read ("½", Arabic-Indic) are not an address, and do not trap.
        for host in ["½.0.0.1", "١٢٧.0.0.1", "127.0.0.1²", "256.0.0.1", "1.2.3", "1..2.3", "１２７.0.0.1"] { #expect(!NetworkInfo.isIPv4(host), "\(host)") }
        #expect(NetworkInfo.isIPv4("127.0.0.1") && NetworkInfo.isIPv4("255.255.255.255"))
        #expect(!NetworkInfo.isLoopback("½.0.0.1"))
        for host in ["localhost", "127.0.0.1", "127.1.2.3", "::1", "[::1]", "::ffff:127.0.0.1", "app.localhost"] { #expect(NetworkInfo.isLoopback(host), "\(host)") }
        for host in ["192.168.1.10", "0.0.0.0", "example.com", "::"] { #expect(!NetworkInfo.isLoopback(host), "\(host)") }
        #expect(NetworkInfo.bindAddress("127.0.0.1") == "127.0.0.1")
        #expect(NetworkInfo.bindAddress(" 192.168.1.2 ") == "192.168.1.2")
        #expect(NetworkInfo.bindAddress("not an ip") == "0.0.0.0")
        #expect(NetworkInfo.bindAddress(nil) == "0.0.0.0")
    }
}
