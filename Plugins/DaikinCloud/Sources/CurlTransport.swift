import Foundation
import HomeswiftNetwork
import NIOConcurrencyHelpers

/// Requests through the system's curl binary: the escape hatch for networks whose firewall drops the built-in
/// client's TLS ClientHello while curl's passes (`"httpTransport": "curl"`).
///
/// Secrets stay off the command line, which every process on the host can read: the URL, headers and body go
/// through a 0600 config file in a private temporary directory. curl runs with `-q` first, so `~/.curlrc`
/// cannot add options, and with `proto = "=https"`, so it never falls back to plain HTTP. Its exit codes
/// become the errno-style codes the retry logic understands.
struct CurlTransport: HTTPSending {
    var executable = "curl"

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daikin-curl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var bodyFile: URL?
        if let body = request.body {
            let url = directory.appendingPathComponent("body")
            guard FileManager.default.createFile(atPath: url.path, contents: body, attributes: [.posixPermissions: 0o600]) else {
                throw DaikinNetworkError(code: "ECURL", message: "cannot write the request body for curl")
            }
            bodyFile = url
        }
        let configFile = directory.appendingPathComponent("request.conf")
        let config = try Self.config(for: request, bodyFile: bodyFile?.path)
        guard FileManager.default.createFile(atPath: configFile.path, contents: Data(config.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw DaikinNetworkError(code: "ECURL", message: "cannot write the curl configuration")
        }
        let (status, output, errors) = try await run(arguments: ["-q", "--config", configFile.path], timeout: request.timeout + .seconds(5))
        if status == -1 { throw DaikinNetworkError(code: "ENOENT", message: errors) }
        guard status == 0 else { throw Self.error(exitCode: status, stderr: errors) }
        return try Self.parse(output)
    }

    /// The curl configuration for a request.
    static func config(for request: HTTPRequest, bodyFile: String?) throws -> String {
        let seconds = Int((Double(request.timeout.components.seconds) + Double(request.timeout.components.attoseconds) / 1e18).rounded(.up))
        var lines = [
            "proto = \"=https\"",
            "url = \(try quote(request.url.absoluteString))",
            "request = \(try quote(request.method))",
            "max-time = \(seconds)",
            // The built-in client's cap: the whole output is read into memory.
            "max-filesize = \(DaikinHTTP.maximumBodySize)",
            "silent",
            "show-error",
            "include",
        ]
        var headers = request.headers
        if !headers.contains(where: { $0.name.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            headers.insert((name: "User-Agent", value: DaikinHTTP.userAgent), at: 0)
        }
        // curl computes Content-Length from the body; a second one is invalid.
        for header in headers where header.name.caseInsensitiveCompare("Content-Length") != .orderedSame {
            lines.append("header = \(try quote("\(header.name): \(header.value)"))")
        }
        if let bodyFile { lines.append("data-binary = \(try quote("@\(bodyFile)"))") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A value for a double-quoted config entry. An entry ends at a line break, so a CR or LF (from a
    /// cloud-supplied id in a URL, say) could inject options such as `output`; NUL truncates. Neither belongs
    /// in a URL or header.
    static func quote(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            throw DaikinNetworkError(code: "ECURL", message: "Refusing to pass a value containing CR, LF or NUL to curl")
        }
        return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// `curl --include` output: one or more header blocks (interim 1xx and proxy CONNECT answers come first),
    /// then the body. Repeated headers (Set-Cookie) stay separate.
    static func parse(_ raw: Data) throws -> HTTPResponse {
        var rest = raw[...]
        while true {
            guard let lineEnd = rest.firstIndex(of: UInt8(ascii: "\n")) else { throw DaikinNetworkError(code: "ECURL", message: "Could not parse curl response (no HTTP status line)") }
            let statusLine = String(decoding: rest[rest.startIndex..<lineEnd], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = statusLine.split(separator: " ")
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]), parts[1].count == 3 else {
                throw DaikinNetworkError(code: "ECURL", message: "Could not parse curl response (no HTTP status line)")
            }
            let headerStart = rest.index(after: lineEnd)
            let (headerBlock, bodyStart) = splitHeaders(rest[headerStart...])
            rest = rest[bodyStart...]
            let next = String(decoding: rest.prefix(16), as: UTF8.self)
            if (100..<200).contains(status) || (next.hasPrefix("HTTP/") && next.dropFirst(5).contains(" ")) {
                continue
            }
            var headers: [(name: String, value: String)] = []
            for line in String(decoding: headerBlock, as: UTF8.self).split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else { continue }
                headers.append((name: text[..<colon].trimmingCharacters(in: .whitespaces).lowercased(), value: text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            }
            return HTTPResponse(status: status, headers: headers, body: Data(rest))
        }
    }

    /// Splits at the first blank line (`\r\n\r\n` or `\n\n`): the header lines, and where the body starts.
    private static func splitHeaders(_ data: Data.SubSequence) -> (Data.SubSequence, Data.Index) {
        var index = data.startIndex
        // No header lines: the blank line comes first.
        if data.first == UInt8(ascii: "\n") { return (data[index..<index], data.index(after: index)) }
        if data.starts(with: [UInt8(ascii: "\r"), UInt8(ascii: "\n")]) { return (data[index..<index], data.index(index, offsetBy: 2)) }
        while index < data.endIndex {
            if data[index] == UInt8(ascii: "\n") {
                var next = data.index(after: index)
                if next < data.endIndex, data[next] == UInt8(ascii: "\r") { next = data.index(after: next) }
                if next < data.endIndex, data[next] == UInt8(ascii: "\n") {
                    return (data[data.startIndex..<index], data.index(after: next))
                }
                if next == data.endIndex { return (data[data.startIndex..<index], data.endIndex) }
            }
            index = data.index(after: index)
        }
        return (data, data.endIndex)
    }

    /// curl's exit codes as the errno-style codes the callers' retry logic uses.
    static let exitCodes: [Int32: String] = [6: "ENOTFOUND", 7: "ECONNREFUSED", 28: "ETIMEDOUT", 35: "ECONNRESET", 52: "ECONNRESET", 55: "EPIPE", 56: "ECONNRESET"]

    static func error(exitCode: Int32, stderr: String) -> DaikinNetworkError {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return DaikinNetworkError(code: exitCodes[exitCode] ?? "ECURL", message: "curl failed (exit \(exitCode)): \(detail.isEmpty ? "no output" : detail)")
    }

    private func run(arguments: [String], timeout: Duration) async throws -> (Int32, Data, String) {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        // Install termination observation before launch: a short-lived child can exit before a later
        // waitUntilExit() starts its run loop (the macOS CI hang). Drain both pipes independently too:
        // reading stdout to EOF first can deadlock when the child fills stderr before closing stdout.
        return try await withCheckedThrowingContinuation { continuation in
            let completed = DispatchGroup()
            let stdout = NIOLockedValueBox(Data())
            let stderr = NIOLockedValueBox(Data())
            let exitStatus = NIOLockedValueBox<Int32>(0)
            completed.enter()
            process.terminationHandler = { child in
                exitStatus.withLockedValue { $0 = child.terminationStatus }
                completed.leave()
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                completed.leave()
                continuation.resume(throwing: DaikinNetworkError(code: "ENOENT", message: "httpTransport \"curl\" requires the curl binary, but none was found on this system"))
                return
            }
            let watchdog = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                if process.isRunning { process.terminate() }
            }
            completed.enter()
            DispatchQueue.global().async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                stdout.withLockedValue { $0 = data }
                completed.leave()
            }
            completed.enter()
            DispatchQueue.global().async {
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                stderr.withLockedValue { $0 = data }
                completed.leave()
            }
            completed.notify(queue: .global()) {
                watchdog.cancel()
                process.terminationHandler = nil
                var status = exitStatus.withLockedValue { $0 }
                let errors = String(decoding: stderr.withLockedValue { $0 }, as: UTF8.self)
                // `env` answers 127 when it cannot find curl.
                if status == 127, errors.contains("No such file") { status = -1 }
                continuation.resume(returning: (status, stdout.withLockedValue { $0 }, status == -1 ? "httpTransport \"curl\" requires the curl binary, but none was found on this system" : errors))
            }
        }
    }
}
